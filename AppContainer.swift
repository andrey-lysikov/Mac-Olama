//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Observation

// Core state and lifecycle; features live in AppContainer+<Area>.swift extensions.
@MainActor
@Observable
final class AppContainer {
    let paths: AppPaths
    let settings: AppSettings
    let catalog: ModelCatalog
    let engineManager: EngineManager
    private let remoteEngine: RemoteEngine
    let chatStore: any ChatStore
    let conversation: ConversationService
    let hardware: HardwareProfile
    var hubClient: HubClient
    let modelScopeClient = ModelScopeClient()
    var downloader: ModelDownloader
    private let cloudStores: [CloudProvider: CloudStore]
    private(set) var updates: UpdateChecker!
    private(set) var engineState: EngineState = .unloaded
    var models: [ModelDescriptor] = []
    var brokenModels: [ModelCatalog.BrokenModel] = []
    var apiStatus: APIStatus = .disabled
    var downloads: [ActiveDownload] = [] { didSet { persistDownloads() } }
    enum Section: Equatable {
        case chat, cloud(CloudProvider), models, settings, about
        var cloudProvider: CloudProvider? {
            if case .cloud(let provider) = self { return provider }
            return nil
        }
    }
    var section: Section = .chat
    var tokenPromptRequested = false
    var panelChatID: UUID?
    private(set) var answersFinished = 0
    private var titleTasks: [UUID: Task<Void, Never>] = [:]
    var windowChatID: UUID?
    var requestedWindowChatID: UUID?

    var liveProgress: [UUID: GenerationProgress] = [:]
    var toolSpecs: [ToolSpec] = []
    let draft = ComposerDraft()

    func openInChats(_ chatID: UUID?) {
        section = .chat
        requestedWindowChatID = chatID
        WindowManager.shared.open(.chats)
    }
    var unavailableModelIDs: Set<String> = []
    var lastAvailabilityCheck: ContinuousClock.Instant?
    var availabilityTask: Task<Void, Never>?
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

    var apiServer: APIServer?
    var apiRestartTask: Task<Void, Never>?
    var apiGeneration = 0
    var apiPortBusy = false
    private var stateTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?
    var downloadTasks: [String: Task<Void, Never>] = [:]
    var downloaderNeedsRebuild = false
    var persistedDownloads: [StoredDownload] = []

    struct StoredDownload: Codable, Equatable {
        var repoID: String
        var title: String?
        var quantization: String?
        var sizeBytes: Int64?
        var paused: Bool
        var drafterFor: String?
    }

    var checkpointSampling: [String: SamplingParams] = [:]
    var strayDrafters: [ModelDescriptor] = []
    var drafterVerdicts: [String: String] = [:]
    var baseModelLookups: Set<String> = []

    var hotkeyChanged: (() -> Void)?
    @ObservationIgnored lazy var codingSnapshots = CodingSnapshotStore(directory: paths.coding)
    @ObservationIgnored lazy var codingTasks = CodingTaskManager(directory: paths.coding)
    @ObservationIgnored lazy var codingProjects = CodingProjectStore(
        projects: settings.chatProjectPaths, states: settings.codingTaskStates, verification: settings.codingVerificationStatus,
        saveProjects: { [weak self] values in Task { @MainActor in self?.settings.chatProjectPaths = values } },
        saveStates: { [weak self] values in Task { @MainActor in self?.settings.codingTaskStates = values } },
        saveVerification: { [weak self] values in Task { @MainActor in self?.settings.codingVerificationStatus = values } })

    init() {
        let paths = AppPaths.standard()
        try? paths.createAll()
        self.paths = paths
        self.settings = AppSettings()
        self.hardware = HardwareProfile.current(recommendedWorkingSetBytes: MLXEngine.recommendedWorkingSetBytes())
        self.catalog = ModelCatalog(modelsDirectory: paths.models)
        let remote = RemoteEngine()
        self.remoteEngine = remote
        self.engineManager = EngineManager(
            engine: RoutingEngine(local: MLXEngine(), remote: remote),
            configuration: .init(idleUnloadSeconds: settings.idleUnloadSeconds))

        let store: any ChatStore
        do {
            store = try SwiftDataChatStore(directory: paths.database)
            self.storeFailure = nil
        } catch {
            print("Chat store failed to open: \(error)")
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
        let appSettings = self.settings
        self.cloudStores = Dictionary(uniqueKeysWithValues: CloudProvider.allCases.map {
            ($0, CloudStore(provider: $0, settings: appSettings, modelsDirectory: paths.models))
        })
        self.updates = UpdateChecker(container: self)
        for store in cloudStores.values {
            store.onChange = { [weak self] in Task { await self?.refreshModels() } }
        }
    }

    func cloudStore(for provider: CloudProvider) -> CloudStore { cloudStores[provider]! }

    func start() {
        stateTask = Task { [engineManager] in
            for await state in await engineManager.states() { self.engineState = state }
        }
        watcher = DirectoryWatcher(url: paths.models) { [weak self] in Task { await self?.refreshModels() } }
        for store in cloudStores.values { store.start() }
        Task {
            for store in cloudStores.values {
                await remoteEngine.setTokenRefresher({ [store] in try await store.validToken() }, for: store.provider.source)
                await remoteEngine.setQuotaExhaustedHandler({ [store] in
                    await MainActor.run { store.markQuotaExhausted() }
                }, for: store.provider.source)
            }
        }
        Task {
            let chats = (try? await chatStore.allChats(includeArchived: true)) ?? []
            let chatIDs = Set(chats.map(\.id))
            await codingProjects.cleanupTemporaryDirectories(keeping: chatIDs)
            await codingSnapshots.prune(keeping: chatIDs)
            await codingTasks.prune(keeping: chatIDs)
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
        for store in cloudStores.values { store.stop() }
        updates.stop()
        Task { await engineManager.unload() }
    }

    func answerFinished(_ message: Message) {
        guard !message.isPartial else { return }
        answersFinished += 1
        titleTasks[message.chatID]?.cancel()
        titleTasks[message.chatID] = Task { try? await conversation.refineTitle(chatID: message.chatID) }
    }

    func setActiveChat(_ id: UUID?) {
        settings.activeChatID = id
        Task { await conversation.setActiveChat(id: id) }
    }

    func isQuotaExhausted(_ model: ModelDescriptor) -> Bool {
        CloudProvider(source: model.source).flatMap { cloudStores[$0] }?.isExhausted == true
    }

    func exhaustedText(for model: ModelDescriptor) -> String {
        CloudProvider(source: model.source).flatMap { cloudStores[$0] }?.exhaustedText ?? ""
    }
}
