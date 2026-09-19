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
public enum GatedValue: Codable, Sendable, Hashable {
    case bool(Bool), string(String)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) } else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b);
        case .string(let s): try c.encode(s)
        }
    }
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

    public static func classify(configJSON: Data) -> HubModelClassification {
        guard let obj = try? JSONSerialization.jsonObject(with: configJSON) as? [String: Any] else {
            return HubModelClassification(kind: .llm, architectures: [])
        }
        let modelType = obj["model_type"] as? String
        let architectures = obj["architectures"] as? [String] ?? []
        // A vision model declares its image tower in the config (`vision_config`, `vision_tower`, `mm_vision_tower`, …).
        // That is a fact about the checkpoint; guessing from architecture class names ("…VL…") is not.
        let hasVision = obj.keys.contains { $0.lowercased().contains("vision") }
        let kind: ModelKind = hasVision ? .vlm : .llm
        let textConfig = obj["text_config"] as? [String: Any] ?? obj
        let context = (textConfig["max_position_embeddings"] as? Int) ?? (obj["max_position_embeddings"] as? Int)
        var quant: String?
        if let q = obj["quantization"] as? [String: Any], let bits = q["bits"] as? Int {
            quant = "\(bits)-bit" + ((q["group_size"] as? Int).map { " g\($0)" } ?? "")
        } else if let q = obj["quantization_config"] as? [String: Any], let bits = q["bits"] as? Int {
            quant = "\(bits)-bit"
        }
        return HubModelClassification(
            kind: kind, architectures: architectures, modelType: modelType, contextLength: context, quantization: quant)
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
}

// HubClient

/// Model families suggested by the empty search field: display name → search text for each hub.
/// `KeyValuePairs` is the ordered flavour of a dictionary literal, so the dropdown keeps this order.
public enum RecommendedModels {
    public static let queries: KeyValuePairs<String, [ModelSource: String]> = [
        "Qwen 3.6": [.huggingFace: "Qwen3.6", .ollama: "qwen3.6"],
        "Qwen 3 Coder": [.huggingFace: "Qwen3-Coder", .ollama: "qwen3-coder"],
        "Gemma 4": [.huggingFace: "gemma-4", .ollama: "gemma4"],
        "Ornith 1.5": [.huggingFace: "Ornith-1.5", .ollama: "ornith"],
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

    public func searchURL(query: String, author: String? = nil, limit: Int = 30, mlxOnly: Bool = true) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if mlxOnly { items.append(URLQueryItem(name: "filter", value: "mlx")) }
        if let author { items.append(URLQueryItem(name: "author", value: author)) }
        c.queryItems = items
        return c.url!
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
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if let url = URL(string: s), let host = url.host, host.hasSuffix("huggingface.co") {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            s = "\(parts[0])/\(parts[1])"
        }
        let parts = s.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return s
    }

    // Requests

    func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Mac-Olama/0.1", forHTTPHeaderField: "User-Agent")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    func get(_ url: URL) async throws -> Data {
        let (data, raw) = try await URLSession.shared.data(for: request(url))
        guard let response = raw as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch response.statusCode {
        case 200: return data
        case 401, 403: throw HubError.gatedRepositoryRequiresToken(url.path)
        case 404: throw HubError.notFound(url.path)
        default: throw HubError.httpStatus(response.statusCode, url: url.absoluteString)
        }
    }

    public func search(query: String, author: String? = nil, limit: Int = 30, mlxOnly: Bool = true) async throws -> [HubModelSummary] {
        try Self.decoder.decode(
            [HubModelSummary].self, from: try await get(searchURL(query: query, author: author, limit: limit, mlxOnly: mlxOnly)))
    }

    public func info(repoID: String) async throws -> HubModelInfo {
        try Self.decoder.decode(HubModelInfo.self, from: try await get(infoURL(repoID: repoID)))
    }

    public func config(repoID: String, revision: String = "main") async throws -> Data {
        try await get(fileURL(repoID: repoID, path: "config.json", revision: revision))
    }

    public func classify(repoID: String) async throws -> HubModelClassification {
        HubModelClassification.classify(configJSON: try await config(repoID: repoID))
    }
}
