//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// ModelReference

/// A downloadable model on one of the hubs. Hugging Face and ModelScope share repository names (`org/repo`), so a
/// ModelScope repository is written `modelscope:org/repo` wherever a single string has to name it.
public enum ModelReference: Sendable, Hashable {
    case huggingFace(repoID: String)
    case modelScope(repoID: String)

    public var source: ModelSource {
        switch self {
        case .huggingFace: .huggingFace
        case .modelScope: .modelScope
        }
    }

    /// Stored in `ModelManifest.repoID` and used as the download's key: `org/repo` or `modelscope:org/repo`.
    public var repoID: String {
        switch self {
        case .huggingFace(let id): id
        case .modelScope(let id): ModelScopeClient.prefix + id
        }
    }

    /// The repository on its own hub, without the prefix.
    public var hubRepoID: String {
        switch self {
        case .huggingFace(let id), .modelScope(let id): id
        }
    }

    public var directoryName: String { ModelDescriptor.directoryName(forRepo: repoID) }

    /// The inverse of `directoryName` (`org--repo`, `modelscope--org--repo`): lets a broken folder be downloaded again.
    public init?(directoryName: String) {
        var parts = directoryName.components(separatedBy: "--")
        if parts.first == "remote" { return nil }  // a remote model is reconnected, not downloaded
        let modelScope = parts.first == "modelscope"
        if modelScope { parts.removeFirst() }
        guard parts.count >= 2 else { return nil }
        let id = parts[0] + "/" + parts[1...].joined(separator: "--")
        self = modelScope ? .modelScope(repoID: id) : .huggingFace(repoID: id)
    }

    /// `org/repo` or a huggingface.co link → Hugging Face; `modelscope:org/repo` or a modelscope.cn link → ModelScope.
    public static func parse(_ input: String) -> ModelReference? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(ModelScopeClient.prefix) {
            return HubClient.parseRepoID(String(s.dropFirst(ModelScopeClient.prefix.count))).map { .modelScope(repoID: $0) }
        }
        if s.contains("modelscope.cn") { return ModelScopeClient.parseRepoID(s).map { .modelScope(repoID: $0) } }
        return HubClient.parseRepoID(s).map { .huggingFace(repoID: $0) }
    }

    /// Reconstructs a reference from a manifest (`source` + `repoID`); nil for a remote model, which has nothing to download.
    public init?(manifest: ModelManifest) {
        switch manifest.source ?? .huggingFace {
        case .huggingFace: self = .huggingFace(repoID: manifest.repoID)
        case .modelScope:
            guard let reference = Self.parse(manifest.repoID) else { return nil }
            self = reference
        case .remote: return nil
        }
    }
}

// RepoFile

/// One file of a hub repository, as the downloader needs it: where it goes, how big it is, what it hashes to.
public struct RepoFile: Sendable, Hashable {
    public var path: String
    public var size: Int64
    public var sha256: String?

    public init(path: String, size: Int64, sha256: String?) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

// ModelScope

/// A search result or repository summary from ModelScope (`/api/v1/dolphin/models`, `/api/v1/models/{id}`).
public struct ModelScopeModel: Sendable, Hashable, Identifiable {
    public var id: String  // "lmstudio-community/gemma-4-12B-it-MLX-4bit"
    public var tags: [String]
    public var libraries: [String]
    public var downloads: Int
    public var lastUpdated: Date?
    public var storageSize: Int64?
    public var baseModel: String?
    public var modelType: String?

    public var isMLX: Bool { tags.contains("mlx") || libraries.contains("mlx") }
    public var displayName: String { id.split(separator: "/").last.map(String.init) ?? id }

    init?(json: [String: Any]) {
        guard let path = json["Path"] as? String, let name = json["Name"] as? String, !path.isEmpty, !name.isEmpty else { return nil }
        id = "\(path)/\(name)"
        tags = json["Tags"] as? [String] ?? []
        libraries = json["Libraries"] as? [String] ?? []
        downloads = json["Downloads"] as? Int ?? 0
        lastUpdated = (json["LastUpdatedTime"] as? Double).map { Date(timeIntervalSince1970: $0) }
        storageSize = (json["StorageSize"] as? NSNumber)?.int64Value
        baseModel = (json["BaseModel"] as? [String])?.first { $0.contains("/") }
        modelType = (json["ModelType"] as? [String])?.first
    }
}

/// ModelScope (modelscope.cn, Alibaba): the same MLX builds as Hugging Face under the same names, a JSON API of its
/// own, SHA-256 for every file and Range downloads. No token: gated repositories are not supported here.
public struct ModelScopeClient: Sendable {
    public static let prefix = "modelscope:"
    public let baseURL: URL

    public init(baseURL: URL = URL(string: "https://modelscope.cn")!) {
        self.baseURL = baseURL
    }

    /// Accepts `org/repo` or `https://modelscope.cn/models/org/repo[/files…]` and returns `org/repo`.
    public static func parseRepoID(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let host = url.host, host.hasSuffix("modelscope.cn") else { return HubClient.parseRepoID(s) }
        return HubClient.parseRepoID(s, host: "modelscope.cn", pathPrefix: "models")
    }

    public func fileURL(repoID: String, path: String) -> URL {
        baseURL.appendingPathComponent("models/\(repoID)/resolve/master/\(path)")
    }

    public func search(query: String, limit: Int = 40, mlxOnly: Bool = true) async throws -> [ModelScopeModel] {
        let body: [String: Any] = [
            "PageSize": limit, "PageNumber": 1, "SortBy": "Default", "Target": "", "SingleCriterion": [], "Criterion": [],
            "Name": query,
        ]
        var request = Self.request(baseURL.appendingPathComponent("api/v1/dolphin/models"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let found = try Self.parseSearch(try await Self.data(for: request))
        return mlxOnly ? found.filter(\.isMLX) : found
    }

    public func info(repoID: String) async throws -> ModelScopeModel {
        let data = try await Self.data(for: Self.request(baseURL.appendingPathComponent("api/v1/models/\(repoID)")))
        guard let model = Self.dataObject(data).flatMap(ModelScopeModel.init(json:)) else { throw HubError.notFound(repoID) }
        return model
    }

    public func files(repoID: String) async throws -> [RepoFile] {
        var c = URLComponents(url: baseURL.appendingPathComponent("api/v1/models/\(repoID)/repo/files"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "Revision", value: "master"), URLQueryItem(name: "Recursive", value: "true")]
        guard let url = c?.url else { throw HubError.badURL(repoID) }
        return Self.parseFiles(try await Self.data(for: Self.request(url)))
    }

    public func config(repoID: String) async throws -> Data {
        try await Self.data(for: Self.request(fileURL(repoID: repoID, path: "config.json")))
    }

    // Parsing (static, so the tests can feed recorded responses)

    static func parseSearch(_ data: Data) throws -> [ModelScopeModel] {
        guard let object = dataObject(data), let model = object["Model"] as? [String: Any], let list = model["Models"] as? [[String: Any]]
        else { throw HubError.badURL("modelscope search") }
        return list.compactMap(ModelScopeModel.init(json:))
    }

    static func parseFiles(_ data: Data) -> [RepoFile] {
        guard let files = dataObject(data)?["Files"] as? [[String: Any]] else { return [] }
        return files.compactMap { file in
            guard file["Type"] as? String == "blob", let path = file["Path"] as? String else { return nil }
            let sha = (file["Sha256"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return RepoFile(path: path, size: (file["Size"] as? NSNumber)?.int64Value ?? 0, sha256: sha)
        }
    }

    /// Every answer is `{"Code": 200, "Data": {…}}`.
    private static func dataObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["Data"] as? [String: Any]
    }

    // Requests

    private static func request(_ url: URL) -> URLRequest {
        // Shorter than the 60 s default, as everywhere else here: the hub is reachable from some networks only, and a
        // search that cannot get through has to say so rather than spin for a minute.
        HTTPJSON.request(url, timeout: 10)
    }

    private static func data(for request: URLRequest) async throws -> Data {
        let (data, raw) = try await URLSession.shared.data(for: request)
        guard let response = raw as? HTTPURLResponse, let url = request.url else { throw URLError(.badServerResponse) }
        // No tokens on this hub, so 401/403 stays a plain server error.
        try HTTPJSON.validate(status: response.statusCode, url: url, gatedOnAuth: false)
        return data
    }
}
