//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// Model selection, availability and generation settings.
extension AppContainer {
    func refreshModels() async {
        var list = await catalog.refresh()
        // Attach a standalone drafter to its model or hide it.
        if await attachStrayDrafters(in: list) { list = await catalog.refresh() }
        let strays = await Self.drafterFolders(in: list)
        strayDrafters = strays
        list = list.filter { model in !strays.contains { $0.id == model.id } }
        models = list
        checkpointSampling = Dictionary(
            uniqueKeysWithValues: list.compactMap { model in
                let sampling = ModelDefaults.sampling(in: model.directory)
                return sampling == SamplingParams() ? nil : (model.id, sampling)
            })
        applyConversationConfiguration()
        fillInBaseModels(list)
        brokenModels = await catalog.brokenModels
        if settings.activeModelID == nil || !list.contains(where: { $0.id == settings.activeModelID }) {
            setActiveModel(list.first)
        }
    }

    func checkModelAvailability(force: Bool = false) {
        let remotes = models.filter { $0.source.isRemote && CloudProvider(source: $0.source)?.checksAvailability != false }
        guard availabilityTask == nil else { return }
        guard !remotes.isEmpty else { return unavailableModelIDs = [] }
        if !force, let last = lastAvailabilityCheck, last.duration(to: .now) < .seconds(30) { return }
        let targets = remotes.compactMap { model in (try? RemoteEndpoint.load(from: model.directory)).map { (model, $0) } }
        availabilityTask = Task {
            defer { availabilityTask = nil }
            // nil probe = up but refused; else what it serves now.
            let results = await withTaskGroup(of: (ModelDescriptor, RemoteEndpoint, RemoteEngine.Probe?, up: Bool).self) { group in
                for (model, endpoint) in targets {
                    group.addTask {
                        do {
                            let probe = try await RemoteEngine.probe(
                                baseURL: endpoint.baseURL, model: endpoint.model, token: RemoteTokens.token(for: model.id),
                                headers: endpoint.headers)
                            print(
                                "remote \(model.repoID): server serves \(probe.model)")
                            return (model, endpoint, probe, true)
                        } catch RemoteError.http(let status, _) where status == 401 || status == 403 {
                            print("remote \(model.repoID): up, but refused the check (\(status))")
                            return (model, endpoint, nil, true)
                        } catch {
                            print(
                                "remote \(model.repoID): unreachable — \(String(describing: error))")
                            return (model, endpoint, nil, false)
                        }
                    }
                }
                var all: [(ModelDescriptor, RemoteEndpoint, RemoteEngine.Probe?, up: Bool)] = []
                for await result in group { all.append(result) }
                return all
            }
            unavailableModelIDs = Set(results.filter { !$0.up }.map(\.0.id))
            var changed = false
            // Only user-added servers are renamed from probe results.
            for (model, endpoint, probe, _) in results where model.source == .remote {
                if let probe, updateRemote(model, endpoint: endpoint, probe: probe) { changed = true }
            }
            if changed { await refreshModels() }
            lastAvailabilityCheck = .now
        }
    }

    private func updateRemote(_ model: ModelDescriptor, endpoint: RemoteEndpoint, probe: RemoteEngine.Probe) -> Bool {
        let repoID = "\(endpoint.hostAndPort)/\(probe.model)"
        let kind: ModelKind = probe.supportsVision ? .vlm : .llm
        let contextLength = probe.contextLength ?? model.contextLength
        let same =
            probe.model == endpoint.model && repoID == model.repoID && kind == model.kind && contextLength == model.contextLength
        guard !same, var manifest = try? ModelManifest.load(from: model.directory) else { return false }
        var updated = endpoint
        updated.model = probe.model
        manifest.repoID = repoID
        manifest.kind = kind
        manifest.contextLength = contextLength
        if probe.supportsTools { manifest.supportsTools = true }
        do {
            try updated.save(to: model.directory)
            try manifest.save(to: model.directory)
        } catch {
            print("Could not update remote model \(model.id): \(error)")
            return false
        }
        print("remote \(model.repoID): renamed to \(repoID)")
        if engineState.modelID == model.id { Task { await engineManager.unload() } }
        return true
    }

    func isAvailable(_ model: ModelDescriptor) -> Bool { !unavailableModelIDs.contains(model.id) }
    var isCheckingAvailability: Bool { availabilityTask != nil }

    func chooseModel(_ model: ModelDescriptor, chatID: UUID? = nil) {
        setActiveModel(model)
        let chatIDs = chatID.map { Set([$0]) } ?? Set([panelChatID, windowChatID].compactMap { $0 })
        Task {
            for id in chatIDs {
                guard var chat = try? await chatStore.chat(id: id), chat.modelID != model.id else { continue }
                if await chatFits(chat, in: model) {
                    chat.modelID = model.id
                    try? await chatStore.update(chat)
                } else {
                    // The conversation outgrew this model's window: continue in a fresh chat.
                    if let fresh = try? await conversation.newChat(origin: chat.origin, modelID: model.id) {
                        setActiveChat(fresh.id)
                    }
                }
            }
        }
    }

    private func chatFits(_ chat: Chat, in model: ModelDescriptor) async -> Bool {
        guard let limit = contextTokens(for: model) else { return true }
        let messages = (try? await chatStore.messages(chatID: chat.id)) ?? []
        let used = ConversationService.contextEstimate(
            chat: chat, history: messages, streamingText: "", input: "",
            toolSpecs: model.supportsTools ? toolSpecs : [], codingContext: await conversation.codingContext(for: chat.id),
            preferredLanguage: settings.preferredLanguage,
            codingDynamicContext: await conversation.codingDynamicContext(for: chat.id))
        return used <= limit
    }

    func setActiveModel(_ model: ModelDescriptor?) {
        settings.activeModelID = model?.id
        Task { await conversation.setActiveModel(id: model?.id) }
        if let model, engineState.modelID != nil, engineState.modelID != model.id {
            Task {
                await engineManager.unloadLocal()
                keepModelLoadedIfPinned()
            }
        } else {
            keepModelLoadedIfPinned()
        }
    }

    func deleteModel(_ model: ModelDescriptor) {
        if model.source.isRemote { RemoteTokens.set(nil, for: model.id) }
        for provider in CloudProvider.allCases where provider.source == model.source {
            cloudStore(for: provider).disable(model)
        }
        Task {
            if engineState.modelID == model.id { await engineManager.unload() }
            try? await catalog.remove(id: model.id)
            await refreshModels()
        }
    }

    func connectRemote(model: String, address: String, token: String) async throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmed.contains("://") ? trimmed : "http://" + trimmed), base.host() != nil else {
            throw RemoteError.badAddress
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = try await RemoteEngine.probe(
            baseURL: base, model: model.trimmingCharacters(in: .whitespacesAndNewlines), token: token.isEmpty ? nil : token)
        let endpoint = RemoteEndpoint(baseURL: base, model: probe.model)
        let directory = paths.models.appendingPathComponent(endpoint.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try endpoint.save(to: directory)
        RemoteTokens.set(token, for: endpoint.directoryName)
        // Write the manifest last so watchers never see a partial model.
        try ModelManifest(
            repoID: "\(endpoint.hostAndPort)/\(probe.model)", revision: "", source: .remote, kind: probe.supportsVision ? .vlm : .llm,
            files: [], contextLength: probe.contextLength, supportsTools: probe.supportsTools
        ).save(to: directory)
        await refreshModels()
    }

    func redownload(_ broken: ModelCatalog.BrokenModel) {
        guard let reference = ModelReference(directoryName: broken.id) else { return }
        download(reference)
    }

    func deleteBroken(_ broken: ModelCatalog.BrokenModel) {
        Task {
            try? await catalog.removeBroken(broken)
            await refreshModels()
        }
    }

    // Generation settings

    func setIdleTimeout(_ seconds: TimeInterval) {
        settings.idleUnloadSeconds = seconds
        Task {
            await engineManager.setConfiguration(.init(idleUnloadSeconds: seconds))
            keepModelLoadedIfPinned()
        }
    }

    func setContextTokens(_ tokens: Int, for model: ModelDescriptor) {
        var map = settings.modelContextTokens
        map[model.id] = tokens > 0 ? tokens : nil
        settings.modelContextTokens = map
        applyConversationConfiguration()
    }

    func defaultTemperature(for model: ModelDescriptor) -> (value: Double, fromModel: Bool)? {
        if model.source == .remote { return nil }
        if let value = checkpointSampling[model.id]?.temperature { return (value, true) }
        return MLXEngine.librarySampling.temperature.map { ($0, false) }
    }

    func temperature(for model: ModelDescriptor) -> Double? {
        model.source == .remote ? nil : settings.modelTemperatures[model.id]
    }

    func setTemperature(_ value: Double?, for model: ModelDescriptor) {
        var map = settings.modelTemperatures
        map[model.id] = value
        settings.modelTemperatures = map
        applyConversationConfiguration()
    }

    func contextTokens(for model: ModelDescriptor) -> Int? {
        guard model.source != .remote, let chosen = settings.modelContextTokens[model.id], chosen > 0 else { return model.contextLength }
        return model.contextLength.map { min(chosen, $0) } ?? chosen
    }

    func apiDefaults(for model: ModelDescriptor) -> APIModelDefaults {
        let speculates = settings.speculativeModels.contains(model.id)
        var sampling = checkpointSampling[model.id] ?? SamplingParams()
        if let chosen = temperature(for: model) { sampling.temperature = chosen }
        if model.source.isCloud { sampling.maxTokens = outputTokenLimit(for: model) }
        if speculates, settings.greedyDrafters.contains(model.id) { sampling.temperature = 0 }
        return APIModelDefaults(
            contextTokens: contextTokens(for: model), sampling: sampling, thinks: settings.reasoningShown.contains(model.id),
            thinkingEffort: settings.modelThinkingEffort[model.id], speculates: speculates)
    }

    func applyConversationConfiguration() {
        var config = ConversationService.Configuration(maxToolIterations: settings.toolIterations)
        config.contextTokensByModel = settings.modelContextTokens
        config.temperatureByModel = settings.modelTemperatures
        config.outputTokensByModel = settings.modelOutputTokens
        config.checkpointSamplingByModel = checkpointSampling
        config.speculativeModelIDs = Set(settings.speculativeModels)
        config.greedyModelIDs = Set(settings.greedyDrafters)
        config.reasoningModelIDs = Set(settings.reasoningShown)
        config.thinkingEffortByModel = settings.modelThinkingEffort
        config.preferredLanguage = settings.preferredLanguage
        let projects = codingProjects
        let appSettings = settings
        config.codingContext = { chatID in
            let allowed = await MainActor.run { appSettings.allowedFolders }
            return await projects.context(for: chatID, allowedFolders: allowed)
        }
        config.codingDynamicContext = { chatID in
            let allowed = await MainActor.run { appSettings.allowedFolders }
            return await projects.dynamicContext(for: chatID, allowedFolders: allowed)
        }
        config.codingNeedsVerification = { chatID in await projects.needsVerification(chatID: chatID) }
        Task { await conversation.setConfiguration(config) }
    }

    func setPreferredLanguage(_ language: String) {
        settings.preferredLanguage = language
        applyConversationConfiguration()
    }

    func unloadNow() { Task { await engineManager.unload() } }

    func keepModelLoadedIfPinned() {
        guard settings.idleUnloadSeconds == 0, let model = activeModel, engineState.modelID != model.id else { return }
        Task { await engineManager.prewarm(model) }
    }

    func fit(for model: ModelDescriptor) -> ModelFitReport {
        ModelFitReport.evaluate(
            modelBytes: model.sizeBytes, contextLength: model.contextLength, hardware: hardware, kvCache: model.kvCache,
            availableBytes: HardwareProfile.availableMemoryBytes(), chosenContext: settings.modelContextTokens[model.id])
    }

    static let outputTokenLimits = [4_096, 8_192, 16_384, 32_768]

    func outputTokenLimit(for model: ModelDescriptor) -> Int {
        ConversationService.cloudOutputBudget(configured: settings.modelOutputTokens[model.id])
    }

    func outputTokenLimit(forModelID id: String) -> Int {
        ConversationService.cloudOutputBudget(configured: settings.modelOutputTokens[id])
    }

    func setOutputTokenLimit(_ tokens: Int, forModelID id: String) {
        var map = settings.modelOutputTokens
        map[id] = tokens == ConversationService.defaultCloudOutputTokens ? nil : tokens
        settings.modelOutputTokens = map
        applyConversationConfiguration()
    }

    func replyLimit(forModel id: String) -> Int? {
        guard let model = models.first(where: { $0.id == id }) else { return nil }
        if model.source.isCloud { return outputTokenLimit(for: model) }
        guard let context = contextTokens(for: model) ?? model.contextLength else { return nil }
        return ConversationService.replyBudget(context: context, atLeast: ConversationService.Configuration().reservedTokensForReply)
    }

    func showsReasoning(modelID: String) -> Bool { settings.reasoningShown.contains(modelID) }

    func toggle(_ id: String, in keyPath: ReferenceWritableKeyPath<AppSettings, [String]>, on: Bool) {
        var ids = Set(settings[keyPath: keyPath])
        if on { ids.insert(id) } else { ids.remove(id) }
        settings[keyPath: keyPath] = Array(ids).sorted()
    }

    func setShowsReasoning(_ shown: Bool, for model: ModelDescriptor) {
        setShowsReasoning(shown, forModelID: model.id)
    }

    func setShowsReasoning(_ shown: Bool, forModelID id: String) {
        toggle(id, in: \.reasoningShown, on: shown)
        applyConversationConfiguration()
    }

    // Backfill `baseModel` for older downloads.

    func fillInBaseModels(_ list: [ModelDescriptor]) {
        let missing = list.filter { $0.baseModel == nil && !$0.source.isRemote && baseModelLookups.insert($0.id).inserted }
        guard !missing.isEmpty else { return }
        let (hub, modelScope) = (hubClient, modelScopeClient)
        Task {
            var changed = false
            for model in missing {
                let base: String? =
                    switch ModelReference.parse(model.repoID) {
                    case .huggingFace(let id): (try? await hub.info(repoID: id)).flatMap { ModelOwners.baseModel(fromTags: $0.tags ?? []) }
                    case .modelScope(let id): (try? await modelScope.info(repoID: id))?.baseModel
                    case nil: nil
                    }
                guard let base, var manifest = try? ModelManifest.load(from: model.directory) else { continue }
                manifest.baseModel = base
                if (try? manifest.save(to: model.directory)) != nil { changed = true }
            }
            if changed { await refreshModels() }
        }
    }
}
