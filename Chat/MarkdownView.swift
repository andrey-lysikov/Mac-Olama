//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct MarkdownView: View {
    let markdown: String
    var baseFontSize: CGFloat = 13
    var streaming = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if streaming {
            let (stable, tail) = MarkdownStreamSplit.split(markdown)
            VStack(alignment: .leading, spacing: 8) {
                if !stable.isEmpty { blocksView(MarkdownCache.blocks(for: String(stable))) }
                // Unfinished markup is not drawn raw: a placeholder stands in until the block
                // is complete, then it renders formatted. Plain prose keeps streaming as text.
                switch MarkdownStreamSplit.tailKind(of: tail) {
                case .empty: EmptyView()
                case .prose:
                    Text(String(tail)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code:
                    TailPlaceholder(symbol: "chevron.left.forwardslash.chevron.right", title: String(localized: "Writing code…"))
                case .markup:
                    TailPlaceholder(symbol: "text.alignleft", title: String(localized: "Formatting…"))
                }
            }
            .font(.system(size: baseFontSize))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                blocksView(MarkdownCache.blocks(for: markdown))
            }
            .font(.system(size: baseFontSize))
        }
    }

    @ViewBuilder
    private func blocksView(_ blocks: [MarkdownBlocks.Block]) -> some View {
        ForEach(blocks) { block in render(block).padding(.leading, CGFloat(block.indent) * 16) }
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlocks.Block) -> some View {
        switch block.kind {
        case .header(let level):
            let size = baseFontSize + CGFloat(max(0, 4 - level)) * 2
            text(block.text, size: size).font(.system(size: size, weight: .semibold)).padding(.top, 3)
        case .paragraph:
            text(block.text).textSelection(.enabled).padding(.leading, CGFloat(block.quoteDepth) * 12)
                .overlay(alignment: .leading) { if block.quoteDepth > 0 { Rectangle().fill(.quaternary).frame(width: 3) } }
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                text(block.text).textSelection(.enabled)
            }
        case .codeBlock(let language):
            CodeBlockView(code: String(block.text.characters), language: language, fontSize: baseFontSize - 1)
        case .formula(let formula):
            FormulaBlockView(formula: formula, fontSize: baseFontSize)
        case .thematicBreak:
            Divider()
        case .table(let rows):
            // No horizontal scroll (unclipped when nested); cells wrap.
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            text(cell).fontWeight(index == 0 ? .semibold : .regular)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

extension MarkdownView {
    fileprivate func text(_ attributed: AttributedString, size: CGFloat? = nil) -> Text {
        var styled = attributed
        let fontSize = size ?? baseFontSize
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                styled[run.range].font = .system(size: fontSize - 0.5, design: .monospaced)
                styled[run.range].backgroundColor = Color.primary.opacity(0.07)
            } else if intent.contains(.stronglyEmphasized) {
                let font = Font.system(size: fontSize, weight: .semibold)
                styled[run.range].font = intent.contains(.emphasized) ? font.italic() : font
            }
        }
        // Links: accent colour, underline and ↗; inserted backwards to keep ranges valid.
        for (url, range) in styled.runs[\.link].reversed() {
            guard let url else { continue }
            styled[range].foregroundColor = .accentColor
            styled[range].underlineStyle = .single
            var arrow = AttributedString("\u{2009}\u{2197}\u{FE0E}")  // thin space, ↗ in text (not emoji) presentation
            arrow.link = url
            arrow.foregroundColor = .accentColor
            styled.insert(arrow, at: range.upperBound)
        }
        return FormulaRenderer.text(styled, fontSize: fontSize, dark: colorScheme == .dark)
    }
}

@MainActor
enum MarkdownCache {
    private final class Entry {
        let blocks: [MarkdownBlocks.Block]
        init(_ blocks: [MarkdownBlocks.Block]) { self.blocks = blocks }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 8 << 20  // cost = source length
        return cache
    }()

    static func blocks(for text: String) -> [MarkdownBlocks.Block] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let parsed = MarkdownBlocks.parse(text)
        cache.setObject(Entry(parsed), forKey: key, cost: text.utf16.count)
        return parsed
    }
}

struct CodeFence {
    private(set) var open: String?
    var isOpen: Bool { open != nil }

    mutating func consume(_ line: Substring) -> Bool {
        let trimmed = line.drop { $0 == " " }
        let marker: String? = trimmed.hasPrefix("```") ? "```" : trimmed.hasPrefix("~~~") ? "~~~" : nil
        guard let marker else { return false }
        if let open {
            if marker == open { self.open = nil }
        } else {
            open = marker
        }
        return true
    }
}

enum MarkdownStreamSplit {
    static func split(_ text: String) -> (stable: Substring, tail: Substring) {
        var fence = CodeFence()
        var boundary = text.startIndex
        var index = text.startIndex
        while let newline = text[index...].firstIndex(of: "\n") {
            let line = text[index..<newline].drop { $0 == " " }
            _ = fence.consume(line)
            let next = text.index(after: newline)
            if !fence.isOpen, line.isEmpty { boundary = next }
            index = next
        }
        return (text[..<boundary], text[boundary...])
    }

    enum TailKind { case empty, prose, code, markup }

    // What the unfinished tail is: plain prose keeps streaming as text,
    // markup waits for its closing line and renders formatted at once.
    static func tailKind(of tail: Substring) -> TailKind {
        guard !tail.isEmpty else { return .empty }
        var fence = CodeFence()
        var markup = false
        for line in tail.split(separator: "\n", omittingEmptySubsequences: false) {
            if fence.consume(line) { markup = true; continue }
            if fence.isOpen { continue }  // code lines inside an open fence
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || trimmed.hasPrefix("|")
                || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
                || trimmed.hasPrefix("$$") || trimmed.hasPrefix("---")
                || trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil
            { markup = true }
        }
        if fence.isOpen { return .code }
        return markup ? .markup : .prose
    }
}

// TailPlaceholder

/// Stands in for an unfinished code block or formatted passage while the model writes it.
private struct TailPlaceholder: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(title)
            ProgressView().controlSize(.small)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct CodeBlockView: View {
    let code: String
    let language: String?
    let fontSize: CGFloat

    var body: some View {
        let trimmed = code.trimmingCharacters(in: .newlines)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: language ?? "code").font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: trimmed).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            Text(CodeHighlighter.highlight(trimmed, language: language))
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        // Nearly opaque background keeps syntax colours readable on glass.
        .background(Color(nsColor: .textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
    }
}
