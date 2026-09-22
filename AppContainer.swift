//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Observation
import os

// AppContainer

/// Dependency root and UI-facing state mirror. Everything here is @MainActor (app target default isolation).
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
    /// Model folders that cannot be loaded; the models section offers to download them again or delete them.
    private(set) var brokenModels: [ModelCatalog.BrokenModel] = []
    private(set) var apiStatus: APIStatus = .disabled
    private(set) var downloads: [ActiveDownload] = [] { didSet { persistDownloads() } }
    /// The chats window shows the model library instead of a chat (set from the menu, notifications and the sidebar).
    /// What the chats window shows on the right: the chat, the model library or the settings.
    enum Section: Equatable { case chat, models, settings }
    var section: Section = .chat
    /// Raised whenever an action turns out to need a Hugging Face token; the model library answers by opening the token popover.
    var tokenPromptRequested = false
    /// Chats on screen right now (the panel's and the one open in the chats window): a model picked in the menu goes to them.
    var panelChatID: UUID?
    /// Bumped when the panel or the chats window gets a complete answer; the status item blinks if nobody sees it.
    private(set) var answersFinished = 0
    var windowChatID: UUID?
    /// A chat the chats window should show when it comes up (the panel's "Open in Chats"); the window clears it.
    var requestedWindowChatID: UUID?

    /// Opens the chats window on this chat instead of whichever it showed last.
    func openInChats(_ chatID: UUID?) {
        section = .chat
        requestedWindowChatID = chatID
        WindowManager.shared.open(.chats)
    }
    /// Models connected by API whose server did not answer the last check; menus and pickers show them disabled.
    private(set) var unavailableModelIDs: Set<String> = []
    private var lastAvailabilityCheck: ContinuousClock.Instant?
    private var availabilityTask: Task<Void, Never>?
    var activeModel: ModelDescriptor? { models.first { $0.id == settings.activeModelID } }
    /// Installed models grouped by hub (Hugging Face, ModelScope, API), empty hubs omitted.
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
        /// `needsToken`: gated repository and no token saved; `needsAccess`: the saved token's account has no access to it.
        enum Phase: Equatable { case queued, running, paused, finished, failed(String), needsToken, needsAccess }
        var id: String { repoID }
        var repoID: String
        // Display metadata for the pinned row in the models window; absent for downloads started elsewhere.
        var title: String?
        var quantization: String?
        var sizeBytes: Int64?
        var progress: DownloadProgress?
        var phase: Phase = .queued
        /// Set on an MTP drafter: the repo id of the model it belongs to. Its files go inside that model's folder.
        var drafterFor: String?
        var error: String? { if case .failed(let message) = phase { message } else { nil } }
        var finished: Bool { phase == .finished }
        var isRunning: Bool { phase == .running }
        /// Still owed work: queued, running or paused.
        var isActive: Bool { phase == .queued || phase == .running || phase == .paused }
    }

    /// Set when the chat database could not be opened. `recovered`: a fresh database took over
    /// (old one backed up); otherwise the session runs on the in-memory store.
    struct StoreFailure: Equatable {
        var message: String
        var backup: URL?
        var recovered = false
    }

    let storeFailure: StoreFailure?

    private var apiServer: APIServer?
    /// Serializes restarts: each waits for the previous stop/probe/bind cycle to finish.
    private var apiRestartTask: Task<Void, Never>?
    private var apiGeneration = 0
    /// The port actually bound; may differ from the setting when the chosen one was busy. Never written back.
    private(set) var apiActivePort: Int?
    private var stateTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloaderNeedsRebuild = false
    private var persistedDownloads: [StoredDownload] = []

    /// What survives a restart: enough to show the row again and continue from the `.part` files on disk.
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
        // A Mac that slept had no network: the connected servers are asked about once, when it comes back.
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
        // A drafter downloaded on its own is not a chat model: attach it to its model, or keep it out of the list.
        if await attachStrayDrafters(in: list) { list = await catalog.refresh() }
        let strays = await Self.drafterFolders(in: list)
        strayDrafters = strays
        list = list.filter { model in !strays.contains { $0.id == model.id } }
        models = list
        modelTemperatures = Dictionary(
            uniqueKeysWithValues: list.compactMap { model in
                ModelDefaults.temperature(in: model.directory).map { (model.id, $0) }
            })
        fillInBaseModels(list)
        brokenModels = await catalog.brokenModels
        if settings.activeModelID == nil || !list.contains(where: { $0.id == settings.activeModelID }) {
            setActiveModel(list.first)
        }
    }

    /// Checks the servers of models connected by API: once at launch, once after the Mac wakes, every minute while the
    /// models section is open, and on the check button of an unavailable model. Local models are on disk and need none.
    /// `force` skips the 30 s that keeps two checks in a row from both going out.
    func checkModelAvailability(force: Bool = false) {
        let remotes = models.filter { $0.source == .remote }
        guard availabilityTask == nil else { return }
        guard !remotes.isEmpty else { return unavailableModelIDs = [] }
        if !force, let last = lastAvailabilityCheck, last.duration(to: .now) < .seconds(30) { return }
        let targets = remotes.compactMap { model in (try? RemoteEndpoint.load(from: model.directory)).map { (model, $0) } }
        availabilityTask = Task {
            defer { availabilityTask = nil }
            // nil probe = up but refused us (no token sent); a probe = up, with what the server serves now.
            let results = await withTaskGroup(of: (ModelDescriptor, RemoteEndpoint, RemoteEngine.Probe?, up: Bool).self) { group in
                let logger = logger  // the probes run in a task group, so the logger travels with them
                for (model, endpoint) in targets {
                    group.addTask {
                        // With its token, so a server that only answers authenticated requests is checked properly;
                        // one that refuses us is still up.
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

    /// llama-server answers under any name with whatever model it was restarted with: the connected model follows it —
    /// new name, context, tools and vision. The folder (the model's id) stays, so chats, the menu choice and the token keep it.
    private func updateRemote(_ model: ModelDescriptor, endpoint: RemoteEndpoint, probe: RemoteEngine.Probe) -> Bool {
        let repoID = "\(endpoint.hostAndPort)/\(probe.model)"
        let kind: ModelKind = probe.supportsVision ? .vlm : .llm
        // llama-server answers `/props` with `{}` on some builds: what it does not report keeps the value it had.
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
        if engineState.modelID == model.id { Task { await engineManager.unload() } }  // next question reconnects with the new model
        return true
    }

    func isAvailable(_ model: ModelDescriptor) -> Bool { !unavailableModelIDs.contains(model.id) }
    var isCheckingAvailability: Bool { availabilityTask != nil }

    func answerFinished(_ message: Message) {
        guard !message.isPartial else { return }  // stopped by the user, who is looking at it
        answersFinished += 1
    }

    /// The status menu choice: the app-wide model, and the chats on screen switch to it too, since each chat keeps its own
    /// model and would otherwise go on answering with the old one.
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

    /// "Connect by API": checks that the server answers and has the model, then adds it to the library like a downloaded one.
    /// `address` may omit the scheme (`localhost:8080`); the optional token is saved with the settings.
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
        // The manifest goes last: a folder watcher refreshing in between would otherwise list a half-written model.
        try ModelManifest(
            repoID: "\(endpoint.hostAndPort)/\(probe.model)", revision: "", source: .remote, kind: probe.supportsVision ? .vlm : .llm,
            files: [], contextLength: probe.contextLength, supportsTools: probe.supportsTools
        ).save(to: directory)
        await refreshModels()
    }

    /// Queues the broken model again: the downloader resumes its `.part` files and replaces the folder when done.
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

    /// Context window is a property of each model. 0 = model maximum. Applies to history trimming and the engine's KV cache bound.
    func setContextTokens(_ tokens: Int, for model: ModelDescriptor) {
        var map = settings.modelContextTokens
        map[model.id] = tokens > 0 ? tokens : nil
        settings.modelContextTokens = map
        applyConversationConfiguration()
    }

    /// What the checkpoint asks for, when it says anything; otherwise the app's own default. The second value says
    /// which of the two it is, because a model served elsewhere has no checkpoint here to ask.
    func defaultTemperature(for model: ModelDescriptor) -> (value: Double, fromModel: Bool) {
        if let value = modelTemperatures[model.id] { return (value, true) }
        return (SamplingParams().temperature, false)
    }

    /// The temperature chosen for this model, or nil while it follows the checkpoint.
    func temperature(for model: ModelDescriptor) -> Double? { settings.modelTemperatures[model.id] }

    func setTemperature(_ value: Double?, for model: ModelDescriptor) {
        var map = settings.modelTemperatures
        map[model.id] = value
        settings.modelTemperatures = map
        applyConversationConfiguration()
    }

    /// The window a model runs with: its saved choice capped by what the model supports.
    func contextTokens(for model: ModelDescriptor) -> Int? {
        guard let chosen = settings.modelContextTokens[model.id], chosen > 0 else { return model.contextLength }
        return model.contextLength.map { min(chosen, $0) } ?? chosen
    }

    private func applyConversationConfiguration() {
        var config = ConversationService.Configuration(maxToolIterations: settings.toolIterations)
        config.contextTokensByModel = settings.modelContextTokens
        config.temperatureByModel = settings.modelTemperatures
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

    /// "Unload After → Never" means the model is resident: load it right away and keep it. With any timeout the model
    /// is loaded only by the first message in the panel or a chat.
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

    /// Accepts `org/repo` or a huggingface.co link (Hugging Face), `modelscope:org/repo` or a modelscope.cn link (ModelScope).
    func download(repoID: String, title: String? = nil, quantization: String? = nil, sizeBytes: Int64? = nil) {
        guard let ref = ModelReference.parse(repoID) else { return }
        download(ref, title: title, quantization: quantization, sizeBytes: sizeBytes)
    }

    /// Queues the model. Only one download runs at a time; the rest wait in order below it.
    func download(_ reference: ModelReference, title: String? = nil, quantization: String? = nil, sizeBytes: Int64? = nil) {
        enqueue(ActiveDownload(repoID: reference.repoID, title: title, quantization: quantization, sizeBytes: sizeBytes))
    }

    /// Replaces any old row for this repo with a queued one and lets the queue advance.
    private func enqueue(_ download: ActiveDownload) {
        guard downloaderIsIdle(repoID: download.repoID) else { return }
        downloads.removeAll { $0.repoID == download.repoID }
        downloads.append(download)
        startNextDownloadIfIdle()
    }

    // Persistence: a download interrupted by quitting the app continues on the next launch.

    /// Called on every change of `downloads`; progress ticks do not alter the stored projection, so they cost no disk writes.
    private func persistDownloads() {
        let stored = downloads.filter { !$0.finished }.map {
            // Anything not actively queued or running comes back paused, so a failed model never restarts on its own.
            StoredDownload(
                repoID: $0.repoID, title: $0.title, quantization: $0.quantization, sizeBytes: $0.sizeBytes,
                paused: !($0.phase == .running || $0.phase == .queued), drafterFor: $0.drafterFor)
        }
        guard stored != persistedDownloads else { return }
        persistedDownloads = stored
        settings.pendingDownloads = try? JSONEncoder().encode(stored)
    }

    /// Running and queued downloads resume automatically; paused ones wait for the Continue pictogram.
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

    /// Half-finished transfers whose download is no longer listed: cancelled, abandoned or left by a crash. Their
    /// `.part` files are only useful to a download that still exists, so they are dropped once, at launch.
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

    /// Rows in display order: the running download first, then paused and queued ones, then failed and finished.
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
        // A paused, preempted or cancelled transfer may still be winding down; its task calls back here when it ends,
        // so nothing else may start while any task is alive — otherwise two transfers would share the bandwidth.
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
                // Pause and cancel both stop the transfer; the row's phase says which one it was. Partial files stay for resume.
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

    /// Downloads report themselves through Notification Center only while the models section is not open: with it on
    /// screen the row says the same thing, whether or not the window has focus.
    private func notifyAboutDownload(title: String, body: String, category: NotificationService.Category = .info) {
        guard !(section == .models && WindowManager.shared.isOpen(.chats)) else { return }
        NotificationService.shared.send(title: title, body: body, category: category)
    }

    // Multi-token prediction: a drafter installed next to a model lets it answer several tokens per round.

    /// The temperature each checkpoint ships with, read once per catalog refresh; the fallback for models that say
    /// nothing is the app's own default.
    private var modelTemperatures: [String: Double] = [:]

    /// Drafter repositories installed as if they were models: they cannot answer anything, so they are shown apart and
    /// wait for their model. Attaching happens by itself once that model is installed.
    private(set) var strayDrafters: [ModelDescriptor] = []

    /// The folders of `list` that hold a drafter rather than a chat model.
    private static func drafterFolders(in list: [ModelDescriptor]) async -> [ModelDescriptor] {
        var found: [ModelDescriptor] = []
        for model in list where model.source != .remote {
            if await MTPDrafter.isDrafter(directory: model.directory) { found.append(model) }
        }
        return found
    }

    /// Moves every stray drafter into the folder of the model it was published for. True when something moved, so the
    /// catalog is read again.
    private func attachStrayDrafters(in list: [ModelDescriptor]) async -> Bool {
        let strays = await Self.drafterFolders(in: list)
        guard !strays.isEmpty else { return false }
        let chatModels = list.filter { model in model.source != .remote && !strays.contains { $0.id == model.id } }
        var moved = false
        for drafter in strays {
            // The drafter names the model it was split from; `google/gemma-4-12B-it-assistant` belongs to `…-it`.
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

    /// Sent whenever a drafter ends up installed for a model, whichever way it arrived.
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

    /// Whether the switch belongs in this model's row at all. Every local model may have a drafter published for it —
    /// Qwen declares its heads in the config, Gemma says nothing and ships an assistant model — so the popover asks
    /// the hub rather than the row guessing.
    func canSpeculate(_ model: ModelDescriptor) -> Bool { model.source != .remote }

    func drafterIsInstalled(for model: ModelDescriptor) -> Bool { MTPDrafter.isInstalled(forModel: model.directory) }

    /// Which repository the installed drafter came from, as its own manifest recorded it.
    func installedDrafterRepo(for model: ModelDescriptor) -> String? {
        try? ModelManifest.load(from: MTPDrafter.directory(forModel: model.directory)).repoID
    }

    func isSpeculative(_ model: ModelDescriptor) -> Bool { settings.speculativeModels.contains(model.id) }

    /// How long a reply of this model may run, so the transcript can say what the count is measured against.
    func replyLimit(forModel id: String) -> Int? {
        guard let model = models.first(where: { $0.id == id }), let context = contextTokens(for: model) ?? model.contextLength
        else { return nil }
        return ConversationService.replyBudget(context: context, atLeast: ConversationService.Configuration().reservedTokensForReply)
    }

    /// Whether the transcript shows what this model says to itself before answering. Off unless asked: the thinking
    /// is long, and it is not the answer.
    func showsReasoning(modelID: String) -> Bool { settings.reasoningShown.contains(modelID) }

    /// Adds or removes `id` in one of the sorted id lists kept in settings.
    private func toggle(_ id: String, in keyPath: ReferenceWritableKeyPath<AppSettings, [String]>, on: Bool) {
        var ids = Set(settings[keyPath: keyPath])
        if on { ids.insert(id) } else { ids.remove(id) }
        settings[keyPath: keyPath] = Array(ids).sorted()
    }

    /// The eye also decides whether the model reasons at all: a template with optional thinking (Gemma 4, Qwen3) is
    /// told to think only for the models whose thinking is on show, so hidden thinking is never paid for in tokens.
    func setShowsReasoning(_ shown: Bool, for model: ModelDescriptor) {
        toggle(model.id, in: \.reasoningShown, on: shown)
        applyConversationConfiguration()
    }

    /// Whether this model's drafter only verifies greedy decoding — then the temperature is not the user's to choose.
    /// Qwen's prediction heads work that way; Gemma's assistant drafter verifies sampled tokens just as well.
    func drafterNeedsGreedy(_ model: ModelDescriptor) -> Bool { settings.greedyDrafters.contains(model.id) }

    /// Speculation needs both parts: the drafter's weights and greedy decoding, which is what the switch turns on.
    func setSpeculative(_ on: Bool, for model: ModelDescriptor) {
        MTPDrafter.logger.info("\(model.repoID, privacy: .public): speculation \(on ? "on" : "off", privacy: .public)")
        toggle(model.id, in: \.speculativeModels, on: on)
        applyConversationConfiguration()
        forgetDrafter(of: model)
    }

    /// Drafters the hub publishes for this model. A drafter is recognised by its architecture — Hugging Face lists the
    /// `model_type` among a repository's tags, and the library's registry says which of those only a drafter uses.
    /// Two questions are asked: repositories tagged with this base model, and repositories named after it.
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

    /// The drafter architecture of a hub repository, from its tags, or from its config when the tags are silent.
    private func drafterType(of candidate: HubModelSummary, client: HubClient) async -> String? {
        for tag in candidate.tags ?? [] where await MTPDrafter.isDrafterType(tag) { return tag }
        guard let config = try? await client.config(repoID: candidate.id), let type = MTPDrafter.modelType(inConfig: config),
            await MTPDrafter.isDrafterType(type)
        else { return nil }
        return type
    }

    /// The drafter being installed for a model right now, and what came of the last attempt: notifications may be
    /// switched off for the app, so the models section says it itself.
    private(set) var drafterVerdicts: [String: String] = [:]

    func drafterDownload(for model: ModelDescriptor) -> ActiveDownload? {
        downloads.first { $0.drafterFor == model.repoID }
    }

    func drafterVerdict(for model: ModelDescriptor) -> String? { drafterVerdicts[model.repoID] }

    /// Queues a drafter repository for this model; it lands in the model's own folder, so it is never a model itself.
    func installDrafter(repoID: String, for model: ModelDescriptor) {
        drafterVerdicts[model.repoID] = nil
        // The name always comes from the hub's own listing, so a parse failure is a bug, not something to report.
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

    /// A downloaded folder counts as a drafter only if the engine can build one from it; otherwise it is thrown away
    /// rather than left to fail at generation time.
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

    /// The engine keeps the drafter with the loaded model, so a change takes effect on the next load.
    private func forgetDrafter(of model: ModelDescriptor) {
        guard engineState.modelID == model.id else { return }
        Task { await engineManager.unload() }
    }

    // Base models (for the icons): models downloaded before `baseModel` was stored get it from their hub once.

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

    /// Runs `body` with the index of this repo's row, if the row exists and its phase passes `allowed`.
    private func withDownload(
        _ repoID: String, phase allowed: (ActiveDownload.Phase) -> Bool = { _ in true }, _ body: (Int) -> Void
    ) {
        guard let i = downloads.firstIndex(where: { $0.repoID == repoID }), allowed(downloads[i].phase) else { return }
        body(i)
    }

    /// Stops the transfer but keeps the row and the partial files; the queue moves on to the next model.
    /// A model that is only waiting its turn can be paused too, so it stops being picked up when the queue advances.
    func pauseDownload(repoID: String) {
        withDownload(repoID, phase: { $0 == .running || $0 == .queued }) { i in
            let wasRunning = downloads[i].isRunning
            downloads[i].phase = .paused
            if wasRunning { Task { await downloader.cancel(repoID: repoID) } }
        }
    }

    /// Continue: this model goes to the head of the queue and starts right away. Whatever was running goes back into the
    /// queue (not paused), so it picks up where it stopped as soon as this one is done.
    func resumeDownload(repoID: String) {
        withDownload(repoID, phase: { $0 == .paused || $0 == .queued }) { i in
            var entry = downloads.remove(at: i)
            entry.phase = .queued
            downloads.insert(entry, at: 0)
            guard let running = downloads.firstIndex(where: \.isRunning) else {
                startNextDownloadIfIdle()
                return
            }
            // Its task calls `startNextDownloadIfIdle` once the transfer winds down, and by then our row is at the head.
            let preempted = downloads[running].repoID
            downloads[running].phase = .queued
            Task { await downloader.cancel(repoID: preempted) }
        }
    }

    /// Removes the row; a running transfer is stopped first.
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
        // A hub that cannot be reached at all (ModelScope is blocked on some networks): the reason is the network,
        // not the search, so it is worded the same whichever way the connection failed.
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

    /// Saves the token from the popover and puts every download that was waiting for it back at the head of the queue.
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

    // The downloader captures the client (and its token); swap it only between transfers so pause/cancel keep reaching the live one.
    private func rebuildDownloaderIfIdle() {
        guard downloaderNeedsRebuild, downloadTasks.isEmpty else { return }
        downloader = ModelDownloader(client: hubClient, paths: paths)
        downloaderNeedsRebuild = false
        // The fresh downloader starts with no speed cap and default concurrency: re-apply the user's limits.
        applyDownloadLimits()
    }

    // Tools

    /// Writes one setting and rebuilds the tool providers from it.
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
        // macOS asks for the permission now, while the user is in the settings, not when a model first needs it.
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

    /// The shortcut that opens the panel from any app. Set here, not in System Settings: a service's shortcut cannot
    /// be given to this app there. `hotkeyChanged` is the app delegate re-registering it.
    var hotkey: GlobalHotkey.Combination {
        .init(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
    }

    var hotkeyChanged: (() -> Void)?

    /// Registers the stored combination again: the settings field switches it off while it listens for a new one.
    func restoreHotkey() { hotkeyChanged?() }

    func setHotkey(_ combination: GlobalHotkey.Combination) {
        settings.hotkeyKeyCode = combination.keyCode
        settings.hotkeyModifiers = combination.modifiers
        hotkeyChanged?()
    }

    /// How many rounds of tools the model may take before it has to answer: each round is a search or a page read.
    func setToolIterations(_ rounds: Int) {
        settings.toolIterations = min(max(rounds, 1), 20)
        applyConversationConfiguration()
    }

    func setPageCharacters(_ characters: Int) { updateToolSetting(\.pageCharacters, to: min(max(characters, 2000), 60000)) }

    func setSearchResults(_ count: Int) { updateToolSetting(\.searchResults, to: min(max(count, 3), 12)) }

    func setPanelClosesOnFocusLoss(_ closes: Bool) { settings.panelClosesOnFocusLoss = closes }
    func setVoiceInputEnabled(_ enabled: Bool) { settings.voiceInputEnabled = enabled }
    func setVoiceAutoSend(_ sends: Bool) { settings.voiceAutoSend = sends }

    /// Writes one API setting and restarts the server; an unchanged value restarts nothing.
    private func updateAPISetting<V: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppSettings, V>, to value: V) {
        guard settings[keyPath: keyPath] != value else { return }
        settings[keyPath: keyPath] = value
        restartAPI()
    }

    /// The port the local API listens on. Changing it restarts the server; a busy port still moves to the next free one.
    /// Whether other programs may reach the models through this app at all.
    func setAPIEnabled(_ enabled: Bool) { updateAPISetting(\.apiServerEnabled, to: enabled) }

    /// The interface the API answers on. "127.0.0.1" keeps it on this Mac; "0.0.0.0" opens it to the network.
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

    /// Pushes the download limits from settings into the downloader; a running download picks them up mid-flight.
    func applyDownloadLimits() {
        let bytesPerSecond = Int64(settings.downloadSpeedLimitMBps) * 1_000_000
        let files = settings.downloadConcurrentFiles
        Task { [downloader] in
            await downloader.setSpeedLimit(bytesPerSecond: bytesPerSecond)
            await downloader.setMaxConcurrentFiles(files)
        }
    }

    /// Queues a restart behind any in-flight one; stale restarts are skipped so only the last settings win.
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

    /// Which browser origins may call the API. Applies to the running server without a restart.
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

    /// Rebuilds the composite tool provider from settings. Web, files and Shortcuts are independent switches.
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
        for tool in ExtraTool.allCases where isToolEnabled(tool) {
            switch tool {
            case .calculator: providers.append(JavaScriptToolProvider())
            case .macInfo: providers.append(MacInfoToolProvider())
            case .network: providers.append(NetworkToolProvider(confirmation: NotificationService.shared))
            case .weather:
                var weather = WeatherToolProvider()
                weather.usesCurrentPlace = isToolEnabled(.location)
                providers.append(weather)
            case .location: providers += [LocationToolProvider(), MapsToolProvider()]
            case .browser:
                providers.append(
                    SafariToolProvider(
                        configuration: .init(pageCharacters: settings.pageCharacters, confirmation: NotificationService.shared)))
            case .calendar: providers.append(CalendarToolProvider(confirmation: NotificationService.shared))
            case .timers: providers.append(TimerToolProvider())
            case .screen: providers.append(ScreenToolProvider(confirmation: NotificationService.shared))
            case .currency: providers.append(CurrencyToolProvider())
            case .contacts: providers.append(ContactsToolProvider())
            case .notes: providers.append(NotesToolProvider(confirmation: NotificationService.shared))
            case .mail: providers.append(MailDraftToolProvider())
            case .spotlight: providers.append(SpotlightToolProvider())
            case .macControl: providers.append(MacControlToolProvider())
            case .music: providers.append(MusicToolProvider())
            }
        }
        if settings.shortcutsToolEnabled {
            providers.append(ShortcutToolProvider(configuration: .init(confirmation: NotificationService.shared)))
        }
        let tools: any ToolProvider = CompositeToolProvider(providers)
        Task { await conversation.setTools(tools) }
    }

    // API server (always on: localhost only, no token; falls back to the next port if 11434 is taken)

    /// The chosen port first, then the three after it: a busy 11434 (Ollama) must not leave the app without an API.
    var apiPortCandidates: [Int] { (0..<4).map { settings.apiServerPort + $0 } }
    /// What to type into another program: the chosen address, or this Mac's own when the server listens everywhere.
    var apiURL: URL {
        let host = settings.apiBindHost == "0.0.0.0" ? (NetworkInterfaces.addresses().first?.address ?? "127.0.0.1") : settings.apiBindHost
        return URL(string: "http://\(host):\(apiActivePort ?? settings.apiServerPort)")!
    }

    func startAPI() async {
        stopAPI()
        // Switched off in the settings: nothing listens, and no port is taken from anyone else.
        guard settings.apiServerEnabled else {
            apiStatus = .disabled
            return
        }
        apiStatus = .starting
        for port in apiPortCandidates {
            switch await APIServer.probe(port: port) {
            case .ollama(let version):
                if port == settings.apiServerPort {
                    NotificationService.shared.send(
                        title: String(localized: "API port in use"),
                        body: String(localized: "Ollama \(version) is listening on \(port); Mac-Olama API will use the next free port."))
                }
                continue
            case .occupied:
                continue
            case .free:
                let server = APIServer(
                    configuration: .init(
                        host: settings.apiBindHost, port: port,
                        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"),
                    catalog: catalog, engine: engineManager, downloader: downloader
                ) { [weak self] in await self?.refreshModels() }
                server.setCORSPolicy(corsPolicy)
                do {
                    try server.start()
                } catch {
                    logger.error("API bind on \(port) failed: \(error)")
                    continue  // taken between probe and bind: try the next candidate
                }
                apiServer = server
                apiActivePort = port
                apiStatus = .running(port: port)
                return
            }
        }
        apiStatus = .portBusy(port: settings.apiServerPort)
        NotificationService.shared.send(
            title: String(localized: "API server not started"), body: String(localized: "All candidate ports are busy."))
    }

    func stopAPI() {
        apiServer?.stop()
        apiServer = nil
        apiActivePort = nil
        apiStatus = .disabled
    }
}

/// Watches the models folder via DispatchSource; a cheap single-directory alternative to FSEvents.
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

/// The single settings object. UserDefaults is the source of truth; keys live in `SettingsKey`.
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
    /// An unset numeric key reads as 0; these settings treat that as "use the default".
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
    /// Single observation token: any settings change invalidates observers of any setting (cheap, settings are few).
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
    var panelClosesOnFocusLoss: Bool {
        get { bool(.panelClosesOnFocusLoss) }
        set { set(newValue, .panelClosesOnFocusLoss) }
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
