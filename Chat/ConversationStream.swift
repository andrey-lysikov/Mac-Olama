//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI

@MainActor
protocol ConversationStreamDelegate: AnyObject {
    func chatIDForSending(question: QueuedQuestion) async -> UUID?
    func modelIDForSending() -> String?
    func displaysChat(_ chatID: UUID) -> Bool
    var acceptsImages: Bool { get }
}

@MainActor
protocol ConversationStreamHosting: AnyObject {
    var stream: ConversationStreamCoordinator { get }
}

extension ConversationStreamHosting {
    var messages: [Message] { stream.messages }
    var streamingText: String { stream.streamingText }
    var visibleStreamingText: String { stream.visibleStreamingText }
    var progress: GenerationProgress? { stream.progress }
    var queuedQuestions: [QueuedQuestion] { stream.queuedQuestions }
    var thoughtSeconds: [UUID: Int] { stream.thoughtSeconds }
    var isGenerating: Bool { stream.isGenerating }
    var errorMessage: String? { stream.errorMessage }
    var streamsHere: Bool { stream.streamsHere }
    var input: String {
        get { stream.input }
        set { stream.input = newValue }
    }
    var pendingImages: [ConversationStreamCoordinator.PendingImage] {
        get { stream.pendingImages }
        set { stream.pendingImages = newValue }
    }
    var pendingDocuments: [DocumentInput] {
        get { stream.pendingDocuments }
        set { stream.pendingDocuments = newValue }
    }

    func removeQueued(_ id: UUID) { stream.removeQueued(id) }
    func pasteFromClipboard() -> Bool { stream.pasteFromClipboard() }
    func attach(image: NSImage) { stream.attach(image: image) }
    func attach(fileURL: URL) { stream.attach(fileURL: fileURL) }
    func attach(webURL url: URL) { stream.attach(webURL: url) }
    func removeImage(_ id: UUID) { stream.removeImage(id) }
    func removeDocument(_ name: String) { stream.removeDocument(name) }
}

@MainActor
@Observable
final class ComposerDraft {
    var input = ""
    var images: [ConversationStreamCoordinator.PendingImage] = []
    var documents: [DocumentInput] = []
}

@MainActor
@Observable
final class ConversationStreamCoordinator {
    struct PendingImage: Identifiable, Equatable {
        let id = UUID()
        let data: Data
        let mimeType: String
        let thumbnail: NSImage
    }

    let container: AppContainer
    weak var delegate: (any ConversationStreamDelegate)?

    // Unsent draft shared by the panel and the chats window via the container.
    var input: String {
        get { container.draft.input }
        set { container.draft.input = newValue }
    }
    var pendingImages: [PendingImage] {
        get { container.draft.images }
        set { container.draft.images = newValue }
    }
    var pendingDocuments: [DocumentInput] {
        get { container.draft.documents }
        set { container.draft.documents = newValue }
    }
    private struct RunState {
        var streamingText = ""
        var unshownText = ""
        var unshownTokens = 0
        var lastShown = ContinuousClock.now
        var progress: GenerationProgress?
        var errorMessage: String?
        var answerStarted = false
    }

    private var runStates: [UUID: RunState] = [:]
    private var streamTasks: [UUID: Task<Void, Never>] = [:]
    private var startingChats: Set<UUID> = []
    private var startingNewChat = false
    private var displayedChatID: UUID?
    private var generalError: String?

    var errorMessage: String? {
        get { displayedChatID.flatMap { runStates[$0]?.errorMessage } ?? generalError }
        set {
            if let displayedChatID {
                runStates[displayedChatID, default: RunState()].errorMessage = newValue
            } else {
                generalError = newValue
            }
        }
    }
    private(set) var messages: [Message] = [] {
        didSet { contextBaseDirty = true }
    }
    var streamingText: String { displayedChatID.flatMap { runStates[$0]?.streamingText } ?? "" }
    var progress: GenerationProgress? { displayedChatID.flatMap { runStates[$0]?.progress } }
    private(set) var queuedQuestions: [QueuedQuestion] = []
    private(set) var thoughtSeconds: [UUID: Int] = [:]
    var isGenerating: Bool {
        startingNewChat || displayedChatID.map { startingChats.contains($0) || streamTasks[$0] != nil } ?? false
    }

    var streamsHere: Bool { progress != nil }
    var visibleStreamingText: String { AnswerText.visible(streamingText) }

    func display(chatID: UUID?) { displayedChatID = chatID }

    // A chat whose stream task is alive here: covers the whole consume(), including
    // the gap where the service has not registered the run yet.
    var locallyActiveChatIDs: Set<UUID> { Set(streamTasks.keys).union(startingChats) }

    private var contextChatID: UUID?
    private var codingContext: String?
    private var codingDynamicContext: String?

    // Token estimate cache: contextEstimate walks the whole history, so it must not run
    // on every keystroke. The draft's own tokens are estimated separately and added on top.
    @ObservationIgnored private var contextBaseChatID: UUID?
    @ObservationIgnored private var contextBaseValue = 0
    @ObservationIgnored private var contextBaseDirty = true

    func invalidateContextBase() { contextBaseDirty = true }

    func contextUsed(chat: Chat?, model: ModelDescriptor?) -> Int {
        let chatID = chat?.id
        if contextBaseDirty || contextBaseChatID != chatID {
            contextBaseChatID = chatID
            contextBaseValue = ConversationService.contextEstimate(
                chat: chat, history: messages, streamingText: "", input: "",
                toolSpecs: model?.supportsTools == true ? container.toolSpecs : [],
                codingContext: contextChatID == chatID ? codingContext : nil,
                preferredLanguage: container.settings.preferredLanguage,
                codingDynamicContext: contextChatID == chatID ? codingDynamicContext : nil)
            contextBaseDirty = false
        }
        return contextBaseValue + ConversationService.estimateTokens(streamingText + input)
    }

    func refreshContext(chatID: UUID?) async {
        contextChatID = chatID
        codingContext = nil
        codingDynamicContext = nil
        guard let chatID else { return }
        async let stable = container.conversation.codingContext(for: chatID)
        async let dynamic = container.conversation.codingDynamicContext(for: chatID)
        let (value, dynamicValue) = await (stable, dynamic)
        guard contextChatID == chatID else { return }
        codingContext = value
        codingDynamicContext = dynamicValue
        invalidateContextBase()
    }

    init(container: AppContainer) {
        self.container = container
    }

    // Transcript

    func setMessages(_ messages: [Message]) { self.messages = messages }

    func fetchMessages(chatID: UUID) async -> [Message] {
        (try? await container.chatStore.messages(chatID: chatID)) ?? []
    }

    func observeStoreChanges(
        onChats: (@MainActor () async -> Void)? = nil,
        onMessages: @escaping @MainActor (UUID) async -> Void,
        onChatDeleted: (@MainActor (UUID) -> Void)? = nil
    ) -> Task<Void, Never> {
        let changes = container.chatStore.changes
        return Task {
            for await change in changes {
                switch change {
                case .chatDeleted(let chatID):
                    onChatDeleted?(chatID)
                    await onChats?()
                case .chatInserted, .chatUpdated:
                    await onChats?()
                case .messageInserted(let chatID, _), .messageUpdated(let chatID, _), .messageDeleted(let chatID, _):
                    await onMessages(chatID)
                }
            }
        }
    }

    // Composer

    func send(chatID: UUID?, surfaceBusy: Bool = false) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty || !pendingDocuments.isEmpty else { return }
        let question = QueuedQuestion(
            chatID: chatID, modelID: delegate?.modelIDForSending(), text: text,
            images: pendingImages.map { ImageInput(data: $0.data, mimeType: $0.mimeType) },
            documents: pendingDocuments)
        input = ""
        pendingImages = []
        pendingDocuments = []
        if isGenerating || surfaceBusy { queuedQuestions.append(question) } else { ask(question) }
    }

    func removeQueued(_ id: UUID) {
        queuedQuestions.removeAll { $0.id == id }
    }

    func drainQueue() {
        guard let displayedChatID else { return }
        drainQueue(chatID: displayedChatID)
    }

    private func drainQueue(chatID: UUID) {
        guard streamTasks[chatID] == nil, !startingChats.contains(chatID), runStates[chatID]?.errorMessage == nil,
            let index = queuedQuestions.firstIndex(where: { $0.chatID == chatID })
        else { return }
        ask(queuedQuestions.remove(at: index))
    }

    func regenerate(chatID: UUID) {
        guard messages.last?.role == .assistant, let userIndex = messages.lastIndex(where: { $0.role == .user }) else { return }
        let tail = Array(messages[userIndex...])
        let user = messages[userIndex]
        Task {
            var images: [ImageInput] = []
            var documents: [DocumentInput] = []
            for attachment in user.attachments {
                let url = container.paths.attachments.appendingPathComponent(attachment.relativePath)
                // One unreadable file must not silently drop the question's other attachments.
                guard let data = try? Data(contentsOf: url) else { continue }
                switch attachment.kind {
                case .image:
                    images.append(ImageInput(data: data, mimeType: "image/png"))
                case .document:
                    documents.append(
                        DocumentInput(name: attachment.displayName ?? attachment.relativePath, text: String(decoding: data, as: UTF8.self)))
                }
            }
            for message in tail { try? await container.chatStore.deleteMessage(id: message.id) }
            ask(QueuedQuestion(chatID: chatID, modelID: delegate?.modelIDForSending(), text: user.text, images: images, documents: documents))
        }
    }

    func reset() {
        displayedChatID = nil
        input = ""
        messages = []
        generalError = nil
        pendingImages = []
        pendingDocuments = []
    }

    // Attachments

    func attach(image: NSImage) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        pendingImages.append(PendingImage(data: png, mimeType: "image/png", thumbnail: image))
    }

    func attach(fileURL: URL) {
        switch DocumentExtractor.extract(url: fileURL) {
        case .image(let image): attach(image: image)
        case .document(let document): pendingDocuments.append(document)
        case nil: errorMessage = String(localized: "Unsupported file: \(fileURL.lastPathComponent)")
        }
    }

    func attach(webURL url: URL) {
        Task {
            do {
                pendingDocuments.append(try await WebPageDocument.fetch(url))
            } catch {
                errorMessage = String(localized: "Could not load the page: \(url.absoluteString)")
            }
        }
    }

    func removeImage(_ id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    func removeDocument(_ name: String) {
        pendingDocuments.removeAll { $0.name == name }
    }

    // Long pastes become a document, as in other chat clients; short ones go into the field as usual.
    static let pastedTextThreshold = 150

    func pasteFromClipboard() -> Bool {
        switch PasteboardAttachments.read() {
        case .files(let urls): urls.forEach { attach(fileURL: $0) }
        case .webURL(let url): attach(webURL: url)
        case .image(let image):
            guard delegate?.acceptsImages == true else {
                errorMessage = String(localized: "This model does not accept images.")
                return true
            }
            attach(image: image)
        case .text(let text):
            guard text.count >= Self.pastedTextThreshold else { return false }
            pendingDocuments.append(DocumentInput(name: String(localized: "Pasted text"), text: text))
        case nil: return false
        }
        return true
    }

    // Run loop

    var streamingChatID: UUID? { displayedChatID.flatMap { streamTasks[$0] == nil ? nil : $0 } }

    private func publishProgress(chatID: UUID) {
        container.liveProgress[chatID] = runStates[chatID]?.progress
    }

    private func ask(_ question: QueuedQuestion) {
        if let chatID = question.chatID {
            startingChats.insert(chatID)
        } else {
            startingNewChat = true
        }
        Task {
            let resolved = await delegate?.chatIDForSending(question: question)
            if let chatID = question.chatID { startingChats.remove(chatID) }
            startingNewChat = false
            guard let chatID = resolved else {
                if let chatID = question.chatID { runStates[chatID, default: RunState()].errorMessage = generalError }
                restoreToComposer(question)
                return
            }
            start(question, chatID: chatID)
        }
    }

    private func start(_ question: QueuedQuestion, chatID: UUID) {
        guard streamTasks[chatID] == nil else {
            queuedQuestions.insert(question, at: 0)
            return
        }
        runStates[chatID] = RunState(progress: GenerationProgress())
        publishProgress(chatID: chatID)
        let task = Task { await consume(question, chatID: chatID) }
        streamTasks[chatID] = task
    }

    private func consume(_ question: QueuedQuestion, chatID: UUID) async {
        do {
            let stream = try await container.conversation.send(
                chatID: chatID, text: question.text, images: question.images, documents: question.documents,
                modelID: question.modelID ?? delegate?.modelIDForSending())
            for await event in stream {
                switch event {
                case .started:
                    await reloadIfDisplayed(chatID)
                case .token(let text):
                    runStates[chatID]?.unshownText += text
                    runStates[chatID]?.unshownTokens += 1
                    // Show whole lines, not words: an update per finished line is far cheaper
                    // than 30 per second. The time fallback keeps a long unbroken line moving.
                    let pending = runStates[chatID]?.unshownText ?? ""
                    let due = (runStates[chatID]?.lastShown.duration(to: .now) ?? .zero) >= .milliseconds(150)
                    if pending.hasSuffix("\n") || (due && !pending.isEmpty) { showUnshown(chatID: chatID) }
                case .generated(let count):
                    runStates[chatID]?.progress?.generated(count)
                    publishProgress(chatID: chatID)
                case .toolCallStarted(let call):
                    showUnshown(chatID: chatID)
                    // The call stays out of the transcript; whatever preceded it was a preamble, not the answer.
                    runStates[chatID]?.progress?.toolStarted(
                        AnswerText.activity(for: call, searchProvider: container.settings.searchProvider))
                    // The reply that preceded the calls is persisted by now. Load it into the
                    // transcript *before* clearing the streaming tail, so the text never blinks:
                    // in every frame it is visible in exactly one place.
                    await reloadIfDisplayed(chatID)
                    runStates[chatID]?.streamingText = ""
                    runStates[chatID]?.answerStarted = false
                    publishProgress(chatID: chatID)
                case .toolCallFinished(let call, let result):
                    runStates[chatID]?.progress?.toolFinished(detail: AnswerText.detail(for: call, result: result))
                    publishProgress(chatID: chatID)
                case .retrying:
                    dropUnshown(chatID: chatID)
                    runStates[chatID]?.streamingText = ""
                    runStates[chatID]?.answerStarted = false
                case .failed(let message):
                    showUnshown(chatID: chatID)
                    runStates[chatID]?.errorMessage = message
                case .finished(let message):
                    showUnshown(chatID: chatID)
                    runStates[chatID]?.progress?.endThinking()
                    thoughtSeconds[message.id] = runStates[chatID]?.progress?.reportedThoughtSeconds
                    container.answerFinished(message)
                }
            }
        } catch {
            runStates[chatID]?.errorMessage = ConversationService.describe(error)
            restoreToComposer(question, chatID: chatID)
        }
        streamTasks[chatID] = nil
        runStates[chatID]?.streamingText = ""
        dropUnshown(chatID: chatID)
        runStates[chatID]?.progress = nil
        runStates[chatID]?.answerStarted = false
        publishProgress(chatID: chatID)
        await reloadIfDisplayed(chatID)
        drainQueue(chatID: chatID)
    }

    private func showUnshown(chatID: UUID) {
        guard var state = runStates[chatID], state.unshownTokens > 0 else { return }
        state.streamingText += state.unshownText
        if !state.answerStarted { state.answerStarted = !AnswerText.visible(state.streamingText).isEmpty }
        for _ in 0..<state.unshownTokens { state.progress?.token(answerStarted: state.answerStarted) }
        state.unshownText = ""
        state.unshownTokens = 0
        state.lastShown = .now
        runStates[chatID] = state
        publishProgress(chatID: chatID)
    }

    private func dropUnshown(chatID: UUID) {
        runStates[chatID]?.unshownText = ""
        runStates[chatID]?.unshownTokens = 0
        runStates[chatID]?.lastShown = .now
    }

    private func reloadIfDisplayed(_ chatID: UUID) async {
        let loaded = await fetchMessages(chatID: chatID)
        guard delegate?.displaysChat(chatID) != false else { return }
        messages = loaded
        await refreshContext(chatID: chatID)
    }

    private func restoreToComposer(_ question: QueuedQuestion, chatID: UUID? = nil) {
        if let chatID, displayedChatID != chatID {
            queuedQuestions.insert(question, at: 0)
            return
        }
        guard question.chatID == nil || displayedChatID == question.chatID else {
            queuedQuestions.insert(question, at: 0)
            return
        }
        if input.isEmpty { input = question.text }
        for image in question.images {
            guard let thumbnail = NSImage(data: image.data) else { continue }
            pendingImages.append(PendingImage(data: image.data, mimeType: image.mimeType, thumbnail: thumbnail))
        }
        pendingDocuments.append(contentsOf: question.documents)
    }
}
