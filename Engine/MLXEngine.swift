//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

// Written against mlx-swift-lm 3.31.4 sources (ModelContainer.prepare/generate, UserInput(chat:), Generation, ToolCall).
// Not compiled yet: the first Mac build may still surface small mismatches.

/// MLX inference engine. In-process, one model; generations are serialized by `EngineManager`.
public actor MLXEngine: InferenceEngine {
    public private(set) var loadedModel: ModelDescriptor?
    private var container: ModelContainer?
    private var currentTask: Task<Void, Never>?
    /// The model's cache after the last generation, reused when the next prompt continues it (see `PromptSession`).
    private var session: PromptSession?
    /// Off switch for cache reuse. Symptom of a cache gone wrong: after tool rounds (not in the first round) the answer turns
    /// incoherent, repeats itself or loses the question, while the same chat regenerated with this off is fine.
    private static let reusesPromptCache = true
    /// Metal buffer cache limit after generation (bytes); nil keeps the MLX default.
    private let cacheLimitBytes: Int?
    private let imageResize = CGSize(width: 1024, height: 1024)

    public init(cacheLimitBytes: Int? = 512 * 1024 * 1024) {
        self.cacheLimitBytes = cacheLimitBytes
    }

    /// Bytes the GPU may reasonably wire; feeds `HardwareProfile.wiredLimitBytes`.
    public nonisolated static func recommendedWorkingSetBytes() -> Int? {
        GPU.maxRecommendedWorkingSetBytes()
    }

    // Load / unload

    public func load(_ model: ModelDescriptor, progress: @Sendable @escaping (Double) -> Void) async throws {
        if loadedModel?.id == model.id, container != nil { return }
        await unload()
        progress(0)
        let tokenizerLoader = LocalTokenizerLoader()
        do {
            // Local weights only: no Downloader involved, hence no fine-grained progress.
            let loaded: ModelContainer =
                switch model.kind {
                case .llm: try await LLMModelFactory.shared.loadContainer(from: model.directory, using: tokenizerLoader)
                case .vlm: try await VLMModelFactory.shared.loadContainer(from: model.directory, using: tokenizerLoader)
                }
            if let cacheLimitBytes { Memory.cacheLimit = cacheLimitBytes }
            container = loaded
            loadedModel = model
            progress(1)
        } catch {
            throw EngineError.loadFailed(String(describing: error))
        }
    }

    public func unload() async {
        currentTask?.cancel()
        currentTask = nil
        container = nil
        loadedModel = nil
        session = nil
        Memory.clearCache()  // release Metal buffers so memory actually returns to the system
    }

    public func cancelCurrent() async {
        currentTask?.cancel()
    }

    // Generate

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        guard let container, let model = loadedModel else {
            continuation.finish(throwing: EngineError.noModelLoaded)
            return stream
        }
        if model.kind == .llm, request.messages.contains(where: { !$0.images.isEmpty }) {
            continuation.finish(throwing: EngineError.imagesNotSupported)
            return stream
        }
        let parameters = GenerateParameters(
            maxTokens: request.sampling.maxTokens,
            maxKVSize: request.contextTokens,  // rotating KV cache: memory stays bounded by the chosen context window
            temperature: Float(request.sampling.temperature),
            topP: Float(request.sampling.topP),
            repetitionPenalty: request.sampling.repetitionPenalty.map(Float.init),
            seed: request.sampling.seed
        )
        let resize = imageResize
        let task = Task {
            do {
                let userInput = try Self.makeUserInput(request, resize: resize)
                let input = try await container.prepare(input: userInput)
                // Some templates open the reasoning block in the prompt itself (`…assistant\n<think>\n`), so the reply
                // carries only the closing tag. Re-open it in the stream, so the transcript hides the reasoning while it is written.
                let promptTail = input.text.tokens.asArray(Int32.self).suffix(8).map(Int.init)
                let promptEnd = await container.perform(values: promptTail) { context, ids in
                    context.tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
                }
                let trimmedEnd = promptEnd.trimmingCharacters(in: .whitespacesAndNewlines)
                if let block = AnswerText.reasoningBlocks.first(where: { trimmedEnd.hasSuffix($0.open) }) {
                    continuation.yield(.token(block.open))
                }
                // Only the part of the prompt the cache does not hold yet is prefilled (the tool result of the next round,
                // the next question). Images are always prefilled whole: a cached prefix cannot carry them.
                let promptTokens = input.text.tokens.asArray(Int32.self).map(Int.init)
                let reusable = Self.reusesPromptCache && input.image == nil && input.video == nil && input.audio == nil
                let previous = reusable ? self.session : nil
                self.session = nil  // owned by this generation until it ends; a failure leaves none
                let run = try await container.perform(nonSendable: input) { context, input in
                    try Self.start(input: input, promptTokens: promptTokens, previous: previous, parameters: parameters, context: context)
                }
                let generation = run.stream
                var finish: FinishReason = .stop
                var sawToolCall = false
                for await item in generation {
                    if Task.isCancelled { finish = .cancelled; break }
                    switch item {
                    case .chunk(let text):
                        continuation.yield(.token(text))
                    case .toolCall(let call):
                        sawToolCall = true
                        continuation.yield(.toolCall(Self.convert(call)))
                    case .info(let info):
                        continuation.yield(
                            .usage(
                                GenerationUsage(
                                    promptTokens: info.promptTokenCount,
                                    completionTokens: info.generationTokenCount,
                                    tokensPerSecond: info.tokensPerSecond,
                                    promptSeconds: info.promptTime,
                                    generationSeconds: info.generateTime
                                )))
                        // Plain `default`: mlx-swift-lm is tracked on `main`, and in Swift 6 mode `@unknown default` still
                        // demands every known case, so each case the library adds would break the build.
                        switch info.stopReason {
                        case .length: finish = .length
                        case .cancelled: finish = .cancelled
                        default: break
                        }
                    default:
                        // Event kinds added after this was written (none of them carries answer text we rely on) are ignored.
                        break
                    }
                }
                if sawToolCall, finish == .stop { finish = .toolCalls }
                // The loop may still be stepping after a cancel: the cache is read only once it has stopped.
                run.loop.cancel()
                await run.loop.value
                if reusable { self.session = run.session.completed(with: run.recorder.tokens) }
                continuation.yield(.finished(finish))
                continuation.finish()
            } catch is CancellationError {
                continuation.yield(.finished(.cancelled))
                continuation.finish()
            } catch {
                continuation.finish(throwing: EngineError.generationFailed(String(describing: error)))
            }
        }
        currentTask = task
        continuation.onTermination = { t in if case .cancelled = t { task.cancel() } }
        return stream
    }

    // Conversion

    // Prompt cache reuse

    /// A generation under way: its stream, the loop feeding it, and what the cache will hold when it ends.
    private struct Run: Sendable {
        let stream: AsyncStream<Generation>
        let loop: Task<Void, Never>
        let recorder: TokenRecorder
        let session: PromptSession
    }

    /// Picks what to prefill: the suffix after a reused prefix, or the whole prompt on a fresh cache. Runs inside
    /// `perform`, i.e. with the model to itself for the prefill.
    private static func start(
        input: LMInput, promptTokens: [Int], previous: PromptSession?, parameters: GenerateParameters, context: ModelContext
    ) throws -> Run {
        var cache: [KVCache]
        var state: LMOutput.State?
        var kept = 0
        if let previous, let reuse = previous.reusablePrefix(for: promptTokens) {
            (cache, state, kept) = (previous.cache, previous.state, reuse)
            // Trimming must leave the carried state valid too. Qwen-VL keeps its rope anchor offset-relative, so it survives;
            // a model storing absolute positions would misplace the suffix (garbled text right after the reused part).
            let surplus = previous.tokens.count - reuse
            if surplus > 0 { trimPromptCache(cache, numTokens: surplus) }
        } else {
            cache = try context.model.newCache(parameters: parameters)
        }
        let suffix = kept > 0 ? LMInput(tokens: MLXArray(promptTokens[kept...].map(Int32.init))) : input
        let iterator = try TokenIterator(input: suffix, model: context.model, cache: cache, state: state, parameters: parameters)
        // Read right after the prefill, as mlx-swift-lm's ChatSession does: models that anchor positions (Qwen-VL rope
        // deltas) need it to continue on this cache next time. Losing it fails loudly: `ContinuationStateError.missingState`.
        state = iterator.state
        let recorder = TokenRecorder()
        let (stream, loop) = generateTask(
            promptTokenCount: promptTokens.count - kept, modelConfiguration: context.configuration, tokenizer: context.tokenizer,
            iterator: RecordingTokenIterator(base: iterator, recorder: recorder))
        return Run(stream: stream, loop: loop, recorder: recorder, session: PromptSession(cache: cache, state: state, tokens: promptTokens))
    }

    private static func makeUserInput(_ request: GenerationRequest, resize: CGSize) throws -> UserInput {
        var chat: [MLXLMCommon.Chat.Message] = []
        for m in request.messages {
            let images: [UserInput.Image] = try m.images.map { img in
                guard let ci = CIImage(data: img.data) else { throw EngineError.generationFailed("bad image data") }
                return .ciImage(ci)
            }
            switch m.role {
            case .system: chat.append(.system(m.content))
            case .user: chat.append(.user(m.content, images: images))
            case .assistant:
                let calls = m.toolCalls.map { Self.convert($0) }
                chat.append(.assistant(m.content, toolCalls: calls.isEmpty ? nil : calls))
            case .tool: chat.append(.tool(m.content, id: m.toolCallID))
            }
        }
        let tools: [MLXLMCommon.ToolSpec]? =
            request.tools.isEmpty
            ? nil
            : request.tools.map { spec in
                // ToolSpec is [String: any Sendable]; decode the schema through JSONValue and convert to plain Sendable values.
                let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(spec.parametersJSONSchema.utf8))
                let params = decoded.map(Self.sendable) as? [String: any Sendable] ?? [:]
                return [
                    "type": "function",
                    "function": [
                        "name": spec.name,
                        "description": spec.description,
                        "parameters": params,
                    ] as [String: any Sendable],
                ] as [String: any Sendable]
            }
        return UserInput(chat: chat, processing: .init(resize: resize), tools: tools)
    }

    /// Plain Sendable representation of a JSONValue tree (String/Int/Double/Bool/arrays/dictionaries).
    private static func sendable(_ value: JSONValue) -> any Sendable {
        switch value {
        case .null: return Optional<String>.none as any Sendable
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { sendable($0) }
        case .object(let o): return o.mapValues { sendable($0) }
        }
    }

    // Unqualified ToolCall is ours: current-module declarations shadow the imported MLXLMCommon.ToolCall.
    private static func convert(_ call: MLXLMCommon.ToolCall) -> ToolCall {
        let dict = call.function.arguments.mapValues { $0.anyValue }
        let args = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolCall(id: call.id ?? "call_\(UUID().uuidString.prefix(8))", name: call.function.name, argumentsJSON: args)
    }

    private static func convert(_ call: ToolCall) -> MLXLMCommon.ToolCall {
        let dict = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: any Sendable] ?? [:]
        return MLXLMCommon.ToolCall(function: .init(name: call.name, arguments: dict), id: call.id)
    }
}

// PromptSession

/// The model's KV cache and the exact tokens it represents (prompt, then every generated token, each fed back as the
/// next step's input). A new prompt that starts with these tokens only needs its remainder prefilled.
// Ways it can go wrong: the token list drifts from what the cache holds (an iterator in mlx-swift-lm that feeds tokens it
// does not yield, or stops feeding the last one), which `completed` catches through the attention offset; a recurrent
// cache (Mamba) shared by two generations at once, which the `session = nil` hand-over in `generate` prevents; and one
// word of difference from a cold run, which is not an error: chunked prefill rounds differently in a 4-bit model.
private final class PromptSession: @unchecked Sendable {
    let cache: [KVCache]
    let state: LMOutput.State?
    let tokens: [Int]

    init(cache: [KVCache], state: LMOutput.State?, tokens: [Int]) {
        self.cache = cache
        self.state = state
        self.tokens = tokens
    }

    /// How many leading tokens of `prompt` the cache can keep. A cache with recurrent layers (Qwen 3.5/3.6: Mamba-style
    /// state) cannot be rewound, so it is reused only when the prompt continues it exactly; one that can be trimmed keeps
    /// the common prefix. At least one prompt token must be left to prefill.
    func reusablePrefix(for prompt: [Int]) -> Int? {
        var common = 0
        let limit = min(tokens.count, prompt.count - 1)
        while common < limit, tokens[common] == prompt[common] { common += 1 }
        if common == tokens.count { return common }
        return canTrimPromptCache(cache) && common > 0 ? common : nil
    }

    /// The same cache after a generation: the recorded tokens are those it has fed. If the attention layers' offset
    /// says otherwise (a change in mlx-swift-lm), the cache is dropped rather than trusted.
    func completed(with generated: [Int]) -> PromptSession? {
        let all = tokens + generated
        let attention = cache.first { !($0 is ArraysCache) }
        guard attention?.offset == all.count else { return nil }
        return PromptSession(cache: cache, state: state, tokens: all)
    }
}

/// Generated token ids, collected on the generation loop's thread and read after it has stopped.
private final class TokenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    func append(_ token: Int) { lock.withLock { storage.append(token) } }
    var tokens: [Int] { lock.withLock { storage } }
}

/// `TokenIterator` that also records every token it yields (each has been fed to the model by then).
private struct RecordingTokenIterator: TokenIteratorProtocol {
    var base: TokenIterator
    let recorder: TokenRecorder

    var maxTokens: Int? { base.maxTokens }
    var tokenCount: Int { base.tokenCount }
    var promptPrefillTime: TimeInterval { base.promptPrefillTime }
    var state: LMOutput.State? { base.state }
    var speculativeDecodingTelemetry: SpeculativeDecodingTelemetry? { base.speculativeDecodingTelemetry }
    mutating func discardGeneratedToken() { base.discardGeneratedToken() }

    mutating func next() -> Int? {
        let token = base.next()
        if let token { recorder.append(token) }
        return token
    }
}
