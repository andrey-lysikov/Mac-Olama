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
    private var levelReset: Task<Void, Never>?

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
        if Self.bringToFront(window) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        if !window.isOnActiveSpace {
            switchSpace(to: window)
            return
        }
        // Activation is cooperative since macOS 14 and may be refused, so the window floats above other apps until it
        // succeeds or two seconds pass, then drops back to the normal level.
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        levelReset?.cancel()
        levelReset = Task { [weak window] in
            for _ in 0..<20 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }  // a newer raise resets the level itself
            // `makeKeyAndOrderFront` before the activation landed does not take the keyboard: repeat it once the app is active.
            if NSApp.isActive { window?.makeKeyAndOrderFront(nil) }
            window?.level = .normal
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

    /// A window on another Space: AppKit switches Spaces only when an active app orders its window front, while
    /// `orderFrontRegardless` on an inactive app just raises it over there. So activate first, then order it front.
    private func switchSpace(to window: NSWindow) {
        window.level = .normal
        NSApp.activate()
        levelReset?.cancel()
        levelReset = Task { [weak window] in
            for _ in 0..<20 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(50)) }
            guard !Task.isCancelled else { return }
            window?.makeKeyAndOrderFront(nil)  // VERIFY(mac): switches to the window's Space
        }
    }

    private func makeWindow(id: ID, title: String, size: NSSize, root: AnyView) -> NSWindow {
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
        window.toolbarStyle = .unified
        window.delegate = self
        // Saved under the window ID: the localized title used before changed with the language. Its frame is taken over
        // once, then every other saved frame (also of windows that no longer exist) is dropped.
        let name = "MacOlama.\(id.rawValue)"
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
