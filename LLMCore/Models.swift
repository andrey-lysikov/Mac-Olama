//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// ModelDescriptor

/// Model kind: text-only or multimodal (accepts images).
public enum ModelKind: String, Codable, Sendable, CaseIterable {
    case llm
    case vlm
}

/// Registry a model was installed from. Drives grouping in menus; Ollama registry support is planned (phase 5).
public enum ModelSource: String, Codable, Sendable, CaseIterable {
    case huggingFace = "huggingface"
    case ollama = "ollama"

    public var displayName: String {
        switch self {
        case .huggingFace: "Hugging Face"
        case .ollama: "Ollama"
        }
    }

    /// Emoji mark of the hub, shown next to models and in the hub picker so the origin is obvious at a glance.
    public var glyph: String {
        switch self {
        case .huggingFace: "🤗"
        case .ollama: "🦙"
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

    public init(
        id: String, name: String, repoID: String, source: ModelSource = .huggingFace, kind: ModelKind, directory: URL,
        sizeBytes: Int64, contextLength: Int? = nil, quantization: String? = nil,
        supportsTools: Bool = false, downloadedAt: Date = .now
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
    }

    /// Folder name for a repo: `org/repo` → `org--repo`.
    public static func directoryName(forRepo repoID: String) -> String {
        repoID.replacingOccurrences(of: "/", with: "--")
    }

    /// Short name for API/menu: last repo component, lowercased.
    public static func shortName(forRepo repoID: String) -> String {
        (repoID.split(separator: "/").last.map(String.init) ?? repoID).lowercased()
    }
}

// ModelManifest

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

    public init(
        version: Int = ModelManifest.currentVersion, repoID: String, revision: String = "main", source: ModelSource? = .huggingFace,
        kind: ModelKind, files: [FileEntry], contextLength: Int? = nil, quantization: String? = nil,
        supportsTools: Bool = false, architectures: [String] = [], downloadedAt: Date = .now,
        chatTemplateOverride: String? = nil
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

    /// Tool calling is a property of the model's own chat template, so ask the model's files instead of a list of names:
    /// a template that mentions `tools` renders tool definitions, one that does not would silently drop them.
    public static func templateSupportsTools(in directory: URL) -> Bool {
        ["chat_template.jinja", "chat_template.json", "tokenizer_config.json"].contains { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return false }
            return String(decoding: data, as: UTF8.self).contains("tools")
        }
    }

    // `supportsTools` is re-read from the template on every catalog refresh, so manifests written by older builds stay correct.
    public func descriptor(directory: URL) -> ModelDescriptor {
        ModelDescriptor(
            id: ModelDescriptor.directoryName(forRepo: repoID),
            name: ModelDescriptor.shortName(forRepo: repoID),
            repoID: repoID, source: source ?? .huggingFace, kind: kind, directory: directory,
            sizeBytes: totalSizeBytes, contextLength: contextLength, quantization: quantization,
            supportsTools: Self.templateSupportsTools(in: directory), downloadedAt: downloadedAt
        )
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

    public var brokenEntries: [Entry] {
        entries.filter { if case .broken = $0 { true } else { false } }
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
