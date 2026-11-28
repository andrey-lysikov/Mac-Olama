//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

public enum CloudClient {
    static func models(provider: CloudProvider, baseAPI: URL, token: String, accountID: String? = nil) async throws -> [CloudModel] {
        switch provider {
        case .kimi: try await kimiModels(baseAPI: baseAPI, token: token)
        case .deepSeek: try await deepSeekModels(baseAPI: baseAPI, token: token)
        case .alibaba: alibabaModels
        case .openAI: try await openAIModels(baseAPI: baseAPI, token: token, accountID: accountID)
        }
    }

    static func balance(baseAPI: URL, token: String) async throws -> [DeepSeekBalance] {
        let object = try await get(baseAPI.appending(path: "user/balance"), token: token, provider: .deepSeek)
        guard let items = object["balance_infos"] as? [[String: Any]] else { throw CloudError.badResponse(.deepSeek) }
        return items.compactMap { item in
            guard let currency = item["currency"] as? String,
                let total = number(item["total_balance"]),
                let granted = number(item["granted_balance"]),
                let toppedUp = number(item["topped_up_balance"])
            else { return nil }
            return DeepSeekBalance(currency: currency, total: total, granted: granted, toppedUp: toppedUp)
        }
    }

    static func usage(provider: CloudProvider, baseAPI: URL, token: String, accountID: String? = nil) async throws -> CloudQuota {
        switch provider {
        case .kimi: try await kimiUsage(baseAPI: baseAPI, token: token)
        case .openAI: try await openAIUsage(token: token, accountID: accountID)
        case .deepSeek, .alibaba: throw CloudError.badResponse(provider)
        }
    }

    static func profile(provider: CloudProvider, baseAPI: URL, token: String, tokens: CloudTokens?) async throws -> CloudProfile {
        switch provider {
        case .kimi:
            let object = try await get(baseAPI.appending(path: "v1/me"), token: token, provider: .kimi)
            let nickname = object["nickname"] as? String ?? ""
            let name = nickname.isEmpty ? (object["username"] as? String ?? "") : nickname
            let level = object["user_level_name"] as? String ?? ""
            return CloudProfile(
                name: name.isEmpty ? String(localized: "Signed in") : name,
                planName: level.isEmpty ? nil : level,
                avatarURL: (object["avatar"] as? String).flatMap { URL(string: $0) })
        case .openAI:
            guard let tokens else { throw CloudError.badResponse(.openAI) }
            return openAIProfile(tokens: tokens)
        case .deepSeek, .alibaba:
            throw CloudError.badResponse(provider)
        }
    }

    static func deviceAuthorization(for provider: CloudProvider, baseAPI: URL) async throws -> CloudDeviceAuthorization {
        switch provider {
        case .kimi:
            guard let host = provider.oauthHost(for: baseAPI), let url = URL(string: "\(host)/api/oauth/device_authorization")
            else { throw CloudError.badResponse(.kimi) }
            let object = try await postForm(url, fields: ["client_id": kimiClientID], provider: .kimi)
            guard let userCode = object["user_code"] as? String, !userCode.isEmpty,
                let deviceCode = object["device_code"] as? String, !deviceCode.isEmpty,
                let complete = object["verification_uri_complete"] as? String,
                let verificationURL = URL(string: complete)
            else { throw CloudError.badResponse(.kimi) }
            return CloudDeviceAuthorization(
                provider: .kimi, deviceCode: deviceCode, userCode: userCode, verificationURL: verificationURL,
                interval: number(object["interval"]) ?? 5, expiresIn: number(object["expires_in"]) ?? 300, oauthHost: host)
        case .openAI:
            let url = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
            let object = try await post(url, json: ["client_id": openAIClientID], provider: .openAI)
            guard let id = object["device_auth_id"] as? String,
                let code = (object["user_code"] as? String) ?? (object["usercode"] as? String)
            else { throw CloudError.badResponse(.openAI) }
            return CloudDeviceAuthorization(
                provider: .openAI, deviceCode: id, userCode: code,
                verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
                interval: number(object["interval"]) ?? 5, expiresIn: 900)
        case .deepSeek, .alibaba:
            throw CloudError.badResponse(provider)
        }
    }

    enum DevicePollResult: Sendable {
        case pending
        case success(CloudTokens)
        case denied
        case expired
    }

    static func pollDeviceToken(_ authorization: CloudDeviceAuthorization) async throws -> DevicePollResult {
        switch authorization.provider {
        case .kimi:
            guard let host = authorization.oauthHost else { throw CloudError.badResponse(.kimi) }
            return try await pollKimi(authorization, oauthHost: host)
        case .openAI:
            let url = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
            do {
                let object = try await post(
                    url, json: ["device_auth_id": authorization.deviceCode, "user_code": authorization.userCode], provider: .openAI)
                guard let code = object["authorization_code"] as? String, let verifier = object["code_verifier"] as? String
                else { throw CloudError.badResponse(.openAI) }
                return .success(try await exchangeOpenAICode(code, verifier: verifier))
            } catch CloudError.http(let provider, let status, _) where provider == .openAI && status == 404 {
                return .pending
            } catch CloudError.unauthorized(let provider) where provider == .openAI {
                return .pending
            }
        case .deepSeek, .alibaba:
            throw CloudError.badResponse(authorization.provider)
        }
    }

    private static func pollKimi(_ authorization: CloudDeviceAuthorization, oauthHost: String) async throws -> DevicePollResult {
        guard let url = URL(string: "\(oauthHost)/api/oauth/token") else { throw CloudError.badResponse(.kimi) }
        do {
            let object = try await postForm(url, fields: [
                "client_id": kimiClientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ], provider: .kimi)
            guard let tokens = parseKimiTokens(object, oauthHost: oauthHost) else { throw CloudError.badResponse(.kimi) }
            return .success(tokens)
        } catch CloudError.http(let provider, let status, let message) where provider == .kimi {
            if status >= 500 { throw CloudError.http(provider, status, message) }
            if message.contains("authorization_pending") || message.contains("slow_down") { return .pending }
            if message.contains("expired_token") { return .expired }
            if message.contains("access_denied") { return .denied }
            throw CloudError.http(provider, status, message)
        }
    }

    static func refresh(_ tokens: CloudTokens, provider: CloudProvider, baseAPI: URL) async throws -> CloudTokens {
        switch provider {
        case .kimi:
            guard let host = tokens.oauthHost ?? provider.oauthHost(for: baseAPI),
                let url = URL(string: "\(host)/api/oauth/token")
            else { throw CloudError.badResponse(.kimi) }
            let object = try await postForm(url, fields: [
                "client_id": kimiClientID,
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
            ], provider: .kimi)
            guard let fresh = parseKimiTokens(object, oauthHost: host) else { throw CloudError.badResponse(.kimi) }
            return fresh
        case .openAI:
            let object = try await postForm(URL(string: "https://auth.openai.com/oauth/token")!, fields: [
                "client_id": openAIClientID,
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
                "scope": "openid profile email",
            ], provider: .openAI)
            return try parseOpenAITokens(object, previous: tokens)
        case .deepSeek, .alibaba:
            throw CloudError.badResponse(provider)
        }
    }

    private static let kimiClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    private static let openAIClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private static func exchangeOpenAICode(_ code: String, verifier: String) async throws -> CloudTokens {
        let object = try await postForm(URL(string: "https://auth.openai.com/oauth/token")!, fields: [
            "grant_type": "authorization_code",
            "client_id": openAIClientID,
            "code": code,
            "redirect_uri": "https://auth.openai.com/deviceauth/callback",
            "code_verifier": verifier,
        ], provider: .openAI)
        return try parseOpenAITokens(object, previous: nil)
    }

    private static func parseKimiTokens(_ object: [String: Any], oauthHost: String) -> CloudTokens? {
        guard let access = object["access_token"] as? String, !access.isEmpty,
            let refresh = object["refresh_token"] as? String, !refresh.isEmpty,
            let expiresIn = number(object["expires_in"]), expiresIn > 0
        else { return nil }
        return CloudTokens(
            accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn), oauthHost: oauthHost)
    }

    private static func parseOpenAITokens(_ object: [String: Any], previous: CloudTokens?) throws -> CloudTokens {
        guard let access = object["access_token"] as? String, !access.isEmpty else { throw CloudError.badResponse(.openAI) }
        let refresh = (object["refresh_token"] as? String) ?? previous?.refreshToken ?? ""
        guard !refresh.isEmpty else { throw CloudError.badResponse(.openAI) }
        let id = (object["id_token"] as? String) ?? previous?.idToken
        let jwt = jwtClaims(id ?? access)
        let auth = jwt["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let account = (auth["chatgpt_account_id"] as? String) ?? previous?.accountID
        let expires = number(object["expires_in"]).map { Date().addingTimeInterval($0) }
            ?? number(jwt["exp"]).map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(3600)
        return CloudTokens(accessToken: access, refreshToken: refresh, idToken: id, expiresAt: expires, accountID: account)
    }

    private static func openAIProfile(tokens: CloudTokens) -> CloudProfile {
        let jwt = jwtClaims(tokens.idToken ?? tokens.accessToken)
        let auth = jwt["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let name = (jwt["name"] as? String) ?? (jwt["email"] as? String) ?? String(localized: "Signed in")
        let plan = (auth["chatgpt_plan_type"] as? String)?.replacingOccurrences(of: "_", with: " ").capitalized
        return CloudProfile(name: name, planName: plan)
    }

    private static func kimiModels(baseAPI: URL, token: String) async throws -> [CloudModel] {
        let object = try await get(baseAPI.appending(path: "v1/models"), token: token, provider: .kimi)
        guard let data = object["data"] as? [[String: Any]] else { throw CloudError.badResponse(.kimi) }
        return data.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let limit = item["limit"] as? [String: Any]
            let context = number(limit?["context"]).map(Int.init) ?? 0
            guard context > 0 else { return nil }
            let reasoning = item["reasoning"] as? [String: Any]
            let effort = reasoning?["effort"] as? [String: Any]
            let efforts = (effort?["valid"] as? [String]) ?? []
            let defaultEffort = effort?["default"] as? String
            let modalities = item["modalities"] as? [String: Any]
            let inputs = (modalities?["input"] as? [String]) ?? []
            return CloudModel(
                id: id, displayName: (item["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                contextLength: context, supportsTools: (item["supports_tool_use"] as? Bool) ?? true,
                supportsImages: inputs.contains("image"), efforts: efforts,
                defaultEffort: defaultEffort.flatMap { efforts.contains($0) ? $0 : nil })
        }
    }

    private static func deepSeekModels(baseAPI: URL, token: String) async throws -> [CloudModel] {
        let object = try await get(baseAPI.appending(path: "models"), token: token, provider: .deepSeek)
        guard let data = object["data"] as? [[String: Any]] else { throw CloudError.badResponse(.deepSeek) }
        return data.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let effort = item["effort"] as? [String: Any]
            let efforts = effort?["supported_levels"] as? [String] ?? []
            let defaultEffort = effort?["default_level"] as? String
            return CloudModel(
                id: id,
                displayName: (item["name"] as? String) ?? (item["display_name"] as? String) ?? id,
                contextLength: number(item["context_window"]).map(Int.init) ?? 128_000,
                maximumOutputTokens: number(item["max_output_tokens"]).map(Int.init),
                supportsTools: true,
                supportsImages: (item["input_modalities"] as? [String])?.contains("image") == true,
                efforts: efforts, defaultEffort: defaultEffort.flatMap { efforts.contains($0) ? $0 : nil })
        }
    }

    private static let alibabaModels = [
        CloudModel(
            id: "qwen3.7-plus", displayName: "Qwen3.7 Plus", detail: "Coding Plan · images", contextLength: 1_000_000,
            supportsImages: true),
        CloudModel(
            id: "qwen3.6-plus", displayName: "Qwen3.6 Plus", detail: "Coding Plan · images", contextLength: 1_000_000,
            supportsImages: true),
        CloudModel(
            id: "kimi-k2.5", displayName: "Kimi K2.5", detail: "Coding Plan · images", contextLength: 262_144,
            supportsImages: true),
        CloudModel(id: "glm-5", displayName: "GLM-5", detail: "Coding Plan", contextLength: 202_752),
        CloudModel(id: "MiniMax-M2.5", displayName: "MiniMax M2.5", detail: "Coding Plan", contextLength: 196_608),
        CloudModel(
            id: "qwen3.5-plus", displayName: "Qwen3.5 Plus", detail: "Coding Plan · images", contextLength: 1_000_000,
            supportsImages: true),
    ]

    private static func openAIModels(baseAPI: URL, token: String, accountID: String?) async throws -> [CloudModel] {
        var components = URLComponents(url: baseAPI.appending(path: "models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "client_version", value: "0.166.0")]
        guard let url = components?.url else { throw CloudError.badResponse(.openAI) }
        let object = try await get(url, token: token, accountID: accountID, provider: .openAI)
        guard let data = object["models"] as? [[String: Any]] else { throw CloudError.badResponse(.openAI) }
        return data.compactMap { item in
            guard let id = item["slug"] as? String, !id.isEmpty,
                (item["visibility"] as? String) == "list", (item["supported_in_api"] as? Bool) ?? true,
                let context = number(item["context_window"]).map(Int.init), context > 0
            else { return nil }
            let levels = item["supported_reasoning_levels"] as? [[String: Any]] ?? []
            let efforts = levels.compactMap { $0["effort"] as? String }
            let defaultEffort = item["default_reasoning_level"] as? String
            return CloudModel(
                id: id, displayName: (item["display_name"] as? String) ?? id, detail: item["description"] as? String,
                contextLength: context, maximumContextLength: number(item["max_context_window"]).map(Int.init),
                supportsTools: true, supportsImages: (item["input_modalities"] as? [String])?.contains("image") == true,
                efforts: efforts, defaultEffort: defaultEffort.flatMap { efforts.contains($0) ? $0 : nil },
                useResponsesLite: (item["use_responses_lite"] as? Bool) ?? false)
        }
    }

    private static func kimiUsage(baseAPI: URL, token: String) async throws -> CloudQuota {
        let object = try await get(baseAPI.appending(path: "v1/usages"), token: token, provider: .kimi)
        let usages = object["usages"] as? [String: Any]
        func entry(_ key: String, id: String, title: String) -> CloudQuota.Entry? {
            guard let raw = usages?[key] as? [String: Any], let ratio = number(raw["used_ratio"]) else { return nil }
            return CloudQuota.Entry(
                id: id, title: title, usedRatio: ratio,
                resetAt: (raw["reset_time"] as? String).flatMap(isoDate))
        }
        let entries = [
            entry("limit_5h", id: "primary", title: String(localized: "5-hour window")),
            entry("limit_month_total", id: "monthly", title: String(localized: "This month"))
                ?? entry("limit_month_code", id: "monthly", title: String(localized: "This month")),
        ].compactMap { $0 }
        return CloudQuota(entries: entries)
    }

    private static func openAIUsage(token: String, accountID: String?) async throws -> CloudQuota {
        let object = try await get(
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!, token: token, accountID: accountID, provider: .openAI)
        let limits = object["rate_limit"] as? [String: Any] ?? [:]
        var entries: [CloudQuota.Entry] = []
        if let primary = limits["primary_window"] as? [String: Any] {
            entries.append(quotaEntry(id: "primary", fallback: String(localized: "5-hour window"), raw: primary))
        }
        if let secondary = limits["secondary_window"] as? [String: Any] {
            entries.append(quotaEntry(id: "secondary", fallback: String(localized: "This week"), raw: secondary))
        }
        let individual = (object["individual_limit"] as? [String: Any]) ?? (limits["individual_limit"] as? [String: Any])
        if let individual, let used = number(individual["used"]), let limit = number(individual["limit"]), limit > 0 {
            entries.append(
                CloudQuota.Entry(
                    id: "monthly", title: String(localized: "This month"), usedRatio: used / limit,
                    resetAt: date(individual["resets_at"] ?? individual["reset_at"])))
        }
        let plan = (object["plan_type"] as? String) ?? (limits["plan_type"] as? String)
        return CloudQuota(entries: entries, planName: plan.map { $0.replacingOccurrences(of: "_", with: " ").capitalized })
    }

    private static func quotaEntry(id: String, fallback: String, raw: [String: Any]) -> CloudQuota.Entry {
        let seconds = number(raw["limit_window_seconds"]).map(Int.init)
        let title =
            switch seconds {
            case 18_000: String(localized: "5-hour window")
            case 604_800: String(localized: "This week")
            default: fallback
            }
        let used = (number(raw["used_percent"]) ?? 0) / 100
        return CloudQuota.Entry(id: id, title: title, usedRatio: used, resetAt: date(raw["reset_at"]))
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        number(value).map { Date(timeIntervalSince1970: $0) }
    }

    private static func isoDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text)
    }

    private static func jwtClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func get(_ url: URL, token: String, accountID: String? = nil, provider: CloudProvider) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        if provider == .openAI { request.setValue("codex_cli_rs/0.166.0", forHTTPHeaderField: "User-Agent") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return try check(response, data: data, provider: provider)
    }

    private static func post(_ url: URL, json: [String: String], provider: CloudProvider) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try check(response, data: data, provider: provider)
    }

    private static func postForm(_ url: URL, fields: [String: String], provider: CloudProvider) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try check(response, data: data, provider: provider)
    }

    private static func check(_ response: URLResponse, data: Data, provider: CloudProvider) throws -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let message =
                (object?["error"] as? String) ?? ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? (object?["error_description"] as? String) ?? (object?["detail"] as? String)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
            if [401, 403].contains(http.statusCode) { throw CloudError.unauthorized(provider) }
            throw CloudError.http(provider, http.statusCode, message)
        }
        guard let object else { throw CloudError.badResponse(provider) }
        return object
    }
}
