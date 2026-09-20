//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

// StatusItemController

/// Menu bar icon: left click opens the panel, right click the menu. Follows `AppContainer.engineState` through the tooltip
/// and shimmers (fades to half and back) while an answer is waiting that neither the panel nor the chats window showed.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let container: AppContainer
    private let panel: QuickPanelController
    private let item: NSStatusItem
    private var observationTask: Task<Void, Never>?
    private var blinkTimer: Timer?
    private var blinkStart = ContinuousClock.now
    private var seenAnswers = 0
    /// The same mark the answers carry in the transcript, so the status item reads as "the model" at a glance.
    /// A template image: the menu bar tints it for light and dark bars and for the highlight.
    private static let icon: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: String(localized: "Mac-Olama"))?
            .withSymbolConfiguration(configuration)
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
            panel.statusItemWindow = button.window
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
        panel.statusItemWindow = item.button?.window  // in case the button had no window yet at launch
        guard WindowManager.shared.isOpen(.chats) else {
            panel.show()  // an open panel stays open and takes the keyboard; Esc or a click elsewhere closes it
            return
        }
        panel.hide()
        WindowManager.shared.open(.chats)
    }

    private func showMenu() {
        let menu = StatusMenuBuilder(container: container).build()
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
        blinkStart = .now
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.blink() }
        }
    }

    private var answerIsVisible: Bool { panel.isVisible || WindowManager.shared.isOnScreen(.chats) }

    /// Opening the panel or the chats window some other way (shortcut, Dock) also counts as seeing the answer.
    /// A soft shimmer, not a blink: the icon fades smoothly down to half and back, once every 1.6 s.
    private func blink() {
        guard let button = item.button, !answerIsVisible else { return stopBlinking() }
        let phase = blinkStart.duration(to: .now) / .milliseconds(1600)
        button.alphaValue = 0.75 + 0.25 * cos(2 * .pi * phase)
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

// StatusMenuBuilder

/// Right-click menu, rebuilt on every open so it always reflects current state. All settings live here (no settings window).
/// The API server is always on (localhost, no token) and therefore has no menu entry.
@MainActor
struct StatusMenuBuilder {
    let container: AppContainer

    func build() -> NSMenu {
        let menu = NSMenu()
        let actions = MenuActions(container: container)
        menu.autoenablesItems = false

        menu.addItem(
            item(
                String(localized: "Open Chat List"), "bubble.left.and.bubble.right", #selector(MenuActions.openChats), actions, key: "C",
                mask: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(submenu(String(localized: "Model"), "cpu", modelSubmenu(actions)))
        menu.addItem(item(String(localized: "Model Library…"), "square.stack.3d.up", #selector(MenuActions.openDownload), actions))
        menu.addItem(.separator())
        menu.addItem(
            toggle(
                String(localized: "Autostart"), "power", container.settings.launchAtLogin, #selector(MenuActions.toggleLaunchAtLogin),
                actions))
        menu.addItem(
            item(String(localized: "Check for Updates"), "arrow.triangle.2.circlepath", #selector(MenuActions.checkUpdates), actions))
        // Everything with a value to pick or a list to edit lives in the window's settings section, not here.
        menu.addItem(item(String(localized: "Settings"), "gearshape", #selector(MenuActions.openSettings), actions))
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
                // An unknown size (a model served over the API) is left out, and so is the fit estimate built on it.
                var title = model.name
                if model.sizeBytes > 0 {
                    let size = ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)
                    title += "  —  \(size)  " + String(repeating: "★", count: fit.stars)
                }
                if container.updates.pendingModelUpdates[model.repoID] != nil { title += " ↑" }
                let mi = NSMenuItem(title: title, action: #selector(MenuActions.selectModel(_:)), keyEquivalent: "")
                mi.target = actions
                mi.representedObject = model.id
                // The model's icon (author, with the community that built it in the corner); the checkmark marks the model in use.
                Self.setModelIcon(model, on: mi)
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
        return sub
    }

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

    private func toggle(
        _ title: String, _ symbol: String, _ on: Bool, _ action: Selector, _ target: AnyObject, help: String? = nil,
        object: Any? = nil
    ) -> NSMenuItem {
        let mi = item(title, symbol, action, target)
        mi.state = on ? .on : .off
        mi.toolTip = help
        if let object { mi.representedObject = object }
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

    private static func setModelIcon(_ model: ModelDescriptor, on item: NSMenuItem) {
        item.image = ModelIcons.shared.menuImage(for: model, size: 16)
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

    init(container: AppContainer) {
        self.container = container
    }

    @objc func openChats() { WindowManager.shared.open(.chats) }
    @objc func openDownload() { WindowManager.shared.openModels() }
    @objc func toggleLaunchAtLogin() {
        container.settings.launchAtLogin.toggle()
        LaunchAtLogin.sync(enabled: container.settings.launchAtLogin)
    }
    @objc func selectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let model = container.models.first(where: { $0.id == id }) else { return }
        container.chooseModel(model)
    }
    @objc func openSettings() { WindowManager.shared.openSettings() }
    @objc func checkUpdates() { container.updates.checkAll(force: true) }
    @objc func quit() { NSApp.terminate(nil) }
}
