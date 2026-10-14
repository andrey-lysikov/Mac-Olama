//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

public enum ChatOrigin: String, Codable, Sendable {
    case panel, window, api
}

public struct Chat: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var modelID: String?
    public var systemPrompt: String?
    public var origin: ChatOrigin
    public var isArchived: Bool

    public init(
        id: UUID = UUID(), title: String = "", createdAt: Date = .now, updatedAt: Date = .now,
        modelID: String? = nil, systemPrompt: String? = nil, origin: ChatOrigin, isArchived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.origin = origin
        self.isArchived = isArchived
    }
}

public enum MessageRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

public struct Attachment: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case image, document }
    public var id: UUID
    public var kind: Kind
    public var relativePath: String
    public var sha256: String
    public var width: Int
    public var height: Int
    public var displayName: String?

    public init(
        id: UUID = UUID(), kind: Kind = .image, relativePath: String, sha256: String, width: Int, height: Int, displayName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.sha256 = sha256
        self.width = width
        self.height = height
        self.displayName = displayName
    }
}

public struct DocumentInput: Sendable, Equatable {
    public var name: String
    public var text: String
    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

public struct ToolCall: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct Message: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var chatID: UUID
    public var role: MessageRole
    public var text: String
    public var attachments: [Attachment]
    public var toolCalls: [ToolCall]
    public var toolCallID: String?
    public var createdAt: Date
    public var completionTokens: Int?
    public var tokensPerSecond: Double?
    public var isPartial: Bool
    public var modelID: String?

    public init(
        id: UUID = UUID(), chatID: UUID, role: MessageRole, text: String, attachments: [Attachment] = [],
        toolCalls: [ToolCall] = [], toolCallID: String? = nil, createdAt: Date = .now,
        completionTokens: Int? = nil, tokensPerSecond: Double? = nil, isPartial: Bool = false, modelID: String? = nil
    ) {
        self.id = id
        self.chatID = chatID
        self.role = role
        self.text = text
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.createdAt = createdAt
        self.completionTokens = completionTokens
        self.tokensPerSecond = tokensPerSecond
        self.isPartial = isPartial
        self.modelID = modelID
    }
}

// ChatStore

public protocol ChatStore: Sendable {
    func allChats(includeArchived: Bool) async throws -> [Chat]
    func chat(id: UUID) async throws -> Chat?
    func messages(chatID: UUID) async throws -> [Message]
    func chatIDs(matching query: String) async throws -> Set<UUID>
    func insert(_ chat: Chat) async throws
    func update(_ chat: Chat) async throws
    func deleteChat(id: UUID) async throws
    func insert(_ message: Message) async throws
    func update(_ message: Message) async throws
    func deleteMessage(id: UUID) async throws
    var changes: AsyncStream<ChatStoreChange> { get }
}

public final class ChatStoreBroadcast: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [UUID: AsyncStream<ChatStoreChange>.Continuation] = [:]

    public init() {}

    public func subscribe() -> AsyncStream<ChatStoreChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatStoreChange.self, bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        lock.withLock { listeners[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.listeners[id] = nil }
        }
        return stream
    }

    public func yield(_ change: ChatStoreChange) {
        let current = lock.withLock { Array(listeners.values) }
        for listener in current { listener.yield(change) }
    }
}

public enum ChatStoreChange: Sendable, Equatable {
    case chatInserted(UUID), chatUpdated(UUID), chatDeleted(UUID)
    case messageInserted(chatID: UUID, messageID: UUID)
    case messageUpdated(chatID: UUID, messageID: UUID)
    case messageDeleted(chatID: UUID, messageID: UUID)
}

public enum ChatStoreError: Error, Equatable {
    case notFound(UUID)
}

public actor InMemoryChatStore: ChatStore {
    private var chats: [UUID: Chat] = [:]
    private var messagesByChat: [UUID: [Message]] = [:]
    private nonisolated let broadcast = ChatStoreBroadcast()
    public nonisolated var changes: AsyncStream<ChatStoreChange> { broadcast.subscribe() }

    public init() {}

    public func allChats(includeArchived: Bool) async throws -> [Chat] {
        chats.values.filter { includeArchived || !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func chat(id: UUID) async throws -> Chat? { chats[id] }

    public func messages(chatID: UUID) async throws -> [Message] {
        (messagesByChat[chatID] ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    public func chatIDs(matching query: String) async throws -> Set<UUID> {
        let found = messagesByChat.filter { _, messages in
            messages.contains { ($0.role == .user || $0.role == .assistant) && $0.text.localizedStandardContains(query) }
        }
        return Set(found.keys)
    }

    public func insert(_ chat: Chat) async throws {
        chats[chat.id] = chat
        broadcast.yield(.chatInserted(chat.id))
    }

    public func update(_ chat: Chat) async throws {
        guard chats[chat.id] != nil else { throw ChatStoreError.notFound(chat.id) }
        chats[chat.id] = chat
        broadcast.yield(.chatUpdated(chat.id))
    }

    public func deleteChat(id: UUID) async throws {
        chats[id] = nil
        messagesByChat[id] = nil
        broadcast.yield(.chatDeleted(id))
    }

    public func insert(_ message: Message) async throws {
        messagesByChat[message.chatID, default: []].append(message)
        touch(message.chatID)
        broadcast.yield(.messageInserted(chatID: message.chatID, messageID: message.id))
    }

    public func update(_ message: Message) async throws {
        guard var list = messagesByChat[message.chatID],
            let idx = list.firstIndex(where: { $0.id == message.id })
        else {
            throw ChatStoreError.notFound(message.id)
        }
        list[idx] = message
        messagesByChat[message.chatID] = list
        touch(message.chatID)
        broadcast.yield(.messageUpdated(chatID: message.chatID, messageID: message.id))
    }

    public func deleteMessage(id: UUID) async throws {
        for (chatID, list) in messagesByChat where list.contains(where: { $0.id == id }) {
            messagesByChat[chatID] = list.filter { $0.id != id }
            broadcast.yield(.messageDeleted(chatID: chatID, messageID: id))
        }
    }

    private func touch(_ chatID: UUID) {
        chats[chatID]?.updatedAt = .now
    }
}
