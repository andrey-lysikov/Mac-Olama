//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

// ChatsViewModel

/// State for the full chats window: list, selection, transcript, composer.
/// Streaming, queueing and attachments live in `ConversationStreamCoordinator`, shared with the panel.
@MainActor
@Observable
final class ChatsViewModel: ConversationStreamDelegate, ConversationStreamHosting {
    private let container: AppContainer
    let stream: ConversationStreamCoordinator
    private(set) var chats: [Chat] = []
    /// Another surface (panel, API) is writing into the selected chat; the stored messages are all there is to show.
    private var remoteGenerating = false
    /// Bumped when the transcript should land on the newest message whatever the user was reading: another chat
    /// opened, the window came back to the front, a question sent. A reply growing or ending is followed by the view.
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
    // Cleanup handles only: `nonisolated(unsafe)` so `deinit`, which is not main-actor isolated, can tear them down.
    @ObservationIgnored nonisolated(unsafe) private var changesTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var pasteMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var activationObserver: Any?

    // The rest of the coordinator's state is forwarded by `ConversationStreamHosting`; only this differs here:
    // the window's own reply shows only in the chat it writes into, and another surface writing into the selected
    // chat counts as generating too.
    var isGenerating: Bool { streamsIntoShownChat || remoteGenerating }
    var streamingText: String { streamsIntoShownChat ? stream.streamingText : "" }
    var visibleStreamingText: String { streamsIntoShownChat ? stream.visibleStreamingText : "" }
    var progress: GenerationProgress? { streamsIntoShownChat ? stream.progress : nil }
    var streamsHere: Bool { streamsIntoShownChat && stream.streamsHere }

    /// The window's reply runs in the chat on screen (or is still creating it); another chat opened meanwhile
    /// shows its own history, not the stream.
    private var streamsIntoShownChat: Bool {
        stream.isGenerating && (stream.streamingChatID == nil || stream.streamingChatID == selectedChatID)
    }

    var selectedChat: Chat? { chats.first { $0.id == selectedChatID } }
    var engineState: EngineState { container.engineState }
    var filteredChats: [Chat] {
        filter.isEmpty ? chats : chats.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }
    var activeModel: ModelDescriptor? {
        if let id = selectedChat?.modelID, let m = container.models.first(where: { $0.id == id }) { return m }
        return container.activeModel
    }

    init(container: AppContainer) {
        self.container = container
        self.stream = ConversationStreamCoordinator(container: container)
        stream.delegate = self
        observe()
        installPasteMonitor()
        observeWindowActivation()
        Task {
            await reload()
            await refreshGeneratingChats()
            // Opened from "Model Library…": stay on the models section instead of auto-selecting a chat.
            if selectedChatID == nil, container.section == .chat { selectedChatID = container.settings.activeChatID ?? chats.first?.id }
        }
    }

    deinit {
        // The window object is cached for the app's life today, but a recreated model must not leak monitors.
        changesTask?.cancel()
        nonisolated(unsafe) let pasteMonitor = pasteMonitor
        nonisolated(unsafe) let activationObserver = activationObserver
        DispatchQueue.main.async {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        }
    }

    // ConversationStreamDelegate

    func chatIDForSending(question: QueuedQuestion) async -> UUID? {
        // A queued question goes to the chat it was asked in, even if another chat is on screen by now.
        if let chatID = question.chatID {
            if chatID != selectedChatID { selectedChatID = chatID }
            return chatID
        }
        if let chatID = selectedChatID { return chatID }
        // First question of a fresh window: the chat is created and selected before anything is sent.
        container.section = .chat
        guard let chat = try? await container.conversation.newChat(origin: .window) else { return nil }
        await reload()
        selectedChatID = chat.id
        container.setActiveChat(chat.id)
        return chat.id
    }

    func modelIDForSending() -> String? { activeModel?.id }

    func displaysChat(_ chatID: UUID) -> Bool { selectedChatID == chatID }

    /// Nothing to refresh here: the end of a reply is followed by the transcript unless the user scrolled up to read.
    func streamDidFinish(chatID: UUID) {}

    var acceptsImages: Bool { activeModel?.kind == .vlm }

    // Data

    func reload() async {
        chats = (try? await container.chatStore.allChats(includeArchived: false)) ?? []
        if let id = selectedChatID, !chats.contains(where: { $0.id == id }) { selectedChatID = chats.first?.id }
    }

    private func loadMessages() async {
        guard let id = selectedChatID else {
            stream.setMessages([])
            loadedChatID = nil
            return
        }
        let loaded = await stream.fetchMessages(chatID: id)
        guard id == selectedChatID else { return }  // another chat was picked meanwhile; its own load follows
        // The same chat reloads four times a second while another surface writes into it; only a new one jumps.
        let opened = loadedChatID != id
        stream.setMessages(loaded)
        loadedChatID = id
        let wasRemote = remoteGenerating
        remoteGenerating = await container.conversation.isGenerating(chatID: id) && stream.streamingChatID != id
        // A reply that ran on another surface just ended: questions queued here may go out now.
        if wasRemote, !remoteGenerating { stream.drainQueue() }
        if opened { transcriptToken += 1 }
    }

    /// The chat whose messages are on screen; until it matches the selection the transcript is still loading.
    private(set) var loadedChatID: UUID?
    var isLoadingChat: Bool { selectedChatID != nil && loadedChatID != selectedChatID }

    /// The window is reused, so the transcript keeps the offset it was left at; raising it again starts at the newest message.
    /// The model is built while the window is still being made, so there is no window object to filter by yet: instead
    /// the closure asks which window is key, and never carries the notification across actors.
    private func observeWindowActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard WindowManager.shared.window(.chats)?.isKeyWindow == true else { return }
                self?.transcriptToken += 1
                self?.focusToken += 1
            }
        }
    }

    private func observe() {
        changesTask = stream.observeStoreChanges(
            onChats: { [weak self] in await self?.reload() },
            onMessages: { [weak self] chatID in
                await self?.refreshGeneratingChats()
                // Skipped only while this window streams the reply itself; one written by the panel or the API is
                // followed through the store, its partial text saved every quarter second.
                guard let self, chatID == self.selectedChatID, !self.streamsHere else { return }
                await self.loadMessages()
            })
    }

    /// Chats the model is answering in right now, marked in the list whichever surface asked.
    private(set) var generatingChatIDs: Set<UUID> = []
    @ObservationIgnored private var generatingPoll: Task<Void, Never>?

    /// A reply's last write lands just before its run is over, so while any chat is busy the set is re-read
    /// twice a second until it empties; the mark would otherwise stay on a finished chat.
    private func refreshGeneratingChats() async {
        let ids = await container.conversation.generatingChatIDs
        if ids != generatingChatIDs { generatingChatIDs = ids }
        guard !ids.isEmpty, generatingPoll == nil else { return }
        generatingPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let ids = await self.container.conversation.generatingChatIDs
                if ids != self.generatingChatIDs { self.generatingChatIDs = ids }
                if ids.isEmpty { break }
            }
            self?.generatingPoll = nil
        }
    }

    // Chats

    func newChat() {
        container.section = .chat
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

    var contextUsed: Int { stream.contextUsed(systemPrompt: selectedChat?.systemPrompt) }

    // Messages

    /// Sends the composer, or queues it while the model is still answering or thinking (here or on another surface).
    func send() {
        stream.send(chatID: selectedChatID, surfaceBusy: remoteGenerating)
        transcriptToken += 1
    }

    /// Questions waiting for the chat on screen.
    var queuedHere: [QueuedQuestion] { queuedQuestions.filter { $0.chatID == selectedChatID } }

    /// Deletes the tail from the last user message and asks it again.
    func regenerate() {
        // A new run would take over the window's stream while it still writes into another chat.
        guard let chatID = selectedChatID, !stream.isGenerating else { return }
        stream.regenerate(chatID: chatID)
        transcriptToken += 1
    }

    func stop() {
        // Stops the reply of the chat on screen: the window's own, or one another surface writes into it.
        guard let id = streamsIntoShownChat ? stream.streamingChatID ?? selectedChatID : selectedChatID else { return }
        Task { await container.conversation.cancel(chatID: id) }
    }

    /// ⌘V in the chats window: a copied image or file becomes an attachment; plain text still goes to the text field.
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 9, flags == .command else { return event }  // V, in any keyboard layout
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, NSApp.keyWindow?.identifier?.rawValue == WindowManager.ID.chats.rawValue,
                    self.container.section == .chat
                else { return false }
                return self.pasteFromClipboard()
            }
            return handled ? nil : event
        }
    }

}

// ChatsWindowView

struct ChatsWindowView: View {
    @Environment(AppContainer.self) private var container
    @State private var viewModel: ChatsViewModel?

    var body: some View {
        VStack(spacing: 0) {
            if let failure = container.storeFailure { StoreFailureBanner(failure: failure) }
            Group {
                if let viewModel { ChatsSplitView(viewModel: viewModel) } else { ProgressView() }
            }
        }
        .onAppear { if viewModel == nil { viewModel = ChatsViewModel(container: container) } }
    }
}

/// The chat database failed to open: this session is in memory only, and the user must know before typing.
private struct StoreFailureBanner: View {
    let failure: AppContainer.StoreFailure

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(
                failure.recovered
                    ? String(
                        localized:
                            "The chat database was damaged and has been reset (\(failure.message)). The old one was backed up.")
                    : String(
                        localized:
                            "Chat history is unavailable (\(failure.message)). New chats will not be saved. A backup of the database was made."
                    )
            )
            .lineLimit(2)
            Spacer()
            if let backup = failure.backup {
                Button(String(localized: "Show Backup in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([backup])
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.12))
    }
}

private struct ChatsSplitView: View {
    /// The composer reads at the size of the messages above it, the system's text size included.
    @ScaledMetric(relativeTo: .body) private var scaledText: CGFloat = ChatMessageView.textSize
    @Bindable var viewModel: ChatsViewModel
    @Environment(AppContainer.self) private var container
    @State private var renaming: Chat?
    @State private var renameText = ""
    @State private var showSystemPrompt = false
    @State private var systemPromptText = ""
    @FocusState private var composerFocused: Bool
    /// The models section keeps its state (search, drafts) while the window shows a chat.
    @State private var models: DownloadViewModel?
    @State private var sidebarWidth: CGFloat = 260
    @State private var sidebarDragStart: CGFloat?
    @State private var showsSidebar = true

    var body: some View {
        // Two columns split by a line that runs the whole height of the window, as in the stock apps: the list column
        // carries the window buttons and the two round ones, the right column its own header. No window toolbar is used,
        // so nothing of it can drift or fold away into a "»" menu.
        HStack(spacing: 0) {
            if showsSidebar {
                sidebar.frame(width: sidebarWidth)
                sidebarHandle
            }
            detailColumn
        }
        .onAppear {
            if models == nil { models = DownloadViewModel(container: container) }
            sidebarWidth = min(max(CGFloat(container.settings.sidebarWidth), 200), 420)
        }
        // "Open in Chats" from the panel: that chat, selected before the window's own choice can show another one.
        .onChange(of: container.requestedWindowChatID, initial: true) { _, id in
            guard let id else { return }
            viewModel.selectedChatID = id
            container.requestedWindowChatID = nil
        }
        // The window is named after what it shows: the chat's short title, as in the sidebar, or the models section.
        .onChange(of: windowTitle, initial: true) { _, title in WindowManager.shared.window(.chats)?.title = title }
        // Showing the library (menu, notification, sidebar) clears the chat selection so only one section is highlighted.
        .onChange(of: container.section) { _, section in if section != .chat { viewModel.selectedChatID = nil } }
        .onChange(of: viewModel.focusToken) { _, _ in
            composerFocused = true
            FieldCaret.moveToEnd()
        }
        .focusOnNewAttachment(count: viewModel.pendingImages.count + viewModel.pendingDocuments.count) {
            composerFocused = true
            FieldCaret.moveToEnd()
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    // Top strips: on the left the window buttons and the two round ones, on the right the section's own controls.

    private var sidebarStrip: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 72, height: 1)  // the red/yellow/green buttons live here
            Spacer(minLength: 0)
            roundButton("square.and.pencil", String(localized: "New Chat")) { viewModel.newChat() }
                .keyboardShortcut("n", modifiers: .command)
                .keyboardShortcut("n", modifiers: .command)
            roundButton("sidebar.left", String(localized: "Hide the chat list")) { showsSidebar.toggle() }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    @ViewBuilder private var detailStrip: some View {
        HStack(spacing: 10) {
            if !showsSidebar {
                Color.clear.frame(width: 72, height: 1)
                roundButton("sidebar.left", String(localized: "Show the chat list")) { showsSidebar.toggle() }
            }
            if container.section == .models, let models {
                ModelLibraryHeader(viewModel: models)
            } else {
                Text(verbatim: windowTitle).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    /// Round glass buttons of the size the system apps use in this strip (Mail, Xcode).
    private func roundButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .regular)).frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Drag the line between the columns to set the list's width; it is remembered.
    private var sidebarHandle: some View {
        // A hairline translucent line that is also the grip for the sidebar width: the drag area around it is wide,
        // the line itself is as thin as possible. The window is transparent behind its content, hence the material.
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .background(SidebarBackground())
            .overlay(
                Rectangle().fill(.clear).frame(width: 10).contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        // Measured in the window, not in the handle: the handle moves with every change, so its own
                        // coordinate space would feed the movement back into the next translation and the drag jitters.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = sidebarDragStart ?? sidebarWidth
                                sidebarDragStart = start
                                sidebarWidth = (min(max(start + value.translation.width, 200), 420)).rounded()
                            }
                            .onEnded { _ in
                                sidebarDragStart = nil
                                container.settings.sidebarWidth = Double(sidebarWidth)
                            })
            )
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailStrip
            switch container.section {
            case .models: if let models { ModelLibraryView(viewModel: models) }
            case .settings: SettingsSectionView()
            case .chat: detail
            }
        }
        // The window itself is transparent for the sidebar's sake, so this column brings its own reading background.
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var windowTitle: String {
        if container.section == .models { return String(localized: "Models") }
        if container.section == .settings { return String(localized: "Settings") }
        return viewModel.selectedChat.map { $0.title.isEmpty ? String(localized: "Untitled chat") : $0.title }
            ?? String(localized: "New Chat")
    }

    // Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarStrip
            chatSearchField
            chatList
        }
        // The sidebar material of macOS: translucent, vibrant, and it lets the desktop through like the stock apps.
        .background(SidebarBackground())
    }

    private var chatSearchField: some View {
        @Bindable var viewModel = viewModel
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
            TextField(String(localized: "Search chats"), text: $viewModel.filter).textFieldStyle(.plain)
            if !viewModel.filter.isEmpty {
                Button {
                    viewModel.filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear"))
            }
        }
        .searchCapsule()
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var chatList: some View {
        @Bindable var container = container
        // No `List` selection: it was cleared by a click on the empty area below the rows and fought back into place
        // (blue, then grey), and its highlight faded whenever the composer held the keyboard. A click opens the chat,
        // and the open chat is tinted like the chosen section below, whatever has the focus.
        return List {
            ForEach(groupedChats, id: \.0) { section, chats in
                Section(section) {
                    ForEach(chats) { chat in
                        let isChosen = chat.id == viewModel.selectedChatID
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                // Titles come from the first question: three lines tell chats apart better than one.
                                Text(chat.title.isEmpty ? String(localized: "Untitled chat") : chat.title).lineLimit(3)
                                // A plain date, not a ticking relative timer: a running clock read as "still generating".
                                Text(chat.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                    .foregroundStyle(isChosen ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                            }
                            Spacer(minLength: 4)
                            if viewModel.generatingChatIDs.contains(chat.id) {
                                ProgressView().controlSize(.small)
                                    .help(String(localized: "The model is answering in this chat"))
                            }
                            Button {
                                viewModel.delete(chat)
                            } label: {
                                Image(systemName: "trash").contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(isChosen ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                            .help(String(localized: "Delete Chat"))
                        }
                        .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.selectedChatID = chat.id }
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isChosen ? Color.accentColor : .clear)
                                .padding(.horizontal, 8).padding(.vertical, 1))
                        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
                        // Rows run one under another; the only lines in the list are the ones between dates.
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button(String(localized: "Rename…")) {
                                renaming = chat; renameText = chat.title
                            }
                            Button(String(localized: "Open in Panel")) { container.setActiveChat(chat.id) }
                            Button(String(localized: "System Prompt…")) {
                                container.section = .chat
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
        // A list draws an opaque background of its own, which hid the sidebar material underneath.
        .scrollContentBackground(.hidden)
        // Picking a chat always leaves the model library.
        .onChange(of: viewModel.selectedChatID) { _, id in if id != nil { container.section = .chat } }
        .safeAreaInset(edge: .bottom, spacing: 0) { modelsEntry }
        .alert(String(localized: "Rename Chat"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(String(localized: "Title"), text: $renameText)
            Button(String(localized: "Save")) {
                if let c = renaming { viewModel.rename(c, to: renameText) }; renaming = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { renaming = nil }
        }
    }

    /// Pinned at the very bottom of the sidebar (a safe-area inset, so the list stays the sidebar column itself):
    /// the two permanent sections of the window, settings above the model library, as Liquid Glass capsules that the
    /// list scrolls under.
    private var modelsEntry: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 6) {
                sectionEntry(.settings, title: String(localized: "Settings"), symbol: "gearshape")
                sectionEntry(.models, title: String(localized: "Models"), symbol: "square.stack.3d.up")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func sectionEntry(_ section: AppContainer.Section, title: String, symbol: String) -> some View {
        let isChosen = container.section == section
        return Button {
            container.section = section
            viewModel.selectedChatID = nil
        } label: {
            Label(title, systemImage: symbol)
                // Heavier than a chat row: these are the sidebar's permanent sections, not items of the list.
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).frame(height: 34)
                .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // The chosen section is glass tinted with the accent colour, the other one plain glass.
        .glassEffect(isChosen ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Capsule())
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

    // Detail: centered column, user bubbles on the right, plain assistant text, rounded composer

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
        // From all the messages: the maps ride on the tool results, which the feed itself does not show.
        let maps = TranscriptMaps.byAnswer(viewModel.messages)
        return ScrollView {
            // Not lazy: a lazy stack guessed the heights of rows it had not drawn yet, so the scroll jumped while an
            // answer streamed, rows stayed blank until another chat was opened and a reused row could draw flipped.
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { position, m in
                    TranscriptRow(
                        message: m, position: position, context: visible,
                        isStreamedPlaceholder: isStreamedPlaceholder(m),
                        thoughtSeconds: viewModel.thoughtSeconds[m.id]
                    ) { message, summary in
                        ChatMessageView(
                            message: message, summary: summary, maps: maps[message.id] ?? [],
                            onRegenerate: message.id == visible.last?.id && message.role == .assistant && !viewModel.isGenerating
                                && !viewModel.stream.isGenerating
                                ? { viewModel.regenerate() } : nil)
                    }
                }
                TranscriptTail(
                    progress: viewModel.progress, engineState: viewModel.engineState,
                    errorMessage: viewModel.errorMessage
                ) {
                    // While the model's thinking is shown, the raw stream goes in and the view splits it.
                    let thinkingShown = viewModel.activeModel.map { container.showsReasoning(modelID: $0.id) } ?? false
                    if !viewModel.visibleStreamingText.isEmpty || (thinkingShown && !viewModel.streamingText.isEmpty) {
                        ChatMessageView(
                            message: Message(
                                chatID: UUID(), role: .assistant,
                                text: thinkingShown ? viewModel.streamingText : viewModel.visibleStreamingText, isPartial: true,
                                modelID: thinkingShown ? viewModel.activeModel?.id : nil),
                            onRegenerate: nil
                        )
                        .id("streaming")
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Growing text, the finished reply replacing the streamed one and the queue taking height are all followed
        // there, and only while the user has not scrolled up to read.
        .followsTranscriptEnd(jumpOn: viewModel.transcriptToken)
    }

    /// The stored copy of the reply being written: the streamed text stands for it, otherwise it shows as a stray "…".
    private func isStreamedPlaceholder(_ message: Message) -> Bool {
        viewModel.streamsHere && message.id == viewModel.messages.last?.id && message.role == .assistant && message.toolCalls.isEmpty
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
                .font(.system(size: scaledText))
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
                if container.settings.voiceInputEnabled {
                    VoiceInputButton(text: $viewModel.input, disabled: viewModel.isGenerating) { viewModel.send() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
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
                    // No spinner here: the transcript above already shows the reply being written.
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
        .glassCard(radius: 22)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .attachmentDrop(
            onFile: { viewModel.attach(fileURL: $0) },
            onWeb: { viewModel.attach(webURL: $0) },
            onImage: { viewModel.attach(image: $0) })
    }

    private var pendingAttachments: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.pendingImages) { img in
                AttachmentThumbnail(image: img.thumbnail, side: 48)
            }
            ForEach(viewModel.pendingDocuments, id: \.name) { doc in
                DocumentChip(name: doc.name)
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
        CheckedMenu(
            items: container.models,
            isChosen: { $0.id == viewModel.activeModel?.id },
            choose: { viewModel.setModel($0) },
            isEnabled: { container.isAvailable($0) },
            row: { m in
                // A menu row takes one title and one icon: the model's icon, the toggle draws the check mark.
                Label {
                    // Just the name: whether the model understands pictures is written out in the models section.
                    Text(verbatim: m.name)
                } icon: {
                    modelImage(m)
                }
                .labelStyle(.titleAndIcon)  // menus on macOS 26+ drop item icons unless asked to show them
            },
            footer: {
                if container.models.isEmpty {
                    Button(String(localized: "Model Library…")) { WindowManager.shared.openModels() }
                }
            }
        ) {
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
            // The same compact form as the pace line under a reply, so 33k reads the same everywhere.
            Text(verbatim: ChatMessageView.contextLeft(limit - used))
                .font(.caption.monospacedDigit())
                .foregroundStyle(used > limit * 9 / 10 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .help(String(localized: "Context left for this chat, estimated"))
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        let documents = AttachableTypes.documents
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
/// Not private: the panel and the queued questions read their size from this view, so one answer size rules them all.
struct ChatMessageView: View {
    /// Follows the system text size (Accessibility → Display → Text size): 15 pt while it is at the default.
    @ScaledMetric(relativeTo: .body) private var scaledText: CGFloat = ChatMessageView.textSize
    /// Reading size of the transcript; the panel keeps the system 13 pt, the window is for longer reading.
    static let textSize: CGFloat = 15
    let message: Message
    /// What the tools and the thinking did on the way to this answer, one line above it.
    var summary: String?
    /// Routes and places the tools found on the way, drawn under the answer.
    var maps: [TranscriptMap] = []
    var onRegenerate: (() -> Void)?
    @Environment(AppContainer.self) private var container

    /// Reasoning channels and tool syntax are the model talking to itself; only the answer is shown and copied.
    private var answer: String { AnswerText.visible(message.text) }

    /// The one line of numbers under a reply, in the panel as well: `21t/s (8.2k/33k)` — pace, tokens, and the limit
    /// they are measured against. Nothing is spelled out in words, so it reads the same in both languages.
    /// `nonisolated`: plain arithmetic over strings, called from wherever a count is shown — the view's own
    /// main-actor isolation would otherwise trap when it is used off the main thread.
    /// The units are localized: the Russian transcript reads т/с, к and М.
    nonisolated static let perSecond = String(localized: "t/s", comment: "tokens per second, after the number")
    nonisolated static let thousands = String(localized: "k", comment: "thousands suffix of a token count")
    nonisolated static let millions = String(localized: "M", comment: "millions suffix of a token count")

    nonisolated static func pace(tokensPerSecond: Double?, tokens: Int?, limit: Int?) -> String? {
        var inner: String?
        if let tokens { inner = limit.map { "\(compact(tokens))/\(compact($0))" } ?? compact(tokens) }
        switch (tokensPerSecond, inner) {
        case (let speed?, let inner?): return "\(Int(speed))\(perSecond) (\(inner))"
        case (let speed?, nil): return "\(Int(speed))\(perSecond)"
        case (nil, let inner?): return inner
        case (nil, nil): return nil
        }
    }

    /// What is left of the context window: `≈31.8k (ctx)`, the window and the panel alike. No words, like the pace
    /// line, so it reads the same in both languages; the tooltip says it is what is left.
    nonisolated static func contextLeft(_ tokens: Int) -> String { "≈\(compact(tokens)) (ctx)" }

    /// Token counts are read at a glance, not added up: 1 234 → 1.2k, 32 768 → 33k, 1 200 000 → 1.2M.
    nonisolated static func compact(_ value: Int) -> String {
        switch value {
        case ..<1000: "\(value)"
        case ..<1_000_000:
            Double(value) / 1000 < 10
                ? String(format: "%.1f", Double(value) / 1000) + thousands : "\(Int((Double(value) / 1000).rounded()))\(thousands)"
        default:
            Double(value) / 1_000_000 < 10
                ? String(format: "%.1f", Double(value) / 1_000_000) + millions
                : "\(Int((Double(value) / 1_000_000).rounded()))\(millions)"
        }
    }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    AttachmentStrip(attachments: message.attachments)
                    if !message.text.isEmpty {
                        Text(message.text).textSelection(.enabled).font(.system(size: scaledText))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let summary { ProgressSummaryLine(text: summary) }
                ReasoningBlock(message: message, fontSize: scaledText)
                // A reply that asked for tools has no answer of its own: its text is a preamble or echoed results.
                if message.toolCalls.isEmpty {
                    AnswerBody(message: message, answer: answer, fontSize: scaledText)
                    ForEach(Array(maps.enumerated()), id: \.offset) { _, map in TranscriptMapView(map: map, height: 240) }
                }
                if !message.isPartial, message.toolCalls.isEmpty {
                    HStack(spacing: 12) {
                        CopyButton(text: answer)
                        if let onRegenerate {
                            Button(action: onRegenerate) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help(String(localized: "Regenerate"))
                        }
                        // The count is read against its limit, so a reply cut short says what it ran into.
                        let limit = message.modelID.flatMap { container.replyLimit(forModel: $0) }
                        let atLimit = (message.completionTokens ?? 0) >= (limit ?? .max)
                        if let pace = Self.pace(tokensPerSecond: message.tokensPerSecond, tokens: message.completionTokens, limit: limit) {
                            PaceText(pace: pace, atLimit: atLimit)
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// SidebarBackground

/// The system's sidebar material; SwiftUI's materials do not include the vibrant, behind-window variant the stock apps use.
private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
