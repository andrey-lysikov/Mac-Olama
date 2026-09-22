//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization

/// Result of probing the configured port before binding.
public enum PortStatus: Sendable, Equatable {
    case free
    case ollama(version: String)
    case occupied
}

/// What the app runs a model with when a client does not say: the context window, the checkpoint's sampling with the
/// temperature chosen in the app, reasoning and MTP, so an API client gets the same model as the chat.
public struct APIModelDefaults: Sendable, Equatable {
    public var contextTokens: Int?
    public var sampling: SamplingParams
    public var thinks: Bool
    public var speculates: Bool

    public init(contextTokens: Int?, sampling: SamplingParams = .init(), thinks: Bool = false, speculates: Bool = false) {
        self.contextTokens = contextTokens
        self.sampling = sampling
        self.thinks = thinks
        self.speculates = speculates
    }
}

/// Local HTTP server exposing Ollama (`/api/*`, primary) and OpenAI (`/v1/*`) compatible endpoints.
/// Stateless: clients send full history; tool calls are returned to the client, not executed here.
/// Models are downloaded and removed in the app only: `pull` and `delete` are refused.
public final class APIServer: Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int
        public var version: String
        /// Requests wait in EngineManager's queue; beyond this many pending, reply 503.
        public var maxQueued: Int
        public var log: (@Sendable (String) -> Void)?

        public init(
            host: String = "127.0.0.1", port: Int = 11434, version: String = "0.1",
            maxQueued: Int = 8, log: (@Sendable (String) -> Void)? = nil
        ) {
            self.host = host
            self.port = port
            self.version = version
            self.maxQueued = maxQueued
            self.log = log
        }
    }

    public let configuration: Configuration
    private let catalog: ModelCatalog
    private let engine: EngineManager
    private let defaults: @Sendable (ModelDescriptor) async -> APIModelDefaults
    private let server: HTTPServer
    private let pending = Mutex(0)

    public init(
        configuration: Configuration, catalog: ModelCatalog, engine: EngineManager,
        defaults: @escaping @Sendable (ModelDescriptor) async -> APIModelDefaults = { APIModelDefaults(contextTokens: $0.contextLength) }
    ) {
        self.configuration = configuration
        self.catalog = catalog
        self.engine = engine
        self.defaults = defaults
        self.server = HTTPServer(configuration: .init(host: configuration.host, port: configuration.port, log: configuration.log))
        registerRoutes()
    }

    // Lifecycle

    /// Checks whether something (Ollama?) already listens on the port. Cheap GET with a short timeout.
    public static func probe(host: String = "127.0.0.1", port: Int) async -> PortStatus {
        guard let url = URL(string: "http://\(host):\(port)/api/version") else { return .free }
        let request = HTTPJSON.request(url, timeout: 1.5, accept: nil, userAgent: nil)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .occupied }
            if http.statusCode == 200, let v = try? JSONCoding.plainDecoder.decode(OllamaVersionResponse.self, from: data),
                !v.version.contains("macolama")
            {
                return .ollama(version: v.version)
            }
            return .occupied
        } catch {
            return .free
        }
    }

    /// Binds the socket and serves on background threads; throws if the port is taken.
    public func start() throws {
        try server.start()
    }

    public func stop() {
        server.stop()
    }

    public var isRunning: Bool { server.isRunning }

    public func setCORSPolicy(_ policy: CORSPolicy) { server.setCORSPolicy(policy) }

    /// For tests/dev: serves until the task is cancelled.
    public func run() async throws {
        try server.start()
        defer { server.stop() }
        while !Task.isCancelled { try await Task.sleep(for: .seconds(1)) }
    }

    // Routes

    private func registerRoutes() {
        server.setErrorMapper { error in
            if let api = error as? APIError { return Self.error(api.status, api.message) }
            return Self.error(Self.status(for: error), "\(error)")
        }
        server.setNotFound { _ in Self.error(404, "not found") }
        server.route("GET", "/") { _ in HTTPResponse.text("Mac-Olama is running") }
        server.route("GET", "/docs") { _ in HTTPResponse.text(Self.docsPage, contentType: "text/html; charset=utf-8") }

        // Ollama
        server.route("GET", "/api/version") { [self] _ in try Self.json(OllamaVersionResponse(version: "\(configuration.version)-macolama"))
        }
        server.route("GET", "/api/tags") { [self] _ in try Self.json(await tags()) }
        server.route("GET", "/api/ps") { [self] _ in try Self.json(await ps()) }
        server.route("POST", "/api/show") { [self] req in try await show(req) }
        server.route("POST", "/api/chat") { [self] req in try await ollamaChat(req) }
        server.route("POST", "/api/generate") { [self] req in try await ollamaGenerate(req) }
        server.route("POST", "/api/pull") { _ in Self.error(403, Self.managedInApp) }
        server.route("DELETE", "/api/delete") { _ in Self.error(403, Self.managedInApp) }
        for path in ["/api/embed", "/api/embeddings"] {
            server.route("POST", path) { _ in Self.error(501, "embeddings are not supported yet") }
        }
        for path in ["/api/create", "/api/push", "/api/copy"] {
            server.route("POST", path) { _ in Self.error(501, "Modelfile operations are not applicable to MLX models") }
        }

        // OpenAI
        server.route("GET", "/v1/models") { [self] _ in try Self.json(await openAIModels()) }
        server.route("POST", "/v1/chat/completions") { [self] req in try await openAIChat(req) }
        server.route("POST", "/v1/completions") { [self] req in try await openAICompletions(req) }
        server.route("POST", "/v1/embeddings") { _ in Self.openAIError(501, "embeddings are not supported yet") }
    }

    // Model listing

    private func resolve(_ ref: String) async throws -> ModelDescriptor {
        guard let model = await catalog.resolve(ref) else { throw APIError(404, "model '\(ref)' not found, try pulling it first") }
        return model
    }

    private static func details(_ m: ModelDescriptor) -> OllamaModelDetails {
        let family = m.name.split(whereSeparator: { "-_.".contains($0) }).first.map(String.init) ?? m.name
        let size = m.name.range(of: #"(\d+(\.\d+)?)b"#, options: .regularExpression).map { String(m.name[$0]).uppercased() } ?? ""
        return OllamaModelDetails(family: family, families: [family], parameter_size: size, quantization_level: m.quantization ?? "")
    }

    private static func digest(_ m: ModelDescriptor) -> String {
        // Stable pseudo-digest from the repo id; clients only use it as an opaque identifier.
        var h: UInt64 = 0xcbf29ce484222325
        for b in m.repoID.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        let digits = String(h, radix: 16)
        return "sha256:" + String(repeating: "0", count: 64 - digits.count) + digits
    }

    private func tags() async -> OllamaTagsResponse {
        let models = await catalog.models.map {
            OllamaModelSummary(
                name: "\($0.name):latest", model: "\($0.name):latest", modified_at: $0.downloadedAt,
                size: $0.sizeBytes, digest: Self.digest($0), details: Self.details($0))
        }
        return OllamaTagsResponse(models: models)
    }

    private func ps() async -> OllamaPsResponse {
        guard let m = await engine.loadedModel else { return OllamaPsResponse(models: []) }
        let idle = await engine.configuration.idleUnloadSeconds
        return OllamaPsResponse(models: [
            OllamaRunningModel(
                name: "\(m.name):latest", model: "\(m.name):latest", size: m.sizeBytes, digest: Self.digest(m),
                details: Self.details(m), expires_at: idle > 0 ? Date().addingTimeInterval(idle) : nil, size_vram: m.sizeBytes)
        ])
    }

    private func show(_ req: HTTPRequest) async throws -> HTTPResponse {
        let body = try req.decode(OllamaShowRequest.self)
        guard let ref = body.ref else { return Self.error(400, "model is required") }
        let m = try await resolve(ref)
        var caps = ["completion"]
        if m.kind == .vlm { caps.append("vision") }
        if m.supportsTools { caps.append("tools") }
        var info: [String: JSON] = [
            "general.architecture": .string(Self.details(m).family), "general.file_type": .string(m.quantization ?? ""),
        ]
        if let ctx = m.contextLength { info["\(Self.details(m).family).context_length"] = .number(Double(ctx)) }
        return try Self.json(
            OllamaShowResponse(
                modelfile: "# MLX model managed by Mac-Olama\nFROM \(m.repoID)\n", parameters: "", template: "",
                details: Self.details(m), model_info: info, capabilities: caps, modified_at: m.downloadedAt
            ))
    }

    private func openAIModels() async -> OpenAIModelList {
        OpenAIModelList(
            data: await catalog.models.map {
                OpenAIModelList.Model(id: $0.name, created: Int($0.downloadedAt.timeIntervalSince1970))
            })
    }

    // Request building

    static let managedInApp = "models are downloaded and removed in the Mac-Olama app"
    /// The window of a model whose config does not say, as the chat assumes too.
    private static let fallbackContext = 8192

    /// The request the chat would make for this model, with what the client asked for on top. A client's `num_ctx`
    /// may move the window up to the model's limit; a prompt that does not fit fails instead of losing its beginning.
    private func generationRequest(
        model: ModelDescriptor, messages: [EngineMessage], tools: [ToolSpec] = [],
        sampling: (SamplingParams) -> SamplingParams, thinks: Bool?, contextTokens: Int?, keepAlive: KeepAlive = .default,
        jsonFormat: JSON?
    ) async -> GenerationRequest {
        let chosen = await defaults(model)
        let modelMax = model.contextLength ?? chosen.contextTokens ?? Self.fallbackContext
        return GenerationRequest(
            messages: jsonFormat.map { Self.withJSONInstruction(messages, schema: $0) } ?? messages, tools: tools,
            sampling: sampling(chosen.sampling), keepAlive: keepAlive,
            contextTokens: min(contextTokens ?? chosen.contextTokens ?? modelMax, modelMax),
            speculates: chosen.speculates, thinks: thinks ?? chosen.thinks, rejectsLongPrompt: true)
    }

    /// MLX here has no constrained decoding: the model is told to answer in JSON, and the reply is cut to the value.
    static func withJSONInstruction(_ messages: [EngineMessage], schema: JSON) -> [EngineMessage] {
        var instruction = "Reply with one valid JSON value and nothing else: no explanations, no Markdown code fences."
        if case .object(let fields) = schema, !fields.isEmpty {
            instruction += " The JSON must match this schema: \(schema.jsonString())"
        }
        var out = messages
        // Some templates accept a system message only in the first place, so the instruction joins the existing one.
        if let i = out.firstIndex(where: { $0.role == .system }) {
            out[i].content += "\n\n" + instruction
        } else {
            out.insert(EngineMessage(role: .system, content: instruction), at: 0)
        }
        return out
    }

    /// Ollama's `format`: `"json"` or a schema object.
    static func ollamaJSONFormat(_ format: JSON?) -> JSON? {
        switch format {
        case .string(let s) where s.lowercased() == "json": .object([:])
        case .object(let schema): .object(schema)
        default: nil
        }
    }

    // Chat (Ollama)

    private func ollamaChat(_ req: HTTPRequest) async throws -> HTTPResponse {
        let body = try req.decode(OllamaChatRequest.self)
        let model = try await resolve(body.model)
        let messages = try body.messages.map { try Self.convert($0) }
        if model.kind == .llm, messages.contains(where: { !$0.images.isEmpty }) {
            return Self.error(400, "model '\(body.model)' does not support images")
        }
        let options = body.options ?? .init()
        let format = Self.ollamaJSONFormat(body.format)
        let request = await generationRequest(
            model: model, messages: messages, tools: Self.toolSpecs(body.tools), sampling: { options.sampling(default: $0) },
            thinks: body.think?.thinkFlag, contextTokens: options.num_ctx, keepAlive: body.keep_alive?.keepAlive ?? .default,
            jsonFormat: format)
        let reply = Reply(stops: options.stop ?? [], json: format != nil)
        let modelName = body.model
        let start = ContinuousClock.now
        try admit()

        if body.stream == false {
            defer { release() }
            let result = try await generate(model: model, request: request, reply: reply)
            return try Self.json(
                OllamaChatChunk(
                    model: modelName, message: Self.ollamaMessage(result), done_reason: result.finish.rawValue,
                    timings: .init(start: start, usage: result.usage)))
        }

        return Self.ndjson { [self] write in
            defer { release() }
            let result: Collected
            do {
                result = try await generate(model: model, request: request, reply: reply) { delta in
                    try write(
                        OllamaChatChunk(
                            model: modelName, created_at: .now,
                            message: OllamaMessage(role: "assistant", content: delta.content, thinking: delta.reasoning.nilIfEmpty),
                            done: false))
                }
            } catch {
                try write(APIErrorBody(error: "\(error)"))
                return
            }
            try write(
                OllamaChatChunk(
                    model: modelName,
                    message: OllamaMessage(role: "assistant", content: "", tool_calls: Self.ollamaCalls(result.toolCalls)),
                    done_reason: result.finish.rawValue, timings: .init(start: start, usage: result.usage)))
        }
    }

    private static func ollamaMessage(_ result: Collected) -> OllamaMessage {
        OllamaMessage(
            role: "assistant", content: result.content, thinking: result.reasoning.nilIfEmpty, tool_calls: ollamaCalls(result.toolCalls))
    }

    private func ollamaGenerate(_ req: HTTPRequest) async throws -> HTTPResponse {
        let body = try req.decode(OllamaGenerateRequest.self)
        let model = try await resolve(body.model)
        var messages: [EngineMessage] = []
        if let system = body.system, !system.isEmpty { messages.append(EngineMessage(role: .system, content: system)) }
        let images = try (body.images ?? []).map { try Self.decodeImage($0) }
        messages.append(EngineMessage(role: .user, content: body.prompt ?? "", images: images))
        let options = body.options ?? .init()
        let format = Self.ollamaJSONFormat(body.format)
        let request = await generationRequest(
            model: model, messages: messages, sampling: { options.sampling(default: $0) }, thinks: body.think?.thinkFlag,
            contextTokens: options.num_ctx, keepAlive: body.keep_alive?.keepAlive ?? .default, jsonFormat: format)
        let reply = Reply(stops: options.stop ?? [], json: format != nil)
        let modelName = body.model
        let start = ContinuousClock.now
        try admit()

        // Empty prompt = load/unload only (Ollama semantics).
        if (body.prompt ?? "").isEmpty {
            defer { release() }
            if case .unloadNow = request.keepAlive { await engine.unload() } else { try await engine.ensureLoaded(model) }
            return try Self.json(OllamaGenerateChunk(model: modelName, created_at: .now, response: "", done: true, done_reason: "load"))
        }

        if body.stream == false {
            defer { release() }
            let result = try await generate(model: model, request: request, reply: reply)
            return try Self.json(
                OllamaGenerateChunk(
                    model: modelName, response: result.content, thinking: result.reasoning.nilIfEmpty,
                    done_reason: result.finish.rawValue, timings: .init(start: start, usage: result.usage)))
        }
        return Self.ndjson { [self] write in
            defer { release() }
            let result: Collected
            do {
                result = try await generate(model: model, request: request, reply: reply) { delta in
                    try write(
                        OllamaGenerateChunk(
                            model: modelName, created_at: .now, response: delta.content, thinking: delta.reasoning.nilIfEmpty,
                            done: false))
                }
            } catch {
                try write(APIErrorBody(error: "\(error)"))
                return
            }
            try write(
                OllamaGenerateChunk(
                    model: modelName, response: "", done_reason: result.finish.rawValue,
                    timings: .init(start: start, usage: result.usage)))
        }
    }

    // Chat (OpenAI)

    private func openAIChat(_ req: HTTPRequest) async throws -> HTTPResponse {
        let body: OpenAIChatRequest
        do { body = try req.decode(OpenAIChatRequest.self) } catch {
            return Self.openAIError(400, "invalid request: \(error)")
        }
        guard let model = await catalog.resolve(body.model) else { return Self.openAIError(404, "model '\(body.model)' not found") }
        let messages: [EngineMessage]
        do { messages = try body.messages.map { try Self.convert($0) } } catch { return Self.openAIError(400, "\(error)") }
        if model.kind == .llm, messages.contains(where: { !$0.images.isEmpty }) {
            return Self.openAIError(400, "model '\(body.model)' does not support images")
        }
        let request = await generationRequest(
            model: model, messages: messages, tools: Self.toolSpecs(body.tools), sampling: { body.sampling(default: $0) },
            thinks: body.thinks, contextTokens: nil, jsonFormat: body.jsonFormat)
        let reply = Reply(stops: body.stop?.strings ?? [], json: body.jsonFormat != nil)
        let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
        let created = Int(Date().timeIntervalSince1970)
        let modelName = body.model
        try admit()

        if body.stream != true {
            defer { release() }
            let result: Collected
            do { result = try await generate(model: model, request: request, reply: reply) } catch {
                return Self.openAIError(Self.status(for: error), "\(error)")
            }
            let calls = Self.openAICalls(result.toolCalls)
            return try Self.json(
                OpenAIChatResponse(
                    id: id, created: created, model: modelName,
                    choices: [
                        .init(
                            index: 0,
                            message: OpenAIMessage(
                                role: "assistant", content: .text(result.content), tool_calls: calls.isEmpty ? nil : calls,
                                reasoning_content: result.reasoning.nilIfEmpty),
                            finish_reason: Self.openAIFinish(result, hasCalls: !calls.isEmpty))
                    ],
                    usage: Self.usage(result.usage)
                ))
        }
        let includeUsage = body.stream_options?.include_usage ?? false
        return Self.sse { [self] write in
            defer { release() }
            try write(
                OpenAIChatChunk(
                    id: id, created: created, model: modelName,
                    choices: [.init(index: 0, delta: .init(role: "assistant", content: ""), finish_reason: nil)]))
            let result: Collected
            do {
                result = try await generate(model: model, request: request, reply: reply) { delta in
                    try write(
                        OpenAIChatChunk(
                            id: id, created: created, model: modelName,
                            choices: [
                                .init(
                                    index: 0,
                                    delta: .init(content: delta.content.nilIfEmpty, reasoning_content: delta.reasoning.nilIfEmpty),
                                    finish_reason: nil)
                            ]))
                }
            } catch {
                try write(OpenAIErrorBody(error: .init(message: "\(error)", type: "server_error")))
                return
            }
            let oaCalls = Self.openAICalls(result.toolCalls)
            if !oaCalls.isEmpty {
                try write(
                    OpenAIChatChunk(
                        id: id, created: created, model: modelName,
                        choices: [.init(index: 0, delta: .init(tool_calls: oaCalls), finish_reason: nil)]))
            }
            try write(
                OpenAIChatChunk(
                    id: id, created: created, model: modelName,
                    choices: [.init(index: 0, delta: .init(), finish_reason: Self.openAIFinish(result, hasCalls: !oaCalls.isEmpty))],
                    usage: includeUsage ? Self.usage(result.usage) : nil))
        }
    }

    private static func openAIFinish(_ result: Collected, hasCalls: Bool) -> String {
        hasCalls ? "tool_calls" : result.finish == .length ? "length" : "stop"
    }

    private func openAICompletions(_ req: HTTPRequest) async throws -> HTTPResponse {
        let body: OpenAICompletionRequest
        do { body = try req.decode(OpenAICompletionRequest.self) } catch {
            return Self.openAIError(400, "invalid request: \(error)")
        }
        guard let model = await catalog.resolve(body.model) else { return Self.openAIError(404, "model '\(body.model)' not found") }
        let request = await generationRequest(
            model: model, messages: [EngineMessage(role: .user, content: body.prompt)],
            sampling: { base in
                var s = base
                if let t = body.temperature { s.temperature = t }
                if let p = body.top_p { s.topP = p }
                if let m = body.max_tokens, m > 0 { s.maxTokens = m }
                if let seed = body.seed { s.seed = UInt64(max(0, seed)) }
                if let p = body.presence_penalty { s.presencePenalty = p }
                if let f = body.frequency_penalty { s.frequencyPenalty = f }
                return s
            }, thinks: nil, contextTokens: nil, jsonFormat: nil)
        let reply = Reply(stops: body.stop?.strings ?? [], json: false)
        let id = "cmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
        let created = Int(Date().timeIntervalSince1970)
        let modelName = body.model
        try admit()
        if body.stream != true {
            defer { release() }
            let result: Collected
            do { result = try await generate(model: model, request: request, reply: reply) } catch {
                return Self.openAIError(Self.status(for: error), "\(error)")
            }
            return try Self.json(
                OpenAICompletionResponse(
                    id: id, object: "text_completion", created: created, model: modelName,
                    choices: [.init(index: 0, text: result.content, finish_reason: result.finish == .length ? "length" : "stop")],
                    usage: Self.usage(result.usage)))
        }
        return Self.sse { [self] write in
            defer { release() }
            let result: Collected
            do {
                result = try await generate(model: model, request: request, reply: reply) { delta in
                    guard !delta.content.isEmpty else { return }
                    try write(
                        OpenAICompletionResponse(
                            id: id, object: "text_completion", created: created, model: modelName,
                            choices: [.init(index: 0, text: delta.content, finish_reason: nil)]))
                }
            } catch {
                try write(OpenAIErrorBody(error: .init(message: "\(error)", type: "server_error")))
                return
            }
            try write(
                OpenAICompletionResponse(
                    id: id, object: "text_completion", created: created, model: modelName,
                    choices: [.init(index: 0, text: "", finish_reason: result.finish == .length ? "length" : "stop")]))
        }
    }

    // Generation helpers

    /// How the reply is cut and shaped for the client (see `ReplyAssembler`).
    struct Reply: Sendable {
        var stops: [String]
        var json: Bool
    }

    struct Collected {
        var content = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var usage: GenerationUsage?
        var finish: FinishReason = .stop
    }

    /// Runs one generation and hands each new piece of answer and reasoning to `onDelta` as it is written. A stop
    /// sequence ends the stream early, which cancels the generation.
    private func generate(
        model: ModelDescriptor, request: GenerationRequest, reply: Reply,
        onDelta: (ReplyAssembler.Delta) throws -> Void = { _ in }
    ) async throws -> Collected {
        var assembler = ReplyAssembler(stops: reply.stops, holdsAnswer: reply.json)
        var collected = Collected()
        func take(_ delta: ReplyAssembler.Delta) throws {
            collected.content += delta.content
            collected.reasoning += delta.reasoning
            if !delta.isEmpty { try onDelta(delta) }
        }
        events: for try await event in await engine.generate(model: model, request: request) {
            switch event {
            case .token(let text):
                let delta = assembler.feed(text)
                try take(delta)
                if delta.stopped {
                    collected.finish = .stop
                    break events
                }
            case .toolCall(let call): collected.toolCalls.append(call)
            case .usage(let usage): collected.usage = usage
            case .finished(let finish): collected.finish = finish
            }
        }
        try take(assembler.finish())
        return collected
    }

    /// Ollama and OpenAI tool schemas are the same type, so both chat handlers share this.
    private static func toolSpecs(_ tools: [OllamaTool]?) -> [ToolSpec] {
        (tools ?? []).map {
            ToolSpec(
                name: $0.function.name, description: $0.function.description ?? "",
                parametersJSONSchema: $0.function.parameters?.jsonString() ?? "{}")
        }
    }

    /// A prompt longer than the window is the client's to fix; anything else is the server's.
    static func status(for error: Error) -> Int {
        if let api = error as? APIError { return api.status }
        if case .promptTooLong = error as? EngineError { return 400 }
        return 500
    }

    private func admit() throws {
        try pending.withLock { n in
            guard n < configuration.maxQueued else { throw APIError(503, "server busy: too many queued requests") }
            n += 1
        }
    }

    private func release() { pending.withLock { $0 = max(0, $0 - 1) } }

    private static func convert(_ m: OllamaMessage) throws -> EngineMessage {
        let role = MessageRole(rawValue: m.role) ?? .user
        let images = try (m.images ?? []).map { try decodeImage($0) }
        let calls = (m.tool_calls ?? []).enumerated().map { i, c in
            ToolCall(id: "call_\(i)", name: c.function.name, argumentsJSON: c.function.arguments.jsonString())
        }
        return EngineMessage(
            role: role, content: m.content ?? "", images: images, toolCalls: calls, toolCallID: role == .tool ? m.tool_name : nil)
    }

    private static func convert(_ m: OpenAIMessage) throws -> EngineMessage {
        let role = MessageRole(rawValue: m.role) ?? .user
        let images = try (m.content?.imageDataURLs ?? []).map { try decodeDataURL($0) }
        let calls = (m.tool_calls ?? []).enumerated().map { i, c in
            ToolCall(id: c.id ?? "call_\(i)", name: c.function?.name ?? "", argumentsJSON: c.function?.arguments ?? "{}")
        }
        return EngineMessage(role: role, content: m.content?.plainText ?? "", images: images, toolCalls: calls, toolCallID: m.tool_call_id)
    }

    static func decodeImage(_ base64: String) throws -> ImageInput {
        if base64.hasPrefix("data:") { return try decodeDataURL(base64) }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw APIError(400, "invalid base64 image")
        }
        return ImageInput(data: data, mimeType: data.starts(with: [0xFF, 0xD8]) ? "image/jpeg" : "image/png")
    }

    static func decodeDataURL(_ url: String) throws -> ImageInput {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else {
            throw APIError(400, "only data: image URLs are supported")
        }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        let mime = header.split(separator: ";").first.map(String.init) ?? "image/png"
        guard let data = Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters) else {
            throw APIError(400, "invalid base64 in data URL")
        }
        return ImageInput(data: data, mimeType: mime)
    }

    private static func ollamaCalls(_ calls: [ToolCall]) -> [OllamaToolCall]? {
        calls.isEmpty ? nil : calls.map { OllamaToolCall(function: .init(name: $0.name, arguments: JSON.parse($0.argumentsJSON))) }
    }

    private static func openAICalls(_ calls: [ToolCall]) -> [OpenAIToolCall] {
        calls.enumerated().map { i, c in OpenAIToolCall(id: c.id, function: .init(name: c.name, arguments: c.argumentsJSON), index: i) }
    }

    private static func usage(_ u: GenerationUsage?) -> OpenAIUsage {
        OpenAIUsage(
            prompt_tokens: u?.promptTokens ?? 0, completion_tokens: u?.completionTokens ?? 0,
            total_tokens: (u?.promptTokens ?? 0) + (u?.completionTokens ?? 0))
    }

    // Response builders

    static let encoder = JSONCoding.apiEncoder

    static func json(_ value: some Encodable, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", data: try encoder.encode(value))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        (try? json(APIErrorBody(error: message), status: status)) ?? HTTPResponse(status: status)
    }

    static func openAIError(_ status: Int, _ message: String) -> HTTPResponse {
        (try? json(
            OpenAIErrorBody(error: .init(message: message, type: status == 404 ? "invalid_request_error" : "server_error")), status: status))
            ?? HTTPResponse(status: status)
    }

    typealias Emit = @Sendable (any Encodable & Sendable) throws -> Void

    /// Runs `producer` on a task tied to the response stream: a client disconnect terminates the stream and cancels it.
    private static func streamed(
        contentType: String, frame: @Sendable @escaping (Data) -> Data, trailer: Data? = nil,
        _ producer: @Sendable @escaping (Emit) async throws -> Void
    ) -> HTTPResponse {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let task = Task {
            do {
                try await producer { value in continuation.yield(frame(try encoder.encode(value))) }
                if let trailer { continuation.yield(trailer) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return HTTPResponse(status: 200, headers: ["Content-Type": contentType], body: .stream(stream))
    }

    /// Newline-delimited JSON objects (Ollama style).
    static func ndjson(_ producer: @Sendable @escaping (Emit) async throws -> Void) -> HTTPResponse {
        streamed(contentType: "application/x-ndjson", frame: { $0 + Data([0x0A]) }, producer)
    }

    /// `data: {...}` server-sent events (OpenAI style), ending with `data: [DONE]`.
    static func sse(_ producer: @Sendable @escaping (Emit) async throws -> Void) -> HTTPResponse {
        streamed(
            contentType: "text/event-stream", frame: { Data("data: ".utf8) + $0 + Data([0x0A, 0x0A]) },
            trailer: Data("data: [DONE]\n\n".utf8), producer)
    }

    static let docsPage = """
        <!doctype html><title>Mac-Olama API</title><style>body{font:14px -apple-system,system-ui;margin:2em;max-width:52em}code{background:#eee;padding:1px 4px}</style>
        <h1>Mac-Olama API</h1><p>Ollama-compatible (primary) and OpenAI-compatible endpoints on this host.</p>
        <h2>Ollama</h2><ul>
        <li><code>GET /api/version</code>, <code>GET /api/tags</code>, <code>GET /api/ps</code>, <code>POST /api/show</code></li>
        <li><code>POST /api/chat</code>, <code>POST /api/generate</code> (NDJSON streaming, <code>keep_alive</code>, <code>images</code>, <code>tools</code>)</li>
        <li><code>think</code>, <code>format</code> (<code>"json"</code> or a schema), <code>options.stop</code>, <code>top_k</code>, <code>min_p</code>, penalties</li>
        <li>403: <code>/api/pull</code>, <code>/api/delete</code> — models are downloaded and removed in the app</li>
        <li>501: <code>/api/embed</code>, <code>/api/embeddings</code>, <code>/api/create</code>, <code>/api/push</code>, <code>/api/copy</code></li></ul>
        <h2>OpenAI</h2><ul><li><code>GET /v1/models</code>, <code>POST /v1/chat/completions</code> (SSE, <code>reasoning_content</code>), <code>POST /v1/completions</code></li><li><code>stop</code>, <code>response_format</code>, <code>reasoning_effort</code>, <code>chat_template_kwargs.enable_thinking</code>, <code>top_k</code>, <code>min_p</code>, penalties</li><li>501: <code>/v1/embeddings</code></li></ul>
        """
}

/// Thrown from handlers; mapped to an Ollama-style JSON error by the server's error mapper.
struct APIError: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

// ReplyAssembler

/// Turns the raw token stream into what an API client reads: reasoning apart from the answer, template markup
/// dropped (the same rules as the chat, `AnswerText`), the answer cut at the first stop sequence, and in JSON mode
/// reduced to the JSON value. Deltas only ever extend what was sent: a marker or stop sequence still being written is
/// held back until it resolves.
struct ReplyAssembler {
    struct Delta: Equatable {
        var reasoning = ""
        var content = ""
        var stopped = false
        var isEmpty: Bool { reasoning.isEmpty && content.isEmpty }
    }

    private let stops: [String]
    /// JSON mode: the answer is sent whole at the end, once it can be cut to the value.
    private let holdsAnswer: Bool
    private var raw = ""
    private var sentReasoning = ""
    private var sentContent = ""
    private var stopped = false
    /// Re-reading the whole reply per token would be quadratic; a few times a second is smooth enough for a client.
    private var lastPass = ContinuousClock.now
    private static let passInterval = Duration.milliseconds(40)

    init(stops: [String], holdsAnswer: Bool = false) {
        self.stops = stops.filter { !$0.isEmpty }
        self.holdsAnswer = holdsAnswer
    }

    mutating func feed(_ token: String) -> Delta {
        raw += token
        let now = ContinuousClock.now
        // A token that may complete a stop sequence is checked at once, so the cut is never late.
        guard now - lastPass >= Self.passInterval || stops.contains(where: { token.contains($0.suffix(1)) }) else { return Delta() }
        lastPass = now
        return pass(final: false)
    }

    mutating func finish() -> Delta { pass(final: true) }

    private mutating func pass(final: Bool) -> Delta {
        guard !stopped else { return Delta() }
        let text = final ? raw : Self.withoutOpenMarker(raw)
        var answer = AnswerText.visible(text)
        var delta = Delta()
        if let cut = stops.compactMap({ answer.range(of: $0)?.lowerBound }).min() {
            answer = String(answer[..<cut])
            stopped = true
            delta.stopped = true
        } else if !final {
            answer = String(answer.dropLast(Self.pendingStopLength(answer, stops)))
        }
        let reasoning = AnswerText.reasoning(text)
        if reasoning.hasPrefix(sentReasoning) {
            delta.reasoning = String(reasoning.dropFirst(sentReasoning.count))
            sentReasoning = reasoning
        }
        if holdsAnswer {
            guard final || stopped else { return delta }
            answer = Self.jsonValue(in: answer)
        }
        if answer.hasPrefix(sentContent) {
            delta.content = String(answer.dropFirst(sentContent.count))
            sentContent = answer
        }
        return delta
    }

    /// The reply without a trailing `<…`, `[…` or `◁…` that has not closed yet: it may become a tag that hides text.
    static func withoutOpenMarker(_ raw: String) -> String {
        let pairs: [(Character, Character)] = [("<", ">"), ("[", "]"), ("◁", "▷")]
        var cut = raw.endIndex
        for (open, close) in pairs {
            guard let start = raw.lastIndex(of: open), !raw[start...].contains(close),
                raw.distance(from: start, to: raw.endIndex) <= 40
            else { continue }
            cut = min(cut, start)
        }
        return String(raw[..<cut])
    }

    /// Length of the longest tail of `text` that begins some stop sequence.
    static func pendingStopLength(_ text: String, _ stops: [String]) -> Int {
        var longest = 0
        for stop in stops {
            for length in stride(from: min(stop.count - 1, text.count), to: longest, by: -1)
            where text.hasSuffix(stop.prefix(length)) {
                longest = length
                break
            }
        }
        return longest
    }

    /// The JSON value in a reply that wrapped it in prose or a code fence; the reply as it is when there is none.
    static func jsonValue(in text: String) -> String {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return text }
        let close: Character = text[start] == "{" ? "}" : "]"
        var end = text.lastIndex(of: close)
        while let e = end, e > start {
            let candidate = String(text[start...e])
            if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8), options: .fragmentsAllowed)) != nil { return candidate }
            end = text[start..<e].lastIndex(of: close)
        }
        return text
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
