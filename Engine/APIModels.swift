//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// Wire formats for the Ollama (`/api/*`) and OpenAI (`/v1/*`) surfaces. Field names follow the official docs.

// Shared helpers

/// JSON value that survives round-trips (tool arguments, options).
public enum JSON: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([JSON]), object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public func jsonString() -> String {
        (try? JSONCoding.plainEncoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func parse(_ text: String) -> JSON {
        (try? JSONCoding.plainDecoder.decode(JSON.self, from: Data(text.utf8))) ?? .object([:])
    }
}

/// Ollama `options` map → sampling params. Unknown keys are ignored.
public struct OllamaOptions: Codable, Sendable {
    public var temperature: Double?
    public var top_p: Double?
    public var top_k: Int?
    public var num_predict: Int?
    public var seed: Int?
    public var repeat_penalty: Double?
    public var num_ctx: Int?

    public func sampling(default base: SamplingParams) -> SamplingParams {
        var s = base
        if let temperature { s.temperature = temperature }
        if let top_p { s.topP = top_p }
        if let num_predict, num_predict > 0 { s.maxTokens = num_predict }
        if let seed { s.seed = UInt64(max(0, seed)) }
        if let repeat_penalty { s.repetitionPenalty = repeat_penalty }
        return s
    }
}

/// `keep_alive` accepts a number (seconds) or a duration string ("5m", "0", "-1").
public enum KeepAliveValue: EitherCodable, Sendable {
    case seconds(Double), text(String)

    public init(first: Double) { self = .seconds(first) }
    public init(second: String) { self = .text(second) }
    public var first: Double? { if case .seconds(let d) = self { d } else { nil } }
    public var second: String? { if case .text(let s) = self { s } else { nil } }
    public init(from decoder: Decoder) throws { self = try Self.decodeEither(from: decoder) }
    public func encode(to encoder: Encoder) throws { try encodeEither(to: encoder) }

    public var keepAlive: KeepAlive {
        switch self {
        case .seconds(let d): return d < 0 ? .forever : d == 0 ? .unloadNow : .seconds(d)
        case .text(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if t == "-1" || t == "forever" { return .forever }
            if t == "0" { return .unloadNow }
            let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600]
            if let last = t.last, let mult = units[last], let n = Double(t.dropLast()) { return n == 0 ? .unloadNow : .seconds(n * mult) }
            if let n = Double(t) { return n < 0 ? .forever : n == 0 ? .unloadNow : .seconds(n) }
            return .default
        }
    }
}

// Ollama

public struct OllamaToolCall: Codable, Sendable {
    public struct Function: Codable, Sendable {
        public var name: String
        public var arguments: JSON
    }
    public var function: Function
}

public struct OllamaMessage: Codable, Sendable {
    public var role: String
    /// Optional so that a streamed chunk (or a request) without it still decodes; always set on responses.
    public var content: String?
    public var images: [String]?  // base64
    public var tool_calls: [OllamaToolCall]?
    public var tool_name: String?

    public init(role: String, content: String, images: [String]? = nil, tool_calls: [OllamaToolCall]? = nil) {
        self.role = role
        self.content = content
        self.images = images
        self.tool_calls = tool_calls
    }
}

public struct OllamaTool: Codable, Sendable {
    public struct Function: Codable, Sendable {
        public var name: String
        public var description: String?
        public var parameters: JSON?
    }
    public var type: String
    public var function: Function
}

public struct OllamaChatRequest: Codable, Sendable {
    public var model: String
    public var messages: [OllamaMessage]
    public var stream: Bool?
    public var tools: [OllamaTool]?
    public var options: OllamaOptions?
    public var keep_alive: KeepAliveValue?
    public var think: Bool?
}

public struct OllamaGenerateRequest: Codable, Sendable {
    public var model: String
    public var prompt: String?
    public var system: String?
    public var images: [String]?
    public var stream: Bool?
    public var options: OllamaOptions?
    public var keep_alive: KeepAliveValue?
    public var raw: Bool?
}

public struct OllamaModelDetails: Codable, Sendable {
    public var parent_model: String = ""
    public var format: String = "mlx"
    public var family: String
    public var families: [String]
    public var parameter_size: String
    public var quantization_level: String
}

public struct OllamaModelSummary: Codable, Sendable {
    public var name: String
    public var model: String
    public var modified_at: Date
    public var size: Int64
    public var digest: String
    public var details: OllamaModelDetails
}

public struct OllamaTagsResponse: Codable, Sendable {
    public var models: [OllamaModelSummary]
}

public struct OllamaRunningModel: Codable, Sendable {
    public var name: String
    public var model: String
    public var size: Int64
    public var digest: String
    public var details: OllamaModelDetails
    public var expires_at: Date?
    public var size_vram: Int64
}

public struct OllamaPsResponse: Codable, Sendable {
    public var models: [OllamaRunningModel]
}

/// A request that names a model as `model` (current clients) or `name` (older ones).
public protocol OllamaModelRequest {
    var model: String? { get }
    var name: String? { get }
}

extension OllamaModelRequest {
    public var ref: String? { model ?? name }
}

public struct OllamaShowRequest: Codable, Sendable, OllamaModelRequest {
    public var model: String?
    public var name: String?
    public var verbose: Bool?
}

public struct OllamaShowResponse: Codable, Sendable {
    public var modelfile: String
    public var parameters: String
    public var template: String
    public var details: OllamaModelDetails
    public var model_info: [String: JSON]
    public var capabilities: [String]
    public var modified_at: Date
}

/// The `*_duration`/`*_count` tail both Ollama chunk kinds carry. The fields sit flat in the chunk JSON, so the
/// chunks keep their own stored properties and copy these in.
public struct OllamaTimings: Sendable {
    public var total_duration: Int64?
    public var load_duration: Int64?
    public var prompt_eval_count: Int?
    public var prompt_eval_duration: Int64?
    public var eval_count: Int?
    public var eval_duration: Int64?

    /// Metrics of a finished generation, in Ollama's nanosecond fields.
    public init(start: ContinuousClock.Instant, usage: GenerationUsage?) {
        total_duration = start.duration(to: .now).nanoseconds
        load_duration = 0
        prompt_eval_count = usage?.promptTokens
        prompt_eval_duration = usage.map { Int64($0.promptSeconds * 1e9) }
        eval_count = usage?.completionTokens
        eval_duration = usage.map { Int64($0.generationSeconds * 1e9) }
    }
}

// The chunk envelopes are optional-heavy: a final chunk carries no `message` at all. The server always fills the
// fields it writes.
public struct OllamaChatChunk: Codable, Sendable {
    public var model: String?
    public var created_at: Date?
    public var message: OllamaMessage?
    public var done: Bool
    public var done_reason: String?
    public var total_duration: Int64?
    public var load_duration: Int64?
    public var prompt_eval_count: Int?
    public var prompt_eval_duration: Int64?
    public var eval_count: Int?
    public var eval_duration: Int64?
}

extension OllamaChatChunk {
    /// Final chunk of a chat response. Lives in an extension so the memberwise initializer survives.
    public init(model: String, message: OllamaMessage, done_reason: String, timings: OllamaTimings) {
        self.init(
            model: model, created_at: .now, message: message, done: true, done_reason: done_reason,
            total_duration: timings.total_duration, load_duration: timings.load_duration,
            prompt_eval_count: timings.prompt_eval_count, prompt_eval_duration: timings.prompt_eval_duration,
            eval_count: timings.eval_count, eval_duration: timings.eval_duration)
    }
}

public struct OllamaGenerateChunk: Codable, Sendable {
    public var model: String
    public var created_at: Date
    public var response: String
    public var done: Bool
    public var done_reason: String?
    public var total_duration: Int64?
    public var load_duration: Int64?
    public var prompt_eval_count: Int?
    public var prompt_eval_duration: Int64?
    public var eval_count: Int?
    public var eval_duration: Int64?
}

extension OllamaGenerateChunk {
    /// Final chunk of a generate response. Lives in an extension so the memberwise initializer survives.
    public init(model: String, response: String, done_reason: String, timings: OllamaTimings) {
        self.init(
            model: model, created_at: .now, response: response, done: true, done_reason: done_reason,
            total_duration: timings.total_duration, load_duration: timings.load_duration,
            prompt_eval_count: timings.prompt_eval_count, prompt_eval_duration: timings.prompt_eval_duration,
            eval_count: timings.eval_count, eval_duration: timings.eval_duration)
    }
}

public struct OllamaPullRequest: Codable, Sendable, OllamaModelRequest {
    public var model: String?
    public var name: String?
    public var stream: Bool?
}

public struct OllamaPullStatus: Codable, Sendable {
    public var status: String
    public var digest: String?
    public var total: Int64?
    public var completed: Int64?
    public var error: String?
}

public struct OllamaDeleteRequest: Codable, Sendable, OllamaModelRequest {
    public var model: String?
    public var name: String?
}

public struct OllamaVersionResponse: Codable, Sendable {
    public var version: String
}

public struct APIErrorBody: Codable, Sendable {
    public var error: String
}

// OpenAI

/// `content` is either a string or an array of parts (`text` / `image_url`).
public enum OpenAIContent: EitherCodable, Sendable {
    public struct Part: Codable, Sendable {
        public struct ImageURL: Codable, Sendable { public var url: String }
        public var type: String
        public var text: String?
        public var image_url: ImageURL?
    }
    case text(String), parts([Part])

    public init(first: String) { self = .text(first) }
    public init(second: [Part]) { self = .parts(second) }
    public var first: String? { if case .text(let s) = self { s } else { nil } }
    public var second: [Part]? { if case .parts(let p) = self { p } else { nil } }
    public init(from decoder: Decoder) throws { self = try Self.decodeEither(from: decoder) }
    public func encode(to encoder: Encoder) throws { try encodeEither(to: encoder) }

    public var plainText: String {
        switch self {
        case .text(let s): return s
        case .parts(let p): return p.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
        }
    }

    /// data: URLs only; remote image URLs are not fetched by the server.
    public var imageDataURLs: [String] {
        if case .parts(let p) = self { return p.compactMap { $0.type == "image_url" ? $0.image_url?.url : nil } }
        return []
    }
}

/// Optional-heavy: streamed deltas carry the call in fragments (the id and name first, then argument pieces keyed by
/// `index`), so every field may be absent. The server always fills id, type and function when it writes one.
public struct OpenAIToolCall: Codable, Sendable {
    public struct Function: Codable, Sendable {
        public var name: String?
        public var arguments: String?
    }
    public var id: String?
    public var type: String? = "function"
    public var function: Function?
    public var index: Int?
}

public struct OpenAIMessage: Codable, Sendable {
    public var role: String
    public var content: OpenAIContent?
    public var tool_calls: [OpenAIToolCall]?
    public var tool_call_id: String?
    public var name: String?
}

/// Identical to Ollama's tool schema on the wire, so it is the same type.
public typealias OpenAITool = OllamaTool

public struct OpenAIChatRequest: Codable, Sendable {
    public var model: String
    public var messages: [OpenAIMessage]
    public var stream: Bool?
    public var temperature: Double?
    public var top_p: Double?
    public var max_tokens: Int?
    public var max_completion_tokens: Int?
    public var seed: Int?
    public var tools: [OpenAITool]?
    public var stream_options: StreamOptions?
    public struct StreamOptions: Codable, Sendable { public var include_usage: Bool? }

    public func sampling(default base: SamplingParams) -> SamplingParams {
        var s = base
        if let temperature { s.temperature = temperature }
        if let top_p { s.topP = top_p }
        if let m = max_completion_tokens ?? max_tokens, m > 0 { s.maxTokens = m }
        if let seed { s.seed = UInt64(max(0, seed)) }
        return s
    }
}

public struct OpenAIUsage: Codable, Sendable {
    // Optional because `RemoteEngine` decodes other servers' usage objects too; this server always fills all three.
    public var prompt_tokens: Int?
    public var completion_tokens: Int?
    public var total_tokens: Int?
}

// Optional-heavy because `RemoteEngine` decodes other servers' streams (whose chunks may omit any envelope field)
// through this type. The server always fills what it writes.
public struct OpenAIChatChunk: Codable, Sendable {
    public struct Choice: Codable, Sendable {
        public struct Delta: Codable, Sendable {
            public var role: String?
            public var content: String?
            /// Separate reasoning stream (DeepSeek-style servers); never written by this server.
            public var reasoning_content: String?
            public var tool_calls: [OpenAIToolCall]?
        }
        public var index: Int?
        public var delta: Delta?
        public var finish_reason: String?
    }
    /// llama-server appends its own metrics next to `usage`; read-only here.
    public struct Timings: Codable, Sendable {
        public var predicted_per_second: Double?
    }
    public var id: String?
    public var object: String? = "chat.completion.chunk"
    public var created: Int?
    public var model: String?
    public var choices: [Choice]?
    public var usage: OpenAIUsage?
    public var timings: Timings?
}

public struct OpenAIChatResponse: Codable, Sendable {
    public struct Choice: Codable, Sendable {
        public var index: Int
        public var message: OpenAIMessage
        public var finish_reason: String
    }
    public var id: String
    public var object: String = "chat.completion"
    public var created: Int
    public var model: String
    public var choices: [Choice]
    public var usage: OpenAIUsage
}

public struct OpenAICompletionRequest: Codable, Sendable {
    public var model: String
    public var prompt: String
    public var stream: Bool?
    public var temperature: Double?
    public var top_p: Double?
    public var max_tokens: Int?
}

public struct OpenAICompletionResponse: Codable, Sendable {
    public struct Choice: Codable, Sendable {
        public var index: Int
        public var text: String
        public var finish_reason: String?
    }
    public var id: String
    public var object: String
    public var created: Int
    public var model: String
    public var choices: [Choice]
    public var usage: OpenAIUsage?
}

public struct OpenAIModelList: Codable, Sendable {
    public struct Model: Codable, Sendable {
        public var id: String
        public var object: String = "model"
        public var created: Int
        public var owned_by: String = "library"
    }
    public var object: String = "list"
    public var data: [Model]
}

public struct OpenAIErrorBody: Codable, Sendable {
    public struct Detail: Codable, Sendable {
        // Optional so a remote server's error object decodes whatever fields it has; this server always fills both.
        public var message: String?
        public var type: String?
        public var code: String?
    }
    public var error: Detail
}
