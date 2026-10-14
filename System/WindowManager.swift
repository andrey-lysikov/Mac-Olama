//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    enum ID: String { case chats }

    static let shared = WindowManager()
    private var windows: [ID: NSWindow] = [:]
    private var toolbarObservations: [ID: NSKeyValueObservation] = [:]
    private var container: AppContainer?
    var hidePanel: (() -> Void)?

    func configure(container: AppContainer) {
        self.container = container
    }

    func openModels() {
        container?.section = .models
        open(.chats)
    }

    func openSettings() {
        container?.section = .settings
        open(.chats)
    }

    func openAbout() {
        container?.section = .about
        open(.chats)
    }

    func isOpen(_ id: ID) -> Bool {
        guard let window = windows[id] else { return false }
        return window.isVisible || window.isMiniaturized
    }

    func isOnScreen(_ id: ID) -> Bool {
        guard let window = windows[id] else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    func window(_ id: ID) -> NSWindow? {
        windows[id]
    }

    func open(_ id: ID) {
        NSApp.setActivationPolicy(.regular)
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
        } else {
            guard let container else { return }
            switch id {
            case .chats:
                window = makeWindow(
                    id: id, title: String(localized: "Chats"), size: NSSize(width: 1000, height: 660),
                    root: AnyView(ChatsWindowView().environment(container)))
            }
            window.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            windows[id] = window
        }
        hidePanel?()
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Order front even if the cooperative activation is refused.
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            // Activating our own app is not refused like `NSApp.activate()`.
            if !NSApp.isActive { NSRunningApplication.current.activate(options: [.activateAllWindows]) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func makeWindow(id: ID, title: String, size: NSSize, root: AnyView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            // Sidebar window with content under the toolbar.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = title  // shown in the toolbar
        // AppKit ignores SwiftUI's minimum frame; avoid clipping.
        window.contentMinSize = NSSize(width: 560, height: 400)
        window.isReleasedWhenClosed = false
        // Normal window level; the status item brings it front.
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary, .participatesInCycle, .managed]
        let hosting = NSHostingView(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars]  // SwiftUI toolbar goes into this window
        hosting.sizingOptions = []  // keep the saved size
        window.contentView = hosting
        window.toolbarStyle = .unified
        // Transparent titlebar without separator.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.delegate = self
        // Frame saved by window ID; drop other stale saved frames.
        let name = "MacOlama.\(id.rawValue)"
        window.layoutIfNeeded()  // first layout before restoring the frame
        // No toolbar display-mode menu; reapplied whenever SwiftUI sets the toolbar.
        toolbarObservations[id] = window.observe(\.toolbar, options: [.initial, .new]) { window, _ in
            MainActor.assumeIsolated {
                window.toolbar?.allowsDisplayModeCustomization = false
                window.toolbar?.allowsUserCustomization = false
                window.toolbar?.displayMode = .iconOnly
            }
        }
        if !window.setFrameUsingName(name), !window.setFrameUsingName("MacOlama.\(title)") { window.center() }
        window.setFrameAutosaveName(name)
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame MacOlama.") {
            if key != "NSWindow Frame \(name)" { defaults.removeObject(forKey: key) }
        }
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        // Back to accessory mode when the last regular window goes, so no Dock icon lingers.
        let others = NSApp.windows.filter { $0 !== sender && $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
        if others.isEmpty {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
        return false
    }
}
