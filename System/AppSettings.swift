//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

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
    var chatsHotkeyKeyCode: Int {
        get { int(.chatsHotkeyKeyCode) }
        set { set(newValue, .chatsHotkeyKeyCode) }
    }
    var chatsHotkeyModifiers: Int {
        get { int(.chatsHotkeyModifiers) }
        set { set(newValue, .chatsHotkeyModifiers) }
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
    var modelOutputTokens: [String: Int] {
        get { dictionary(.modelOutputTokens) }
        set { set(newValue, .modelOutputTokens) }
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
    var sidebarModelsExpanded: Bool {
        get { bool(.sidebarModelsExpanded) }
        set { set(newValue, .sidebarModelsExpanded) }
    }
    var chatFontSize: Double {
        get {
            let value = double(.chatFontSize)
            return value > 0 ? min(max(value, SettingsDefaults.chatFontSizeRange.lowerBound), SettingsDefaults.chatFontSizeRange.upperBound) : SettingsDefaults.chatFontSize
        }
        set { set(min(max(newValue, SettingsDefaults.chatFontSizeRange.lowerBound), SettingsDefaults.chatFontSizeRange.upperBound), .chatFontSize) }
    }
    var extraTools: [String] {
        get { stringArray(.extraTools) }
        set { set(newValue, .extraTools) }
    }
    var huggingFaceToken: String? {
        get { string(.huggingFaceToken) }
        set { set(newValue, .huggingFaceToken) }
    }
    var modelThinkingEffort: [String: String] {
        get { dictionary(.modelThinkingEffort) }
        set { set(newValue, .modelThinkingEffort) }
    }
    func cloudAccount(for provider: CloudProvider) -> CloudAccountConfiguration {
        access(keyPath: \.token)
        let accounts = defaults.dictionary(forKey: SettingsKey.cloudAccounts.rawValue) as? [String: Data] ?? [:]
        return accounts[provider.rawValue].flatMap { try? JSONCoding.decoder.decode(CloudAccountConfiguration.self, from: $0) }
            ?? CloudAccountConfiguration()
    }
    func setCloudAccount(_ account: CloudAccountConfiguration, for provider: CloudProvider) {
        var accounts = defaults.dictionary(forKey: SettingsKey.cloudAccounts.rawValue) as? [String: Data] ?? [:]
        accounts[provider.rawValue] = try? JSONCoding.encoder.encode(account)
        set(accounts, .cloudAccounts)
    }
    var chatProjectPaths: [String: String] {
        get { dictionary(.chatProjectPaths) }
        set { set(newValue, .chatProjectPaths) }
    }
    var codingTaskStates: [String: String] {
        get { dictionary(.codingTaskStates) }
        set { set(newValue, .codingTaskStates) }
    }
    var codingVerificationStatus: [String: String] {
        get { dictionary(.codingVerificationStatus) }
        set { set(newValue, .codingVerificationStatus) }
    }
    var chatPermissionModes: [String: String] {
        get { dictionary(.chatPermissionModes) }
        set { set(newValue, .chatPermissionModes) }
    }

    func permissionMode(for chatID: UUID) -> PermissionMode {
        chatPermissionModes[chatID.uuidString].flatMap(PermissionMode.init) ?? .ask
    }

    func setPermissionMode(_ mode: PermissionMode, for chatID: UUID) {
        var modes = chatPermissionModes
        modes[chatID.uuidString] = mode.rawValue
        chatPermissionModes = modes
    }
}
