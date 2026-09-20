//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import UserNotifications
import os

// NotificationService

/// All user-facing messages go through Notification Center; the app never shows alert windows.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, ToolConfirmation {
    static let shared = NotificationService()

    enum Category: String {
        case appUpdate = "APP_UPDATE"
        case modelUpdate = "MODEL_UPDATE"
        case downloadFinished = "DOWNLOAD_FINISHED"
        case confirm = "CONFIRM"
        case info = "INFO"
    }

    enum Action: String {
        case downloadUpdate = "DOWNLOAD_UPDATE"
        case updateModel = "UPDATE_MODEL"
        case openChats = "OPEN_CHATS"
        case allow = "ALLOW"
        case deny = "DENY"
    }

    /// Pending Allow/Deny questions keyed by notification id; resolved from the delegate callback.
    private var pendingConfirmations: [String: CheckedContinuation<Bool, Never>] = [:]
    private static let confirmationTimeout: TimeInterval = 90

    private let logger = Logger(subsystem: "ru.lysnet.macolama", category: "notifications")
    private weak var container: AppContainer?

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
            UNNotificationCategory(identifier: Category.info.rawValue, actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [logger] granted, error in
            if let error { logger.error("notification authorization failed: \(error)") }
            if !granted { logger.notice("notifications not granted") }
        }
    }

    func send(title: String, body: String, category: Category = .info, userInfo: [String: String] = [:], identifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue
        content.userInfo = userInfo
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier ?? UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error { logger.error("notification failed: \(error)") }
        }
    }

    /// Tool confirmation: a notification with Allow/Deny; no answer within the timeout counts as Deny.
    func confirm(title: String, detail: String) async -> Bool {
        let id = "confirm-\(UUID().uuidString)"
        return await withCheckedContinuation { continuation in
            // The body runs synchronously on the caller's actor, but the closure itself is typed nonisolated.
            MainActor.assumeIsolated { askConfirmation(id: id, title: title, detail: detail, continuation: continuation) }
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
            case .downloadUpdate:
                if let s = info["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
            case .updateModel:
                if let repo = info["repoID"] as? String { container?.updates.updateModel(repoID: repo) }
            case .openChats:
                WindowManager.shared.open(.chats)
            case nil:
                // Default tap: confirmation → deny; app update → release page; model update → download window; otherwise → chats.
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

/// Daily checks of the app (GitHub Releases) and the models (hub revision); `force` skips the daily guard and always reports.
/// Observable so the model list reacts to `pendingModelUpdates` and `checkingModels`.
@MainActor
@Observable
final class UpdateChecker {
    static let latestReleaseURL = URL(string: "https://github.com/andrey-lysikov/Mac-Olama/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/andrey-lysikov/Mac-Olama/releases/latest")!
    private static let startupDelay: TimeInterval = 600
    private static let pollInterval: TimeInterval = 6 * 3600

    private struct Release: Decodable {
        var tagName: String
        var htmlUrl: String?
    }

    private unowned let container: AppContainer
    private let logger = Logger(subsystem: "ru.lysnet.macolama", category: "updates")
    private var timer: Timer?
    private var appTask: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?
    /// repoID → new revision found by the last check; drives the "Update" menu entries.
    private(set) var pendingModelUpdates: [String: String] = [:]
    /// Models whose single check (the update pictogram) is in flight; the pictogram spins for them.
    private(set) var checkingModels: Set<String> = []

    init(container: AppContainer) {
        self.container = container
    }

    var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// The daily check is always on; there is no setting to disable it.
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
            var request = URLRequest(url: Self.apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try? await URLSession.shared.data(for: request).0
            let parsed = release.flatMap { try? decoder.decode(Release.self, from: $0) }
            guard let self, !Task.isCancelled else { return }
            self.finishApp(release: parsed, installed: installed, force: force)
        }
    }

    private func finishApp(release: Release?, installed: String, force: Bool) {
        // Only an answer counts as today's check: offline at launch, the next 6-hour tick tries again.
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

    /// Update pictogram of one downloaded model: compare its saved revision with the hub and download the new one if there is any.
    /// What the last check said. Notifications can be switched off, and a pictogram that merely stops spinning tells
    /// the user nothing, so the row shows this too.
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
                // Downloaded before revisions were recorded: there is nothing to compare, so no claim is made.
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

    /// Hugging Face: the commit sha; ModelScope: the time of the last update (its model API has no commit id).
    private static func latestRevision(of reference: ModelReference, client: HubClient, modelScope: ModelScopeClient) async -> String? {
        switch reference {
        case .huggingFace(let repo): (try? await client.info(repoID: repo))?.sha
        case .modelScope(let repo):
            (try? await modelScope.info(repoID: repo))?.lastUpdated.map { String(Int($0.timeIntervalSince1970)) }
        }
    }

    /// A branch name instead of a revision means the hub did not report one at download time: nothing to compare.
    private static func isKnown(_ revision: String) -> Bool { !revision.isEmpty && revision != "main" && revision != "master" }

    /// Re-downloads the repo; the downloader replaces the model folder atomically on completion.
    func updateModel(repoID: String) {
        pendingModelUpdates[repoID] = nil
        modelCheckResults[repoID] = nil
        container.download(repoID: repoID)
    }

    /// Versions are two-part (`1.4`); a third component is still understood so an accidental `1.4.1` tag compares sanely.
    nonisolated static func versionNumber(_ value: String) -> Int {
        let scale = [1_000_000, 1_000, 1]
        let components = value.split(whereSeparator: { !$0.isNumber }).prefix(scale.count)
        guard !components.isEmpty else { return 0 }
        return zip(components, scale).reduce(0) { $0 + (Int($1.0) ?? 0) * $1.1 }
    }
}
