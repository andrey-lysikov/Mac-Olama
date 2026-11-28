//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

enum OpenAIResponses {
    private struct Request: Encodable {
        struct Reasoning: Encodable {
            var effort: String?
            var summary: String?
        }
        var model: String
        var stream = true
        var input: [JSON]
        var tools: [JSON]?
        var tool_choice = "auto"
        var parallel_tool_calls: Bool
        var reasoning: Reasoning?
        var store = false
        var include: [String] = []
        var max_output_tokens: Int?
        var prompt_cache_key: String?
    }

    private struct ReasoningTagger {
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

    static func stream(
        _ endpoint: RemoteEndpoint, token: String?, request: GenerationRequest,
        into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let lite = endpoint.responsesLite == true
        let toolDefinitions = request.tools.map {
            JSON.object([
                "type": .string("function"),
                "name": .string($0.name),
                "description": .string($0.description),
                "parameters": JSON.parse($0.parametersJSONSchema),
            ])
        }
        var input = messages(request.messages)
        let tools: [JSON]?
        if lite, !toolDefinitions.isEmpty {
            input.insert(
                .object([
                    "type": .string("additional_tools"),
                    "role": .string("developer"),
                    "tools": .array([
                        .object([
                            "type": .string("namespace"),
                            "name": .string("functions"),
                            "description": .string(""),
                            "tools": .array(toolDefinitions),
                        ])
                    ]),
                ]), at: 0)
            tools = nil
        } else {
            tools = toolDefinitions.isEmpty ? nil : toolDefinitions
        }
        let body = Request(
            model: endpoint.model, input: input, tools: tools, parallel_tool_calls: !lite,
            reasoning: request.thinkingEffort.map { .init(effort: $0, summary: request.thinks ? "auto" : "none") },
            max_output_tokens: request.sampling.maxTokens, prompt_cache_key: request.chatID?.uuidString)
        var urlRequest = URLRequest(url: endpoint.baseURL.appending(path: "responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        urlRequest.setValue("codex_cli_rs/0.166.0", forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        if let token { urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let chatID = request.chatID { urlRequest.setValue(chatID.uuidString, forHTTPHeaderField: "x-client-request-id") }
        if lite { urlRequest.setValue("true", forHTTPHeaderField: "x-openai-internal-codex-responses-lite") }
        endpoint.headers?.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        urlRequest.httpBody = try JSONCoding.plainEncoder.encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var data = Data()
            for try await byte in bytes.prefix(8192) { data.append(byte) }
            throw RemoteError.http(http.statusCode, errorMessage(data))
        }

        var tagger = ReasoningTagger()
        var calls: [String: ToolCall] = [:]
        var usage: GenerationUsage?
        var finish: FinishReason = .stop
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            let data = Data(payload.utf8)
            guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = event["type"] as? String
            else { continue }
            switch type {
            case "response.output_text.delta":
                tagger.content(event["delta"] as? String ?? "", into: continuation)
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                tagger.reasoning(event["delta"] as? String ?? "", into: continuation)
            case "response.output_item.done":
                if let item = event["item"] as? [String: Any] { recordCall(item, into: &calls) }
            case "response.completed", "response.incomplete":
                let response = event["response"] as? [String: Any] ?? [:]
                usage = generationUsage(response["usage"] as? [String: Any])
                for item in response["output"] as? [[String: Any]] ?? [] { recordCall(item, into: &calls) }
                if type == "response.incomplete" || response["status"] as? String == "incomplete" {
                    finish = .length
                }
            case "response.failed":
                let response = event["response"] as? [String: Any] ?? [:]
                let error = response["error"] as? [String: Any] ?? event["error"] as? [String: Any] ?? [:]
                throw RemoteError.http(500, (error["message"] as? String) ?? "OpenAI response failed")
            case "error":
                throw RemoteError.http(500, (event["message"] as? String) ?? errorMessage(data))
            default:
                break
            }
        }
        tagger.close(into: continuation)
        for call in calls.values.sorted(by: { $0.id < $1.id }) {
            continuation.yield(.toolCall(call))
        }
        if !calls.isEmpty { finish = .toolCalls }
        if let usage { continuation.yield(.usage(usage)) }
        continuation.yield(.finished(finish))
    }

    private static func messages(_ messages: [EngineMessage]) -> [JSON] {
        var result: [JSON] = []
        for message in messages {
            if message.role == .tool {
                result.append(
                    .object([
                        "type": .string("function_call_output"),
                        "call_id": .string(message.toolCallID ?? ""),
                        "output": .string(message.content),
                    ]))
                continue
            }
            let role = message.role == .system ? "developer" : message.role.rawValue
            let textType = message.role == .assistant ? "output_text" : "input_text"
            var content: [JSON] = []
            if !message.content.isEmpty || message.toolCalls.isEmpty {
                content.append(.object(["type": .string(textType), "text": .string(message.content)]))
            }
            if message.role == .user {
                content += message.images.map { image in
                    .object([
                        "type": .string("input_image"),
                        "image_url": .string("data:\(image.mimeType);base64,\(image.data.base64EncodedString())"),
                    ])
                }
            }
            if !content.isEmpty {
                result.append(.object(["type": .string("message"), "role": .string(role), "content": .array(content)]))
            }
            for call in message.toolCalls {
                result.append(
                    .object([
                        "type": .string("function_call"),
                        "call_id": .string(call.id),
                        "name": .string(call.name),
                        "arguments": .string(call.argumentsJSON),
                    ]))
            }
        }
        return result
    }

    private static func recordCall(_ item: [String: Any], into calls: inout [String: ToolCall]) {
        guard item["type"] as? String == "function_call", let name = item["name"] as? String else { return }
        let id = (item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
        guard calls[id] == nil else { return }
        let shortName = name.hasPrefix("functions.") ? String(name.dropFirst("functions.".count)) : name
        calls[id] = ToolCall(id: id, name: shortName, argumentsJSON: (item["arguments"] as? String) ?? "{}")
    }

    private static func generationUsage(_ raw: [String: Any]?) -> GenerationUsage? {
        guard let raw else { return nil }
        let details = raw["input_tokens_details"] as? [String: Any]
        return GenerationUsage(
            promptTokens: int(raw["input_tokens"]), completionTokens: int(raw["output_tokens"]),
            cachedTokens: int(details?["cached_tokens"]), tokensPerSecond: 0)
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? Int(value as? String ?? "") ?? 0
    }

    private static func errorMessage(_ data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        return (error?["message"] as? String) ?? (object?["error"] as? String) ?? (object?["detail"] as? String)
            ?? String(decoding: data.prefix(1000), as: UTF8.self)
    }
}
