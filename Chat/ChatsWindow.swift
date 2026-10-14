//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ChatsViewModel: ConversationStreamDelegate, ConversationStreamHosting {
    private let container: AppContainer
    let stream: ConversationStreamCoordinator
    private(set) var chats: [Chat] = []
    private var remoteGenerating = false
    private(set) var transcriptToken = 0
    private(set) var focusToken = 0
    var selectedChatID: UUID? {
        didSet {
            container.windowChatID = selectedChatID
            guard selectedChatID != oldValue else { return }
            // The chat open here is the one the panel opens too: one chat for both.
            if let selectedChatID { container.setActiveChat(selectedChatID) }
            Task { await loadMessages() }
        }
    }
    var filter = "" {
        didSet { if filter != oldValue { searchContents() } }
    }
    private var contentMatches: Set<UUID> = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    // `nonisolated(unsafe)` so `deinit` can tear them down.
    @ObservationIgnored nonisolated(unsafe) private var changesTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var pasteMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var activationObserver: Any?

    // Window-specific overrides of the shared coordinator state.
    var isGenerating: Bool { streamsIntoShownChat || remoteGenerating }
    var streamingText: String { streamsIntoShownChat ? stream.streamingText : "" }
    var visibleStreamingText: String { streamsIntoShownChat ? stream.visibleStreamingText : "" }
    var progress: GenerationProgress? {
        streamsIntoShownChat ? stream.progress : selectedChatID.flatMap { container.liveProgress[$0] }
    }
    var streamsHere: Bool { streamsIntoShownChat && stream.streamsHere }

    private var streamsIntoShownChat: Bool {
        stream.isGenerating && (stream.streamingChatID == nil || stream.streamingChatID == selectedChatID)
    }

    var selectedChat: Chat? { chats.first { $0.id == selectedChatID } }
    var engineState: EngineState { container.engineState }
    var filteredChats: [Chat] {
        filter.isEmpty
            ? chats
            : chats.filter { $0.title.localizedCaseInsensitiveContains(filter) || contentMatches.contains($0.id) }
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
        // Do not leak monitors if the model is recreated.
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
        // Queued questions go to the chat they were asked in.
        if let chatID = question.chatID {
            if chatID != selectedChatID { selectedChatID = chatID }
            return chatID
        }
        if let chatID = selectedChatID { return chatID }
        // First question: create and select the chat first.
        container.section = .chat
        guard let chat = try? await container.conversation.newChat(origin: .window) else { return nil }
        await reload()
        selectedChatID = chat.id
        container.setActiveChat(chat.id)
        return chat.id
    }

    func modelIDForSending() -> String? { activeModel?.id }

    func displaysChat(_ chatID: UUID) -> Bool { selectedChatID == chatID }

    var acceptsImages: Bool { activeModel?.kind == .vlm }

    // Data

    func reload() async {
        chats = (try? await container.chatStore.allChats(includeArchived: false)) ?? []
        if let id = selectedChatID, !chats.contains(where: { $0.id == id }) { selectedChatID = chats.first?.id }
        if !filter.isEmpty { searchContents() }  // new chats and replies count too
        await loadAnswerStarts()
    }

    private(set) var answerStarts: [UUID: String] = [:]

    private func loadAnswerStarts() async {
        for chat in chats where answerStarts[chat.id] == nil {
            guard let messages = try? await container.chatStore.messages(chatID: chat.id) else { continue }
            let answer = messages.lazy.filter { $0.role == .assistant && !$0.isPartial }.map { AnswerText.visible($0.text) }
                .first { !$0.isEmpty }
            guard let answer else { continue }
            // One line of plain words: the row has no room for Markdown's marks.
            let words = answer.prefix(400).replacing(/[#*`>|_~]+/, with: " ").split(whereSeparator: \.isWhitespace)
            answerStarts[chat.id] = String(words.joined(separator: " ").prefix(160))
        }
    }

    private func searchContents() {
        searchTask?.cancel()
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            contentMatches = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            let found = (try? await container.chatStore.chatIDs(matching: query)) ?? []
            guard !Task.isCancelled else { return }
            contentMatches = found
        }
    }

    private func loadMessages() async {
        guard let id = selectedChatID else {
            stream.setMessages([])
            loadedChatID = nil
            return
        }
        let loaded = await stream.fetchMessages(chatID: id)
        guard id == selectedChatID else { return }  // another chat was picked meanwhile
        // Same-chat reloads do not jump; a new chat does.
        let opened = loadedChatID != id
        stream.setMessages(loaded)
        loadedChatID = id
        if opened { upgradeShortTitle(chatID: id, messages: loaded) }
        let wasRemote = remoteGenerating
        remoteGenerating = await container.conversation.isGenerating(chatID: id) && stream.streamingChatID != id
        // A reply that ran on another surface just ended: questions queued here may go out now.
        if wasRemote, !remoteGenerating { stream.drainQueue() }
        if opened { transcriptToken += 1 }
    }

    private func upgradeShortTitle(chatID: UUID, messages: [Message]) {
        guard var chat = chats.first(where: { $0.id == chatID }), chat.title.hasSuffix("…"),
            let question = messages.first(where: { $0.role == .user })?.text
        else { return }
        let longer = ConversationService.makeTitle(from: question)
        guard longer.count > chat.title.count, longer.hasPrefix(chat.title.dropLast()) else { return }
        chat.title = longer
        if let i = chats.firstIndex(where: { $0.id == chatID }) { chats[i].title = longer }
        Task { try? await container.chatStore.update(chat) }
    }

    private(set) var loadedChatID: UUID?
    var isLoadingChat: Bool { selectedChatID != nil && loadedChatID != selectedChatID }

    private func observeWindowActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard WindowManager.shared.window(.chats)?.isKeyWindow == true else { return }
                self?.transcriptToken += 1
                self?.focusToken += 1
                Task { await self?.followActiveChat() }
            }
        }
    }

    private func followActiveChat() async {
        guard container.section == .chat, let id = container.settings.activeChatID, id != selectedChatID else { return }
        if !chats.contains(where: { $0.id == id }) { await reload() }
        if chats.contains(where: { $0.id == id }) { selectedChatID = id }
    }

    private func observe() {
        changesTask = stream.observeStoreChanges(
            onChats: { [weak self] in await self?.reload() },
            onMessages: { [weak self] chatID in
                await self?.refreshGeneratingChats()
                // Follow replies written elsewhere through the store.
                guard let self, chatID == self.selectedChatID, !self.streamsHere else { return }
                await self.loadMessages()
            })
    }

    private(set) var generatingChatIDs: Set<UUID> = []
    @ObservationIgnored private var generatingPoll: Task<Void, Never>?

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

    func setModel(_ model: ModelDescriptor) {
        // Shown at once; the store update follows.
        if let i = chats.firstIndex(where: { $0.id == selectedChatID }) { chats[i].modelID = model.id }
        container.chooseModel(model)
    }

    // Context

    var contextLimit: Int? { activeModel.flatMap { container.contextTokens(for: $0) } }

    var contextUsed: Int { stream.contextUsed(systemPrompt: selectedChat?.systemPrompt) }

    // Messages

    func send() {
        stream.send(chatID: selectedChatID, surfaceBusy: remoteGenerating)
        transcriptToken += 1
    }

    var queuedHere: [QueuedQuestion] { queuedQuestions.filter { $0.chatID == selectedChatID } }

    func regenerate() {
        // A new run would take over the window's stream while it still writes into another chat.
        guard let chatID = selectedChatID, !stream.isGenerating else { return }
        stream.regenerate(chatID: chatID)
        transcriptToken += 1
    }

    func stop() {
        // Stops the reply of the chat on screen.
        guard let id = streamsIntoShownChat ? stream.streamingChatID ?? selectedChatID : selectedChatID else { return }
        Task { await container.conversation.cancel(chatID: id) }
    }

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
    @ScaledMetric(relativeTo: .body) private var scaledText: CGFloat = ChatMessageView.textSize
    @Bindable var viewModel: ChatsViewModel
    @Environment(AppContainer.self) private var container
    @FocusState private var composerFocused: Bool
    @State private var models: DownloadViewModel?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        // System sidebar window from AppKit, nothing hand-drawn.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: 250, ideal: min(max(CGFloat(container.settings.sidebarWidth), 250), 420), max: 420)
                // Restore and save the sidebar width.
                .background(
                    SidebarWidthKeeper(
                        initial: min(max(CGFloat(container.settings.sidebarWidth), 250), 420),
                        save: { width in
                            if Double(width) != container.settings.sidebarWidth { container.settings.sidebarWidth = Double(width) }
                        }))
                // New Chat button in the sidebar's toolbar area.
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
        } detail: {
            detailColumn
        }
        // The system search field at the top of the sidebar, as in Mail.
        .searchable(text: $viewModel.filter, placement: .sidebar, prompt: Text(String(localized: "Search chats")))
        .onAppear {
            if models == nil { models = DownloadViewModel(container: container) }
        }
        // "Open in Chats" from the panel selects that chat.
        .onChange(of: container.requestedWindowChatID, initial: true) { _, id in
            guard let id else { return }
            viewModel.selectedChatID = id
            container.requestedWindowChatID = nil
        }
        // Window title: chat title or section name.
        .onChange(of: windowTitle, initial: true) { _, title in WindowManager.shared.window(.chats)?.title = title }
        // Leaving the chat section clears the chat selection.
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

    private var detailColumn: some View {
        // Right column content by section.
        VStack(spacing: 0) {
            switch container.section {
            case .models:
                if let models {
                    ModelLibraryHeader(viewModel: models).padding(.horizontal, 12).padding(.vertical, 8)
                    ModelLibraryView(viewModel: models)
                }
            case .settings: SettingsSectionView()
            case .about: AboutSectionView()
            case .chat: detail
            }
        }
        // Content column extends to the window's top edge, no toolbar strip.
        .ignoresSafeArea(.container, edges: .top)
        // The reading background of the content column; the sidebar floats over the window's own.
        .background(Color(nsColor: .textBackgroundColor))
        // No toolbar title, background or scroll edge effect over the content.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .scrollEdgeEffectHidden(true, for: .top)
    }

    private var windowTitle: String {
        if container.section == .models { return String(localized: "Models") }
        if container.section == .settings { return String(localized: "Settings") }
        if container.section == .about { return String(localized: "About") }
        return viewModel.selectedChat.map { $0.title.isEmpty ? String(localized: "Untitled chat") : $0.title }
            ?? String(localized: "New Chat")
    }

    // Sidebar

    private var sidebar: some View {
        chatList
    }

    private var chatList: some View {
        @Bindable var container = container
        // Manual selection instead of `List` selection, which flickered and faded.
        return ScrollViewReader { proxy in
        List {
            ForEach(groupedChats, id: \.0) { section, chats in
                // Date sections fold, remembered per session.
                Section(isExpanded: expansion(of: section)) {
                    ForEach(chats) { chat in
                        let isChosen = chat.id == viewModel.selectedChatID
                        chatRow(chat, isChosen: isChosen)
                        .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.selectedChatID = chat.id }
                        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isChosen ? Color.accentColor : .clear))
                        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
                        // Rows run one under another; the only lines in the list are the ones between dates.
                        .listRowSeparator(.hidden)
                        // Swipe left to delete, as in Mail.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.delete(chat)
                            } label: {
                                Label(String(localized: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(section)
                }
            }
        }
        // Finder-style sidebar sections.
        .listStyle(.sidebar)
        // Picking a chat always leaves the model library.
        .onChange(of: viewModel.selectedChatID) { _, id in if id != nil { container.section = .chat } }
        // Hard edge so rows do not show through the pinned sections.
        .safeAreaBar(edge: .bottom, spacing: 0) { modelsEntry }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        // Scroll the open chat's row into view minimally.
        .onChange(of: viewModel.selectedChatID, initial: true) { _, _ in reveal(viewModel.selectedChatID, with: proxy) }
        .onChange(of: viewModel.focusToken) { _, _ in reveal(viewModel.selectedChatID, with: proxy) }
        }
    }

    private func chatRow(_ chat: Chat, isChosen: Bool) -> some View {
        let isAnswering = viewModel.generatingChatIDs.contains(chat.id)
        return HStack(alignment: .top, spacing: 6) {
            // While the model answers in the chat, a spinner stands in the bubble's place, at its size.
            Image(systemName: "bubble.left")
                .font(.system(size: 14))
                .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                .opacity(isAnswering ? 0 : 1)
                .overlay {
                    if isAnswering {
                        ProgressView().controlSize(.small).tint(isChosen ? .white : nil)
                            .help(String(localized: "The model is answering in this chat"))
                    }
                }
                // The bubble sits on the title's first line.
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                // Title from the first question, followed by the answer's first words.
                let title = Text(Hyphenation.soft(chat.title.isEmpty ? String(localized: "Untitled chat") : chat.title))
                let answer = Text(viewModel.answerStarts[chat.id].map { "  " + Hyphenation.soft($0) } ?? "")
                    .foregroundStyle(isChosen ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
                Text("\(title)\(answer)")
                    .font(.system(size: 14)).lineLimit(3)
                // Plain date, no ticking relative time.
                HStack(spacing: 4) {
                    Text(chat.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(verbatim: "·")
                    ChatExportLink(isChosen: isChosen) {
                        ChatExport.run(chat: chat, container: container, window: WindowManager.shared.window(.chats))
                    }
                }
                .font(.caption).lineLimit(1)
                .foregroundStyle(isChosen ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            // Title takes the full width.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reveal(_ chatID: UUID?, with proxy: ScrollViewProxy) {
        guard let chatID, let section = groupedChats.first(where: { $0.1.contains { $0.id == chatID } })?.0 else { return }
        collapsedSections.remove(section)
        // After the unfolded rows are laid out, or there is nothing to scroll to yet.
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(chatID) } }
    }

    private var modelsEntry: some View {
        VStack(spacing: 2) {
            sectionEntry(.models, title: String(localized: "Models"), symbol: "square.stack.3d.up")
            sectionEntry(.settings, title: String(localized: "Settings"), symbol: "gearshape")
            sectionEntry(.about, title: String(localized: "About"), symbol: "info.circle")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func sectionEntry(_ section: AppContainer.Section, title: String, symbol: String) -> some View {
        let isChosen = container.section == section
        return Button {
            container.section = section
            viewModel.selectedChatID = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 32)
            // Chosen like a chat row: the same accent-filled rounded rectangle.
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isChosen ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }

    @State private var collapsedSections: Set<String> = []

    private func expansion(of section: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(section) },
            set: { open in
                if open { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
            })
    }

    private var groupedChats: [(String, [Chat])] {
        let cal = Calendar.current
        var buckets: [(String, [Chat])] = []
        func bucket(_ c: Chat) -> String {
            if cal.isDateInToday(c.updatedAt) { return String(localized: "Today") }
            if cal.isDateInYesterday(c.updatedAt) { return String(localized: "Yesterday") }
            if let week = cal.date(byAdding: .day, value: -7, to: .now), c.updatedAt > week { return String(localized: "Previous 7 days") }
            if let month = cal.date(byAdding: .day, value: -30, to: .now), c.updatedAt > month {
                return String(localized: "Previous 30 days")
            }
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
        // The chat title is the window title, not a transcript line.
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.isLoadingChat {
                // Nothing, rather than the empty-chat prompt flashing before the history arrives.
                Spacer().frame(maxWidth: .infinity)
            } else if viewModel.messages.isEmpty && viewModel.streamingText.isEmpty && viewModel.errorMessage == nil {
                emptyState
            } else {
                transcript
            }
            // Queued questions pinned above the composer.
            if !viewModel.queuedHere.isEmpty {
                QueuedQuestionsView(questions: viewModel.queuedHere, onRemove: viewModel.removeQueued)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            composer
        }
    }

    // Nothing on the chat background: the composer below is the only call to action.
    private var emptyState: some View {
        Spacer().frame(maxWidth: .infinity)
    }

    private var transcript: some View {
        let visible = viewModel.messages.filter { $0.role == .user || $0.role == .assistant }
        // All messages: maps ride on hidden tool results.
        let maps = TranscriptMaps.byAnswer(viewModel.messages)
        return ScrollView {
            // Not lazy: lazy rows mismeasured and jumped while streaming.
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
            // Top padding matching the sides and bottom.
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Follow the end while the user has not scrolled up.
        .followsTranscriptEnd(jumpOn: viewModel.transcriptToken)
    }

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
                // Narrow window: drop the context estimate first.
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

    private func modelImage(_ model: ModelDescriptor) -> Image {
        _ = ModelIcons.shared.revision
        return ModelIcons.shared.menuImage(for: model, size: 16).map { Image(nsImage: $0) } ?? Image(systemName: model.source.symbol)
    }

    private var modelPicker: some View {
        // No check mark: the label already shows the model.
        Menu {
            ForEach(container.models, id: \.self) { m in
                Button {
                    viewModel.setModel(m)
                } label: {
                    // A menu row takes one title and one icon: the model's icon.
                    Label {
                        // Just the name.
                        Text(verbatim: m.name)
                    } icon: {
                        modelImage(m)
                    }
                    .labelStyle(.titleAndIcon)  // macOS 26 menus hide icons otherwise
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
        // Locked while this chat is answering.
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

struct ChatMessageView: View {
    @ScaledMetric(relativeTo: .body) private var scaledText: CGFloat = ChatMessageView.textSize
    static let textSize: CGFloat = 15
    let message: Message
    var summary: String?
    var maps: [TranscriptMap] = []
    var onRegenerate: (() -> Void)?
    @Environment(AppContainer.self) private var container

    private var answer: String { AnswerText.visible(message.text) }

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

    nonisolated static func contextLeft(_ tokens: Int) -> String { "≈\(compact(tokens))" }

    nonisolated static func compact(_ value: Int) -> String {
        switch value {
        case ..<1024: "\(value)"
        case ..<1048576:
            Double(value) / 1024 < 10
                ? String(format: "%.1f", Double(value) / 1024) + thousands : "\(Int((Double(value) / 1024).rounded()))\(thousands)"
        default:
            Double(value) / 1048576 < 10
                ? String(format: "%.1f", Double(value) / 1048576) + millions
                : "\(Int((Double(value) / 1048576).rounded()))\(millions)"
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
                // Tool-asking replies have no answer of their own.
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

// SidebarWidthKeeper

private struct SidebarWidthKeeper: NSViewRepresentable {
    let initial: CGFloat
    let save: (CGFloat) -> Void

    func makeNSView(context: Context) -> KeeperView { KeeperView(initial: initial, save: save) }

    func updateNSView(_ view: KeeperView, context: Context) { view.save = save }

    final class KeeperView: NSView {
        private let initial: CGFloat
        var save: (CGFloat) -> Void
        private weak var splitView: NSSplitView?
        private var observer: Any?
        private var pendingSave: Task<Void, Never>?

        init(initial: CGFloat, save: @escaping (CGFloat) -> Void) {
            self.initial = initial
            self.save = save
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
                return
            }
            guard splitView == nil else { return }
            // After the first layout pass, when the split view has a size.
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard splitView == nil, let split = findSplitView() else { return }
            splitView = split
            split.setPosition(initial, ofDividerAt: 0)
            // Added after restore so the initial width is not saved.
            observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let split = self.splitView, let sidebar = split.arrangedSubviews.first,
                        !split.isSubviewCollapsed(sidebar)
                    else { return }
                    let width = sidebar.frame.width.rounded()
                    guard (250...420).contains(width) else { return }
                    // Saved once the drag settles: every write wakes all the settings' observers.
                    self.pendingSave?.cancel()
                    self.pendingSave = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        self?.save(width)
                    }
                }
            }
        }

        private func findSplitView() -> NSSplitView? {
            var view = superview
            while let current = view {
                if let split = current as? NSSplitView, split.isVertical { return split }
                view = current.superview
            }
            func search(_ view: NSView) -> NSSplitView? {
                if let split = view as? NSSplitView, split.isVertical { return split }
                for sub in view.subviews { if let found = search(sub) { return found } }
                return nil
            }
            return window?.contentView.flatMap(search)
        }
    }
}

private struct ChatExportLink: View {
    let isChosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(String(localized: "Export…")).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The date's own colour, set here: a plain button would paint its words in the primary one.
        .foregroundStyle(colour)
        .onHover { hovering = $0 }
        .help(String(localized: "Export Chat…"))
    }

    private var colour: AnyShapeStyle {
        if isChosen { return AnyShapeStyle(.white.opacity(hovering ? 1 : 0.8)) }
        return hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
    }
}

@MainActor
enum Hyphenation {
    private static let english = Locale(identifier: "en_US") as CFLocale
    private static let cache = NSCache<NSString, NSString>()

    static func soft(_ text: String) -> String {
        if let known = cache.object(forKey: text as NSString) { return known as String }
        guard CFStringIsHyphenationAvailableForLocale(english) else { return text }
        let result = text.replacing(/[A-Za-z]{7,}/) { match in
            let word = NSMutableString(string: String(match.0))
            var index = word.length - 2
            // From the end backwards, so a mark put in does not move the places still to come.
            while index > 2 {
                let at = CFStringGetHyphenationLocationBeforeIndex(word, index, CFRange(location: 0, length: word.length), 0, english, nil)
                guard at != kCFNotFound, at >= 2, at < index else { break }
                word.insert("\u{00AD}", at: at)
                index = at
            }
            return word as String
        }
        cache.setObject(result as NSString, forKey: text as NSString)
        return result
    }
}
