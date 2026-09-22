//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Synchronization
import os

// Minimal HTTP/1.1 server for a localhost API: blocking sockets, one thread per connection, keep-alive,
// chunked streaming responses, CORS preflight. Replaces Hummingbird and its ~20 transitive packages.

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONCoding.plainDecoder.decode(type, from: body)
    }
}

public struct HTTPResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        case stream(AsyncThrowingStream<Data, Error>)
    }

    public var status: Int
    public var headers: [String: String]
    public var body: Body

    public init(status: Int = 200, headers: [String: String] = [:], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public init(status: Int = 200, contentType: String, data: Data) {
        self.init(status: status, headers: ["Content-Type": contentType], body: .data(data))
    }

    public static func text(_ s: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, contentType: contentType, data: Data(s.utf8))
    }

    static let reasons: [Int: String] = [
        200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 413: "Content Too Large", 500: "Internal Server Error", 501: "Not Implemented",
        503: "Service Unavailable",
    ]
}

/// Which browser origins may call the API; clients without an Origin header are unaffected.
public enum CORSPolicy: Sendable, Equatable {
    case disabled
    case localhost
    case custom([String])

    public static func parse(mode: String, origins: String) -> CORSPolicy {
        switch mode {
        case "off": return .disabled
        case "custom":
            return .custom(origins.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        default: return .localhost
        }
    }

    /// Value to echo in Access-Control-Allow-Origin, or nil when the origin is not allowed.
    public func allowedOrigin(for origin: String?) -> String? {
        guard let origin, !origin.isEmpty else { return nil }
        switch self {
        case .disabled: return nil
        case .localhost: return Self.isLocalhost(origin) ? origin : nil
        case .custom(let list):
            if list.contains("*") { return "*" }
            return list.contains { $0.caseInsensitiveCompare(origin) == .orderedSame } ? origin : nil
        }
    }

    /// Web pages must come from localhost; non-web schemes (app://, vscode-webview://, file://…)
    /// are desktop clients a web page cannot impersonate, so they pass — as Ollama allows them.
    static func isLocalhost(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return true }
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }
}

public typealias HTTPHandler = @Sendable (HTTPRequest) async throws -> HTTPResponse

/// Routes are exact `METHOD /path` matches; HEAD falls back to GET; OPTIONS answers CORS preflight.
public final class HTTPServer: Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int
        public var serverName: String
        public var maxBodyBytes: Int
        public var keepAliveTimeoutSeconds: Int
        public var log: (@Sendable (String) -> Void)?

        public init(
            host: String = "127.0.0.1", port: Int, serverName: String = "Mac-Olama", maxBodyBytes: Int = 256 << 20,
            keepAliveTimeoutSeconds: Int = 75, log: (@Sendable (String) -> Void)? = nil
        ) {
            self.host = host
            self.port = port
            self.serverName = serverName
            self.maxBodyBytes = maxBodyBytes
            self.keepAliveTimeoutSeconds = keepAliveTimeoutSeconds
            self.log = log
        }
    }

    public enum ServerError: Error { case socket(String), bind(Int32), listen(Int32) }

    private let configuration: Configuration
    private let routes = Mutex<[String: HTTPHandler]>([:])
    private let notFound = Mutex<HTTPHandler>({ _ in
        HTTPResponse.text("{\"error\":\"not found\"}", status: 404, contentType: "application/json")
    })
    private let errorMapper = Mutex<(@Sendable (Error) -> HTTPResponse)?>(nil)
    private let listenFD = Mutex<Int32>(-1)
    private let running = Mutex(false)
    private let cors = Mutex<CORSPolicy>(.localhost)
    private let activeConnections = Mutex(0)
    /// Connections waiting for their next request, and since when: at the ceiling the oldest is closed for a new client.
    private let idleConnections = Mutex<[Int32: ContinuousClock.Instant]>([:])
    /// Thread-per-connection needs a ceiling; beyond it the longest-idle keep-alive connection makes room, and only
    /// when every connection is busy does a new client get a 503.
    private static let maxConnections = 64
    /// A client that stops reading fails its send() after this instead of parking the thread forever.
    private static let sendTimeoutSeconds = 30

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func route(_ method: String, _ path: String, _ handler: @escaping HTTPHandler) {
        routes.withLock { $0["\(method.uppercased()) \(path)"] = handler }
    }

    public func setNotFound(_ handler: @escaping HTTPHandler) { notFound.withLock { $0 = handler } }

    /// Applies immediately to new responses; no restart needed.
    public func setCORSPolicy(_ policy: CORSPolicy) { cors.withLock { $0 = policy } }

    /// Maps errors thrown by handlers to responses (default: 500 with the error text).
    public func setErrorMapper(_ mapper: @escaping @Sendable (Error) -> HTTPResponse) { errorMapper.withLock { $0 = mapper } }

    // Lifecycle

    /// Binds and starts the accept loop on a dedicated thread. Throws when the port is taken.
    public func start() throws {
        let streamType = SOCK_STREAM
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw ServerError.socket("socket() failed: \(errno)") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(configuration.port).bigEndian
        addr.sin_addr.s_addr = inet_addr(configuration.host)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { let e = errno; close(fd); throw ServerError.bind(e) }
        guard listen(fd, 64) == 0 else { let e = errno; close(fd); throw ServerError.listen(e) }
        listenFD.withLock { $0 = fd }
        running.withLock { $0 = true }
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "HTTPServer.accept"
        thread.start()
        configuration.log?("listening on \(configuration.host):\(configuration.port)")
    }

    public func stop() {
        running.withLock { $0 = false }
        let fd = listenFD.withLock { fd -> Int32 in
            let f = fd; fd = -1; return f
        }
        if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
    }

    public var isRunning: Bool { running.withLock { $0 } }

    /// Whether a server could take this address now: nothing accepts connections on it, and it can be bound. The
    /// connect catches a program on 127.0.0.1 that a wildcard bind with `SO_REUSEADDR` would quietly share the port with.
    public static func portIsFree(host: String, port: Int) -> Bool {
        let local = host == "0.0.0.0" ? "127.0.0.1" : host
        if withSocket(host: local, port: port, { fd, addr in connect(fd, addr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }) {
            return false
        }
        return withSocket(host: host, port: port) { fd, addr in
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            return bind(fd, addr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }

    private static func withSocket(host: String, port: Int, _ body: (Int32, UnsafePointer<sockaddr>) -> Bool) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body(fd, $0) } }
    }

    private func acceptLoop(_ fd: Int32) {
        while running.withLock({ $0 }) {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            guard client >= 0 else { if errno == EINTR { continue } else { break } }
            if activeConnections.withLock({ $0 }) >= Self.maxConnections, !closeOldestIdleConnection() {
                let body = #"{"error":"server busy: too many connections"}"#
                let reply = Data(
                    ("HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
                        + "Retry-After: 1\r\nConnection: close\r\n\r\n" + body).utf8)
                _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                close(client)
                continue
            }
            var timeout = timeval()
            timeout.tv_sec = numericCast(configuration.keepAliveTimeoutSeconds)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var sendTimeout = timeval()
            sendTimeout.tv_sec = numericCast(Self.sendTimeoutSeconds)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            activeConnections.withLock { $0 += 1 }
            let thread = Thread { [self] in
                serve(client)
                activeConnections.withLock { $0 -= 1 }
            }
            thread.name = "HTTPServer.connection"
            thread.start()
        }
    }

    /// Shuts the longest-idle keep-alive connection down; its thread sees the end of the stream and exits. The owner
    /// leaves the map under the same lock before it closes the descriptor, so a reused number is never shut here.
    private func closeOldestIdleConnection() -> Bool {
        idleConnections.withLock { idle in
            guard let oldest = idle.min(by: { $0.value < $1.value })?.key else { return false }
            idle[oldest] = nil
            shutdown(oldest, Int32(SHUT_RDWR))
            return true
        }
    }

    // Connection

    private func serve(_ fd: Int32) {
        defer {
            idleConnections.withLock { $0[fd] = nil }
            close(fd)
        }
        let connection = Connection(fd: fd)
        while running.withLock({ $0 }) {
            idleConnections.withLock { $0[fd] = .now }
            let parsed: Connection.Parsed?
            do {
                // Busy from the first byte on: an evicted connection must not be one that is sending a request.
                parsed = try connection.readRequest(maxBody: configuration.maxBodyBytes) {
                    idleConnections.withLock { $0[fd] = nil }
                }
            } catch Connection.ReadError.tooLarge {
                let limit = configuration.maxBodyBytes >> 20
                let response = HTTPResponse.text(
                    "{\"error\":\"request body is larger than \(limit) MB\"}", status: 413, contentType: "application/json")
                _ = connection.write(response, isHead: false)
                return
            } catch {
                return
            }
            guard let request = parsed else { return }
            let wantsClose = request.request.headers["connection"]?.lowercased() == "close" || request.version == "HTTP/1.0"
            let origin = request.request.headers["origin"]
            let allowedOrigin = cors.withLock { $0 }.allowedOrigin(for: origin)
            // Simple cross-origin POSTs skip the preflight; a disallowed browser origin must not reach
            // state-changing routes at all, not merely lose the response.
            var response: HTTPResponse
            if origin != nil, allowedOrigin == nil, !["GET", "HEAD", "OPTIONS"].contains(request.request.method) {
                response = HTTPResponse.text("{\"error\":\"origin not allowed\"}", status: 403, contentType: "application/json")
            } else {
                response = handle(request.request, fd: fd)
            }
            var headers = response.headers
            headers["Server"] = configuration.serverName
            if origin != nil { headers["Vary"] = "Origin" }
            if let allowedOrigin { headers["Access-Control-Allow-Origin"] = allowedOrigin }
            headers["Connection"] = wantsClose ? "close" : "keep-alive"
            response.headers = headers
            let ok = connection.write(response, isHead: request.request.method == "HEAD")
            if !ok || wantsClose { return }
        }
    }

    /// Runs the async handler on a cooperative task and blocks this connection thread until it returns. A client that
    /// hangs up meanwhile (a request without streaming, still generating) cancels the handler instead of leaving a
    /// reply nobody reads at the head of the model's queue.
    private func handle(_ request: HTTPRequest, fd: Int32) -> HTTPResponse {
        if request.method == "OPTIONS" {
            let origin = request.headers["origin"]
            guard origin == nil || cors.withLock({ $0 }).allowedOrigin(for: origin) != nil else {
                return HTTPResponse(status: 403)
            }
            return HTTPResponse(
                status: 204,
                headers: [
                    "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
                    "Access-Control-Allow-Headers": "Content-Type, Authorization",
                ])
        }
        let key = "\(request.method) \(request.path)"
        let getKey = "GET \(request.path)"
        let handler = routes.withLock { $0[key] ?? (request.method == "HEAD" ? $0[getKey] : nil) } ?? notFound.withLock { $0 }
        let mapper = errorMapper.withLock { $0 }
        // A lock rather than `Mutex`: the result crosses into an escaping closure, and `Mutex` cannot be captured there.
        let result = OSAllocatedUnfairLock(initialState: HTTPResponse(status: 500))
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let response: HTTPResponse
            do { response = try await handler(request) } catch {
                response = mapper?(error) ?? HTTPResponse.text("{\"error\":\"\(error)\"}", status: 500, contentType: "application/json")
            }
            result.withLock { $0 = response }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
            if Connection.peerClosed(fd) { task.cancel() }
        }
        return result.withLock { $0 }
    }
}

/// Blocking reader/writer for one socket.
private final class Connection {
    struct Parsed {
        var request: HTTPRequest
        var version: String
    }

    enum ReadError: Error { case tooLarge }

    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    /// Whether the client has closed its side: readable with nothing to read, or an error. Pipelined bytes of a next
    /// request mean it is still there.
    static func peerClosed(_ fd: Int32) -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&entry, 1, 0) > 0 else { return false }
        if entry.revents & Int16(POLLHUP | POLLERR) != 0 { return true }
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    /// `started` runs once the first byte of the request is here (at once for a pipelined one).
    func readRequest(maxBody: Int, started: () -> Void = {}) throws -> Parsed? {
        if !buffer.isEmpty { started() }
        // Head: up to the blank line.
        var headEnd: Range<Data.Index>?
        while true {
            if let r = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) { headEnd = r; break }
            let wasEmpty = buffer.isEmpty
            guard buffer.count < 64 << 10, fill() else { return nil }
            if wasEmpty { started() }
        }
        guard let headEnd else { return nil }
        let headData = buffer.subdata(in: buffer.startIndex..<headEnd.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<headEnd.upperBound)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = requestLine[1]
        let (path, query) = Self.splitTarget(target)

        if headers["expect"]?.lowercased() == "100-continue" { _ = writeRaw(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
        var body = Data()
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try readChunkedBody(maxBody: maxBody)
        } else if let lengthText = headers["content-length"], let length = Int(lengthText) {
            guard length <= maxBody else { throw ReadError.tooLarge }
            while buffer.count < length { guard fill() else { return nil } }
            body = buffer.prefix(length)
            buffer.removeFirst(length)
        }
        return Parsed(
            request: HTTPRequest(method: requestLine[0].uppercased(), path: path, query: query, headers: headers, body: body),
            version: requestLine.count > 2 ? requestLine[2] : "HTTP/1.1")
    }

    private func readChunkedBody(maxBody: Int) throws -> Data {
        var body = Data()
        while true {
            var lineEnd: Range<Data.Index>?
            while true {
                if let r = buffer.range(of: Data([0x0D, 0x0A])) { lineEnd = r; break }
                guard fill() else { return body }
            }
            guard let lineEnd else { return body }
            let sizeText = String(decoding: buffer.subdata(in: buffer.startIndex..<lineEnd.lowerBound), as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
            guard let size = Int(sizeText.split(separator: ";").first ?? "", radix: 16) else { return body }
            if size == 0 {
                while buffer.range(of: Data([0x0D, 0x0A])) == nil { guard fill() else { break } }
                if let r = buffer.range(of: Data([0x0D, 0x0A])) { buffer.removeSubrange(buffer.startIndex..<r.upperBound) }
                return body
            }
            while buffer.count < size + 2 { guard fill() else { return body } }
            body.append(buffer.prefix(size))
            buffer.removeFirst(size + 2)
            guard body.count <= maxBody else { throw ReadError.tooLarge }
        }
    }

    static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        var query: [String: String] = [:]
        for pair in target[target.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            query[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return (String(target[..<q]), query)
    }

    /// Returns false when the client went away (streams stop generating through stream termination).
    func write(_ response: HTTPResponse, isHead: Bool) -> Bool {
        var headers = response.headers
        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reasons[response.status] ?? "OK")\r\n"
        switch response.body {
        case .data(let data):
            headers["Content-Length"] = String(data.count)
            for (k, v) in headers { head += "\(k): \(v)\r\n" }
            head += "\r\n"
            guard writeRaw(Data(head.utf8)) else { return false }
            return isHead || data.isEmpty ? true : writeRaw(data)
        case .stream(let stream):
            headers["Transfer-Encoding"] = "chunked"
            headers["Cache-Control"] = headers["Cache-Control"] ?? "no-cache"
            for (k, v) in headers { head += "\(k): \(v)\r\n" }
            head += "\r\n"
            guard writeRaw(Data(head.utf8)) else { return false }
            if isHead { return true }
            // This thread does every send(); the producer task only generates and never blocks the pool.
            let queue = ChunkQueue()
            let producer = Task.detached {
                do {
                    for try await chunk in stream where !chunk.isEmpty {
                        guard await queue.push(chunk) else { return }
                    }
                    queue.finish()
                } catch {
                    queue.fail()
                }
            }
            let fd = self.fd
            while true {
                switch queue.pop() {
                case .chunk(let data):
                    guard Connection.writeChunk(fd, data) else {
                        queue.cancel()
                        producer.cancel()
                        return false
                    }
                case .finished:
                    return Connection.writeRaw(fd, Data("0\r\n\r\n".utf8))
                case .failed:
                    return false
                }
            }
        }
    }

    /// Bounded hand-off between the async producer and the connection thread. The consumer blocks on a
    /// condition (its own thread); the producer suspends with a short backoff when the queue is full.
    final class ChunkQueue: @unchecked Sendable {
        enum Next {
            case chunk(Data)
            case finished
            case failed
        }

        private let condition = NSCondition()
        private var chunks: [Data] = []
        private var finished = false
        private var failed = false
        private var cancelled = false
        private let capacity = 64

        private enum PushAttempt {
            case pushed, cancelled, full
        }

        /// False once the consumer cancelled: the producer must stop generating.
        func push(_ data: Data) async -> Bool {
            while true {
                switch tryPush(data) {
                case .pushed: return true
                case .cancelled: return false
                case .full:
                    try? await Task.sleep(for: .milliseconds(20))
                    if Task.isCancelled { return false }
                }
            }
        }

        // Locking lives in a synchronous helper: NSCondition.lock is unavailable in async contexts.
        private func tryPush(_ data: Data) -> PushAttempt {
            condition.lock()
            defer { condition.unlock() }
            if cancelled { return .cancelled }
            guard chunks.count < capacity else { return .full }
            chunks.append(data)
            condition.signal()
            return .pushed
        }

        func finish() { end { $0.finished = true } }
        func fail() { end { $0.failed = true } }
        func cancel() { end { $0.cancelled = true } }

        private func end(_ mark: (ChunkQueue) -> Void) {
            condition.lock()
            mark(self)
            condition.broadcast()
            condition.unlock()
        }

        func pop() -> Next {
            condition.lock()
            defer { condition.unlock() }
            // A producer that stalls without finishing must not park this connection thread forever.
            let deadline = Date(timeIntervalSinceNow: 600)
            while chunks.isEmpty, !finished, !failed, !cancelled {
                if !condition.wait(until: deadline) {
                    cancelled = true
                    return .failed
                }
            }
            if !chunks.isEmpty {
                let first = chunks.removeFirst()
                return .chunk(first)
            }
            return failed || cancelled ? .failed : .finished
        }
    }

    private static func writeChunk(_ fd: Int32, _ chunk: Data) -> Bool {
        var frame = Data(String(chunk.count, radix: 16).utf8)
        frame.append(contentsOf: [0x0D, 0x0A])
        frame.append(chunk)
        frame.append(contentsOf: [0x0D, 0x0A])
        return writeRaw(fd, frame)
    }

    private func writeRaw(_ data: Data) -> Bool { Self.writeRaw(fd, data) }

    private static func writeRaw(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                return send(fd, raw.baseAddress! + offset, data.count - offset, 0)
            }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
