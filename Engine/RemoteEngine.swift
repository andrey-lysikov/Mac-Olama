//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// Models on another server: Ollama `/api/chat` or OpenAI-compatible `/v1/chat/completions`, streamed over HTTP.
// Separate reasoning (`thinking`, `reasoning_content`) is wrapped in <think> tags, so it is hidden like a local model's.

enum RemoteError: Error, CustomStringConvertible {
    case badAddress
    case unreachable(String)
    case modelNotFound(String, available: [String])
    case http(Int, String)
    case timedOut(Int)

    var description: String {
        switch self {
        case .badAddress: String(localized: "Enter the server address, e.g. http://localhost:11434.")
        case .unreachable(let detail): String(localized: "The server does not answer as an Ollama or OpenAI-compatible API: \(detail)")
        case .modelNotFound(let name, let available):
            available.isEmpty
                ? String(localized: "The server has no model “\(name)”.")
                : String(localized: "The server has no model “\(name)”. Available: \(available.prefix(8).joined(separator: ", "))")
        case .http(let status, let message): String(localized: "Server error \(status): \(message)")
        case .timedOut(let seconds): String(localized: "The server did not answer in \(seconds) s. Check the address and port.")
        }
    }
}

actor RemoteEngine: InferenceEngine {
    /// What the server reported when the model was connected.
    struct Probe: Sendable {
        var api: RemoteEndpoint.API
        /// The name as the server spells it (`qwen3` may be listed as `qwen3:latest`).
        var model: String
        var supportsTools: Bool
        var supportsVision: Bool
        var contextLength: Int?
    }

    private(set) var loadedModel: ModelDescriptor?
    private var endpoint: RemoteEndpoint?
    private var token: String?
    private var current: Task<Void, Never>?

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
        current?.cancel()
        loadedModel = nil
        endpoint = nil
        token = nil
    }

    func cancelCurrent() async {
        current?.cancel()
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        guard let endpoint else {
            continuation.finish(throwing: EngineError.noModelLoaded)
            return stream
        }
        let token = token
        let task = Task {
            do {
                switch endpoint.api {
                case .ollama: try await Self.streamOllama(endpoint, token: token, request: request, into: continuation)
                case .openAI: try await Self.streamOpenAI(endpoint, token: token, request: request, into: continuation)
                }
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
        current = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // Probe

    /// A mistyped address or port must not keep the user waiting: the whole check, all its requests together, ends here.
    static let probeTimeout = 10

    /// Checks the address and the model: Ollama first (`/api/tags`, `/api/show`), then OpenAI-compatible (`/v1/models`, `/props`).
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
        if let tags = try? await json(baseURL.appending(path: "api/tags"), token: token),
            let list = tags["models"] as? [[String: Any]]
        {
            let names = list.compactMap { $0["name"] as? String ?? $0["model"] as? String }
            guard let name = match(model, in: names) else { throw RemoteError.modelNotFound(model, available: names) }
            let show = try? await json(baseURL.appending(path: "api/show"), token: token, body: ["model": name])
            let capabilities = show?["capabilities"] as? [String] ?? []
            let info = show?["model_info"] as? [String: Any] ?? [:]
            let context = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
            return Probe(
                api: .ollama, model: name, supportsTools: capabilities.contains("tools"), supportsVision: capabilities.contains("vision"),
                contextLength: context)
        }
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
            api: .openAI, model: name, supportsTools: template.contains("tools"), supportsVision: modalities?["vision"] as? Bool ?? false,
            contextLength: settings?["n_ctx"] as? Int)
    }

    /// Exact name, then `name:latest`, then ignoring case or the path of a file-named model.
    private static func match(_ wanted: String, in names: [String]) -> String? {
        let w = wanted.trimmingCharacters(in: .whitespaces)
        if let exact = names.first(where: { $0 == w }) { return exact }
        if let latest = names.first(where: { $0 == w + ":latest" }) { return latest }
        return names.first { $0.lowercased() == w.lowercased() || ($0 as NSString).lastPathComponent.lowercased() == w.lowercased() }
    }

    // Ollama

    private static func streamOllama(
        _ endpoint: RemoteEndpoint, token: String?, request: GenerationRequest,
        into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        var options: [String: Any] = [
            "temperature": request.sampling.temperature, "top_p": request.sampling.topP, "num_predict": request.sampling.maxTokens,
        ]
        if let context = request.contextTokens { options["num_ctx"] = context }
        if let penalty = request.sampling.repetitionPenalty { options["repeat_penalty"] = penalty }
        if let seed = request.sampling.seed { options["seed"] = seed }
        var body: [String: Any] = [
            "model": endpoint.model, "stream": true, "options": options,
            "messages": ollamaMessages(request.messages),
        ]
        if !request.tools.isEmpty { body["tools"] = toolsJSON(request.tools) }
        let bytes = try await stream(endpoint.baseURL.appending(path: "api/chat"), token: token, body: body)
        var thinking = false
        var sawToolCall = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let object = parse(line) else { continue }
            if let error = object["error"] as? String { throw RemoteError.http(500, error) }
            if let message = object["message"] as? [String: Any] {
                if let text = message["thinking"] as? String, !text.isEmpty {
                    if !thinking { continuation.yield(.token("<think>")) }
                    thinking = true
                    continuation.yield(.token(text))
                }
                if let text = message["content"] as? String, !text.isEmpty {
                    if thinking { continuation.yield(.token("</think>")) }
                    thinking = false
                    continuation.yield(.token(text))
                }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { continue }
                    sawToolCall = true
                    continuation.yield(
                        .toolCall(
                            ToolCall(
                                id: "call_\(UUID().uuidString.prefix(8))", name: name, argumentsJSON: jsonString(function["arguments"]))))
                }
            }
            if object["done"] as? Bool == true {
                if thinking { continuation.yield(.token("</think>")) }
                let evalCount = object["eval_count"] as? Int ?? 0
                let evalSeconds = Double(object["eval_duration"] as? Int ?? 0) / 1e9
                continuation.yield(
                    .usage(
                        GenerationUsage(
                            promptTokens: object["prompt_eval_count"] as? Int ?? 0, completionTokens: evalCount,
                            tokensPerSecond: evalSeconds > 0 ? Double(evalCount) / evalSeconds : 0,
                            promptSeconds: Double(object["prompt_eval_duration"] as? Int ?? 0) / 1e9, generationSeconds: evalSeconds)))
                let reason: FinishReason = sawToolCall ? .toolCalls : (object["done_reason"] as? String == "length" ? .length : .stop)
                continuation.yield(.finished(reason))
                return
            }
        }
    }

    private static func ollamaMessages(_ messages: [EngineMessage]) -> [[String: Any]] {
        var names: [String: String] = [:]  // tool call id → tool name, for the results that answer them
        return messages.map { message in
            var out: [String: Any] = ["role": message.role.rawValue, "content": message.content]
            if !message.images.isEmpty { out["images"] = message.images.map { $0.data.base64EncodedString() } }
            if !message.toolCalls.isEmpty {
                for call in message.toolCalls { names[call.id] = call.name }
                out["tool_calls"] = message.toolCalls.map { call in
                    ["function": ["name": call.name, "arguments": object(call.argumentsJSON)]]
                }
            }
            if message.role == .tool, let id = message.toolCallID, let name = names[id] { out["tool_name"] = name }
            return out
        }
    }

    // OpenAI-compatible

    private static func streamOpenAI(
        _ endpoint: RemoteEndpoint, token: String?, request: GenerationRequest,
        into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        var body: [String: Any] = [
            "model": endpoint.model, "stream": true, "temperature": request.sampling.temperature, "top_p": request.sampling.topP,
            "max_tokens": request.sampling.maxTokens, "stream_options": ["include_usage": true],
            "messages": openAIMessages(request.messages),
        ]
        if let seed = request.sampling.seed { body["seed"] = seed }
        if !request.tools.isEmpty { body["tools"] = toolsJSON(request.tools) }
        let bytes = try await stream(endpoint.baseURL.appending(path: "v1/chat/completions"), token: token, body: body)
        var thinking = false
        var calls: [Int: (id: String, name: String, arguments: String)] = [:]
        var finish: FinishReason = .stop
        var usage: GenerationUsage?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let object = parse(payload) else { continue }
            if let error = object["error"] as? [String: Any] { throw RemoteError.http(500, error["message"] as? String ?? "\(error)") }
            if let u = object["usage"] as? [String: Any] {
                let completion = u["completion_tokens"] as? Int ?? 0
                let timings = object["timings"] as? [String: Any]
                usage = GenerationUsage(
                    promptTokens: u["prompt_tokens"] as? Int ?? 0, completionTokens: completion,
                    tokensPerSecond: timings?["predicted_per_second"] as? Double ?? 0)
            }
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { continue }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let text = delta["reasoning_content"] as? String, !text.isEmpty {
                if !thinking { continuation.yield(.token("<think>")) }
                thinking = true
                continuation.yield(.token(text))
            }
            if let text = delta["content"] as? String, !text.isEmpty {
                if thinking { continuation.yield(.token("</think>")) }
                thinking = false
                continuation.yield(.token(text))
            }
            // Tool calls arrive in pieces keyed by index: the name first, the arguments as a JSON string in fragments.
            for part in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = part["index"] as? Int ?? 0
                var call = calls[index] ?? (id: part["id"] as? String ?? "call_\(index)", name: "", arguments: "")
                if let function = part["function"] as? [String: Any] {
                    call.name += function["name"] as? String ?? ""
                    call.arguments += function["arguments"] as? String ?? ""
                }
                calls[index] = call
            }
            switch choice["finish_reason"] as? String {
            case "length": finish = .length
            case "tool_calls": finish = .toolCalls
            default: break
            }
        }
        if thinking { continuation.yield(.token("</think>")) }
        for (_, call) in calls.sorted(by: { $0.key < $1.key }) where !call.name.isEmpty {
            continuation.yield(
                .toolCall(ToolCall(id: call.id, name: call.name, argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments)))
            finish = .toolCalls
        }
        if let usage { continuation.yield(.usage(usage)) }
        continuation.yield(.finished(finish))
    }

    private static func openAIMessages(_ messages: [EngineMessage]) -> [[String: Any]] {
        messages.map { message in
            var out: [String: Any] = ["role": message.role.rawValue]
            if message.images.isEmpty {
                out["content"] = message.content
            } else {
                out["content"] =
                    [["type": "text", "text": message.content]]
                    + message.images.map { image -> [String: Any] in
                        ["type": "image_url", "image_url": ["url": "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"]]
                    }
            }
            if !message.toolCalls.isEmpty {
                out["tool_calls"] = message.toolCalls.map { call in
                    ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.argumentsJSON]]
                }
            }
            if let id = message.toolCallID { out["tool_call_id"] = id }
            return out
        }
    }

    // HTTP and JSON

    private static func toolsJSON(_ tools: [ToolSpec]) -> [[String: Any]] {
        tools.map { tool in
            [
                "type": "function",
                "function": ["name": tool.name, "description": tool.description, "parameters": object(tool.parametersJSONSchema)],
            ]
        }
    }

    private static func makeRequest(_ url: URL, token: String?, body: [String: Any]?, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func json(_ url: URL, token: String?, body: [String: Any]? = nil) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: makeRequest(url, token: token, body: body, timeout: 15))
        try check(response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteError.unreachable(String(localized: "the answer is not JSON"))
        }
        return object
    }

    /// Long timeout: a big prompt may take the server a while before the first token.
    private static func stream(_ url: URL, token: String?, body: [String: Any]) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await URLSession.shared.bytes(for: makeRequest(url, token: token, body: body, timeout: 600))
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

    private static func parse(_ line: String) -> [String: Any]? {
        guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func object(_ json: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
    }

    private static func jsonString(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value)
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
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
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        guard let engine = active else {
            continuation.finish(throwing: EngineError.noModelLoaded)
            return stream
        }
        let task = Task {
            do {
                for try await event in await engine.generate(request) { continuation.yield(event) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
