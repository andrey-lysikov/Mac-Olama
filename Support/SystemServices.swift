//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Security
import ServiceManagement
import os

// ServicesProvider

/// Handlers for the NSServices declared in Info.plist. `openQuickPanel` is bound to ⌘⇧Space (user-changeable in System Settings).
@MainActor
final class ServicesProvider: NSObject {
    private let panel: QuickPanelController

    init(panel: QuickPanelController) {
        self.panel = panel
    }

    /// NSMessage `openQuickPanel` maps to selector `openQuickPanel:userData:error:`. VERIFY(V15): parameter types.
    @objc func openQuickPanel(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        panel.toggle()
    }

    /// Phase 4: service with NSSendTypes — ask about the selected text.
    @objc func askAboutSelection(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        panel.show(prefill: text)
    }
}

// DeepLink

/// `macolama://ask?url=…` sent by the Safari extension; anything else — including non-web page URLs — is rejected.
enum DeepLink {
    static func page(from url: URL) -> URL? {
        guard url.scheme == "macolama", url.host == "ask",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let raw = items.first(where: { $0.name == "url" })?.value,
            let page = URL(string: raw), page.isWebURL
        else { return nil }
        return page
    }
}

// LaunchAtLogin

/// Launch at login via SMAppService. VERIFY(V9): behaviour for LSUIElement apps outside the App Store.
@MainActor
enum LaunchAtLogin {
    private static let logger = Logger(subsystem: "ru.lysnet.macolama", category: "launch-at-login")

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func sync(enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("SMAppService failed: \(error)")
        }
    }
}
