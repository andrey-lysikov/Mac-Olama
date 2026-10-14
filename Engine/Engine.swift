//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization

// Errors

public protocol DescribedError: Error, LocalizedError, CustomStringConvertible {}

extension DescribedError {
    public var errorDescription: String? { description }
}

// Duration

extension Duration {
    public var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
    public var nanoseconds: Int64 { Int64(components.seconds) * 1_000_000_000 + Int64(components.attoseconds / 1_000_000_000) }
}

// InferenceEngine

public enum EngineState: Sendable, Equatable {
    case unloaded
    case loading(modelID: String, progress: Double)
    case ready(modelID: String)
    case generating(modelID: String, chatID: UUID?, tokensPerSecond: Double)
    case error(message: String)

    public var modelID: String? {
        switch self {
        case .unloaded, .error: nil
        case .loading(let id, _), .ready(let id), .generating(let id, _, _): id
        }
    }
}

public struct SamplingParams: Sendable, Equatable, Codable {
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var repetitionPenalty: Double?
    public var seed: UInt64?
    public var topK: Int?
    public var minP: Double?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?

    public init(
        temperature: Double? = nil, topP: Double? = nil, maxTokens: Int? = nil, repetitionPenalty: Double? = nil, seed: UInt64? = nil,
        topK: Int? = nil, minP: Double? = nil, presencePenalty: Double? = nil, frequencyPenalty: Double? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
        self.topK = topK
        self.minP = minP
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
    }

    public func over(_ base: SamplingParams) -> SamplingParams {
        SamplingParams(
            temperature: temperature ?? base.temperature, topP: topP ?? base.topP, maxTokens: maxTokens ?? base.maxTokens,
            repetitionPenalty: repetitionPenalty ?? base.repetitionPenalty, seed: seed ?? base.seed, topK: topK ?? base.topK,
            minP: minP ?? base.minP, presencePenalty: presencePenalty ?? base.presencePenalty,
            frequencyPenalty: frequencyPenalty ?? base.frequencyPenalty)
    }
}

public enum KeepAlive: Sendable, Equatable {
    case `default`  // idle timer from settings
    case seconds(TimeInterval)
    case forever
    case unloadNow
}

public struct ToolSpec: Sendable, Equatable, Codable {
    public var name: String
    public var description: String
    public var parametersJSONSchema: String

    public init(name: String, description: String, parametersJSONSchema: String) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }
}

public struct ImageInput: Sendable, Equatable {
    public var data: Data
    public var mimeType: String
    public init(data: Data, mimeType: String = "image/png") {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct EngineMessage: Sendable, Equatable {
    public var role: MessageRole
    public var content: String
    public var images: [ImageInput]
    public var toolCalls: [ToolCall]
    public var toolCallID: String?

    public init(role: MessageRole, content: String, images: [ImageInput] = [], toolCalls: [ToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

public struct GenerationRequest: Sendable {
    public var messages: [EngineMessage]
    public var tools: [ToolSpec]
    public var sampling: SamplingParams
    public var keepAlive: KeepAlive
    public var chatID: UUID?
    public var contextTokens: Int?
    public var speculates: Bool
    public var thinks: Bool
    public var rejectsLongPrompt: Bool

    public init(
        messages: [EngineMessage], tools: [ToolSpec] = [], sampling: SamplingParams = .init(), keepAlive: KeepAlive = .default,
        chatID: UUID? = nil, contextTokens: Int? = nil, speculates: Bool = false, thinks: Bool = false, rejectsLongPrompt: Bool = false
    ) {
        self.messages = messages
        self.tools = tools
        self.sampling = sampling
        self.keepAlive = keepAlive
        self.chatID = chatID
        self.contextTokens = contextTokens
        self.speculates = speculates
        self.thinks = thinks
        self.rejectsLongPrompt = rejectsLongPrompt
    }
}

public enum FinishReason: String, Sendable, Codable {
    case stop, length, toolCalls = "tool_calls", cancelled, error
}

public struct GenerationUsage: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var tokensPerSecond: Double
    public var promptSeconds: TimeInterval
    public var generationSeconds: TimeInterval
    public init(
        promptTokens: Int, completionTokens: Int, tokensPerSecond: Double, promptSeconds: TimeInterval = 0,
        generationSeconds: TimeInterval = 0
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.tokensPerSecond = tokensPerSecond
        self.promptSeconds = promptSeconds
        self.generationSeconds = generationSeconds
    }
}

public enum GenerationEvent: Sendable, Equatable {
    case token(String)
    case toolCall(ToolCall)
    case usage(GenerationUsage)
    case generated(Int)
    case finished(FinishReason)
}

public enum EngineError: DescribedError, Equatable, Sendable {
    case noModelLoaded
    case imagesNotSupported
    case loadFailed(String)
    case unsupportedArchitecture(String)
    case generationFailed(String)
    case busy
    case promptTooLong(tokens: Int, limit: Int)
}

// "\(error)" is what the UI shows, so the cases read as sentences instead of enum dumps.
extension EngineError {
    public var description: String {
        switch self {
        case .noModelLoaded: String(localized: "No model is loaded.")
        case .imagesNotSupported: String(localized: "This model does not accept images.")
        case .busy: String(localized: "The model is busy with another request.")
        case .promptTooLong(let tokens, let limit):
            String(localized: "The prompt is \(tokens) tokens long, but the context window holds \(limit).")
        case .generationFailed(let detail): String(localized: "Generation failed: \(detail)")
        case .unsupportedArchitecture(let type):
            String(
                localized:
                    "The MLX engine in this version of the app does not support this model's architecture (\(type)). Another conversion of it will not load either; choose a different model or wait for an app update."
            )
        case .loadFailed(let detail):
            // MLX reports a weight mismatch as keyNotFound.
            detail.contains("keyNotFound")
                ? String(
                    localized:
                        "This build of the model cannot be loaded: its weight files do not match what the current MLX engine expects. Try another conversion of the same model (another author or quantization). Details: \(detail)"
                )
                : String(localized: "The model could not be loaded: \(detail)")
        }
    }
}

public protocol InferenceEngine: Actor {
    var loadedModel: ModelDescriptor? { get }
    func load(_ model: ModelDescriptor, progress: @Sendable @escaping (Double) -> Void) async throws
    func unload() async
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
    func cancelCurrent() async
}

// Generation stream scaffolding

final class GenerationTaskBox: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    func install(_ new: Task<Void, Never>) {
        task.withLock { $0 = new }
    }

    func cancel() {
        task.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}

extension AsyncThrowingStream where Element == GenerationEvent, Failure == Error {
    static func failed(_ error: Error) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = makeStream(of: GenerationEvent.self)
        continuation.finish(throwing: error)
        return stream
    }

    static func engine(
        current: GenerationTaskBox? = nil,
        _ body: @escaping @Sendable (Continuation) async throws -> Void
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = makeStream(of: GenerationEvent.self)
        let task = Task {
            do {
                try await body(continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.yield(.finished(.cancelled))
                continuation.finish()
            } catch let error as URLError where error.code == .cancelled {
                continuation.yield(.finished(.cancelled))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        current?.install(task)
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

// EngineManager

public actor EngineManager {
    public struct Configuration: Sendable {
        public var idleUnloadSeconds: TimeInterval
        public init(idleUnloadSeconds: TimeInterval = SettingsDefaults.idleUnloadSeconds) {
            self.idleUnloadSeconds = idleUnloadSeconds
        }
    }

    public private(set) var state: EngineState = .unloaded {
        didSet { if state != oldValue { broadcast(state) } }
    }
    public var configuration: Configuration

    private let engine: any InferenceEngine
    private var subscribers: [UUID: AsyncStream<EngineState>.Continuation] = [:]
    private var idleTask: Task<Void, Never>?
    private var keepForever = false
    private var queueTail: Task<Void, Never>?
    private var loadTask: (generation: Int, task: Task<Void, Error>)?
    private var loadingModelID: String?
    private var loadGeneration = 0

    public init(engine: any InferenceEngine, configuration: Configuration = .init()) {
        self.engine = engine
        self.configuration = configuration
    }

    public func setConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
        scheduleIdleUnload()
    }

    // State observation

    public func states() -> AsyncStream<EngineState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: EngineState.self, bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func broadcast(_ state: EngineState) {
        for c in subscribers.values { c.yield(state) }
    }

    // Load / unload

    public var loadedModel: ModelDescriptor? {
        get async { await engine.loadedModel }
    }

    public func ensureLoaded(_ model: ModelDescriptor) async throws {
        // Loop: every await is a suspension where another call may have installed its own load.
        while true {
            if await engine.loadedModel?.id == model.id { return }
            guard let existing = loadTask else { break }
            if loadingModelID == model.id {
                try await existing.task.value
                scheduleIdleUnload()
                return
            }
            existing.task.cancel()
            _ = try? await existing.task.value
            if loadTask?.generation == existing.generation {
                loadTask = nil
                loadingModelID = nil
            }
        }
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { [engine] in
            try Task.checkCancellation()
            if await engine.loadedModel != nil { await engine.unload() }
            if self.loadGeneration == generation { self.state = .loading(modelID: model.id, progress: 0) }
            do {
                try await engine.load(model) { p in
                    Task { await self.reportLoadProgress(modelID: model.id, progress: p) }
                }
                if self.loadGeneration == generation { self.state = .ready(modelID: model.id) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A superseded load must not flash its error over the state of the one that replaced it.
                if self.loadGeneration == generation { self.state = .error(message: "\(error)") }
                throw error
            }
        }
        loadTask = (generation, task)
        loadingModelID = model.id
        defer {
            // Only this call's task may clear the slot; a later load may have replaced it already.
            if loadTask?.generation == generation {
                loadTask = nil
                loadingModelID = nil
            }
        }
        try await task.value
        scheduleIdleUnload()
    }

    private func reportLoadProgress(modelID: String, progress: Double) {
        if case .loading(let id, _) = state, id == modelID {
            state = .loading(modelID: id, progress: min(max(progress, 0), 1))
        }
    }

    public func prewarm(_ model: ModelDescriptor) {
        Task { try? await ensureLoaded(model) }
    }

    public func unload() async {
        idleTask?.cancel()
        idleTask = nil
        keepForever = false
        await engine.cancelCurrent()
        await engine.unload()
        state = .unloaded
    }

    private func scheduleIdleUnload(after override: TimeInterval? = nil) {
        idleTask?.cancel()
        idleTask = nil
        if keepForever { return }
        let seconds = override ?? configuration.idleUnloadSeconds
        guard seconds > 0 else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        if case .generating = state { return }
        if case .loading = state { return }
        await unload()
    }

    // Generation

    public func generate(model: ModelDescriptor, request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let previous = queueTail
        let task = Task { [weak self] in
            _ = await previous?.value
            // A client that gave up while queued must not load a model or start a reply nobody reads.
            guard let self, !Task.isCancelled else { continuation.finish(throwing: CancellationError()); return }
            await self.run(model: model, request: request, continuation: continuation)
        }
        queueTail = task
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return stream
    }

    private func run(
        model: ModelDescriptor, request: GenerationRequest, continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async {
        idleTask?.cancel()
        do {
            try await ensureLoaded(model)
        } catch {
            continuation.finish(throwing: error)
            return
        }
        state = .generating(modelID: model.id, chatID: request.chatID, tokensPerSecond: 0)
        var tokenCount = 0
        let start = ContinuousClock.now
        do {
            for try await event in await engine.generate(request) {
                if Task.isCancelled {
                    await engine.cancelCurrent()
                    continuation.yield(.finished(.cancelled))
                    break
                }
                if case .token = event {
                    tokenCount += 1
                    if tokenCount % 8 == 0 {
                        let secs = start.duration(to: .now).seconds
                        state = .generating(
                            modelID: model.id, chatID: request.chatID, tokensPerSecond: secs > 0 ? Double(tokenCount) / secs : 0)
                    }
                }
                continuation.yield(event)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
        // Unload within this request's turn in the queue.
        await finishGeneration(model: model, keepAlive: request.keepAlive)
    }

    private func finishGeneration(model: ModelDescriptor, keepAlive: KeepAlive) async {
        switch keepAlive {
        case .unloadNow:
            await unload()
        case .forever:
            keepForever = true
            // The load armed the idle timer before this request's keep-alive was known.
            idleTask?.cancel()
            idleTask = nil
            state = .ready(modelID: model.id)
        case .seconds(let s):
            keepForever = false
            state = .ready(modelID: model.id)
            scheduleIdleUnload(after: s)
        case .default:
            keepForever = false
            state = .ready(modelID: model.id)
            scheduleIdleUnload()
        }
    }

    public func cancelCurrent() async {
        await engine.cancelCurrent()
    }
}
