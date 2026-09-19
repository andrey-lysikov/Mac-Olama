//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

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
    let ollamaClient = OllamaRegistryClient()
    private(set) var downloader: ModelDownloader
    private(set) var updates: UpdateChecker!
    let logger = Logger(subsystem: "com.macolama.app", category: "container")

    // UI mirror
    private(set) var engineState: EngineState = .unloaded
    private(set) var models: [ModelDescriptor] = []
    /// Model folders that cannot be loaded; the models section offers to download them again or delete them.
    private(set) var brokenModels: [ModelCatalog.BrokenModel] = []
    private(set) var apiStatus: APIStatus = .disabled
    private(set) var downloads: [ActiveDownload] = [] { didSet { persistDownloads() } }
    /// The chats window shows the model library instead of a chat (set from the menu, notifications and the sidebar).
    var showsModelLibrary = false
    /// Raised whenever an action turns out to need a Hugging Face token; the model library answers by opening the token popover.
    var tokenPromptRequested = false
    /// Chats on screen right now (the panel's and the one open in the chats window): a model picked in the menu goes to them.
    var panelChatID: UUID?
    /// Bumped when the panel or the chats window gets a complete answer; the status item blinks if nobody sees it.
    private(set) var answersFinished = 0
    var windowChatID: UUID?
    /// Models connected by API whose server did not answer the last check; menus and pickers show them disabled.
    private(set) var unavailableModelIDs: Set<String> = []
    private var lastAvailabilityCheck: ContinuousClock.Instant?
    private var availabilityTask: Task<Void, Never>?
    var activeModel: ModelDescriptor? { models.first { $0.id == settings.activeModelID } }
    /// Installed models grouped by registry (Hugging Face, Ollama…), empty registries omitted.
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
        var error: String? { if case .failed(let message) = phase { message } else { nil } }
        var finished: Bool { phase == .finished }
        var isRunning: Bool { phase == .running }
        /// Still owed work: queued, running or paused.
        var isActive: Bool { phase == .queued || phase == .running || phase == .paused }
    }

    private var apiServer: APIServer?
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
        } catch {
            logger.error("SwiftData unavailable, falling back to memory store: \(error)")
            store = InMemoryChatStore()
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
            await startAPI()
            updates.start()
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
        let list = await catalog.refresh()
        models = list
        brokenModels = await catalog.brokenModels
        if settings.activeModelID == nil || !list.contains(where: { $0.id == settings.activeModelID }) {
            setActiveModel(list.first)
        }
    }

    /// Checks the servers of models connected by API. Called when the panel or the chats window opens, at most every 30 s:
    /// local models are on disk and need no check.
    func checkModelAvailability() {
        let remotes = models.filter { $0.source == .remote }
        guard availabilityTask == nil else { return }
        guard !remotes.isEmpty else { return unavailableModelIDs = [] }
        if let last = lastAvailabilityCheck, last.duration(to: .now) < .seconds(30) { return }
        let targets = remotes.compactMap { model in (try? RemoteEndpoint.load(from: model.directory)).map { (model.id, $0) } }
        availabilityTask = Task {
            let down = await withTaskGroup(of: String?.self) { group in
                for (id, endpoint) in targets {
                    group.addTask {
                        // No token: reading the Keychain on every open made macOS ask for the password. A server that
                        // refuses us without one is still up.
                        do {
                            _ = try await RemoteEngine.probe(baseURL: endpoint.baseURL, model: endpoint.model, token: nil)
                            return nil
                        } catch RemoteError.http(let status, _) where status == 401 || status == 403 {
                            return nil
                        } catch {
                            return id
                        }
                    }
                }
                var down: Set<String> = []
                for await id in group { if let id { down.insert(id) } }
                return down
            }
            unavailableModelIDs = down
            lastAvailabilityCheck = .now
            availabilityTask = nil
        }
    }

    func isAvailable(_ model: ModelDescriptor) -> Bool { !unavailableModelIDs.contains(model.id) }

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
        if model.source == .remote { KeychainStore.set(nil, account: RemoteEndpoint.tokenAccount(modelID: model.id)) }
        Task {
            if engineState.modelID == model.id { await engineManager.unload() }
            try? await catalog.remove(id: model.id)
            await refreshModels()
        }
    }

    /// "Connect by API": checks that the server answers and has the model, then adds it to the library like a downloaded one.
    /// `address` may omit the scheme (`localhost:11434`); the optional token goes to the Keychain.
    func connectRemote(model: String, address: String, token: String) async throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmed.contains("://") ? trimmed : "http://" + trimmed), base.host() != nil else {
            throw RemoteError.badAddress
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = try await RemoteEngine.probe(
            baseURL: base, model: model.trimmingCharacters(in: .whitespacesAndNewlines), token: token.isEmpty ? nil : token)
        let endpoint = RemoteEndpoint(baseURL: base, model: probe.model, api: probe.api)
        let directory = paths.models.appendingPathComponent(endpoint.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try endpoint.save(to: directory)
        KeychainStore.set(token.isEmpty ? nil : token, account: RemoteEndpoint.tokenAccount(modelID: endpoint.directoryName))
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

    /// The window a model runs with: its saved choice capped by what the model supports.
    func contextTokens(for model: ModelDescriptor) -> Int? {
        guard let chosen = settings.modelContextTokens[model.id], chosen > 0 else { return model.contextLength }
        return model.contextLength.map { min(chosen, $0) } ?? chosen
    }

    private func applyConversationConfiguration() {
        var config = ConversationService.Configuration()
        config.contextTokensByModel = settings.modelContextTokens
        config.deepWebResearch = settings.deepWebSearch
        // Detailed search reformulates queries and reads several pages, each a tool round.
        if settings.deepWebSearch { config.maxToolIterations = 10 }
        Task { await conversation.setConfiguration(config) }
    }

    func unloadNow() { Task { await engineManager.unload() } }

    /// "Unload After → Never" means the model is resident: load it right away and keep it. With any timeout the model
    /// is loaded only by the first message in the panel or a chat.
    func keepModelLoadedIfPinned() {
        guard settings.idleUnloadSeconds == 0, let model = activeModel, engineState.modelID != model.id else { return }
        Task { await engineManager.prewarm(model) }
    }

    func fit(for model: ModelDescriptor) -> ModelFitReport {
        ModelFitReport.evaluate(modelBytes: model.sizeBytes, contextLength: model.contextLength, hardware: hardware)
    }

    // Downloads (shared by the download window, menu, notifications and the update checker)

    /// Accepts `org/repo`, a huggingface.co link, or `name:tag` / ollama.com link.
    func download(repoID: String, title: String? = nil, quantization: String? = nil, sizeBytes: Int64? = nil) {
        guard let ref = ModelReference.parse(repoID) else { return }
        download(ref, title: title, quantization: quantization, sizeBytes: sizeBytes)
    }

    /// Queues the model. Only one download runs at a time; the rest wait in order below it.
    func download(_ reference: ModelReference, title: String? = nil, quantization: String? = nil, sizeBytes: Int64? = nil) {
        let repoID = reference.repoID
        guard downloaderIsIdle(repoID: repoID) else { return }
        downloads.removeAll { $0.repoID == repoID }
        downloads.append(ActiveDownload(repoID: repoID, title: title, quantization: quantization, sizeBytes: sizeBytes))
        startNextDownloadIfIdle()
    }

    // Persistence: a download interrupted by quitting the app continues on the next launch.

    /// Called on every change of `downloads`; progress ticks do not alter the stored projection, so they cost no disk writes.
    private func persistDownloads() {
        let stored = downloads.filter { !$0.finished }.map {
            // Anything not actively queued or running comes back paused, so a failed model never restarts on its own.
            StoredDownload(
                repoID: $0.repoID, title: $0.title, quantization: $0.quantization, sizeBytes: $0.sizeBytes,
                paused: !($0.phase == .running || $0.phase == .queued))
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
                phase: $0.paused ? .paused : .queued)
        }
        startNextDownloadIfIdle()
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
        run(reference)
    }

    private func run(_ reference: ModelReference) {
        let repoID = reference.repoID
        downloadTasks[repoID] = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in await self.downloader.download(reference) {
                    guard let i = self.downloads.firstIndex(where: { $0.repoID == repoID }) else { break }
                    switch event {
                    case .progress(let p): self.downloads[i].progress = p
                    case .finished(let model):
                        // The model now appears in the installed list, so its download row has done its job.
                        await self.refreshModels()
                        self.downloads.removeAll { $0.repoID == repoID }
                        if self.settings.activeModelID == nil { self.setActiveModel(model) }
                        let needsConversion = FileManager.default.fileExists(
                            atPath: model.directory.appendingPathComponent("conversion.json").path)
                        NotificationService.shared.send(
                            title: String(localized: "Model downloaded"),
                            body: needsConversion
                                ? String(localized: "\(model.name) will be converted to MLX 4-bit on first use; this takes a few minutes.")
                                : String(localized: "\(model.name) is ready to use."),
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
                        NotificationService.shared.send(
                            title: String(localized: "Download failed"), body: "\(repoID): \(Self.describe(error))")
                    }
                }
            }
            self.downloadTasks[repoID] = nil
            self.startNextDownloadIfIdle()
        }
    }

    /// Stops the transfer but keeps the row and the partial files; the queue moves on to the next model.
    /// A model that is only waiting its turn can be paused too, so it stops being picked up when the queue advances.
    func pauseDownload(repoID: String) {
        guard let i = downloads.firstIndex(where: { $0.repoID == repoID }), downloads[i].phase == .running || downloads[i].phase == .queued
        else { return }
        let wasRunning = downloads[i].isRunning
        downloads[i].phase = .paused
        if wasRunning { Task { await downloader.cancel(repoID: repoID) } }
    }

    /// Continue: this model goes to the head of the queue and starts right away. Whatever was running goes back into the
    /// queue (not paused), so it picks up where it stopped as soon as this one is done.
    func resumeDownload(repoID: String) {
        guard let i = downloads.firstIndex(where: { $0.repoID == repoID }), downloads[i].phase == .paused || downloads[i].phase == .queued
        else { return }
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

    /// Removes the row; a running transfer is stopped first.
    func cancelDownload(repoID: String) {
        guard let i = downloads.firstIndex(where: { $0.repoID == repoID }) else { return }
        let wasRunning = downloads[i].isRunning
        downloads.remove(at: i)
        if wasRunning { Task { await downloader.cancel(repoID: repoID) } }
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
        case HubError.cancelled: String(localized: "Cancelled.")
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
    }

    // Tools

    func setToolsEnabled(_ enabled: Bool) {
        settings.toolsEnabled = enabled
        updateTools()
    }

    func setSearchProvider(_ provider: String) {
        settings.searchProvider = provider
        updateTools()
    }

    func setDeepWebSearch(_ enabled: Bool) {
        settings.deepWebSearch = enabled
        updateTools()
        applyConversationConfiguration()
    }

    func setFileToolsEnabled(_ enabled: Bool) {
        settings.fileToolsEnabled = enabled
        updateTools()
    }

    func setShortcutsToolEnabled(_ enabled: Bool) {
        settings.shortcutsToolEnabled = enabled
        updateTools()
    }

    func addAllowedFolder(_ url: URL) {
        var list = settings.allowedFolders
        let path = url.standardizedFileURL.path
        if !list.contains(path) { list.append(path) }
        settings.allowedFolders = list
        updateTools()
    }

    func removeAllowedFolder(_ path: String) {
        settings.allowedFolders.removeAll { $0 == path }
        updateTools()
    }

    /// Rebuilds the composite tool provider from settings. Web, files and Shortcuts are independent switches.
    func updateTools() {
        var providers: [any ToolProvider] = []
        if settings.toolsEnabled {
            let provider: any SearchProvider = settings.searchProvider == "google" ? GoogleProvider() : DuckDuckGoProvider()
            providers.append(WebToolProvider(provider: provider, configuration: settings.deepWebSearch ? .detailed : .init()))
        }
        if settings.fileToolsEnabled, !settings.allowedFolders.isEmpty {
            providers.append(
                FileToolProvider(configuration: .init(allowedFolders: settings.allowedFolders.map { URL(fileURLWithPath: $0) })))
        }
        if settings.shortcutsToolEnabled {
            providers.append(ShortcutToolProvider(configuration: .init(confirmation: NotificationService.shared)))
        }
        let tools: any ToolProvider = CompositeToolProvider(providers)
        Task { await conversation.setTools(tools) }
    }

    // API server (always on: localhost only, no token; falls back to the next port if 11434 is taken)

    static let apiPortCandidates = [11434, 11435, 11436, 11437]
    var apiURL: URL { URL(string: "http://127.0.0.1:\(settings.apiServerPort)")! }

    func startAPI() async {
        stopAPI()
        apiStatus = .starting
        for port in Self.apiPortCandidates {
            switch await APIServer.probe(port: port) {
            case .ollama(let version):
                if port == Self.apiPortCandidates[0] {
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
                        host: "127.0.0.1", port: port,
                        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"),
                    catalog: catalog, engine: engineManager, downloader: downloader
                ) { [weak self] in await self?.refreshModels() }
                do {
                    try server.start()
                } catch {
                    logger.error("API bind on \(port) failed: \(error)")
                    continue  // taken between probe and bind: try the next candidate
                }
                apiServer = server
                settings.apiServerPort = port
                apiStatus = .running(port: port)
                return
            }
        }
        apiStatus = .portBusy(port: Self.apiPortCandidates[0])
        NotificationService.shared.send(
            title: String(localized: "API server not started"), body: String(localized: "All candidate ports are busy."))
    }

    func stopAPI() {
        apiServer?.stop()
        apiServer = nil
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
    private func bool(_ key: SettingsKey) -> Bool { access(keyPath: \.token); return defaults.bool(forKey: key.rawValue) }
    private func double(_ key: SettingsKey) -> Double { access(keyPath: \.token); return defaults.double(forKey: key.rawValue) }
    private func int(_ key: SettingsKey) -> Int { access(keyPath: \.token); return defaults.integer(forKey: key.rawValue) }
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
    var spotlightTimeoutSeconds: TimeInterval {
        get { double(.spotlightTimeoutSeconds) }
        set { set(newValue, .spotlightTimeoutSeconds) }
    }
    var launchAtLogin: Bool {
        get { bool(.launchAtLogin) }
        set { set(newValue, .launchAtLogin) }
    }
    var apiServerPort: Int {
        get { int(.apiServerPort) }
        set { set(newValue, .apiServerPort) }
    }
    var toolsEnabled: Bool {
        get { bool(.toolsEnabled) }
        set { set(newValue, .toolsEnabled) }
    }
    var searchProvider: String {
        get { string(.searchProvider) ?? SettingsDefaults.searchProvider }
        set { set(newValue, .searchProvider) }
    }
    var deepWebSearch: Bool {
        get { bool(.deepWebSearch) }
        set { set(newValue, .deepWebSearch) }
    }
    var fileToolsEnabled: Bool {
        get { bool(.fileToolsEnabled) }
        set { set(newValue, .fileToolsEnabled) }
    }
    var modelContextTokens: [String: Int] {
        get {
            access(keyPath: \.token)
            return defaults.dictionary(forKey: SettingsKey.modelContextTokens.rawValue) as? [String: Int] ?? [:]
        }
        set { set(newValue, .modelContextTokens) }
    }
    var shortcutsToolEnabled: Bool {
        get { bool(.shortcutsToolEnabled) }
        set { set(newValue, .shortcutsToolEnabled) }
    }
    var allowedFolders: [String] {
        get { access(keyPath: \.token); return defaults.stringArray(forKey: SettingsKey.allowedFolders.rawValue) ?? [] }
        set { set(newValue, .allowedFolders) }
    }
    var panelClosesOnFocusLoss: Bool {
        get { bool(.panelClosesOnFocusLoss) }
        set { set(newValue, .panelClosesOnFocusLoss) }
    }
    var panelGeometry: [Double] {
        get { access(keyPath: \.token); return defaults.array(forKey: SettingsKey.panelGeometry.rawValue) as? [Double] ?? [] }
        set { set(newValue, .panelGeometry) }
    }
    var pendingDownloads: Data? {
        get { access(keyPath: \.token); return defaults.data(forKey: SettingsKey.pendingDownloads.rawValue) }
        set { set(newValue, .pendingDownloads) }
    }
    var lastAppUpdateCheck: Date? {
        get { access(keyPath: \.token); return defaults.object(forKey: SettingsKey.lastAppUpdateCheck.rawValue) as? Date }
        set { set(newValue, .lastAppUpdateCheck) }
    }
    var lastModelUpdateCheck: Date? {
        get { access(keyPath: \.token); return defaults.object(forKey: SettingsKey.lastModelUpdateCheck.rawValue) as? Date }
        set { set(newValue, .lastModelUpdateCheck) }
    }
    var huggingFaceToken: String? {
        get { string(.huggingFaceToken) }
        set { set(newValue, .huggingFaceToken) }
    }
}
