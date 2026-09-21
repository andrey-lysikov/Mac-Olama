//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization

// Errors

/// `LocalizedError` as well as `CustomStringConvertible`: without both, the system prints "operation could not be
/// completed (MacOlama.SomeError, error 0)" wherever an error is shown or logged.
public protocol DescribedError: Error, LocalizedError, CustomStringConvertible {}

extension DescribedError {
    public var errorDescription: String? { description }
}

// Duration

extension Duration {
    /// Seconds as a Double, for rates and progress.
    public var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
    /// Whole nanoseconds, as the Ollama API counts durations.
    public var nanoseconds: Int64 { Int64(components.seconds) * 1_000_000_000 + Int64(components.attoseconds / 1_000_000_000) }
}

// InferenceEngine

/// Engine state: the single source for every indicator (menu bar icon, panel and chats window spinners).
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
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int
    public var repetitionPenalty: Double?
    public var seed: UInt64?

    /// 8192 by default: a reasoning model spends thousands of tokens before the visible answer, and a lower limit
    /// cuts the reply off while it is still thinking — which reads as no answer at all.
    public init(temperature: Double = 0.7, topP: Double = 0.9, maxTokens: Int = 8192, repetitionPenalty: Double? = nil, seed: UInt64? = nil)
    {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
    }
}

/// `keep_alive` semantics as in Ollama.
public enum KeepAlive: Sendable, Equatable {
    case `default`  // idle timer from settings
    case seconds(TimeInterval)
    case forever
    case unloadNow
}

/// Tool description for tool calling; parameters are a JSON Schema string to keep JSON types out of the API.
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

/// VLM image input as bytes, not a path: the engine runs on another actor and must not touch the file system.
public struct ImageInput: Sendable, Equatable {
    public var data: Data
    public var mimeType: String
    public init(data: Data, mimeType: String = "image/png") {
        self.data = data
        self.mimeType = mimeType
    }
}

/// Message in engine form (no ids, dates or other storage fields).
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
    /// For indicators: which chat is generating (nil for chat-less API requests).
    public var chatID: UUID?
    /// Context window in tokens (prompt + reply). nil = model maximum; engines bound their KV cache by it.
    public var contextTokens: Int?
    /// Multi-token prediction is allowed for this request: the model has a drafter and the user switched it on.
    /// Without it the engine leaves the drafter unloaded instead of paying for weights it may not use.
    public var speculates: Bool
    /// The model may reason before answering. Families whose chat template makes thinking optional (Gemma 4, Qwen3)
    /// read this as `enable_thinking`; one that always reasons ignores it. Off, Gemma 4 does not think at all.
    public var thinks: Bool

    public init(
        messages: [EngineMessage], tools: [ToolSpec] = [], sampling: SamplingParams = .init(), keepAlive: KeepAlive = .default,
        chatID: UUID? = nil, contextTokens: Int? = nil, speculates: Bool = false, thinks: Bool = false
    ) {
        self.messages = messages
        self.tools = tools
        self.sampling = sampling
        self.keepAlive = keepAlive
        self.chatID = chatID
        self.contextTokens = contextTokens
        self.speculates = speculates
        self.thinks = thinks
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
    case finished(FinishReason)
}

public enum EngineError: DescribedError, Equatable, Sendable {
    case noModelLoaded
    case imagesNotSupported
    case loadFailed(String)
    case generationFailed(String)
    case busy
}

// "\(error)" is what the UI shows, so the cases read as sentences instead of enum dumps.
extension EngineError {
    public var description: String {
        switch self {
        case .noModelLoaded: String(localized: "No model is loaded.")
        case .imagesNotSupported: String(localized: "This model does not accept images.")
        case .busy: String(localized: "The model is busy with another request.")
        case .generationFailed(let detail): String(localized: "Generation failed: \(detail)")
        case .loadFailed(let detail):
            // MLX reports a checkpoint/architecture mismatch as keyNotFound(path: [...]) for the first missing weight.
            detail.contains("keyNotFound")
                ? String(
                    localized:
                        "This build of the model cannot be loaded: its weight files do not match what the current MLX engine expects. Try another conversion of the same model (another author or quantization). Details: \(detail)"
                )
                : String(localized: "The model could not be loaded: \(detail)")
        }
    }
}

/// Inference engine. Implementation: `MLXEngine` (Engine/); a llama.cpp engine may be added behind the same protocol.
/// An engine holds at most one model.
public protocol InferenceEngine: Actor {
    var loadedModel: ModelDescriptor? { get }
    /// `progress` is 0...1 and may be called from any context.
    func load(_ model: ModelDescriptor, progress: @Sendable @escaping (Double) -> Void) async throws
    func unload() async
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
    func cancelCurrent() async
}

// Generation stream scaffolding

/// The generation task an engine currently runs. Engines are actors and cannot share a base class, so each holds
/// one of these and `AsyncThrowingStream.engine` installs the task into it; `cancelCurrent`/`unload` cancel through it.
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
    /// A stream that has already failed: what `generate` returns when nothing is loaded.
    static func failed(_ error: Error) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = makeStream(of: GenerationEvent.self)
        continuation.finish(throwing: error)
        return stream
    }

    /// Shared scaffolding of the engines' `generate`: the body runs on a task (installed into `current`, if given, so
    /// `cancelCurrent`/`unload` reach it), cancellation becomes `.finished(.cancelled)`, a normal return finishes the
    /// stream, and a consumer walking away cancels the task.
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

/// Owns the single engine and its single loaded model: serializes generations, unloads on idle,
/// and publishes `EngineState` for every indicator.
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
    /// Generation queue: each request waits for the previous one.
    private var queueTail: Task<Void, Never>?
    /// Task is a value type, so the slot carries the generation as its identity.
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

    /// State stream; the current state is delivered first.
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

    /// Loads the model unless already loaded; concurrent calls for the same model await the same task.
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

    /// Prewarm: start loading without waiting.
    public func prewarm(_ model: ModelDescriptor) {
        Task { try? await ensureLoaded(model) }
    }

    public func unload() async {
        idleTask?.cancel()
        idleTask = nil
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

    /// Loads the model if needed and enqueues the generation; events arrive as a stream.
    public func generate(model: ModelDescriptor, request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        let previous = queueTail
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self else { continuation.finish(throwing: CancellationError()); return }
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
        applyKeepAlivePolicy(request.keepAlive)
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
        finishGeneration(model: model, keepAlive: request.keepAlive)
    }

    private func applyKeepAlivePolicy(_ keepAlive: KeepAlive) {
        if case .forever = keepAlive { keepForever = true }
    }

    private func finishGeneration(model: ModelDescriptor, keepAlive: KeepAlive) {
        switch keepAlive {
        case .unloadNow:
            Task { await unload() }
        case .forever:
            keepForever = true
            state = .ready(modelID: model.id)
        case .seconds(let s):
            keepForever = false
            state = .ready(modelID: model.id)
            scheduleIdleUnload(after: s)
        case .default:
            state = .ready(modelID: model.id)
            scheduleIdleUnload()
        }
    }

    public func cancelCurrent() async {
        await engine.cancelCurrent()
    }
}
