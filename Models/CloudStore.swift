//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CloudStore {
    let provider: CloudProvider
    private let settings: AppSettings
    private let modelsDirectory: URL
    var onChange: () -> Void = {}

    private(set) var catalog: [CloudModel]
    private(set) var usage: CloudQuota?
    private(set) var balances: [DeepSeekBalance] = []
    private(set) var profile: CloudProfile?
    private(set) var isRefreshing = false
    private var serverExhausted = false
    var errorMessage: String?

    private(set) var signInCode: String?
    private(set) var signInURL: URL?
    private var signInTask: Task<Void, Never>?
    private var tokenTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    var isSigningIn: Bool { signInTask != nil }

    init(provider: CloudProvider, settings: AppSettings, modelsDirectory: URL) {
        self.provider = provider
        self.settings = settings
        self.modelsDirectory = modelsDirectory
        self.catalog = settings.cloudAccount(for: provider).modelSnapshot
    }

    private var configuration: CloudAccountConfiguration {
        get { settings.cloudAccount(for: provider) }
        set { settings.setCloudAccount(newValue, for: provider) }
    }

    private var tokens: CloudTokens? {
        get { configuration.tokens }
        set {
            var updated = configuration
            updated.tokens = newValue
            configuration = updated
        }
    }

    var isSignedIn: Bool { tokens != nil || (configuration.apiKey?.isEmpty == false) }
    var baseAPI: URL { provider.baseAPI(from: configuration.baseAPI) }
    var accountName: String? {
        if let profile { return profile.name }
        return isSignedIn ? String(localized: "Connected") : nil
    }

    func validToken() async throws -> String {
        if let tokens {
            if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
            let fresh = try await CloudClient.refresh(tokens, provider: provider, baseAPI: baseAPI)
            self.tokens = fresh
            writeToken(fresh.accessToken)
            return fresh.accessToken
        }
        if let key = configuration.apiKey, !key.isEmpty { return key }
        throw CloudError.unauthorized(provider)
    }

    func signIn() {
        guard provider.usesOAuth, signInTask == nil else { return }
        errorMessage = nil
        signInTask = Task {
            defer { self.signInTask = nil; self.signInCode = nil; self.signInURL = nil }
            do {
                let authorization = try await CloudClient.deviceAuthorization(for: provider, baseAPI: baseAPI)
                guard !Task.isCancelled else { return }
                signInCode = authorization.userCode
                signInURL = authorization.verificationURL
                NSWorkspace.shared.open(authorization.verificationURL)
                let deadline = Date().addingTimeInterval(authorization.expiresIn)
                while !Task.isCancelled, Date() < deadline {
                    try await Task.sleep(for: .seconds(authorization.interval))
                    guard !Task.isCancelled else { return }
                    switch try await CloudClient.pollDeviceToken(authorization) {
                    case .pending: continue
                    case .denied:
                        errorMessage = CloudError.denied.description
                        return
                    case .expired:
                        errorMessage = CloudError.expired.description
                        return
                    case .success(let fresh):
                        tokens = fresh
                        await refresh()
                        return
                    }
                }
                if !Task.isCancelled { errorMessage = CloudError.expired.description }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { errorMessage = "\(error)" }
            }
        }
    }

    func cancelSignIn() { signInTask?.cancel() }

    func signOut() {
        quotaTask?.cancel()
        tokenTask?.cancel()
        cancelSignIn()
        var updated = configuration
        updated.apiKey = nil
        updated.tokens = nil
        configuration = updated
        usage = nil
        balances = []
        profile = nil
        serverExhausted = false
        errorMessage = nil
        for id in installedIDs { removeModel(id) }
        onChange()
    }

    func setAPIKey(_ value: String) {
        quotaTask?.cancel()
        serverExhausted = false
        var updated = configuration
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.apiKey = key.isEmpty ? nil : key
        configuration = updated
        errorMessage = nil
        syncModels()
        onChange()
        Task { await refresh() }
    }

    func setBaseAPI(_ value: String) {
        guard provider.supportsCustomBaseAPI else { return }
        quotaTask?.cancel()
        serverExhausted = false
        var updated = configuration
        updated.baseAPI = value
        configuration = updated
        if let tokens, let host = provider.oauthHost(for: baseAPI), tokens.oauthHost != host { self.tokens = nil }
        syncModels()
        onChange()
        Task { await refresh() }
    }

    func isEnabled(_ model: CloudModel) -> Bool { configuration.enabledModels.contains(model.id) }

    func disable(_ model: ModelDescriptor) {
        let id = model.repoID.split(separator: "/").last.map(String.init) ?? model.repoID
        var updated = configuration
        updated.enabledModels = updated.enabledModels.filter { $0 != id }
        configuration = updated
        syncModels()
        onChange()
    }

    func setEnabled(_ enabled: Bool, for model: CloudModel) {
        var updated = configuration
        var ids = Set(updated.enabledModels)
        if enabled { ids.insert(model.id) } else { ids.remove(model.id) }
        updated.enabledModels = ids.sorted()
        configuration = updated
        syncModels()
        onChange()
    }

    func modelID(for model: CloudModel) -> String { directoryName(for: model.id) }

    func context(for model: CloudModel) -> Int {
        let maximum = model.maximumContextLength ?? model.contextLength
        let chosen = settings.modelContextTokens[directoryName(for: model.id)] ?? 0
        return chosen > 0 ? min(chosen, maximum) : model.contextLength
    }

    func setContext(_ tokens: Int, for model: CloudModel) {
        var map = settings.modelContextTokens
        map[directoryName(for: model.id)] = tokens > 0 ? tokens : nil
        settings.modelContextTokens = map
        onChange()
    }

    func effort(for model: CloudModel) -> String {
        settings.modelThinkingEffort[directoryName(for: model.id)] ?? model.defaultEffort ?? model.efforts.first ?? ""
    }

    func setEffort(_ effort: String, for model: CloudModel) {
        var map = settings.modelThinkingEffort
        map[directoryName(for: model.id)] = effort.isEmpty ? nil : effort
        settings.modelThinkingEffort = map
        onChange()
    }

    var isExhausted: Bool { exhaustedEntry != nil || (provider.showsBalance && !balances.isEmpty && balances.allSatisfy { $0.total <= 0 }) }
    var exhaustedEntry: CloudQuota.Entry? {
        if let entry = usage?.entries.first(where: { $0.usedRatio >= 1 && ($0.resetAt.map { $0 > .now } ?? true) }) {
            return entry
        }
        let reset = usage?.entries.compactMap(\.resetAt).filter { $0 > .now }.min()
        return serverExhausted ? CloudQuota.Entry(id: "server", title: provider.title, usedRatio: 1, resetAt: reset) : nil
    }

    func markQuotaExhausted() {
        guard !serverExhausted else { return }
        serverExhausted = true
        scheduleQuotaRefresh()
        onChange()
    }

    var exhaustedText: String {
        if provider.showsBalance { return String(localized: "The DeepSeek balance is empty. Top it up to continue.") }
        guard let reset = exhaustedEntry?.resetAt else {
            return String(localized: "The \(provider.title) quota is exhausted.")
        }
        return String(localized: "The \(provider.title) quota is exhausted. Resets \(reset.formatted(date: .abbreviated, time: .shortened)).")
    }

    func refresh() async {
        guard !isRefreshing, isSignedIn else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            scheduleQuotaRefresh()
        }
        do {
            switch provider {
            case .alibaba:
                catalog = try await CloudClient.models(provider: provider, baseAPI: baseAPI, token: "")
            case .deepSeek:
                let token = try await validToken()
                async let models = CloudClient.models(provider: provider, baseAPI: baseAPI, token: token)
                async let currentBalances = try? CloudClient.balance(baseAPI: baseAPI, token: token)
                catalog = try await models
                if let currentBalances = await currentBalances { balances = currentBalances }
            case .kimi, .openAI:
                let token = try await validToken()
                let accountID = tokens?.accountID
                async let models = CloudClient.models(provider: provider, baseAPI: baseAPI, token: token, accountID: accountID)
                async let currentUsage = try? CloudClient.usage(provider: provider, baseAPI: baseAPI, token: token, accountID: accountID)
                async let currentProfile = try? CloudClient.profile(
                    provider: provider, baseAPI: baseAPI, token: token, tokens: tokens)
                catalog = try await models
                if let currentUsage = await currentUsage {
                    usage = currentUsage
                    serverExhausted = false
                }
                if var currentProfile = await currentProfile {
                    currentProfile.planName = usage?.planName ?? currentProfile.planName
                    profile = currentProfile
                }
            }
            errorMessage = nil
            syncModels()
            onChange()
        } catch CloudError.unauthorized(_) {
            if provider.usesOAuth { tokens = nil }
            errorMessage = CloudError.unauthorized(provider).description
            onChange()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func start() {
        syncModels()
        onChange()
        Task { await refresh() }
        guard provider.usesOAuth else { return }
        tokenTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                if self?.tokens != nil { _ = try? await self?.validToken() }
            }
        }
    }

    func stop() {
        tokenTask?.cancel()
        quotaTask?.cancel()
        cancelSignIn()
    }

    private func scheduleQuotaRefresh() {
        quotaTask?.cancel()
        quotaTask = nil
        guard serverExhausted || exhaustedEntry != nil else { return }
        let delay = exhaustedEntry?.resetAt.map { max(1, $0.timeIntervalSinceNow + 1) } ?? 600
        quotaTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private var installedIDs: [String] {
        let fm = FileManager.default
        let prefix = provider.rawValue + "--"
        let dirs = (try? fm.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)) ?? []
        return dirs.map(\.lastPathComponent).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private func directoryName(for id: String) -> String {
        provider.rawValue + "--" + id.replacingOccurrences(of: "/", with: "--")
    }

    private func syncModels() {
        let enabled = configuration.enabledModels
        let known = catalog + configuration.modelSnapshot
        var used: [CloudModel] = []
        for id in enabled {
            guard let model = known.first(where: { $0.id == id }) else { continue }
            used.append(model)
            install(model)
        }
        var updated = configuration
        updated.modelSnapshot = used
        configuration = updated
        for id in installedIDs where !enabled.contains(id) { removeModel(id) }
    }

    private func install(_ model: CloudModel) {
        let name = directoryName(for: model.id)
        let directory = modelsDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let headers = tokens?.accountID.map { ["ChatGPT-Account-Id": $0] }
            try RemoteEndpoint(
                baseURL: baseAPI, model: model.id, headers: headers,
                responsesLite: provider.usesResponsesAPI ? model.useResponsesLite : nil,
                maximumOutputTokens: model.maximumOutputTokens
            ).save(to: directory)
            try ModelManifest(
                repoID: "\(provider.rawValue)/\(model.id)", revision: "", source: provider.source,
                kind: model.supportsImages ? .vlm : .llm, files: [], contextLength: model.contextLength,
                supportsTools: model.supportsTools
            ).save(to: directory)
            if let token = validTokenSync() { RemoteTokens.set(token, for: name) }
        } catch {
            print("could not install \(model.id): \(error.localizedDescription)")
        }
    }

    private func validTokenSync() -> String? {
        if let tokens, tokens.expiresAt.timeIntervalSinceNow > 0 { return tokens.accessToken }
        return configuration.apiKey
    }

    private func removeModel(_ id: String) {
        let name = directoryName(for: id)
        RemoteTokens.set(nil, for: name)
        try? FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent(name))
    }

    private func writeToken(_ token: String) {
        for id in installedIDs { RemoteTokens.set(token, for: directoryName(for: id)) }
    }
}
