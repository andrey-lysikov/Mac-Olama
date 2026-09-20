//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Synchronization

public struct DownloadProgress: Sendable, Equatable {
    public var repoID: String
    public var currentFile: String
    public var fileIndex: Int
    public var fileCount: Int
    public var bytesReceived: Int64
    public var bytesTotal: Int64
    public var bytesPerSecond: Double
    public var fraction: Double { bytesTotal > 0 ? Double(bytesReceived) / Double(bytesTotal) : 0 }
}

public enum DownloadEvent: Sendable, Equatable {
    case resolved(HubModelInfo.Sibling.Count)
    case progress(DownloadProgress)
    case fileFinished(String)
    case finished(ModelDescriptor)
}

extension HubModelInfo.Sibling {
    public struct Count: Sendable, Equatable {
        public var files: Int
        public var bytes: Int64
    }
}

/// Downloads a repo (Hugging Face or ModelScope) into `models/<folder>/` with Range resume, sha256 checks and a `manifest.json`.
/// Partial files live in `downloads/<org>--<repo>/*.part` and are moved into place when complete.
public actor ModelDownloader {
    public struct Options: Sendable {
        /// Files not needed for inference; skipping them shrinks the download.
        public var excludedPatterns: [String] = [
            "*.md", ".gitattributes", "*.png", "*.jpg", "LICENSE*", "*.txt", "*.pt", "*.bin", "*.gguf",
        ]
        public var verifyChecksums = true
        public var minFreeBytesAfterDownload: Int64 = 2 * 1024 * 1024 * 1024
        public init() {}
    }

    private let client: HubClient
    private let modelScope: ModelScopeClient
    private let paths: AppPaths
    private let options: Options
    private let session: URLSession
    private let throttle = DownloadThrottle()
    private var maxConcurrentFiles = 2
    private var activeTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Cancelled tasks that may still be writing their .part; a restart waits for them first.
    private var draining: [String: Task<Void, Never>] = [:]

    /// 0 = unlimited. Applies to chunks in flight, so a running download slows within a second.
    public func setSpeedLimit(bytesPerSecond: Int64) async {
        await throttle.setLimit(bytesPerSecond)
    }

    public func setMaxConcurrentFiles(_ count: Int) {
        maxConcurrentFiles = min(max(count, 1), 4)
    }

    public init(
        client: HubClient, modelScope: ModelScopeClient = .init(), paths: AppPaths, options: Options = .init(),
        session: URLSession = .shared
    ) {
        self.client = client
        self.modelScope = modelScope
        self.paths = paths
        self.options = options
        self.session = session
    }

    public func cancel(repoID: String) {
        guard let entry = activeTasks.removeValue(forKey: repoID) else { return }
        entry.task.cancel()
        draining[repoID] = entry.task
    }

    /// Convenience for Hugging Face repos.
    public func download(repoID: String, revision: String = "main") -> AsyncThrowingStream<DownloadEvent, Error> {
        download(.huggingFace(repoID: repoID), revision: revision)
    }

    /// Starts a download and streams events. A second call for the same reference fails the stream with `busy`.
    /// `into` installs the files somewhere other than `models/<repo>` — an MTP drafter goes inside its model's folder.
    public func download(
        _ reference: ModelReference, revision: String = "main", into destination: URL? = nil
    )
        -> AsyncThrowingStream<DownloadEvent, Error>
    {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DownloadEvent.self)
        let repoID = reference.repoID
        if activeTasks[repoID] != nil {
            continuation.finish(throwing: EngineError.busy)
            return stream
        }
        let id = UUID()
        let task = Task { [self] in
            // A just-cancelled predecessor may still hold the .part files open: wait it out first.
            if let previous = self.takeDraining(repoID: repoID) { await previous.value }
            do {
                try await self.run(reference, revision: revision, destination: destination, continuation: continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: HubError.cancelled)
            } catch {
                continuation.finish(throwing: error)
            }
            self.clearTask(repoID: repoID, id: id)
        }
        activeTasks[repoID] = (id, task)
        continuation.onTermination = { t in if case .cancelled = t { task.cancel() } }
        return stream
    }

    private func takeDraining(repoID: String) -> Task<Void, Never>? {
        draining.removeValue(forKey: repoID)
    }

    /// Clears only this download's slot: a cancelled predecessor must not evict its replacement.
    private func clearTask(repoID: String, id: UUID) {
        if activeTasks[repoID]?.id == id { activeTasks[repoID] = nil }
        if draining[repoID] != nil, activeTasks[repoID] == nil { draining[repoID] = nil }
    }

    /// What a hub reports before the transfer: the files, the revision stored for update checks, the base model.
    private struct Listing {
        var files: [RepoFile]
        var revision: String
        var baseModel: String?
        var url: @Sendable (String) -> URL
    }

    private func listing(for reference: ModelReference, revision: String) async throws -> Listing {
        switch reference {
        case .huggingFace(let id):
            let info = try await client.info(repoID: id)
            let client = client
            return Listing(
                files: info.siblings.map { RepoFile(path: $0.rfilename, size: $0.byteSize, sha256: $0.sha256) },
                revision: info.sha ?? revision, baseModel: ModelOwners.baseModel(fromTags: info.tags ?? []),
                url: { client.fileURL(repoID: id, path: $0, revision: revision) })
        case .modelScope(let id):
            async let files = modelScope.files(repoID: id)
            async let info = modelScope.info(repoID: id)
            let details = try? await info
            let modelScope = modelScope
            // ModelScope has no commit id in its model API; the last update time serves as the revision for update checks.
            return Listing(
                files: try await files, revision: details?.lastUpdated.map { String(Int($0.timeIntervalSince1970)) } ?? "master",
                baseModel: details?.baseModel, url: { modelScope.fileURL(repoID: id, path: $0) })
        }
    }

    private func run(
        _ reference: ModelReference, revision: String, destination: URL?,
        continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation
    ) async throws {
        let repoID = reference.repoID
        let listing = try await listing(for: reference, revision: revision)
        let files = listing.files.filter { !Self.isExcluded($0.path, patterns: options.excludedPatterns) }
        let totalBytes = files.reduce(0) { $0 + $1.size }
        continuation.yield(.resolved(.init(files: files.count, bytes: totalBytes)))

        let dirName = reference.directoryName
        let stagingDir = paths.downloads.appendingPathComponent(dirName, isDirectory: true)
        let finalDir = destination ?? paths.models.appendingPathComponent(dirName, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        try checkDiskSpace(required: totalBytes, at: paths.root)

        let reporter = DownloadProgressReporter(repoID: repoID, fileCount: files.count, totalBytes: totalBytes) { progress in
            continuation.yield(.progress(progress))
        }
        var slots: [ModelManifest.FileEntry?] = Array(repeating: nil, count: files.count)
        let width = maxConcurrentFiles
        try await withThrowingTaskGroup(of: (Int, ModelManifest.FileEntry).self) { group in
            var iterator = files.enumerated().makeIterator()
            @discardableResult func addNext() -> Bool {
                guard let (index, file) = iterator.next() else { return false }
                let url = listing.url(file.path)
                group.addTask { try await self.fetchOne(file, at: index, url: url, stagingDir: stagingDir, reporter: reporter) }
                return true
            }
            for _ in 0..<width { addNext() }
            while let (index, entry) = try await group.next() {
                slots[index] = entry
                continuation.yield(.fileFinished(entry.path))
                addNext()
            }
        }
        let manifestFiles = slots.compactMap { $0 }

        // classify from the downloaded config.json
        let configData = (try? Data(contentsOf: stagingDir.appendingPathComponent("config.json"))) ?? Data()
        let cls = HubModelClassification.classify(configJSON: configData)
        let manifest = ModelManifest(
            repoID: repoID, revision: listing.revision, source: reference.source, kind: cls.kind, files: manifestFiles,
            contextLength: cls.contextLength, quantization: cls.quantization,
            supportsTools: ModelManifest.templateSupportsTools(in: stagingDir), architectures: cls.architectures,
            baseModel: listing.baseModel
        )
        try manifest.save(to: stagingDir)

        if fm.fileExists(atPath: finalDir.path) { try fm.removeItem(at: finalDir) }
        try fm.createDirectory(at: finalDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: stagingDir, to: finalDir)
        continuation.yield(.finished(manifest.descriptor(directory: finalDir)))
    }

    /// One file end to end, off the actor: network, disk and hashing must not serialize behind actor calls.
    private nonisolated func fetchOne(
        _ file: RepoFile, at index: Int, url: URL, stagingDir: URL, reporter: DownloadProgressReporter
    ) async throws -> (Int, ModelManifest.FileEntry) {
        let dest = try Self.safeDestination(for: file.path, under: stagingDir)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await downloadFile(url: url, to: dest, expectedSize: file.size, path: file.path, reporter: reporter)
        if options.verifyChecksums, let expected = file.sha256 {
            let actual = try Self.sha256Hex(of: dest)
            guard actual == expected.lowercased() else {
                // A corrupt file left in place would pass the size check and defeat every retry.
                try? FileManager.default.removeItem(at: dest)
                throw HubError.checksumMismatch(file: file.path)
            }
        }
        reporter.finished(file.path, bytes: file.size)
        return (index, .init(path: file.path, sizeBytes: file.size, sha256: file.sha256))
    }

    /// Downloads one file; if a `.part` exists, resumes from its size via a Range request.
    /// A size of 0 means "unknown": whatever arrives is accepted and an existing empty file is not trusted.
    private nonisolated func downloadFile(
        url: URL, to dest: URL, expectedSize: Int64, path: String, reporter: DownloadProgressReporter, retryOn416: Bool = true
    ) async throws {
        let fm = FileManager.default
        if expectedSize > 0, let attrs = try? fm.attributesOfItem(atPath: dest.path),
            (attrs[.size] as? NSNumber)?.int64Value == expectedSize
        {
            return
        }
        let part = dest.appendingPathExtension("part")
        var offset: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: part.path) {
            offset = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        if offset > expectedSize { try? fm.removeItem(at: part); offset = 0 }
        if expectedSize > 0, offset == expectedSize {
            // Fully staged before a crash: finish locally instead of sending a range the server answers with 416.
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.moveItem(at: part, to: dest)
            return
        }

        var request = url.host?.hasSuffix("huggingface.co") == true ? client.request(url) : URLRequest(url: url)
        request.setValue(nil, forHTTPHeaderField: "Accept")
        request.setValue("Mac-Olama/0.1", forHTTPHeaderField: "User-Agent")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        let (http, body, bridge) = try await ChunkedResponse.begin(request, on: session)
        if http.statusCode == 416 {
            // The .part no longer matches what the server has: drop it and start over once.
            try? fm.removeItem(at: part)
            guard retryOn416 else { throw HubError.httpStatus(416, url: url.absoluteString) }
            return try await downloadFile(
                url: url, to: dest, expectedSize: expectedSize, path: path, reporter: reporter, retryOn416: false)
        }
        try Self.validate(status: http.statusCode, url: url)
        var received = offset
        if http.statusCode == 200, offset > 0 {
            received = 0  // server ignored Range: start over
            try? fm.removeItem(at: part)
        }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: part)
        try handle.seekToEnd()
        reporter.started(path, resumedFrom: received)
        do {
            for try await chunk in body {
                try handle.write(contentsOf: chunk)
                received += Int64(chunk.count)
                reporter.received(path, total: received, delta: chunk.count)
                bridge.consumed(chunk.count)
                await throttle.consume(chunk.count)
                try Task.checkCancellation()
            }
            // A cancelled iterator ends with nil, not a throw: report "cancelled", not "incomplete".
            try Task.checkCancellation()
        } catch {
            try? handle.close()
            throw error  // keep .part for resume
        }
        try handle.close()
        if expectedSize > 0, received != expectedSize {
            throw HubError.httpStatus(-1, url: "\(url.absoluteString) (incomplete: \(received)/\(expectedSize))")
        }
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        try fm.moveItem(at: part, to: dest)
    }

    static func validate(status: Int, url: URL) throws {
        switch status {
        case 200, 206: return
        case 401, 403: throw HubError.gatedRepositoryRequiresToken(url.path)
        case 404: throw HubError.notFound(url.path)
        default: throw HubError.httpStatus(status, url: url.absoluteString)
        }
    }

    private func checkDiskSpace(required: Int64, at url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
        if available > 0, available < required + options.minFreeBytesAfterDownload {
            throw HubError.insufficientDiskSpace(requiredBytes: required, availableBytes: available)
        }
    }

    /// Maps an untrusted hub listing path to a location inside `dir`; rejects absolute paths,
    /// `~`, `.`/`..` components and anything resolving outside `dir`.
    static func safeDestination(for path: String, under dir: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { throw HubError.unsafePath(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, components.allSatisfy({ $0 != ".." && $0 != "." }) else {
            throw HubError.unsafePath(path)
        }
        var dest = dir
        for component in components { dest.appendPathComponent(String(component)) }
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = dest.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base + "/") else { throw HubError.unsafePath(path) }
        return dest
    }

    static func isExcluded(_ name: String, patterns: [String]) -> Bool {
        let file = name.split(separator: "/").last.map(String.init) ?? name
        return patterns.contains { pattern in
            if pattern.hasPrefix("*") { return file.hasSuffix(String(pattern.dropFirst())) }
            if pattern.hasSuffix("*") { return file.hasPrefix(String(pattern.dropLast())) }
            return file == pattern
        }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()  // streamed: weight files are far too large to read whole
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hex
    }
}

// Transfer plumbing

/// Delivers a response body as Data chunks via delegate callbacks; `URLSession.AsyncBytes` hands out
/// single bytes and burns a CPU core on multi-gigabyte files.
enum ChunkedResponse {
    static func begin(
        _ request: URLRequest, on session: URLSession
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>, Bridge) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let bridge = Bridge(continuation: continuation)
        let task = session.dataTask(with: request)
        task.delegate = bridge
        bridge.task = task
        continuation.onTermination = { t in if case .cancelled = t { task.cancel() } }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPURLResponse, Error>) in
                bridge.armResponse(c)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (response, stream, bridge)
    }

    final class Bridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        // The slot survives a completion that races the arm (a task cancelled before begin() ran).
        private enum Slot {
            case idle
            case armed(CheckedContinuation<HTTPURLResponse, Error>)
            case finished(Result<HTTPURLResponse, Error>)
        }

        // Backpressure: the consumer acknowledges written bytes; past the high-water mark the task suspends.
        static let highWater = 8 << 20
        static let lowWater = 2 << 20

        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        private let slot = Mutex<Slot>(.idle)
        private let buffered = Mutex((bytes: 0, suspended: false))
        weak var task: URLSessionDataTask?

        init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            self.continuation = continuation
        }

        func armResponse(_ c: CheckedContinuation<HTTPURLResponse, Error>) {
            let ready: Result<HTTPURLResponse, Error>? = slot.withLock { s -> Result<HTTPURLResponse, Error>? in
                if case .finished(let result) = s { return result }
                s = .armed(c)
                return nil
            }
            if let ready { c.resume(with: ready) }
        }

        private func deliver(_ result: Result<HTTPURLResponse, Error>) {
            let armed: CheckedContinuation<HTTPURLResponse, Error>? = slot.withLock { s in
                switch s {
                case .armed(let c):
                    s = .finished(result)
                    return c
                case .idle:
                    s = .finished(result)
                    return nil
                case .finished:
                    return nil
                }
            }
            armed?.resume(with: result)
        }

        /// The consumer wrote this chunk to disk; refill the window and wake the transfer if it was paused.
        func consumed(_ count: Int) {
            let resume: Bool = buffered.withLock { b in
                b.bytes -= count
                if b.suspended, b.bytes < Self.lowWater {
                    b.suspended = false
                    return true
                }
                return false
            }
            if resume { task?.resume() }
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                deliver(.failure(URLError(.badServerResponse)))
                completionHandler(.cancel)
                return
            }
            deliver(.success(http))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(data)
            let pause: Bool = buffered.withLock { b in
                b.bytes += data.count
                if !b.suspended, b.bytes > Self.highWater {
                    b.suspended = true
                    return true
                }
                return false
            }
            if pause { dataTask.suspend() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            deliver(.failure(error ?? URLError(.badServerResponse)))
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
}

/// Token bucket shared by all files of all downloads; `consume` suspends until the chunk fits the rate.
actor DownloadThrottle {
    private var limit: Int64 = 0
    private var available = 0.0
    private var last = ContinuousClock.now

    func setLimit(_ bytesPerSecond: Int64) {
        limit = max(0, bytesPerSecond)
        available = 0  // fresh start: no debt from the old rate, no burst either
        last = .now
    }

    func consume(_ bytes: Int) async {
        guard limit > 0 else { return }
        refill()
        available -= Double(bytes)
        // Re-check the limit each turn: switching to unlimited mid-wait must release the waiters.
        while available < 0, limit > 0, !Task.isCancelled {
            let wait = min(-available / Double(limit), 0.5)
            try? await Task.sleep(for: .seconds(wait))
            refill()
        }
    }

    private func refill() {
        let now = ContinuousClock.now
        available = min(Double(limit), available + Double(limit) * last.duration(to: now).downloaderSeconds)
        last = now
    }
}

/// Aggregates per-file progress of concurrent transfers. Speed is a sliding five-second window over
/// this session's bytes, so resumed and already-present files do not inflate it.
final class DownloadProgressReporter: Sendable {
    private struct State {
        var perFile: [String: Int64] = [:]
        var completedBytes: Int64 = 0
        var finishedFiles = 0
        var currentFile = ""
        var sessionBytes: Int64 = 0
        var samples: [(at: ContinuousClock.Instant, bytes: Int64)] = []
        var lastEmit: ContinuousClock.Instant?
    }

    private let state = Mutex(State())
    private let repoID: String
    private let fileCount: Int
    private let totalBytes: Int64
    private let emit: @Sendable (DownloadProgress) -> Void

    init(repoID: String, fileCount: Int, totalBytes: Int64, emit: @escaping @Sendable (DownloadProgress) -> Void) {
        self.repoID = repoID
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.emit = emit
    }

    func started(_ path: String, resumedFrom bytes: Int64) {
        update(force: true) { s in
            s.perFile[path] = bytes
            s.currentFile = path
        }
    }

    func received(_ path: String, total: Int64, delta: Int) {
        update { s in
            s.perFile[path] = total
            s.currentFile = path
            s.sessionBytes += Int64(delta)
        }
    }

    func finished(_ path: String, bytes: Int64) {
        update(force: true) { s in
            s.perFile[path] = nil
            s.completedBytes += bytes
            s.finishedFiles += 1
        }
    }

    private func update(force: Bool = false, _ mutate: (inout State) -> Void) {
        let progress: DownloadProgress? = state.withLock { s in
            mutate(&s)
            let now = ContinuousClock.now
            s.samples.append((at: now, bytes: s.sessionBytes))
            while s.samples.count > 1, s.samples[0].at.duration(to: now) > .seconds(5) {
                s.samples.removeFirst()
            }
            if !force, let lastEmit = s.lastEmit, lastEmit.duration(to: now) < .milliseconds(150) { return nil }
            s.lastEmit = now
            let windowSeconds = s.samples.first.map { $0.at.duration(to: now).downloaderSeconds } ?? 0
            let windowBytes = s.sessionBytes - (s.samples.first?.bytes ?? 0)
            return DownloadProgress(
                repoID: repoID, currentFile: s.currentFile,
                fileIndex: min(s.finishedFiles + (s.perFile.isEmpty ? 0 : 1), fileCount), fileCount: fileCount,
                bytesReceived: s.completedBytes + s.perFile.values.reduce(0, +), bytesTotal: totalBytes,
                bytesPerSecond: windowSeconds > 0.3 ? Double(windowBytes) / windowSeconds : 0
            )
        }
        if let progress { emit(progress) }
    }
}

extension Duration {
    /// Seconds as Double; named to avoid clashing with other helpers.
    var downloaderSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
