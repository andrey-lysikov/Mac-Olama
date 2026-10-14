//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// AppPaths

public struct AppPaths: Sendable {
    public static let appFolderName = "Mac-Olama"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func standard() -> AppPaths {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return AppPaths(root: base.appendingPathComponent(appFolderName, isDirectory: true))
    }

    public var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    public var database: URL { root.appendingPathComponent("db", isDirectory: true) }
    public var attachments: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var icons: URL { root.appendingPathComponent("icons", isDirectory: true) }

    public func createAll() throws {
        for dir in [root, models, downloads, database, attachments, logs, icons] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// SettingsKeys

public enum SettingsKey: String, CaseIterable, Sendable {
    case activeModelID = "activeModelID"
    case activeChatID = "activeChatID"
    case idleUnloadSeconds = "idleUnloadSeconds"  // Double, default 300
    case launchAtLogin = "launchAtLogin"  // Bool, default false
    case apiServerPort = "apiServerPort"  // Int, default 11434
    case toolsEnabled = "toolsEnabled"  // Bool, default false
    case searchProvider = "searchProvider"  // String: "duckduckgo" (default) or "google"
    case fileToolsEnabled = "fileToolsEnabled"  // Bool, default false
    case shortcutsToolEnabled = "shortcutsToolEnabled"  // Bool, default false
    case allowedFolders = "allowedFolders"  // [String] absolute paths the file tools may access
    case modelContextTokens = "modelContextTokens"  // [model id: Int]; 0 = model maximum
    case panelGeometry = "panelGeometry"  // [Double]: left, bottom, width, max height, format
    case pendingDownloads = "pendingDownloads"  // Data: JSON of unfinished downloads
    case lastAppUpdateCheck = "lastAppUpdateCheck"  // Date?
    case lastModelUpdateCheck = "lastModelUpdateCheck"  // Date?
    case sidebarWidth = "sidebarWidth"  // Double: width of the chat list column
    case remoteTokens = "remoteTokens"  // [model id: token] for API models
    case extraTools = "extraTools"  // [String]: enabled `ExtraTool` raw values
    case huggingFaceToken = "huggingFaceToken"  // String?: Hugging Face token
    case modelTemperatures = "modelTemperatures"  // [model id: Double]; missing = model default
    case apiServerEnabled = "apiServerEnabled"  // Bool: API server on
    case apiBindHost = "apiBindHost"  // String: listen address
    case apiCORSMode = "apiCORSMode"  // String: localhost, off or custom
    case apiCORSOrigins = "apiCORSOrigins"  // String: comma-separated custom origins
    case hotkeyKeyCode = "hotkeyKeyCode"  // Int: panel shortcut key; 0 = none
    case hotkeyModifiers = "hotkeyModifiers"  // Int: Carbon modifier mask of that shortcut
    case toolIterations = "toolIterations"  // Int: tool rounds before answering
    case pageCharacters = "pageCharacters"  // Int: web page characters given to the model
    case searchResults = "searchResults"  // Int: how many results a web search returns
    case reasoningShown = "reasoningShown"  // [String]: models with visible thinking
    case greedyDrafters = "greedyDrafters"  // [String]: drafters needing greedy decoding
    case speculativeModels = "speculativeModels"  // [String]: models using MTP speculation
    case downloadSpeedLimitMBps = "downloadSpeedLimitMBps"  // Int, MB/s cap for model downloads; 0 = unlimited
    case downloadConcurrentFiles = "downloadConcurrentFiles"  // Int 1...4: parallel files per download
    case preferredLanguage = "preferredLanguage"  // String: reply language; empty = user's
    case voiceInputEnabled = "voiceInputEnabled"  // Bool: the microphone button next to the paperclip
    case voiceAutoSend = "voiceAutoSend"  // Bool: send dictated text after a pause
}

public enum SettingsDefaults {
    public static let idleUnloadSeconds: TimeInterval = 300
    public static let apiServerPort = 11434
    public static let apiBindHost = "127.0.0.1"
    public static let apiCORSMode = "localhost"
    public static let downloadConcurrentFiles = 2
    public static let toolIterations = 10
    public static let hotkeyKeyCode = 49  // kVK_Space
    public static let hotkeyModifiers = 2048  // optionKey
    public static let pageCharacters = 12_000
    public static let searchResults = 8
    public static let searchProvider = "duckduckgo"

    public static var registration: [String: Any] {
        [
            SettingsKey.idleUnloadSeconds.rawValue: idleUnloadSeconds,
            SettingsKey.launchAtLogin.rawValue: false,
            SettingsKey.apiServerPort.rawValue: apiServerPort,
            SettingsKey.apiServerEnabled.rawValue: true,
            SettingsKey.apiCORSMode.rawValue: apiCORSMode,
            SettingsKey.apiCORSOrigins.rawValue: "",
            SettingsKey.toolsEnabled.rawValue: false,
            SettingsKey.searchProvider.rawValue: searchProvider,
            SettingsKey.hotkeyKeyCode.rawValue: hotkeyKeyCode,
            SettingsKey.hotkeyModifiers.rawValue: hotkeyModifiers,
            SettingsKey.fileToolsEnabled.rawValue: false,
            SettingsKey.shortcutsToolEnabled.rawValue: false,
            SettingsKey.allowedFolders.rawValue: [String](),
            SettingsKey.extraTools.rawValue: [String](),
            SettingsKey.remoteTokens.rawValue: [String: String](),
            SettingsKey.sidebarWidth.rawValue: 260.0,
            SettingsKey.downloadSpeedLimitMBps.rawValue: 0,
            SettingsKey.downloadConcurrentFiles.rawValue: downloadConcurrentFiles,
            SettingsKey.preferredLanguage.rawValue: "",
            SettingsKey.voiceInputEnabled.rawValue: true,
            SettingsKey.voiceAutoSend.rawValue: false,
        ]
    }
}

// RemoteTokens

public enum RemoteTokens {
    public static func token(for modelID: String) -> String? {
        let tokens = UserDefaults.standard.dictionary(forKey: SettingsKey.remoteTokens.rawValue) as? [String: String]
        return tokens?[modelID].flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func set(_ token: String?, for modelID: String) {
        var tokens = UserDefaults.standard.dictionary(forKey: SettingsKey.remoteTokens.rawValue) as? [String: String] ?? [:]
        if let token, !token.isEmpty { tokens[modelID] = token } else { tokens[modelID] = nil }
        UserDefaults.standard.set(tokens, forKey: SettingsKey.remoteTokens.rawValue)
    }
}
