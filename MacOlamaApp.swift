//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppIntents
import AppKit

// AppKit lifecycle, LSUIElement app: menu bar, quick panel and the chats window.
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
        // Hosted unit tests: keep the app inert.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        replaceRunningInstances()
        UserDefaults.standard.register(defaults: SettingsDefaults.registration)
        // Remove an old custom tooltip delay; use the system one.
        UserDefaults.standard.removeObject(forKey: "NSInitialToolTipDelay")
        NSApp.setActivationPolicy(.accessory)  // No Dock icon; windows are raised manually
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

    private func replaceRunningInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current }
        guard !others.isEmpty else { return }
        // `isTerminated` changes on the run loop, so the wait has to turn it.
        func wait(_ seconds: TimeInterval) {
            let deadline = Date(timeIntervalSinceNow: seconds)
            while others.contains(where: { !$0.isTerminated }), Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            }
        }
        others.forEach { $0.terminate() }
        wait(5)
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        wait(2)
    }

    @objc private func closeWindowOrQuit() {
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            window.performClose(nil)
        } else {
            NSApp.terminate(nil)
        }
    }

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
