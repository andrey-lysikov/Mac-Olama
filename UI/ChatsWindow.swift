//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// ChatsViewModel

/// State for the full chats window: list, selection, transcript, composer.
@MainActor
@Observable
final class ChatsViewModel {
    private let container: AppContainer
    private(set) var chats: [Chat] = []
    private(set) var messages: [Message] = []
    private(set) var streamingText = ""
    /// Steps and thinking of the running reply, shown above it; nil when nothing runs.
    private(set) var progress: GenerationProgress?
    /// Questions sent while the model was busy; they go out one by one after the current reply, each to its own chat.
    private(set) var queuedQuestions: [QueuedQuestion] = []
    /// Thinking time of replies finished in this session, for their summary line (not stored with the message).
    private(set) var thoughtSeconds: [UUID: Int] = [:]
    private(set) var isGenerating = false
    private(set) var errorMessage: String?
    /// Bumped when the transcript should land on the newest message: history loaded, or the window came back to the front.
    private(set) var transcriptToken = 0
    /// Bumped when the window becomes key: the composer takes the keyboard, ready for the next question.
    private(set) var focusToken = 0
    var selectedChatID: UUID? {
        didSet {
            container.windowChatID = selectedChatID
            if selectedChatID != oldValue { Task { await loadMessages() } }
        }
    }
    var filter = ""
    var input = ""
    var pendingImages: [QuickPanelViewModel.PendingImage] = []
    var pendingDocuments: [DocumentInput] = []
    private var streamTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var pasteMonitor: Any?
    private var activationObserver: Any?

    var selectedChat: Chat? { chats.first { $0.id == selectedChatID } }
    var engineState: EngineState { container.engineState }
    /// The streamed reply without the model's private channels; notes about tools are separate state.
    var visibleStreamingText: String { AnswerText.visible(streamingText) }
    var filteredChats: [Chat] {
        filter.isEmpty ? chats : chats.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }
    var activeModel: ModelDescriptor? {
        if let id = selectedChat?.modelID, let m = container.models.first(where: { $0.id == id }) { return m }
        return container.activeModel
    }

    init(container: AppContainer) {
        self.container = container
        observe()
        installPasteMonitor()
        observeWindowActivation()
        Task {
            await reload()
            // Opened from "Model Library…": stay on the models section instead of auto-selecting a chat.
            if selectedChatID == nil, !container.showsModelLibrary { selectedChatID = container.settings.activeChatID ?? chats.first?.id }
        }
    }

    // Data

    func reload() async {
        chats = (try? await container.chatStore.allChats(includeArchived: false)) ?? []
        if let id = selectedChatID, !chats.contains(where: { $0.id == id }) { selectedChatID = chats.first?.id }
    }

    private func loadMessages() async {
        guard let id = selectedChatID else {
            messages = []
            loadedChatID = nil
            return
        }
        let loaded = (try? await container.chatStore.messages(chatID: id)) ?? []
        guard id == selectedChatID else { return }  // another chat was picked meanwhile; its own load follows
        messages = loaded
        loadedChatID = id
        isGenerating = await container.conversation.isGenerating(chatID: id)
        transcriptToken += 1
    }

    /// This window is writing the current reply (it has its own token stream and progress). `isGenerating` is also true when
    /// another surface writes to this chat; then the stored messages are all there is to show.
    var streamsHere: Bool { progress != nil }

    /// The chat whose messages are on screen; until it matches the selection the transcript is still loading.
    private(set) var loadedChatID: UUID?
    var isLoadingChat: Bool { selectedChatID != nil && loadedChatID != selectedChatID }

    /// The window is reused, so the transcript keeps the offset it was left at; raising it again starts at the newest message.
    /// Filtering by the window object keeps the notification out of the closure, which must not carry it across actors.
    private func observeWindowActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: WindowManager.shared.window(.chats), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.container.checkModelAvailability()
                self?.transcriptToken += 1
                self?.focusToken += 1
            }
        }
    }

    private func observe() {
        changesTask = Task { [weak self] in
            guard let changes = self?.container.chatStore.changes else { return }
            for await change in changes {
                guard let self else { return }
                switch change {
                case .chatInserted, .chatUpdated, .chatDeleted:
                    await self.reload()
                case .messageInserted(let cid, _), .messageUpdated(let cid, _), .messageDeleted(let cid, _):
                    // Skipped only while this window streams the reply itself; one written by the panel or the API is
                    // followed through the store, its partial text saved every quarter second.
                    if cid == self.selectedChatID, !self.streamsHere { await self.loadMessages() }
                }
            }
        }
    }

    // Chats

    func newChat() {
        container.showsModelLibrary = false
        Task {
            let chat = try? await container.conversation.newChat(origin: .window)
            await reload()
            selectedChatID = chat?.id
            container.setActiveChat(chat?.id)
        }
    }

    func delete(_ chat: Chat) {
        Task {
            try? await container.conversation.deleteChat(id: chat.id)
            await reload()
        }
    }

    func rename(_ chat: Chat, to title: String) {
        var updated = chat
        updated.title = title
        Task { try? await container.chatStore.update(updated) }
    }

    func setSystemPrompt(_ text: String) {
        guard var chat = selectedChat else { return }
        chat.systemPrompt = text.isEmpty ? nil : text
        Task { try? await container.chatStore.update(chat) }
    }

    /// Same as picking the model in the status menu: it becomes the app-wide model (checked there) and this chat and the
    /// panel's switch to it.
    func setModel(_ model: ModelDescriptor) {
        // Shown (and used by the next question) at once; the store's own update arrives a moment later.
        if let i = chats.firstIndex(where: { $0.id == selectedChatID }) { chats[i].modelID = model.id }
        container.chooseModel(model)
    }

    // Context

    /// Window the chat runs with: the context saved for its model, otherwise the model maximum.
    var contextLimit: Int? { activeModel.flatMap { container.contextTokens(for: $0) } }

    /// Estimate: exact counts for generated replies, ~3 characters per token for everything else.
    var contextUsed: Int {
        let system = (selectedChat?.systemPrompt?.count ?? 0) / 3
        let history = messages.reduce(0) { $0 + ($1.role == .assistant ? $1.completionTokens ?? $1.text.count / 3 : $1.text.count / 3) }
        return system + history + (streamingText.count + input.count) / 3
    }

    // Messages

    /// Sends the composer, or queues it while the model is still answering or thinking.
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty || !pendingDocuments.isEmpty else { return }
        let question = QueuedQuestion(
            chatID: selectedChatID, text: text, images: pendingImages.map { ImageInput(data: $0.data, mimeType: $0.mimeType) },
            documents: pendingDocuments)
        input = ""
        pendingImages = []
        pendingDocuments = []
        if isGenerating {
            queuedQuestions.append(question)
        } else {
            ask(question)
        }
    }

    func removeQueued(_ id: UUID) {
        queuedQuestions.removeAll { $0.id == id }
    }

    /// Questions waiting for the chat on screen.
    var queuedHere: [QueuedQuestion] { queuedQuestions.filter { $0.chatID == selectedChatID } }

    private func ask(_ question: QueuedQuestion) {
        let (text, images, documents) = (question.text, question.images, question.documents)
        // A queued question goes to the chat it was asked in, even if another chat is on screen by now.
        if let chatID = question.chatID, chatID != selectedChatID { selectedChatID = chatID }
        run { chatID in
            // The model shown in the composer is the one that answers, whatever the store still says.
            try await self.container.conversation.send(
                chatID: chatID, text: text, images: images, documents: documents, modelID: self.activeModel?.id)
        }
    }

    /// Deletes the last assistant reply and asks again with the same user message.
    func regenerate() {
        guard let last = messages.last, last.role == .assistant,
            let user = messages.last(where: { $0.role == .user })
        else { return }
        Task {
            try? await container.chatStore.deleteMessage(id: last.id)
            try? await container.chatStore.deleteMessage(id: user.id)
            let images = (try? user.attachments.map { try loadImage($0) }) ?? []
            run { chatID in
                try await self.container.conversation.send(chatID: chatID, text: user.text, images: images, modelID: self.activeModel?.id)
            }
        }
    }

    func stop() {
        guard let id = selectedChatID else { return }
        Task { await container.conversation.cancel(chatID: id) }
    }

    /// ⌘V in the chats window: a copied image or file becomes an attachment; plain text still goes to the text field.
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 9, flags == .command else { return event }  // V, in any keyboard layout
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, NSApp.keyWindow?.identifier?.rawValue == WindowManager.ID.chats.rawValue,
                    !self.container.showsModelLibrary
                else { return false }
                return self.pasteFromClipboard()
            }
            return handled ? nil : event
        }
    }

    func pasteFromClipboard() -> Bool {
        switch PasteboardAttachments.read() {
        case .files(let urls): urls.forEach { attach(fileURL: $0) }
        case .webURL(let url): attach(webURL: url)
        case .image(let image):
            guard activeModel?.kind == .vlm else {
                errorMessage = String(localized: "This model does not accept images.")
                return true
            }
            attach(image: image)
        case nil: return false
        }
        return true
    }

    func attach(image: NSImage) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        pendingImages.append(.init(data: png, mimeType: "image/png", thumbnail: image))
    }

    func attach(fileURL: URL) {
        switch DocumentExtractor.extract(url: fileURL) {
        case .image(let image): attach(image: image)
        case .document(let doc): pendingDocuments.append(doc)
        case nil: errorMessage = String(localized: "Unsupported file: \(fileURL.lastPathComponent)")
        }
    }

    /// A copied or dropped link: the page text becomes a document attachment.
    func attach(webURL url: URL) {
        Task {
            do {
                pendingDocuments.append(try await WebPageDocument.fetch(url))
            } catch {
                errorMessage = String(localized: "Could not load the page: \(url.absoluteString)")
            }
        }
    }

    private func loadImage(_ a: Attachment) throws -> ImageInput {
        ImageInput(data: try Data(contentsOf: container.paths.attachments.appendingPathComponent(a.relativePath)), mimeType: "image/png")
    }

    private func run(_ start: @escaping (UUID) async throws -> AsyncStream<ConversationEvent>) {
        streamTask?.cancel()
        streamTask = Task {
            do {
                if selectedChatID == nil { newChat(); try await Task.sleep(for: .milliseconds(50)) }
                guard let chatID = selectedChatID else { return }
                errorMessage = nil
                streamingText = ""
                progress = GenerationProgress()
                isGenerating = true
                for await event in try await start(chatID) {
                    switch event {
                    case .started: await loadMessagesKeepingFlag()
                    case .token(let t):
                        streamingText += t
                        progress?.token(answerStarted: !visibleStreamingText.isEmpty)
                    // The call itself stays out of the transcript; the step says where the answer is going to come from.
                    case .toolCallStarted(let call):
                        progress?.toolStarted(AnswerText.activity(for: call, searchProvider: container.settings.searchProvider))
                        streamingText = ""  // the preamble before the call is not the answer
                    case .toolCallFinished: progress?.toolFinished()
                    case .retrying: streamingText = ""
                    case .failed(let e): errorMessage = e
                    case .finished(let message):
                        progress?.endThinking()
                        thoughtSeconds[message.id] = progress?.reportedThoughtSeconds
                        container.answerFinished(message)
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
            streamingText = ""
            progress = nil
            await loadMessages()
            // The next waiting question goes out; after a failure the queue waits, the user sees the error first.
            if errorMessage == nil, !queuedQuestions.isEmpty { ask(queuedQuestions.removeFirst()) }
        }
    }

    private func loadMessagesKeepingFlag() async {
        guard let id = selectedChatID else { return }
        messages = (try? await container.chatStore.messages(chatID: id)) ?? []
    }
}

// ChatsWindowView

struct ChatsWindowView: View {
    @Environment(AppContainer.self) private var container
    @State private var viewModel: ChatsViewModel?

    var body: some View {
        Group {
            if let viewModel { ChatsSplitView(viewModel: viewModel) } else { ProgressView() }
        }
        .onAppear { if viewModel == nil { viewModel = ChatsViewModel(container: container) } }
    }
}

private struct ChatsSplitView: View {
    @Bindable var viewModel: ChatsViewModel
    @Environment(AppContainer.self) private var container
    @State private var renaming: Chat?
    @State private var renameText = ""
    @State private var showSystemPrompt = false
    @State private var systemPromptText = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // The model library replaces the chat in the same detail area and brings its own toolbar items.
            if container.showsModelLibrary { ModelLibraryView() } else { detail }
        }
        .navigationSplitViewStyle(.balanced)
        // "Open in Chats" from the panel: that chat, selected before the window's own choice can show another one.
        .onChange(of: container.requestedWindowChatID, initial: true) { _, id in
            guard let id else { return }
            viewModel.selectedChatID = id
            container.requestedWindowChatID = nil
        }
        // The window is named after what it shows: the chat's short title, as in the sidebar, or the models section.
        .onChange(of: windowTitle, initial: true) { _, title in WindowManager.shared.window(.chats)?.title = title }
        // Showing the library (menu, notification, sidebar) clears the chat selection so only one section is highlighted.
        .onChange(of: container.showsModelLibrary) { _, shown in if shown { viewModel.selectedChatID = nil } }
        .onChange(of: viewModel.focusToken) { _, _ in
            composerFocused = true
            FieldCaret.moveToEnd()
        }
        // A new attachment (paste, drop, file picker, link) puts the caret in the composer, ready for the question.
        .onChange(of: viewModel.pendingImages.count + viewModel.pendingDocuments.count) { old, new in
            guard new > old else { return }
            composerFocused = true
            FieldCaret.moveToEnd()
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var windowTitle: String {
        if container.showsModelLibrary { return String(localized: "Models") }
        return viewModel.selectedChat.map { $0.title.isEmpty ? String(localized: "Untitled chat") : $0.title }
            ?? String(localized: "New Chat")
    }

    // Sidebar

    private var sidebar: some View {
        @Bindable var container = container
        return List(selection: $viewModel.selectedChatID) {
            ForEach(groupedChats, id: \.0) { section, chats in
                Section(section) {
                    ForEach(chats) { chat in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                // Titles come from the first question: three lines tell chats apart better than one.
                                Text(chat.title.isEmpty ? String(localized: "Untitled chat") : chat.title).lineLimit(3)
                                // A plain date, not a ticking relative timer: a running clock read as "still generating".
                                Text(chat.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(
                                    .secondary)
                            }
                            Spacer(minLength: 4)
                            Button {
                                viewModel.delete(chat)
                            } label: {
                                Image(systemName: "trash").contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(String(localized: "Delete Chat"))
                        }
                        .tag(chat.id)
                        .contextMenu {
                            Button(String(localized: "Rename…")) {
                                renaming = chat; renameText = chat.title
                            }
                            Button(String(localized: "Open in Panel")) { container.setActiveChat(chat.id) }
                            Button(String(localized: "System Prompt…")) {
                                container.showsModelLibrary = false
                                viewModel.selectedChatID = chat.id
                                systemPromptText = chat.systemPrompt ?? ""
                                showSystemPrompt = true
                            }
                            Divider()
                            Button(String(localized: "Delete"), role: .destructive) { viewModel.delete(chat) }
                        }
                    }
                }
            }
        }
        // Picking a chat always leaves the model library.
        .onChange(of: viewModel.selectedChatID) { _, id in if id != nil { container.showsModelLibrary = false } }
        .searchable(text: $viewModel.filter, placement: .sidebar, prompt: String(localized: "Search chats"))
        // Sidebar toolbar: the button sits right of the sidebar toggle and stays inside the sidebar column.
        .toolbar {
            ToolbarItem {
                Button {
                    viewModel.newChat()
                } label: {
                    Label(String(localized: "New Chat"), systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help(String(localized: "New Chat"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { modelsEntry }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .alert(String(localized: "Rename Chat"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(String(localized: "Title"), text: $renameText)
            Button(String(localized: "Save")) {
                if let c = renaming { viewModel.rename(c, to: renameText) }; renaming = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { renaming = nil }
        }
    }

    /// Pinned at the very bottom of the sidebar: opens the model library in the detail area.
    private var modelsEntry: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                container.showsModelLibrary = true
                viewModel.selectedChatID = nil
            } label: {
                Label(String(localized: "Models"), systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    // Selected like a sidebar row: accent fill, not the grey `.selection` material.
                    .foregroundStyle(container.showsModelLibrary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background(
                        container.showsModelLibrary ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    private var groupedChats: [(String, [Chat])] {
        let cal = Calendar.current
        var buckets: [(String, [Chat])] = []
        func bucket(_ c: Chat) -> String {
            if cal.isDateInToday(c.updatedAt) { return String(localized: "Today") }
            if cal.isDateInYesterday(c.updatedAt) { return String(localized: "Yesterday") }
            if let week = cal.date(byAdding: .day, value: -7, to: .now), c.updatedAt > week { return String(localized: "Previous 7 days") }
            return String(localized: "Older")
        }
        for chat in viewModel.filteredChats {
            let b = bucket(chat)
            if let i = buckets.firstIndex(where: { $0.0 == b }) { buckets[i].1.append(chat) } else { buckets.append((b, [chat])) }
        }
        return buckets
    }

    // Detail: centered column, user bubbles on the right, plain assistant text, rounded composer (the familiar Ollama layout)

    private var detail: some View {
        // The chat's title is the window's title (`windowTitle`), not a line of its own above the transcript.
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.isLoadingChat {
                // Nothing, rather than the empty-chat prompt flashing before the history arrives.
                Spacer().frame(maxWidth: .infinity)
            } else if viewModel.messages.isEmpty && viewModel.streamingText.isEmpty && viewModel.errorMessage == nil {
                emptyState
            } else {
                transcript
            }
            // Questions asked while the model works stay pinned above the composer until their turn comes.
            if !viewModel.queuedHere.isEmpty {
                QueuedQuestionsView(questions: viewModel.queuedHere, onRemove: viewModel.removeQueued)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            composer
        }
        .popover(isPresented: $showSystemPrompt, attachmentAnchor: .point(.top), arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("System prompt for this chat").font(.headline)
                TextEditor(text: $systemPromptText).frame(width: 360, height: 140).font(.body)
                HStack {
                    Spacer()
                    Button(String(localized: "Save")) {
                        viewModel.setSystemPrompt(systemPromptText)
                        showSystemPrompt = false
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(12)
        }
    }

    // Nothing on the chat background: the composer below is the only call to action.
    private var emptyState: some View {
        Spacer().frame(maxWidth: .infinity)
    }

    private var transcript: some View {
        let visible = viewModel.messages.filter { $0.role == .user || $0.role == .assistant }
        return ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a lazy stack guessed the heights of rows it had not drawn yet, so the scroll jumped while an
                // answer streamed, rows stayed blank until another chat was opened and a reused row could draw flipped.
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { position, m in
                        // Tool rounds fold into one summary line above the answer they led to.
                        if isStreamedPlaceholder(m) {
                            EmptyView()
                        } else if m.toolCalls.isEmpty {
                            ChatMessageView(
                                message: m,
                                summary: m.role == .assistant
                                    ? AnswerText.summary(
                                        of: AnswerText.toolCalls(before: position, in: visible),
                                        thoughtSeconds: viewModel.thoughtSeconds[m.id])
                                    : nil,
                                onRegenerate: m.id == visible.last?.id && m.role == .assistant && !viewModel.isGenerating
                                    ? { viewModel.regenerate() } : nil)
                        } else if !AnswerText.isFoldedIntoAnswer(position, in: visible) {
                            ChatMessageView(
                                message: m, summary: AnswerText.summary(of: m.toolCalls, thoughtSeconds: nil), onRegenerate: nil)
                        }
                    }
                    if let progress = viewModel.progress {
                        GenerationProgressView(progress: progress, engineState: viewModel.engineState)
                    }
                    if !viewModel.visibleStreamingText.isEmpty {
                        ChatMessageView(
                            message: Message(chatID: UUID(), role: .assistant, text: viewModel.visibleStreamingText, isPartial: true),
                            onRegenerate: nil
                        )
                        .id("streaming")
                    }
                    if let e = viewModel.errorMessage {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Growing content stays pinned to the bottom by the anchor; no scroll per token, which made the view jump.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: viewModel.messages.count) { _, _ in scrollToEnd(proxy) }
            // A freshly loaded history is laid out a frame later, so the jump to its end waits for that.
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: viewModel.transcriptToken) { _, _ in scrollToEnd(proxy) }
        }
    }

    /// The stored copy of the reply being written: the streamed text stands for it, otherwise it shows as a stray "…".
    private func isStreamedPlaceholder(_ message: Message) -> Bool {
        viewModel.streamsHere && message.id == viewModel.messages.last?.id && message.role == .assistant && message.toolCalls.isEmpty
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // Composer: text on top; below it attach, context usage, the chat's model and send/stop.

    private var hasComposerInput: Bool {
        !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.pendingImages.isEmpty
            || !viewModel.pendingDocuments.isEmpty
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.pendingImages.isEmpty || !viewModel.pendingDocuments.isEmpty { pendingAttachments }
            TextField(String(localized: "Ask a question…"), text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: ChatMessageView.textSize))
                .lineLimit(1...10)
                .focused($composerFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    viewModel.send()
                    return .handled
                }
            HStack(spacing: 10) {
                Button {
                    chooseFile()
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(String(localized: "Attach files"))
                Spacer(minLength: 4)
                // Narrow window: the context estimate is the first thing to go, the model name truncates next.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        contextUsage
                        modelPicker
                    }
                    modelPicker
                }
                if viewModel.isGenerating {
                    ProgressView().controlSize(.small)
                    Button(action: viewModel.stop) {
                        Image(systemName: "stop.fill")
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .help(String(localized: "Stop"))
                } else {
                    Button(action: viewModel.send) {
                        Image(systemName: "arrow.up")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .disabled(!hasComposerInput)
                    .help(String(localized: "Send"))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .onDrop(of: [.fileURL, .url, .image], isTargeted: nil) { providers in
            for p in providers {
                if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                        guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        Task { @MainActor in viewModel.attach(fileURL: url) }
                    }
                } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    p.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                        guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isWebURL
                        else { return }
                        Task { @MainActor in viewModel.attach(webURL: url) }
                    }
                } else if p.canLoadObject(ofClass: NSImage.self) {
                    _ = p.loadObject(ofClass: NSImage.self) { image, _ in
                        if let image = image as? NSImage { Task { @MainActor in viewModel.attach(image: image) } }
                    }
                }
            }
            return true
        }
    }

    private var pendingAttachments: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.pendingImages) { img in
                Image(nsImage: img.thumbnail).resizable().scaledToFill().frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            ForEach(viewModel.pendingDocuments, id: \.name) { doc in
                Label(doc.name, systemImage: "doc.text").font(.caption).lineLimit(1).padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
        }
    }

    /// Menus are drawn by AppKit, so the icon goes in as an image (the hub's symbol until the avatars have loaded).
    private func modelImage(_ model: ModelDescriptor) -> Image {
        _ = ModelIcons.shared.revision
        return ModelIcons.shared.menuImage(for: model, size: 16).map { Image(nsImage: $0) } ?? Image(systemName: model.source.symbol)
    }

    /// Model used by this chat; defaults to the one picked in the status menu.
    private var modelPicker: some View {
        Menu {
            // A menu row takes one title and one icon: the model's icon, the toggle draws the check mark.
            ForEach(container.models) { m in
                Toggle(
                    isOn: Binding(get: { m.id == viewModel.activeModel?.id }, set: { _ in viewModel.setModel(m) })
                ) {
                    Label {
                        Text(verbatim: m.kind == .vlm ? "\(m.name) · VLM" : m.name)
                    } icon: {
                        modelImage(m)
                    }
                    .labelStyle(.titleAndIcon)  // menus on macOS 26+ drop item icons unless asked to show them
                }
                .disabled(!container.isAvailable(m))
            }
            if container.models.isEmpty {
                Button(String(localized: "Model Library…")) { WindowManager.shared.openModels() }
            }
        } label: {
            if let model = viewModel.activeModel {
                // An unreachable server greys the chat's model out, like its row in the list.
                Label {
                    Text(verbatim: model.name).font(.callout).lineLimit(1).truncationMode(.middle)
                } icon: {
                    modelImage(model)
                }
                .foregroundStyle(container.isAvailable(model) ? .primary : .tertiary)  // VERIFY(mac): menu label keeps the style
                .help(
                    container.isAvailable(model)
                        ? String(localized: "Model for this chat") : String(localized: "The server does not answer"))
            } else {
                Text(String(localized: "No model")).font(.callout)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 260)
        .fixedSize(horizontal: true, vertical: false)
        .help(String(localized: "Model for this chat"))
        // Locked until this chat's answer is complete (tool rounds included); other chats keep their own picker free.
        .disabled(viewModel.isGenerating)
    }

    @ViewBuilder
    private var contextUsage: some View {
        if let limit = viewModel.contextLimit, limit > 0 {
            let used = min(viewModel.contextUsed, limit)
            Text(verbatim: "≈\(Self.tokens(used)) / \(Self.tokens(limit)) · " + String(localized: "\(Self.tokens(limit - used)) free"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(used > limit * 9 / 10 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .help(String(localized: "Estimated context used by this chat, the context window, and what is left"))
        }
    }

    private static func tokens(_ count: Int) -> String {
        count < 1000 ? "\(count)" : "\((Double(count) / 1024).formatted(.number.precision(.fractionLength(count < 10_240 ? 1 : 0))))k"
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        let documents: [UTType] = [.pdf, .text, .sourceCode, .json, .rtf]
        panel.allowedContentTypes = viewModel.activeModel?.kind == .vlm ? [.image] + documents : documents
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { viewModel.attach(fileURL: url) }
        }
    }
}

// ChatMessageView

/// Chat transcript line: the user's text in a bubble on the right, the model's reply as plain Markdown on the left.
private struct ChatMessageView: View {
    /// Reading size of the transcript; the panel keeps the system 13 pt, the window is for longer reading.
    static let textSize: CGFloat = 15
    let message: Message
    /// What the tools and the thinking did on the way to this answer, one line above it.
    var summary: String?
    var onRegenerate: (() -> Void)?
    @State private var hovering = false
    @Environment(AppContainer.self) private var container

    /// Reasoning channels and tool syntax are the model talking to itself; only the answer is shown and copied.
    private var answer: String { AnswerText.visible(message.text) }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    AttachmentStrip(attachments: message.attachments)
                    if !message.text.isEmpty {
                        Text(message.text).textSelection(.enabled).font(.system(size: Self.textSize))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let summary { ProgressSummaryLine(text: summary) }
                // A reply that asked for tools has no answer of its own: its text is a preamble or echoed results.
                if message.toolCalls.isEmpty {
                    if answer.isEmpty, !message.isPartial {
                        NoAnswerLine()
                    } else {
                        MarkdownView(markdown: answer.isEmpty ? "…" : answer, baseFontSize: Self.textSize)
                    }
                }
                if !message.isPartial, message.toolCalls.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(answer, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help(String(localized: "Copy"))
                        if let onRegenerate {
                            Button(action: onRegenerate) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help(String(localized: "Regenerate"))
                        }
                        if let tps = message.tokensPerSecond {
                            Text(String(localized: "\(Int(tps)) tok/s")).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .opacity(hovering || onRegenerate != nil ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering = $0 }
        }
    }
}
