//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// QuickPanelController

/// Spotlight-style floating panel. Non-activating: keeps the front app active but still accepts input.
@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    private let container: AppContainer
    private let viewModel: QuickPanelViewModel
    private var panel: QuickPanel!
    private var focusObserver: Any?
    private var screenObserver: Any?

    // Plain constants: `PanelPlacement` and the tests read them outside the main actor.
    nonisolated static let defaultWidth: CGFloat = 680
    nonisolated static let minWidth: CGFloat = 420
    nonisolated static let minHeight: CGFloat = 56
    /// Height of the last content report, so the panel can snap back to it after the user stops dragging an edge.
    private var contentHeight: CGFloat = minHeight
    private var isApplyingFrame = false

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
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: Self.minWidth, height: Self.minHeight)
        panel.onEscape = { [weak self] in self?.hide() }
        panel.onPasteAttachment = { [weak self] in self?.viewModel.pasteFromClipboard() ?? false }

        let root = QuickPanelView(
            viewModel: viewModel, onClose: { [weak self] in self?.hide() },
            onHeightChange: { [weak self] height in self?.fit(contentHeight: height) }
        )
        .environment(container)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []  // the window is sized by `fit(contentHeight:)`, not by Auto Layout
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show(prefill: String? = nil) {
        if let prefill { viewModel.input = prefill }
        position()
        panel.makeKeyAndOrderFront(nil)
        viewModel.panelDidAppear()
        installFocusObserver()
    }

    /// The Safari extension button: open the panel with the current page attached as a document.
    func show(attachingPage url: URL) {
        show()
        viewModel.attach(webURL: url)
    }

    func hide() {
        panel.orderOut(nil)
        removeFocusObserver()
    }

    // Geometry: the user drags the panel anywhere and drags its edges; width and the height limit for answers are remembered.

    /// Follows the SwiftUI content: the top edge stays where it is and the panel grows or shrinks downwards,
    /// up to the height limit (the user's own, otherwise half of the screen).
    private func fit(contentHeight: CGFloat) {
        self.contentHeight = contentHeight
        guard !panel.inLiveResize else { return }
        let height = min(max(contentHeight.rounded(.up), Self.minHeight), viewModel.maxPanelHeight)
        var frame = panel.frame
        guard abs(frame.height - height) >= 1 else { return }
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        isApplyingFrame = true
        panel.setFrame(frame, display: true)
        isApplyingFrame = false
    }

    /// Dragging an edge: the width is kept as is, the height the user chose becomes the limit for answers.
    func windowDidEndLiveResize(_ notification: Notification) {
        viewModel.maxPanelHeight = max(panel.frame.height, 160)
        saveGeometry()
        fit(contentHeight: contentHeight)
    }

    func windowDidMove(_ notification: Notification) {
        if !isApplyingFrame, panel.isVisible { saveGeometry() }
    }

    private func saveGeometry() {
        let frame = panel.frame
        container.settings.panelGeometry = [frame.minX, frame.maxY, frame.width, viewModel.maxPanelHeight].map(Double.init)
    }

    /// Remembered place and size if they still fit a screen; otherwise centred on the screen under the cursor, like Spotlight.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let placed = PanelPlacement.resolve(
            saved: container.settings.panelGeometry, panelHeight: panel.frame.height,
            visible: screen.visibleFrame, screens: NSScreen.screens.map(\.visibleFrame))
        viewModel.maxPanelHeight = placed.maxHeight
        isApplyingFrame = true
        panel.setFrame(placed.frame, display: false)
        isApplyingFrame = false
    }

    /// A display was unplugged or its resolution changed while the panel is open: recentre if it ended up off-screen.
    /// `position()` falls back to the centre on its own because the remembered frame no longer fits any screen.
    private func screenParametersDidChange() {
        guard panel.isVisible, !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }) else { return }
        position()
        fit(contentHeight: contentHeight)
        saveGeometry()
    }

    private func installFocusObserver() {
        removeFocusObserver()
        guard container.settings.panelClosesOnFocusLoss else { return }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeFocusObserver() {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
    }
}

/// Pure geometry behind `position()`, separated so it can be unit-tested without NSScreen.
enum PanelPlacement {
    /// `saved` is `SettingsKey.panelGeometry`: left, top, width, height limit; anything else means "first run".
    static func resolve(
        saved: [Double], panelHeight: CGFloat, visible: NSRect, screens: [NSRect]
    ) -> (frame: NSRect, maxHeight: CGFloat) {
        let width =
            saved.count == 4
            ? min(max(CGFloat(saved[2]), QuickPanelController.minWidth), visible.width) : QuickPanelController.defaultWidth
        let maxHeight = saved.count == 4 ? min(max(CGFloat(saved[3]), 160), visible.height) : visible.height / 2
        var frame = NSRect(
            x: visible.midX - width / 2, y: visible.maxY - visible.height * 0.22 - panelHeight, width: width, height: panelHeight)
        if saved.count == 4 {
            let remembered = NSRect(x: CGFloat(saved[0]), y: CGFloat(saved[1]) - panelHeight, width: width, height: panelHeight)
            // Off-screen (a display was unplugged, the resolution changed): fall back to the centre.
            if screens.contains(where: { $0.contains(remembered) }) { frame = remembered }
        }
        return (frame, maxHeight)
    }
}

/// NSPanel that can become key (needed for typing in a non-activating panel) and handles Esc.
@MainActor
final class QuickPanel: NSPanel {
    var onEscape: (() -> Void)?
    /// Returns true when ⌘V was consumed by attaching a copied image or file instead of pasting text.
    var onPasteAttachment: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// The panel is non-activating, so the app's Edit menu may never see its key equivalents: route them to the field editor here.
    /// Key codes, not characters, so the shortcuts work in any keyboard layout.
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

/// Panel state: active chat, streaming reply, attachments. One instance per app.
@MainActor
@Observable
final class QuickPanelViewModel {
    struct PendingImage: Identifiable, Equatable {
        let id = UUID()
        let data: Data
        let mimeType: String
        let thumbnail: NSImage
    }

    private let container: AppContainer

    var input = ""
    /// Height limit of the whole panel: the user's choice, otherwise half of the screen. The transcript scrolls beyond it.
    var maxPanelHeight: CGFloat = 480
    var pendingImages: [PendingImage] = []
    var pendingDocuments: [DocumentInput] = []
    private(set) var chat: Chat?
    private(set) var messages: [Message] = []
    /// Reply text currently streaming, before it lands in `messages`.
    private(set) var streamingText = ""
    /// What the model went off to do (search, open a page): its own line, never mixed into the answer.
    private(set) var activity: AnswerText.Activity?
    private(set) var isGenerating = false
    private(set) var errorMessage: String?
    /// Bumped when the transcript should jump back to the newest exchange: the panel was opened, or the chat changed.
    private(set) var transcriptToken = 0
    private var streamTask: Task<Void, Never>?
    private var storeTask: Task<Void, Never>?

    var activeModel: ModelDescriptor? { container.activeModel }
    var canAttachImages: Bool { activeModel?.kind == .vlm }
    var engineState: EngineState { container.engineState }
    /// The streamed reply without the model's private channels; notes about tools are separate state.
    var visibleStreamingText: String { AnswerText.visible(streamingText) }

    init(container: AppContainer) {
        self.container = container
        observeStore()
    }

    func panelDidAppear() {
        Task { await loadActiveChat() }
    }

    // Chat

    func loadActiveChat() async {
        do {
            let chat = try await container.conversation.activeChat(origin: .panel)
            self.chat = chat
            container.setActiveChat(chat.id)
            messages = try await container.chatStore.messages(chatID: chat.id)
            transcriptToken += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Clear: start a new chat.
    func clear() {
        streamTask?.cancel()
        input = ""
        Task {
            let chat = try? await container.conversation.newChat(origin: .panel)
            self.chat = chat
            container.setActiveChat(chat?.id)
            messages = []
            streamingText = ""
            activity = nil
            errorMessage = nil
            pendingImages = []
            pendingDocuments = []
        }
    }

    func stop() {
        guard let chat else { return }
        Task { await container.conversation.cancel(chatID: chat.id) }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty || !pendingDocuments.isEmpty, !isGenerating else { return }
        guard container.activeModel != nil else {
            errorMessage = String(localized: "No model selected. Download one from the menu.")
            return
        }
        let images = pendingImages.map { ImageInput(data: $0.data, mimeType: $0.mimeType) }
        let documents = pendingDocuments
        input = ""
        pendingImages = []
        pendingDocuments = []
        errorMessage = nil
        streamingText = ""
        activity = nil
        isGenerating = true

        streamTask = Task {
            do {
                if chat == nil { await loadActiveChat() }
                guard let chat else { return }
                let stream = try await container.conversation.send(chatID: chat.id, text: text, images: images, documents: documents)
                for await event in stream {
                    switch event {
                    case .started:
                        messages = (try? await container.chatStore.messages(chatID: chat.id)) ?? messages
                    case .token(let t):
                        streamingText += t
                    case .toolCallStarted(let call):
                        // The call itself stays out of the transcript; the line says where the answer is going to come from.
                        activity = AnswerText.activity(for: call, searchProvider: container.settings.searchProvider)
                    case .toolCallFinished:
                        break
                    case .finished, .failed:
                        if case .failed(let message) = event { errorMessage = message }
                        messages = (try? await container.chatStore.messages(chatID: chat.id)) ?? messages
                        streamingText = ""
                        activity = nil
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    // Images

    func attach(image: NSImage) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        pendingImages.append(PendingImage(data: png, mimeType: "image/png", thumbnail: image))
    }

    /// Images go to the VLM, everything readable becomes an attached document (works with text-only models too).
    func attach(fileURL: URL) {
        switch DocumentExtractor.extract(url: fileURL) {
        case .image(let image): attach(image: image)
        case .document(let doc): pendingDocuments.append(doc)
        case nil: errorMessage = String(localized: "Unsupported file: \(fileURL.lastPathComponent)")
        }
    }

    /// A copied or dropped link, or the Safari extension button: the page text becomes a document attachment.
    func attach(webURL url: URL) {
        Task {
            do {
                pendingDocuments.append(try await WebPageDocument.fetch(url))
            } catch {
                errorMessage = String(localized: "Could not load the page: \(url.absoluteString)")
            }
        }
    }

    func removeDocument(_ name: String) {
        pendingDocuments.removeAll { $0.name == name }
    }

    func pasteFromClipboard() -> Bool {
        switch PasteboardAttachments.read() {
        case .files(let urls): urls.forEach { attach(fileURL: $0) }
        case .webURL(let url): attach(webURL: url)
        case .image(let image):
            guard canAttachImages else {
                errorMessage = String(localized: "This model does not accept images.")
                return true
            }
            attach(image: image)
        case nil: return false
        }
        return true
    }

    func removeImage(_ id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    // Store sync (the reply may have finished while the panel was closed)

    private func observeStore() {
        storeTask = Task { [weak self] in
            guard let changes = self?.container.chatStore.changes else { return }
            for await change in changes {
                guard let self, let chat = self.chat else { continue }
                switch change {
                case .messageInserted(let cid, _), .messageUpdated(let cid, _), .messageDeleted(let cid, _):
                    if cid == chat.id, !self.isGenerating {
                        self.messages = (try? await self.container.chatStore.messages(chatID: chat.id)) ?? self.messages
                    }
                case .chatDeleted(let cid) where cid == chat.id:
                    self.chat = nil
                    self.messages = []
                default:
                    break
                }
            }
        }
    }
}
