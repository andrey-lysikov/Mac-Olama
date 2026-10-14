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
    var errorMessage: String?
    private(set) var messages: [Message] = []
    private(set) var streamingText = ""
    private var unshownText = ""
    private var unshownTokens = 0
    private var lastShown = ContinuousClock.now
    private(set) var progress: GenerationProgress? { didSet { publishProgress() } }
    private(set) var queuedQuestions: [QueuedQuestion] = []
    private(set) var thoughtSeconds: [UUID: Int] = [:]
    private(set) var isGenerating = false

    var streamsHere: Bool { progress != nil }
    var visibleStreamingText: String { AnswerText.visible(streamingText) }

    func contextUsed(systemPrompt: String?) -> Int {
        let system = (systemPrompt?.count ?? 0) / 3
        let history = messages.reduce(0) { $0 + ($1.role == .assistant ? $1.completionTokens ?? $1.text.count / 3 : $1.text.count / 3) }
        return system + history + (streamingText.count + input.count) / 3
    }

    private var answerStarted = false
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

    func drainQueue() {
        guard !isGenerating, errorMessage == nil, !queuedQuestions.isEmpty else { return }
        ask(queuedQuestions.removeFirst())
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
            ask(QueuedQuestion(chatID: chatID, text: user.text, images: images, documents: documents))
        }
    }

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

    private(set) var streamingChatID: UUID? { didSet { publishProgress() } }

    private func publishProgress() {
        if let streamingChatID { container.liveProgress[streamingChatID] = progress }
    }

    private func ask(_ question: QueuedQuestion) {
        streamTask?.cancel()
        generation += 1
        let gen = generation
        // Set synchronously so a racing send() queues.
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
                    case .generated(let count):
                        progress?.generated(count)
                    case .toolCallStarted(let call):
                        showUnshown()
                        // The call stays out of the transcript; whatever preceded it was a preamble, not the answer.
                        progress?.toolStarted(AnswerText.activity(for: call, searchProvider: container.settings.searchProvider))
                        streamingText = ""
                        answerStarted = false
                    case .toolCallFinished(let call, let result):
                        progress?.toolFinished(detail: AnswerText.detail(for: call, result: result))
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
            // Send the next queued question; pause after a failure.
            if errorMessage == nil, !queuedQuestions.isEmpty { ask(queuedQuestions.removeFirst()) }
        }
    }

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

    private func restoreToComposer(_ question: QueuedQuestion) {
        if input.isEmpty { input = question.text }
        for image in question.images {
            guard let thumbnail = NSImage(data: image.data) else { continue }
            pendingImages.append(PendingImage(data: image.data, mimeType: image.mimeType, thumbnail: thumbnail))
        }
        pendingDocuments.append(contentsOf: question.documents)
    }
}
