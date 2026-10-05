//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// App windows hosting SwiftUI via NSHostingView. One window per ID; reopening raises the existing one.
/// The app is LSUIElement: while a regular window is open we switch to `.regular` so it gets ⌘Tab and focus.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    enum ID: String { case chats }

    static let shared = WindowManager()
    private var windows: [ID: NSWindow] = [:]
    private var container: AppContainer?
    /// Hides the quick panel: it floats above everything and would cover the window being opened.
    var hidePanel: (() -> Void)?

    func configure(container: AppContainer) {
        self.container = container
    }

    /// The model library and the settings are sections of the chats window, not windows of their own.
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

    /// On screen right now, so a menu bar click can raise this window instead of opening the panel over it.
    func isOpen(_ id: ID) -> Bool {
        guard let window = windows[id] else { return false }
        return window.isVisible || window.isMiniaturized
    }

    /// Actually seen: shown, not minimized and not fully covered by other windows.
    func isOnScreen(_ id: ID) -> Bool {
        guard let window = windows[id] else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// The window itself, for views that need to observe it (they run inside it, so by then it exists).
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(id: ID, title: String, size: NSSize, root: AnyView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            // A stock sidebar window: the content runs under the toolbar and the sidebar floats over it, as in Finder.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = title  // shown by the system in the toolbar, as Finder shows the folder's name
        // SwiftUI's minimum frame does not stop AppKit from shrinking the window; below this size the content would be clipped.
        window.contentMinSize = NSSize(width: 560, height: 400)
        window.isReleasedWhenClosed = false
        // An ordinary document-like window: other apps can cover it. Clicking the status item brings it front again.
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary, .participatesInCycle, .managed]
        let hosting = NSHostingView(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars]  // SwiftUI .toolbar content goes into this window's toolbar
        hosting.sizingOptions = []  // the window's size is the saved one, not the size SwiftUI would like
        window.contentView = hosting
        window.toolbarStyle = .unified
        window.delegate = self
        // Saved under the window ID: the localized title used before changed with the language. Its frame is taken over
        // once, then every other saved frame (also of windows that no longer exist) is dropped.
        let name = "MacOlama.\(id.rawValue)"
        window.layoutIfNeeded()  // the first SwiftUI layout happens here, before the frame is restored, not after it
        if !window.setFrameUsingName(name), !window.setFrameUsingName("MacOlama.\(title)") { window.center() }
        window.setFrameAutosaveName(name)
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame MacOlama.") {
            if key != "NSWindow Frame \(name)" { defaults.removeObject(forKey: key) }
        }
        return window
    }

    /// Closing only hides the window. A closed window keeps its SwiftUI content alive but detached from the screen, and
    /// selectable text laid out meanwhile — a reply streaming in, the panel writing into the chat — came back drawn
    /// upside down. A window ordered out lays it out the right way up.
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
