//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// EitherCodable

/// A JSON value that comes in one of two shapes (`false` or `"auto"`, a number or a duration string, a string or an
/// array of parts). Conformers name the cases; this supplies the try-first-then-second coding. Conformers forward the
/// `Codable` members explicitly — a `Codable` enum with associated values would otherwise compete with a synthesized
/// conformance that encodes keyed cases instead of the bare value.
public protocol EitherCodable: Codable {
    associatedtype First: Codable
    associatedtype Second: Codable
    init(first: First)
    init(second: Second)
    var first: First? { get }
    var second: Second? { get }
}

extension EitherCodable {
    /// Decodes whichever of the two shapes the payload holds.
    public static func decodeEither(from decoder: Decoder) throws -> Self {
        let c = try decoder.singleValueContainer()
        if let a = try? c.decode(First.self) { return Self(first: a) }
        return Self(second: try c.decode(Second.self))
    }

    public func encodeEither(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let first { try c.encode(first) } else if let second { try c.encode(second) }
    }
}

// ModelConfig

/// `config.json` as this app reads it. Multimodal models keep the language model's numbers inside `text_config`,
/// so lookups try that section first and fall back to the root.
struct ModelConfig {
    let root: [String: Any]
    private let text: [String: Any]

    init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.root = root
        self.text = root["text_config"] as? [String: Any] ?? root
    }

    init?(directory: URL) {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")) else { return nil }
        self.init(data: data)
    }

    func int(_ key: String) -> Int? { (text[key] as? NSNumber)?.intValue ?? (root[key] as? NSNumber)?.intValue }
    func double(_ key: String) -> Double? { (text[key] as? NSNumber)?.doubleValue ?? (root[key] as? NSNumber)?.doubleValue }
    func string(_ key: String) -> String? { text[key] as? String ?? root[key] as? String }
    func strings(_ key: String) -> [String]? { text[key] as? [String] ?? root[key] as? [String] }
}

// ModelDescriptor

/// Model kind: text-only or multimodal (accepts images).
public enum ModelKind: String, Codable, Sendable, CaseIterable {
    case llm
    case vlm
}

/// Hub a model was installed from. Drives grouping in menus.
public enum ModelSource: String, Codable, Sendable, CaseIterable {
    case huggingFace = "huggingface"
    case modelScope = "modelscope"
    /// A model served by another program over the OpenAI-compatible API (llama.cpp and others); nothing is downloaded.
    case remote = "remote"

    public var displayName: String {
        switch self {
        case .huggingFace: "Hugging Face"
        case .modelScope: "ModelScope"
        case .remote: "API"
        }
    }

    /// Hugging Face account whose avatar stands for the hub in the hub picker (the hubs have no emoji of their own).
    public var avatarOwner: String? {
        switch self {
        case .huggingFace: "huggingface"
        case .modelScope: "modelscope"
        case .remote: nil
        }
    }

    /// Mark of a model that has no avatar yet (or never gets one, like a model served over the API).
    public var symbol: String {
        switch self {
        case .huggingFace, .modelScope: "shippingbox"
        case .remote: "network"
        }
    }
}

/// Locally installed model. Source of truth is `manifest.json` in the model folder.
public struct ModelDescriptor: Codable, Sendable, Hashable, Identifiable {
    /// Stable id = folder name (`mlx-community--Qwen3-8B-4bit`).
    public var id: String
    /// Short name for UI and API (`qwen3-8b-4bit`).
    public var name: String
    /// Full Hugging Face repo id (`mlx-community/Qwen3-8B-4bit`).
    public var repoID: String
    public var source: ModelSource
    public var kind: ModelKind
    public var directory: URL
    public var sizeBytes: Int64
    public var contextLength: Int?
    public var quantization: String?
    public var supportsTools: Bool
    public var downloadedAt: Date
    /// What one token costs in the attention cache; nil when `config.json` does not say (a model served over the API).
    public var kvCache: KVCacheProfile?
    /// Repository the weights were made from (`google/gemma-4-12B-it`), as the hub declares it; nil when unknown.
    public var baseModel: String?

    public init(
        id: String, name: String, repoID: String, source: ModelSource = .huggingFace, kind: ModelKind, directory: URL,
        sizeBytes: Int64, contextLength: Int? = nil, quantization: String? = nil,
        supportsTools: Bool = false, downloadedAt: Date = .now, kvCache: KVCacheProfile? = nil, baseModel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.repoID = repoID
        self.source = source
        self.kind = kind
        self.directory = directory
        self.sizeBytes = sizeBytes
        self.contextLength = contextLength
        self.quantization = quantization
        self.supportsTools = supportsTools
        self.downloadedAt = downloadedAt
        self.kvCache = kvCache
        self.baseModel = baseModel
    }

    /// Folder name for a repo: `org/repo` → `org--repo`, `modelscope:org/repo` → `modelscope--org--repo`.
    public static func directoryName(forRepo repoID: String) -> String {
        repoID.replacingOccurrences(of: ":", with: "--").replacingOccurrences(of: "/", with: "--")
    }

    /// Who made the model (the owner of its base model) and who built this copy: the pair behind the model's icon.
    public var owners: ModelOwners { ModelOwners(repoID: repoID, baseModel: baseModel) }

    /// Short name for API/menu: last repo component, lowercased.
    public static func shortName(forRepo repoID: String) -> String {
        (repoID.split(separator: "/").last.map(String.init) ?? repoID).lowercased()
    }
}

// KVCacheProfile

/// What the model's attention cache costs per token, read from `config.json`. Layers differ: plain attention grows with
/// the context, sliding-window layers stop at their window, and linear (recurrent) layers keep a constant state.
public struct KVCacheProfile: Codable, Sendable, Equatable, Hashable {
    public var bytesPerTokenPerLayer: Int
    public var fullLayers: Int
    public var slidingLayers: Int
    public var window: Int

    public init(bytesPerTokenPerLayer: Int, fullLayers: Int, slidingLayers: Int, window: Int) {
        self.bytesPerTokenPerLayer = bytesPerTokenPerLayer
        self.fullLayers = fullLayers
        self.slidingLayers = slidingLayers
        self.window = window
    }

    public func bytes(context: Int) -> Int64 {
        let full = Int64(fullLayers) * Int64(context)
        let sliding = Int64(slidingLayers) * Int64(min(context, window))
        return (full + sliding) * Int64(bytesPerTokenPerLayer)
    }

    /// `config.json` of an MLX model: layer count, KV heads, head size, and how the layers attend.
    public static func read(configJSON data: Data) -> KVCacheProfile? {
        guard let config = ModelConfig(data: data) else { return nil }
        func int(_ key: String) -> Int? { config.int(key) }
        guard let layers = int("num_hidden_layers"), layers > 0 else { return nil }
        let heads = int("num_attention_heads")
        guard let kvHeads = int("num_key_value_heads") ?? heads, kvHeads > 0 else { return nil }
        guard let headDim = int("head_dim") ?? heads.flatMap({ h in int("hidden_size").map { $0 / max(h, 1) } }), headDim > 0 else {
            return nil
        }
        // Keys and values, in the 16-bit type MLX keeps the cache in.
        let perLayer = 2 * kvHeads * headDim * 2
        let window = int("sliding_window") ?? 0
        var full = layers
        var sliding = 0
        if let types = config.strings("layer_types") {
            full = types.filter { $0.contains("full") }.count
            sliding = window > 0 ? types.filter { $0.contains("sliding") }.count : 0
            // Linear or recurrent layers (Qwen 3.5/3.6, Mamba) hold a constant state: they are simply not counted.
            if full == 0, sliding == 0 { full = types.filter { !$0.contains("linear") && !$0.contains("mamba") }.count }
        } else if window > 0, let pattern = int("sliding_window_pattern"), pattern > 1 {
            full = max(1, layers / pattern)
            sliding = layers - full
        }
        guard full + sliding > 0 else { return nil }
        return KVCacheProfile(bytesPerTokenPerLayer: perLayer, fullLayers: full, slidingLayers: sliding, window: max(window, 1))
    }
}

// ModelManifest

/// What the checkpoint itself asks to be sampled with: `generation_config.json`, the file Hugging Face ships for
/// exactly this, and failing that `config.json`. Read from disk when needed — old manifests do not carry it.
public enum ModelDefaults {
    public static func temperature(in directory: URL) -> Double? {
        for name in ["generation_config.json", "config.json"] {
            guard let data = try? Data(contentsOf: directory.appending(path: name)), let config = ModelConfig(data: data) else {
                continue
            }
            if let value = config.double("temperature"), value >= 0 { return value }
        }
        return nil
    }
}

/// `manifest.json` in the model folder. Written by the downloader, read by the catalog.
public struct ModelManifest: Codable, Sendable, Equatable {
    public static let fileName = "manifest.json"
    public static let currentVersion = 1

    public struct FileEntry: Codable, Sendable, Equatable {
        public var path: String
        public var sizeBytes: Int64
        public var sha256: String?
        public init(path: String, sizeBytes: Int64, sha256: String? = nil) {
            self.path = path
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
        }
    }

    public var version: Int
    public var repoID: String
    public var revision: String
    /// nil in manifests written before sources existed; treated as Hugging Face.
    public var source: ModelSource?
    public var kind: ModelKind
    public var files: [FileEntry]
    public var contextLength: Int?
    public var quantization: String?
    public var supportsTools: Bool
    public var architectures: [String]
    public var downloadedAt: Date
    /// Chat template override for repos whose template breaks in swift-jinja.
    public var chatTemplateOverride: String?
    /// See `ModelDescriptor.baseModel`; filled in later for models downloaded before it existed.
    public var baseModel: String?

    public init(
        version: Int = ModelManifest.currentVersion, repoID: String, revision: String = "main", source: ModelSource? = .huggingFace,
        kind: ModelKind, files: [FileEntry], contextLength: Int? = nil, quantization: String? = nil,
        supportsTools: Bool = false, architectures: [String] = [], downloadedAt: Date = .now,
        chatTemplateOverride: String? = nil, baseModel: String? = nil
    ) {
        self.version = version
        self.repoID = repoID
        self.revision = revision
        self.source = source
        self.kind = kind
        self.files = files
        self.contextLength = contextLength
        self.quantization = quantization
        self.supportsTools = supportsTools
        self.architectures = architectures
        self.downloadedAt = downloadedAt
        self.chatTemplateOverride = chatTemplateOverride
        self.baseModel = baseModel
    }

    public var totalSizeBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    public static func load(from directory: URL) throws -> ModelManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent(fileName))
        return try JSONCoding.decoder.decode(ModelManifest.self, from: data)
    }

    public func save(to directory: URL) throws {
        let data = try JSONCoding.encoder.encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Read from the model's own `config.json` on every refresh, so models downloaded by older builds get it too.
    static func kvCache(in directory: URL) -> KVCacheProfile? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")) else { return nil }
        return KVCacheProfile.read(configJSON: data)
    }

    /// Tool calling is a property of the model's own chat template, so ask the model's files instead of a list of names:
    /// a template that mentions `tools` renders tool definitions, one that does not would silently drop them.
    public static func templateSupportsTools(in directory: URL) -> Bool {
        ["chat_template.jinja", "chat_template.json", "tokenizer_config.json"].contains { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return false }
            return String(decoding: data, as: UTF8.self).contains("tools")
        }
    }

    // `supportsTools` is re-read from the template on every catalog refresh, so manifests written by older builds stay correct.
    // A remote model has no template here: the server reported its capabilities when it was connected.
    public func descriptor(directory: URL) -> ModelDescriptor {
        let remote = source == .remote
        return ModelDescriptor(
            id: remote ? directory.lastPathComponent : ModelDescriptor.directoryName(forRepo: repoID),
            name: ModelDescriptor.shortName(forRepo: repoID),
            repoID: repoID, source: source ?? .huggingFace, kind: kind, directory: directory,
            sizeBytes: totalSizeBytes, contextLength: contextLength, quantization: quantization,
            supportsTools: remote ? supportsTools : Self.templateSupportsTools(in: directory), downloadedAt: downloadedAt,
            kvCache: remote ? nil : Self.kvCache(in: directory), baseModel: baseModel
        )
    }
}

// ModelOwners

/// The two accounts a model's icon is drawn from: the author of the base model (Google, Qwen…) and the community that
/// built this copy (mlx-community, lmstudio-community…). Both are Hugging Face account names.
public struct ModelOwners: Sendable, Hashable {
    public var author: String?
    public var community: String?

    public init(author: String?, community: String?) {
        self.author = author
        self.community = community
    }

    /// `repoID` may carry a hub prefix (`modelscope:org/repo`); a base model is `org/repo` (a path-like `org/a/b` keeps `org`).
    public init(repoID: String, baseModel: String?) {
        let repo = repoID.split(separator: ":").last.map(String.init) ?? repoID
        let owner = repo.contains("/") ? repo.split(separator: "/").first.map(String.init) : nil
        let author = baseModel.flatMap { $0.contains("/") ? $0.split(separator: "/").first.map(String.init) : nil }
        self.init(author: author ?? owner, community: author != nil && author != owner ? owner : nil)
    }

    /// Hugging Face lists the base model as tags (`base_model:google/x`, `base_model:quantized:google/x`).
    public static func baseModel(fromTags tags: [String]) -> String? {
        let values = tags.filter { $0.hasPrefix("base_model:") }.map { String($0.split(separator: ":").last ?? "") }
        return values.first { $0.contains("/") }
    }
}

// RemoteEndpoint

/// `remote.json` next to the manifest of a remote model: where the OpenAI-compatible server is and the model's name.
/// The optional token lives in the settings (`RemoteTokens`), never in this file. An older file's `api` key is ignored.
public struct RemoteEndpoint: Codable, Sendable, Equatable {
    public static let fileName = "remote.json"
    public var baseURL: URL
    public var model: String

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    public static func load(from directory: URL) throws -> RemoteEndpoint {
        try JSONCoding.decoder.decode(RemoteEndpoint.self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))
    }

    public func save(to directory: URL) throws {
        try JSONCoding.encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// `host:port` for display and for the model's repo id.
    public var hostAndPort: String {
        let host = baseURL.host() ?? baseURL.absoluteString
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }

    /// Folder name under `models/`: `remote--host_port--model`, flat and filesystem-safe.
    public var directoryName: String {
        let safe = { (s: String) in
            String(s.map { $0.isLetter || $0.isNumber || "-._".contains($0) ? $0 : "_" })
        }
        return "remote--\(safe(hostAndPort))--\(safe(model))"
    }

}

/// Shared JSON settings for all project files (ISO-8601 dates, pretty output).
public enum JSONCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    /// For the API surface: ISO-8601 dates, compact output (clients parse it, nobody reads it).
    public static let apiEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    /// Default-configured, shared so hot paths do not allocate a coder per call.
    public static let plainEncoder = JSONEncoder()
    public static let plainDecoder = JSONDecoder()
}

// ModelCatalog

/// Catalog of local models: scans `models/` and reads manifests.
/// Does not watch the file system; callers invoke `refresh()` (the app does so on folder changes and after downloads).
public actor ModelCatalog {
    public enum Entry: Sendable, Equatable {
        case ready(ModelDescriptor)
        /// Folder exists but the manifest is missing/invalid; offer re-download or delete.
        case broken(directory: URL, reason: String)
    }

    public let modelsDirectory: URL
    private var entries: [Entry] = []

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    public var models: [ModelDescriptor] {
        entries.compactMap { if case .ready(let d) = $0 { d } else { nil } }
    }

    /// A model folder that cannot be loaded (download interrupted, file truncated or deleted): shown for re-download or removal.
    public struct BrokenModel: Sendable, Equatable, Identifiable {
        public var directory: URL
        public var reason: String
        public var id: String { directory.lastPathComponent }
    }

    public var brokenModels: [BrokenModel] {
        entries.compactMap {
            if case .broken(let directory, let reason) = $0 { BrokenModel(directory: directory, reason: reason) } else { nil }
        }
    }

    /// Deletes a broken model's folder; only folders inside the models directory are touched.
    public func removeBroken(_ model: BrokenModel) throws {
        guard model.directory.standardizedFileURL.deletingLastPathComponent() == modelsDirectory.standardizedFileURL else { return }
        try FileManager.default.removeItem(at: model.directory)
        refresh()
    }

    public func model(id: String) -> ModelDescriptor? {
        models.first { $0.id == id }
    }

    /// Resolves by id, short name or repoID (API clients may send any of them).
    public func resolve(_ reference: String) -> ModelDescriptor? {
        let ref = reference.lowercased()
        return models.first {
            $0.id.lowercased() == ref || $0.name == ref || $0.repoID.lowercased() == ref
                || $0.name == ref.split(separator: ":").first.map(String.init)  // ollama-style "name:tag"
        }
    }

    @discardableResult
    public func refresh() -> [ModelDescriptor] {
        let fm = FileManager.default
        try? fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let dirs =
            (try? fm.contentsOfDirectory(
                at: modelsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        entries = dirs.compactMap { dir in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            do {
                let manifest = try ModelManifest.load(from: dir)
                // quick integrity check: every file present with the expected size
                for file in manifest.files {
                    let url = dir.appendingPathComponent(file.path)
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
                    if size != file.sizeBytes {
                        return .broken(directory: dir, reason: "missing or truncated file: \(file.path)")
                    }
                }
                return .ready(manifest.descriptor(directory: dir))
            } catch {
                return .broken(directory: dir, reason: "manifest: \(error)")
            }
        }
        .sorted {
            switch ($0, $1) {
            case (.ready(let a), .ready(let b)): (a.source.rawValue, a.name) < (b.source.rawValue, b.name)
            case (.ready, .broken): true
            case (.broken, .ready): false
            case (.broken(let a, _), .broken(let b, _)): a.path < b.path
            }
        }
        return models
    }

    public func remove(id: String) throws {
        guard let model = model(id: id) else { return }
        try FileManager.default.removeItem(at: model.directory)
        refresh()
    }
}
