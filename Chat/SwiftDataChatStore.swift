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

    /// Sets what never changes; the rest goes through `apply`, so insert and update share one field list.
    init(_ chat: Chat) {
        id = chat.id
        createdAt = chat.createdAt
        title = ""
        updatedAt = chat.updatedAt
        originRaw = ""
        isArchived = false
        apply(chat)
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

    /// Sets what never changes; the rest goes through `apply`, so insert and update share one field list.
    init(_ m: Message) {
        id = m.id
        chatID = m.chatID
        roleRaw = m.role.rawValue
        createdAt = m.createdAt
        text = ""
        attachmentsJSON = Data()
        toolCallsJSON = Data()
        isPartial = false
        apply(m)
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

// Schema versions

/// Future model changes add a ChatSchemaV2 and a migration stage instead of breaking the store.
enum ChatSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [ChatRecord.self, MessageRecord.self] }
}

enum ChatMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ChatSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
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
        let schema = Schema(versionedSchema: ChatSchemaV1.self)
        let config = ModelConfiguration("MacOlama", schema: schema, url: directory.appendingPathComponent("MacOlama.store"))
        let container = try ModelContainer(for: schema, migrationPlan: ChatMigrationPlan.self, configurations: [config])
        self.modelContainer = container
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
    }

    /// Moves the broken store files aside so the next open starts fresh; returns the backup folder.
    static func backUpStore(in directory: URL) -> URL? {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backup = directory.appendingPathComponent("ChatsBackup-\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasPrefix("MacOlama.store") } ?? []
        guard !names.isEmpty, (try? fm.createDirectory(at: backup, withIntermediateDirectories: true)) != nil else { return nil }
        var moved = false
        for name in names {
            do {
                try fm.moveItem(at: directory.appendingPathComponent(name), to: backup.appendingPathComponent(name))
                moved = true
            } catch {
                // A file that cannot even be moved stays; the retry will fail and the session runs in memory.
            }
        }
        return moved ? backup : nil
    }

    private func first<T: PersistentModel>(_ predicate: Predicate<T>) throws -> T? {
        var d = FetchDescriptor<T>(predicate: predicate)
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    private func chatRecord(_ id: UUID) throws -> ChatRecord? { try first(#Predicate<ChatRecord> { $0.id == id }) }
    private func messageRecord(_ id: UUID) throws -> MessageRecord? { try first(#Predicate<MessageRecord> { $0.id == id }) }

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
