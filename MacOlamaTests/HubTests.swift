//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
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

    @Test func mlxFilterIsOptional() {
        let client = HubClient()
        #expect(client.searchURL(query: "qwen", mlxOnly: true).absoluteString.contains("filter=mlx"))
        #expect(!client.searchURL(query: "qwen", mlxOnly: false).absoluteString.contains("filter=mlx"))
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
        #expect(RecommendedModels.query(for: "Gemma 4", in: .ollama) == "gemma4")
        #expect(RecommendedModels.query(for: "Gemma 4", in: .huggingFace) == "gemma-4")
        #expect(RecommendedModels.query(for: "Unknown", in: .ollama) == nil)
    }
}

@Suite struct OllamaTests {
    @Test func referencesAreTellingHubsApart() {
        #expect(ModelReference.parse("mlx-community/Qwen3-8B-4bit") == .huggingFace(repoID: "mlx-community/Qwen3-8B-4bit"))
        #expect(ModelReference.parse("gemma4:12b-mlx") == .ollama(name: "gemma4", tag: "12b-mlx"))
        #expect(ModelReference.parse("https://ollama.com/library/gemma4:12b-mlx") == .ollama(name: "gemma4", tag: "12b-mlx"))
        #expect(ModelReference.parse("gemma4") == nil)
    }

    @Test func directoryNamesAreFlat() {
        #expect(ModelReference.ollama(name: "gemma4", tag: "12b-mlx").directoryName == "ollama--gemma4--12b-mlx")
        #expect(!ModelReference.huggingFace(repoID: "a/b").directoryName.contains("/"))
    }

    @Test func tagsPageIsParsed() {
        let html = """
            <a href="/library/gemma4:12b-mlx">gemma4:12b-mlx</a> <span>MLX</span> <span>7.7GB</span>
            <a href="/library/gemma4:12b">gemma4:12b</a> <span>GGUF</span> <span>8.1GB</span>
            """
        let tags = OllamaRegistryClient.parseTags(html: html, name: "gemma4")
        #expect(tags.map(\.tag) == ["12b-mlx", "12b"])
        #expect(tags[0].isMLX)
        #expect(!tags[1].isMLX)
        #expect(tags[0].sizeBytes == 7_700_000_000)
    }

    @Test func searchPageIsParsed() {
        let html = #"<a href="/library/gemma4"><p>Google's open model</p></a><a href="/library/gemma4:12b">tag</a>"#
        let entries = OllamaRegistryClient.parseSearch(html: html)
        #expect(entries.map(\.name) == ["gemma4"])
        #expect(entries[0].description == "Google's open model")
    }

    @Test func excludedFilesFollowPatterns() {
        let patterns = ["*.md", "LICENSE*", "*.gguf"]
        #expect(ModelDownloader.isExcluded("README.md", patterns: patterns))
        #expect(ModelDownloader.isExcluded("LICENSE.txt", patterns: patterns))
        #expect(!ModelDownloader.isExcluded("model.safetensors", patterns: patterns))
    }

    @Test func sha256MatchesKnownVector() {
        #expect(SHA256Hasher.hex(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
