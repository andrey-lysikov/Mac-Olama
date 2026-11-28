//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// QuickPanelController

@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    private let container: AppContainer
    private let viewModel: QuickPanelViewModel
    private var panel: QuickPanel!
    private var focusObserver: Any?
    private var screenObserver: Any?
    private var overlayObservers: [Any] = []
    private var fontShortcutMonitor: Any?

    // Plain constants: `PanelPlacement` and the tests read them outside the main actor.
    nonisolated static let defaultWidth: CGFloat = 680
    nonisolated static let minWidth: CGFloat = 420
    nonisolated static let minHeight: CGFloat = 48  // below the one-line field
    private var contentHeight: CGFloat = minHeight
    private var isApplyingFrame = false
    private var fitScheduled = false
    private var dragWatch: Task<Void, Never>?
    private var opening: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
        self.viewModel = QuickPanelViewModel(container: container)
        super.init()
        makePanel()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersDidChange() }
        }
        observeOverlays()
        observeFontShortcuts()
    }

    // ⌘+ / ⌘− scale the transcript text in both the panel and the chats window.
    private func observeFontShortcuts() {
        fontShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, let characters = event.charactersIgnoringModifiers?.lowercased() else { return event }
            let step: Double? = switch characters {
            case "+", "=": 1  // "+" needs Shift on most layouts; "=" is its unshifted key
            case "-", "_": -1
            default: nil
            }
            guard let step else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                // Only when a chat surface is in front; elsewhere the keys keep their usual meaning.
                let panelVisible = self.panel.isVisible
                let chatsKey = NSApp.keyWindow?.identifier?.rawValue == WindowManager.ID.chats.rawValue
                guard panelVisible || chatsKey else { return false }
                let size = self.container.settings.chatFontSize + step
                guard size != self.container.settings.chatFontSize else { return true }  // at the limit: swallow the key
                self.container.settings.chatFontSize = size
                return true
            }
            return handled ? nil : event
        }
    }

    // Lift tooltips and popovers above the panel's level as they appear.
    private func observeOverlays() {
        // There is no "window became visible" notification; didUpdate fires on every window
        // flush, which reliably catches a tooltip the moment it shows. `lift` is cheap and idempotent.
        for name in [NSWindow.didUpdateNotification, NSWindow.didChangeOcclusionStateNotification] {
            overlayObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                    let window = note.object as? NSWindow
                    MainActor.assumeIsolated { Self.lift(window) }
                })
        }
    }

    private static func lift(_ window: NSWindow?) {
        guard let window, window.isVisible else { return }
        let kind = String(describing: type(of: window))
        guard kind.contains("ToolTip") || kind.contains("Popover") else { return }
        let above = NSWindow.Level.screenSaver.rawValue + 1
        if window.level.rawValue < above { window.level = NSWindow.Level(rawValue: above) }
    }

    private func makePanel() {
        panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.minHeight),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false
        )
        panel.delegate = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false  // let text selection win; the background has its own drag gesture
        // Screen-saver level: above floating palettes and full-screen windows.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // No show/hide animation: it flickered with glass.
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: Self.minWidth, height: Self.minHeight)
        panel.onEscape = { [weak self] in self?.hide() }
        panel.onPasteAttachment = { [weak self] in self?.viewModel.pasteFromClipboard() ?? false }
        panel.onNewChat = { [weak self] in self?.viewModel.clear() }

        let root = QuickPanelView(
            viewModel: viewModel, onClose: { [weak self] in self?.hide() },
            onHeightChange: { [weak self] height in self?.scheduleFit(contentHeight: height) },
            onMakeKey: { [weak self] in self?.panel.makeKey() },
            onChooseFiles: { [weak self] in self?.chooseFiles() }
        )
        .environment(container)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []  // sized by `fit(contentHeight:)`
        // Drop the hidden title bar's safe area, which SwiftUI could not ignore.
        hosting.safeAreaRegions = []
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible || opening != nil ? hide() : show()
    }

    weak var statusItemWindow: NSWindow?

    private func isStatusItemClick(_ event: NSEvent?) -> Bool {
        guard let event, let window = statusItemWindow else { return false }
        return [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp].contains(event.type) && event.window === window
    }

    func show(prefill: String? = nil) {
        if let prefill { viewModel.input = prefill }
        // Already on screen: stay where it is, just take the keyboard again (no hide-and-show).
        if panel.isVisible {
            panel.orderFrontRegardless()
            panel.makeKey()
            viewModel.panelDidAppear()
            Task { await viewModel.loadActiveChat() }
            return
        }
        guard opening == nil else { return }
        // Load the chat first so the panel opens at the right height.
        opening = Task { [weak self] in
            await self?.viewModel.loadActiveChat()
            guard let self, !Task.isCancelled else { return }
            opening = nil
            position()
            // Size the panel before showing it to avoid a resize flash.
            panel.contentView?.layoutSubtreeIfNeeded()
            fit(contentHeight: contentHeight)
            // Order front regardless; the non-activating panel takes the keyboard.
            panel.orderFrontRegardless()
            panel.makeKey()
            // A status menu item dismisses its menu only after its action returns; repeat once it has.
            Task { @MainActor [panel] in panel?.orderFrontRegardless() }
            viewModel.panelDidAppear()
            installFocusObserver()
        }
    }

    func hide() {
        opening?.cancel()
        opening = nil
        panel.orderOut(nil)
        removeFocusObserver()
    }

    private func chooseFiles() {
        removeFocusObserver()
        let dialog = NSOpenPanel()
        dialog.allowedContentTypes = AttachableTypes.documents + (viewModel.canAttachImages ? [.image] : [])
        dialog.allowsMultipleSelection = true
        dialog.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        NSApp.activate()
        dialog.begin { [weak self] response in
            guard let self else { return }
            if response == .OK { dialog.urls.forEach { self.viewModel.attach(fileURL: $0) } }
            guard panel.isVisible else { return }
            panel.makeKey()
            installFocusObserver()
            // Hand the keyboard back to the composer so typing continues right away.
            self.viewModel.panelDidAppear()
        }
        dialog.orderFrontRegardless()
        dialog.makeKey()  // VERIFY(mac): dialog gets the keyboard while accessory
    }

    // Geometry: draggable and resizable; width and height limit are remembered.

    private func scheduleFit(contentHeight: CGFloat) {
        self.contentHeight = contentHeight
        guard !fitScheduled else { return }  // coalesce reports into one resize
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            fitScheduled = false
            fit(contentHeight: self.contentHeight)
        }
    }

    private func fit(contentHeight: CGFloat) {
        self.contentHeight = contentHeight
        guard !panel.inLiveResize else { return }
        var frame = panel.frame
        let screenTop = (panel.screen ?? NSScreen.main)?.visibleFrame.maxY ?? .greatestFiniteMagnitude
        viewModel.heightLimit = max(min(viewModel.maxPanelHeight, screenTop - frame.minY), Self.minHeight)
        let height = max(min(contentHeight.rounded(.up), viewModel.heightLimit), Self.minHeight)
        guard abs(frame.height - height) >= 1 else { return }
        frame.size.height = height
        isApplyingFrame = true
        panel.setFrame(frame, display: true)
        isApplyingFrame = false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        viewModel.maxPanelHeight = max(panel.frame.height, 160)
        saveGeometry()
        fit(contentHeight: contentHeight)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame, panel.isVisible else { return }
        saveGeometry()
        // Refit after the drag ends.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return fit(contentHeight: contentHeight) }
        guard dragWatch == nil else { return }
        dragWatch = Task { [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(100)) }
            guard let self else { return }
            dragWatch = nil
            fit(contentHeight: contentHeight)
        }
    }

    private func saveGeometry() {
        let frame = panel.frame
        container.settings.panelGeometry = [frame.minX, frame.minY, frame.width, viewModel.maxPanelHeight, 1].map(Double.init)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        // No screens: skip showing.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let placed = PanelPlacement.resolve(
            saved: container.settings.panelGeometry, panelHeight: panel.frame.height,
            visible: screen.visibleFrame, screens: NSScreen.screens.map(\.visibleFrame))
        viewModel.maxPanelHeight = placed.maxHeight
        isApplyingFrame = true
        panel.setFrame(placed.frame, display: false)
        isApplyingFrame = false
        fit(contentHeight: contentHeight)
    }

    private func screenParametersDidChange() {
        guard panel.isVisible, !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }) else { return }
        position()
        fit(contentHeight: contentHeight)
        saveGeometry()
    }

    private func installFocusObserver() {
        removeFocusObserver()
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                // A click on our status item decides, not the auto-close.
                guard let self, !self.isStatusItemClick(NSApp.currentEvent) else { return }
                self.hide()
            }
        }
    }

    private func removeFocusObserver() {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
    }
}

enum PanelPlacement {
    static func resolve(
        saved: [Double], panelHeight: CGFloat, visible: NSRect, screens: [NSRect]
    ) -> (frame: NSRect, maxHeight: CGFloat) {
        let hasSaved = saved.count == 4 || saved.count == 5
        let width =
            hasSaved ? min(max(CGFloat(saved[2]), QuickPanelController.minWidth), visible.width) : QuickPanelController.defaultWidth
        let maxHeight = hasSaved ? min(max(CGFloat(saved[3]), 160), visible.height) : visible.height / 2
        // Default: centred, field a quarter of the screen above the bottom.
        var frame = NSRect(x: visible.midX - width / 2, y: visible.minY + visible.height / 4, width: width, height: panelHeight)
        if hasSaved {
            let bottom = saved.count == 5 ? CGFloat(saved[1]) : CGFloat(saved[1]) - panelHeight
            let remembered = NSRect(x: CGFloat(saved[0]), y: bottom, width: width, height: panelHeight)
            // Off-screen: use the default place.
            if screens.contains(where: { $0.contains(remembered) }) { frame = remembered }
        }
        return (frame, maxHeight)
    }
}

@MainActor
final class QuickPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onPasteAttachment: (() -> Bool)?
    var onNewChat: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc(_hasActiveAppearance) dynamic func hasActiveAppearance() -> Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting(.shift) == .command else { return false }
        let action: Selector? =
            switch event.keyCode {
            case 0: #selector(NSText.selectAll(_:))  // A
            case 8: #selector(NSText.copy(_:))  // C
            case 9: #selector(NSText.paste(_:))  // V
            case 7: #selector(NSText.cut(_:))  // X
            case 6: flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))  // Z
            default: nil
            }
        if event.keyCode == 45, flags == .command {  // N: a new chat, as in the chats window
            onNewChat?()
            return true
        }
        guard let action else { return false }
        if event.keyCode == 9, onPasteAttachment?() == true { return true }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }  // Esc
        super.keyDown(with: event)
    }
}

// QuickPanelViewModel

@MainActor
@Observable
final class QuickPanelViewModel: ConversationStreamDelegate, ConversationStreamHosting {
    typealias PendingImage = ConversationStreamCoordinator.PendingImage

    private let container: AppContainer
    let stream: ConversationStreamCoordinator

    var maxPanelHeight: CGFloat = 480
    var heightLimit: CGFloat = 480
    private(set) var chat: Chat? {
        didSet {
            container.panelChatID = chat?.id
            stream.display(chatID: chat?.id)
        }
    }
    private(set) var transcriptToken = 0
    private var storeTask: Task<Void, Never>?

    // Show steps of a reply the chats window writes into the panel's chat.
    var progress: GenerationProgress? { stream.progress ?? chat.flatMap { container.liveProgress[$0.id] } }

    var activeModel: ModelDescriptor? { container.activeModel }
    var canAttachImages: Bool { activeModel?.kind == .vlm }
    var quotaBlocked: Bool { activeModel.map { container.isQuotaExhausted($0) } ?? false }
    private(set) var compacting = false
    private(set) var isLoadingChat = false
    var contextLimit: Int? { activeModel.flatMap { container.contextTokens(for: $0) } }
    var contextUsed: Int { stream.contextUsed(chat: chat, model: activeModel) }
    var engineState: EngineState { container.engineState }

    init(container: AppContainer) {
        self.container = container
        self.stream = ConversationStreamCoordinator(container: container)
        stream.delegate = self
        observeStore()
    }

    isolated deinit {
        storeTask?.cancel()
    }

    // ConversationStreamDelegate

    func chatIDForSending(question: QueuedQuestion) async -> UUID? {
        if chat == nil { await loadActiveChat() }
        return chat?.id
    }

    func modelIDForSending() -> String? { container.activeModel?.id }

    func displaysChat(_ chatID: UUID) -> Bool { chat?.id == chatID }

    var acceptsImages: Bool { canAttachImages }

    private(set) var focusToken = 0

    func panelDidAppear() {
        focusToken += 1
    }

    // Chat

    func loadActiveChat() async {
        isLoadingChat = true
        defer { isLoadingChat = false }
        do {
            let chat = try await container.conversation.activeChat(origin: .panel)
            self.chat = chat
            container.setActiveChat(chat.id)
            stream.setMessages(try await container.chatStore.messages(chatID: chat.id))
            await stream.refreshContext(chatID: chat.id)
            transcriptToken += 1
        } catch {
            stream.errorMessage = ConversationService.describe(error)
        }
    }

    func clear() {
        stream.reset()
        Task {
            let chat = try? await container.conversation.newChat(origin: .panel)
            self.chat = chat
            container.setActiveChat(chat?.id)
        }
    }

    func compact() {
        guard let chat, !isGenerating, !compacting else { return }
        compacting = true
        Task {
            defer { compacting = false }
            do {
                try await container.conversation.compact(chatID: chat.id)
                await loadActiveChat()
            } catch {
                stream.errorMessage = ConversationService.describe(error)
            }
        }
    }

    func retryFailed() {
        guard let chat else { return }
        // A failure before the run started already returned the question to the composer.
        if stream.messages.last?.role == .assistant {
            stream.regenerate(chatID: chat.id)
        } else if !stream.input.isEmpty {
            send()
        }
    }

    func send() {
        guard !quotaBlocked, !compacting else { return }
        guard container.activeModel != nil else {
            stream.errorMessage = String(localized: "No model selected. Download one from the menu.")
            return
        }
        stream.send(chatID: chat?.id)
        transcriptToken += 1
    }

    // Store sync (the reply may have finished while the panel was closed)

    private func observeStore() {
        storeTask = stream.observeStoreChanges(
            onChats: { [weak self] in
                // Chat-level edits (e.g. the compaction mark) refresh the chat without touching a live stream.
                guard let self, let current = self.chat, !self.isGenerating else { return }
                self.chat = try? await self.container.chatStore.chat(id: current.id)
            },
            onMessages: { [weak self] chatID in
                guard let self, let chat = self.chat, chatID == chat.id, !self.isGenerating else { return }
                self.stream.setMessages((try? await self.container.chatStore.messages(chatID: chat.id)) ?? self.messages)
            },
            onChatDeleted: { [weak self] chatID in
                guard let self, chatID == self.chat?.id else { return }
                self.chat = nil
                self.stream.setMessages([])
            })
    }
}
