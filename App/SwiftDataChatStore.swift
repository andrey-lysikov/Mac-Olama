//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftData

// SwiftData records

@Model
final class ChatRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelID: String?
    var systemPrompt: String?
    var originRaw: String
    var isArchived: Bool
    @Relationship(deleteRule: .cascade, inverse: \MessageRecord.chat) var messages: [MessageRecord] = []

    init(_ chat: Chat) {
        id = chat.id
        title = chat.title
        createdAt = chat.createdAt
        updatedAt = chat.updatedAt
        modelID = chat.modelID
        systemPrompt = chat.systemPrompt
        originRaw = chat.origin.rawValue
        isArchived = chat.isArchived
    }

    func apply(_ chat: Chat) {
        title = chat.title
        updatedAt = chat.updatedAt
        modelID = chat.modelID
        systemPrompt = chat.systemPrompt
        originRaw = chat.origin.rawValue
        isArchived = chat.isArchived
    }

    var value: Chat {
        Chat(
            id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, modelID: modelID,
            systemPrompt: systemPrompt, origin: ChatOrigin(rawValue: originRaw) ?? .window, isArchived: isArchived)
    }
}

@Model
final class MessageRecord {
    @Attribute(.unique) var id: UUID
    var chatID: UUID
    var roleRaw: String
    var text: String
    var attachmentsJSON: Data
    var toolCallsJSON: Data
    var toolCallID: String?
    var createdAt: Date
    var completionTokens: Int?
    var tokensPerSecond: Double?
    var isPartial: Bool
    var modelID: String?
    var chat: ChatRecord?

    init(_ m: Message) {
        id = m.id
        chatID = m.chatID
        roleRaw = m.role.rawValue
        text = m.text
        attachmentsJSON = (try? JSONCoding.encoder.encode(m.attachments)) ?? Data()
        toolCallsJSON = (try? JSONCoding.encoder.encode(m.toolCalls)) ?? Data()
        toolCallID = m.toolCallID
        createdAt = m.createdAt
        completionTokens = m.completionTokens
        tokensPerSecond = m.tokensPerSecond
        isPartial = m.isPartial
        modelID = m.modelID
    }

    func apply(_ m: Message) {
        text = m.text
        attachmentsJSON = (try? JSONCoding.encoder.encode(m.attachments)) ?? Data()
        toolCallsJSON = (try? JSONCoding.encoder.encode(m.toolCalls)) ?? Data()
        toolCallID = m.toolCallID
        completionTokens = m.completionTokens
        tokensPerSecond = m.tokensPerSecond
        isPartial = m.isPartial
        modelID = m.modelID
    }

    var value: Message {
        Message(
            id: id, chatID: chatID, role: MessageRole(rawValue: roleRaw) ?? .assistant, text: text,
            attachments: (try? JSONCoding.decoder.decode([Attachment].self, from: attachmentsJSON)) ?? [],
            toolCalls: (try? JSONCoding.decoder.decode([ToolCall].self, from: toolCallsJSON)) ?? [],
            toolCallID: toolCallID, createdAt: createdAt, completionTokens: completionTokens,
            tokensPerSecond: tokensPerSecond, isPartial: isPartial, modelID: modelID
        )
    }
}

// Store

/// SwiftData-backed `ChatStore` on its own ModelActor; the UI only ever sees value types.
// ModelActor is adopted by hand: the @ModelActor macro synthesizes an init that cannot set our extra stored properties.
actor SwiftDataChatStore: ModelActor, ChatStore {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    private nonisolated let broadcast = ChatStoreBroadcast()
    nonisolated var changes: AsyncStream<ChatStoreChange> { broadcast.subscribe() }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = ModelConfiguration("MacOlama", url: directory.appendingPathComponent("MacOlama.store"))
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: config)
        self.modelContainer = container
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
    }

    private func chatRecord(_ id: UUID) throws -> ChatRecord? {
        var d = FetchDescriptor<ChatRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    private func messageRecord(_ id: UUID) throws -> MessageRecord? {
        var d = FetchDescriptor<MessageRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    func allChats(includeArchived: Bool) async throws -> [Chat] {
        let d = FetchDescriptor<ChatRecord>(
            predicate: includeArchived ? nil : #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(d).map(\.value)
    }

    func chat(id: UUID) async throws -> Chat? { try chatRecord(id)?.value }

    func messages(chatID: UUID) async throws -> [Message] {
        let d = FetchDescriptor<MessageRecord>(predicate: #Predicate { $0.chatID == chatID }, sortBy: [SortDescriptor(\.createdAt)])
        return try modelContext.fetch(d).map(\.value)
    }

    func insert(_ chat: Chat) async throws {
        modelContext.insert(ChatRecord(chat))
        try modelContext.save()
        broadcast.yield(.chatInserted(chat.id))
    }

    func update(_ chat: Chat) async throws {
        guard let record = try chatRecord(chat.id) else { throw ChatStoreError.notFound(chat.id) }
        record.apply(chat)
        try modelContext.save()
        broadcast.yield(.chatUpdated(chat.id))
    }

    func deleteChat(id: UUID) async throws {
        guard let record = try chatRecord(id) else { return }
        modelContext.delete(record)
        try modelContext.save()
        broadcast.yield(.chatDeleted(id))
    }

    func insert(_ message: Message) async throws {
        let record = MessageRecord(message)
        record.chat = try chatRecord(message.chatID)
        record.chat?.updatedAt = .now
        modelContext.insert(record)
        try modelContext.save()
        broadcast.yield(.messageInserted(chatID: message.chatID, messageID: message.id))
    }

    func update(_ message: Message) async throws {
        guard let record = try messageRecord(message.id) else { throw ChatStoreError.notFound(message.id) }
        record.apply(message)
        record.chat?.updatedAt = .now
        try modelContext.save()
        broadcast.yield(.messageUpdated(chatID: message.chatID, messageID: message.id))
    }

    func deleteMessage(id: UUID) async throws {
        guard let record = try messageRecord(id) else { return }
        let chatID = record.chatID
        modelContext.delete(record)
        try modelContext.save()
        broadcast.yield(.messageDeleted(chatID: chatID, messageID: id))
    }
}
