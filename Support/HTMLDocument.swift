//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSoup

// HTML is read through SwiftSoup's HTML5 tree builder instead of regular expressions; pages reach the model as Markdown
// so headings, lists, tables, links and code survive extraction.

/// Small text helpers over the SwiftSoup DOM.
public enum HTMLText {
    /// Visible text of an HTML fragment with whitespace collapsed.
    public static func plainText(_ html: String) -> String {
        guard let document = try? SwiftSoup.parseBodyFragment(html), let text = try? document.text() else { return html }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All text nodes joined with spaces, so adjacent inline elements never glue together (`<a>x</a><b>y</b>` → "x y").
    static func spacedText(of node: Node) -> String {
        var parts: [String] = []
        collectText(node, into: &parts)
        return parts.joined(separator: " ")
    }

    private static func collectText(_ node: Node, into parts: inout [String]) {
        if let text = node as? TextNode {
            let collapsed = collapse(text.getWholeText()).trimmingCharacters(in: .whitespaces)
            if !collapsed.isEmpty { parts.append(collapsed) }
            return
        }
        for child in node.getChildNodes() { collectText(child, into: &parts) }
    }

    /// Turns every whitespace run into one space without trimming the ends (they separate inline elements).
    static func collapse(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var pendingSpace = false
        for character in s {
            if character.isWhitespace {
                pendingSpace = true
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(character)
            }
        }
        if pendingSpace { out.append(" ") }
        return out
    }
}

// Page extraction

public enum PageExtractor {
    public struct Page: Sendable, Equatable {
        public var title: String
        public var markdown: String
    }

    /// Page chrome that never carries the content itself.
    static let chrome = """
        script, style, noscript, template, svg, canvas, iframe, object, embed, form, button, input, select, textarea, \
        nav, footer, aside, dialog, [hidden], [aria-hidden=true], [role=navigation], [role=banner], [role=contentinfo], \
        [role=complementary]
        """

    /// Readable Markdown from HTML: drops chrome, prefers the main article, caps the length.
    /// `url` resolves relative links so the model can pass them to `fetch_url`.
    public static func extract(html: String, url: URL? = nil, maxCharacters: Int) throws -> Page {
        let document = try SwiftSoup.parse(html, url?.absoluteString ?? "")
        let title = HTMLText.collapse(try document.title()).trimmingCharacters(in: .whitespaces)
        try document.select(chrome).remove()
        let root = try mainContent(of: document)
        if root !== document.body() { try root.select("header").remove() }
        var markdown = HTMLMarkdown.convert(root)
        if markdown.count > maxCharacters { markdown = clip(markdown, to: maxCharacters) }
        return Page(title: title, markdown: markdown)
    }

    /// The longest `<article>` if it holds a real share of the page (listing pages have many small ones), else `<main>`, else body.
    static func mainContent(of document: Document) throws -> Element {
        let body = document.body() ?? document
        let bodyLength = try body.text().count
        let articles = try document.select("article").array().map { ($0, try $0.text().count) }
        if let best = articles.max(by: { $0.1 < $1.1 }), best.1 * 10 >= bodyLength * 3 { return best.0 }
        if let main = try document.select("main, [role=main]").first() { return main }
        return body
    }

    /// Cuts at a line break near the limit so the model does not see half a table row.
    static func clip(_ markdown: String, to limit: Int) -> String {
        var head = String(markdown.prefix(limit))
        if let newline = head.lastIndex(of: "\n"), head.distance(from: head.startIndex, to: newline) > limit * 4 / 5 {
            head = String(head[..<newline])
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n…"
    }
}

/// DOM → GitHub-flavoured Markdown for the model: structure survives, presentation does not. Images are dropped.
enum HTMLMarkdown {
    static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "caption", "center", "details", "dialog", "dd", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "html",
        "li", "main", "nav", "ol", "p", "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]

    static func convert(_ root: Element) -> String {
        blocks(of: root).joined(separator: "\n\n")
    }

    /// Children of a container: runs of inline content become paragraphs, block children render on their own.
    static func blocks(of element: Element) -> [String] {
        var out: [String] = []
        var line = ""
        func flush() {
            let paragraph = tidy(line)
            if !paragraph.isEmpty { out.append(paragraph) }
            line = ""
        }
        for node in element.getChildNodes() {
            guard let child = node as? Element, blockTags.contains(child.tagNameNormal()) else {
                line += inline(node)
                continue
            }
            flush()
            out += block(child)
        }
        flush()
        return out
    }

    static func block(_ element: Element) -> [String] {
        let tag = element.tagNameNormal()
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let text = singleLine(element)
            let level = Int(tag.dropFirst()) ?? 1
            return text.isEmpty ? [] : [String(repeating: "#", count: level) + " " + text]
        case "pre":
            return codeBlock(element)
        case "ul", "ol":
            let list = self.list(element, ordered: tag == "ol")
            return list.isEmpty ? [] : [list]
        case "li":
            let item = blocks(of: element).joined(separator: "\n")
            return item.isEmpty ? [] : [indentContinuation("- " + item, by: 2)]
        case "blockquote":
            let inner = blocks(of: element).joined(separator: "\n\n")
            return inner.isEmpty
                ? [] : [inner.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")]
        case "table":
            return table(element)
        case "hr":
            return ["---"]
        case "dl":
            let items = element.children().array().compactMap { child -> String? in
                let text = child.tagNameNormal() == "dt" ? singleLine(child) : blocks(of: child).joined(separator: "\n")
                guard !text.isEmpty else { return nil }
                return child.tagNameNormal() == "dt" ? "**\(text)**" : text
            }
            return items.isEmpty ? [] : [items.joined(separator: "\n")]
        default:
            return blocks(of: element)
        }
    }

    static func inline(_ node: Node) -> String {
        if let text = node as? TextNode { return HTMLText.collapse(text.getWholeText()) }
        guard let element = node as? Element else { return "" }
        let tag = element.tagNameNormal()
        switch tag {
        case "br": return "\n"
        case "img", "picture", "video", "audio": return ""
        case "code", "kbd", "samp", "tt": return code(HTMLText.collapse(rawText(element)))
        default: break
        }
        let inner = element.getChildNodes().map(inline).joined()
        switch tag {
        case "strong", "b": return wrap(inner, "**")
        case "em", "i": return wrap(inner, "*")
        case "del", "s", "strike": return wrap(inner, "~~")
        case "a": return link(element, text: inner)
        default: return blockTags.contains(tag) ? " \(inner) " : inner  // a block inside a link or span still separates words
        }
    }

    static func link(_ element: Element, text: String) -> String {
        let label = tidy(text).replacingOccurrences(of: "\n", with: " ")
        let absolute = (try? element.absUrl("href")) ?? ""
        let href = absolute.isEmpty ? ((try? element.attr("href")) ?? "") : absolute
        guard !label.isEmpty else { return "" }
        guard href.hasPrefix("http://") || href.hasPrefix("https://") else { return text }
        let leading = text.first?.isWhitespace == true ? " " : ""
        let trailing = text.last?.isWhitespace == true ? " " : ""
        return label == href ? "\(leading)<\(href)>\(trailing)" : "\(leading)[\(label)](\(href))\(trailing)"
    }

    static func list(_ element: Element, ordered: Bool) -> String {
        var number = Int((try? element.attr("start")) ?? "") ?? 1
        var items: [String] = []
        for item in element.children().array() {
            let content = blocks(of: item).joined(separator: "\n")
            guard !content.isEmpty else { continue }
            let marker = ordered ? "\(number)." : "-"
            number += 1
            items.append(indentContinuation("\(marker) \(content)", by: marker.count + 1))
        }
        return items.joined(separator: "\n")
    }

    static func codeBlock(_ element: Element) -> [String] {
        let code = rawText(element).trimmingCharacters(in: .newlines)
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let classes = ([element] + element.children().array()).compactMap { try? $0.className() }.joined(separator: " ")
        let language =
            classes.split(separator: " ").lazy.compactMap { name -> Substring? in
                if name.hasPrefix("language-") { return name.dropFirst("language-".count) }
                if name.hasPrefix("lang-") { return name.dropFirst("lang-".count) }
                return nil
            }.first.map(String.init) ?? ""
        let fence = code.contains("```") ? "~~~~" : "```"
        return ["\(fence)\(language)\n\(code)\n\(fence)"]
    }

    /// GFM table from the rows of this table (not of nested ones); single-column layout tables become plain blocks.
    static func table(_ element: Element) -> [String] {
        let rows = ((try? element.select("tr").array()) ?? []).filter { row in
            var parent = row.parent()
            while let current = parent, current.tagNameNormal() != "table" { parent = current.parent() }
            return parent === element
        }
        let cells = rows.map { row in
            row.children().array().filter { ["td", "th"].contains($0.tagNameNormal()) }.map {
                singleLine($0).replacingOccurrences(of: "|", with: "\\|")
            }
        }.filter { !$0.allSatisfy(\.isEmpty) }
        let columns = cells.map(\.count).max() ?? 0
        guard columns > 1 else { return blocks(of: element) }
        func line(_ row: [String]) -> String {
            "| " + (row + Array(repeating: "", count: columns - row.count)).joined(separator: " | ") + " |"
        }
        var lines = [line(cells[0]), line(Array(repeating: "---", count: columns))]
        lines += cells.dropFirst().map(line)
        return [lines.joined(separator: "\n")]
    }

    /// Text exactly as written (for code): whitespace kept, `<br>` as a newline.
    static func rawText(_ node: Node) -> String {
        if let text = node as? TextNode { return text.getWholeText() }
        if let element = node as? Element, element.tagNameNormal() == "br" { return "\n" }
        return node.getChildNodes().map(rawText).joined()
    }

    static func singleLine(_ element: Element) -> String {
        tidy(element.getChildNodes().map(inline).joined()).replacingOccurrences(of: "\n", with: " ")
    }

    static func code(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }
        let fence = trimmed.contains("`") ? "``" : "`"
        return "\(fence)\(trimmed)\(fence)"
    }

    /// Moves the element's outer whitespace outside the markers: `<b> x </b>` → ` **x** `.
    static func wrap(_ text: String, _ marker: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return text }
        let leading = text.first?.isWhitespace == true ? " " : ""
        let trailing = text.last?.isWhitespace == true ? " " : ""
        return leading + marker + trimmed + marker + trailing
    }

    /// Collapses spaces on every line and drops empty lines (left by `<br>` runs and whitespace-only nodes).
    static func tidy(_ text: String) -> String {
        text.split(separator: "\n").map { HTMLText.collapse(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func indentContinuation(_ text: String, by width: Int) -> String {
        let pad = String(repeating: " ", count: width)
        return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { $0.offset == 0 ? String($0.element) : pad + $0.element }.joined(separator: "\n")
    }
}
