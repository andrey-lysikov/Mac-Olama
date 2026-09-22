//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// HubModels

/// Hugging Face search result (subset of `/api/models` fields).
public struct HubModelSummary: Codable, Sendable, Identifiable, Hashable {
    public var id: String  // "mlx-community/Qwen3-8B-4bit"
    public var author: String?
    public var downloads: Int?
    public var likes: Int?
    public var tags: [String]?
    public var pipelineTag: String?
    public var lastModified: Date?
    public var gated: GatedValue?

    enum CodingKeys: String, CodingKey {
        case id, author, downloads, likes, tags, gated
        case pipelineTag = "pipeline_tag"
        case lastModified
    }

    public var isMLX: Bool { tags?.contains("mlx") == true }
    public var isGated: Bool { gated?.isGated ?? false }
    public var displayName: String { id.split(separator: "/").last.map(String.init) ?? id }
}

/// HF returns `gated` as false | "auto" | "manual".
public enum GatedValue: EitherCodable, Sendable, Hashable {
    case bool(Bool), string(String)
    public init(first: Bool) { self = .bool(first) }
    public init(second: String) { self = .string(second) }
    public var first: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var second: String? { if case .string(let s) = self { s } else { nil } }
    public init(from decoder: Decoder) throws { self = try Self.decodeEither(from: decoder) }
    public func encode(to encoder: Encoder) throws { try encodeEither(to: encoder) }
    public var isGated: Bool { if case .bool(let b) = self { b } else { true } }
}

/// Repo details with file list (`/api/models/{id}?blobs=true`).
public struct HubModelInfo: Codable, Sendable, Hashable {
    public struct Sibling: Codable, Sendable, Hashable {
        public var rfilename: String
        public var size: Int64?
        public var lfs: LFS?
        public struct LFS: Codable, Sendable, Hashable {
            public var oid: String  // sha256
            public var size: Int64

            enum CodingKeys: String, CodingKey { case oid, sha256, size }
            public init(oid: String, size: Int64) {
                self.oid = oid
                self.size = size
            }
            // `/api/models/{id}?blobs=true` names the hash `sha256`; the tree API names it `oid`.
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                oid = try c.decodeIfPresent(String.self, forKey: .sha256) ?? c.decode(String.self, forKey: .oid)
                size = try c.decode(Int64.self, forKey: .size)
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(oid, forKey: .oid)
                try c.encode(size, forKey: .size)
            }
        }
        public var byteSize: Int64 { lfs?.size ?? size ?? 0 }
        public var sha256: String? { lfs?.oid }
    }
    public var id: String
    public var sha: String?
    public var siblings: [Sibling]
    public var tags: [String]?
    public var gated: GatedValue?

    public var totalBytes: Int64 { siblings.reduce(0) { $0 + $1.byteSize } }
}

/// Model facts read from `config.json`: kind, context, quantization. Nothing here is keyed on model names.
public struct HubModelClassification: Sendable, Equatable {
    public var kind: ModelKind
    public var architectures: [String]
    public var modelType: String?
    public var contextLength: Int?
    public var quantization: String?
    /// What a token costs in the attention cache, from the same config.
    public var kvCache: KVCacheProfile?

    public static func classify(configJSON: Data) -> HubModelClassification {
        guard let config = ModelConfig(data: configJSON) else {
            return HubModelClassification(kind: .llm, architectures: [])
        }
        // The root, not the `text_config` fallback: a multimodal `text_config` may carry its own `model_type`.
        let obj = config.root
        let modelType = obj["model_type"] as? String
        let architectures = obj["architectures"] as? [String] ?? []
        // A vision model declares its image tower in the config (`vision_config`, `vision_tower`, `mm_vision_tower`, …).
        // That is a fact about the checkpoint; guessing from architecture class names ("…VL…") is not.
        let hasVision = obj.keys.contains { $0.lowercased().contains("vision") }
        let kind: ModelKind = hasVision ? .vlm : .llm
        let context = config.int("max_position_embeddings")
        var quant: String?
        if let q = obj["quantization"] as? [String: Any], let bits = q["bits"] as? Int {
            quant = "\(bits)-bit" + ((q["group_size"] as? Int).map { " g\($0)" } ?? "")
        } else if let q = obj["quantization_config"] as? [String: Any], let bits = q["bits"] as? Int {
            quant = "\(bits)-bit"
        }
        return HubModelClassification(
            kind: kind, architectures: architectures, modelType: modelType, contextLength: context, quantization: quant,
            kvCache: KVCacheProfile.read(configJSON: configJSON))
    }
}

public enum HubError: Error, Equatable {
    case badURL(String)
    case httpStatus(Int, url: String)
    case gatedRepositoryRequiresToken(String)
    case notFound(String)
    case checksumMismatch(file: String)
    case cancelled
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case unsafePath(String)
}

// HTTPJSON

/// Shared HTTP plumbing of the JSON APIs (the hubs, the remote engines): one request builder, one status check.
enum HTTPJSON {
    /// A GET request, or a JSON POST when `jsonBody` is given. `accept`/`userAgent` are nil for endpoints whose
    /// requests must stay byte-identical to what they were (remote inference servers, port probes).
    static func request(
        _ url: URL, token: String? = nil, jsonBody: Data? = nil, timeout: TimeInterval? = nil,
        accept: String? = "application/json", userAgent: String? = "Mac-Olama/0.1"
    ) -> URLRequest {
        var r = URLRequest(url: url)
        if let timeout { r.timeoutInterval = timeout }
        if let accept { r.setValue(accept, forHTTPHeaderField: "Accept") }
        if let userAgent { r.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let jsonBody {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = jsonBody
        }
        return r
    }

    /// Maps a status code to `HubError`. `gatedOnAuth` is off for hubs without tokens, where 401/403 stays a plain
    /// server error instead of "needs a token".
    static func validate(status: Int, url: URL, allowing: Set<Int> = [200], gatedOnAuth: Bool = true) throws {
        if allowing.contains(status) { return }
        if gatedOnAuth, status == 401 || status == 403 { throw HubError.gatedRepositoryRequiresToken(url.path) }
        if status == 404 { throw HubError.notFound(url.path) }
        throw HubError.httpStatus(status, url: url.absoluteString)
    }
}

// HubClient

/// Model families suggested by the empty search field: display name → search text for each hub.
/// `KeyValuePairs` is the ordered flavour of a dictionary literal, so the dropdown keeps this order.
public enum RecommendedModels {
    public static let queries: KeyValuePairs<String, [ModelSource: String]> = [
        "Qwen 3.6": [.huggingFace: "Qwen3.6", .modelScope: "Qwen3.6"],
        "Qwen 3 Coder": [.huggingFace: "Qwen3-Coder", .modelScope: "Qwen3-Coder"],
        "Gemma 4": [.huggingFace: "gemma-4", .modelScope: "gemma-4"],
        "Ornith 1.5": [.huggingFace: "Ornith-1.5", .modelScope: "Ornith-1.5"],
    ]

    public static var names: [String] { queries.map(\.key) }

    public static func query(for name: String, in source: ModelSource) -> String? {
        queries.first { $0.key == name }?.value[source]
    }
}

/// Hugging Face Hub client: search, metadata, config.json. Weights are fetched by `ModelDownloader`.
public struct HubClient: Sendable {
    public let baseURL: URL
    public let token: String?

    public init(baseURL: URL = URL(string: "https://huggingface.co")!, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s) ?? .distantPast
        }
        return d
    }()

    // URLs

    /// `api/models`, most downloaded first. `leading`/`trailing` keep each caller's exact query order.
    private func modelsURL(_ leading: [URLQueryItem], trailing: [URLQueryItem] = [], limit: Int) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        c.queryItems =
            leading + [
                URLQueryItem(name: "sort", value: "downloads"),
                URLQueryItem(name: "direction", value: "-1"),
                URLQueryItem(name: "limit", value: String(limit)),
            ] + trailing
        return c.url!
    }

    /// Only MLX builds: the app runs nothing else.
    public func searchURL(query: String, author: String? = nil, limit: Int = 30) -> URL {
        var trailing = [URLQueryItem(name: "filter", value: "mlx")]
        if let author { trailing.append(URLQueryItem(name: "author", value: author)) }
        return modelsURL([URLQueryItem(name: "search", value: query)], trailing: trailing, limit: limit)
    }

    /// MTP drafters published for a base model: the hub is asked for repositories tagged with that base model, built
    /// for MLX and marked as prediction heads. Nothing is derived from the model's name.
    public func drafterURL(baseModel: String, limit: Int = 10) -> URL {
        modelsURL(
            [
                URLQueryItem(name: "filter", value: "base_model:\(baseModel)"),
                URLQueryItem(name: "filter", value: "mlx"),
                URLQueryItem(name: "filter", value: "mtp"),
            ], limit: limit)
    }

    public func infoURL(repoID: String) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("api/models/\(repoID)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        return c.url!
    }

    public func fileURL(repoID: String, path: String, revision: String = "main") -> URL {
        baseURL.appendingPathComponent("\(repoID)/resolve/\(revision)/\(path)")
    }

    /// Accepts `org/repo`, `https://huggingface.co/org/repo` or `.../org/repo/tree/main` and returns `org/repo`.
    public static func parseRepoID(_ input: String) -> String? {
        parseRepoID(input, host: "huggingface.co", pathPrefix: nil)
    }

    /// The same for any hub: `org/repo`, or a link on `host` whose path may start with `pathPrefix`
    /// (ModelScope keeps repositories under `/models/org/repo`).
    static func parseRepoID(_ input: String, host: String, pathPrefix: String?) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if let url = URL(string: s), let h = url.host, h.hasSuffix(host) {
            var parts = url.path.split(separator: "/").map(String.init)
            if let pathPrefix {
                guard parts.first == pathPrefix else { return nil }
                parts.removeFirst()
            }
            guard parts.count >= 2 else { return nil }
            s = "\(parts[0])/\(parts[1])"
        }
        let parts = s.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return s
    }

    // Requests

    func request(_ url: URL) -> URLRequest {
        HTTPJSON.request(url, token: token)
    }

    func get(_ url: URL) async throws -> Data {
        let (data, raw) = try await URLSession.shared.data(for: request(url))
        guard let response = raw as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try HTTPJSON.validate(status: response.statusCode, url: url)
        return data
    }

    public func search(query: String, author: String? = nil, limit: Int = 30) async throws -> [HubModelSummary] {
        try Self.decoder.decode([HubModelSummary].self, from: try await get(searchURL(query: query, author: author, limit: limit)))
    }

    public func drafters(baseModel: String, limit: Int = 10) async throws -> [HubModelSummary] {
        let found = try Self.decoder.decode([HubModelSummary].self, from: try await get(drafterURL(baseModel: baseModel, limit: limit)))
        // A GGUF build cannot be loaded here, whatever its tags say.
        return found.filter { !($0.tags ?? []).contains("gguf") }
    }

    public func info(repoID: String) async throws -> HubModelInfo {
        try Self.decoder.decode(HubModelInfo.self, from: try await get(infoURL(repoID: repoID)))
    }

    /// Any file of a repository. `head` asks for its first bytes only, enough to read a safetensors header without
    /// pulling the weights behind it.
    public func file(repoID: String, path: String, revision: String = "main", head: Int? = nil) async throws -> Data {
        let url = fileURL(repoID: repoID, path: path, revision: revision)
        guard let head else { return try await get(url) }
        var r = request(url)
        r.setValue("bytes=0-\(head - 1)", forHTTPHeaderField: "Range")
        let (data, raw) = try await URLSession.shared.data(for: r)
        guard let response = raw as? HTTPURLResponse, response.statusCode == 200 || response.statusCode == 206 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public func config(repoID: String, revision: String = "main") async throws -> Data {
        try await get(fileURL(repoID: repoID, path: "config.json", revision: revision))
    }

    public func classify(repoID: String) async throws -> HubModelClassification {
        HubModelClassification.classify(configJSON: try await config(repoID: repoID))
    }
}
