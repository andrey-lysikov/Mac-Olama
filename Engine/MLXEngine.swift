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

public actor MLXEngine: InferenceEngine {
    public private(set) var loadedModel: ModelDescriptor?
    private var container: ModelContainer?
    private let current = GenerationTaskBox()
    private var sessions: [PromptSession] = []
    private static let maxSessions = 4
    private static let sessionBudgetBytes = max(1 << 30, (GPU.maxRecommendedWorkingSetBytes() ?? 0) / 6)
    private var mediaTokenIDs: Set<Int> = []
    private static let reusesPromptCache = true
    private static let usesSpeculativeDecoding = true
    private static let speculationBlockSize = 4
    private var drafterState: DrafterState = .unknown
    private let cacheLimitBytes: Int?
    private let generationCacheLimit: Int

    public init(cacheLimitBytes: Int? = 512 * 1024 * 1024) {
        self.cacheLimitBytes = cacheLimitBytes
        self.generationCacheLimit = Memory.cacheLimit
    }

    private func setGenerating(_ generating: Bool) {
        guard let idle = cacheLimitBytes else { return }
        Memory.cacheLimit = generating ? generationCacheLimit : idle
        if !generating, Memory.cacheMemory > idle { Memory.clearCache() }
    }

    public nonisolated static var librarySampling: SamplingParams {
        let p = GenerateParameters()
        return SamplingParams(temperature: Double(p.temperature), topP: Double(p.topP), topK: p.topK, minP: Double(p.minP))
    }

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
        let model = try await Self.loadable(model)
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

    private static func loadable(_ model: ModelDescriptor) async throws -> ModelDescriptor {
        guard let config = try? Data(contentsOf: model.directory.appendingPathComponent("config.json")),
            let type = MTPDrafter.modelType(inConfig: config)
        else { return model }
        let llm = await LLMModelFactory.shared.typeRegistry.contains(type)
        let vlm = await VLMModelFactory.shared.typeRegistry.contains(type)
        guard llm || vlm else { throw EngineError.unsupportedArchitecture(type) }
        var model = model
        if model.kind == .vlm, !vlm { model.kind = .llm }
        return model
    }

    public func unload() async {
        current.cancel()
        container = nil
        loadedModel = nil
        sessions = []
        mediaTokenIDs = []
        drafterState = .unknown
        Memory.clearCache()  // return Metal memory to the system
    }

    public func cancelCurrent() async {
        current.cancel()
    }

    // Generate

    // Inline `Task` keeps actor isolation for mutating state.
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
                // Re-open a reasoning block the template opened in the prompt.
                let promptTail = Array(promptTokens.suffix(8))
                let promptEnd = await container.perform(values: promptTail) { context, ids in
                    context.tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
                }
                let trimmedEnd = promptEnd.trimmingCharacters(in: .whitespacesAndNewlines)
                if let block = AnswerText.reasoningBlocks.first(where: { trimmedEnd.hasSuffix($0.open) }) {
                    continuation.yield(.token(block.open))
                }
                // Prefill only the uncached part; image caches reused only for the same images.
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
                // Token count from the loop, four times a second.
                let reporter = Task {
                    var reported = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        let count = run.recorder.count
                        if count != reported {
                            reported = count
                            continuation.yield(.generated(count))
                        }
                    }
                }
                defer { reporter.cancel() }
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
                        // Plain `default` so new library cases do not break the build.
                        switch info.stopReason {
                        case .length: finish = .length
                        case .cancelled: finish = .cancelled
                        default: break
                        }
                    default:
                        // Ignore newer event kinds.
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

    private struct Run: Sendable {
        let stream: AsyncStream<Generation>
        let loop: Task<Void, Never>
        let recorder: TokenRecorder
        let session: PromptSession
    }

    private struct StartInput {
        let input: LMInput
        let drafter: DrafterBox?
    }

    private struct DrafterBox: @unchecked Sendable {
        let model: any MTPDrafterModel
    }

    private enum DrafterState {
        case unknown
        case none
        case loaded(any MTPDrafterModel)
        case greedyOnly
    }

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

    private static func start(
        input: LMInput, promptTokens: [Int], images: [String], previous: (session: PromptSession, reuse: Int)?,
        parameters: GenerateParameters, context: ModelContext, drafter: (any MTPDrafterModel)?
    ) throws -> Run {
        var cache: [KVCache]
        var state: LMOutput.State?
        var kept = 0
        if let (previous, reuse) = previous {
            (cache, state, kept) = (previous.cache, previous.state, reuse)
            // Trim must keep carried state valid (Qwen-VL rope anchor is offset-relative).
            let surplus = previous.tokens.count - reuse
            if surplus > 0 { trimPromptCache(cache, numTokens: surplus) }
        } else {
            cache = try context.model.newCache(parameters: parameters)
        }
        let suffix = kept > 0 ? LMInput(tokens: MLXArray(promptTokens[kept...].map(Int32.init))) : input
        let recorder = TokenRecorder()
        let prefill = promptTokens.count - kept
        // Caches with carried state skip speculation.
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
        // Save continuation state after prefill; missing state fails loudly.
        state = iterator.state
        let (stream, loop) = generateTask(
            promptTokenCount: prefill, modelConfiguration: context.configuration, tokenizer: context.tokenizer,
            iterator: RecordingTokenIterator(base: iterator, recorder: recorder))
        return Run(
            stream: stream, loop: loop, recorder: recorder,
            session: PromptSession(cache: cache, state: state, tokens: promptTokens, images: images))
    }

    // Prompt cache pool

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

    private func keep(_ session: PromptSession) {
        sessions.append(session)
        while sessions.count > Self.maxSessions
            || (sessions.count > 1 && sessions.reduce(0, { $0 + $1.bytes }) > Self.sessionBudgetBytes)
        {
            sessions.removeFirst()
        }
    }

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
                // Decode the tool schema via JSONValue into Sendable values.
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
        // `enable_thinking` for optional reasoning; images are scaled by each model's processor.
        return UserInput(chat: chat, tools: tools, additionalContext: ["enable_thinking": request.thinks])
    }

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

    // Unqualified ToolCall is ours (shadows MLXLMCommon's).
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

// Failure modes: token drift, shared recurrent cache.
private final class PromptSession: @unchecked Sendable {
    let cache: [KVCache]
    let state: LMOutput.State?
    let tokens: [Int]
    let promptCount: Int
    let images: [String]
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

    func reusablePrefix(for prompt: [Int]) -> Int? {
        var common = 0
        let limit = min(tokens.count, prompt.count - 1)
        while common < limit, tokens[common] == prompt[common] { common += 1 }
        if common == tokens.count { return common }
        return canTrimPromptCache(cache) && common > 0 ? common : nil
    }

    func completed(with generated: [Int]) -> PromptSession? {
        let all = tokens + generated
        let attention = cache.first { !($0 is ArraysCache) }
        guard attention?.offset == all.count else { return nil }
        return PromptSession(cache: cache, state: state, tokens: all, promptCount: tokens.count, images: images)
    }
}

private final class TokenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    func append(_ token: Int) { lock.withLock { storage.append(token) } }
    var tokens: [Int] { lock.withLock { storage } }
    var count: Int { lock.withLock { storage.count } }
}

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
