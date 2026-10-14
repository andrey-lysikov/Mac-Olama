//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Observation
import os

// AppContainer

@MainActor
@Observable
final class AppContainer {
    let paths: AppPaths
    let settings: AppSettings
    let catalog: ModelCatalog
    let engineManager: EngineManager
    let chatStore: any ChatStore
    let conversation: ConversationService
    let hardware: HardwareProfile
    private(set) var hubClient: HubClient
    let modelScopeClient = ModelScopeClient()
    private(set) var downloader: ModelDownloader
    private(set) var updates: UpdateChecker!
    let logger = Logger(subsystem: "ru.lysnet.macolama", category: "container")

    // UI mirror
    private(set) var engineState: EngineState = .unloaded
    private(set) var models: [ModelDescriptor] = []
    private(set) var brokenModels: [ModelCatalog.BrokenModel] = []
    private(set) var apiStatus: APIStatus = .disabled
    private(set) var downloads: [ActiveDownload] = [] { didSet { persistDownloads() } }
    enum Section: Equatable { case chat, models, settings, about }
    var section: Section = .chat
    var tokenPromptRequested = false
    var panelChatID: UUID?
    private(set) var answersFinished = 0
    var windowChatID: UUID?
    var requestedWindowChatID: UUID?

    var liveProgress: [UUID: GenerationProgress] = [:]
    let draft = ComposerDraft()

    func openInChats(_ chatID: UUID?) {
        section = .chat
        requestedWindowChatID = chatID
        WindowManager.shared.open(.chats)
    }
    private(set) var unavailableModelIDs: Set<String> = []
    private var lastAvailabilityCheck: ContinuousClock.Instant?
    private var availabilityTask: Task<Void, Never>?
    var activeModel: ModelDescriptor? { models.first { $0.id == settings.activeModelID } }
    var modelsBySource: [(source: ModelSource, models: [ModelDescriptor])] {
        ModelSource.allCases.compactMap { src in
            let list = models.filter { $0.source == src }
            return list.isEmpty ? nil : (src, list)
        }
    }

    enum APIStatus: Equatable {
        case disabled, starting
        case running(port: Int)
        case portBusy(port: Int)
    }

    struct ActiveDownload: Identifiable, Equatable {
        enum Phase: Equatable { case queued, running, paused, finished, failed(String), needsToken, needsAccess }
        var id: String { repoID }
        var repoID: String
        // Display metadata for the download row.
        var title: String?
        var quantization: String?
        var sizeBytes: Int64?
        var progress: DownloadProgress?
        var phase: Phase = .queued
        var drafterFor: String?
        var error: String? { if case .failed(let message) = phase { message } else { nil } }
        var finished: Bool { phase == .finished }
        var isRunning: Bool { phase == .running }
        var isActive: Bool { phase == .queued || phase == .running || phase == .paused }
    }

    struct StoreFailure: Equatable {
        var message: String
        var backup: URL?
        var recovered = false
    }

    let storeFailure: StoreFailure?

    private var apiServer: APIServer?
    private var apiRestartTask: Task<Void, Never>?
    private var apiGeneration = 0
    private(set) var apiPortBusy = false
    private var stateTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloaderNeedsRebuild = false
    private var persistedDownloads: [StoredDownload] = []

    private struct StoredDownload: Codable, Equatable {
        var repoID: String
        var title: String?
        var quantization: String?
        var sizeBytes: Int64?
        var paused: Bool
        var drafterFor: String?
    }

    init() {
        let paths = AppPaths.standard()
        try? paths.createAll()
        self.paths = paths
        self.settings = AppSettings()
        self.hardware = HardwareProfile.current(recommendedWorkingSetBytes: MLXEngine.recommendedWorkingSetBytes())
        self.catalog = ModelCatalog(modelsDirectory: paths.models)
        self.engineManager = EngineManager(
            engine: RoutingEngine(local: MLXEngine(), remote: RemoteEngine()),
            configuration: .init(idleUnloadSeconds: settings.idleUnloadSeconds))

        let store: any ChatStore
        do {
            store = try SwiftDataChatStore(directory: paths.database)
            self.storeFailure = nil
        } catch {
            logger.error("Chat store failed to open: \(error)")
            // Move the broken files aside and retry with a fresh database; memory is the last resort.
            let backup = SwiftDataChatStore.backUpStore(in: paths.database)
            if backup != nil, let fresh = try? SwiftDataChatStore(directory: paths.database) {
                store = fresh
                self.storeFailure = StoreFailure(message: error.localizedDescription, backup: backup, recovered: true)
            } else {
                self.storeFailure = StoreFailure(message: error.localizedDescription, backup: backup, recovered: false)
                store = InMemoryChatStore()
            }
        }
        self.chatStore = store
        self.conversation = ConversationService(
            engineManager: engineManager, store: store, catalog: catalog, attachmentsDirectory: paths.attachments,
            activeChatID: settings.activeChatID, activeModelID: settings.activeModelID
        )
        let client = HubClient(token: settings.huggingFaceToken)
        self.hubClient = client
        self.downloader = ModelDownloader(client: client, paths: paths)
        self.updates = UpdateChecker(container: self)
    }

    func start() {
        stateTask = Task { [engineManager] in
            for await state in await engineManager.states() { self.engineState = state }
        }
        watcher = DirectoryWatcher(url: paths.models) { [weak self] in Task { await self?.refreshModels() } }
        Task {
            await refreshModels()
            updateTools()
            applyConversationConfiguration()
            keepModelLoadedIfPinned()
            restoreDownloads()
            removeOrphanedStaging()
            checkModelAvailability(force: true)
            applyDownloadLimits()
            restartAPI()
            updates.start()
        }
        // Re-check remote servers after wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkModelAvailability(force: true) }
        }
    }

    func shutdown() {
        stateTask?.cancel()
        watcher = nil
        apiServer?.stop()
        updates.stop()
        Task { await engineManager.unload() }
    }

    // Models

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
        let remotes = models.filter { $0.source == .remote }
        guard availabilityTask == nil else { return }
        guard !remotes.isEmpty else { return unavailableModelIDs = [] }
        if !force, let last = lastAvailabilityCheck, last.duration(to: .now) < .seconds(30) { return }
        let targets = remotes.compactMap { model in (try? RemoteEndpoint.load(from: model.directory)).map { (model, $0) } }
        availabilityTask = Task {
            defer { availabilityTask = nil }
            // nil probe = up but refused; else what it serves now.
            let results = await withTaskGroup(of: (ModelDescriptor, RemoteEndpoint, RemoteEngine.Probe?, up: Bool).self) { group in
                let logger = logger  // captured for the task group
                for (model, endpoint) in targets {
                    group.addTask {
                        // Probe with the token; a refusal still means the server is up.
                        do {
                            let probe = try await RemoteEngine.probe(
                                baseURL: endpoint.baseURL, model: endpoint.model, token: RemoteTokens.token(for: model.id))
                            logger.info(
                                "remote \(model.repoID, privacy: .public): server serves \(probe.model, privacy: .public)")
                            return (model, endpoint, probe, true)
                        } catch RemoteError.http(let status, _) where status == 401 || status == 403 {
                            logger.info("remote \(model.repoID, privacy: .public): up, but refused the check (\(status))")
                            return (model, endpoint, nil, true)
                        } catch {
                            logger.info(
                                "remote \(model.repoID, privacy: .public): unreachable — \(String(describing: error), privacy: .public)")
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
            for (model, endpoint, probe, _) in results {
                if let probe, updateRemote(model, endpoint: endpoint, probe: probe) { changed = true }
            }
            if changed { await refreshModels() }
            lastAvailabilityCheck = .now
        }
    }

    private func updateRemote(_ model: ModelDescriptor, endpoint: RemoteEndpoint, probe: RemoteEngine.Probe) -> Bool {
        let repoID = "\(endpoint.hostAndPort)/\(probe.model)"
        let kind: ModelKind = probe.supportsVision ? .vlm : .llm
        // Keep old values for fields `/props` omits.
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
            logger.error("Could not update remote model \(model.id): \(error)")
            return false
        }
        logger.info("remote \(model.repoID, privacy: .public): renamed to \(repoID, privacy: .public)")
        if engineState.modelID == model.id { Task { await engineManager.unload() } }  // reconnect with the new model on next question
        return true
    }

    func isAvailable(_ model: ModelDescriptor) -> Bool { !unavailableModelIDs.contains(model.id) }
    var isCheckingAvailability: Bool { availabilityTask != nil }

    func answerFinished(_ message: Message) {
        guard !message.isPartial else { return }  // stopped by the user, who is looking at it
        answersFinished += 1
    }

    func chooseModel(_ model: ModelDescriptor) {
        setActiveModel(model)
        let chatIDs = Set([panelChatID, windowChatID].compactMap { $0 })
        Task {
            for id in chatIDs {
                guard var chat = try? await chatStore.chat(id: id), chat.modelID != model.id else { continue }
                chat.modelID = model.id
                try? await chatStore.update(chat)
            }
        }
    }

    func setActiveModel(_ model: ModelDescriptor?) {
        settings.activeModelID = model?.id
        Task { await conversation.setActiveModel(id: model?.id) }
        if let model, engineState.modelID != nil, engineState.modelID != model.id {
            Task {
                await engineManager.unload()
                keepModelLoadedIfPinned()
            }
        } else {
            keepModelLoadedIfPinned()
        }
    }

    func deleteModel(_ model: ModelDescriptor) {
        if model.source == .remote { RemoteTokens.set(nil, for: model.id) }
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

    func setActiveChat(_ id: UUID?) {
        settings.activeChatID = id
        Task { await conversation.setActiveChat(id: id) }
    }

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
        // Greedy-only drafter forces the temperature.
        if speculates, settings.greedyDrafters.contains(model.id) { sampling.temperature = 0 }
        return APIModelDefaults(
            contextTokens: contextTokens(for: model), sampling: sampling, thinks: settings.reasoningShown.contains(model.id),
            speculates: speculates)
    }

    private func applyConversationConfiguration() {
        var config = ConversationService.Configuration(maxToolIterations: settings.toolIterations)
        config.contextTokensByModel = settings.modelContextTokens
        config.temperatureByModel = settings.modelTemperatures
        config.checkpointSamplingByModel = checkpointSampling
        config.speculativeModelIDs = Set(settings.speculativeModels)
        config.greedyModelIDs = Set(settings.greedyDrafters)
        config.reasoningModelIDs = Set(settings.reasoningShown)
        config.preferredLanguage = settings.preferredLanguage
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

    // Downloads (shared by the download window, menu, notifications and the update checker)

    func download(repoID: String, title: String? = nil, quantization: String? = nil, sizeBytes: Int64? = nil) {
        guard let ref = ModelReference.parse(repoID) else { return }
        download(ref, title: title, quantization: quantization, sizeBytes: sizeBytes)
    }

    func download(_ reference: ModelReference, title: String? = nil, quantization: String? = nil, sizeBytes: Int64? = nil) {
        enqueue(ActiveDownload(repoID: reference.repoID, title: title, quantization: quantization, sizeBytes: sizeBytes))
    }

    private func enqueue(_ download: ActiveDownload) {
        guard downloaderIsIdle(repoID: download.repoID) else { return }
        downloads.removeAll { $0.repoID == download.repoID }
        downloads.append(download)
        startNextDownloadIfIdle()
    }

    // Persistence: a download interrupted by quitting the app continues on the next launch.

    private func persistDownloads() {
        let stored = downloads.filter { !$0.finished }.map {
            // Restored downloads come back paused unless active.
            StoredDownload(
                repoID: $0.repoID, title: $0.title, quantization: $0.quantization, sizeBytes: $0.sizeBytes,
                paused: !($0.phase == .running || $0.phase == .queued), drafterFor: $0.drafterFor)
        }
        guard stored != persistedDownloads else { return }
        persistedDownloads = stored
        settings.pendingDownloads = try? JSONEncoder().encode(stored)
    }

    private func restoreDownloads() {
        guard downloads.isEmpty, let data = settings.pendingDownloads,
            let stored = try? JSONDecoder().decode([StoredDownload].self, from: data)
        else { return }
        let installed = Set(models.map { $0.repoID.lowercased() })
        downloads = stored.filter { !installed.contains($0.repoID.lowercased()) }.map {
            ActiveDownload(
                repoID: $0.repoID, title: $0.title, quantization: $0.quantization, sizeBytes: $0.sizeBytes,
                phase: $0.paused ? .paused : .queued, drafterFor: $0.drafterFor)
        }
        startNextDownloadIfIdle()
    }

    private func removeOrphanedStaging() {
        let fm = FileManager.default
        let wanted = Set(downloads.compactMap { ModelReference.parse($0.repoID)?.directoryName })
        let folders = (try? fm.contentsOfDirectory(at: paths.downloads, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !wanted.contains(folder.lastPathComponent) {
            let files = (fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL]) ?? []
            let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } / (1 << 20)
            do {
                try fm.removeItem(at: folder)
                logger.info("dropped an abandoned download: \(folder.lastPathComponent, privacy: .public), \(size) MB freed")
            } catch {
                logger.error("could not drop \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            }
        }
    }

    var orderedDownloads: [ActiveDownload] {
        func rank(_ d: ActiveDownload) -> Int {
            switch d.phase {
            case .running: 0
            case .paused: 1
            case .queued: 2
            case .failed, .needsToken, .needsAccess: 3
            case .finished: 4
            }
        }
        return downloads.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    private func startNextDownloadIfIdle() {
        rebuildDownloaderIfIdle()
        // Start nothing while any transfer task is still winding down.
        guard downloadTasks.isEmpty, !downloads.contains(where: \.isRunning),
            let next = downloads.firstIndex(where: { $0.phase == .queued }),
            let reference = ModelReference.parse(downloads[next].repoID)
        else { return }
        downloads[next].phase = .running
        run(reference, drafterFor: downloads[next].drafterFor)
    }

    private func run(_ reference: ModelReference, drafterFor: String?) {
        let repoID = reference.repoID
        let destination = drafterFor.flatMap { target in models.first { $0.repoID == target } }
            .map { MTPDrafter.directory(forModel: $0.directory) }
        if drafterFor != nil, destination == nil {
            downloads.removeAll { $0.repoID == repoID }
            return
        }
        downloadTasks[repoID] = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in await self.downloader.download(reference, into: destination) {
                    guard let i = self.downloads.firstIndex(where: { $0.repoID == repoID }) else { break }
                    switch event {
                    case .progress(let p): self.downloads[i].progress = p
                    case .finished(let model):
                        self.downloads.removeAll { $0.repoID == repoID }
                        if let target = drafterFor, let folder = destination {
                            await self.finishDrafter(at: folder, repoID: repoID, modelRepoID: target)
                            break
                        }
                        // The model now appears in the installed list, so its download row has done its job.
                        await self.refreshModels()
                        if self.settings.activeModelID == nil { self.setActiveModel(model) }
                        self.notifyAboutDownload(
                            title: String(localized: "Model downloaded"), body: String(localized: "\(model.name) is ready to use."),
                            category: .downloadFinished)
                    case .resolved, .fileFinished: break
                    }
                }
            } catch {
                // Pause and cancel both stop; partial files are kept.
                if let i = self.downloads.firstIndex(where: { $0.repoID == repoID }), self.downloads[i].phase == .running {
                    if case HubError.gatedRepositoryRequiresToken = error {
                        self.downloads[i].phase = self.hubClient.token == nil ? .needsToken : .needsAccess
                        if self.downloads[i].phase == .needsToken { self.tokenPromptRequested = true }
                    } else {
                        self.downloads[i].phase = .failed(Self.describe(error))
                    }
                    if case HubError.cancelled = error {
                    } else {
                        self.notifyAboutDownload(
                            title: String(localized: "Download failed"), body: "\(repoID): \(Self.describe(error))")
                    }
                }
            }
            self.downloadTasks[repoID] = nil
            self.startNextDownloadIfIdle()
        }
    }

    private func notifyAboutDownload(title: String, body: String, category: NotificationService.Category = .info) {
        guard !(section == .models && WindowManager.shared.isOpen(.chats)) else { return }
        NotificationService.shared.send(title: title, body: body, category: category)
    }

    // MTP drafters installed next to their models.

    private var checkpointSampling: [String: SamplingParams] = [:]

    private(set) var strayDrafters: [ModelDescriptor] = []

    private static func drafterFolders(in list: [ModelDescriptor]) async -> [ModelDescriptor] {
        var found: [ModelDescriptor] = []
        for model in list where model.source != .remote {
            if await MTPDrafter.isDrafter(directory: model.directory) { found.append(model) }
        }
        return found
    }

    private func attachStrayDrafters(in list: [ModelDescriptor]) async -> Bool {
        let strays = await Self.drafterFolders(in: list)
        guard !strays.isEmpty else { return false }
        let chatModels = list.filter { model in model.source != .remote && !strays.contains { $0.id == model.id } }
        var moved = false
        for drafter in strays {
            // Drafter name derived from its base model.
            let base = drafter.baseModel?.lowercased().replacingOccurrences(of: "-assistant", with: "")
            guard let base,
                let target = chatModels.first(where: {
                    $0.baseModel?.lowercased() == base && !MTPDrafter.isInstalled(forModel: $0.directory)
                })
            else {
                MTPDrafter.logger.info(
                    "\(drafter.repoID, privacy: .public): a drafter without its model here, waiting in the list")
                continue
            }
            let destination = MTPDrafter.directory(forModel: target.directory)
            do {
                try FileManager.default.moveItem(at: drafter.directory, to: destination)
            } catch {
                MTPDrafter.logger.error("\(drafter.repoID, privacy: .public): could not attach — \(error.localizedDescription)")
                continue
            }
            MTPDrafter.logger.info(
                "\(drafter.repoID, privacy: .public): attached to \(target.repoID, privacy: .public)")
            moved = true
            setSpeculative(true, for: target)
            notifySpeculationOn(target)
        }
        return moved
    }

    private func notifySpeculationOn(_ model: ModelDescriptor) {
        notifyAboutDownload(
            title: String(localized: "Faster answers are on"),
            body: String(localized: "\(model.name) drafts several tokens per round; its answers no longer vary."),
            category: .downloadFinished)
    }

    func deleteStrayDrafter(_ drafter: ModelDescriptor) {
        try? FileManager.default.removeItem(at: drafter.directory)
        Task { await refreshModels() }
    }

    func canSpeculate(_ model: ModelDescriptor) -> Bool {
        guard model.source != .remote else { return false }
        return model.baseModel?.isEmpty == false || drafterIsInstalled(for: model)
    }

    func drafterIsInstalled(for model: ModelDescriptor) -> Bool { MTPDrafter.isInstalled(forModel: model.directory) }

    func installedDrafterRepo(for model: ModelDescriptor) -> String? {
        try? ModelManifest.load(from: MTPDrafter.directory(forModel: model.directory)).repoID
    }

    func isSpeculative(_ model: ModelDescriptor) -> Bool { settings.speculativeModels.contains(model.id) }

    func replyLimit(forModel id: String) -> Int? {
        guard let model = models.first(where: { $0.id == id }), let context = contextTokens(for: model) ?? model.contextLength
        else { return nil }
        return ConversationService.replyBudget(context: context, atLeast: ConversationService.Configuration().reservedTokensForReply)
    }

    func showsReasoning(modelID: String) -> Bool { settings.reasoningShown.contains(modelID) }

    private func toggle(_ id: String, in keyPath: ReferenceWritableKeyPath<AppSettings, [String]>, on: Bool) {
        var ids = Set(settings[keyPath: keyPath])
        if on { ids.insert(id) } else { ids.remove(id) }
        settings[keyPath: keyPath] = Array(ids).sorted()
    }

    func setShowsReasoning(_ shown: Bool, for model: ModelDescriptor) {
        toggle(model.id, in: \.reasoningShown, on: shown)
        applyConversationConfiguration()
    }

    func drafterNeedsGreedy(_ model: ModelDescriptor) -> Bool { settings.greedyDrafters.contains(model.id) }

    func setSpeculative(_ on: Bool, for model: ModelDescriptor) {
        MTPDrafter.logger.info("\(model.repoID, privacy: .public): speculation \(on ? "on" : "off", privacy: .public)")
        toggle(model.id, in: \.speculativeModels, on: on)
        applyConversationConfiguration()
        forgetDrafter(of: model)
    }

    func drafterCandidates(for model: ModelDescriptor) async -> [String] {
        guard let base = model.baseModel, !base.isEmpty else {
            MTPDrafter.logger.info("\(model.repoID, privacy: .public): no base model recorded, nothing to look for")
            return []
        }
        let client = hubClient
        let name = base.split(separator: "/").last.map(String.init) ?? base
        async let tagged = try? client.drafters(baseModel: base, limit: 20)
        async let named = try? client.search(query: name, limit: 50)
        var seen = Set<String>()
        let found = ((await tagged) ?? []) + ((await named) ?? [])
        var fitting: [String] = []
        for candidate in found where seen.insert(candidate.id).inserted {
            guard let type = await drafterType(of: candidate, client: client) else { continue }
            MTPDrafter.logger.info("\(candidate.id, privacy: .public): drafter of type \(type, privacy: .public)")
            fitting.append(candidate.id)
            if fitting.count == 8 { break }
        }
        MTPDrafter.logger.info(
            "\(model.repoID, privacy: .public): \(found.count) repositories seen, \(fitting.count) usable drafters")
        return fitting
    }

    private func drafterType(of candidate: HubModelSummary, client: HubClient) async -> String? {
        for tag in candidate.tags ?? [] where await MTPDrafter.isDrafterType(tag) { return tag }
        guard let config = try? await client.config(repoID: candidate.id), let type = MTPDrafter.modelType(inConfig: config),
            await MTPDrafter.isDrafterType(type)
        else { return nil }
        return type
    }

    private(set) var drafterVerdicts: [String: String] = [:]

    func drafterDownload(for model: ModelDescriptor) -> ActiveDownload? {
        downloads.first { $0.drafterFor == model.repoID }
    }

    func drafterVerdict(for model: ModelDescriptor) -> String? { drafterVerdicts[model.repoID] }

    func installDrafter(repoID: String, for model: ModelDescriptor) {
        drafterVerdicts[model.repoID] = nil
        // Hub-provided name; a parse failure is a bug.
        guard let reference = ModelReference.parse(repoID) else {
            MTPDrafter.logger.error("not a repository name: \(repoID, privacy: .public)")
            return
        }
        let id = reference.repoID
        guard downloaderIsIdle(repoID: id) else { return }
        logger.info("drafter queued: \(id, privacy: .public) for \(model.repoID, privacy: .public)")
        enqueue(ActiveDownload(repoID: id, title: model.name, drafterFor: model.repoID))
    }

    private func setNeedsGreedy(_ needed: Bool, for model: ModelDescriptor) {
        toggle(model.id, in: \.greedyDrafters, on: needed)
        applyConversationConfiguration()
    }

    func removeDrafter(for model: ModelDescriptor) {
        MTPDrafter.logger.info("\(model.repoID, privacy: .public): drafter removed")
        try? FileManager.default.removeItem(at: MTPDrafter.directory(forModel: model.directory))
        setNeedsGreedy(false, for: model)
        setSpeculative(false, for: model)
    }

    private func finishDrafter(at folder: URL, repoID: String, modelRepoID: String) async {
        guard let model = models.first(where: { $0.repoID == modelRepoID }) else { return }
        let traits = await MTPDrafter.inspect(folder: folder, target: model.directory)
        if traits == nil {
            try? FileManager.default.removeItem(at: folder)
            logger.error("drafter rejected: \(repoID, privacy: .public) is not usable for \(model.repoID, privacy: .public)")
            drafterVerdicts[model.repoID] = String(localized: "\(repoID) does not hold prediction heads for \(model.name).")
            notifyAboutDownload(
                title: String(localized: "Not an MTP drafter"),
                body: String(localized: "\(repoID) does not hold prediction heads for \(model.name)."))
            return
        }
        logger.info("drafter installed: \(repoID, privacy: .public) for \(model.repoID, privacy: .public)")
        setNeedsGreedy(traits?.needsGreedy == true, for: model)
        drafterVerdicts[model.repoID] = nil
        setSpeculative(true, for: model)
        await refreshModels()
        notifySpeculationOn(model)
    }

    private func forgetDrafter(of model: ModelDescriptor) {
        guard engineState.modelID == model.id else { return }
        Task { await engineManager.unload() }
    }

    // Backfill `baseModel` for older downloads.

    private var baseModelLookups: Set<String> = []

    private func fillInBaseModels(_ list: [ModelDescriptor]) {
        let missing = list.filter { $0.baseModel == nil && $0.source != .remote && baseModelLookups.insert($0.id).inserted }
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

    private func withDownload(
        _ repoID: String, phase allowed: (ActiveDownload.Phase) -> Bool = { _ in true }, _ body: (Int) -> Void
    ) {
        guard let i = downloads.firstIndex(where: { $0.repoID == repoID }), allowed(downloads[i].phase) else { return }
        body(i)
    }

    func pauseDownload(repoID: String) {
        withDownload(repoID, phase: { $0 == .running || $0 == .queued }) { i in
            let wasRunning = downloads[i].isRunning
            downloads[i].phase = .paused
            if wasRunning { Task { await downloader.cancel(repoID: repoID) } }
        }
    }

    func resumeDownload(repoID: String) {
        withDownload(repoID, phase: { $0 == .paused || $0 == .queued }) { i in
            var entry = downloads.remove(at: i)
            entry.phase = .queued
            downloads.insert(entry, at: 0)
            guard let running = downloads.firstIndex(where: \.isRunning) else {
                startNextDownloadIfIdle()
                return
            }
            // The finished task starts the next download, which is this one.
            let preempted = downloads[running].repoID
            downloads[running].phase = .queued
            Task { await downloader.cancel(repoID: preempted) }
        }
    }

    func cancelDownload(repoID: String) {
        withDownload(repoID) { i in
            let wasRunning = downloads[i].isRunning
            downloads.remove(at: i)
            if wasRunning { Task { await downloader.cancel(repoID: repoID) } }
        }
    }

    func downloaderIsIdle(repoID: String) -> Bool {
        !downloads.contains { $0.repoID == repoID && $0.isActive }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case HubError.gatedRepositoryRequiresToken:
            String(localized: "This repository is gated. Add a Hugging Face token and accept the license on huggingface.co.")
        case HubError.notFound: String(localized: "Repository not found.")
        case HubError.insufficientDiskSpace(let need, let have):
            String(
                localized:
                    "Not enough disk space: need \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)), available \(ByteCountFormatter.string(fromByteCount: have, countStyle: .file))."
            )
        case HubError.checksumMismatch(let file): String(localized: "Checksum mismatch for \(file). Try again.")
        case HubError.unsafePath(let path): String(localized: "The repository lists an unsafe file path (\(path)) and cannot be installed.")
        case HubError.cancelled: String(localized: "Cancelled.")
        // Unreachable hub reported as a network problem.
        case let error as URLError
        where [
            URLError.Code.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
            .secureConnectionFailed, .dnsLookupFailed,
        ].contains(error.code):
            String(localized: "Connection failed")
        default: error.localizedDescription
        }
    }

    // Credentials

    func setHuggingFaceToken(_ token: String?) {
        let value = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = value?.isEmpty == false ? value : nil
        settings.huggingFaceToken = stored
        hubClient = HubClient(token: stored)
        downloaderNeedsRebuild = true
        rebuildDownloaderIfIdle()
    }

    func saveHuggingFaceTokenAndRetry(_ token: String) {
        setHuggingFaceToken(token)
        guard hubClient.token != nil else { return }
        let waiting = downloads.filter { $0.phase == .needsToken }
        downloads.removeAll { $0.phase == .needsToken }
        let head = downloads.firstIndex(where: { $0.phase == .queued }) ?? downloads.endIndex
        downloads.insert(
            contentsOf: waiting.map {
                var d = $0; d.phase = .queued; d.progress = nil; return d
            }, at: head)
        startNextDownloadIfIdle()
    }

    // Swap the hub client only between transfers.
    private func rebuildDownloaderIfIdle() {
        guard downloaderNeedsRebuild, downloadTasks.isEmpty else { return }
        downloader = ModelDownloader(client: hubClient, paths: paths)
        downloaderNeedsRebuild = false
        // Re-apply user limits to a fresh downloader.
        applyDownloadLimits()
    }

    // Tools

    private func updateToolSetting<V>(_ keyPath: ReferenceWritableKeyPath<AppSettings, V>, to value: V) {
        settings[keyPath: keyPath] = value
        updateTools()
    }

    func setToolsEnabled(_ enabled: Bool) { updateToolSetting(\.toolsEnabled, to: enabled) }

    func setSearchProvider(_ provider: String) { updateToolSetting(\.searchProvider, to: provider) }

    func setFileToolsEnabled(_ enabled: Bool) { updateToolSetting(\.fileToolsEnabled, to: enabled) }

    func isToolEnabled(_ tool: ExtraTool) -> Bool { settings.extraTools.contains(tool.rawValue) }

    func setToolEnabled(_ tool: ExtraTool, _ enabled: Bool) {
        toggle(tool.rawValue, in: \.extraTools, on: enabled)
        // Request permission while in settings.
        if enabled {
            switch tool {
            case .location: LocationService.shared.requestPermission()
            case .calendar: CalendarAccess.request()
            case .contacts: ContactsAccess.request()
            case .screen: ScreenAccess.request()
            default: break
            }
        }
        updateTools()
    }

    var hotkey: GlobalHotkey.Combination {
        .init(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
    }

    var hotkeyChanged: (() -> Void)?

    func restoreHotkey() { hotkeyChanged?() }

    func setHotkey(_ combination: GlobalHotkey.Combination) {
        settings.hotkeyKeyCode = combination.keyCode
        settings.hotkeyModifiers = combination.modifiers
        hotkeyChanged?()
    }

    func setToolIterations(_ rounds: Int) {
        settings.toolIterations = min(max(rounds, 1), 20)
        applyConversationConfiguration()
    }

    func setPageCharacters(_ characters: Int) { updateToolSetting(\.pageCharacters, to: min(max(characters, 2000), 60000)) }

    func setSearchResults(_ count: Int) { updateToolSetting(\.searchResults, to: min(max(count, 3), 12)) }

    func setVoiceInputEnabled(_ enabled: Bool) { settings.voiceInputEnabled = enabled }
    func setVoiceAutoSend(_ sends: Bool) { settings.voiceAutoSend = sends }

    private func updateAPISetting<V: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppSettings, V>, to value: V) {
        guard settings[keyPath: keyPath] != value else { return }
        settings[keyPath: keyPath] = value
        restartAPI()
    }

    func setAPIEnabled(_ enabled: Bool) { updateAPISetting(\.apiServerEnabled, to: enabled) }

    func setAPIBindHost(_ host: String) { updateAPISetting(\.apiBindHost, to: host) }

    func setAPIPort(_ port: Int) { updateAPISetting(\.apiServerPort, to: min(max(port, 1024), 65535)) }

    func setDownloadSpeedLimit(_ mbps: Int) {
        settings.downloadSpeedLimitMBps = max(0, mbps)
        applyDownloadLimits()
    }

    func setDownloadConcurrentFiles(_ count: Int) {
        settings.downloadConcurrentFiles = min(max(count, 1), 4)
        applyDownloadLimits()
    }

    func applyDownloadLimits() {
        let bytesPerSecond = Int64(settings.downloadSpeedLimitMBps) * 1_000_000
        let files = settings.downloadConcurrentFiles
        Task { [downloader] in
            await downloader.setSpeedLimit(bytesPerSecond: bytesPerSecond)
            await downloader.setMaxConcurrentFiles(files)
        }
    }

    func restartAPI() {
        let previous = apiRestartTask
        apiGeneration += 1
        let generation = apiGeneration
        apiRestartTask = Task {
            await previous?.value
            guard generation == self.apiGeneration else { return }
            await self.startAPI()
        }
    }

    var corsPolicy: CORSPolicy { CORSPolicy.parse(mode: settings.apiCORSMode, origins: settings.apiCORSOrigins) }

    func setCORSMode(_ mode: String) {
        settings.apiCORSMode = mode
        apiServer?.setCORSPolicy(corsPolicy)
    }

    func setCORSOrigins(_ origins: String) {
        settings.apiCORSOrigins = origins
        apiServer?.setCORSPolicy(corsPolicy)
    }

    func setShortcutsToolEnabled(_ enabled: Bool) { updateToolSetting(\.shortcutsToolEnabled, to: enabled) }

    func addAllowedFolder(_ url: URL) {
        var list = settings.allowedFolders
        let path = url.standardizedFileURL.path
        if !list.contains(path) { list.append(path) }
        updateToolSetting(\.allowedFolders, to: list)
    }

    func removeAllowedFolder(_ path: String) {
        updateToolSetting(\.allowedFolders, to: settings.allowedFolders.filter { $0 != path })
    }

    func updateTools() {
        var providers: [any ToolProvider] = []
        if settings.toolsEnabled {
            let provider: any SearchProvider = settings.searchProvider == "google" ? GoogleProvider() : DuckDuckGoProvider()
            var web = WebToolProvider.Configuration()
            web.maxPageCharacters = settings.pageCharacters
            web.maxResults = settings.searchResults
            providers.append(WebToolProvider(provider: provider, configuration: web))
        }
        if settings.fileToolsEnabled, !settings.allowedFolders.isEmpty {
            providers.append(
                FileToolProvider(
                    configuration: .init(
                        allowedFolders: settings.allowedFolders.map { URL(fileURLWithPath: $0) }, confirmation: NotificationService.shared))
            )
        }
        // Enabled tools are permitted; only file changes still ask.
        for tool in ExtraTool.allCases where isToolEnabled(tool) {
            switch tool {
            case .calculator: providers.append(JavaScriptToolProvider())
            case .macInfo: providers.append(MacInfoToolProvider())
            case .network: providers.append(NetworkToolProvider())
            case .weather:
                var weather = WeatherToolProvider()
                weather.usesCurrentPlace = isToolEnabled(.location)
                providers.append(weather)
            case .location: providers += [LocationToolProvider(), MapsToolProvider()]
            case .trips:
                var trips = TripsToolProvider()
                trips.usesCurrentPlace = isToolEnabled(.location)
                providers.append(trips)
            case .browser:
                providers.append(SafariToolProvider(configuration: .init(pageCharacters: settings.pageCharacters)))
            case .calendar: providers.append(CalendarToolProvider())
            case .timers: providers.append(TimerToolProvider())
            case .screen: providers.append(ScreenToolProvider())
            case .currency: providers.append(CurrencyToolProvider())
            case .contacts: providers.append(ContactsToolProvider())
            case .notes: providers.append(NotesToolProvider())
            case .mail: providers.append(MailToolProvider())
            case .spotlight: providers.append(SpotlightToolProvider())
            case .macControl: providers.append(MacControlToolProvider())
            case .music: providers.append(MusicToolProvider())
            }
        }
        if settings.shortcutsToolEnabled {
            providers.append(ShortcutToolProvider())
        }
        let tools: any ToolProvider = CompositeToolProvider(providers)
        Task { await conversation.setTools(tools) }
    }

    // API server only on the chosen port; a busy port blocks the switch.

    var apiURL: URL {
        let host = settings.apiBindHost == "0.0.0.0" ? (NetworkInterfaces.addresses().first?.address ?? "127.0.0.1") : settings.apiBindHost
        return URL(string: "http://\(host):\(settings.apiServerPort)")!
    }

    func startAPI() async {
        stopAPI()
        let port = settings.apiServerPort
        apiPortBusy = !HTTPServer.portIsFree(host: settings.apiBindHost, port: port)
        // Switched off in the settings: nothing listens, and no port is taken from anyone else.
        guard settings.apiServerEnabled else { return }
        guard !apiPortBusy else {
            apiStatus = .portBusy(port: port)
            NotificationService.shared.send(title: String(localized: "API port in use"), body: Self.portBusyText(port))
            return
        }
        apiStatus = .starting
        let server = APIServer(
            configuration: .init(
                host: settings.apiBindHost, port: port,
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"),
            catalog: catalog, engine: engineManager, fallbackModel: { [weak self] in await self?.activeModel }
        ) { [weak self] model in await self?.apiDefaults(for: model) ?? APIModelDefaults(contextTokens: model.contextLength) }
        server.setCORSPolicy(corsPolicy)
        do {
            try server.start()
        } catch {
            // Taken between the check and the bind.
            logger.error("API bind on \(port) failed: \(error)")
            apiPortBusy = true
            apiStatus = .portBusy(port: port)
            return
        }
        apiServer = server
        apiStatus = .running(port: port)
    }

    func checkAPIPort() {
        guard apiServer == nil else { return }
        let busy = !HTTPServer.portIsFree(host: settings.apiBindHost, port: settings.apiServerPort)
        guard busy != apiPortBusy else { return }
        apiPortBusy = busy
        if !busy, settings.apiServerEnabled { restartAPI() }
    }

    static func portBusyText(_ port: Int) -> String {
        String(localized: "Port \(port) is taken by another program: choose a free one to turn the API on.")
    }

    func stopAPI() {
        apiServer?.stop()
        apiServer = nil
        apiStatus = .disabled
    }
}

final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private let fd: Int32

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .global(qos: .utility))
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

// AppSettings

@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func string(_ key: SettingsKey) -> String? { access(keyPath: \.token); return defaults.string(forKey: key.rawValue) }
    private func string(_ key: SettingsKey, or fallback: String) -> String { string(key) ?? fallback }
    private func bool(_ key: SettingsKey) -> Bool { access(keyPath: \.token); return defaults.bool(forKey: key.rawValue) }
    private func double(_ key: SettingsKey) -> Double { access(keyPath: \.token); return defaults.double(forKey: key.rawValue) }
    private func int(_ key: SettingsKey) -> Int { access(keyPath: \.token); return defaults.integer(forKey: key.rawValue) }
    private func int(_ key: SettingsKey, or fallback: Int) -> Int { let value = int(key); return value > 0 ? value : fallback }
    private func stringArray(_ key: SettingsKey) -> [String] {
        access(keyPath: \.token)
        return defaults.stringArray(forKey: key.rawValue) ?? []
    }
    private func dictionary<T>(_ key: SettingsKey) -> [String: T] {
        access(keyPath: \.token)
        return defaults.dictionary(forKey: key.rawValue) as? [String: T] ?? [:]
    }
    private func date(_ key: SettingsKey) -> Date? { access(keyPath: \.token); return defaults.object(forKey: key.rawValue) as? Date }
    private func data(_ key: SettingsKey) -> Data? { access(keyPath: \.token); return defaults.data(forKey: key.rawValue) }
    private func set(_ value: Any?, _ key: SettingsKey) { withMutation(keyPath: \.token) { defaults.set(value, forKey: key.rawValue) } }
    private var token = 0

    var activeModelID: String? {
        get { string(.activeModelID) }
        set { set(newValue, .activeModelID) }
    }
    var activeChatID: UUID? {
        get { string(.activeChatID).flatMap(UUID.init) }
        set { set(newValue?.uuidString, .activeChatID) }
    }
    var idleUnloadSeconds: TimeInterval {
        get { double(.idleUnloadSeconds) }
        set { set(newValue, .idleUnloadSeconds) }
    }
    var launchAtLogin: Bool {
        get { bool(.launchAtLogin) }
        set { set(newValue, .launchAtLogin) }
    }
    var apiServerPort: Int {
        get { int(.apiServerPort) }
        set { set(newValue, .apiServerPort) }
    }
    var apiServerEnabled: Bool {
        get { bool(.apiServerEnabled) }
        set { set(newValue, .apiServerEnabled) }
    }
    var apiBindHost: String {
        get { string(.apiBindHost, or: SettingsDefaults.apiBindHost) }
        set { set(newValue, .apiBindHost) }
    }
    var apiCORSMode: String {
        get { string(.apiCORSMode, or: SettingsDefaults.apiCORSMode) }
        set { set(newValue, .apiCORSMode) }
    }
    var apiCORSOrigins: String {
        get { string(.apiCORSOrigins, or: "") }
        set { set(newValue, .apiCORSOrigins) }
    }
    var downloadSpeedLimitMBps: Int {
        get { int(.downloadSpeedLimitMBps) }
        set { set(newValue, .downloadSpeedLimitMBps) }
    }
    var preferredLanguage: String {
        get { string(.preferredLanguage, or: "") }
        set { set(newValue, .preferredLanguage) }
    }
    var downloadConcurrentFiles: Int {
        get { int(.downloadConcurrentFiles, or: SettingsDefaults.downloadConcurrentFiles) }
        set { set(newValue, .downloadConcurrentFiles) }
    }
    var hotkeyKeyCode: Int {
        get { int(.hotkeyKeyCode) }
        set { set(newValue, .hotkeyKeyCode) }
    }
    var hotkeyModifiers: Int {
        get { int(.hotkeyModifiers) }
        set { set(newValue, .hotkeyModifiers) }
    }
    var toolIterations: Int {
        get { int(.toolIterations, or: SettingsDefaults.toolIterations) }
        set { set(newValue, .toolIterations) }
    }
    var pageCharacters: Int {
        get { int(.pageCharacters, or: SettingsDefaults.pageCharacters) }
        set { set(newValue, .pageCharacters) }
    }
    var searchResults: Int {
        get { int(.searchResults, or: SettingsDefaults.searchResults) }
        set { set(newValue, .searchResults) }
    }
    var toolsEnabled: Bool {
        get { bool(.toolsEnabled) }
        set { set(newValue, .toolsEnabled) }
    }
    var searchProvider: String {
        get { string(.searchProvider, or: SettingsDefaults.searchProvider) }
        set { set(newValue, .searchProvider) }
    }
    var fileToolsEnabled: Bool {
        get { bool(.fileToolsEnabled) }
        set { set(newValue, .fileToolsEnabled) }
    }
    var modelContextTokens: [String: Int] {
        get { dictionary(.modelContextTokens) }
        set { set(newValue, .modelContextTokens) }
    }
    var modelTemperatures: [String: Double] {
        get { dictionary(.modelTemperatures) }
        set { set(newValue, .modelTemperatures) }
    }
    var reasoningShown: [String] {
        get { stringArray(.reasoningShown) }
        set { set(newValue, .reasoningShown) }
    }
    var greedyDrafters: [String] {
        get { stringArray(.greedyDrafters) }
        set { set(newValue, .greedyDrafters) }
    }
    var speculativeModels: [String] {
        get { stringArray(.speculativeModels) }
        set { set(newValue, .speculativeModels) }
    }
    var shortcutsToolEnabled: Bool {
        get { bool(.shortcutsToolEnabled) }
        set { set(newValue, .shortcutsToolEnabled) }
    }
    var allowedFolders: [String] {
        get { stringArray(.allowedFolders) }
        set { set(newValue, .allowedFolders) }
    }
    var voiceInputEnabled: Bool {
        get { bool(.voiceInputEnabled) }
        set { set(newValue, .voiceInputEnabled) }
    }
    var voiceAutoSend: Bool {
        get { bool(.voiceAutoSend) }
        set { set(newValue, .voiceAutoSend) }
    }
    var panelGeometry: [Double] {
        get { access(keyPath: \.token); return defaults.array(forKey: SettingsKey.panelGeometry.rawValue) as? [Double] ?? [] }
        set { set(newValue, .panelGeometry) }
    }
    var pendingDownloads: Data? {
        get { data(.pendingDownloads) }
        set { set(newValue, .pendingDownloads) }
    }
    var lastAppUpdateCheck: Date? {
        get { date(.lastAppUpdateCheck) }
        set { set(newValue, .lastAppUpdateCheck) }
    }
    var lastModelUpdateCheck: Date? {
        get { date(.lastModelUpdateCheck) }
        set { set(newValue, .lastModelUpdateCheck) }
    }
    var sidebarWidth: Double {
        get { double(.sidebarWidth) }
        set { set(newValue, .sidebarWidth) }
    }
    var extraTools: [String] {
        get { stringArray(.extraTools) }
        set { set(newValue, .extraTools) }
    }
    var huggingFaceToken: String? {
        get { string(.huggingFaceToken) }
        set { set(newValue, .huggingFaceToken) }
    }
}
