//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

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
    private var activeTasks: [String: Task<Void, Never>] = [:]

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
        activeTasks[repoID]?.cancel()
        activeTasks[repoID] = nil
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
        let task = Task { [self] in
            do {
                try await self.run(reference, revision: revision, destination: destination, continuation: continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: HubError.cancelled)
            } catch {
                continuation.finish(throwing: error)
            }
            self.clearTask(repoID: repoID)
        }
        activeTasks[repoID] = task
        continuation.onTermination = { t in if case .cancelled = t { task.cancel() } }
        return stream
    }

    private func clearTask(repoID: String) { activeTasks[repoID] = nil }

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

        var receivedBefore: Int64 = 0
        var manifestFiles: [ModelManifest.FileEntry] = []
        let start = ContinuousClock.now
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let dest = stagingDir.appendingPathComponent(file.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = receivedBefore
            let fileName = file.path
            try await downloadFile(url: listing.url(fileName), to: dest, expectedSize: file.size) { received in
                let elapsed = start.duration(to: .now)
                let secs = max(0.001, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                continuation.yield(
                    .progress(
                        DownloadProgress(
                            repoID: repoID, currentFile: fileName, fileIndex: index + 1, fileCount: files.count,
                            bytesReceived: base + received, bytesTotal: totalBytes, bytesPerSecond: Double(base + received) / secs
                        )))
            }
            if options.verifyChecksums, let expected = file.sha256 {
                let actual = try Self.sha256Hex(of: dest)
                guard actual == expected.lowercased() else { throw HubError.checksumMismatch(file: fileName) }
            }
            receivedBefore += file.size
            manifestFiles.append(.init(path: fileName, sizeBytes: file.size, sha256: file.sha256))
            continuation.yield(.fileFinished(fileName))
        }

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

    /// Downloads one file; if a `.part` exists, resumes from its size via a Range request.
    private func downloadFile(url: URL, to dest: URL, expectedSize: Int64, progress: @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: dest.path), (attrs[.size] as? NSNumber)?.int64Value == expectedSize {
            progress(expectedSize)
            return
        }
        let part = dest.appendingPathExtension("part")
        var offset: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: part.path) {
            offset = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        if offset > expectedSize { try? fm.removeItem(at: part); offset = 0 }

        var request = url.host?.hasSuffix("huggingface.co") == true ? client.request(url) : URLRequest(url: url)
        request.setValue(nil, forHTTPHeaderField: "Accept")
        request.setValue("Mac-Olama/0.1", forHTTPHeaderField: "User-Agent")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        var received = offset
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try Self.validate(status: http.statusCode, url: url)
        if http.statusCode == 200 {
            received = 0  // server ignored Range: start over
            try? fm.removeItem(at: part)
        }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: part)
        try handle.seekToEnd()
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var lastReport = ContinuousClock.now
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if lastReport.duration(to: .now) > .milliseconds(200) {
                        progress(received)
                        lastReport = .now
                    }
                    try Task.checkCancellation()
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
            }
        } catch {
            try? handle.close()
            throw error  // keep .part for resume
        }
        try handle.close()
        progress(received)
        guard received == expectedSize else {
            throw HubError.httpStatus(-1, url: "\(url.absoluteString) (incomplete: \(received)/\(expectedSize))")
        }
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
