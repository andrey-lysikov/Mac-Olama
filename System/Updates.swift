//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import UserNotifications
import os

// NotificationService

@MainActor
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

    private var pendingConfirmations: [String: CheckedContinuation<Bool, Never>] = [:]
    private static let confirmationTimeout: TimeInterval = 90

    private let logger = Logger(subsystem: "ru.lysnet.macolama", category: "notifications")
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
            logger.error("notification authorization failed: \(error)")
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
        Task { @MainActor [logger] in
            guard await authorize() else { return logger.notice("notification dropped: not allowed") }
            do { try await UNUserNotificationCenter.current().add(request) } catch { logger.error("notification failed: \(error)") }
        }
    }

    func confirm(title: String, detail: String) async -> Bool {
        // Without notifications the question would never show and silently time out as Deny.
        guard await ensureAllowed() else { return false }
        let id = "confirm-\(UUID().uuidString)"
        return await withCheckedContinuation { continuation in
            // Hop to the main actor explicitly; callers may be off-main.
            Task { @MainActor in askConfirmation(id: id, title: title, detail: detail, continuation: continuation) }
        }
    }

    private func askConfirmation(id: String, title: String, detail: String, continuation: CheckedContinuation<Bool, Never>) {
        pendingConfirmations[id] = continuation
        send(title: title, body: detail, category: .confirm, identifier: id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.confirmationTimeout))
            self?.resolveConfirmation(id: id, allowed: false)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    private func resolveConfirmation(id: String, allowed: Bool) {
        guard let continuation = pendingConfirmations.removeValue(forKey: id) else { return }
        continuation.resume(returning: allowed)
    }

    // Show banners even while the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let requestID = response.notification.request.identifier
        await MainActor.run {
            switch Action(rawValue: response.actionIdentifier) {
            case .allow: resolveConfirmation(id: requestID, allowed: true)
            case .deny: resolveConfirmation(id: requestID, allowed: false)
            case .openPrivacy:
                if let s = info["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
            case .downloadUpdate:
                if let s = info["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
            case .updateModel:
                if let repo = info["repoID"] as? String { container?.updates.updateModel(repoID: repo) }
            case .openChats:
                WindowManager.shared.open(.chats)
            case nil:
                // Default tap: confirm → deny, app → release, model → library, else chats.
                if pendingConfirmations[requestID] != nil {
                    resolveConfirmation(id: requestID, allowed: false)
                } else if let s = info["url"] as? String, let url = URL(string: s) {
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
    private let logger = Logger(subsystem: "ru.lysnet.macolama", category: "updates")
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
