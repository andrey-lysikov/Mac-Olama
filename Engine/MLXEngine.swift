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
        // Ollama NVFP4 imports are re-quantized to affine 4-bit on first use (takes minutes for 10B+ models).
        if OllamaImportConverter.needsConversion(model.directory) {
            do {
                try OllamaImportConverter.convert(directory: model.directory) { progress($0 * 0.8) }
            } catch {
                throw EngineError.loadFailed("conversion failed: \(error)")
            }
        }
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
                let generation = try await container.generate(input: input, parameters: parameters)
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
