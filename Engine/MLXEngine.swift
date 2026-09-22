//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import CoreImage
import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers
import os

// Written against mlx-swift-lm 3.31.4 sources (ModelContainer.prepare/generate, UserInput(chat:), Generation, ToolCall).

/// MLX inference engine. In-process, one model; generations are serialized by `EngineManager`.
public actor MLXEngine: InferenceEngine {
    public private(set) var loadedModel: ModelDescriptor?
    private var container: ModelContainer?
    private let current = GenerationTaskBox()
    /// Caches of recent generations, least recently used first: a prompt that continues one of them (the next turn of
    /// that chat, or of an API client's conversation) prefills only its remainder (see `PromptSession`).
    private var sessions: [PromptSession] = []
    /// Several chats stay warm; the byte budget keeps idle caches from crowding out the model on a small Mac.
    private static let maxSessions = 4
    private static let sessionBudgetBytes = max(1 << 30, (GPU.maxRecommendedWorkingSetBytes() ?? 0) / 6)
    /// Token ids that stand for images in the prompt (from `config.json`); empty when the model does not say, which
    /// keeps image prompts out of cache reuse.
    private var mediaTokenIDs: Set<Int> = []
    /// Off switch for cache reuse. Symptom of a cache gone wrong: after tool rounds (not in the first round) the answer turns
    /// incoherent, repeats itself or loses the question, while the same chat regenerated with this off is fine.
    private static let reusesPromptCache = true
    /// Off switch for multi-token prediction. Drafted tokens are verified by the model itself, so the answer is the
    /// one plain decoding would give; only the speed changes.
    private static let usesSpeculativeDecoding = true
    /// Tokens offered per speculative round (one bonus plus the drafted ones), the library's default; a drafter that
    /// cannot go that wide clamps it.
    private static let speculationBlockSize = 4
    /// What is known about the loaded model's MTP drafter. `greedyOnly` remembers a drafter that was let go because
    /// the request sampled: it is loaded again if a later request is greedy, rather than sitting in memory unused.
    private var drafterState: DrafterState = .unknown
    /// Metal buffer cache kept between generations (bytes); nil keeps the MLX default.
    private let cacheLimitBytes: Int?
    /// MLX's own limit, read before this engine changes it. A generation runs with it: a small cache makes MLX free
    /// and reallocate the prefill's large temporary buffers on every step.
    private let generationCacheLimit: Int

    public init(cacheLimitBytes: Int? = 512 * 1024 * 1024) {
        self.cacheLimitBytes = cacheLimitBytes
        self.generationCacheLimit = Memory.cacheLimit
    }

    /// The buffer cache is large only while a generation runs; after it the surplus goes back to the system.
    private func setGenerating(_ generating: Bool) {
        guard let idle = cacheLimitBytes else { return }
        Memory.cacheLimit = generating ? generationCacheLimit : idle
        if !generating, Memory.cacheMemory > idle { Memory.clearCache() }
    }

    /// What MLX samples with when neither the request nor the checkpoint says: shown in the models list as the default.
    public nonisolated static var librarySampling: SamplingParams {
        let p = GenerateParameters()
        return SamplingParams(temperature: Double(p.temperature), topP: Double(p.topP), topK: p.topK, minP: Double(p.minP))
    }

    /// Bytes the GPU may reasonably wire; feeds `HardwareProfile.wiredLimitBytes`.
    public nonisolated static func recommendedWorkingSetBytes() -> Int? {
        GPU.maxRecommendedWorkingSetBytes()
    }

    // Load / unload

    public func load(_ model: ModelDescriptor, progress: @Sendable @escaping (Double) -> Void) async throws {
        if loadedModel?.id == model.id, container != nil { return }
        await unload()
        try Task.checkCancellation()
        progress(0)
        let tokenizerLoader = LocalTokenizerLoader()
        do {
            // Local weights only: no Downloader involved, hence no fine-grained progress.
            let loaded: ModelContainer =
                switch model.kind {
                case .llm: try await LLMModelFactory.shared.loadContainer(from: model.directory, using: tokenizerLoader)
                case .vlm: try await VLMModelFactory.shared.loadContainer(from: model.directory, using: tokenizerLoader)
                }
            // A cancelled load must not publish its container over the one a newer load installs.
            try Task.checkCancellation()
            if let cacheLimitBytes { Memory.cacheLimit = cacheLimitBytes }
            container = loaded
            loadedModel = model
            mediaTokenIDs = Self.mediaTokenIDs(in: model.directory)
            progress(1)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EngineError.loadFailed(String(describing: error))
        }
    }

    public func unload() async {
        current.cancel()
        container = nil
        loadedModel = nil
        sessions = []
        mediaTokenIDs = []
        drafterState = .unknown
        Memory.clearCache()  // release Metal buffers so memory actually returns to the system
    }

    public func cancelCurrent() async {
        current.cancel()
    }

    // Generate

    // The task body mutates actor state (`sessions`, `drafterState`), so unlike the other engines it cannot move into
    // the nonisolated `AsyncThrowingStream.engine` helper: the inline `Task` inherits this actor's isolation.
    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        guard let container, let model = loadedModel else { return .failed(EngineError.noModelLoaded) }
        if model.kind == .llm, request.messages.contains(where: { !$0.images.isEmpty }) {
            return .failed(EngineError.imagesNotSupported)
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        // Only what was asked for is set; the rest stays at mlx-swift-lm's defaults.
        let s = request.sampling
        // Rotating KV cache: memory stays bounded by the chosen context window.
        var parameters = GenerateParameters(maxTokens: s.maxTokens, maxKVSize: request.contextTokens)
        if let v = s.temperature { parameters.temperature = Float(v) }
        if let v = s.topP { parameters.topP = Float(v) }
        if let v = s.topK { parameters.topK = v }
        if let v = s.minP { parameters.minP = Float(v) }
        parameters.repetitionPenalty = s.repetitionPenalty.map(Float.init)
        parameters.presencePenalty = s.presencePenalty.map(Float.init)
        parameters.frequencyPenalty = s.frequencyPenalty.map(Float.init)
        parameters.seed = s.seed
        let temperature = Double(parameters.temperature)
        let generateParameters = parameters
        let task = Task {
            self.setGenerating(true)
            defer { self.setGenerating(false) }
            do {
                let userInput = try Self.makeUserInput(request)
                let input = try await container.prepare(input: userInput)
                let promptTokens = input.text.tokens.asArray(Int32.self).map(Int.init)
                if request.rejectsLongPrompt, let limit = request.contextTokens, promptTokens.count >= limit {
                    throw EngineError.promptTooLong(tokens: promptTokens.count, limit: limit)
                }
                // Some templates open the reasoning block in the prompt itself (`…assistant\n<think>\n`), so the reply
                // carries only the closing tag. Re-open it in the stream, so the transcript hides the reasoning while it is written.
                let promptTail = Array(promptTokens.suffix(8))
                let promptEnd = await container.perform(values: promptTail) { context, ids in
                    context.tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
                }
                let trimmedEnd = promptEnd.trimmingCharacters(in: .whitespacesAndNewlines)
                if let block = AnswerText.reasoningBlocks.first(where: { trimmedEnd.hasSuffix($0.open) }) {
                    continuation.yield(.token(block.open))
                }
                // Only the part of the prompt the cache does not hold yet is prefilled (the tool result of the next round,
                // the next question). A cache holding images is reused only for the same images, and only when every
                // image token lies in the reused part: the text-only remainder cannot carry pixels.
                let images = PromptSession.imageKeys(request)
                let reusable = Self.reusesPromptCache && input.video == nil && input.audio == nil
                let previous = reusable ? self.takeSession(for: promptTokens, images: images) : nil
                let drafter = request.speculates ? await self.drafter(temperature: temperature) : nil
                let run = try await container.perform(nonSendable: StartInput(input: input, drafter: drafter)) { context, start in
                    try Self.start(
                        input: start.input, promptTokens: promptTokens, images: images, previous: previous, parameters: generateParameters,
                        context: context, drafter: start.drafter?.model)
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
                        if drafter != nil { Self.logSpeculation(info) }
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
                if reusable, let done = run.session.completed(with: run.recorder.tokens) { self.keep(done) }
                continuation.yield(.finished(finish))
                continuation.finish()
            } catch is CancellationError {
                continuation.yield(.finished(.cancelled))
                continuation.finish()
            } catch {
                continuation.finish(throwing: EngineError.generationFailed(String(describing: error)))
            }
        }
        current.install(task)
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

    /// The prompt and, when the checkpoint has MTP heads, the drafter: neither MLX object is `Sendable`, so they cross
    /// into the model's isolation together.
    private struct StartInput {
        let input: LMInput
        let drafter: DrafterBox?
    }

    /// The drafter is kept with the model in this actor and used inside the model's isolation. Generations are
    /// serialized by `EngineManager`, so the reference crosses once per generation and is touched nowhere else —
    /// stated here the way mlx-swift-lm's own tests state it for drafter models.
    private struct DrafterBox: @unchecked Sendable {
        let model: any MTPDrafterModel
    }

    /// What is known about this model's drafter; see `drafterState`.
    private enum DrafterState {
        case unknown
        case none
        case loaded(any MTPDrafterModel)
        case greedyOnly
    }

    /// The drafter to speculate with, loaded on the first generation of a model that has MTP heads and kept with it.
    /// A drafter that insists on greedy decoding is let go while the request samples — it would only hold memory.
    private func drafter(temperature: Double) async -> DrafterBox? {
        guard Self.usesSpeculativeDecoding, let model = loadedModel else { return nil }
        switch drafterState {
        case .none: return nil
        case .greedyOnly where temperature != 0: return nil
        case .unknown, .greedyOnly:
            guard let loaded = await MTPDrafter.load(modelDirectory: model.directory) else {
                drafterState = .none
                return nil
            }
            drafterState = .loaded(loaded)
            return self.drafter(loaded, temperature: temperature)
        case .loaded(let loaded):
            return self.drafter(loaded, temperature: temperature)
        }
    }

    private func drafter(_ loaded: any MTPDrafterModel, temperature: Double) -> DrafterBox? {
        guard loaded.requiresGreedySampling, temperature != 0 else { return DrafterBox(model: loaded) }
        MTPDrafter.logger.info("drafter set aside: it needs greedy decoding, this request samples at \(temperature)")
        drafterState = .greedyOnly
        return nil
    }

    /// Whether the drafting actually paid off, from the library's own counters: the one honest answer to "is MTP on".
    private static func logSpeculation(_ info: GenerateCompletionInfo) {
        if let reason = info.passthroughReason {
            MTPDrafter.logger.notice("speculation stopped: \(reason, privacy: .public)")
            return
        }
        let proposed = info.proposedDraftTokens ?? 0
        let accepted = info.acceptedDraftTokens ?? 0
        MTPDrafter.logger.info(
            "speculation: \(accepted) of \(proposed) drafted tokens accepted, \(info.generationTokenCount) generated at \(Int(info.tokensPerSecond)) tok/s"
        )
    }

    /// Picks what to prefill: the suffix after a reused prefix, or the whole prompt on a fresh cache, and how to
    /// decode it. Runs inside `perform`, i.e. with the model to itself for the prefill.
    private static func start(
        input: LMInput, promptTokens: [Int], images: [String], previous: (session: PromptSession, reuse: Int)?,
        parameters: GenerateParameters, context: ModelContext, drafter: (any MTPDrafterModel)?
    ) throws -> Run {
        var cache: [KVCache]
        var state: LMOutput.State?
        var kept = 0
        if let (previous, reuse) = previous {
            (cache, state, kept) = (previous.cache, previous.state, reuse)
            // Trimming must leave the carried state valid too. Qwen-VL keeps its rope anchor offset-relative, so it survives;
            // a model storing absolute positions would misplace the suffix (garbled text right after the reused part).
            let surplus = previous.tokens.count - reuse
            if surplus > 0 { trimPromptCache(cache, numTokens: surplus) }
        } else {
            cache = try context.model.newCache(parameters: parameters)
        }
        let suffix = kept > 0 ? LMInput(tokens: MLXArray(promptTokens[kept...].map(Int32.init))) : input
        let recorder = TokenRecorder()
        let prefill = promptTokens.count - kept
        // Speculation has nowhere to put a carried state, so a cache that needs one (Qwen-VL rope anchors) keeps the
        // plain path: reusing that cache saves more than drafting would.
        if let drafter, state == nil {
            let iterator = try MTPSpeculativeTokenIterator(
                input: suffix, mainModel: context.model, drafter: drafter, mainCache: cache, parameters: parameters,
                blockSize: speculationBlockSize)
            let (stream, loop) = generateTask(
                promptTokenCount: prefill, modelConfiguration: context.configuration, tokenizer: context.tokenizer,
                iterator: RecordingTokenIterator(base: iterator, recorder: recorder))
            return Run(
                stream: stream, loop: loop, recorder: recorder,
                session: PromptSession(cache: cache, state: iterator.state, tokens: promptTokens, images: images))
        }
        let iterator = try TokenIterator(input: suffix, model: context.model, cache: cache, state: state, parameters: parameters)
        // Read right after the prefill, as mlx-swift-lm's ChatSession does: models that anchor positions (Qwen-VL rope
        // deltas) need it to continue on this cache next time. Losing it fails loudly: `ContinuationStateError.missingState`.
        state = iterator.state
        let (stream, loop) = generateTask(
            promptTokenCount: prefill, modelConfiguration: context.configuration, tokenizer: context.tokenizer,
            iterator: RecordingTokenIterator(base: iterator, recorder: recorder))
        return Run(
            stream: stream, loop: loop, recorder: recorder,
            session: PromptSession(cache: cache, state: state, tokens: promptTokens, images: images))
    }

    // Prompt cache pool

    /// Takes the cache this prompt can continue out of the pool (it is this generation's until it ends; a failure
    /// leaves none). The next turn of a conversation covers that cache's whole prompt; a cache from another chat that
    /// shares only the system prompt is not cut down for it while the pool has room, since that chat will be back.
    private func takeSession(for prompt: [Int], images: [String]) -> (session: PromptSession, reuse: Int)? {
        let full = sessions.count >= Self.maxSessions
        var best: (index: Int, reuse: Int)?
        for (index, session) in sessions.enumerated() {
            guard session.images == images, let reuse = session.reusablePrefix(for: prompt) else { continue }
            if !images.isEmpty, prompt[reuse...].contains(where: mediaTokenIDs.contains) || mediaTokenIDs.isEmpty { continue }
            let continues = reuse >= session.promptCount || reuse * 2 >= session.tokens.count
            guard continues || (full && index == 0) else { continue }
            if reuse > (best?.reuse ?? 0) { best = (index, reuse) }
        }
        guard let best else { return nil }
        return (sessions.remove(at: best.index), best.reuse)
    }

    /// Adds a finished generation's cache as the most recent, evicting the least recent past the count or byte budget.
    private func keep(_ session: PromptSession) {
        sessions.append(session)
        while sessions.count > Self.maxSessions
            || (sessions.count > 1 && sessions.reduce(0, { $0 + $1.bytes }) > Self.sessionBudgetBytes)
        {
            sessions.removeFirst()
        }
    }

    /// Image, video and audio placeholder ids a VLM's `config.json` declares at its root (`image_token_id`,
    /// `image_token_index`, `boi_token_index`, `vision_start_token_id`…).
    private static func mediaTokenIDs(in directory: URL) -> Set<Int> {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        let media = ["image", "video", "vision", "audio", "boi", "eoi", "boa", "eoa"]
        var ids: Set<Int> = []
        for (key, value) in root where key.hasSuffix("_token_id") || key.hasSuffix("_token_index") || key.hasSuffix("_token_ids") {
            guard media.contains(where: key.contains) else { continue }
            if let id = value as? Int { ids.insert(id) }
            if let list = value as? [Int] { ids.formUnion(list) }
        }
        return ids
    }

    private static func makeUserInput(_ request: GenerationRequest) throws -> UserInput {
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
                let decoded = try? JSONCoding.plainDecoder.decode(JSONValue.self, from: Data(spec.parametersJSONSchema.utf8))
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
        // `enable_thinking` is what a template with optional reasoning reads; Gemma 4 writes no thought channel without
        // it, and one that always reasons ignores the key. No resize: each model's processor scales images to what its
        // vision tower was trained on (Qwen-VL within its pixel budget, Gemma at its fixed size).
        return UserInput(chat: chat, tools: tools, additionalContext: ["enable_thinking": request.thinks])
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
// cache (Mamba) shared by two generations at once, which taking it out of the pool (`takeSession`) prevents; and one
// word of difference from a cold run, which is not an error: chunked prefill rounds differently in a 4-bit model.
private final class PromptSession: @unchecked Sendable {
    let cache: [KVCache]
    let state: LMOutput.State?
    let tokens: [Int]
    /// How many of `tokens` were the prompt; the rest were generated.
    let promptCount: Int
    /// Fingerprints of the images the prompt carried, in order: equal token ids do not mean equal pixels.
    let images: [String]
    /// What the cache holds in memory, counted once the generation has ended: the allocated buffers, not the `state`
    /// slice. Trimming only moves the offset, so a cache cut down for reuse keeps its full-size buffers.
    private(set) lazy var bytes: Int = cache.reduce(0) { total, layer in total + layer.innerState().reduce(0) { $0 + $1.nbytes } }

    init(cache: [KVCache], state: LMOutput.State?, tokens: [Int], promptCount: Int? = nil, images: [String]) {
        self.cache = cache
        self.state = state
        self.tokens = tokens
        self.promptCount = promptCount ?? tokens.count
        self.images = images
    }

    static func imageKeys(_ request: GenerationRequest) -> [String] {
        request.messages.flatMap(\.images).map { SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined() }
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
        return PromptSession(cache: cache, state: state, tokens: all, promptCount: tokens.count, images: images)
    }
}

/// Generated token ids, collected on the generation loop's thread and read after it has stopped.
private final class TokenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    func append(_ token: Int) { lock.withLock { storage.append(token) } }
    var tokens: [Int] { lock.withLock { storage } }
}

/// A token iterator that also records every token it yields (each has been fed to the model by then).
private struct RecordingTokenIterator<Base: TokenIteratorProtocol>: TokenIteratorProtocol {
    var base: Base
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
