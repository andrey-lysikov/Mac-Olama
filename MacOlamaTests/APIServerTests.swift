//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import MacOlama

// The local API as clients see it: a real server on a random port, a temporary models folder and an engine that plays
// back a fixed script, so the Ollama and OpenAI wire formats are checked end to end without loading a model.

/// Plays back `script` for every generation and remembers what it was asked.
actor ScriptedEngine: InferenceEngine {
    private(set) var loadedModel: ModelDescriptor?
    private(set) var requests: [GenerationRequest] = []
    private let script: [GenerationEvent]

    init(_ script: [GenerationEvent]) { self.script = script }

    func load(_ model: ModelDescriptor, progress: @Sendable @escaping (Double) -> Void) async throws { loadedModel = model }
    func unload() async { loadedModel = nil }
    func cancelCurrent() async {}

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        requests.append(request)
        let script = script
        return AsyncThrowingStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// One server with one installed model (`qwen3-8b-4bit`, 32K context, a chat template with tools); the folder is removed
/// on deinit.
final class APIFixture {
    static let repoID = "mlx-community/Qwen3-8B-4bit"
    static let answer: [GenerationEvent] = [
        .token("He"), .token("llo"), .usage(GenerationUsage(promptTokens: 5, completionTokens: 2, tokensPerSecond: 20)),
        .finished(.stop),
    ]

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("api-\(UUID().uuidString)")
    let engine: ScriptedEngine
    let catalog: ModelCatalog
    private(set) var server: APIServer!
    private(set) var port = 0

    init(script: [GenerationEvent] = APIFixture.answer, maxQueued: Int = 8) async throws {
        let folder = directory.appendingPathComponent(ModelDescriptor.directoryName(forRepo: Self.repoID))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ModelManifest(
            repoID: Self.repoID, kind: .llm, files: [], contextLength: 32768, quantization: "4bit"
        ).save(to: folder)
        try Data("{% if tools %}{% endif %}".utf8).write(to: folder.appendingPathComponent("chat_template.jinja"))
        catalog = ModelCatalog(modelsDirectory: directory)
        await catalog.refresh()
        engine = ScriptedEngine(script)
        let manager = EngineManager(engine: engine)
        // A random high port; a taken one is simply skipped.
        for _ in 0..<20 {
            let port = Int.random(in: 20000..<60000)
            let server = APIServer(
                configuration: .init(port: port, version: "9.9", maxQueued: maxQueued), catalog: catalog, engine: manager)
            if (try? server.start()) != nil {
                self.server = server
                self.port = port
                return
            }
        }
        throw APIError(500, "no free port for the test server")
    }

    deinit {
        server?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func call(_ method: String, _ path: String, _ body: String? = nil) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func object(_ method: String, _ path: String, _ body: String? = nil) async throws -> (status: Int, json: [String: Any]) {
        let (status, data) = try await call(method, path, body)
        return (status, try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    /// NDJSON (Ollama) or SSE (OpenAI) body as JSON objects; `[DONE]` is dropped.
    func lines(_ method: String, _ path: String, _ body: String) async throws -> [[String: Any]] {
        let (_, data) = try await call(method, path, body)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let payload = line.hasPrefix("data:") ? line.dropFirst(5).trimmingCharacters(in: .whitespaces) : String(line)
            return try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        }
    }
}

@Suite struct OllamaAPITests {
    @Test func versionIsMarkedAsThisApp() async throws {
        let api = try await APIFixture()
        let (status, json) = try await api.object("GET", "/api/version")
        #expect(status == 200 && json["version"] as? String == "9.9-macolama")
        // The startup probe must not mistake this app for Ollama and step aside from its own port.
        #expect(await APIServer.probe(port: api.port) == .occupied)
    }

    @Test func tagsListModelsTheWayOllamaNamesThem() async throws {
        let api = try await APIFixture()
        let models = try #require(try await api.object("GET", "/api/tags").json["models"] as? [[String: Any]])
        #expect(models.count == 1)
        #expect(models[0]["name"] as? String == "qwen3-8b-4bit:latest")
        #expect((models[0]["digest"] as? String)?.hasPrefix("sha256:") == true)
        let details = try #require(models[0]["details"] as? [String: Any])
        #expect(details["family"] as? String == "qwen3" && details["parameter_size"] as? String == "8B")
        #expect(details["quantization_level"] as? String == "4bit" && details["format"] as? String == "mlx")
    }

    @Test func showReportsCapabilitiesAndContext() async throws {
        let api = try await APIFixture()
        let (status, json) = try await api.object("POST", "/api/show", #"{"model":"qwen3-8b-4bit"}"#)
        #expect(status == 200)
        #expect(json["capabilities"] as? [String] == ["completion", "tools"])
        let info = try #require(json["model_info"] as? [String: Any])
        #expect(info["qwen3.context_length"] as? Int == 32768)
    }

    @Test func chatStreamsNDJSONAndEndsWithMetrics() async throws {
        let api = try await APIFixture()
        let chunks = try await api.lines(
            "POST", "/api/chat", #"{"model":"qwen3-8b-4bit:latest","messages":[{"role":"user","content":"hi"}]}"#)
        let texts = chunks.compactMap { ($0["message"] as? [String: Any])?["content"] as? String }
        #expect(texts.joined() == "Hello")
        #expect(chunks.dropLast().allSatisfy { $0["done"] as? Bool == false })
        let last = try #require(chunks.last)
        #expect(last["done"] as? Bool == true && last["done_reason"] as? String == "stop")
        #expect(last["eval_count"] as? Int == 2 && last["prompt_eval_count"] as? Int == 5)
    }

    @Test func chatWithoutStreamingAnswersOnce() async throws {
        let api = try await APIFixture()
        let (status, json) = try await api.object(
            "POST", "/api/chat", #"{"model":"qwen3-8b-4bit","stream":false,"messages":[{"role":"user","content":"hi"}]}"#)
        #expect(status == 200 && json["done"] as? Bool == true)
        #expect((json["message"] as? [String: Any])?["content"] as? String == "Hello")
    }

    @Test func toolCallsComeBackWithObjectArguments() async throws {
        let api = try await APIFixture(script: [
            .toolCall(ToolCall(id: "call_1", name: "web_search", argumentsJSON: #"{"query":"x"}"#)), .finished(.toolCalls),
        ])
        let (_, json) = try await api.object(
            "POST", "/api/chat",
            #"""
            {"model":"qwen3-8b-4bit","stream":false,"messages":[{"role":"user","content":"hi"}],
             "tools":[{"type":"function","function":{"name":"web_search","description":"Search","parameters":{"type":"object"}}}]}
            """#)
        let calls = try #require((json["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]])
        let function = try #require(calls.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "web_search")
        #expect((function["arguments"] as? [String: Any])?["query"] as? String == "x")
        #expect(json["done_reason"] as? String == "tool_calls")
        let request = try #require(await api.engine.requests.last)
        #expect(request.tools.map(\.name) == ["web_search"])
    }

    @Test func optionsAndKeepAliveReachTheEngine() async throws {
        let api = try await APIFixture()
        _ = try await api.call(
            "POST", "/api/chat",
            #"""
            {"model":"qwen3-8b-4bit","stream":false,"keep_alive":"-1","messages":[{"role":"user","content":"hi"}],
             "options":{"temperature":0.2,"top_p":0.5,"num_predict":64,"seed":7,"repeat_penalty":1.1,"num_ctx":4096}}
            """#)
        let request = try #require(await api.engine.requests.last)
        #expect(request.sampling == SamplingParams(temperature: 0.2, topP: 0.5, maxTokens: 64, repetitionPenalty: 1.1, seed: 7))
        #expect(request.keepAlive == .forever && request.contextTokens == 4096)
    }

    @Test func toolResultIsTiedToItsToolByName() async throws {
        let api = try await APIFixture()
        _ = try await api.call(
            "POST", "/api/chat",
            #"""
            {"model":"qwen3-8b-4bit","stream":false,"messages":[
              {"role":"user","content":"time?"},
              {"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_time","arguments":{}}}]},
              {"role":"tool","content":"12:00","tool_name":"get_time"}]}
            """#)
        let messages = try #require(await api.engine.requests.last?.messages)
        #expect(messages.map(\.role) == [.user, .assistant, .tool])
        #expect(messages[1].toolCalls.map(\.name) == ["get_time"] && messages[1].toolCalls[0].argumentsJSON == "{}")
        #expect(messages[2].toolCallID == "get_time" && messages[2].content == "12:00")
    }

    @Test func generateTakesSystemAndPrompt() async throws {
        let api = try await APIFixture()
        let (_, json) = try await api.object(
            "POST", "/api/generate", #"{"model":"qwen3-8b-4bit","stream":false,"system":"Be brief.","prompt":"hi"}"#)
        #expect(json["response"] as? String == "Hello" && json["done"] as? Bool == true)
        let messages = try #require(await api.engine.requests.last?.messages)
        #expect(messages == [EngineMessage(role: .system, content: "Be brief."), EngineMessage(role: .user, content: "hi")])
    }

    @Test func emptyPromptLoadsAndUnloadsOnly() async throws {
        let api = try await APIFixture()
        let (_, loaded) = try await api.object("POST", "/api/generate", #"{"model":"qwen3-8b-4bit"}"#)
        #expect(loaded["done_reason"] as? String == "load")
        #expect(await api.engine.loadedModel?.name == "qwen3-8b-4bit")
        #expect(await api.engine.requests.isEmpty)
        let running = try #require(try await api.object("GET", "/api/ps").json["models"] as? [[String: Any]])
        #expect(running.map { $0["name"] as? String } == ["qwen3-8b-4bit:latest"])

        _ = try await api.call("POST", "/api/generate", #"{"model":"qwen3-8b-4bit","keep_alive":0}"#)
        #expect(await api.engine.loadedModel == nil)
        #expect((try await api.object("GET", "/api/ps").json["models"] as? [Any])?.isEmpty == true)
    }

    @Test func unknownModelIs404() async throws {
        let api = try await APIFixture()
        let (status, json) = try await api.object("POST", "/api/chat", #"{"model":"nope","messages":[]}"#)
        #expect(status == 404 && (json["error"] as? String)?.contains("nope") == true)
    }

    @Test func textModelRejectsImages() async throws {
        let api = try await APIFixture()
        let (status, _) = try await api.call(
            "POST", "/api/chat", #"{"model":"qwen3-8b-4bit","messages":[{"role":"user","content":"?","images":["iVBORw0KGgo="]}]}"#)
        #expect(status == 400)
    }

    @Test func pullNeedsARepositoryAndADownloader() async throws {
        let api = try await APIFixture()
        #expect(try await api.call("POST", "/api/pull", #"{"model":"llama3"}"#).status == 400)
        #expect(try await api.call("POST", "/api/pull", #"{"model":"mlx-community/Qwen3-8B-4bit"}"#).status == 501)
    }

    @Test func deleteRemovesTheModel() async throws {
        let api = try await APIFixture()
        #expect(try await api.call("DELETE", "/api/delete", #"{"model":"qwen3-8b-4bit"}"#).status == 200)
        #expect((try await api.object("GET", "/api/tags").json["models"] as? [Any])?.isEmpty == true)
        #expect(try await api.call("DELETE", "/api/delete", #"{"model":"qwen3-8b-4bit"}"#).status == 404)
    }

    @Test(arguments: ["/api/embed", "/api/embeddings", "/api/create", "/api/push", "/api/copy"])
    func unsupportedEndpointsSayNotImplemented(path: String) async throws {
        let api = try await APIFixture()
        #expect(try await api.call("POST", path, "{}").status == 501)
    }

    @Test func unknownPathIs404AndRootAnswers() async throws {
        let api = try await APIFixture()
        #expect(try await api.call("GET", "/api/nothing").status == 404)
        let (status, data) = try await api.call("GET", "/")
        #expect(status == 200 && String(decoding: data, as: UTF8.self).contains("running"))
    }

    @Test func fullQueueAnswers503() async throws {
        let api = try await APIFixture(maxQueued: 0)
        let (status, _) = try await api.call(
            "POST", "/api/chat", #"{"model":"qwen3-8b-4bit","stream":false,"messages":[{"role":"user","content":"hi"}]}"#)
        #expect(status == 503)
    }
}

@Suite struct OpenAIAPITests {
    @Test func modelsAreListedByShortName() async throws {
        let api = try await APIFixture()
        let data = try #require(try await api.object("GET", "/v1/models").json["data"] as? [[String: Any]])
        #expect(data.map { $0["id"] as? String } == ["qwen3-8b-4bit"])
    }

    @Test func chatAnswersWithUsage() async throws {
        let api = try await APIFixture()
        let (status, json) = try await api.object(
            "POST", "/v1/chat/completions",
            #"{"model":"qwen3-8b-4bit","max_completion_tokens":32,"max_tokens":16,"messages":[{"role":"user","content":"hi"}]}"#)
        #expect(status == 200)
        let choice = try #require((json["choices"] as? [[String: Any]])?.first)
        #expect((choice["message"] as? [String: Any])?["content"] as? String == "Hello")
        #expect(choice["finish_reason"] as? String == "stop")
        #expect((json["usage"] as? [String: Any])?["total_tokens"] as? Int == 7)
        // `max_completion_tokens` is the newer name and wins over `max_tokens`.
        #expect(await api.engine.requests.last?.sampling.maxTokens == 32)
    }

    @Test func chatStreamsSSEWithRoleFirstAndUsageLast() async throws {
        let api = try await APIFixture()
        let (_, data) = try await api.call(
            "POST", "/v1/chat/completions",
            #"{"model":"qwen3-8b-4bit","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"hi"}]}"#
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("data: [DONE]\n\n"))
        let chunks = try await api.lines(
            "POST", "/v1/chat/completions",
            #"{"model":"qwen3-8b-4bit","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"hi"}]}"#
        )
        let deltas = chunks.compactMap { (($0["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]) }
        #expect(deltas.first?["role"] as? String == "assistant")
        #expect(deltas.compactMap { $0["content"] as? String }.joined() == "Hello")
        let last = try #require(chunks.last)
        #expect((last["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "stop")
        #expect((last["usage"] as? [String: Any])?["completion_tokens"] as? Int == 2)
    }

    @Test func toolCallsKeepTheirIDsAndStringArguments() async throws {
        let api = try await APIFixture(script: [
            .toolCall(ToolCall(id: "call_9", name: "get_time", argumentsJSON: #"{"zone":"UTC"}"#)), .finished(.toolCalls),
        ])
        let (_, json) = try await api.object(
            "POST", "/v1/chat/completions", #"{"model":"qwen3-8b-4bit","messages":[{"role":"user","content":"time?"}]}"#)
        let choice = try #require((json["choices"] as? [[String: Any]])?.first)
        #expect(choice["finish_reason"] as? String == "tool_calls")
        let call = try #require(((choice["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call_9")
        #expect((call["function"] as? [String: Any])?["arguments"] as? String == #"{"zone":"UTC"}"#)
    }

    @Test func textModelRefusesImageParts() async throws {
        let api = try await APIFixture()
        _ = try await api.call(
            "POST", "/v1/chat/completions",
            #"""
            {"model":"qwen3-8b-4bit","messages":[{"role":"user","content":[
              {"type":"text","text":"what is it?"},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,/9j/4AAQ"}}]}]}
            """#)
        // A text-only model refuses the image before it reaches the engine.
        #expect(await api.engine.requests.isEmpty)
    }

    @Test func completionsAnswerPlainText() async throws {
        let api = try await APIFixture()
        let (_, json) = try await api.object("POST", "/v1/completions", #"{"model":"qwen3-8b-4bit","prompt":"hi"}"#)
        let choice = try #require((json["choices"] as? [[String: Any]])?.first)
        #expect(json["object"] as? String == "text_completion" && choice["text"] as? String == "Hello")
    }

    @Test func errorsUseTheOpenAIShape() async throws {
        let api = try await APIFixture()
        let (status, json) = try await api.object("POST", "/v1/chat/completions", #"{"model":"nope","messages":[]}"#)
        #expect(status == 404)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "invalid_request_error")
        #expect(try await api.call("POST", "/v1/chat/completions", "not json").status == 400)
        #expect(try await api.call("POST", "/v1/embeddings", "{}").status == 501)
    }
}

// Wire values that clients send in more than one shape.

@Suite struct APIWireTests {
    @Test(arguments: [
        ("\"5m\"", KeepAlive.seconds(300)), ("\"2h\"", .seconds(7200)), ("\"30s\"", .seconds(30)), ("\"0\"", .unloadNow),
        ("\"-1\"", .forever), ("\"forever\"", .forever), ("\"0m\"", .unloadNow), ("\"soon\"", .default),
        ("120", .seconds(120)), ("0", .unloadNow), ("-1", .forever),
    ])
    func keepAliveAcceptsNumbersAndDurations(json: String, expected: KeepAlive) throws {
        #expect(try JSONDecoder().decode(KeepAliveValue.self, from: Data(json.utf8)).keepAlive == expected)
    }

    @Test func ollamaOptionsKeepDefaultsForWhatIsMissing() {
        let base = SamplingParams(temperature: 0.7, topP: 0.9, maxTokens: 100)
        var options = OllamaOptions()
        #expect(options.sampling(default: base) == base)
        options.num_predict = 0  // "no limit" in Ollama: the default stays
        options.seed = -5
        let s = options.sampling(default: base)
        #expect(s.maxTokens == 100 && s.seed == 0)
    }

    @Test func imagesAreDecodedFromBase64AndDataURLs() throws {
        let jpeg = try APIServer.decodeImage(Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
        #expect(jpeg.mimeType == "image/jpeg" && jpeg.data == Data([0xFF, 0xD8, 0xFF]))
        #expect(try APIServer.decodeImage(Data([0x89, 0x50]).base64EncodedString()).mimeType == "image/png")
        let url = try APIServer.decodeImage("data:image/webp;base64,AAEC")
        #expect(url.mimeType == "image/webp" && url.data == Data([0, 1, 2]))
        #expect(throws: APIError.self) { try APIServer.decodeDataURL("https://example.com/cat.png") }
        #expect(throws: APIError.self) { try APIServer.decodeImage("***") }
    }
}

// Model catalog and remote endpoints on disk.

@Suite struct CatalogTests {
    @Test func modelsResolveByAnyNameAClientMaySend() async throws {
        let api = try await APIFixture()
        for reference in ["qwen3-8b-4bit", "qwen3-8b-4bit:latest", "mlx-community/Qwen3-8B-4bit", "MLX-COMMUNITY--QWEN3-8B-4BIT"] {
            #expect(await api.catalog.resolve(reference)?.repoID == APIFixture.repoID, "\(reference)")
        }
        #expect(await api.catalog.resolve("qwen3") == nil)
    }

    @Test func truncatedModelIsListedAsBroken() async throws {
        let api = try await APIFixture()
        let folder = api.directory.appendingPathComponent("org--broken")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ModelManifest(repoID: "org/broken", kind: .llm, files: [.init(path: "model.safetensors", sizeBytes: 10)]).save(to: folder)
        await api.catalog.refresh()
        #expect(await api.catalog.models.count == 1)
        #expect(await api.catalog.brokenModels.map(\.id) == ["org--broken"])
    }

    /// Models connected before only the OpenAI API was spoken still carry `"api": "ollama"`; they must keep loading.
    @Test func olderRemoteFileStillLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"baseURL":"http://localhost:11434","model":"qwen3:8b","api":"ollama"}"#.utf8)
            .write(to: directory.appendingPathComponent(RemoteEndpoint.fileName))
        let endpoint = try RemoteEndpoint.load(from: directory)
        #expect(endpoint == RemoteEndpoint(baseURL: URL(string: "http://localhost:11434")!, model: "qwen3:8b"))
    }

    @Test func remoteFolderNamesAreFlat() {
        let endpoint = RemoteEndpoint(baseURL: URL(string: "http://192.168.1.5:8080")!, model: "org/model:Q4 K")
        #expect(endpoint.hostAndPort == "192.168.1.5:8080")
        #expect(endpoint.directoryName == "remote--192.168.1.5_8080--org_model_Q4_K")
    }
}
