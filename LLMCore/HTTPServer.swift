//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Synchronization

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
        try JSONDecoder().decode(type, from: body)
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
        200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
        500: "Internal Server Error", 501: "Not Implemented", 503: "Service Unavailable",
    ]
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

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func route(_ method: String, _ path: String, _ handler: @escaping HTTPHandler) {
        routes.withLock { $0["\(method.uppercased()) \(path)"] = handler }
    }

    public func setNotFound(_ handler: @escaping HTTPHandler) { notFound.withLock { $0 = handler } }

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

    private func acceptLoop(_ fd: Int32) {
        while running.withLock({ $0 }) {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            guard client >= 0 else { if errno == EINTR { continue } else { break } }
            var timeout = timeval()
            timeout.tv_sec = numericCast(configuration.keepAliveTimeoutSeconds)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [self] in serve(client) }
            thread.name = "HTTPServer.connection"
            thread.start()
        }
    }

    // Connection

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        let connection = Connection(fd: fd)
        while running.withLock({ $0 }) {
            guard let request = try? connection.readRequest(maxBody: configuration.maxBodyBytes) else { return }
            let wantsClose = request.request.headers["connection"]?.lowercased() == "close" || request.version == "HTTP/1.0"
            var response = handle(request.request)
            var headers = response.headers
            headers["Server"] = configuration.serverName
            headers["Access-Control-Allow-Origin"] = "*"
            headers["Connection"] = wantsClose ? "close" : "keep-alive"
            response.headers = headers
            let ok = connection.write(response, isHead: request.request.method == "HEAD")
            if !ok || wantsClose { return }
        }
    }

    /// Runs the async handler on a cooperative task and blocks this connection thread until it returns.
    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        if request.method == "OPTIONS" {
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
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.set(try await handler(request)) } catch {
                box.set(mapper?(error) ?? HTTPResponse.text("{\"error\":\"\(error)\"}", status: 500, contentType: "application/json"))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()
    }
}

private final class ResultBox: @unchecked Sendable {
    private var value = HTTPResponse(status: 500)
    func set(_ v: HTTPResponse) { value = v }
    func get() -> HTTPResponse { value }
}

/// Blocking reader/writer for one socket.
private final class Connection {
    struct Parsed {
        var request: HTTPRequest
        var version: String
    }

    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    func readRequest(maxBody: Int) throws -> Parsed? {
        // Head: up to the blank line.
        var headEnd: Range<Data.Index>?
        while true {
            if let r = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) { headEnd = r; break }
            guard buffer.count < 64 << 10, fill() else { return nil }
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
            guard length <= maxBody else { return nil }
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
            guard body.count <= maxBody else { return body }
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
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultFlag()
            let fd = self.fd
            Task.detached {
                var alive = true
                do {
                    for try await chunk in stream where !chunk.isEmpty {
                        guard Connection.writeChunk(fd, chunk) else { alive = false; break }
                    }
                } catch {
                    alive = false
                }
                if alive { alive = Connection.writeRaw(fd, Data("0\r\n\r\n".utf8)) }
                result.value = alive
                semaphore.signal()
            }
            semaphore.wait()
            return result.value
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

private final class ResultFlag: @unchecked Sendable {
    var value = false
}
