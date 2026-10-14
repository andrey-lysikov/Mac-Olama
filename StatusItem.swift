//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// StatusItemController

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let container: AppContainer
    private let panel: QuickPanelController
    private let item: NSStatusItem
    private var observationTask: Task<Void, Never>?
    private var blinkTimer: Timer?
    private var blinkStart = ContinuousClock.now
    private var seenAnswers = 0
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

    // Lives as long as the app; the task holds `self` weakly.

    // Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        stopBlinking()
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) { showMenu() } else { activate() }
    }

    private func activate() {
        panel.statusItemWindow = item.button?.window  // in case the button had no window yet at launch
        guard WindowManager.shared.isOpen(.chats) else {
            panel.show()  // stays open until Esc or a click elsewhere
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
        // No check mark in the menu: the item says whether autostart is on, a click switches it.
        menu.addItem(
            item(
                container.settings.launchAtLogin ? String(localized: "Autostart is on") : String(localized: "Autostart is off"), "power",
                #selector(MenuActions.toggleLaunchAtLogin), actions))
        menu.addItem(
            item(String(localized: "Check for Updates"), "arrow.triangle.2.circlepath", #selector(MenuActions.checkUpdates), actions))
        // Values and lists live in the settings section.
        menu.addItem(item(String(localized: "Settings"), "gearshape", #selector(MenuActions.openSettings), actions))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "About"), "info.circle", #selector(MenuActions.openAbout), actions))
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
                // Size and fit omitted when unknown (API models).
                var title = model.name
                if model.sizeBytes > 0 {
                    title += "  —  \(model.sizeBytes.fileSizeText)  " + String(repeating: "★", count: fit.stars)
                }
                if container.updates.pendingModelUpdates[model.repoID] != nil { title += " ↑" }
                let mi = NSMenuItem(title: title, action: #selector(MenuActions.selectModel(_:)), keyEquivalent: "")
                mi.target = actions
                mi.representedObject = model.id
                // Model icon; the checkmark marks the active model.
                Self.setModelIcon(model, on: mi)
                mi.toolTip = model.kind == .vlm ? String(localized: "Understands images and text") : String(localized: "Text only")
                mi.state = model.id == container.activeModel?.id ? .on : .off
                if !container.isAvailable(model) {
                    mi.isEnabled = false
                    mi.toolTip = String(localized: "The server does not answer")
                }
                if fit.fit == .no, mi.isEnabled {  // explicit colour would override disabled grey
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

    private func submenu(_ title: String, _ symbol: String, _ menu: NSMenu) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = menu
        Self.setSymbol(symbol, on: mi)
        return mi
    }

    private static func setSymbol(_ name: String, on item: NSMenuItem) {
        let base =
            NSImage(systemSymbolName: name, accessibilityDescription: item.title)
            ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: item.title)
        // Same optical size for all menu pictograms.
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
    @objc func openAbout() { WindowManager.shared.openAbout() }
    @objc func checkUpdates() { container.updates.checkAll(force: true) }
    @objc func quit() { NSApp.terminate(nil) }
}
