//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// AppPaths

/// App working paths. Root is `~/Library/Application Support/Mac-Olama/` (no sandbox, see R13).
public struct AppPaths: Sendable {
    public static let appFolderName = "Mac-Olama"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Standard location for the current user.
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
    /// Greyscale avatars behind the model icons, one PNG per Hugging Face account.
    public var icons: URL { root.appendingPathComponent("icons", isDirectory: true) }

    public func createAll() throws {
        for dir in [root, models, downloads, database, attachments, logs, icons] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// SettingsKeys

/// UserDefaults keys; the only place they are listed.
public enum SettingsKey: String, CaseIterable, Sendable {
    case activeModelID = "activeModelID"
    case activeChatID = "activeChatID"
    case idleUnloadSeconds = "idleUnloadSeconds"  // Double, default 300
    case launchAtLogin = "launchAtLogin"  // Bool, default false
    case apiServerPort = "apiServerPort"  // Int, default 11434; auto-advanced when the port is taken
    case toolsEnabled = "toolsEnabled"  // Bool, default false
    case searchProvider = "searchProvider"  // String: "duckduckgo" (default) or "google"
    case panelClosesOnFocusLoss = "panelClosesOnFocusLoss"  // Bool, default true
    case fileToolsEnabled = "fileToolsEnabled"  // Bool, default false
    case shortcutsToolEnabled = "shortcutsToolEnabled"  // Bool, default false
    case allowedFolders = "allowedFolders"  // [String] absolute paths the file tools may access
    case modelContextTokens = "modelContextTokens"  // [model id: Int]; missing or 0 = model maximum (max_position_embeddings)
    case panelGeometry = "panelGeometry"  // [Double]: left, bottom, width, max height, 1 (format); 4 items = older top-anchored
    case pendingDownloads = "pendingDownloads"  // Data: JSON list of unfinished downloads, restored at launch
    case lastAppUpdateCheck = "lastAppUpdateCheck"  // Date?
    case lastModelUpdateCheck = "lastModelUpdateCheck"  // Date?
    case sidebarWidth = "sidebarWidth"  // Double: width of the chat list column
    case remoteTokens = "remoteTokens"  // [model id: token] of models connected by API; empty when a server needs none
    case extraTools = "extraTools"  // [String]: `ExtraTool` raw values the user switched on (calculator, macInfo, …)
    case huggingFaceToken = "huggingFaceToken"  // String?: Hugging Face access token for gated models
    case modelTemperatures = "modelTemperatures"  // [model id: Double]; missing = the temperature the model ships with
    case apiServerEnabled = "apiServerEnabled"  // Bool: whether other programs may talk to the models through us
    case apiBindHost = "apiBindHost"  // String: the address the API listens on; "127.0.0.1" = this Mac only
    case hotkeyKeyCode = "hotkeyKeyCode"  // Int: virtual key of the panel's shortcut; 0 = no shortcut
    case hotkeyModifiers = "hotkeyModifiers"  // Int: Carbon modifier mask of that shortcut
    case toolIterations = "toolIterations"  // Int: how many times in a row the model may use tools before answering
    case pageCharacters = "pageCharacters"  // Int: how much of a web page the model is given, in characters
    case searchResults = "searchResults"  // Int: how many results a web search returns
    case reasoningShown = "reasoningShown"  // [String]: models whose thinking is shown in the transcript
    case greedyDrafters = "greedyDrafters"  // [String]: models whose drafter only verifies greedy decoding
    case speculativeModels = "speculativeModels"  // [String]: model ids answering with MTP speculation (greedy decoding)
}

public enum SettingsDefaults {
    public static let idleUnloadSeconds: TimeInterval = 300
    public static let apiServerPort = 11434
    public static let apiBindHost = "127.0.0.1"
    public static let toolIterations = 10
    /// ⌥Space out of the box: free on a stock system and easy to reach with one hand.
    public static let hotkeyKeyCode = 49  // kVK_Space
    public static let hotkeyModifiers = 2048  // optionKey
    public static let pageCharacters = 12_000
    public static let searchResults = 8
    public static let searchProvider = "duckduckgo"

    /// Values for `UserDefaults.register(defaults:)`.
    public static var registration: [String: Any] {
        [
            SettingsKey.idleUnloadSeconds.rawValue: idleUnloadSeconds,
            SettingsKey.launchAtLogin.rawValue: false,
            SettingsKey.apiServerPort.rawValue: apiServerPort,
            SettingsKey.apiServerEnabled.rawValue: true,
            SettingsKey.toolsEnabled.rawValue: false,
            SettingsKey.searchProvider.rawValue: searchProvider,
            SettingsKey.panelClosesOnFocusLoss.rawValue: true,
            SettingsKey.hotkeyKeyCode.rawValue: hotkeyKeyCode,
            SettingsKey.hotkeyModifiers.rawValue: hotkeyModifiers,
            SettingsKey.fileToolsEnabled.rawValue: false,
            SettingsKey.shortcutsToolEnabled.rawValue: false,
            SettingsKey.allowedFolders.rawValue: [String](),
            SettingsKey.extraTools.rawValue: [String](),
            SettingsKey.remoteTokens.rawValue: [String: String](),
            SettingsKey.sidebarWidth.rawValue: 260.0,
        ]
    }
}

// RemoteTokens

/// Optional tokens of models connected by API, kept in the settings like everything else (the customer's call: the
/// Keychain asked for a password on every rebuild of an ad-hoc signed app). Readable by anything running as this user.
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
