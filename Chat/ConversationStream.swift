//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI

// The streaming logic shared by the chats window and the quick panel lives here once: composer,
// question queue, attachments, the event loop of a running reply and its transcript.

/// What a surface (chats window, quick panel) provides to the shared coordinator.
@MainActor
protocol ConversationStreamDelegate: AnyObject {
    /// The chat the question goes to, created on demand; nil aborts the send (the question returns to the composer).
    func chatIDForSending(question: QueuedQuestion) async -> UUID?
    /// The model that should answer: the surface's own picker, or the app-wide choice.
    func modelIDForSending() -> String?
    /// Whether the surface currently shows this chat; a reply streaming into another chat must not overwrite the transcript.
    func displaysChat(_ chatID: UUID) -> Bool
    /// A run ended, whatever the outcome: the surface refreshes what it owns (chat list, flags).
    func streamDidFinish(chatID: UUID)
    var acceptsImages: Bool { get }
}

/// Adopted by the surfaces' view models: the coordinator holds the shared state, and these defaults let the views
/// keep their old property names. `@Observable` tracks the coordinator's own properties, so observation still works.
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
    /// A copied or dropped link: the page text becomes a document attachment.
    func attach(webURL url: URL) { stream.attach(webURL: url) }
    func removeImage(_ id: UUID) { stream.removeImage(id) }
    func removeDocument(_ name: String) { stream.removeDocument(name) }
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

    var input = ""
    var pendingImages: [PendingImage] = []
    var pendingDocuments: [DocumentInput] = []
    var errorMessage: String?
    private(set) var messages: [Message] = []
    private(set) var streamingText = ""
    /// Tokens not on screen yet. The views re-read the whole reply (markup, reasoning, Markdown) on every change, so it
    /// changes about 30 times a second rather than per token: per token that work grows with the square of the reply.
    private var unshownText = ""
    private var unshownTokens = 0
    private var lastShown = ContinuousClock.now
    /// Steps and thinking of the running reply, shown above it; nil when nothing runs here.
    private(set) var progress: GenerationProgress?
    /// Questions sent while the model was busy; they go out one by one after the current reply.
    private(set) var queuedQuestions: [QueuedQuestion] = []
    /// Thinking time of replies finished in this session, for their summary line (not stored with the message).
    private(set) var thoughtSeconds: [UUID: Int] = [:]
    private(set) var isGenerating = false

    /// This surface is writing the current reply (its own token stream and progress).
    var streamsHere: Bool { progress != nil }
    /// The streamed reply without the model's private channels; notes about tools are separate state.
    var visibleStreamingText: String { AnswerText.visible(streamingText) }

    /// Context the chat takes, estimated: exact counts for generated replies, ~3 characters per token for everything
    /// else. Shared so the window and the panel show the same number for the same chat.
    func contextUsed(systemPrompt: String?) -> Int {
        let system = (systemPrompt?.count ?? 0) / 3
        let history = messages.reduce(0) { $0 + ($1.role == .assistant ? $1.completionTokens ?? $1.text.count / 3 : $1.text.count / 3) }
        return system + history + (streamingText.count + input.count) / 3
    }

    /// Cached so the answer-started check is not an O(n) rescan of the reply on every token.
    private var answerStarted = false
    /// Bumped on every new run and on reset; the tail of a cancelled task must not write stale state.
    private var generation = 0
    private var streamTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
    }

    // Transcript

    func setMessages(_ messages: [Message]) { self.messages = messages }

    func fetchMessages(chatID: UUID) async -> [Message] {
        (try? await container.chatStore.messages(chatID: chatID)) ?? []
    }

    /// The chat-store loop shared by the surfaces; which callback does what is the only difference between them.
    /// The surface stores the returned task and cancels it in `deinit`; the callbacks should capture it weakly.
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

    /// Sends the composer, or queues the question while a reply is running.
    /// `surfaceBusy`: the surface knows the chat is busy elsewhere (panel or API streaming into it).
    func send(chatID: UUID?, surfaceBusy: Bool = false) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty || !pendingDocuments.isEmpty else { return }
        let question = QueuedQuestion(
            chatID: chatID, text: text,
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

    /// Kicks the next waiting question once the chat is free again (a reply that ran on another surface ended).
    func drainQueue() {
        guard !isGenerating, errorMessage == nil, !queuedQuestions.isEmpty else { return }
        ask(queuedQuestions.removeFirst())
    }

    /// Deletes the tail from the last user message (its tool rounds included) and asks it again.
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
            ask(QueuedQuestion(chatID: chatID, text: user.text, images: images, documents: documents))
        }
    }

    /// Cancels the running reply and wipes all composer and streaming state; the old task's tail cannot write back.
    func reset() {
        streamTask?.cancel()
        streamTask = nil
        generation += 1
        input = ""
        messages = []
        streamingText = ""
        dropUnshown()
        progress = nil
        queuedQuestions = []
        errorMessage = nil
        pendingImages = []
        pendingDocuments = []
        isGenerating = false
        answerStarted = false
        streamingChatID = nil
    }

    // Attachments

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
        case .document(let document): pendingDocuments.append(document)
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

    func removeImage(_ id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    func removeDocument(_ name: String) {
        pendingDocuments.removeAll { $0.name == name }
    }

    /// A copied image or file becomes an attachment; returns false when only text is on the pasteboard.
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
        case nil: return false
        }
        return true
    }

    // Run loop

    /// The chat the running reply streams into; nil while idle. Stop must aim here, not at the selection.
    private(set) var streamingChatID: UUID?

    private func ask(_ question: QueuedQuestion) {
        streamTask?.cancel()
        generation += 1
        let gen = generation
        // Set synchronously: a send() racing the async chat resolution must queue, not start a second run.
        isGenerating = true
        errorMessage = nil
        streamingText = ""
        dropUnshown()
        answerStarted = false
        progress = GenerationProgress()
        streamTask = Task {
            let resolved = await delegate?.chatIDForSending(question: question)
            guard generation == gen else { return }
            guard let chatID = resolved else {
                isGenerating = false
                progress = nil
                restoreToComposer(question)
                return
            }
            streamingChatID = chatID
            do {
                let stream = try await container.conversation.send(
                    chatID: chatID, text: question.text, images: question.images, documents: question.documents,
                    modelID: delegate?.modelIDForSending())
                for await event in stream {
                    guard generation == gen else { return }
                    switch event {
                    case .started:
                        await reloadIfDisplayed(chatID, generation: gen)
                    case .token(let t):
                        unshownText += t
                        unshownTokens += 1
                        if lastShown.duration(to: .now) >= .milliseconds(33) { showUnshown() }
                    case .toolCallStarted(let call):
                        showUnshown()
                        // The call stays out of the transcript; whatever preceded it was a preamble, not the answer.
                        progress?.toolStarted(AnswerText.activity(for: call, searchProvider: container.settings.searchProvider))
                        streamingText = ""
                        answerStarted = false
                    case .toolCallFinished:
                        progress?.toolFinished()
                    case .retrying:
                        dropUnshown()
                        streamingText = ""
                        answerStarted = false
                    case .failed(let message):
                        showUnshown()
                        errorMessage = message
                    case .finished(let message):
                        showUnshown()
                        progress?.endThinking()
                        thoughtSeconds[message.id] = progress?.reportedThoughtSeconds
                        container.answerFinished(message)
                    }
                }
            } catch {
                guard generation == gen else { return }
                errorMessage = ConversationService.describe(error)
                restoreToComposer(question)
            }
            guard generation == gen else { return }
            isGenerating = false
            streamingText = ""
            dropUnshown()
            progress = nil
            answerStarted = false
            streamingChatID = nil
            await reloadIfDisplayed(chatID, generation: gen)
            // A fresh send may have started during the reload; its run owns the state now.
            guard generation == gen else { return }
            delegate?.streamDidFinish(chatID: chatID)
            // The next waiting question goes out; after a failure the queue waits, the user sees the error first.
            if errorMessage == nil, !queuedQuestions.isEmpty { ask(queuedQuestions.removeFirst()) }
        }
    }

    /// Puts the tokens received since the last update on screen, and counts them in the progress line.
    private func showUnshown() {
        guard unshownTokens > 0 else { return }
        streamingText += unshownText
        if !answerStarted { answerStarted = !AnswerText.visible(streamingText).isEmpty }
        for _ in 0..<unshownTokens { progress?.token(answerStarted: answerStarted) }
        dropUnshown()
    }

    private func dropUnshown() {
        unshownText = ""
        unshownTokens = 0
        lastShown = .now
    }

    private func reloadIfDisplayed(_ chatID: UUID, generation gen: Int) async {
        let loaded = await fetchMessages(chatID: chatID)
        guard generation == gen, delegate?.displaysChat(chatID) != false else { return }
        messages = loaded
    }

    /// A send that failed before anything was stored: the question returns to the composer instead of vanishing.
    private func restoreToComposer(_ question: QueuedQuestion) {
        if input.isEmpty { input = question.text }
        for image in question.images {
            guard let thumbnail = NSImage(data: image.data) else { continue }
            pendingImages.append(PendingImage(data: image.data, mimeType: image.mimeType, thumbnail: thumbnail))
        }
        pendingDocuments.append(contentsOf: question.documents)
    }
}
