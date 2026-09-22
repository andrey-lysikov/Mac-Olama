//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
import Testing

@testable import MacOlama

// Hub parsing: the places where a third-party format decides whether a download works at all.

@Suite struct HuggingFaceTests {
    @Test func lfsHashIsReadFromSha256OrOid() throws {
        let blobs =
            #"{"id":"a/b","siblings":[{"rfilename":"model.safetensors","size":10,"lfs":{"sha256":"abc","size":10,"pointerSize":134}}]}"#
        let tree = #"{"id":"a/b","siblings":[{"rfilename":"model.safetensors","lfs":{"oid":"def","size":7}}]}"#
        let fromBlobs = try HubClient.decoder.decode(HubModelInfo.self, from: Data(blobs.utf8))
        let fromTree = try HubClient.decoder.decode(HubModelInfo.self, from: Data(tree.utf8))
        #expect(fromBlobs.siblings[0].sha256 == "abc")
        #expect(fromTree.siblings[0].sha256 == "def")
        #expect(fromBlobs.totalBytes == 10)
        #expect(fromTree.totalBytes == 7)
    }

    @Test func gatedAcceptsBoolAndString() throws {
        let list = #"[{"id":"a/open","gated":false},{"id":"a/auto","gated":"auto"}]"#
        let models = try HubClient.decoder.decode([HubModelSummary].self, from: Data(list.utf8))
        #expect(models[0].isGated == false)
        #expect(models[1].isGated == true)
    }

    @Test(arguments: [
        ("mlx-community/Qwen3-8B-4bit", "mlx-community/Qwen3-8B-4bit"),
        ("https://huggingface.co/mlx-community/Qwen3-8B-4bit", "mlx-community/Qwen3-8B-4bit"),
        ("https://huggingface.co/mlx-community/Qwen3-8B-4bit/tree/main", "mlx-community/Qwen3-8B-4bit"),
    ])
    func repoIDIsParsed(input: String, expected: String) {
        #expect(HubClient.parseRepoID(input) == expected)
    }

    @Test func repoIDRejectsGarbage() {
        #expect(HubClient.parseRepoID("") == nil)
        #expect(HubClient.parseRepoID("just-a-name") == nil)
    }

    @Test func searchAsksForMLXOnly() {
        #expect(HubClient().searchURL(query: "qwen").absoluteString.contains("filter=mlx"))
    }

    @Test func classificationReadsFactsFromConfig() {
        let text = #"{"model_type":"qwen3","max_position_embeddings":32768,"quantization":{"bits":4,"group_size":64}}"#
        let vision = #"{"model_type":"gemma4","vision_config":{},"text_config":{"max_position_embeddings":131072}}"#
        let llm = HubModelClassification.classify(configJSON: Data(text.utf8))
        let vlm = HubModelClassification.classify(configJSON: Data(vision.utf8))
        #expect(llm.kind == .llm)
        #expect(llm.contextLength == 32768)
        #expect(llm.quantization == "4-bit g64")
        #expect(vlm.kind == .vlm)
        #expect(vlm.contextLength == 131_072)
    }

    @Test func recommendationsKeepOrderAndResolvePerHub() {
        #expect(RecommendedModels.names == ["Qwen 3.6", "Qwen 3 Coder", "Gemma 4", "Ornith 1.5"])
        #expect(RecommendedModels.query(for: "Gemma 4", in: .modelScope) == "gemma-4")
        #expect(RecommendedModels.query(for: "Gemma 4", in: .huggingFace) == "gemma-4")
        #expect(RecommendedModels.query(for: "Unknown", in: .modelScope) == nil)
    }
}

@Suite struct ModelScopeTests {
    @Test func referencesAreTellingHubsApart() {
        #expect(ModelReference.parse("mlx-community/Qwen3-8B-4bit") == .huggingFace(repoID: "mlx-community/Qwen3-8B-4bit"))
        #expect(ModelReference.parse("modelscope:mlx-community/Qwen3-8B-4bit") == .modelScope(repoID: "mlx-community/Qwen3-8B-4bit"))
        #expect(
            ModelReference.parse("https://modelscope.cn/models/lmstudio-community/gemma-4-12B-it-MLX-4bit/files")
                == .modelScope(repoID: "lmstudio-community/gemma-4-12B-it-MLX-4bit"))
        #expect(ModelReference.parse("gemma4") == nil)
    }

    @Test func directoryNamesRoundTrip() {
        for reference in [ModelReference.huggingFace(repoID: "mlx-community/Qwen3-8B-4bit"), .modelScope(repoID: "a/b--c")] {
            #expect(ModelReference(directoryName: reference.directoryName) == reference)
        }
    }

    @Test func directoryNamesAreFlatAndDistinct() {
        #expect(ModelReference.modelScope(repoID: "org/model").directoryName == "modelscope--org--model")
        #expect(ModelReference.huggingFace(repoID: "org/model").directoryName == "org--model")
        // The installed model's id is derived from the manifest's repoID; it must name the same folder.
        #expect(ModelDescriptor.directoryName(forRepo: ModelReference.modelScope(repoID: "org/model").repoID) == "modelscope--org--model")
    }

    @Test func searchAnswerIsParsed() throws {
        let json = """
            {"Code": 200, "Data": {"Model": {"TotalCount": 2, "Models": [
              {"Name": "gemma-4-12B-it-MLX-4bit", "Path": "lmstudio-community", "Tags": ["mlx"], "Libraries": ["mlx", "safetensors"],
               "Downloads": 135, "LastUpdatedTime": 1784910499, "StorageSize": 6773395357, "BaseModel": ["google/gemma-4-12B-it"],
               "ModelType": ["gemma4_unified"]},
              {"Name": "gemma-4-12b-it-GGUF", "Path": "unsloth", "Tags": ["gguf"], "Libraries": ["gguf"], "Downloads": 9}
            ]}}}
            """
        let models = try ModelScopeClient.parseSearch(Data(json.utf8))
        #expect(models.map(\.id) == ["lmstudio-community/gemma-4-12B-it-MLX-4bit", "unsloth/gemma-4-12b-it-GGUF"])
        #expect(models[0].isMLX && !models[1].isMLX)
        #expect(models[0].storageSize == 6_773_395_357)
        #expect(models[0].baseModel == "google/gemma-4-12B-it")
        #expect(models[0].lastUpdated == Date(timeIntervalSince1970: 1_784_910_499))
    }

    @Test func fileListKeepsBlobsWithHashes() {
        let json = """
            {"Code": 200, "Data": {"Files": [
              {"Path": "config.json", "Type": "blob", "Size": 5894, "Sha256": "677723368b4196b5"},
              {"Path": "sub", "Type": "tree", "Size": 0, "Sha256": ""},
              {"Path": "sub/tokenizer.json", "Type": "blob", "Size": 12, "Sha256": ""}
            ]}}
            """
        let files = ModelScopeClient.parseFiles(Data(json.utf8))
        #expect(
            files == [
                RepoFile(path: "config.json", size: 5894, sha256: "677723368b4196b5"),
                RepoFile(path: "sub/tokenizer.json", size: 12, sha256: nil),
            ])
    }
}

@Suite struct ModelOwnersTests {
    @Test func authorComesFromTheBaseModel() {
        let owners = ModelOwners(repoID: "modelscope:lmstudio-community/gemma-4-12B-it-MLX-4bit", baseModel: "google/gemma-4-12B-it")
        #expect(owners == ModelOwners(author: "google", community: "lmstudio-community"))
    }

    @Test func withoutBaseModelTheOwnerIsTheAuthor() {
        #expect(ModelOwners(repoID: "Qwen/Qwen3-8B-MLX-4bit", baseModel: nil) == ModelOwners(author: "Qwen", community: nil))
        #expect(
            ModelOwners(repoID: "google/gemma-4-12B-it", baseModel: "google/gemma-4-12B") == ModelOwners(author: "google", community: nil))
    }

    @Test func baseModelIsReadFromHubTags() {
        let tags = ["mlx", "base_model:google/gemma-4-12B-it", "base_model:quantized:google/gemma-4-12B-it"]
        #expect(ModelOwners.baseModel(fromTags: tags) == "google/gemma-4-12B-it")
        #expect(ModelOwners.baseModel(fromTags: ["mlx"]) == nil)
    }

    @Test func excludedFilesFollowPatterns() {
        let patterns = ["*.md", "LICENSE*", "*.gguf"]
        #expect(ModelDownloader.isExcluded("README.md", patterns: patterns))
        #expect(ModelDownloader.isExcluded("LICENSE.txt", patterns: patterns))
        #expect(!ModelDownloader.isExcluded("model.safetensors", patterns: patterns))
    }

    @Test func progressAggregatesAcrossConcurrentFiles() {
        let seen = Mutex<[DownloadProgress]>([])
        let reporter = DownloadProgressReporter(repoID: "a/b", fileCount: 2, totalBytes: 300) { p in
            seen.withLock { $0.append(p) }
        }
        reporter.started("one.bin", resumedFrom: 0)
        reporter.received("one.bin", total: 100, delta: 100)
        reporter.finished("one.bin", bytes: 100)
        reporter.started("two.bin", resumedFrom: 50)
        let last = seen.withLock { $0.last }
        #expect(last?.bytesReceived == 150)
        #expect(last?.bytesTotal == 300)
        #expect(last?.fileCount == 2)
        #expect(last?.currentFile == "two.bin")
    }

    @Test func listingPathsStayInsideStaging() throws {
        let dir = URL(fileURLWithPath: "/tmp/staging", isDirectory: true)
        let ok = try ModelDownloader.safeDestination(for: "sub/tokenizer.json", under: dir)
        #expect(ok.path == "/tmp/staging/sub/tokenizer.json")
        for bad in [
            "../../../Library/LaunchAgents/evil.plist", "/etc/passwd", "~/x", "a/../../b", "..", ".", "", "a/./b",
        ] {
            #expect(throws: HubError.unsafePath(bad)) { try ModelDownloader.safeDestination(for: bad, under: dir) }
        }
    }
}

// Remote models: the network is replaced by a URLProtocol that answers per path, so parsing is tested without a server.

final class RemoteStub: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (status: Int, body: String)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let (status, body) = Self.responses[url.path()] ?? (404, #"{"error":"not found"}"#)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct RemoteEngineTests {
    private let base = URL(string: "http://stub.test:11434")!

    init() { URLProtocol.registerClass(RemoteStub.self) }

    private func run() async throws -> [GenerationEvent] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try RemoteEndpoint(baseURL: base, model: "qwen3:8b").save(to: directory)
        let model = ModelDescriptor(
            id: "remote--stub", name: "qwen3:8b", repoID: "stub.test:11434/qwen3:8b", source: .remote, kind: .llm, directory: directory,
            sizeBytes: 0)
        let engine = RemoteEngine()
        try await engine.load(model) { _ in }
        var events: [GenerationEvent] = []
        for try await event in await engine.generate(GenerationRequest(messages: [EngineMessage(role: .user, content: "hi")])) {
            events.append(event)
        }
        return events
    }

    @Test func llamaServerProbeAndStream() async throws {
        RemoteStub.responses = [
            "/v1/models": (200, #"{"data":[{"id":"model.gguf"}]}"#),
            "/props": (
                200, #"{"chat_template":"{% if tools %}","modalities":{"vision":true},"default_generation_settings":{"n_ctx":8192}}"#
            ),
            "/v1/chat/completions": (
                200,
                """
                data: {"choices":[{"delta":{"reasoning_content":"plan"}}]}

                data: {"choices":[{"delta":{"content":"Hello"}}]}

                data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}

                data: [DONE]
                """
            ),
        ]
        let probe = try await RemoteEngine.probe(baseURL: base, model: "anything", token: nil)
        #expect(probe.model == "model.gguf" && probe.supportsTools && probe.supportsVision)
        let events = try await run()
        let tokens = events.compactMap { if case .token(let t) = $0 { t } else { nil } }
        #expect(tokens == ["<think>", "plan", "</think>", "Hello"])
        #expect(events.last == .finished(.stop))
    }

    @Test func missingModelIsReported() async throws {
        RemoteStub.responses = ["/v1/models": (200, #"{"data":[{"id":"llama3:8b"},{"id":"qwen2:7b"}]}"#)]
        await #expect(throws: RemoteError.self) { try await RemoteEngine.probe(baseURL: base, model: "qwen3:8b", token: nil) }
    }
}
