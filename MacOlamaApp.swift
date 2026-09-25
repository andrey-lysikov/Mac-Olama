//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppIntents
import AppKit

// Pure AppKit lifecycle: an LSUIElement app with no SwiftUI scenes. The only windows are Chats and Download
// (hosted by WindowManager); every other interaction is the menu bar, the quick panel or notifications.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var container: AppContainer!
    private var statusItem: StatusItemController!
    private var panel: QuickPanelController!
    private var servicesProvider: ServicesProvider!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run hosted inside the app: keep it inert then (no status item, API server, downloads or model loading).
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        UserDefaults.standard.register(defaults: SettingsDefaults.registration)
        // An earlier build shortened the tooltip delay in the app's own defaults; the system delay applies again.
        UserDefaults.standard.removeObject(forKey: "NSInitialToolTipDelay")
        NSApp.setActivationPolicy(.accessory)  // LSUIElement: no Dock icon; windows are raised manually
        installMainMenu()
        container = AppContainer()

        WindowManager.shared.configure(container: container)
        // The panel's shortcut: registered now and again whenever the settings change it.
        container.hotkeyChanged = { [weak self] in self?.applyHotkey() }
        NotificationService.shared.configure(container: container)
        panel = QuickPanelController(container: container)
        WindowManager.shared.hidePanel = { [weak panel] in panel?.hide() }
        statusItem = StatusItemController(container: container, panel: panel)

        servicesProvider = ServicesProvider(panel: panel)
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        applyHotkey()

        LaunchAtLogin.sync(enabled: container.settings.launchAtLogin)
        container.start()
    }

    /// ⌘Q closes the chats window instead of quitting: the app lives in the menu bar, and leaving it is the "Quit" item
    /// of the status menu. With no window open it does quit.
    @objc private func closeWindowOrQuit() {
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            window.performClose(nil)
        } else {
            NSApp.terminate(nil)
        }
    }

    /// An agent app gets no main menu for free, and without an Edit menu text fields lose ⌘A/⌘C/⌘V/⌘X/⌘Z.
    /// The menu bar shows it only while the chats window is open (activation policy `.regular`).
    private func applyHotkey() {
        GlobalHotkey.shared.register(container.hotkey) { [weak self] in self?.panel.toggle() }
    }

    private func installMainMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, shift: Bool = false) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if shift { mi.keyEquivalentModifierMask = [.command, .shift] }
            return mi
        }
        let quit = item(String(localized: "Close Window"), #selector(closeWindowOrQuit), "q")
        quit.target = self
        add("Mac-Olama", [quit])
        add(String(localized: "File"), [item(String(localized: "Close Window"), #selector(NSWindow.performClose(_:)), "w")])
        add(
            String(localized: "Edit"),
            [
                item(String(localized: "Undo"), Selector(("undo:")), "z"),
                item(String(localized: "Redo"), Selector(("redo:")), "z", shift: true),
                .separator(),
                item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
                item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
                item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
                item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
            ])
        NSApp.mainMenu = main
    }

    /// Reopening from the Dock or Finder follows the same rule as a click on the status item: the chats window wins
    /// while it is open, otherwise the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if WindowManager.shared.isOpen(.chats) {
            panel?.hide()
            WindowManager.shared.open(.chats)
        } else {
            panel?.show()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Both are nil when the app only hosts unit tests.
        container?.shutdown()
    }
}
