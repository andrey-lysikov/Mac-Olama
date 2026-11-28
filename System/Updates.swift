//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import UserNotifications

// NotificationService

@MainActor
@Observable
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, ToolConfirmation {
    static let shared = NotificationService()

    enum Category: String {
        case appUpdate = "APP_UPDATE"
        case modelUpdate = "MODEL_UPDATE"
        case downloadFinished = "DOWNLOAD_FINISHED"
        case confirm = "CONFIRM"
        case access = "ACCESS"
        case info = "INFO"
    }

    enum Action: String {
        case downloadUpdate = "DOWNLOAD_UPDATE"
        case updateModel = "UPDATE_MODEL"
        case openChats = "OPEN_CHATS"
        case allow = "ALLOW"
        case deny = "DENY"
        case openPrivacy = "OPEN_PRIVACY"
    }

    @ObservationIgnored private var pendingApprovals: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private(set) var approvalRequests: [UUID: ToolApprovalRequest] = [:]
    private weak var container: AppContainer?

    private(set) var isDenied = false

    func configure(container: AppContainer) {
        self.container = container
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.appUpdate.rawValue,
                actions: [
                    UNNotificationAction(
                        identifier: Action.downloadUpdate.rawValue, title: String(localized: "Download"), options: [.foreground])
                ],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Category.modelUpdate.rawValue,
                actions: [UNNotificationAction(identifier: Action.updateModel.rawValue, title: String(localized: "Update"), options: [])],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Category.downloadFinished.rawValue,
                actions: [
                    UNNotificationAction(
                        identifier: Action.openChats.rawValue, title: String(localized: "Open Chats"), options: [.foreground])
                ],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Category.confirm.rawValue,
                actions: [
                    UNNotificationAction(identifier: Action.allow.rawValue, title: String(localized: "Allow"), options: []),
                    UNNotificationAction(identifier: Action.deny.rawValue, title: String(localized: "Deny"), options: [.destructive]),
                ],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Category.access.rawValue,
                actions: [
                    UNNotificationAction(identifier: Action.openPrivacy.rawValue, title: String(localized: "Allow"), options: [.foreground])
                ],
                intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.info.rawValue, actions: [], intentIdentifiers: []),
        ])
    }

    func authorize() async -> Bool {
        do {
            isDenied = !(try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]))
        } catch {
            print("notification authorization failed: \(error)")
            isDenied = true
        }
        return !isDenied
    }

    func ensureAllowed() async -> Bool {
        guard await authorize() else {
            openSettings()
            return false
        }
        return true
    }

    func askAccess(to pane: PrivacySettings.Pane) {
        guard let url = pane.url else { return }
        Task { @MainActor in
            guard await authorize() else {
                NSWorkspace.shared.open(url)
                return
            }
            send(
                title: String(localized: "Allow Mac-Olama access to \(pane.title)?"),
                body: String(localized: "A model needs it to answer. Allow opens System Settings, where access is turned on."),
                category: .access, userInfo: ["url": url.absoluteString], identifier: "access-\(pane.rawValue)")
        }
    }

    func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    func send(title: String, body: String, category: Category = .info, userInfo: [String: String] = [:], identifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue
        content.userInfo = userInfo
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier ?? UUID().uuidString, content: content, trigger: nil)
        Task { @MainActor [] in
            guard await authorize() else { return print("notification dropped: not allowed") }
            do { try await UNUserNotificationCenter.current().add(request) } catch { print("notification failed: \(error)") }
        }
    }

    func confirm(title: String, detail: String) async -> Bool {
        await confirm(title: title, detail: detail, chatID: container?.settings.activeChatID)
    }

    func confirmDiff(title: String, diff: String) async -> Bool {
        await confirmDiff(title: title, diff: diff, chatID: container?.settings.activeChatID)
    }

    func confirm(title: String, detail: String, chatID: UUID?) async -> Bool {
        await confirm(title: title, detail: detail, chatID: chatID, category: .other)
    }

    func confirmDiff(title: String, diff: String, chatID: UUID?) async -> Bool {
        await confirmDiff(title: title, diff: diff, chatID: chatID, category: .other)
    }

    func confirm(title: String, detail: String, chatID: UUID?, category: ToolApprovalCategory) async -> Bool {
        await approval(title: title, detail: detail, chatID: chatID, isDiff: false, category: category)
    }

    func confirmDiff(title: String, diff: String, chatID: UUID?, category: ToolApprovalCategory) async -> Bool {
        await approval(title: title, detail: diff, chatID: chatID, isDiff: true, category: category)
    }

    private func approval(
        title: String, detail: String, chatID: UUID?, isDiff: Bool, category: ToolApprovalCategory
    ) async -> Bool {
        guard let chatID = chatID ?? container?.settings.activeChatID else { return false }
        let request = ToolApprovalRequest(chatID: chatID, title: title, detail: detail, isDiff: isDiff, category: category)
        let mode = container?.settings.permissionMode(for: chatID) ?? .ask
        if mode.allowsAutomatically(category) {
            await container?.conversation.recordApproval(request, allowed: true, automatic: true)
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingApprovals[request.id] = continuation
                approvalRequests[request.id] = request
            }
        } onCancel: {
            Task { @MainActor in resolveApproval(id: request.id, allowed: false) }
        }
    }

    func resolveApproval(id: UUID, allowed: Bool) {
        let request = approvalRequests[id]
        approvalRequests[id] = nil
        guard let continuation = pendingApprovals.removeValue(forKey: id) else { return }
        continuation.resume(returning: allowed)
        if let request {
            Task { await container?.conversation.recordApproval(request, allowed: allowed) }
        }
    }

    func approvals(for chatID: UUID?) -> [ToolApprovalRequest] {
        guard let chatID else { return [] }
        return approvalRequests.values.filter { $0.chatID == chatID }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // Show banners even while the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run {
            switch Action(rawValue: response.actionIdentifier) {
            case .allow, .deny: break
            case .openPrivacy:
                if let s = info["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
            case .downloadUpdate:
                if let s = info["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
            case .updateModel:
                if let repo = info["repoID"] as? String { container?.updates.updateModel(repoID: repo) }
            case .openChats:
                WindowManager.shared.open(.chats)
            case nil:
                if let s = info["url"] as? String, let url = URL(string: s) {
                    NSWorkspace.shared.open(url)
                } else if info["repoID"] != nil {
                    WindowManager.shared.openModels()
                } else if response.notification.request.content.categoryIdentifier == Category.downloadFinished.rawValue {
                    WindowManager.shared.open(.chats)
                }
            }
        }
    }
}

// UpdateChecker

@MainActor
@Observable
final class UpdateChecker {
    static let latestReleaseURL = URL(string: "https://github.com/andrey-lysikov/Mac-Olama/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/andrey-lysikov/Mac-Olama/releases/latest")!
    private static let startupDelay: TimeInterval = 600
    private static let pollInterval: TimeInterval = 24 * 3600

    private struct Release: Decodable {
        var tagName: String
        var htmlUrl: String?
    }

    private unowned let container: AppContainer
    private var timer: Timer?
    private var appTask: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?
    private(set) var pendingModelUpdates: [String: String] = [:]
    private(set) var checkingModels: Set<String> = []

    init(container: AppContainer) {
        self.container = container
    }

    var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAll() }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.startupDelay))
            self?.checkAll()
        }
    }

    var isCheckingApp: Bool { appTask != nil }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func checkAll(force: Bool = false) {
        checkApp(force: force)
        checkModels(force: force)
    }

    // App

    func checkApp(force: Bool = false) {
        let installed = installedVersion
        guard !installed.isEmpty else { return }
        if !force {
            guard appTask == nil else { return }
            if let last = container.settings.lastAppUpdateCheck, Calendar.current.isDateInToday(last) { return }
        }
        appTask?.cancel()
        appTask = Task { [weak self] in
            defer { self?.appTask = nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            // No explicit User-Agent, as before: the session's own is enough for the GitHub API.
            let release = try? await HTTP.get(Self.apiURL, timeout: 20, userAgent: nil, accept: "application/vnd.github+json").0
            let parsed = release.flatMap { try? decoder.decode(Release.self, from: $0) }
            guard let self, !Task.isCancelled else { return }
            self.finishApp(release: parsed, installed: installed, force: force)
        }
    }

    private func finishApp(release: Release?, installed: String, force: Bool) {
        // Only an answer counts; offline retries in 6 hours.
        guard let release else {
            if force {
                NotificationService.shared.send(
                    title: String(localized: "Mac-Olama update"), body: String(localized: "Could not reach GitHub to check for updates."))
            }
            return
        }
        container.settings.lastAppUpdateCheck = .now
        let latest = Self.versionNumber(release.tagName)
        let current = Self.versionNumber(installed)
        if latest > 0, current > 0, latest > current {
            NotificationService.shared.send(
                title: String(localized: "Mac-Olama update"),
                body: String(localized: "Version \(release.tagName) is available. You have \(installed)."),
                category: .appUpdate, userInfo: ["url": release.htmlUrl ?? Self.latestReleaseURL.absoluteString], identifier: "app-update"
            )
        } else if force {
            NotificationService.shared.send(
                title: String(localized: "Mac-Olama update"), body: String(localized: "Version \(installed) is up to date."))
        }
    }

    // Models

    func checkModels(force: Bool = false) {
        if !force {
            guard modelsTask == nil else { return }
            if let last = container.settings.lastModelUpdateCheck, Calendar.current.isDateInToday(last) { return }
        }
        modelsTask?.cancel()
        let models = container.models
        let (client, modelScope) = (container.hubClient, container.modelScopeClient)
        modelsTask = Task { [weak self] in
            defer { self?.modelsTask = nil }
            var found: [String: String] = [:]
            var reachable = false
            for model in models {
                guard let manifest = try? ModelManifest.load(from: model.directory), let reference = ModelReference(manifest: manifest)
                else { continue }
                guard let latest = await Self.latestRevision(of: reference, client: client, modelScope: modelScope) else { continue }
                reachable = true
                if Self.isKnown(manifest.revision), latest != manifest.revision {
                    found[model.repoID] = latest
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.finishModels(found: found, reachable: reachable)
        }
    }

    private func finishModels(found: [String: String], reachable: Bool) {
        container.settings.lastModelUpdateCheck = .now
        pendingModelUpdates = found
        for (repo, _) in found where container.downloaderIsIdle(repoID: repo) {
            NotificationService.shared.send(
                title: String(localized: "Model update available"),
                body: String(localized: "\(repo) has a newer revision on its hub."),
                category: .modelUpdate, userInfo: ["repoID": repo], identifier: "model-update-\(repo)"
            )
        }
    }

    enum ModelCheckResult: Equatable { case upToDate, unreachable, noRevision }

    private(set) var modelCheckResults: [String: ModelCheckResult] = [:]

    func checkAndUpdate(_ model: ModelDescriptor) {
        guard !checkingModels.contains(model.repoID), container.downloaderIsIdle(repoID: model.repoID) else { return }
        checkingModels.insert(model.repoID)
        modelCheckResults[model.repoID] = nil
        let (client, modelScope) = (container.hubClient, container.modelScopeClient)
        Task { [weak self] in
            defer { self?.checkingModels.remove(model.repoID) }
            guard let manifest = try? ModelManifest.load(from: model.directory), let reference = ModelReference(manifest: manifest)
            else {
                self?.modelCheckResults[model.repoID] = .noRevision
                return
            }
            let latest = await Self.latestRevision(of: reference, client: client, modelScope: modelScope)
            guard let self else { return }
            guard let latest else {
                self.modelCheckResults[model.repoID] = .unreachable
                return
            }
            guard Self.isKnown(manifest.revision) else {
                // No recorded revision, no claim.
                self.modelCheckResults[model.repoID] = .noRevision
                return
            }
            if latest != manifest.revision {
                self.updateModel(repoID: model.repoID)
            } else {
                self.pendingModelUpdates[model.repoID] = nil
                self.modelCheckResults[model.repoID] = .upToDate
            }
        }
    }

    private static func latestRevision(of reference: ModelReference, client: HubClient, modelScope: ModelScopeClient) async -> String? {
        switch reference {
        case .huggingFace(let repo): (try? await client.info(repoID: repo))?.sha
        case .modelScope(let repo):
            (try? await modelScope.info(repoID: repo))?.lastUpdated.map { String(Int($0.timeIntervalSince1970)) }
        }
    }

    private static func isKnown(_ revision: String) -> Bool { !revision.isEmpty && revision != "main" && revision != "master" }

    func updateModel(repoID: String) {
        pendingModelUpdates[repoID] = nil
        modelCheckResults[repoID] = nil
        container.download(repoID: repoID)
    }

    nonisolated static func versionNumber(_ value: String) -> Int {
        let scale = [1_000_000, 1_000, 1]
        let components = value.split(whereSeparator: { !$0.isNumber }).prefix(scale.count)
        guard !components.isEmpty else { return 0 }
        return zip(components, scale).reduce(0) { $0 + (Int($1.0) ?? 0) * $1.1 }
    }
}
