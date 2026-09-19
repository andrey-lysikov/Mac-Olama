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

    public func createAll() throws {
        for dir in [root, models, downloads, database, attachments, logs] {
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
    case spotlightTimeoutSeconds = "spotlightTimeoutSeconds"  // Double, default 8
    case launchAtLogin = "launchAtLogin"  // Bool, default false
    case apiServerPort = "apiServerPort"  // Int, default 11434; auto-advanced when the port is taken
    case toolsEnabled = "toolsEnabled"  // Bool, default false
    case searchProvider = "searchProvider"  // String: "duckduckgo" (default) or "google"
    case deepWebSearch = "deepWebSearch"  // Bool, default true: more results, longer pages, several sources per answer
    case panelClosesOnFocusLoss = "panelClosesOnFocusLoss"  // Bool, default true
    case fileToolsEnabled = "fileToolsEnabled"  // Bool, default false
    case shortcutsToolEnabled = "shortcutsToolEnabled"  // Bool, default false
    case allowedFolders = "allowedFolders"  // [String] absolute paths the file tools may access
    case modelContextTokens = "modelContextTokens"  // [model id: Int]; missing or 0 = model maximum (max_position_embeddings)
    case panelGeometry = "panelGeometry"  // [Double]: left, bottom, width, max height, 1 (format); 4 items = older top-anchored
    case pendingDownloads = "pendingDownloads"  // Data: JSON list of unfinished downloads, restored at launch
    case lastAppUpdateCheck = "lastAppUpdateCheck"  // Date?
    case lastModelUpdateCheck = "lastModelUpdateCheck"  // Date?
    case huggingFaceToken = "huggingFaceToken"  // String?: Hugging Face access token for gated models
}

public enum SettingsDefaults {
    public static let idleUnloadSeconds: TimeInterval = 300
    public static let spotlightTimeoutSeconds: TimeInterval = 8
    public static let apiServerPort = 11434
    public static let searchProvider = "duckduckgo"

    /// Values for `UserDefaults.register(defaults:)`.
    public static var registration: [String: Any] {
        [
            SettingsKey.idleUnloadSeconds.rawValue: idleUnloadSeconds,
            SettingsKey.spotlightTimeoutSeconds.rawValue: spotlightTimeoutSeconds,
            SettingsKey.launchAtLogin.rawValue: false,
            SettingsKey.apiServerPort.rawValue: apiServerPort,
            SettingsKey.toolsEnabled.rawValue: false,
            SettingsKey.searchProvider.rawValue: searchProvider,
            SettingsKey.deepWebSearch.rawValue: true,
            SettingsKey.panelClosesOnFocusLoss.rawValue: true,
            SettingsKey.fileToolsEnabled.rawValue: false,
            SettingsKey.shortcutsToolEnabled.rawValue: false,
            SettingsKey.allowedFolders.rawValue: [String](),
        ]
    }
}
