//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

public enum CloudProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case kimi = "kimi"
    case deepSeek = "deepseek"
    case alibaba = "alibaba"
    case openAI = "openai"

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .kimi: "Kimi"
        case .deepSeek: "DeepSeek"
        case .alibaba: "Alibaba"
        case .openAI: "OpenAI"
        }
    }

    var source: ModelSource {
        switch self {
        case .kimi: .kimi
        case .deepSeek: .deepSeek
        case .alibaba: .alibaba
        case .openAI: .openAI
        }
    }

    init?(source: ModelSource) {
        guard let provider = Self.allCases.first(where: { $0.source == source }) else { return nil }
        self = provider
    }

    var defaultBaseAPI: String {
        switch self {
        case .kimi: "https://api.kimi.ai/coding"
        case .deepSeek: "https://api.deepseek.com"
        case .alibaba: "https://coding-intl.dashscope.aliyuncs.com"
        case .openAI: "https://chatgpt.com/backend-api/codex"
        }
    }

    var baseAPI: URL { URL(string: defaultBaseAPI)! }

    func baseAPI(from setting: String) -> URL {
        var text = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = defaultBaseAPI }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if self != .openAI, text.hasSuffix("/v1") { text = String(text.dropLast(3)) }
        return URL(string: text) ?? baseAPI
    }

    var accountURL: URL {
        switch self {
        case .kimi: URL(string: "https://www.kimi.ai/code")!
        case .deepSeek: URL(string: "https://platform.deepseek.com/top_up")!
        case .alibaba: URL(string: "https://modelstudio.console.alibabacloud.com/#/efm/coding_plan")!
        case .openAI: URL(string: "https://chatgpt.com/codex/settings/usage")!
        }
    }

    var apiKeyURL: URL? {
        switch self {
        case .kimi, .alibaba: accountURL
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")!
        case .openAI: nil
        }
    }

    var usesOAuth: Bool { self == .kimi || self == .openAI }
    var showsAPIKeyInAdvanced: Bool { self == .kimi }
    var showsBalance: Bool { self == .deepSeek }
    var supportsCustomBaseAPI: Bool { self != .openAI }
    var checksAvailability: Bool { self == .kimi || self == .deepSeek }
    var usesResponsesAPI: Bool { self == .openAI }
    var quotaHTTPStatuses: Set<Int> { self == .deepSeek ? [402] : [402, 429] }
    var iconName: String { "Cloud\(rawValue.capitalized)" }

    func oauthHost(for baseAPI: URL) -> String? {
        guard self == .kimi else { return nil }
        return baseAPI.host() == "api.kimi.com" ? "https://auth.kimi.com" : "https://auth.kimi.ai"
    }

    var accountPrompt: String {
        switch self {
        case .kimi: String(localized: "A browser opens to confirm the sign-in with your Kimi membership")
        case .deepSeek: String(localized: "Pay-per-token API. Add an API key to see your balance and available models.")
        case .alibaba: String(localized: "Add the sk-sp- key from your Coding Plan page. Use the plan key, not a pay-as-you-go Model Studio key.")
        case .openAI: String(localized: "A browser opens to confirm sign-in with your ChatGPT subscription")
        }
    }
}

public struct CloudModel: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var displayName: String
    public var detail: String?
    public var contextLength: Int
    public var maximumContextLength: Int?
    public var maximumOutputTokens: Int?
    public var supportsTools: Bool
    public var supportsImages: Bool
    public var efforts: [String]
    public var defaultEffort: String?
    public var useResponsesLite: Bool

    public init(
        id: String, displayName: String, detail: String? = nil, contextLength: Int, maximumContextLength: Int? = nil,
        maximumOutputTokens: Int? = nil, supportsTools: Bool = true, supportsImages: Bool = false, efforts: [String] = [],
        defaultEffort: String? = nil, useResponsesLite: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.contextLength = contextLength
        self.maximumContextLength = maximumContextLength
        self.maximumOutputTokens = maximumOutputTokens
        self.supportsTools = supportsTools
        self.supportsImages = supportsImages
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.useResponsesLite = useResponsesLite
    }

    public var contextOptions: [Int] {
        let maximum = maximumContextLength ?? contextLength
        var options = [contextLength]
        if maximum != contextLength { options.append(maximum) }
        if maximum > 262_144, !options.contains(262_144) { options.insert(262_144, at: 0) }
        return options.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, detail, contextLength, maximumContextLength, maximumOutputTokens
        case supportsTools, supportsImages, efforts, defaultEffort, useResponsesLite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        contextLength = try container.decode(Int.self, forKey: .contextLength)
        maximumContextLength = try container.decodeIfPresent(Int.self, forKey: .maximumContextLength)
        maximumOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maximumOutputTokens)
        supportsTools = try container.decodeIfPresent(Bool.self, forKey: .supportsTools) ?? true
        supportsImages = try container.decodeIfPresent(Bool.self, forKey: .supportsImages) ?? false
        efforts = try container.decodeIfPresent([String].self, forKey: .efforts) ?? []
        defaultEffort = try container.decodeIfPresent(String.self, forKey: .defaultEffort)
        useResponsesLite = try container.decodeIfPresent(Bool.self, forKey: .useResponsesLite) ?? false
    }
}

public struct CloudQuota: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var usedRatio: Double
        public var resetAt: Date?

        public init(id: String, title: String, usedRatio: Double, resetAt: Date? = nil) {
            self.id = id
            self.title = title
            self.usedRatio = usedRatio
            self.resetAt = resetAt
        }
    }
    public var entries: [Entry]
    public var planName: String?

    public init(entries: [Entry], planName: String? = nil) {
        self.entries = entries
        self.planName = planName
    }
}

public struct DeepSeekBalance: Sendable, Equatable, Identifiable {
    public var currency: String
    public var total: Double
    public var granted: Double
    public var toppedUp: Double
    public var id: String { currency }
}

public struct CloudTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String?
    public var expiresAt: Date
    public var accountID: String?
    public var oauthHost: String?

    public init(
        accessToken: String, refreshToken: String, idToken: String? = nil, expiresAt: Date,
        accountID: String? = nil, oauthHost: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.oauthHost = oauthHost
    }
}

public struct CloudAccountConfiguration: Codable, Sendable {
    public var apiKey: String?
    public var baseAPI = ""
    public var enabledModels: [String] = []
    public var modelSnapshot: [CloudModel] = []
    public var tokens: CloudTokens?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case apiKey, baseAPI, enabledModels, modelSnapshot, tokens, openAITokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        baseAPI = try container.decodeIfPresent(String.self, forKey: .baseAPI) ?? ""
        enabledModels = try container.decodeIfPresent([String].self, forKey: .enabledModels) ?? []
        modelSnapshot = try container.decodeIfPresent([CloudModel].self, forKey: .modelSnapshot) ?? []
        tokens = try container.decodeIfPresent(CloudTokens.self, forKey: .tokens)
            ?? container.decodeIfPresent(CloudTokens.self, forKey: .openAITokens)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(apiKey, forKey: .apiKey)
        try container.encode(baseAPI, forKey: .baseAPI)
        try container.encode(enabledModels, forKey: .enabledModels)
        try container.encode(modelSnapshot, forKey: .modelSnapshot)
        try container.encodeIfPresent(tokens, forKey: .tokens)
    }
}

public struct CloudDeviceAuthorization: Sendable {
    public var provider: CloudProvider
    public var deviceCode: String
    public var userCode: String
    public var verificationURL: URL
    public var interval: Double
    public var expiresIn: Double
    public var oauthHost: String? = nil
}

public struct CloudProfile: Sendable, Equatable {
    public var name: String
    public var planName: String?
    public var avatarURL: URL?

    public init(name: String, planName: String? = nil, avatarURL: URL? = nil) {
        self.name = name
        self.planName = planName
        self.avatarURL = avatarURL
    }
}

public enum CloudError: DescribedError {
    case unauthorized(CloudProvider)
    case http(CloudProvider, Int, String)
    case badResponse(CloudProvider)
    case denied
    case expired

    public var description: String {
        switch self {
        case .unauthorized(let provider): String(localized: "\(provider.title) rejected the credentials. Sign in again.")
        case .http(let provider, let status, let message): String(localized: "\(provider.title) error \(status): \(message)")
        case .badResponse(let provider): String(localized: "\(provider.title) returned an unexpected answer.")
        case .denied: String(localized: "Authorization was declined in the browser.")
        case .expired: String(localized: "The authorization code expired. Start signing in again.")
        }
    }
}
