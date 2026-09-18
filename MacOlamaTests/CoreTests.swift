//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import MacOlama

// Estimates, prompts and scraping: logic whose mistakes are silent (a wrong verdict, a model that never searches).

@Suite struct HardwareTests {
    private func mac(memoryGB: UInt64, family: Int? = 4) -> HardwareProfile {
        let bytes = memoryGB * 1024 * 1024 * 1024
        return HardwareProfile(
            chipName: "Apple M4", family: family, tier: .base, gpuCores: 10, memoryBytes: bytes,
            wiredLimitBytes: UInt64(Double(bytes) * 0.67), bandwidthGBs: HardwareProfile.bandwidth(family: family, tier: .base))
    }

    // Regression: a 0.5 MB/token KV estimate once marked every model above ~5 GB as "will not fit" on a 16 GB Mac.
    @Test func sevenGigabyteModelFitsSixteenGigabyteMac() {
        let report = ModelFitReport.evaluate(modelBytes: 7_500_000_000, contextLength: 131_072, hardware: mac(memoryGB: 16))
        #expect(report.fit != .no)
    }

    @Test func modelLargerThanMemoryDoesNotFit() {
        let report = ModelFitReport.evaluate(modelBytes: 40_000_000_000, contextLength: 8192, hardware: mac(memoryGB: 16))
        #expect(report.fit == .no)
        #expect(report.stars == 1)
    }

    @Test func smallModelIsComfortable() {
        let report = ModelFitReport.evaluate(modelBytes: 2_000_000_000, contextLength: 8192, hardware: mac(memoryGB: 32))
        #expect(report.fit == .comfortable)
        #expect(report.estimatedTokensPerSecond > 10)
    }

    @Test func unknownNewChipIsNotSlowerThanTheNewestKnown() {
        let newestKnown = HardwareProfile.bandwidth(family: 5, tier: .max)
        #expect(HardwareProfile.bandwidth(family: 9, tier: .max) == newestKnown)
        #expect(HardwareProfile.bandwidth(family: nil, tier: .unknown) == 100)
    }
}

@Suite struct ConversationTests {
    private let web = ToolSpec(name: "web_search", description: "", parametersJSONSchema: "{}")
    private let fetch = ToolSpec(name: "fetch_url", description: "", parametersJSONSchema: "{}")

    @Test func guidanceAlwaysCarriesTheDate() {
        let text = ConversationService.guidance(toolSpecs: [], now: Date(timeIntervalSince1970: 1_789_689_600))
        #expect(text.contains("2026"))
        #expect(!text.contains("web_search"))
    }

    @Test func guidanceTellsTheModelToSearchWhenItCan() {
        let text = ConversationService.guidance(toolSpecs: [web, fetch])
        #expect(text.contains("web_search"))
        #expect(text.contains("fetch_url"))
        #expect(text.contains("Never say that you cannot browse"))
    }

    @Test func toolSupportComesFromTheChatTemplate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!ModelManifest.templateSupportsTools(in: directory))
        try Data(#"{"chat_template":"{% if tools %}…{% endif %}"}"#.utf8).write(
            to: directory.appendingPathComponent("tokenizer_config.json"))
        #expect(ModelManifest.templateSupportsTools(in: directory))
    }

    @Test(arguments: [("1.4", "1.3"), ("1.10", "1.9"), ("2.0", "1.99"), ("1.4.1", "1.4")])
    func versionsCompareNumerically(newer: String, older: String) {
        #expect(UpdateChecker.versionNumber(newer) > UpdateChecker.versionNumber(older))
    }
}

@Suite struct WebTests {
    @Test func entitiesAndTagsAreCleaned() {
        #expect(HTMLText.decodeEntities("a &amp; b &#x41; &#66;") == "a & b A B")
        #expect(HTMLText.plainText("<p>Hello <b>world</b></p>\n  twice") == "Hello world twice")
    }

    @Test func duckDuckGoResultsAreParsed() throws {
        let html = """
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&rut=1">Example <b>page</b></a>
            <a class="result__snippet">A short snippet</a>
            """
        let results = try DuckDuckGoProvider.parse(html: html, limit: 5)
        #expect(results == [SearchResult(title: "Example page", url: "https://example.com/page", snippet: "A short snippet")])
    }

    @Test func googleResultsSkipItsOwnLinks() throws {
        let html = """
            <a href="/url?q=https://example.com/a&sa=U"><h3><div>First</div></h3></a><div>Snippet one</div>
            <a href="/url?q=https://accounts.google.com/x&sa=U"><h3>Sign in</h3></a>
            <a href="/url?q=https://example.org/b&sa=U">no heading here</a>
            """
        let results = try GoogleProvider.parse(html: html, limit: 5)
        #expect(results.map(\.url) == ["https://example.com/a"])
        #expect(results[0].title == "First")
        #expect(results[0].snippet.contains("Snippet one"))
    }

    @Test func pageTextPrefersTheArticle() throws {
        let html = "<html><head><title>T</title></head><body><nav>menu</nav><article><p>Body text</p></article></body></html>"
        let page = try PageExtractor.extractText(html: html, maxCharacters: 1000)
        #expect(page.title == "T")
        #expect(page.text == "Body text")
    }
}
