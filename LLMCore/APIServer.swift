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

/// Local HTTP server exposing Ollama (`/api/*`, primary) and OpenAI (`/v1/*`) compatible endpoints.
/// Stateless: clients send full history; tool calls are returned to the client, not executed here.
public final class APIServer: Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int
        public var version: String
        public var defaultSampling: SamplingParams
        /// Requests wait in EngineManager's queue; beyond this many pending, reply 503.
        public var maxQueued: Int
        public var log: (@Sendable (String) -> Void)?

        public init(
            host: String = "127.0.0.1", port: Int = 11434, version: String = "0.1", defaultSampling: SamplingParams = .init(),
            maxQueued: Int = 8, log: (@Sendable (String) -> Void)? = nil
        ) {
            self.host = host
            self.port = port
            self.version = version
            self.defaultSampling = defaultSampling
            self.maxQueued = maxQueued
            self.log = log
        }
    }

    public let configuration: Configuration
    private let catalog: ModelCatalog
    private let engine: EngineManager
    private let downloader: ModelDownloader?
    private let onModelsChanged: (@Sendable () async -> Void)?
    private let server: HTTPServer
    private let pending = Mutex(0)

    public init(
        configuration: Configuration, catalog: ModelCatalog, engine: EngineManager,
        downloader: ModelDownloader? = nil, onModelsChanged: (@Sendable () async -> Void)? = nil
    ) {
        self.configuration = configuration
        self.catalog = catalog
        self.engine = engine
        self.downloader = downloader
        self.onModelsChanged = onModelsChanged
        self.server = HTTPServer(configuration: .init(host: configuration.host, port: configuration.port, log: configuration.log))
        registerRoutes()
    }

    // Lifecycle

    /// Checks whether something (Ollama?) already listens on the port. Cheap GET with a short timeout.
    public static func probe(host: String = "127.0.0.1", port: Int) async -> PortStatus {
        guard let url = URL(string: "http://\(host):\(port)/api/version") else { return .free }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .occupied }
            if http.statusCode == 200, let v = try? JSONDecoder().decode(OllamaVersionResponse.self, from: data),
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
            return Self.error(500, "\(error)")
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
        server.route("POST", "/api/pull") { [self] req in try await pull(req) }
        server.route("DELETE", "/api/delete") { [self] req in try await delete(req) }
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
        return "sha256:" + String(repeating: "0", count: 48) + String(h, radix: 16).leftPadded(to: 16)
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

    // Chat (Ollama)

    private func ollamaChat(_ req: HTTPRequest) async throws -> HTTPResponse {
        let body = try req.decode(OllamaChatRequest.self)
        let model = try await resolve(body.model)
        let messages = try body.messages.map { try Self.convert($0) }
        if model.kind == .llm, messages.contains(where: { !$0.images.isEmpty }) {
            return Self.error(400, "model '\(body.model)' does not support images")
        }
        let tools = (body.tools ?? []).map {
            ToolSpec(
                name: $0.function.name, description: $0.function.description ?? "",
                parametersJSONSchema: $0.function.parameters?.jsonString() ?? "{}")
        }
        let request = GenerationRequest(
            messages: messages, tools: tools, sampling: (body.options ?? .init()).sampling(default: configuration.defaultSampling),
            keepAlive: body.keep_alive?.keepAlive ?? .default,
            contextTokens: body.options?.num_ctx)
        let modelName = body.model
        let stream = body.stream ?? true
        let start = ContinuousClock.now
        try admit()
        defer { release() }

        if !stream {
            let result = try await collect(model: model, request: request)
            let chunk = OllamaChatChunk(
                model: modelName, created_at: .now,
                message: OllamaMessage(role: "assistant", content: result.text, tool_calls: Self.ollamaCalls(result.toolCalls)),
                done: true, done_reason: result.finish.rawValue,
                total_duration: Self.ns(start), load_duration: 0,
                prompt_eval_count: result.usage?.promptTokens, prompt_eval_duration: Self.ns(result.usage?.promptSeconds),
                eval_count: result.usage?.completionTokens, eval_duration: Self.ns(result.usage?.generationSeconds))
            return try Self.json(chunk)
        }

        let events = await engine.generate(model: model, request: request)
        return Self.ndjson { write in
            var usage: GenerationUsage?
            var finish: FinishReason = .stop
            var calls: [ToolCall] = []
            do {
                for try await event in events {
                    switch event {
                    case .token(let t):
                        try write(
                            OllamaChatChunk(
                                model: modelName, created_at: .now, message: OllamaMessage(role: "assistant", content: t), done: false))
                    case .toolCall(let c): calls.append(c)
                    case .usage(let u): usage = u
                    case .finished(let f): finish = f
                    }
                }
            } catch {
                try write(APIErrorBody(error: "\(error)"))
                return
            }
            try write(
                OllamaChatChunk(
                    model: modelName, created_at: .now,
                    message: OllamaMessage(role: "assistant", content: "", tool_calls: Self.ollamaCalls(calls)),
                    done: true, done_reason: finish.rawValue, total_duration: Self.ns(start), load_duration: 0,
                    prompt_eval_count: usage?.promptTokens, prompt_eval_duration: Self.ns(usage?.promptSeconds),
                    eval_count: usage?.completionTokens, eval_duration: Self.ns(usage?.generationSeconds)))
        }
    }

    private func ollamaGenerate(_ req: HTTPRequest) async throws -> HTTPResponse {
        let body = try req.decode(OllamaGenerateRequest.self)
        let model = try await resolve(body.model)
        var messages: [EngineMessage] = []
        if let system = body.system, !system.isEmpty { messages.append(EngineMessage(role: .system, content: system)) }
        let images = try (body.images ?? []).map { try Self.decodeImage($0) }
        messages.append(EngineMessage(role: .user, content: body.prompt ?? "", images: images))
        let request = GenerationRequest(
            messages: messages, sampling: (body.options ?? .init()).sampling(default: configuration.defaultSampling),
            keepAlive: body.keep_alive?.keepAlive ?? .default,
            contextTokens: body.options?.num_ctx)
        let modelName = body.model
        let start = ContinuousClock.now
        try admit()
        defer { release() }

        // Empty prompt = load/unload only (Ollama semantics).
        if (body.prompt ?? "").isEmpty {
            if case .unloadNow = request.keepAlive { await engine.unload() } else { try await engine.ensureLoaded(model) }
            return try Self.json(OllamaGenerateChunk(model: modelName, created_at: .now, response: "", done: true, done_reason: "load"))
        }

        if body.stream == false {
            let result = try await collect(model: model, request: request)
            return try Self.json(
                OllamaGenerateChunk(
                    model: modelName, created_at: .now, response: result.text, done: true, done_reason: result.finish.rawValue,
                    total_duration: Self.ns(start), load_duration: 0,
                    prompt_eval_count: result.usage?.promptTokens, prompt_eval_duration: Self.ns(result.usage?.promptSeconds),
                    eval_count: result.usage?.completionTokens, eval_duration: Self.ns(result.usage?.generationSeconds)))
        }
        let events = await engine.generate(model: model, request: request)
        return Self.ndjson { write in
            var usage: GenerationUsage?
            var finish: FinishReason = .stop
            do {
                for try await event in events {
                    switch event {
                    case .token(let t): try write(OllamaGenerateChunk(model: modelName, created_at: .now, response: t, done: false))
                    case .usage(let u): usage = u
                    case .finished(let f): finish = f
                    case .toolCall: break
                    }
                }
            } catch {
                try write(APIErrorBody(error: "\(error)"))
                return
            }
            try write(
                OllamaGenerateChunk(
                    model: modelName, created_at: .now, response: "", done: true, done_reason: finish.rawValue,
                    total_duration: Self.ns(start), load_duration: 0,
                    prompt_eval_count: usage?.promptTokens, prompt_eval_duration: Self.ns(usage?.promptSeconds),
                    eval_count: usage?.completionTokens, eval_duration: Self.ns(usage?.generationSeconds)))
        }
    }

    // Pull / delete

    private func pull(_ req: HTTPRequest) async throws -> HTTPResponse {
        let body = try req.decode(OllamaPullRequest.self)
        guard let ref = body.ref, let repoID = HubClient.parseRepoID(ref) else {
            return Self.error(400, "model must be a Hugging Face repo id like mlx-community/Qwen3.5-9B-MLX-4bit")
        }
        guard let downloader else { return Self.error(501, "downloads are disabled") }
        let events = await downloader.download(repoID: repoID)
        let onChanged = onModelsChanged
        if body.stream == false {
            do {
                for try await _ in events {}
                await onChanged?()
                return try Self.json(OllamaPullStatus(status: "success"))
            } catch {
                return Self.error(500, "\(error)")
            }
        }
        return Self.ndjson { write in
            try write(OllamaPullStatus(status: "pulling manifest"))
            do {
                for try await event in events {
                    switch event {
                    case .resolved(let c): try write(OllamaPullStatus(status: "pulling \(c.files) files", total: c.bytes, completed: 0))
                    case .progress(let p):
                        try write(
                            OllamaPullStatus(
                                status: "pulling \(p.currentFile)", digest: p.currentFile, total: p.bytesTotal, completed: p.bytesReceived))
                    case .fileFinished: break
                    case .finished:
                        try write(OllamaPullStatus(status: "verifying sha256 digest"))
                        try write(OllamaPullStatus(status: "writing manifest"))
                    }
                }
                await onChanged?()
                try write(OllamaPullStatus(status: "success"))
            } catch {
                try write(OllamaPullStatus(status: "error", error: "\(error)"))
            }
        }
    }

    private func delete(_ req: HTTPRequest) async throws -> HTTPResponse {
        let body = try req.decode(OllamaDeleteRequest.self)
        guard let ref = body.ref else { return Self.error(400, "model is required") }
        let m = try await resolve(ref)
        if await engine.loadedModel?.id == m.id { await engine.unload() }
        try await catalog.remove(id: m.id)
        await onModelsChanged?()
        return HTTPResponse(status: 200)
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
        let tools = (body.tools ?? []).map {
            ToolSpec(
                name: $0.function.name, description: $0.function.description ?? "",
                parametersJSONSchema: $0.function.parameters?.jsonString() ?? "{}")
        }
        let request = GenerationRequest(messages: messages, tools: tools, sampling: body.sampling(default: configuration.defaultSampling))
        let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
        let created = Int(Date().timeIntervalSince1970)
        let modelName = body.model
        try admit()
        defer { release() }

        if body.stream != true {
            let result = try await collect(model: model, request: request)
            let calls = Self.openAICalls(result.toolCalls)
            let finish = result.finish == .toolCalls ? "tool_calls" : result.finish == .length ? "length" : "stop"
            return try Self.json(
                OpenAIChatResponse(
                    id: id, created: created, model: modelName,
                    choices: [
                        .init(
                            index: 0,
                            message: OpenAIMessage(role: "assistant", content: .text(result.text), tool_calls: calls.isEmpty ? nil : calls),
                            finish_reason: finish)
                    ],
                    usage: Self.usage(result.usage)
                ))
        }
        let includeUsage = body.stream_options?.include_usage ?? false
        let events = await engine.generate(model: model, request: request)
        return Self.sse { write in
            var usage: GenerationUsage?
            var finish: FinishReason = .stop
            var calls: [ToolCall] = []
            try write(
                OpenAIChatChunk(
                    id: id, created: created, model: modelName,
                    choices: [.init(index: 0, delta: .init(role: "assistant", content: ""), finish_reason: nil)]))
            do {
                for try await event in events {
                    switch event {
                    case .token(let t):
                        try write(
                            OpenAIChatChunk(
                                id: id, created: created, model: modelName,
                                choices: [.init(index: 0, delta: .init(content: t), finish_reason: nil)]))
                    case .toolCall(let c): calls.append(c)
                    case .usage(let u): usage = u
                    case .finished(let f): finish = f
                    }
                }
            } catch {
                try write(OpenAIErrorBody(error: .init(message: "\(error)", type: "server_error")))
                return
            }
            let oaCalls = Self.openAICalls(calls)
            if !oaCalls.isEmpty {
                try write(
                    OpenAIChatChunk(
                        id: id, created: created, model: modelName,
                        choices: [.init(index: 0, delta: .init(tool_calls: oaCalls), finish_reason: nil)]))
            }
            let reason = !oaCalls.isEmpty ? "tool_calls" : finish == .length ? "length" : "stop"
            try write(
                OpenAIChatChunk(
                    id: id, created: created, model: modelName, choices: [.init(index: 0, delta: .init(), finish_reason: reason)],
                    usage: includeUsage ? Self.usage(usage) : nil))
        }
    }

    private func openAICompletions(_ req: HTTPRequest) async throws -> HTTPResponse {
        let body: OpenAICompletionRequest
        do { body = try req.decode(OpenAICompletionRequest.self) } catch {
            return Self.openAIError(400, "invalid request: \(error)")
        }
        guard let model = await catalog.resolve(body.model) else { return Self.openAIError(404, "model '\(body.model)' not found") }
        var sampling = configuration.defaultSampling
        if let t = body.temperature { sampling.temperature = t }
        if let p = body.top_p { sampling.topP = p }
        if let m = body.max_tokens, m > 0 { sampling.maxTokens = m }
        let request = GenerationRequest(messages: [EngineMessage(role: .user, content: body.prompt)], sampling: sampling)
        let id = "cmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
        let created = Int(Date().timeIntervalSince1970)
        let modelName = body.model
        try admit()
        defer { release() }
        if body.stream != true {
            let result = try await collect(model: model, request: request)
            return try Self.json(
                OpenAICompletionResponse(
                    id: id, object: "text_completion", created: created, model: modelName,
                    choices: [.init(index: 0, text: result.text, finish_reason: result.finish == .length ? "length" : "stop")],
                    usage: Self.usage(result.usage)))
        }
        let events = await engine.generate(model: model, request: request)
        return Self.sse { write in
            var finish: FinishReason = .stop
            do {
                for try await event in events {
                    switch event {
                    case .token(let t):
                        try write(
                            OpenAICompletionResponse(
                                id: id, object: "text_completion", created: created, model: modelName,
                                choices: [.init(index: 0, text: t, finish_reason: nil)]))
                    case .finished(let f): finish = f
                    default: break
                    }
                }
            } catch {
                try write(OpenAIErrorBody(error: .init(message: "\(error)", type: "server_error")))
                return
            }
            try write(
                OpenAICompletionResponse(
                    id: id, object: "text_completion", created: created, model: modelName,
                    choices: [.init(index: 0, text: "", finish_reason: finish == .length ? "length" : "stop")]))
        }
    }

    // Generation helpers

    struct Collected {
        var text = ""
        var toolCalls: [ToolCall] = []
        var usage: GenerationUsage?
        var finish: FinishReason = .stop
    }

    private func collect(model: ModelDescriptor, request: GenerationRequest) async throws -> Collected {
        var c = Collected()
        for try await event in await engine.generate(model: model, request: request) {
            switch event {
            case .token(let t): c.text += t
            case .toolCall(let call): c.toolCalls.append(call)
            case .usage(let u): c.usage = u
            case .finished(let f): c.finish = f
            }
        }
        return c
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
            role: role, content: m.content, images: images, toolCalls: calls, toolCallID: role == .tool ? m.tool_name : nil)
    }

    private static func convert(_ m: OpenAIMessage) throws -> EngineMessage {
        let role = MessageRole(rawValue: m.role) ?? .user
        let images = try (m.content?.imageDataURLs ?? []).map { try decodeDataURL($0) }
        let calls = (m.tool_calls ?? []).map { ToolCall(id: $0.id, name: $0.function.name, argumentsJSON: $0.function.arguments) }
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

    private static func ns(_ start: ContinuousClock.Instant) -> Int64 {
        let d = start.duration(to: .now)
        return Int64(d.components.seconds) * 1_000_000_000 + Int64(d.components.attoseconds / 1_000_000_000)
    }

    private static func ns(_ seconds: TimeInterval?) -> Int64? { seconds.map { Int64($0 * 1e9) } }

    // Response builders

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

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
        <li><code>POST /api/pull</code> (Hugging Face repo id), <code>DELETE /api/delete</code></li>
        <li>501: <code>/api/embed</code>, <code>/api/embeddings</code>, <code>/api/create</code>, <code>/api/push</code>, <code>/api/copy</code></li></ul>
        <h2>OpenAI</h2><ul><li><code>GET /v1/models</code>, <code>POST /v1/chat/completions</code> (SSE), <code>POST /v1/completions</code></li><li>501: <code>/v1/embeddings</code></li></ul>
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

extension String {
    func leftPadded(to width: Int) -> String { count >= width ? self : String(repeating: "0", count: width - count) + self }
}
