//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreImage
import SwiftUI

// StatusItemController

/// Menu bar icon: left click opens the panel, right click the menu. Follows `AppContainer.engineState` through the tooltip
/// and blinks while an answer is waiting that neither the panel nor the chats window showed.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let container: AppContainer
    private let panel: QuickPanelController
    private let item: NSStatusItem
    private var observationTask: Task<Void, Never>?
    private var blinkTimer: Timer?
    private var seenAnswers = 0
    /// A template silhouette with the features cut out: the menu bar tints it for light and dark bars and for highlight.
    private static let icon: NSImage? = {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }()

    init(container: AppContainer, panel: QuickPanelController) {
        self.container = container
        self.panel = panel
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = Self.icon
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observeState()
    }

    // No deinit: the controller lives as long as the app; the observation task only holds `self` weakly.

    // Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        stopBlinking()
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) { showMenu() } else { activate() }
    }

    /// A left click shows one thing at a time: the chats window when it is already open, the panel otherwise.
    /// The menu items stay explicit — they open whichever of the two the user picked.
    private func activate() {
        guard WindowManager.shared.isOpen(.chats) else {
            panel.toggle()
            return
        }
        panel.hide()
        WindowManager.shared.open(.chats)
    }

    private func showMenu() {
        let menu = StatusMenuBuilder(container: container, panel: panel).build()
        menu.delegate = self
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil  // otherwise left click would open the menu too
    }

    // State

    private func observeState() {
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                // Register interest without keeping `self` alive across the suspension.
                guard let container = self?.container else { return }
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    // The body runs on the caller's actor, but the closure is typed nonisolated.
                    MainActor.assumeIsolated {
                        withObservationTracking {
                            _ = container.engineState
                            _ = container.downloads
                            _ = container.answersFinished
                        } onChange: {
                            c.resume()
                        }
                    }
                }
                guard let self else { return }
                self.render(container.engineState)
                self.noticeAnswers()
            }
        }
        render(container.engineState)
    }

    // Unseen answer

    private func noticeAnswers() {
        guard container.answersFinished != seenAnswers else { return }
        seenAnswers = container.answersFinished
        guard !answerIsVisible, blinkTimer == nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.blink() }
        }
    }

    private var answerIsVisible: Bool { panel.isVisible || WindowManager.shared.isOnScreen(.chats) }

    /// Opening the panel or the chats window some other way (shortcut, Spotlight, Dock) also counts as seeing the answer.
    private func blink() {
        guard let button = item.button, !answerIsVisible else { return stopBlinking() }
        button.alphaValue = button.alphaValue < 1 ? 1 : 0.2
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        item.button?.alphaValue = 1
    }

    /// The icon stays still; state is conveyed by the tooltip alone (the only motion is the unseen-answer blink).
    private func render(_ state: EngineState) {
        guard let button = item.button else { return }
        button.image = Self.icon
        let downloading = container.downloads.contains { $0.isRunning }
        switch state {
        case .unloaded:
            button.toolTip = downloading ? String(localized: "Downloading model…") : String(localized: "Model unloaded")
        case .loading(let id, let progress):
            button.toolTip = String(localized: "Loading model \(id)… \(progress.formatted(.percent.precision(.fractionLength(0))))")
        case .ready(let id):
            button.toolTip = String(localized: "Ready · \(id)")
        case .generating(let id, _, let tps):
            button.toolTip = String(localized: "Generating · \(id) · \(Int(tps)) tok/s")
        case .error(let message):
            let warning = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: message)
            warning?.isTemplate = true
            button.image = warning
            button.toolTip = message
        }
    }
}

// GlyphImage

/// Emoji hub marks rendered as black-and-white images, for places drawn by AppKit (menus, pop-up buttons) where a SwiftUI
/// greyscale modifier has no effect.
@MainActor
enum GlyphImage {
    private static var cache: [String: NSImage] = [:]

    static func monochrome(_ glyph: String, pointSize: CGFloat) -> NSImage {
        let key = "\(glyph)@\(pointSize)"
        if let cached = cache[key] { return cached }
        let text = NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: pointSize)])
        let size = text.size()
        let colour = NSImage(size: size, flipped: false) { rect in
            text.draw(in: rect)
            return true
        }
        var result = colour
        if let tiff = colour.tiffRepresentation, let input = CIImage(data: tiff), let filter = CIFilter(name: "CIPhotoEffectMono") {
            filter.setValue(input, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                let image = NSImage(size: size)
                image.addRepresentation(NSCIImageRep(ciImage: output))
                result = image
            }
        }
        cache[key] = result
        return result
    }
}

// StatusMenuBuilder

/// Right-click menu, rebuilt on every open so it always reflects current state. All settings live here (no settings window).
/// The API server is always on (localhost, no token) and therefore has no menu entry.
@MainActor
struct StatusMenuBuilder {
    let container: AppContainer
    let panel: QuickPanelController

    func build() -> NSMenu {
        let menu = NSMenu()
        let actions = MenuActions(container: container, panel: panel)
        menu.autoenablesItems = false

        if case .generating = container.engineState {
            menu.addItem(item(String(localized: "Stop"), "stop.circle", #selector(MenuActions.stopGeneration), actions, key: "."))
            menu.addItem(.separator())
        }
        menu.addItem(item(String(localized: "Ask a Question"), "sparkle.magnifyingglass", #selector(MenuActions.openPanel), actions))
        menu.addItem(
            item(
                String(localized: "Open Chat List"), "bubble.left.and.bubble.right", #selector(MenuActions.openChats), actions, key: "C",
                mask: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(submenu(String(localized: "Model"), "cpu", modelSubmenu(actions)))
        menu.addItem(submenu(String(localized: "Features"), "wand.and.stars", featuresSubmenu(actions)))
        menu.addItem(.separator())
        menu.addItem(submenu(String(localized: "Unload After"), "timer", idleSubmenu(actions)))
        menu.addItem(
            toggle(
                String(localized: "Auto-Close Panel"), "rectangle.badge.xmark", container.settings.panelClosesOnFocusLoss,
                #selector(MenuActions.togglePanelFocus), actions, help: String(localized: "Close the panel when you click outside it")))
        menu.addItem(
            toggle(
                String(localized: "Autostart"), "power", container.settings.launchAtLogin, #selector(MenuActions.toggleLaunchAtLogin),
                actions))
        menu.addItem(
            item(String(localized: "Keyboard Shortcut…"), "keyboard", #selector(MenuActions.openKeyboardSettings), actions))
        menu.addItem(
            item(String(localized: "Check for Updates"), "arrow.triangle.2.circlepath", #selector(MenuActions.checkUpdates), actions))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit"), "xmark.circle", #selector(MenuActions.quit), actions, key: "q"))
        menu.items.forEach { $0.representedObject = actions }  // keep `actions` alive while the menu is open
        return menu
    }

    // Submenus

    private func modelSubmenu(_ actions: MenuActions) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        if container.models.isEmpty { sub.addItem(disabled(String(localized: "No models installed"), "tray")) }
        for (index, group) in container.modelsBySource.enumerated() {
            if index > 0 { sub.addItem(.separator()) }
            sub.addItem(header(group.source.displayName))
            for model in group.models {
                let fit = container.fit(for: model)
                let size = ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)
                let stars = String(repeating: "★", count: fit.stars)
                let pending = container.updates.pendingModelUpdates[model.repoID] != nil ? " ↑" : ""
                let mi = NSMenuItem(
                    title: "\(model.name)  —  \(size)  \(stars)\(pending)", action: #selector(MenuActions.selectModel(_:)),
                    keyEquivalent: "")
                mi.target = actions
                mi.representedObject = model.id
                // The pictogram is the hub the model came from; the checkmark marks the model in use.
                Self.setGlyph(model.source.glyph, on: mi)
                mi.toolTip = model.kind == .vlm ? String(localized: "Understands images and text") : String(localized: "Text only")
                mi.state = model.id == container.activeModel?.id ? .on : .off
                if !container.isAvailable(model) {
                    mi.isEnabled = false
                    mi.toolTip = String(localized: "The server does not answer")
                }
                if fit.fit == .no, mi.isEnabled {  // an explicit colour would override the disabled grey
                    mi.attributedTitle = NSAttributedString(string: mi.title, attributes: [.foregroundColor: NSColor.systemRed])
                }
                sub.addItem(mi)
            }
        }
        sub.addItem(.separator())
        sub.addItem(item(String(localized: "Model Library…"), "square.stack.3d.up", #selector(MenuActions.openDownload), actions))
        return sub
    }

    private func idleSubmenu(_ actions: MenuActions) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for (title, secs) in [
            (String(localized: "1 minute"), 60.0), (String(localized: "5 minutes"), 300.0), (String(localized: "15 minutes"), 900.0),
            (String(localized: "1 hour"), 3600.0), (String(localized: "Never"), 0.0),  // Never = loaded at launch and kept resident
        ] {
            let mi = itemWith(title, secs == 0 ? "infinity" : "clock", #selector(MenuActions.setIdle(_:)), actions, object: secs)
            mi.state = container.settings.idleUnloadSeconds == secs ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        let unload = item(String(localized: "Unload Now"), "eject", #selector(MenuActions.unloadNow), actions)
        unload.isEnabled = container.engineState.modelID != nil
        sub.addItem(unload)
        return sub
    }

    /// What the model may do besides chatting. A checkmark on the item itself means the feature is on; all are off by default.
    private func featuresSubmenu(_ actions: MenuActions) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let search = submenu(String(localized: "Web Search"), "globe", searchSubmenu(actions))
        search.state = container.settings.toolsEnabled ? .on : .off
        sub.addItem(search)
        let folders = submenu(String(localized: "Folder Access"), "folder", foldersSubmenu(actions))
        folders.state = container.settings.fileToolsEnabled && !container.settings.allowedFolders.isEmpty ? .on : .off
        sub.addItem(folders)
        sub.addItem(
            toggle(
                String(localized: "Shortcuts"), "square.2.layers.3d", container.settings.shortcutsToolEnabled,
                #selector(MenuActions.toggleShortcutsTool), actions,
                help: String(localized: "The model may run your shortcuts; it asks before each run")))
        return sub
    }

    // Picking a provider turns search on; "Off" turns it off.
    private func searchSubmenu(_ actions: MenuActions) -> NSMenu {
        let sub = NSMenu()
        let off = itemWith(String(localized: "Off"), "nosign", #selector(MenuActions.setSearchProvider(_:)), actions, object: "")
        off.state = container.settings.toolsEnabled ? .off : .on
        sub.addItem(off)
        sub.addItem(.separator())
        for (title, key) in [("DuckDuckGo", "duckduckgo"), ("Google", "google")] {
            let mi = itemWith(title, "magnifyingglass", #selector(MenuActions.setSearchProvider(_:)), actions, object: key)
            // Anything else stored by an older build behaves as DuckDuckGo.
            let selected = (container.settings.searchProvider == "google") == (key == "google")
            mi.state = container.settings.toolsEnabled && selected ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(
            toggle(
                String(localized: "Detailed Analysis"), "text.magnifyingglass", container.settings.deepWebSearch,
                #selector(MenuActions.toggleDeepWebSearch), actions,
                help: String(
                    localized: "The model runs several searches, reads the best pages in full and compares sources; answers take longer")))
        return sub
    }

    // Adding the first folder turns file access on; "Off" keeps the list but hides the files from the model.
    private func foldersSubmenu(_ actions: MenuActions) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let folders = container.settings.allowedFolders
        let enabled = container.settings.fileToolsEnabled && !folders.isEmpty
        let off = itemWith(String(localized: "Off"), "nosign", #selector(MenuActions.setFileAccess(_:)), actions, object: false)
        off.state = enabled ? .off : .on
        sub.addItem(off)
        let on = itemWith(
            String(localized: "Read Files in These Folders"), "doc.text.magnifyingglass", #selector(MenuActions.setFileAccess(_:)), actions,
            object: true)
        on.state = enabled ? .on : .off
        on.isEnabled = !folders.isEmpty
        sub.addItem(on)
        sub.addItem(.separator())
        if folders.isEmpty { sub.addItem(disabled(String(localized: "No folders yet"), "folder.badge.questionmark")) }
        for path in folders {
            let mi = itemWith(
                (path as NSString).abbreviatingWithTildeInPath, "folder", #selector(MenuActions.removeAllowedFolder(_:)), actions,
                object: path)
            mi.toolTip = String(localized: "Click to remove")
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(item(String(localized: "Add Folder…"), "plus", #selector(MenuActions.addAllowedFolder), actions))
        return sub
    }

    // Item helpers: every item carries a pictogram.

    private func item(
        _ title: String, _ symbol: String, _ action: Selector, _ target: AnyObject, key: String = "",
        mask: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = key.isEmpty ? [] : mask
        mi.target = target
        Self.setSymbol(symbol, on: mi)
        return mi
    }

    private func itemWith(_ title: String, _ symbol: String, _ action: Selector, _ target: AnyObject, object: Any) -> NSMenuItem {
        let mi = item(title, symbol, action, target)
        mi.representedObject = object
        return mi
    }

    private func toggle(
        _ title: String, _ symbol: String, _ on: Bool, _ action: Selector, _ target: AnyObject, help: String? = nil
    ) -> NSMenuItem {
        let mi = item(title, symbol, action, target)
        mi.state = on ? .on : .off
        mi.toolTip = help
        return mi
    }

    private func submenu(_ title: String, _ symbol: String, _ menu: NSMenu) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = menu
        Self.setSymbol(symbol, on: mi)
        return mi
    }

    /// SF Symbol shown before a menu item; template, so it follows the menu appearance. Unknown names fall back to a dot.
    private static func setSymbol(_ name: String, on item: NSMenuItem) {
        let base =
            NSImage(systemSymbolName: name, accessibilityDescription: item.title)
            ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: item.title)
        // An explicit configuration gives every pictogram the same optical size next to the menu font.
        let image = base?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        item.image = image
        // macOS 27 hides menu item images unless the item asks for them.
        if #available(macOS 27.0, *) {
            item.preferredImageVisibility = .visible
        }
    }

    /// Emoji mark (hub glyph) drawn into an image so it sits in the pictogram column like the symbols do.
    private static func setGlyph(_ glyph: String, on item: NSMenuItem) {
        item.image = GlyphImage.monochrome(glyph, pointSize: 13)
        if #available(macOS 27.0, *) {
            item.preferredImageVisibility = .visible
        }
    }

    /// Registry header: disabled, small caps-like secondary text.
    private func header(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        mi.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        return mi
    }

    private func disabled(_ title: String, _ symbol: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        Self.setSymbol(symbol, on: mi)
        return mi
    }
}

// MenuActions

/// NSMenuItem targets (selectors require NSObject).
@MainActor
final class MenuActions: NSObject {
    private let container: AppContainer
    private let panel: QuickPanelController

    init(container: AppContainer, panel: QuickPanelController) {
        self.container = container
        self.panel = panel
    }

    @objc func stopGeneration() { Task { await container.engineManager.cancelCurrent() } }
    @objc func openChats() { WindowManager.shared.open(.chats) }
    @objc func openPanel() { panel.show() }
    @objc func openDownload() { WindowManager.shared.openModels() }
    /// The panel hot key is an NSServices shortcut, assigned in System Settings → Keyboard → App Shortcuts.
    @objc func openKeyboardSettings() {
        // VERIFY(macOS26): deep link into the Shortcuts pane of Keyboard settings.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func toggleLaunchAtLogin() {
        container.settings.launchAtLogin.toggle()
        LaunchAtLogin.sync(enabled: container.settings.launchAtLogin)
    }
    @objc func selectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let model = container.models.first(where: { $0.id == id }) else { return }
        container.chooseModel(model)
    }
    @objc func unloadNow() { container.unloadNow() }
    @objc func setIdle(_ sender: NSMenuItem) { if let s = sender.representedObject as? Double { container.setIdleTimeout(s) } }
    /// An empty provider means "Off"; any provider switches web search on.
    @objc func setSearchProvider(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        if provider.isEmpty {
            container.setToolsEnabled(false)
        } else {
            container.setSearchProvider(provider)
            container.setToolsEnabled(true)
        }
    }
    @objc func setFileAccess(_ sender: NSMenuItem) {
        if let enabled = sender.representedObject as? Bool { container.setFileToolsEnabled(enabled) }
    }
    @objc func toggleDeepWebSearch() { container.setDeepWebSearch(!container.settings.deepWebSearch) }
    @objc func toggleShortcutsTool() { container.setShortcutsToolEnabled(!container.settings.shortcutsToolEnabled) }
    @objc func removeAllowedFolder(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { container.removeAllowedFolder(path) }
    }
    @objc func addAllowedFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.begin { [container] response in
            guard response == .OK else { return }
            for url in panel.urls { container.addAllowedFolder(url) }
            container.setFileToolsEnabled(true)
        }
    }
    @objc func togglePanelFocus() { container.settings.panelClosesOnFocusLoss.toggle() }
    @objc func checkUpdates() { container.updates.checkAll(force: true) }
    @objc func quit() { NSApp.terminate(nil) }
}
