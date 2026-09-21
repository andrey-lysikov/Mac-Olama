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

    /// NSMessage `openQuickPanel` maps to selector `openQuickPanel:userData:error:`. Every parameter is optional:
    /// AppKit passes nil for the pasteboard of a no-input service and for userData when Info.plist has no NSUserData.
    @objc func openQuickPanel(_ pasteboard: NSPasteboard?, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        panel.toggle()
    }

    /// Phase 4: service with NSSendTypes — ask about the selected text.
    @objc func askAboutSelection(_ pasteboard: NSPasteboard?, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text = pasteboard?.string(forType: .string), !text.isEmpty else { return }
        panel.show(prefill: text)
    }
}

/// The addresses this Mac can serve the API on, for the interface picker: loopback first, then each IPv4 address.
enum NetworkInterfaces {
    static func addresses() -> [(name: String, address: String)] {
        var found: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return found }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                pointer.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            guard
                let address = SocketAddress.numericHost(
                    pointer.pointee.ifa_addr, length: socklen_t(pointer.pointee.ifa_addr.pointee.sa_len))
            else { continue }
            let name = String(cString: pointer.pointee.ifa_name)
            found.append((name, address))
        }
        return found
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
