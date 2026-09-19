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
    private var spotlightIndexer: SpotlightIndexer!

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
        // Tooltips carry real information here (why a model fits or not), so they should not wait the default ~1.5 s.
        UserDefaults.standard.set(150, forKey: "NSInitialToolTipDelay")
        NSApp.setActivationPolicy(.accessory)  // LSUIElement: no Dock icon; windows are raised manually
        installMainMenu()
        container = AppContainer()

        WindowManager.shared.configure(container: container)
        NotificationService.shared.configure(container: container)
        panel = QuickPanelController(container: container)
        WindowManager.shared.hidePanel = { [weak panel] in panel?.hide() }
        statusItem = StatusItemController(container: container, panel: panel)
        IntentBridge.shared.configure(container: container, panel: panel)
        spotlightIndexer = SpotlightIndexer(store: container.chatStore)
        spotlightIndexer.start()

        servicesProvider = ServicesProvider(panel: panel)
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()

        LaunchAtLogin.sync(enabled: container.settings.launchAtLogin)
        container.start()
        MacOlamaShortcuts.updateAppShortcutParameters()
    }

    /// An agent app gets no main menu for free, and without an Edit menu text fields lose ⌘A/⌘C/⌘V/⌘X/⌘Z.
    /// The menu bar shows it only while the chats window is open (activation policy `.regular`).
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
        add("Mac-Olama", [item(String(localized: "Quit"), #selector(NSApplication.terminate(_:)), "q")])
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

    /// `macolama://ask?url=…` from the Safari extension button: open the panel with the page attached.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let page = DeepLink.page(from: url) { panel?.show(attachingPage: page) }
        }
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
        spotlightIndexer?.stop()
        container?.shutdown()
    }
}
