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

enum HTTP {
    static let appUserAgent = "Mac-Olama/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15 "
        + appUserAgent

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

    static func allowsHost(_ host: String?, blockedHosts: Set<String>) async -> Bool {
        guard let host = host?.lowercased(), !blockedHosts.contains(host), !host.hasSuffix(".local"),
            !(await resolvesToLocal(host))
        else { return false }
        return true
    }
}

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

public struct DuckDuckGoProvider: SearchProvider {
    public let name = "duckduckgo"
    public init() {}

    public func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, _) = try await HTTP.get(c.url!)
        return try Self.parse(html: String(decoding: data, as: UTF8.self), limit: limit)
    }

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

public struct GoogleProvider: SearchProvider {
    public let name = "google"
    public init() {}

    public func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "gbv", value: "1"), URLQueryItem(name: "num", value: String(limit)),
        ]
        // VERIFY(google): basic HTML is served to text-browser user agents.
        let (data, _) = try await HTTP.get(c.url!, headers: ["User-Agent": "Lynx/2.9.0 libwww-FM/2.14 SSL-MM/1.4.1"])
        let results = try Self.parse(html: String(decoding: data, as: UTF8.self), limit: limit)
        return results.isEmpty ? try await DuckDuckGoProvider().search(query, limit: limit) : results
    }

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
                return  // anchor text is the title and URL, not the snippet
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
                name: "fetch_url",
                description:
                    "Fetch a web page and return its readable content as Markdown. For a video on YouTube, VK Video or Rutube it returns the title, the description and the transcript of what is said, with time marks: use it to summarize or retell a video.",
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
            // Video pages are read through their subtitles.
            if let video = await VideoTranscript.read(url, maxCharacters: configuration.maxPageCharacters) {
                return ToolOutput.wrap(video, source: raw)
            }
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
                // A remaining 3xx means RedirectGuard refused it.
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

// What is said in a video

enum VideoTranscript {
    enum Source: Equatable {
        case youtube(String)
        case rutube(String, key: String?)
        case vk(owner: String, id: String)
    }

    static func source(_ url: URL) -> Source? {
        guard let host = url.host()?.lowercased() else { return nil }
        func site(_ name: String) -> Bool { host == name || host.hasSuffix("." + name) }
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if host == "youtu.be" || site("youtube.com") || site("youtube-nocookie.com") {
            var id: String?
            if host == "youtu.be" {
                id = parts.first
            } else if parts.first == "watch" {
                id = value("v")
            } else if parts.count >= 2, ["shorts", "live", "embed", "v"].contains(parts[0]) {
                id = parts[1]
            }
            guard let id, id.wholeMatch(of: /[A-Za-z0-9_-]{6,20}/) != nil else { return nil }
            return .youtube(id)
        }
        if site("rutube.ru") {
            guard let id = parts.first(where: { $0.wholeMatch(of: /[0-9a-f]{32}/) != nil }) else { return nil }
            return .rutube(id, key: value("p"))
        }
        if site("vkvideo.ru") || site("vk.com") || site("vk.ru") {
            // VK video ids from the path or `z=`.
            if let match = url.absoluteString.firstMatch(of: /(?:video|clip)(-?\d+)_(\d+)/) {
                return .vk(owner: String(match.1), id: String(match.2))
            }
            if let owner = value("oid"), let id = value("id"), Int(owner) != nil, Int(id) != nil { return .vk(owner: owner, id: id) }
        }
        return nil
    }

    private struct Video {
        var site: String
        var title: String
        var channel: String?
        var seconds: Int?
        var description: String?
        var subtitles: (url: String, language: String, automatic: Bool)?
        var agent = HTTP.userAgent
    }

    static func read(_ url: URL, maxCharacters: Int) async -> String? {
        let video: Video?
        switch source(url) {
        case .youtube(let id): video = await youtube(id)
        case .rutube(let id, let key): video = await rutube(id, key: key)
        case .vk(let owner, let id): video = await vk(owner: owner, id: id)
        case nil: return nil
        }
        guard let video else { return nil }
        var lines = ["\(video.site) video: \(video.title)"]
        if let channel = video.channel, !channel.isEmpty { lines.append("Channel: " + channel) }
        if let seconds = video.seconds, seconds > 0 { lines.append("Length: " + clock(seconds)) }
        if let description = video.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            lines += ["", "Description:", String(description.prefix(600))]
        }
        guard let subtitles = video.subtitles, let address = URL(string: subtitles.url),
            let (data, _) = try? await HTTP.get(address, userAgent: video.agent, accept: nil),
            let text = transcript(cues(data)), !text.isEmpty
        else {
            lines += ["", "This video has no subtitles, so what is said in it cannot be read."]
            return lines.joined(separator: "\n")
        }
        lines += ["", "Transcript (\(subtitles.language)\(subtitles.automatic ? ", recognized automatically" : "")):"]
        // Videos get three times the page limit.
        let room = maxCharacters * 3
        lines.append(text.count > room ? String(text.prefix(room)) + "\n…[the transcript goes on; the rest was cut]" : text)
        return lines.joined(separator: "\n")
    }

    private static func clock(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func json(_ request: URLRequest) async -> [String: Any]? {
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func pick<Track>(_ tracks: [Track], language: (Track) -> String?, automatic: (Track) -> Bool) -> Track? {
        let spoken = tracks.first(where: automatic).flatMap(language)
        return tracks.first { !automatic($0) && language($0) == spoken } ?? tracks.first(where: automatic) ?? tracks.first
    }

    // YouTube

    private static let youtubeAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)"

    private static func youtube(_ id: String) async -> Video? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(youtubeAgent, forHTTPHeaderField: "User-Agent")
        let client: [String: Any] = ["clientName": "IOS", "clientVersion": "20.10.4", "deviceModel": "iPhone16,2", "hl": "en"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["context": ["client": client], "videoId": id])
        guard let player = await json(request), let details = player["videoDetails"] as? [String: Any] else { return nil }
        var video = Video(
            site: "YouTube", title: details["title"] as? String ?? id, channel: details["author"] as? String,
            seconds: (details["lengthSeconds"] as? String).flatMap(Int.init), description: details["shortDescription"] as? String,
            agent: youtubeAgent)
        let tracks =
            ((player["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any])?["captionTracks"]
            as? [[String: Any]] ?? []
        let automatic = { (track: [String: Any]) in track["kind"] as? String == "asr" }
        if let track = pick(tracks, language: { $0["languageCode"] as? String }, automatic: automatic), let base = track["baseUrl"] as? String {
            video.subtitles = (base + "&fmt=vtt", track["languageCode"] as? String ?? "", automatic(track))
        }
        return video
    }

    // Rutube

    private static func rutube(_ id: String, key: String?) async -> Video? {
        var address = "https://rutube.ru/api/play/options/\(id)/?no_404=true&referer=https%3A%2F%2Frutube.ru"
        if let key, key.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil { address += "&p=" + key }
        guard let url = URL(string: address), let (data, _) = try? await HTTP.get(url),
            let options = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let title = options["title"] as? String
        else { return nil }
        var video = Video(
            site: "Rutube", title: title, channel: (options["author"] as? [String: Any])?["name"] as? String,
            seconds: (options["duration"] as? NSNumber).map { $0.intValue / 1000 }, description: options["description"] as? String)
        let tracks = options["captions"] as? [[String: Any]] ?? []
        let automatic = { (track: [String: Any]) in track["is_autogenerated"] as? Bool ?? false }
        if let track = pick(tracks, language: { $0["code"] as? String }, automatic: automatic), let file = track["file"] as? String {
            video.subtitles = (file, track["code"] as? String ?? "", automatic(track))
        }
        return video
    }

    // VK Video

    private static func vk(owner: String, id: String) async -> Video? {
        let client = "52461373"
        func form(_ address: String, _ fields: [String: String]) -> URLRequest? {
            guard let url = URL(string: address) else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://vkvideo.ru", forHTTPHeaderField: "Origin")
            var body = URLComponents()
            body.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            return request
        }
        let scopes = "audio_anonymous,video_anonymous,photos_anonymous,profile_anonymous"
        guard
            let ask = form(
                "https://login.vk.ru/?act=get_anonym_token",
                ["client_id": client, "client_secret": "o557NLIkAErNhakXrQ7A", "scopes": scopes, "version": "1", "app_id": client]),
            let token = ((await json(ask))?["data"] as? [String: Any])?["access_token"] as? String,
            let get = form(
                "https://api.vkvideo.ru/method/video.get?v=5.245&client_id=" + client,
                ["videos": "\(owner)_\(id)", "extended": "1", "access_token": token]),
            let response = (await json(get))?["response"] as? [String: Any],
            let item = (response["items"] as? [[String: Any]])?.first, let title = item["title"] as? String,
            // A video closed to visitors who are not signed in comes back as a stub with no length.
            let seconds = (item["duration"] as? NSNumber)?.intValue, seconds > 0
        else { return nil }
        let group = (response["groups"] as? [[String: Any]])?.first?["name"] as? String
        let person = (response["profiles"] as? [[String: Any]])?.first.map {
            [$0["first_name"] as? String, $0["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
        }
        var video = Video(
            site: "VK", title: title, channel: group ?? person, seconds: seconds,
            description: item["description"] as? String)
        let tracks = item["subtitles"] as? [[String: Any]] ?? []
        let automatic = { (track: [String: Any]) in track["is_auto"] as? Bool ?? false }
        if let track = pick(tracks, language: { $0["lang"] as? String }, automatic: automatic), let file = track["url"] as? String {
            video.subtitles = (file, track["lang"] as? String ?? "", automatic(track))
        }
        return video
    }

    // Subtitles

    static func cues(_ data: Data) -> [(second: Int, text: String)] {
        var out: [(second: Int, text: String)] = []
        var second: Int?
        var last = ""
        for raw in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let time = line.firstMatch(of: /^(?:(\d+):)?(\d\d):(\d\d)[.,]\d+\s+-->/) {
                second = (time.1.flatMap { Int($0) } ?? 0) * 3600 + (Int(time.2) ?? 0) * 60 + (Int(time.3) ?? 0)
                continue
            }
            guard let second, !line.isEmpty else {
                if line.isEmpty { second = nil }
                continue
            }
            let text = line.replacing(/<[^>]*>/, with: "").replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text != last else { continue }
            last = text
            out.append((second, text))
        }
        return out
    }

    private static func transcript(_ cues: [(second: Int, text: String)]) -> String? {
        var paragraphs: [String] = []
        var mark = -1
        for cue in cues {
            if cue.second / 30 != mark {
                mark = cue.second / 30
                paragraphs.append("[" + clock(mark * 30) + "] " + cue.text)
            } else {
                paragraphs[paragraphs.count - 1] += " " + cue.text
            }
        }
        return paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n")
    }
}

// Shared page reading

enum WebFetch {
    enum FetchError: Error {
        case status(Int)
    }

    enum Content {
        case plain(Data)
        case page(title: String, markdown: String)
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
