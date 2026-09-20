//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

// Markdown rendering: `MarkdownBlocks` (swift-markdown) turns the text into blocks, SwiftUI draws headers, lists, quotes,
// code blocks and tables. Nesting inside lists shows as a leading indent.

struct MarkdownView: View {
    let markdown: String
    var baseFontSize: CGFloat = 13
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let blocks = MarkdownBlocks.parse(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in render(block).padding(.leading, CGFloat(block.indent) * 16) }
        }
        .font(.system(size: baseFontSize))
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlocks.Block) -> some View {
        switch block.kind {
        case .header(let level):
            let size = baseFontSize + CGFloat(max(0, 4 - level)) * 3
            text(block.text, size: size).font(.system(size: size, weight: .semibold)).padding(.top, 4)
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
            // No horizontal scroll view: nested inside the transcript's scroll view on macOS it is not clipped and
            // draws over the panel's edges. Cells wrap to the width instead.
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
    /// Text of a block: formulas typeset by SwiftMath, inline code with a light tint like the code cards, links marked.
    fileprivate func text(_ attributed: AttributedString, size: CGFloat? = nil) -> Text {
        var styled = attributed
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].backgroundColor = Color(nsColor: .quaternaryLabelColor)
        }
        // A link reads as one: accent colour, underline and a ↗ after it (clickable too). Backwards, so inserting keeps
        // the ranges still to visit valid.
        for (url, range) in styled.runs[\.link].reversed() {
            guard let url else { continue }
            styled[range].foregroundColor = .accentColor
            styled[range].underlineStyle = .single
            var arrow = AttributedString("\u{2009}\u{2197}\u{FE0E}")  // thin space, ↗ in text (not emoji) presentation
            arrow.link = url
            arrow.foregroundColor = .accentColor
            styled.insert(arrow, at: range.upperBound)
        }
        return FormulaRenderer.text(styled, fontSize: size ?? baseFontSize, dark: colorScheme == .dark)
    }
}

/// Code on its own tinted card: language and a copy button on top, syntax colours. Long lines wrap: a sideways scroll view
/// nested in the transcript's scroll view is not clipped on macOS and draws past the window.
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
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trimmed, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(String(localized: "Copy"))
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
        // Nearly opaque text background: syntax colours on the translucent glass of the panel lose their contrast.
        .background(Color(nsColor: .textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
    }
}
