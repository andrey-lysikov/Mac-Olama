//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppIntents
import AppKit
import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers

// Bridge

/// Entry point for intents into the running app. Configured by AppDelegate; intents run in-process.
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()
    private(set) var container: AppContainer?
    private(set) var panel: QuickPanelController?

    func configure(container: AppContainer, panel: QuickPanelController) {
        self.container = container
        self.panel = panel
    }

    struct Answer {
        var chatID: UUID
        var prompt: String
        var text: String
        var modelName: String
        var isPartial: Bool
    }

    /// Spotlight may launch the app only to run an intent: wait briefly for startup and the model catalog before failing.
    func readyContainer(needsModel: Bool = false, timeout: TimeInterval = 8) async throws -> AppContainer {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let container, !needsModel || container.activeModel != nil { return container }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard let container else { throw IntentError.appNotReady }
        return container
    }

    /// Sends a prompt to the active (or a new) chat and waits up to `timeout`; generation keeps running afterwards.
    func ask(prompt: String, file: IntentFile?, newChat: Bool, timeout: TimeInterval, progress: Progress?) async throws -> Answer {
        let container = try await readyContainer(needsModel: true)
        guard let model = container.activeModel else { throw IntentError.noModel }
        let chat =
            newChat
            ? try await container.conversation.newChat(origin: .spotlight) : try await container.conversation.activeChat(origin: .spotlight)
        container.setActiveChat(chat.id)
        var images: [ImageInput] = []
        var documents: [DocumentInput] = []
        if let file {
            switch DocumentExtractor.extract(data: file.data, name: file.filename, type: file.type) {
            case .image(let image):
                guard model.kind == .vlm else { throw IntentError.imagesUnsupported(model.name) }
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:])
                {
                    images.append(ImageInput(data: png, mimeType: "image/png"))
                }
            case .document(let doc): documents.append(doc)
            case nil: throw IntentError.unsupportedFile(file.filename)
            }
        }
        progress?.localizedDescription = String(localized: "Loading model…")
        let stream = try await container.conversation.send(chatID: chat.id, text: prompt, images: images, documents: documents)

        let collector = Task { () -> (String, Bool) in
            var text = ""
            var started = false
            for await event in stream {
                switch event {
                case .started:
                    started = true
                    progress?.localizedDescription = String(localized: "Generating…")
                    progress?.completedUnitCount = 40
                case .token(let t):
                    text += t
                    if let p = progress, p.completedUnitCount < 95 { p.completedUnitCount += 1 }
                case .retrying: text = ""
                case .finished(let m): return (m.text, false)
                case .failed(let e): throw IntentError.generationFailed(e)
                default: break
                }
            }
            return (text, started)
        }
        let deadline = Task { try await Task.sleep(for: .seconds(timeout)) }
        let result: (String, Bool)
        do {
            result = try await withThrowingTaskGroup(of: (String, Bool)?.self) { group in
                group.addTask { try await collector.value }
                group.addTask {
                    try await deadline.value; return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                if let first { return first }
                // Timed out: report what we have so far; the store keeps receiving the rest.
                let partial = (try? await container.chatStore.messages(chatID: chat.id))?.last(where: { $0.role == .assistant })?.text ?? ""
                return (partial, true)
            }
        }
        progress?.completedUnitCount = 100
        return Answer(chatID: chat.id, prompt: prompt, text: result.0, modelName: model.name, isPartial: result.1)
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady, noModel, imagesUnsupported(String), unsupportedFile(String), generationFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: "Mac-Olama is still starting. Try again in a moment."
        case .noModel: "No model is installed. Open Mac-Olama and download one."
        case .imagesUnsupported(let name): "Model \(name) does not accept images. Pick a VLM model."
        case .unsupportedFile(let name): "Cannot read \(name). Attach an image, PDF or text file."
        case .generationFailed(let e): "Generation failed: \(e)"
        }
    }
}

// Entities

struct ChatEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chat"
    static let defaultQuery = ChatQuery()

    var id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Updated") var updatedAt: Date
    var preview: String
    var fullText: String

    init(chat: Chat, messages: [Message]) {
        // Plain stored properties first: assigning an @Property-wrapped value goes through `self`.
        let visible = messages.filter { $0.role == .user || $0.role == .assistant }
        id = chat.id
        preview = String((visible.last?.text ?? "").prefix(120))
        fullText = visible.map(\.text).joined(separator: "\n")
        title = chat.title.isEmpty ? String(localized: "Untitled chat") : chat.title
        updatedAt = chat.updatedAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(preview)", image: .init(systemName: "bubble.left.and.text.bubble.right"))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let a = CSSearchableItemAttributeSet(contentType: .text)
        a.title = title
        a.contentDescription = preview
        a.textContent = fullText
        a.contentModificationDate = updatedAt
        return a
    }
}

struct ChatQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ChatEntity] {
        guard let store = IntentBridge.shared.container?.chatStore else { return [] }
        var out: [ChatEntity] = []
        for id in identifiers {
            if let chat = try await store.chat(id: id) {
                out.append(ChatEntity(chat: chat, messages: try await store.messages(chatID: id)))
            }
        }
        return out
    }

    @MainActor
    func suggestedEntities() async throws -> [ChatEntity] {
        guard let store = IntentBridge.shared.container?.chatStore else { return [] }
        var out: [ChatEntity] = []
        for chat in try await store.allChats(includeArchived: false).prefix(10) {
            out.append(ChatEntity(chat: chat, messages: try await store.messages(chatID: chat.id)))
        }
        return out
    }
}

struct ModelEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "LLM Model"
    static let defaultQuery = ModelQuery()
    var id: String
    var name: String
    var kind: ModelKind
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: kind == .vlm ? "Vision + text" : "Text")
    }
    init(_ m: ModelDescriptor) { id = m.id; name = m.name; kind = m.kind }
}

struct ModelQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ModelEntity] {
        (IntentBridge.shared.container?.models ?? []).filter { identifiers.contains($0.id) }.map(ModelEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [ModelEntity] {
        (IntentBridge.shared.container?.models ?? []).filter { $0.name.localizedCaseInsensitiveContains(string) }.map(ModelEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [ModelEntity] {
        (IntentBridge.shared.container?.models ?? []).map(ModelEntity.init)
    }
}

// Intents

/// Spotlight entry point. Reports progress so Spotlight can show "Loading model… / Generating…" (V13).
struct AskModelIntent: AppIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Ask Mac-Olama"
    static let description = IntentDescription("Ask the local model and continue the current chat.")
    static let openAppWhenRun = false

    @Parameter(title: "Prompt", inputOptions: String.IntentInputOptions(multiline: true)) var prompt: String
    @Parameter(title: "File", supportedContentTypes: [.image, .pdf, .text, .plainText, .sourceCode, .json, .rtf]) var file: IntentFile?
    @Parameter(title: "Start a new chat", default: false) var newChat: Bool

    let progress = Progress(totalUnitCount: 100)

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$prompt)") {
            \.$file
            \.$newChat
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let timeout = IntentBridge.shared.container?.settings.spotlightTimeoutSeconds ?? SettingsDefaults.spotlightTimeoutSeconds
        let answer = try await IntentBridge.shared.ask(
            prompt: prompt, file: file, newChat: newChat, timeout: timeout, progress: progress)
        let dialog: IntentDialog =
            answer.isPartial
            ? IntentDialog(full: "Still generating. Open Mac-Olama to follow the answer.", supporting: "\(answer.text)")
            : IntentDialog("\(answer.text)")
        return .result(dialog: dialog, view: AnswerSnippetView(answer: answer))
    }
}

struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat in Mac-Olama"
    static let description = IntentDescription("Starts a fresh conversation; the previous one stays in the chat list.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try await IntentBridge.shared.readyContainer()
        let chat = try await container.conversation.newChat(origin: .spotlight)
        container.setActiveChat(chat.id)
        return .result(dialog: "New chat started.")
    }
}

struct OpenPanelIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Mac-Olama Panel"
    static let description = IntentDescription("Shows the quick panel, optionally with a specific chat.")
    static let openAppWhenRun = true

    @Parameter(title: "Chat") var chat: ChatEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = try await IntentBridge.shared.readyContainer()
        if let chat { container.setActiveChat(chat.id) }
        IntentBridge.shared.panel?.show()
        return .result()
    }
}

struct OpenChatsWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Mac-Olama Chats"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WindowManager.shared.open(.chats)
        return .result()
    }
}

struct SetActiveModelIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Mac-Olama Model"
    @Parameter(title: "Model") var model: ModelEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try await IntentBridge.shared.readyContainer(needsModel: true)
        container.setActiveModel(container.models.first { $0.id == model.id })
        return .result(dialog: "Active model: \(model.name)")
    }
}

struct MacOlamaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskModelIntent(), phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
            shortTitle: "Ask Mac-Olama", systemImageName: "sparkle.magnifyingglass")
        AppShortcut(
            intent: NewChatIntent(), phrases: ["New chat in \(.applicationName)"], shortTitle: "New Chat", systemImageName: "plus.bubble")
        AppShortcut(
            intent: OpenPanelIntent(), phrases: ["Open \(.applicationName)"], shortTitle: "Open Panel",
            systemImageName: "rectangle.and.text.magnifyingglass")
    }
}

// Snippet

/// Result view rendered by Spotlight/Siri. Static: no scrolling, so long answers are trimmed.
struct AnswerSnippetView: View {
    let answer: IntentBridge.Answer
    private var trimmed: String { answer.text.count > 1200 ? String(answer.text.prefix(1200)) + "…" : answer.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image("MenuBarIcon").resizable().frame(width: 16, height: 16)
                Text(answer.prompt).font(.headline).lineLimit(2)
                Spacer()
                if answer.isPartial {
                    ProgressView().controlSize(.small)
                }
            }
            Text(
                (try? AttributedString(markdown: trimmed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(trimmed)
            )
            .font(.body)
            .textSelection(.enabled)
            HStack {
                Text(answer.modelName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(answer.isPartial ? "Generating… open Mac-Olama for the full answer" : "Run “Ask Mac-Olama” again to continue")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

// Spotlight index

/// Keeps CoreSpotlight in sync with the chat store so past chats are searchable by content.
@MainActor
final class SpotlightIndexer {
    private let store: any ChatStore
    private var task: Task<Void, Never>?

    init(store: any ChatStore) {
        self.store = store
    }

    func start() {
        task = Task { [store] in
            await self.reindexAll()
            for await change in store.changes {
                switch change {
                case .chatInserted(let id), .chatUpdated(let id), .messageInserted(let id, _), .messageUpdated(let id, _),
                    .messageDeleted(let id, _):
                    await self.index(chatID: id)
                case .chatDeleted(let id):
                    try? await CSSearchableIndex.default().deleteAppEntities(identifiedBy: [id], ofType: ChatEntity.self)
                }
            }
        }
    }

    func stop() { task?.cancel() }

    private func index(chatID: UUID) async {
        guard let chat = try? await store.chat(id: chatID), let messages = try? await store.messages(chatID: chatID) else { return }
        try? await CSSearchableIndex.default().indexAppEntities([ChatEntity(chat: chat, messages: messages)])
    }

    private func reindexAll() async {
        guard let chats = try? await store.allChats(includeArchived: true) else { return }
        var entities: [ChatEntity] = []
        for chat in chats {
            entities.append(ChatEntity(chat: chat, messages: (try? await store.messages(chatID: chat.id)) ?? []))
        }
        try? await CSSearchableIndex.default().indexAppEntities(entities)
    }
}
