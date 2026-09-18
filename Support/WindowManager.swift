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

    func configure(container: AppContainer) {
        self.container = container
    }

    /// The model library is a section of the chats window, not a window of its own.
    func openModels() {
        container?.showsModelLibrary = true
        open(.chats)
    }

    /// On screen right now, so a menu bar click can raise this window instead of opening the panel over it.
    func isOpen(_ id: ID) -> Bool {
        guard let window = windows[id] else { return false }
        return window.isVisible || window.isMiniaturized
    }

    /// The window itself, for views that need to observe it (they run inside it, so by then it exists).
    func window(_ id: ID) -> NSWindow? {
        windows[id]
    }

    func open(_ id: ID) {
        let wasAccessory = NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(.regular)
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
        } else {
            guard let container else { return }
            switch id {
            case .chats:
                window = makeWindow(
                    title: String(localized: "Chats"), size: NSSize(width: 1000, height: 660),
                    root: AnyView(ChatsWindowView().environment(container)))
            }
            window.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            windows[id] = window
        }
        raise(window)
        // Two things land after this call returns: leaving accessory mode takes a turn of the run loop, and a status
        // menu item only dismisses its menu afterwards — both leave the window behind the previously active app.
        Task { @MainActor in
            raise(window)
            if wasAccessory {
                try? await Task.sleep(for: .milliseconds(150))
                raise(window)
            }
        }
    }

    private func raise(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Ordering front "regardless" works even while another app is still active, which is the state right after
        // a click in the status menu; `activate` then hands over the focus.
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow(title: String, size: NSSize, root: AnyView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = title
        // SwiftUI's minimum frame does not stop AppKit from shrinking the window; below this size the content would be clipped.
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars]  // SwiftUI .toolbar content goes into this window's toolbar
        window.contentView = hosting
        window.setFrameAutosaveName("MacOlama.\(title)")
        window.toolbarStyle = .unified
        window.delegate = self
        window.center()
        return window
    }

    /// Back to accessory mode when the last regular window closes, so no Dock icon lingers.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
        if others.isEmpty {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
