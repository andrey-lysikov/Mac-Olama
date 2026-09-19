//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Markdown

// swift-markdown (cmark-gfm) parses the reply into a tree; this file flattens it into blocks for `MarkdownView`.
// Kept free of SwiftUI: both modules export `Text`, `Image` and `Link`.

/// Marks the run that stands for a formula; `MarkdownView` draws it with SwiftMath instead of its placeholder text.
enum FormulaAttribute: AttributedStringKey {
    typealias Value = Formula
    static let name = "com.macolama.formula"
}

/// Splits a Markdown string into renderable blocks; inline styles become Foundation attributes that SwiftUI `Text` draws.
enum MarkdownBlocks {
    enum Kind {
        case paragraph
        case header(level: Int)
        case listItem(marker: String)
        case codeBlock(language: String?)
        case thematicBreak
        case table(rows: [[AttributedString]])
        /// A display formula standing alone in its paragraph: typeset larger and centred.
        case formula(Formula)
    }

    struct Block: Identifiable {
        let id: Int
        var kind: Kind
        var text: AttributedString
        var indent = 0
        var quoteDepth = 0
    }

    static func parse(_ markdown: String) -> [Block] {
        let (source, formulas) = MathText.extract(markdown)
        var builder = Builder(formulas: formulas)
        for child in Document(parsing: source).children { builder.block(child, indent: 0, quote: 0) }
        return builder.blocks
    }

    /// Ids are block positions, so views stay stable while a streamed reply grows.
    private struct Builder {
        let formulas: [Formula]
        var blocks: [Block] = []

        mutating func add(_ kind: Kind, _ text: AttributedString = AttributedString(), indent: Int, quote: Int) {
            blocks.append(Block(id: blocks.count, kind: kind, text: text, indent: indent, quoteDepth: quote))
        }

        mutating func block(_ markup: any Markup, indent: Int, quote: Int) {
            switch markup {
            case let heading as Heading:
                add(.header(level: heading.level), inline(heading), indent: indent, quote: quote)
            case let paragraph as Paragraph:
                let text = inline(paragraph)
                if let formula = Self.soleDisplayFormula(text) {
                    add(.formula(formula), indent: indent, quote: quote)
                } else {
                    add(.paragraph, text, indent: indent, quote: quote)
                }
            case let code as CodeBlock:
                add(
                    .codeBlock(language: code.language.flatMap { $0.isEmpty ? nil : $0 }), AttributedString(code.code), indent: indent,
                    quote: quote)
            case is ThematicBreak:
                add(.thematicBreak, indent: indent, quote: quote)
            case let blockQuote as BlockQuote:
                for child in blockQuote.children { block(child, indent: indent, quote: quote + 1) }
            case let list as OrderedList:
                items(Array(list.listItems), start: Int(list.startIndex), indent: indent, quote: quote)
            case let list as UnorderedList:
                items(Array(list.listItems), start: nil, indent: indent, quote: quote)
            case let table as Table:
                let builder = self  // lazy maps must not capture the mutating self
                var rows: [[AttributedString]] = [Array(table.head.cells.map { builder.inline($0) })]
                rows += table.body.rows.map { row in Array(row.cells.map { builder.inline($0) }) }
                add(.table(rows: rows), indent: indent, quote: quote)
            case let html as HTMLBlock:
                add(.paragraph, AttributedString(html.rawHTML.trimmingCharacters(in: .newlines)), indent: indent, quote: quote)
            default:
                for child in markup.children { block(child, indent: indent, quote: quote) }
            }
        }

        /// The first paragraph shares the line with the marker; the rest of the item (nested lists, code) goes one level deeper.
        mutating func items(_ items: [ListItem], start: Int?, indent: Int, quote: Int) {
            for (offset, item) in items.enumerated() {
                var marker = start.map { "\($0 + offset)." } ?? "•"
                if let checkbox = item.checkbox { marker = checkbox == .checked ? "☑" : "☐" }
                var children = Array(item.children)
                if let paragraph = children.first as? Paragraph {
                    add(.listItem(marker: marker), inline(paragraph), indent: indent, quote: quote)
                    children.removeFirst()
                } else {
                    add(.listItem(marker: marker), indent: indent, quote: quote)
                }
                for child in children { block(child, indent: indent + 1, quote: quote) }
            }
        }

        /// The paragraph is one `$$…$$` formula and nothing else (whitespace aside).
        static func soleDisplayFormula(_ text: AttributedString) -> Formula? {
            let formulas = text.runs.compactMap { $0[FormulaAttribute.self] }
            guard formulas.count == 1, let formula = formulas.first, formula.display else { return nil }
            let rest = text.runs.filter { $0[FormulaAttribute.self] == nil }.map { String(text[$0.range].characters) }.joined()
            return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? formula : nil
        }

        /// Plain text with formula tokens: each token becomes a run carrying its formula (the run text is the LaTeX).
        func text(_ string: String) -> AttributedString {
            guard string.contains(MathText.tokenStart) else { return AttributedString(string) }
            var out = AttributedString()
            var rest = Substring(string)
            while let start = rest.firstIndex(of: MathText.tokenStart),
                let end = rest[start...].firstIndex(of: MathText.tokenEnd),
                let index = Int(rest[rest.index(after: start)..<end]), formulas.indices.contains(index)
            {
                out.append(AttributedString(String(rest[..<start])))
                var piece = AttributedString(formulas[index].latex)
                piece[FormulaAttribute.self] = formulas[index]
                out.append(piece)
                rest = rest[rest.index(after: end)...]
            }
            out.append(AttributedString(String(rest)))
            return out
        }

        func inline(_ markup: any Markup) -> AttributedString {
            var out = AttributedString()
            for child in markup.children { out.append(inlineNode(child)) }
            return out
        }

        func inlineNode(_ markup: any Markup) -> AttributedString {
            switch markup {
            case let text as Markdown.Text: return self.text(text.string)
            case is SoftBreak: return AttributedString(" ")
            case is LineBreak: return AttributedString("\n")
            case let code as InlineCode: return Self.styled(AttributedString(code.code), .code)
            case is Emphasis: return Self.styled(inline(markup), .emphasized)
            case is Strong: return Self.styled(inline(markup), .stronglyEmphasized)
            case is Strikethrough: return Self.styled(inline(markup), .strikethrough)
            case let html as InlineHTML: return AttributedString(html.rawHTML)
            case let link as Markdown.Link:
                var text = inline(link)
                if let destination = link.destination, let url = URL(string: destination) { text.link = url }
                return text
            default: return inline(markup)  // images show their alt text
            }
        }

        /// Adds an intent to every run, keeping the ones already there (bold inside italic stays both).
        static func styled(_ text: AttributedString, _ intent: InlinePresentationIntent) -> AttributedString {
            var text = text
            let runs = text.runs.map { ($0.range, $0.inlinePresentationIntent ?? []) }
            for (range, existing) in runs { text[range].inlinePresentationIntent = existing.union(intent) }
            return text
        }
    }
}
