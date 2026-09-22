//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// Models on another server over the OpenAI-compatible `/v1/chat/completions`, streamed over HTTP.
// Separate reasoning (`reasoning_content`) is wrapped in <think> tags, so it is hidden like a local model's.

enum RemoteError: DescribedError {
    case badAddress
    case unreachable(String)
    case modelNotFound(String, available: [String])
    case http(Int, String)
    case timedOut(Int)

    var description: String {
        switch self {
        case .badAddress: String(localized: "Enter the server address, e.g. http://localhost:8080.")
        case .unreachable(let detail): String(localized: "The server does not answer as an OpenAI-compatible API: \(detail)")
        case .modelNotFound(let name, let available):
            available.isEmpty
                ? String(localized: "The server has no model “\(name)”.")
                : String(localized: "The server has no model “\(name)”. Available: \(available.prefix(8).joined(separator: ", "))")
        case .http(let status, let message): String(localized: "Server error \(status): \(message)")
        case .timedOut(let seconds): String(localized: "The server did not answer in \(seconds) s. Check the address and port.")
        }
    }
}

/// Wraps a server's separate reasoning stream in the canonical reasoning tags, so the transcript hides it the same
/// way it hides a local model's.
private struct ThinkingTagger {
    /// The first pair in the table is the canonical `<think>`/`</think>` every reply is normalized to.
    private static let tags = AnswerText.reasoningBlocks[0]
    private var thinking = false

    mutating func reasoning(_ text: String, into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) {
        guard !text.isEmpty else { return }
        if !thinking { continuation.yield(.token(Self.tags.open)) }
        thinking = true
        continuation.yield(.token(text))
    }

    mutating func content(_ text: String, into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) {
        guard !text.isEmpty else { return }
        close(into: continuation)
        continuation.yield(.token(text))
    }

    /// Ends an open reasoning block (the answer begins, or the stream is done).
    mutating func close(into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) {
        if thinking { continuation.yield(.token(Self.tags.close)) }
        thinking = false
    }
}

extension JSON {
    /// Tool arguments as a JSON string. Some servers send them pre-encoded as a string; that string passes through.
    fileprivate var argumentsString: String {
        if case .string(let s) = self { return s }
        return jsonString()
    }
}

actor RemoteEngine: InferenceEngine {
    /// What the server reported when the model was connected.
    struct Probe: Sendable {
        /// The name as the server spells it (`qwen3` may be listed as `qwen3:latest`).
        var model: String
        var supportsTools: Bool
        var supportsVision: Bool
        var contextLength: Int?
    }

    private(set) var loadedModel: ModelDescriptor?
    private var endpoint: RemoteEndpoint?
    private var token: String?
    private let current = GenerationTaskBox()

    func load(_ model: ModelDescriptor, progress: @Sendable @escaping (Double) -> Void) async throws {
        let endpoint = try RemoteEndpoint.load(from: model.directory)
        let token = RemoteTokens.token(for: model.id)
        progress(0.3)
        // "Loading" a remote model is checking that the server is up and still has it.
        _ = try await Self.probe(baseURL: endpoint.baseURL, model: endpoint.model, token: token)
        self.endpoint = endpoint
        self.token = token
        loadedModel = model
        progress(1)
    }

    func unload() async {
        current.cancel()
        loadedModel = nil
        endpoint = nil
        token = nil
    }

    func cancelCurrent() async {
        current.cancel()
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        guard let endpoint else { return .failed(EngineError.noModelLoaded) }
        let token = token
        return .engine(current: current) { continuation in
            try await Self.streamOpenAI(endpoint, token: token, request: request, into: continuation)
        }
    }

    // Probe

    /// A mistyped address or port must not keep the user waiting: the whole check, all its requests together, ends here.
    static let probeTimeout = 10

    /// Checks the address and the model: `/v1/models`, then llama-server's `/props` for tools, vision and context.
    static func probe(baseURL: URL, model: String, token: String?) async throws -> Probe {
        try await withThrowingTaskGroup(of: Probe?.self) { group in
            group.addTask { try await probeServer(baseURL: baseURL, model: model, token: token) }
            group.addTask {
                try await Task.sleep(for: .seconds(probeTimeout))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let probe = first else { throw RemoteError.timedOut(probeTimeout) }
            return probe
        }
    }

    private static func probeServer(baseURL: URL, model: String, token: String?) async throws -> Probe {
        let models: [String: Any]
        do {
            models = try await json(baseURL.appending(path: "v1/models"), token: token)
        } catch let error as RemoteError {
            throw error
        } catch {
            throw RemoteError.unreachable(error.localizedDescription)
        }
        let names = (models["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        // llama-server serves one model under whatever name it was started with; any name reaches it.
        guard let name = match(model, in: names) ?? (names.count == 1 ? names[0] : nil) else {
            throw RemoteError.modelNotFound(model, available: names)
        }
        let props = try? await json(baseURL.appending(path: "props"), token: token)
        let template = props?["chat_template"] as? String ?? ""
        let modalities = props?["modalities"] as? [String: Any]
        let settings = props?["default_generation_settings"] as? [String: Any]
        return Probe(
            model: name, supportsTools: template.contains("tools"), supportsVision: modalities?["vision"] as? Bool ?? false,
            contextLength: settings?["n_ctx"] as? Int)
    }

    /// Exact name, then `name:latest`, then ignoring case or the path of a file-named model.
    private static func match(_ wanted: String, in names: [String]) -> String? {
        let w = wanted.trimmingCharacters(in: .whitespaces)
        if let exact = names.first(where: { $0 == w }) { return exact }
        if let latest = names.first(where: { $0 == w + ":latest" }) { return latest }
        return names.first { $0.lowercased() == w.lowercased() || ($0 as NSString).lastPathComponent.lowercased() == w.lowercased() }
    }

    // OpenAI-compatible

    private static func streamOpenAI(
        _ endpoint: RemoteEndpoint, token: String?, request: GenerationRequest,
        into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let body = OpenAIChatRequest(
            model: endpoint.model, messages: openAIMessages(request.messages), stream: true,
            temperature: request.sampling.temperature, top_p: request.sampling.topP, max_tokens: request.sampling.maxTokens,
            seed: request.sampling.seed.flatMap { Int(exactly: $0) }, tools: tools(request.tools),
            stream_options: .init(include_usage: true))
        let bytes = try await stream(endpoint.baseURL.appending(path: "v1/chat/completions"), token: token, body: body)
        var tagger = ThinkingTagger()
        var finish: FinishReason = .stop
        var usage: GenerationUsage?
        // Tool calls arrive in pieces keyed by index: the name first, the arguments as a JSON string in fragments.
        var calls: [Int: (id: String, name: String, arguments: String)] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            let data = Data(payload.utf8)
            if let failure = try? chunkDecoder.decode(OpenAIErrorBody.self, from: data) {
                throw RemoteError.http(500, failure.error.message ?? "unknown server error")
            }
            guard let chunk = try? chunkDecoder.decode(OpenAIChatChunk.self, from: data) else { continue }
            if let u = chunk.usage {
                usage = GenerationUsage(
                    promptTokens: u.prompt_tokens ?? 0, completionTokens: u.completion_tokens ?? 0,
                    tokensPerSecond: chunk.timings?.predicted_per_second ?? 0)
            }
            guard let choice = chunk.choices?.first else { continue }
            if let delta = choice.delta {
                tagger.reasoning(delta.reasoning_content ?? "", into: continuation)
                tagger.content(delta.content ?? "", into: continuation)
                for part in delta.tool_calls ?? [] {
                    let index = part.index ?? 0
                    var call = calls[index] ?? (id: part.id ?? "call_\(index)", name: "", arguments: "")
                    call.name += part.function?.name ?? ""
                    call.arguments += part.function?.arguments ?? ""
                    calls[index] = call
                }
            }
            switch choice.finish_reason {
            case "length": finish = .length
            case "tool_calls": finish = .toolCalls
            default: break
            }
        }
        tagger.close(into: continuation)
        for (_, call) in calls.sorted(by: { $0.key < $1.key }) where !call.name.isEmpty {
            continuation.yield(
                .toolCall(ToolCall(id: call.id, name: call.name, argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments)))
            finish = .toolCalls
        }
        if let usage { continuation.yield(.usage(usage)) }
        continuation.yield(.finished(finish))
    }

    // Engine → wire conversion (the reverse of `APIServer.convert`)

    private static func openAIMessages(_ messages: [EngineMessage]) -> [OpenAIMessage] {
        messages.map { message in
            let content: OpenAIContent =
                message.images.isEmpty
                ? .text(message.content)
                : .parts(
                    [OpenAIContent.Part(type: "text", text: message.content, image_url: nil)]
                        + message.images.map { image in
                            OpenAIContent.Part(
                                type: "image_url", text: nil,
                                image_url: .init(url: "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"))
                        })
            return OpenAIMessage(
                role: message.role.rawValue, content: content,
                tool_calls: message.toolCalls.isEmpty
                    ? nil
                    : message.toolCalls.map { OpenAIToolCall(id: $0.id, function: .init(name: $0.name, arguments: $0.argumentsJSON)) },
                tool_call_id: message.toolCallID)
        }
    }

    private static func tools(_ specs: [ToolSpec]) -> [OpenAITool]? {
        specs.isEmpty
            ? nil
            : specs.map {
                OpenAITool(
                    type: "function",
                    function: .init(name: $0.name, description: $0.description, parameters: JSON.parse($0.parametersJSONSchema)))
            }
    }

    // HTTP and JSON

    /// Chunk decoding is lenient: timestamps are not read here, and a date format the strict ISO-8601 strategy
    /// rejects must not drop the chunk.
    private static let chunkDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { _ in .distantPast }
        return d
    }()

    private static func json(_ url: URL, token: String?, body: [String: Any]? = nil) async throws -> [String: Any] {
        let encoded = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let request = HTTPJSON.request(url, token: token, jsonBody: encoded, timeout: 15, accept: nil, userAgent: nil)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteError.unreachable(String(localized: "the answer is not JSON"))
        }
        return object
    }

    /// Long timeout: a big prompt may take the server a while before the first token.
    private static func stream(_ url: URL, token: String?, body: some Encodable) async throws -> URLSession.AsyncBytes {
        let request = HTTPJSON.request(
            url, token: token, jsonBody: try JSONCoding.plainEncoder.encode(body), timeout: 600, accept: nil, userAgent: nil)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var data = Data()
            for try await byte in bytes.prefix(4096) { data.append(byte) }
            try check(response, data: data)
        }
        return bytes
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode >= 400 else { return }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message =
            (object?["error"] as? String) ?? ((object?["error"] as? [String: Any])?["message"] as? String)
            ?? String(decoding: data.prefix(300), as: UTF8.self)
        throw RemoteError.http(http.statusCode, message)
    }
}

// RoutingEngine

/// The one engine `EngineManager` owns: local models go to MLX, remote ones over HTTP. One model is loaded at a time.
actor RoutingEngine: InferenceEngine {
    private let local: any InferenceEngine
    private let remote: any InferenceEngine
    private var active: (any InferenceEngine)?
    private(set) var loadedModel: ModelDescriptor?

    init(local: any InferenceEngine, remote: any InferenceEngine) {
        self.local = local
        self.remote = remote
    }

    func load(_ model: ModelDescriptor, progress: @Sendable @escaping (Double) -> Void) async throws {
        let target = model.source == .remote ? remote : local
        if let active, active !== target { await active.unload() }
        loadedModel = nil
        try await target.load(model, progress: progress)
        active = target
        loadedModel = model
    }

    func unload() async {
        await active?.unload()
        active = nil
        loadedModel = nil
    }

    func cancelCurrent() async {
        await active?.cancelCurrent()
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        guard let engine = active else { return .failed(EngineError.noModelLoaded) }
        return .engine { continuation in
            for try await event in await engine.generate(request) { continuation.yield(event) }
        }
    }
}
