//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

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

private struct ThinkingTagger {
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

    mutating func close(into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) {
        if thinking { continuation.yield(.token(Self.tags.close)) }
        thinking = false
    }
}

actor RemoteEngine: InferenceEngine {
    struct Probe: Sendable {
        var model: String
        var supportsTools: Bool
        var supportsVision: Bool
        var contextLength: Int?
    }

    private(set) var loadedModel: ModelDescriptor?
    private var endpoint: RemoteEndpoint?
    private var token: String?
    private var tokenRefreshers: [ModelSource: @Sendable () async throws -> String] = [:]
    private var quotaExhaustedHandlers: [ModelSource: @Sendable () async -> Void] = [:]
    private var currents: [UUID: GenerationTaskBox] = [:]

    func setTokenRefresher(_ refresher: @escaping @Sendable () async throws -> String, for source: ModelSource) {
        tokenRefreshers[source] = refresher
    }

    func setQuotaExhaustedHandler(_ handler: @escaping @Sendable () async -> Void, for source: ModelSource) {
        quotaExhaustedHandlers[source] = handler
    }

    func load(_ model: ModelDescriptor, progress: @Sendable @escaping (Double) -> Void) async throws {
        let endpoint = try RemoteEndpoint.load(from: model.directory)
        let token = RemoteTokens.token(for: model.id)
        progress(0.3)
        if CloudProvider(source: model.source)?.checksAvailability != false {
            _ = try await Self.probe(baseURL: endpoint.baseURL, model: endpoint.model, token: token, headers: endpoint.headers)
        }
        self.endpoint = endpoint
        self.token = token
        loadedModel = model
        progress(1)
    }

    func unload() async {
        loadedModel = nil
        endpoint = nil
        token = nil
    }

    func cancel(chatID: UUID) async {
        currents[chatID]?.cancel()
    }

    func cancelCurrent() async {
        for current in currents.values { current.cancel() }
    }

    func generate(_ request: GenerationRequest, model: ModelDescriptor) -> AsyncThrowingStream<GenerationEvent, Error> {
        let endpoint: RemoteEndpoint
        do {
            endpoint = try RemoteEndpoint.load(from: model.directory)
        } catch {
            return .failed(error)
        }
        // Each request owns its endpoint and token, so different remote models can run together.
        let token = RemoteTokens.token(for: model.id)
        let source = model.source
        let refresher = tokenRefreshers[source]
        let key = request.chatID ?? UUID()
        let current = GenerationTaskBox()
        currents[key] = current
        return .engine(current: current) { continuation in
            defer { Task { await self.removeCurrent(current, for: key) } }
            do {
                try await Self.stream(endpoint, token: token, request: request, source: source, into: continuation)
            } catch let error as RemoteError {
                await self.reportQuotaIfNeeded(error, source: source)
                guard case .http(let status, _) = error, status == 401, let refresher else { throw error }
                // The OAuth token expired: refresh it once and retry the request.
                let fresh = try await refresher()
                do {
                    try await Self.stream(endpoint, token: fresh, request: request, source: source, into: continuation)
                } catch let retryError as RemoteError {
                    await self.reportQuotaIfNeeded(retryError, source: source)
                    throw retryError
                }
            }
        }
    }

    private func removeCurrent(_ current: GenerationTaskBox, for key: UUID) {
        if currents[key] === current { currents[key] = nil }
    }

    private static func stream(
        _ endpoint: RemoteEndpoint, token: String?, request: GenerationRequest, source: ModelSource?,
        into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        if CloudProvider(source: source ?? .remote)?.usesResponsesAPI == true {
            try await OpenAIResponses.stream(endpoint, token: token, request: request, into: continuation)
        } else {
            try await streamOpenAI(endpoint, token: token, request: request, into: continuation)
        }
    }

    private func reportQuotaIfNeeded(_ error: RemoteError, source: ModelSource) async {
        guard let provider = CloudProvider(source: source), case .http(let status, _) = error else { return }
        guard provider.quotaHTTPStatuses.contains(status) else { return }
        await quotaExhaustedHandlers[source]?()
    }

    // Probe

    static let probeTimeout = 10

    static func probe(baseURL: URL, model: String, token: String?, headers: [String: String]? = nil) async throws -> Probe {
        try await withThrowingTaskGroup(of: Probe?.self) { group in
            group.addTask { try await probeServer(baseURL: baseURL, model: model, token: token, headers: headers) }
            group.addTask {
                try await Task.sleep(for: .seconds(probeTimeout))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let probe = first else { throw RemoteError.timedOut(probeTimeout) }
            return probe
        }
    }

    private static func probeServer(baseURL: URL, model: String, token: String?, headers: [String: String]?) async throws -> Probe {
        let models: [String: Any]
        do {
            models = try await json(baseURL.appending(path: "v1/models"), token: token, headers: headers)
        } catch let error as RemoteError {
            throw error
        } catch {
            throw RemoteError.unreachable(error.localizedDescription)
        }
        let names = (models["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        // llama-server answers under any model name.
        guard let name = match(model, in: names) ?? (names.count == 1 ? names[0] : nil) else {
            throw RemoteError.modelNotFound(model, available: names)
        }
        let props = try? await json(baseURL.appending(path: "props"), token: token, headers: headers)
        let template = props?["chat_template"] as? String ?? ""
        let modalities = props?["modalities"] as? [String: Any]
        let settings = props?["default_generation_settings"] as? [String: Any]
        return Probe(
            model: name, supportsTools: template.contains("tools"), supportsVision: modalities?["vision"] as? Bool ?? false,
            contextLength: settings?["n_ctx"] as? Int)
    }

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
            temperature: request.sampling.temperature, top_p: request.sampling.topP,
            max_tokens: request.sampling.maxTokens.map { min($0, endpoint.maximumOutputTokens ?? Int.max) },
            seed: request.sampling.seed.flatMap { Int(exactly: $0) }, tools: tools(request.tools),
            stream_options: .init(include_usage: true), presence_penalty: request.sampling.presencePenalty,
            frequency_penalty: request.sampling.frequencyPenalty, top_k: request.sampling.topK, min_p: request.sampling.minP,
            repetition_penalty: request.sampling.repetitionPenalty, reasoning_effort: request.thinkingEffort)
        let bytes = try await stream(
            endpoint.baseURL.appending(path: "v1/chat/completions"), token: token, body: body, headers: endpoint.headers)
        var tagger = ThinkingTagger()
        var finish: FinishReason = .stop
        var usage: GenerationUsage?
        // Tool calls arrive in fragments keyed by index.
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
                    cachedTokens: u.prompt_tokens_details?.cached_tokens ?? u.prompt_cache_hit_tokens ?? 0,
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
            let content: OpenAIContent? =
                // A tool-asking turn has no text: send null, not an empty string (Kimi rejects the latter).
                message.content.isEmpty && message.images.isEmpty && !message.toolCalls.isEmpty
                ? nil
                : message.images.isEmpty
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

    private static let chunkDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { _ in .distantPast }
        return d
    }()

    private static func json(
        _ url: URL, token: String?, body: [String: Any]? = nil, headers: [String: String]? = nil
    ) async throws -> [String: Any] {
        let encoded = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        var request = HTTPJSON.request(url, token: token, jsonBody: encoded, timeout: 15, accept: nil, userAgent: nil)
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteError.unreachable(String(localized: "the answer is not JSON"))
        }
        return object
    }

    private static func stream(
        _ url: URL, token: String?, body: some Encodable, headers: [String: String]? = nil
    ) async throws -> URLSession.AsyncBytes {
        var request = HTTPJSON.request(
            url, token: token, jsonBody: try JSONCoding.plainEncoder.encode(body), timeout: 600, accept: nil, userAgent: nil)
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
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

actor RoutingEngine: InferenceEngine {
    private let local: any InferenceEngine
    private let remote: any InferenceEngine
    private(set) var loadedModel: ModelDescriptor?

    init(local: any InferenceEngine, remote: any InferenceEngine) {
        self.local = local
        self.remote = remote
    }

    func load(_ model: ModelDescriptor, progress: @Sendable @escaping (Double) -> Void) async throws {
        let target = model.source.isRemote ? remote : local
        if !model.source.isRemote { loadedModel = nil }
        try await target.load(model, progress: progress)
        if !model.source.isRemote { loadedModel = model }
    }

    func unload() async {
        await local.unload()
        await remote.unload()
        loadedModel = nil
    }

    func cancel(chatID: UUID) async {
        await local.cancel(chatID: chatID)
        await remote.cancel(chatID: chatID)
    }

    func cancelCurrent() async {
        await local.cancelCurrent()
        await remote.cancelCurrent()
    }

    func generate(_ request: GenerationRequest, model: ModelDescriptor) -> AsyncThrowingStream<GenerationEvent, Error> {
        let engine = model.source.isRemote ? remote : local
        return .engine { continuation in
            for try await event in await engine.generate(request, model: model) { continuation.yield(event) }
        }
    }
}
