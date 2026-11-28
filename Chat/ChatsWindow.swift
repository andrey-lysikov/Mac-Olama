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

    // Returns the keyboard to the composer (after the file dialog, an attachment, etc.).
    func focusComposer() { focusToken += 1 }
    var selectedChatID: UUID? {
        didSet {
            container.windowChatID = selectedChatID
            stream.display(chatID: selectedChatID)
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

    var quotaBlocked: Bool { activeModel.map { container.isQuotaExhausted($0) } ?? false }
    private(set) var compacting = false

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
    // Messages do not change on chat-level updates; reloading every chat's history each time
    // a title or a token count is written stalls the window after every reply.
    @ObservationIgnored private var answerStartsLoadedAt = ContinuousClock.now

    private func loadAnswerStarts(force: Bool = false) async {
        // Cheap path: once a minute is plenty for sidebar previews.
        guard force || ContinuousClock.now - answerStartsLoadedAt >= .seconds(60) else { return }
        answerStartsLoadedAt = .now
        for chat in chats {
            guard let messages = try? await container.chatStore.messages(chatID: chat.id) else { continue }
            let answer = messages.lazy.filter { $0.role == .assistant && !$0.isPartial }.map { AnswerText.visible($0.text) }
                .reversed().first { !$0.isEmpty }
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
        await stream.refreshContext(chatID: id)
        loadedChatID = id
        let wasRemote = remoteGenerating
        remoteGenerating = await container.conversation.isGenerating(chatID: id) && stream.streamingChatID != id
        // A reply that ran on another surface just ended: questions queued here may go out now.
        if wasRemote, !remoteGenerating { stream.drainQueue() }
        if opened { transcriptToken += 1 }
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
                await self.loadMessagesThrottled()
            })
    }

    private(set) var generatingChatIDs: Set<UUID> = []
    @ObservationIgnored private var generatingPoll: Task<Void, Never>?
    // Remote generation persists ~4×/s; reloading the whole chat that often stalls scrolling.
    @ObservationIgnored private var lastStoreReload = ContinuousClock.now

    private func refreshGeneratingChats() async {
        let ids = await container.conversation.generatingChatIDs
        // Between "the reply ended" and "the next queued question reached the engine" the service
        // reports nothing running; queued questions and local stream tasks keep the spinner
        // honest through that gap (a dequeued question is no longer in queuedQuestions).
        let active = ids
            .union(stream.queuedQuestions.compactMap(\.chatID))
            .union(stream.locallyActiveChatIDs)
        let finished = generatingChatIDs.subtracting(active)
        if active != generatingChatIDs { generatingChatIDs = active }
        // A reply just ended elsewhere: refresh its sidebar preview now, not on the minute mark.
        if !finished.isEmpty {
            for chatID in finished { await refreshAnswerStart(chatID: chatID) }
        }
        guard !active.isEmpty, generatingPoll == nil else { return }
        generatingPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let ids = await self.container.conversation.generatingChatIDs
                let active = ids
                    .union(self.stream.queuedQuestions.compactMap(\.chatID))
                    .union(self.stream.locallyActiveChatIDs)
                if active != self.generatingChatIDs { self.generatingChatIDs = active }
                if active.isEmpty {
                    await self.reload()
                    break
                }
            }
            self?.generatingPoll = nil
        }
    }

    // Throttled reload for a chat another surface is writing: two hertz is plenty for a watcher.
    private func loadMessagesThrottled() async {
        guard ContinuousClock.now - lastStoreReload >= .milliseconds(500) else { return }
        lastStoreReload = .now
        await loadMessages()
    }

    // One chat's sidebar preview, refreshed right after its reply ended.
    private func refreshAnswerStart(chatID: UUID) async {
        guard let messages = try? await container.chatStore.messages(chatID: chatID) else { return }
        let answer = messages.lazy.filter { $0.role == .assistant && !$0.isPartial }.map { AnswerText.visible($0.text) }
            .reversed().first { !$0.isEmpty }
        guard let answer else { return }
        let words = answer.prefix(400).replacing(/[#*`>|_~]+/, with: " ").split(whereSeparator: \.isWhitespace)
        answerStarts[chatID] = String(words.joined(separator: " ").prefix(160))
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
        container.chooseModel(model, chatID: selectedChatID)
    }

    // Context

    var contextLimit: Int? { activeModel.flatMap { container.contextTokens(for: $0) } }

    var contextUsed: Int { stream.contextUsed(chat: selectedChat, model: activeModel) }

    // Messages

    func send() {
        guard !quotaBlocked, !compacting else { return }
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

    func compact() {
        guard let chatID = selectedChatID, !isGenerating, !compacting else { return }
        compacting = true
        Task {
            defer { compacting = false }
            do {
                try await container.conversation.compact(chatID: chatID)
                await loadMessages()
            } catch {
                stream.errorMessage = ConversationService.describe(error)
            }
        }
    }

    func retryFailed() {
        // A failure before the run started already returned the question to the composer.
        if stream.messages.last?.role == .assistant { regenerate() } else if !input.isEmpty { send() }
    }

    func stop(chatID: UUID) {
        Task { await container.conversation.cancel(chatID: chatID) }
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
                            "The chat database is incompatible or damaged and has been reset (\(failure.message)). The old one was backed up.")
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
                .buttonStyle(.glass)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.12))
    }
}

private struct ChatActivityIcon: View {
    let isAnswering: Bool
    let isCoding: Bool
    let isChosen: Bool
    let onStop: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isAnswering, hovering {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Stop Generation"))
            } else if isAnswering {
                // A custom spinner: ProgressView stops animating when nothing else redraws,
                // which is exactly what a long thinking pause looks like.
                Spinner(color: isChosen ? .white : .accentColor, still: reduceMotion)
            } else {
                Image(systemName: isCoding ? "chevron.left.forwardslash.chevron.right" : "bubble.left")
                    .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
            }
        }
        .frame(width: 20, height: 20)
        .font(.system(size: 16))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// Spinner

/// A spinning arc driven by a repeating Core Animation, so it keeps turning under load:
/// a TimelineView's schedule can stall while the window redraws for the streaming text.
private struct Spinner: View {
    var color: Color = .accentColor
    var still = false
    @State private var rotating = false

    var body: some View {
        if still {
            Circle().strokeBorder(color.opacity(0.4), lineWidth: 2).frame(width: 14, height: 14)
        } else {
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(rotating ? 360 : 0))
                .frame(width: 14, height: 14)
                .frame(width: 20, height: 20)
                .onAppear {
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { rotating = true }
                }
        }
    }
}

private struct ChatsSplitView: View {
    @Bindable var viewModel: ChatsViewModel
    @Environment(AppContainer.self) private var container
    @FocusState private var composerFocused: Bool
    @State private var models: DownloadViewModel?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var previewedImage: ConversationStreamCoordinator.PendingImage?
    @State private var previewedDocument: DocumentInput?

    var body: some View {
        // System sidebar window from AppKit, nothing hand-drawn.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: 150, ideal: min(max(CGFloat(container.settings.sidebarWidth), 150), 420), max: 420)
                // Restore and save the sidebar width.
                .background(
                    SidebarWidthKeeper(
                        initial: min(max(CGFloat(container.settings.sidebarWidth), 150), 420),
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
            case .cloud(let provider): CloudSectionView(provider: provider)
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
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .scrollEdgeEffectHidden(true, for: .top)
    }

    private var windowTitle: String {
        if let provider = container.section.cloudProvider { return provider.title }
        if container.section == .models { return String(localized: "Local Models") }
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
        // The bottom block reserves its own space (no bar edge), so the models divider
        // below stays the single full-width line.
        .safeAreaInset(edge: .bottom, spacing: 0) { modelsEntry }
        // Scroll the open chat's row into view minimally.
        .onChange(of: viewModel.selectedChatID, initial: true) { _, _ in reveal(viewModel.selectedChatID, with: proxy) }
        .onChange(of: viewModel.focusToken) { _, _ in reveal(viewModel.selectedChatID, with: proxy) }
        }
    }

    private func chatRow(_ chat: Chat, isChosen: Bool) -> some View {
        let isAnswering = viewModel.generatingChatIDs.contains(chat.id)
        let isCoding = container.settings.chatProjectPaths[chat.id.uuidString] != nil
        return HStack(alignment: .top, spacing: 6) {
            ChatActivityIcon(
                isAnswering: isAnswering, isCoding: isCoding, isChosen: isChosen,
                onStop: { viewModel.stop(chatID: chat.id) })
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                // Title from the first question, followed by the answer's first words.
                let title = Text(Hyphenation.soft(chat.title.isEmpty ? String(localized: "Untitled chat") : chat.title))
                let answer = Text(viewModel.answerStarts[chat.id].map { "  " + Hyphenation.soft($0) } ?? "")
                    .foregroundStyle(isChosen ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
                Text("\(title)\(answer)")
                    .font(.system(size: 12)).lineLimit(4)
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
        // Sources the user can actually work with: signed-in clouds and installed local models.
        let connectedProviders = CloudProvider.allCases.filter { container.cloudStore(for: $0).isSignedIn }
        let hasLocal = container.models.contains { !$0.source.isCloud }
        let anyConnected = !connectedProviders.isEmpty || hasLocal
        // With nothing connected the full list is the only way in, so it always shows.
        let expanded = container.settings.sidebarModelsExpanded || !anyConnected || chosenModelSectionIsHidden(
            connectedProviders: connectedProviders, hasLocal: hasLocal)
        return VStack(spacing: 2) {
            modelsDivider(expandable: anyConnected, expanded: expanded)
            if expanded {
                ForEach(CloudProvider.allCases) { provider in
                    sectionEntry(.cloud(provider), title: provider.title, provider: provider)
                }
                sectionEntry(.models, title: String(localized: "Local LLMs"), symbol: "cpu")
            } else {
                ForEach(connectedProviders) { provider in
                    sectionEntry(.cloud(provider), title: provider.title, provider: provider)
                }
                if hasLocal {
                    sectionEntry(.models, title: String(localized: "Local LLMs"), symbol: "cpu")
                }
            }
            Divider().padding(.vertical, 6)
            sectionEntry(.settings, title: String(localized: "Settings"), symbol: "gearshape")
            sectionEntry(.about, title: String(localized: "About"), symbol: "info.circle")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    // The chosen section is not listed while the block is folded: unfold so the selection stays visible.
    private func chosenModelSectionIsHidden(connectedProviders: [CloudProvider], hasLocal: Bool) -> Bool {
        switch container.section {
        case .cloud(let provider): !connectedProviders.contains(provider)
        case .models: !hasLocal
        default: false
        }
    }

    // A plain divider that doubles as the models list toggle: the chevron folds and unfolds it.
    private func modelsDivider(expandable: Bool, expanded: Bool) -> some View {
        Button {
            guard expandable else { return }
            container.settings.sidebarModelsExpanded = !expanded
        } label: {
            HStack(spacing: 6) {
                if expandable {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                // The line runs the full width of the sidebar.
                Rectangle().fill(.quaternary).frame(height: 1)
            }
            .padding(.leading, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!expandable)
        .accessibilityLabel(String(localized: "Models"))
    }

    private func sectionEntry(
        _ section: AppContainer.Section, title: String, symbol: String? = nil, provider: CloudProvider? = nil, prominent: Bool = true
    ) -> some View {
        let isChosen = container.section == section
        return Button {
            container.section = section
            viewModel.selectedChatID = nil
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let provider, let image = ModelIcons.shared.providerImage(provider, size: 18) {
                        Image(nsImage: image).resizable().interpolation(.high)
                    } else {
                        Image(systemName: symbol ?? "questionmark")
                            .font(.system(size: 14))
                            .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                    }
                }
                .frame(width: 20, height: 20)
                Text(title)
                    .font(.system(size: 14, weight: prominent ? .bold : .regular))
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
    @State private var historyLimit = 40

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
                Text(String(localized: "Loading…"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.messages.isEmpty && !viewModel.isGenerating && viewModel.errorMessage == nil {
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
        // Only the tail is rendered; scrolling to the top pulls in older messages.
        let shown = visibleMessages.suffix(historyLimit)
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { position, m in
                    // The summary replaces the older history for the model; a divider marks the cut for the reader.
                    if let cut = viewModel.selectedChat?.compactedAt,
                        m.id == visibleMessages.first(where: { $0.createdAt > cut })?.id {
                        CompactionDivider()
                    }
                    TranscriptRow(
                        message: m, position: position, context: Array(shown),
                        isStreamedPlaceholder: isStreamedPlaceholder(m),
                        thoughtSeconds: viewModel.thoughtSeconds[m.id]
                    ) { message, summary in
                        ChatMessageView(
                            message: message, summary: summary, maps: transcriptMaps[message.id] ?? [],
                            onRegenerate: message.id == visibleMessages.last?.id && message.role == .assistant && !viewModel.isGenerating
                                && !viewModel.stream.isGenerating
                                ? { viewModel.regenerate() } : nil)
                    }
                }
                // Its own view: streaming ticks update the tail, not this message list.
                ChatStreamTail(viewModel: viewModel)
            }
            // Top padding matching the sides and bottom.
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollTargetLayout()
        }
        // Follow the end while the user has not scrolled up.
        .followsTranscriptEnd(jumpOn: viewModel.transcriptToken) {
            guard historyLimit < visibleMessages.count else { return }
            // Keep the message that was on screen in place after older ones arrive above it.
            let anchor = shown.first?.id
            historyLimit += 40
            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
        }
        .onChange(of: viewModel.selectedChatID) { _, _ in historyLimit = 40 }
        }
        .onAppear { rebuildDerived() }
        .onChange(of: viewModel.messages) { _, _ in rebuildDerived() }
    }

    // Derived once per `messages` change; streaming ticks must not recompute them.
    @State private var visibleMessages: [Message] = []
    @State private var transcriptMaps: [UUID: [TranscriptMap]] = [:]

    private func rebuildDerived() {
        visibleMessages = viewModel.messages.filter { $0.role == .user || $0.role == .assistant || ToolApprovalRecord.isApproval($0) }
        transcriptMaps = TranscriptMaps.byAnswer(viewModel.messages)
    }

    private func isStreamedPlaceholder(_ message: Message) -> Bool {
        viewModel.streamsHere && message.id == viewModel.messages.last?.id && message.role == .assistant && message.toolCalls.isEmpty
    }

    // Composer: the same single-row layout as the quick panel.

    private var composer: some View {
        VStack(spacing: 0) {
            if !viewModel.pendingImages.isEmpty || !viewModel.pendingDocuments.isEmpty { pendingAttachments }
            HStack(alignment: .center, spacing: 10) {
                if container.settings.voiceInputEnabled {
                    VoiceInputButton(text: $viewModel.input, disabled: viewModel.isGenerating) { viewModel.send() }
                        .buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(.secondary)
                }
                Button(action: chooseFile) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
                TextField(String(localized: "Ask a question…"), text: $viewModel.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    // Follows ⌘+ / ⌘−, slightly smaller than the transcript as before (12 at the base 13).
                    .font(.system(size: max(container.settings.chatFontSize - 1, 8), weight: .regular))
                    .lineLimit(1...6)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .focused($composerFocused)
                    .disabled(viewModel.quotaBlocked)
                    .onSubmit { viewModel.send() }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        viewModel.send()
                        return .handled
                    }
                HStack(spacing: 12) {
                    modelPicker
                    ContextPermissionControl(
                        used: viewModel.contextUsed, limit: viewModel.contextLimit,
                        modelName: viewModel.activeModel?.name ?? String(localized: "No model"),
                        mode: viewModel.selectedChatID.map { container.permissionMode(for: $0) } ?? .ask,
                        compacting: viewModel.compacting,
                        canCompact: viewModel.selectedChatID != nil && !viewModel.isGenerating && !viewModel.messages.isEmpty
                            && !viewModel.compacting,
                        isEnabled: viewModel.selectedChatID != nil,
                        onMode: { mode in
                            guard let chatID = viewModel.selectedChatID else { return }
                            container.setPermissionMode(mode, for: chatID)
                        },
                        onCompact: viewModel.compact)
                }
                .buttonStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .fixedSize()
                .layoutPriority(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .glassCard(radius: 20)
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
                AttachmentThumbnail(
                    image: img.thumbnail, side: 48,
                    onPreview: { previewedImage = img },
                    onRemove: { viewModel.removeImage(img.id) }
                )
                .popover(isPresented: previewBinding(for: img)) {
                    ImagePreviewPopover(image: img.thumbnail, isPresented: previewBinding(for: img))
                }
            }
            ForEach(viewModel.pendingDocuments, id: \.name) { doc in
                DocumentChip(
                    name: doc.name,
                    onPreview: { previewedDocument = doc },
                    onRemove: { viewModel.removeDocument(doc.name) }
                )
                .popover(isPresented: previewBinding(for: doc)) {
                    DocumentPreviewPopover(document: doc, isPresented: previewBinding(for: doc))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    private func previewBinding(for image: ConversationStreamCoordinator.PendingImage) -> Binding<Bool> {
        Binding(
            get: { previewedImage?.id == image.id },
            set: { if !$0, previewedImage?.id == image.id { previewedImage = nil } })
    }

    private func previewBinding(for document: DocumentInput) -> Binding<Bool> {
        Binding(
            get: { previewedDocument?.name == document.name },
            set: { if !$0, previewedDocument?.name == document.name { previewedDocument = nil } })
    }

    private func modelImage(_ model: ModelDescriptor) -> Image {
        _ = ModelIcons.shared.revision
        if container.isQuotaExhausted(model) { return Image(systemName: "exclamationmark.triangle") }
        return ModelIcons.shared.menuImage(for: model, size: 16).map { Image(nsImage: $0) } ?? Image(systemName: model.source.symbol)
    }

    private func compactName(_ model: ModelDescriptor) -> String {
        func isSuffix(_ part: Substring) -> Bool {
            let p = part.lowercased()
            if ["mlx", "gguf", "it", "instruct", "chat", "base"].contains(p) { return true }
            if p.hasPrefix("q"), p.dropFirst().first?.isNumber == true { return true }
            if p.hasSuffix("bit"), p.dropLast(3).allSatisfy(\.isNumber) { return true }
            for prefix in ["bf", "fp", "int", "iq"] where p.hasPrefix(prefix) {
                if p.dropFirst(prefix.count).allSatisfy(\.isNumber) { return true }
            }
            let size = p.hasPrefix("e") ? p.dropFirst() : p[...]
            if let last = size.last, last == "b" || last == "m" {
                let digits = size.dropLast()
                if !digits.isEmpty, digits.allSatisfy({ $0.isNumber || $0 == "." }), digits.contains(where: \.isNumber) { return true }
            }
            return false
        }
        let parts = model.name.split(separator: "-", omittingEmptySubsequences: false)
        guard let cut = parts.firstIndex(where: isSuffix), cut > 0 else { return model.name }
        return parts[..<cut].joined(separator: "-")
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
                            .foregroundStyle(container.isQuotaExhausted(m) ? AnyShapeStyle(.red) : container.isAvailable(m) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .labelStyle(.titleAndIcon)  // macOS 26 menus hide icons otherwise
                }
                // A model whose window cannot hold this chat is not a choice for it.
                .disabled(
                    !container.isAvailable(m)
                        || (container.contextTokens(for: m).map { viewModel.contextUsed > $0 } ?? false))
            }
            if container.models.isEmpty {
                Button(String(localized: "Model Library…")) { WindowManager.shared.openModels() }
            }
        } label: {
            if let model = viewModel.activeModel {
                // An unreachable server greys the chat's model out, like its row in the list.
                Label {
                    Text(verbatim: compactName(model)).font(.callout).lineLimit(1).truncationMode(.middle)
                } icon: {
                    modelImage(model)
                        .foregroundStyle(container.isQuotaExhausted(model) ? AnyShapeStyle(.red) : container.isAvailable(model) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
                .foregroundStyle(container.isAvailable(model) ? .primary : .tertiary)  // VERIFY(mac): menu label keeps the style
            } else {
                Text(String(localized: "No model")).font(.callout)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 160)
        .fixedSize(horizontal: true, vertical: false)
        // Locked while this chat is answering.
        .disabled(viewModel.isGenerating)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        let documents = AttachableTypes.documents
        panel.allowedContentTypes = viewModel.activeModel?.kind == .vlm ? [.image] + documents : documents
        panel.allowsMultipleSelection = true
        panel.begin { [weak viewModel] response in
            guard response == .OK, let viewModel else { return }
            for url in panel.urls { viewModel.attach(fileURL: url) }
            // Hand the keyboard back to the composer once the dialog is gone,
            // so typing continues right where the attachments landed.
            viewModel.focusComposer()
        }
    }
}

// ChatStreamTail

/// The live part of the chats-window transcript: progress, approvals, errors and the streaming
/// reply. Streaming ticks invalidate this view alone — the message list above stays untouched.
private struct ChatStreamTail: View {
    @Bindable var viewModel: ChatsViewModel
    @Environment(AppContainer.self) private var container

    var body: some View {
        TranscriptTail(
            progress: viewModel.progress, engineState: viewModel.engineState,
            // A persisted failure shows here too, with the retry button.
            errorMessage: viewModel.errorMessage ?? viewModel.messages.last?.failure,
            approvals: NotificationService.shared.approvals(for: viewModel.selectedChatID),
            onRetry: { viewModel.retryFailed() }
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
}

// ChatMessageView

struct ChatMessageView: View {
    static let textSize: CGFloat = 13
    let message: Message
    var summary: String?
    var maps: [TranscriptMap] = []
    var onRegenerate: (() -> Void)?
    @Environment(AppContainer.self) private var container

    // ⌘+ / ⌘− change the setting; Observation re-renders every message at once.
    private var scaledText: CGFloat { container.settings.chatFontSize }

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
                // Keep the model's rationale visible when it precedes tool calls.
                if message.toolCalls.isEmpty || !answer.isEmpty {
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
                        }
                        // The count is read against its limit, so a reply cut short says what it ran into.
                        let limit = message.modelID.flatMap { container.replyLimit(forModel: $0) }
                        let atLimit = (message.completionTokens ?? 0) >= (limit ?? .max)
                        if let pace = Self.pace(tokensPerSecond: message.tokensPerSecond, tokens: message.completionTokens, limit: limit) {
                            PaceText(pace: pace, atLimit: atLimit)
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    TokenUsageView(message: message)
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
