//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

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
    nonisolated static let minHeight: CGFloat = 48  // below the one-line field, so the panel never pads above it
    /// Height of the last content report, so the panel can snap back to it after the user stops dragging an edge.
    private var contentHeight: CGFloat = minHeight
    private var isApplyingFrame = false
    private var fitScheduled = false
    /// Waits for the end of a drag, see `windowDidMove`.
    private var dragWatch: Task<Void, Never>?

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
        // Above other apps' floating palettes too, like Spotlight; menus still open over it.
        // Above everything, as the OSD panel of System-Spinner does it: the screen-saver level clears other apps' floating
        // palettes and full-screen windows too.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // No show/hide animation: with the glass material it read as a flicker on every open and close.
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
            onChooseFiles: { [weak self] in self?.chooseFiles() },
            onToggleAutoClose: { [weak self] in self?.toggleAutoClose() }
        )
        .environment(container)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []  // the window is sized by `fit(contentHeight:)`, not by Auto Layout
        // The hidden title bar still counts as a safe area: the content got less height than the window, so the field
        // was pushed up out of the glass. `ignoresSafeArea()` in SwiftUI did not reach it.
        hosting.safeAreaRegions = []
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// The menu bar icon's window, so a click on it is not taken for "clicked elsewhere".
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
            return
        }
        position()
        // Lay out and size the panel before it is on screen, so it appears at its final height instead of growing a frame
        // later (the deferred `scheduleFit` is for layout passes; here, in an event handler, resizing directly is safe).
        panel.contentView?.layoutSubtreeIfNeeded()
        fit(contentHeight: contentHeight)
        // The app is usually not active here (hotkey, status item, Safari): "regardless" orders the panel front anyway,
        // and a non-activating panel takes the keyboard without pulling the app forward.
        panel.orderFrontRegardless()
        panel.makeKey()
        // A status menu item dismisses its menu only after this call returns; repeat once it has.
        Task { @MainActor [panel] in panel?.orderFrontRegardless() }
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

    /// The lock on the panel: applies at once, while the panel is shown.
    private func toggleAutoClose() {
        container.settings.panelClosesOnFocusLoss.toggle()
        installFocusObserver()
    }

    /// The open dialog goes above the panel (one level over it) and takes the keyboard; the panel must not auto-close
    /// while the dialog is key, so the focus observer rests until it is dismissed.
    private func chooseFiles() {
        removeFocusObserver()
        let dialog = NSOpenPanel()
        dialog.allowedContentTypes = [.pdf, .text, .sourceCode, .json, .rtf] + (viewModel.canAttachImages ? [.image] : [])
        dialog.allowsMultipleSelection = true
        dialog.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        NSApp.activate()
        dialog.begin { [weak self] response in
            guard let self else { return }
            if response == .OK { dialog.urls.forEach { self.viewModel.attach(fileURL: $0) } }
            guard panel.isVisible else { return }
            panel.makeKey()
            installFocusObserver()
        }
        dialog.orderFrontRegardless()
        dialog.makeKey()  // VERIFY(mac): the dialog gets the keyboard while the app is an accessory
    }

    // Geometry: the user drags the panel anywhere and drags its edges; width and the height limit for answers are remembered.

    /// SwiftUI reports the height from inside its layout pass, i.e. during a Core Animation commit, where resizing the
    /// window breaks AppKit's transaction ("Invalid attempt to open a new transaction during CA commit"): resize next turn.
    private func scheduleFit(contentHeight: CGFloat) {
        self.contentHeight = contentHeight
        guard !fitScheduled else { return }  // several reports in one frame collapse into one resize
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            fitScheduled = false
            fit(contentHeight: self.contentHeight)
        }
    }

    /// Follows the SwiftUI content: the bottom edge (the field) stays where it is and the panel grows or shrinks upwards,
    /// up to the height limit (the user's own, otherwise half of the screen) and never past the top of the screen.
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

    /// Dragging an edge: the width is kept as is, the height the user chose becomes the limit for answers.
    func windowDidEndLiveResize(_ notification: Notification) {
        viewModel.maxPanelHeight = max(panel.frame.height, 160)
        saveGeometry()
        fit(contentHeight: contentHeight)
    }

    /// Dragged higher or lower: the room above the field changes, and with it how tall the transcript may be.
    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame, panel.isVisible else { return }
        saveGeometry()
        // Resizing while the panel is being dragged fights the drag: refit once the mouse button is released.
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

    /// Remembered place and size if they still fit a screen; otherwise low on the screen under the cursor.
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
        fit(contentHeight: contentHeight)
    }

    /// A display was unplugged or its resolution changed while the panel is open: move it back if it ended up off-screen.
    /// `position()` falls back to the default place on its own because the remembered frame no longer fits any screen.
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
            MainActor.assumeIsolated {
                // A click on our own menu bar icon takes the focus too; the click decides what happens, not the auto-close
                // (which used to hide the panel only for the click to show it again).
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

/// Pure geometry behind `position()`, separated so it can be unit-tested without NSScreen.
enum PanelPlacement {
    /// `saved` is `SettingsKey.panelGeometry`: left, bottom, width, height limit and the format marker 1. Four items are the
    /// older top-anchored format (left, top, width, limit), converted with the current height; anything else is "first run".
    static func resolve(
        saved: [Double], panelHeight: CGFloat, visible: NSRect, screens: [NSRect]
    ) -> (frame: NSRect, maxHeight: CGFloat) {
        let hasSaved = saved.count == 4 || saved.count == 5
        let width =
            hasSaved ? min(max(CGFloat(saved[2]), QuickPanelController.minWidth), visible.width) : QuickPanelController.defaultWidth
        let maxHeight = hasSaved ? min(max(CGFloat(saved[3]), 160), visible.height) : visible.height / 2
        // Default: centred, the field a quarter of the screen above the bottom; answers grow the panel upwards from there.
        var frame = NSRect(x: visible.midX - width / 2, y: visible.minY + visible.height / 4, width: width, height: panelHeight)
        if hasSaved {
            let bottom = saved.count == 5 ? CGFloat(saved[1]) : CGFloat(saved[1]) - panelHeight
            let remembered = NSRect(x: CGFloat(saved[0]), y: bottom, width: width, height: panelHeight)
            // Off-screen (a display was unplugged, the resolution changed): fall back to the default place.
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
    /// ⌘N starts a new chat here, as it does in the chats window.
    var onNewChat: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Private AppKit hook (as System-Spinner's OSD uses): the glass and the controls keep their active look while the
    /// app itself stays in the background, which is where this panel spends its life.
    @objc(_hasActiveAppearance) dynamic func hasActiveAppearance() -> Bool { true }

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
    /// What the panel may really take: the limit above, cut by the room between the field and the top of the screen.
    var heightLimit: CGFloat = 480
    var pendingImages: [PendingImage] = []
    var pendingDocuments: [DocumentInput] = []
    private(set) var chat: Chat? { didSet { container.panelChatID = chat?.id } }
    private(set) var messages: [Message] = []
    /// Reply text currently streaming, before it lands in `messages`.
    private(set) var streamingText = ""
    /// Steps and thinking of the running reply, shown above it; nil when nothing runs.
    private(set) var progress: GenerationProgress?
    /// Questions sent while the model was busy; they go out one by one after the current reply.
    private(set) var queuedQuestions: [QueuedQuestion] = []
    /// Thinking time of replies finished in this session, for their summary line (not stored with the message).
    private(set) var thoughtSeconds: [UUID: Int] = [:]
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

    /// Bumped on every show: the field takes the keyboard each time, not only the first time the view appears.
    private(set) var focusToken = 0

    func panelDidAppear() {
        focusToken += 1
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
            errorMessage = ConversationService.describe(error)
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
            progress = nil
            queuedQuestions = []
            errorMessage = nil
            pendingImages = []
            pendingDocuments = []
        }
    }

    func stop() {
        guard let chat else { return }
        Task { await container.conversation.cancel(chatID: chat.id) }
    }

    /// Sends the field, or queues it while the model is still answering or thinking.
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty || !pendingDocuments.isEmpty else { return }
        guard container.activeModel != nil else {
            errorMessage = String(localized: "No model selected. Download one from the menu.")
            return
        }
        let question = QueuedQuestion(
            text: text, images: pendingImages.map { ImageInput(data: $0.data, mimeType: $0.mimeType) }, documents: pendingDocuments)
        input = ""
        pendingImages = []
        pendingDocuments = []
        if isGenerating {
            queuedQuestions.append(question)
        } else {
            start(question)
        }
    }

    func removeQueued(_ id: UUID) {
        queuedQuestions.removeAll { $0.id == id }
    }

    private func start(_ question: QueuedQuestion) {
        let (text, images, documents) = (question.text, question.images, question.documents)
        errorMessage = nil
        streamingText = ""
        progress = GenerationProgress()
        isGenerating = true

        streamTask = Task {
            do {
                if chat == nil { await loadActiveChat() }
                guard let chat else { return }
                // The panel answers with the model checked in the status menu.
                let stream = try await container.conversation.send(
                    chatID: chat.id, text: text, images: images, documents: documents, modelID: container.activeModel?.id)
                for await event in stream {
                    switch event {
                    case .started:
                        messages = (try? await container.chatStore.messages(chatID: chat.id)) ?? messages
                    case .token(let t):
                        streamingText += t
                        progress?.token(answerStarted: !visibleStreamingText.isEmpty)
                    case .toolCallStarted(let call):
                        // The call itself stays out of the transcript; the step says where the answer is going to come from.
                        // Whatever the model wrote before the call is a preamble: only the answer after the results is shown.
                        progress?.toolStarted(AnswerText.activity(for: call, searchProvider: container.settings.searchProvider))
                        streamingText = ""
                    case .toolCallFinished:
                        progress?.toolFinished()
                    case .retrying:
                        streamingText = ""
                    case .finished, .failed:
                        if case .failed(let message) = event { errorMessage = message }
                        if case .finished(let message) = event {
                            progress?.endThinking()
                            thoughtSeconds[message.id] = progress?.reportedThoughtSeconds
                            container.answerFinished(message)
                        }
                        messages = (try? await container.chatStore.messages(chatID: chat.id)) ?? messages
                        streamingText = ""
                        progress = nil
                    }
                }
            } catch {
                errorMessage = ConversationService.describe(error)
            }
            progress = nil
            isGenerating = false
            // The next waiting question goes out; after a failure the queue waits, the user sees the error first.
            if errorMessage == nil, !queuedQuestions.isEmpty { start(queuedQuestions.removeFirst()) }
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
