//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSoup

// Search providers

public struct SearchResult: Sendable, Equatable, Codable {
    public var title: String
    public var url: String
    public var snippet: String
}

public protocol SearchProvider: Sendable {
    var name: String { get }
    func search(_ query: String, limit: Int) async throws -> [SearchResult]
}

/// Shared fetch with a browser-like UA and a hard timeout.
enum HTTP {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15 Mac-Olama/0.1"

    /// `userAgent`/`accept` nil = do not set the header (the session's defaults apply).
    static func get(
        _ url: URL, timeout: TimeInterval = 15, headers: [String: String] = [:], maxBytes: Int? = nil,
        userAgent: String? = HTTP.userAgent, accept: String? = "text/html,application/json;q=0.9,*/*;q=0.8",
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        guard let maxBytes else {
            let (data, response) = try await URLSession.shared.data(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
        // Capped read: the body stops at maxBytes instead of buffering whatever the server sends.
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var data = Data()
        data.reserveCapacity(min(maxBytes, 1 << 20))
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxBytes { break }
        }
        return (data, http)
    }

    /// True when any address `host` resolves to is loopback, private or link-local (getaddrinfo also accepts
    /// literal IPs; both families are checked because the connection may use either). Resolution failure blocks.
    static func resolvesToLocal(_ host: String) async -> Bool {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return true }
            defer { freeaddrinfo(first) }
            var node: UnsafeMutablePointer<addrinfo>? = first
            while let current = node {
                if let address = SocketAddress.numericHost(current.pointee.ai_addr, length: current.pointee.ai_addrlen),
                    NetworkToolProvider.isLocal(address)
                {
                    return true
                }
                node = current.pointee.ai_next
            }
            return false
        }.value
    }

    /// Whether this host may be fetched at all: not on the block list, not this Mac's own network.
    static func allowsHost(_ host: String?, blockedHosts: Set<String>) async -> Bool {
        guard let host = host?.lowercased(), !blockedHosts.contains(host), !host.hasSuffix(".local"),
            !(await resolvesToLocal(host))
        else { return false }
        return true
    }
}

/// Follows redirects only to http(s) URLs whose host is neither blocked nor resolving to a local address.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    private let blockedHosts: Set<String>

    init(blockedHosts: Set<String>) { self.blockedHosts = blockedHosts }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let blocked = blockedHosts
        Task {
            guard let url = request.url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                await HTTP.allowsHost(url.host, blockedHosts: blocked)
            else { return completionHandler(nil) }
            completionHandler(request)
        }
    }
}

/// DuckDuckGo HTML endpoint: no API key, parsed from the DOM. Fragile by nature; kept as the zero-config default.
public struct DuckDuckGoProvider: SearchProvider {
    public let name = "duckduckgo"
    public init() {}

    public func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, _) = try await HTTP.get(c.url!)
        return try Self.parse(html: String(decoding: data, as: UTF8.self), limit: limit)
    }

    /// Result links `a.result__a` and snippets `a.result__snippet` come in document order; a snippet belongs to the link before it.
    static func parse(html: String, limit: Int) throws -> [SearchResult] {
        let document = try SwiftSoup.parse(html, "https://html.duckduckgo.com/html/")
        var results: [SearchResult] = []
        var collecting = false
        for element in try document.select("a.result__a, a.result__snippet").array() {
            if element.hasClass("result__snippet") {
                if collecting, let last = results.indices.last, results[last].snippet.isEmpty {
                    results[last].snippet = try element.text()
                }
                continue
            }
            var href = try element.attr("href")
            // DDG wraps links as //duckduckgo.com/l/?uddg=<encoded>
            if let range = href.range(of: "uddg="),
                let decoded = href[range.upperBound...].split(separator: "&").first?.removingPercentEncoding
            {
                href = decoded
            }
            if href.hasPrefix("//") { href = "https:" + href }
            let title = try element.text()
            collecting = !href.isEmpty && !title.isEmpty
            if collecting { results.append(SearchResult(title: title, url: href, snippet: "")) }
        }
        return Array(results.prefix(limit))
    }
}

/// Google's basic-HTML results page (`gbv=1`): no API key, parsed from the DOM.
/// Google may answer with a JavaScript or consent wall instead; then the query falls back to DuckDuckGo so the tool keeps working.
public struct GoogleProvider: SearchProvider {
    public let name = "google"
    public init() {}

    public func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "gbv", value: "1"), URLQueryItem(name: "num", value: String(limit)),
        ]
        // VERIFY(google): the basic-HTML page is served to text browsers; a regular Safari UA gets the JavaScript version.
        let (data, _) = try await HTTP.get(c.url!, headers: ["User-Agent": "Lynx/2.9.0 libwww-FM/2.14 SSL-MM/1.4.1"])
        let results = try Self.parse(html: String(decoding: data, as: UTF8.self), limit: limit)
        return results.isEmpty ? try await DuckDuckGoProvider().search(query, limit: limit) : results
    }

    /// Result links are `<a href="/url?q=<target>&…">` with an `<h3>` title; the snippet is the text up to the next result link.
    static func parse(html: String, limit: Int) throws -> [SearchResult] {
        let document = try SwiftSoup.parse(html, "https://www.google.com/")
        var results: [SearchResult] = []
        var snippets: [[String]] = []
        var current: Int?
        func walk(_ node: Node) throws {
            if let text = node as? TextNode {
                let piece = HTMLText.collapse(text.getWholeText()).trimmingCharacters(in: .whitespaces)
                if let current, !piece.isEmpty, snippets[current].joined().count < 300 { snippets[current].append(piece) }
                return
            }
            guard let element = node as? Element else { return }
            if element.tagNameNormal() == "a", let href = try? element.attr("href"), href.hasPrefix("/url?"),
                let heading = try element.select("h3").first()
            {
                current = nil
                let target = URLComponents(string: href)?.queryItems?.first { $0.name == "q" }?.value ?? ""
                let title = try heading.text()
                if let host = URL(string: target)?.host, !host.hasSuffix("google.com"), !title.isEmpty,
                    !results.contains(where: { $0.url == target })
                {
                    results.append(SearchResult(title: title, url: target, snippet: ""))
                    snippets.append([])
                    current = results.count - 1
                }
                return  // the link's own text is the title and the displayed URL, not the snippet
            }
            for child in element.getChildNodes() { try walk(child) }
        }
        try walk(document)
        for index in results.indices {
            var snippet = snippets[index].joined(separator: " ")
            if snippet.count > 300 { snippet = String(snippet.prefix(300)) + "…" }
            results[index].snippet = snippet
        }
        return Array(results.prefix(limit))
    }
}

// Tool provider

/// `web_search` and `fetch_url` for tool calling. Results are wrapped as untrusted data for the model.
public struct WebToolProvider: ToolProvider {
    public struct Configuration: Sendable {
        // Enough candidates to choose from and pages read far enough to compare sources.
        public var maxResults = 8
        public var maxPageCharacters = 12_000
        public var blockedHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]
        public var maxFetchBytes = 8 << 20
        public var timeout: TimeInterval = 15
        public init() {}
    }

    let provider: any SearchProvider
    let configuration: Configuration

    public init(provider: any SearchProvider = DuckDuckGoProvider(), configuration: Configuration = .init()) {
        self.provider = provider
        self.configuration = configuration
    }

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "web_search",
                description:
                    "Search the internet for current information: news, recent events, prices, releases, anything after your training data or that you are unsure about. Returns titles, URLs and snippets. Use fetch_url to read a result in full.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"query":{"type":"string","description":"Search query"}},"required":["query"]}"#),
            ToolSpec(
                name: "fetch_url", description: "Fetch a web page and return its readable content as Markdown.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"url":{"type":"string","description":"Absolute http(s) URL"}},"required":["url"]}"#),
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        switch call.name {
        case "web_search":
            guard let query = args.string("query"), !query.isEmpty else { return toolFailure(missing: "query") }
            let results = try await provider.search(query, limit: configuration.maxResults)
            if results.isEmpty { return "No results." }
            let body = results.enumerated().map { i, r in "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)" }.joined(separator: "\n")
            return ToolOutput.wrap(body, source: "web_search: \(query)")
        case "fetch_url":
            guard let raw = args.string("url"), let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                ["http", "https"].contains(scheme)
            else {
                return "error: url must be an absolute http(s) URL"
            }
            guard await HTTP.allowsHost(url.host, blockedHosts: configuration.blockedHosts) else { return "error: host is not allowed" }
            let content: WebFetch.Content
            do {
                content = try await WebFetch.readable(
                    url: url, maxCharacters: configuration.maxPageCharacters, badStatus: 300,
                    timeout: configuration.timeout, maxBytes: configuration.maxFetchBytes,
                    delegate: RedirectGuard(blockedHosts: configuration.blockedHosts),
                    isRaw: { contentType in
                        let lowered = contentType.lowercased()
                        return ["image/", "video/", "audio/", "font/"].contains(where: lowered.hasPrefix)
                            || ["octet-stream", "/pdf", "/zip", "/gzip"].contains(where: lowered.contains)
                    })
            } catch WebFetch.FetchError.status(let code) {
                // Redirects are followed automatically, so a surviving 3xx means RedirectGuard refused the target.
                return (300..<400).contains(code) ? "error: redirect blocked (target not allowed)" : "error: HTTP \(code)"
            }
            switch content {
            case .plain(let data):
                return ToolOutput.wrap(String(decoding: data.prefix(configuration.maxPageCharacters), as: UTF8.self), source: raw)
            case .page(let title, let markdown):
                return ToolOutput.wrap((title.isEmpty ? "" : "Title: \(title)\n\n") + markdown, source: raw)
            case .other(_, let contentType, _):
                return "error: unsupported content type \(contentType)"
            }
        default:
            throw ConversationError.unknownTool(call.name)
        }
    }
}

// Shared page reading

/// One pipeline for `fetch_url` and pasted links: GET, then JSON and plain text as they are, HTML through
/// PageExtractor; anything `isRaw` claims comes back untouched for the caller to handle (PDF) or refuse.
enum WebFetch {
    enum FetchError: Error {
        case status(Int)
    }

    enum Content {
        /// A JSON or text/plain body, not clipped: each caller caps it its own way.
        case plain(Data)
        /// Readable HTML, already capped at `maxCharacters` by the extractor.
        case page(title: String, markdown: String)
        /// A content type `isRaw` claimed; `url` is the final one after redirects.
        case other(data: Data, contentType: String, url: URL)
    }

    static func readable(
        url: URL, maxCharacters: Int, badStatus: Int = 400, timeout: TimeInterval = 15, maxBytes: Int? = nil,
        delegate: (any URLSessionTaskDelegate)? = nil, isRaw: (String) -> Bool = { _ in false }
    ) async throws -> Content {
        let (data, http) = try await HTTP.get(url, timeout: timeout, maxBytes: maxBytes, delegate: delegate)
        guard http.statusCode < badStatus else { throw FetchError.status(http.statusCode) }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if isRaw(contentType) { return .other(data: data, contentType: contentType, url: http.url ?? url) }
        if contentType.contains("json") || contentType.contains("text/plain") { return .plain(data) }
        let page = try PageExtractor.extract(
            html: String(decoding: data, as: UTF8.self), url: http.url ?? url, maxCharacters: maxCharacters)
        return .page(title: page.title, markdown: page.markdown)
    }
}
