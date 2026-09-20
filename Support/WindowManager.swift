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
    private var keyChase: Task<Void, Never>?

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
                    id: id, title: String(localized: "Chats"), size: NSSize(width: 1000, height: 660),
                    root: AnyView(ChatsWindowView().environment(container)))
            }
            window.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            windows[id] = window
        }
        hidePanel?()
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
        if !window.isVisible { window.orderFrontRegardless() }  // a window number the WindowServer knows
        if !Self.bringToFront(window) {
            // Cooperative activation (macOS 14+) may be refused, so the window is raised without waiting for it. A
            // window on another Space follows only an active app, so there the activation has to come first.
            if window.isOnActiveSpace { window.orderFrontRegardless() } else { NSApp.activate() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        takeKeyboard(window)
    }

    /// Ordering a window front before the activation lands leaves it frontmost but not key: it looks inactive and the
    /// text field keeps no caret. A click on the status item makes this worse — the status bar window is the app's key
    /// window while the click is handled. So key status is asked for again, for a second, until the window holds it.
    private func takeKeyboard(_ window: NSWindow) {
        keyChase?.cancel()
        keyChase = Task { [weak window] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let window, window.isVisible else { return }
                if window.isKeyWindow && NSApp.isActive { return }
                // Not `activate(ignoringOtherApps:)` (deprecated): activating our own running application is allowed
                // and is not refused the way the cooperative `NSApp.activate()` can be.
                if !NSApp.isActive { NSRunningApplication.current.activate(options: [.activateAllWindows]) }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Makes this process frontmost with `window` in front, the way the Dock does, switching to the window's desktop.
    /// Public activation is cooperative (may be refused) and never switches desktops for a menu bar app: its status item is
    /// a window on every desktop, so the app always "has a window here". So this uses SkyLight's private
    /// `_SLPSSetFrontProcessWithOptions` (as AltTab does), looked up at run time: without it the public path below is used.
    private static func bringToFront(_ window: NSWindow) -> Bool {
        guard let setFront = privateSetFrontProcess, window.windowNumber > 0 else { return false }
        // The "current process" serial number: no deprecated Process Manager call is needed to name ourselves.
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        return setFront(&psn, UInt32(window.windowNumber), 0x200) == 0  // 0x200: kCPSUserGenerated, as a user click
    }

    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32

    private static let privateSetFrontProcess: SetFrontProcess? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions")
        else { return nil }
        return unsafeBitCast(symbol, to: SetFrontProcess.self)
    }()

    private func makeWindow(id: ID, title: String, size: NSSize, root: AnyView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            // The app draws the title row itself (the window buttons keep their space in it), so the content reaches
            // the top of the window.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        // Without this the window's own opaque fill sits under the sidebar material and nothing shows through it.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden  // the name is drawn in the app's own title row
        // SwiftUI's minimum frame does not stop AppKit from shrinking the window; below this size the content would be clipped.
        window.contentMinSize = NSSize(width: 560, height: 400)
        window.isReleasedWhenClosed = false
        // An ordinary document-like window: other apps can cover it. Clicking the status item brings it front again.
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary, .participatesInCycle, .managed]
        let hosting = NSHostingView(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars]  // SwiftUI .toolbar content goes into this window's toolbar
        hosting.sizingOptions = []  // the window's size is the saved one, not the size SwiftUI would like
        // The title bar is not a safe area here: the app's own title row fills it, level with the window buttons.
        hosting.safeAreaRegions = []
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

    /// Back to accessory mode when the last regular window closes, so no Dock icon lingers.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
        if others.isEmpty {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
