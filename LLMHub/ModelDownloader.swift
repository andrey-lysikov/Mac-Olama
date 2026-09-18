//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

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

/// Downloads a repo into `models/<org>--<repo>/` with Range resume, sha256 checks and a `manifest.json`.
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
    private let ollama: OllamaRegistryClient
    private let paths: AppPaths
    private let options: Options
    private let session: URLSession
    private var activeTasks: [String: Task<Void, Never>] = [:]

    public init(
        client: HubClient, ollama: OllamaRegistryClient = .init(), paths: AppPaths, options: Options = .init(),
        session: URLSession = .shared
    ) {
        self.client = client
        self.ollama = ollama
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
    public func download(_ reference: ModelReference, revision: String = "main") -> AsyncThrowingStream<DownloadEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DownloadEvent.self)
        let repoID = reference.repoID
        if activeTasks[repoID] != nil {
            continuation.finish(throwing: EngineError.busy)
            return stream
        }
        let task = Task { [self] in
            do {
                switch reference {
                case .huggingFace(let id): try await self.run(repoID: id, revision: revision, continuation: continuation)
                case .ollama(let name, let tag): try await self.runOllama(name: name, tag: tag, continuation: continuation)
                }
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

    private func run(repoID: String, revision: String, continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation) async throws {
        let info = try await client.info(repoID: repoID)
        let files = info.siblings.filter { !Self.isExcluded($0.rfilename, patterns: options.excludedPatterns) }
        let totalBytes = files.reduce(0) { $0 + $1.byteSize }
        continuation.yield(.resolved(.init(files: files.count, bytes: totalBytes)))

        let dirName = ModelDescriptor.directoryName(forRepo: repoID)
        let stagingDir = paths.downloads.appendingPathComponent(dirName, isDirectory: true)
        let finalDir = paths.models.appendingPathComponent(dirName, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        try checkDiskSpace(required: totalBytes, at: paths.root)

        var receivedBefore: Int64 = 0
        var manifestFiles: [ModelManifest.FileEntry] = []
        let start = ContinuousClock.now
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let dest = stagingDir.appendingPathComponent(file.rfilename)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = receivedBefore
            let fileName = file.rfilename
            try await downloadFile(
                url: client.fileURL(repoID: repoID, path: fileName, revision: revision),
                to: dest, expectedSize: file.byteSize
            ) { received in
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
                guard actual == expected else { throw HubError.checksumMismatch(file: fileName) }
            }
            receivedBefore += file.byteSize
            manifestFiles.append(.init(path: fileName, sizeBytes: file.byteSize, sha256: file.sha256))
            continuation.yield(.fileFinished(fileName))
        }

        // classify from the downloaded config.json
        let configData = (try? Data(contentsOf: stagingDir.appendingPathComponent("config.json"))) ?? Data()
        let cls = HubModelClassification.classify(configJSON: configData)
        let manifest = ModelManifest(
            repoID: repoID, revision: info.sha ?? revision, source: .huggingFace, kind: cls.kind, files: manifestFiles,
            contextLength: cls.contextLength, quantization: cls.quantization,
            supportsTools: ModelManifest.templateSupportsTools(in: stagingDir), architectures: cls.architectures
        )
        try manifest.save(to: stagingDir)

        if fm.fileExists(atPath: finalDir.path) { try fm.removeItem(at: finalDir) }
        try fm.createDirectory(at: paths.models, withIntermediateDirectories: true)
        try fm.moveItem(at: stagingDir, to: finalDir)
        continuation.yield(.finished(manifest.descriptor(directory: finalDir)))
    }

    /// Ollama registry: JSON layers become files, tensor blobs are merged into safetensors shards (≤ 1 GB each).
    /// Blobs are content-addressed, so a restart only re-fetches blobs that are missing or truncated.
    private func runOllama(name: String, tag: String, continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation) async throws {
        let repoID = "\(name):\(tag)"
        let manifest = try await ollama.manifest(name: name, tag: tag)
        guard manifest.isSafetensors else { throw HubError.badURL("\(repoID) is not an MLX/safetensors tag") }
        let totalBytes = manifest.totalBytes
        continuation.yield(.resolved(.init(files: manifest.layers.count, bytes: totalBytes)))

        let reference = ModelReference.ollama(name: name, tag: tag)
        let stagingDir = paths.downloads.appendingPathComponent(reference.directoryName, isDirectory: true)
        let blobDir = stagingDir.appendingPathComponent("blobs", isDirectory: true)
        let finalDir = paths.models.appendingPathComponent(reference.directoryName, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: blobDir, withIntermediateDirectories: true)
        try checkDiskSpace(required: totalBytes * 2, at: paths.root)  // blobs + merged shards coexist briefly

        var received: Int64 = 0
        let start = ContinuousClock.now
        let layerCount = manifest.layers.count
        let emit: @Sendable (String, Int, Int64) -> Void = { file, index, bytes in
            let elapsed = start.duration(to: .now)
            let secs = max(0.001, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            continuation.yield(
                .progress(
                    DownloadProgress(
                        repoID: repoID, currentFile: file, fileIndex: index, fileCount: layerCount,
                        bytesReceived: bytes, bytesTotal: totalBytes, bytesPerSecond: Double(bytes) / secs)))
        }

        // JSON layers (config.json, tokenizer.json, …) straight into the staging folder; skip draft/* (speculative decoding).
        var manifestFiles: [ModelManifest.FileEntry] = []
        var index = 0
        for layer in manifest.jsonLayers {
            index += 1
            guard let fileName = layer.name, !fileName.hasPrefix("draft/") else { received += layer.size; continue }
            let dest = stagingDir.appendingPathComponent(fileName)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (base, idx) = (received, index)
            try await downloadFile(url: ollama.blobURL(name: name, digest: layer.digest), to: dest, expectedSize: layer.size) { got in
                emit(fileName, idx, base + got)
            }
            received += layer.size
            manifestFiles.append(.init(path: fileName, sizeBytes: layer.size, sha256: String(layer.digest.dropFirst("sha256:".count))))
            continuation.yield(.fileFinished(fileName))
        }

        // Tensor blobs → shards.
        var shard: [SafetensorsMerger.Entry] = []
        var shardBytes: Int64 = 0
        var shardIndex = 0
        var shardFiles: [URL] = []
        var quantTypes = Set<String>()
        let shardLimit: Int64 = 1024 * 1024 * 1024
        func flush() throws {
            guard !shard.isEmpty else { return }
            shardIndex += 1
            let url = stagingDir.appendingPathComponent(String(format: "model-%05d.safetensors", shardIndex))
            try SafetensorsMerger.write(shard, to: url)
            shardFiles.append(url)
            shard.removeAll(); shardBytes = 0
        }
        for layer in manifest.tensorLayers {
            try Task.checkCancellation()
            index += 1
            guard let tensorName = layer.name, !tensorName.hasPrefix("draft.") else { received += layer.size; continue }
            let blob = blobDir.appendingPathComponent(String(layer.digest.dropFirst("sha256:".count)))
            let (base, idx) = (received, index)
            try await downloadFile(url: ollama.blobURL(name: name, digest: layer.digest), to: blob, expectedSize: layer.size) { got in
                emit(tensorName, idx, base + got)
            }
            received += layer.size
            let parsed = try SafetensorsMerger.parse(try Data(contentsOf: blob), fallbackName: tensorName)
            if let q = parsed.quantType { quantTypes.insert(q) }
            for entry in parsed.entries {
                shard.append(entry)
                shardBytes += Int64(entry.data.count)
            }
            if shardBytes >= shardLimit { try flush() }
        }
        try flush()
        for url in shardFiles {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            manifestFiles.append(.init(path: url.lastPathComponent, sizeBytes: size, sha256: nil))
            continuation.yield(.fileFinished(url.lastPathComponent))
        }
        try? fm.removeItem(at: blobDir)

        // One quant scheme per model is assumed (Ollama converts uniformly); mixed schemes are rejected.
        let configURL = stagingDir.appendingPathComponent("config.json")
        var quantLabel: String?
        if let type = quantTypes.first {
            guard quantTypes.count == 1, let scheme = OllamaQuantScheme(quantType: type) else {
                throw HubError.badURL("\(repoID): unsupported quantization \(quantTypes.sorted().joined(separator: ","))")
            }
            try SafetensorsMerger.patchConfig(at: configURL, scheme: scheme)
            quantLabel = "\(scheme.bits)-bit \(scheme.mode)"
            if scheme.needsConversion {
                try JSONCoding.encoder.encode(scheme).write(
                    to: stagingDir.appendingPathComponent(OllamaQuantScheme.conversionMarker), options: .atomic)
            }
        }
        try? fm.removeItem(at: stagingDir.appendingPathComponent("hf_quant_config.json"))
        let configData = (try? Data(contentsOf: configURL)) ?? Data()
        let cls = HubModelClassification.classify(configJSON: configData)
        let manifestFile = ModelManifest(
            repoID: repoID, revision: manifest.digest, source: .ollama, kind: cls.kind, files: manifestFiles,
            contextLength: cls.contextLength, quantization: quantLabel ?? cls.quantization,
            supportsTools: ModelManifest.templateSupportsTools(in: stagingDir), architectures: cls.architectures)
        try manifestFile.save(to: stagingDir)
        if fm.fileExists(atPath: finalDir.path) { try fm.removeItem(at: finalDir) }
        try fm.createDirectory(at: paths.models, withIntermediateDirectories: true)
        try fm.moveItem(at: stagingDir, to: finalDir)
        continuation.yield(.finished(manifestFile.descriptor(directory: finalDir)))
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
        var hasher = SHA256Hasher()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.finalizeHex()
    }
}
