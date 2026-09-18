//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// Markdown rendering without third-party packages: Foundation parses the text (`AttributedString(markdown:)`),
// `PresentationIntent` describes the block structure, SwiftUI draws headers, lists, quotes, code blocks and tables.

struct MarkdownView: View {
    let markdown: String
    var baseFontSize: CGFloat = 13

    var body: some View {
        let blocks = MarkdownBlocks.parse(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in render(block) }
        }
        .font(.system(size: baseFontSize))
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlocks.Block) -> some View {
        switch block.kind {
        case .header(let level):
            Text(block.text).font(.system(size: baseFontSize + CGFloat(max(0, 4 - level)) * 3, weight: .semibold)).padding(.top, 4)
        case .paragraph:
            Text(block.text).textSelection(.enabled).padding(.leading, CGFloat(block.quoteDepth) * 12)
                .overlay(alignment: .leading) { if block.quoteDepth > 0 { Rectangle().fill(.quaternary).frame(width: 3) } }
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                Text(block.text).textSelection(.enabled)
            }
            .padding(.leading, CGFloat(block.indent) * 16)
        case .codeBlock(let language):
            CodeBlockView(code: String(block.text.characters), language: language, fontSize: baseFontSize - 1)
        case .thematicBreak:
            Divider()
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).fontWeight(index == 0 ? .semibold : .regular)
                            }
                        }
                        if index == 0 { Divider() }
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// Monospaced block with language label and a copy button.
struct CodeBlockView: View {
    let code: String
    let language: String?
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language ?? "code").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(String(localized: "Copy"))
            }
            ScrollView(.horizontal) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(size: fontSize, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Splits a Markdown string into renderable blocks using Foundation's presentation intents.
enum MarkdownBlocks {
    enum Kind {
        case paragraph
        case header(level: Int)
        case listItem(marker: String)
        case codeBlock(language: String?)
        case thematicBreak
        case table(rows: [[AttributedString]])
    }

    struct Block: Identifiable {
        let id: Int
        var kind: Kind
        var text: AttributedString
        var indent = 0
        var quoteDepth = 0
    }

    static func parse(_ markdown: String) -> [Block] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            return [Block(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }
        var blocks: [Block] = []
        var tableRows: [Int: [Int: AttributedString]] = [:]  // row → column → text
        var tableBlockID: Int?
        var currentLeaf: Int?

        for run in attributed.runs {
            guard let intent = run.presentationIntent else {
                append(
                    &blocks, leafID: -1, current: &currentLeaf, kind: .paragraph, text: AttributedString(attributed[run.range]), indent: 0,
                    quote: 0)
                continue
            }
            var kind: Kind = .paragraph
            var leafID = -1
            var indent = 0
            var quote = 0
            var marker = "•"
            var ordinal: Int?
            var cell: (row: Int, column: Int)?
            for component in intent.components {  // innermost first
                switch component.kind {
                case .paragraph: if leafID < 0 { leafID = component.identity }
                case .header(let level): kind = .header(level: level); leafID = component.identity
                case .codeBlock(let language): kind = .codeBlock(language: language); leafID = component.identity
                case .thematicBreak: kind = .thematicBreak; leafID = component.identity
                case .listItem(let ord): ordinal = ordinal ?? ord; indent += 1
                case .orderedList: if let ord = ordinal, marker == "•" { marker = "\(ord)." }
                case .unorderedList: break
                case .blockQuote: quote += 1
                case .tableCell(let column): cell = (cell?.row ?? 0, column)
                case .tableRow(let row): cell = (row, cell?.column ?? 0)
                case .table: tableBlockID = tableBlockID ?? component.identity; leafID = component.identity
                case .tableHeaderRow: cell = (0, cell?.column ?? 0)
                @unknown default: break
                }
            }
            let text = AttributedString(attributed[run.range])
            if let cell, let tableID = tableBlockID {
                tableRows[cell.row, default: [:]][cell.column, default: AttributedString()].append(text)
                if !blocks.contains(where: { $0.id == tableID }) {
                    blocks.append(Block(id: tableID, kind: .table(rows: []), text: AttributedString()))
                }
                currentLeaf = nil
                continue
            }
            if indent > 0 { kind = .listItem(marker: marker); indent -= 1 }
            append(&blocks, leafID: leafID, current: &currentLeaf, kind: kind, text: text, indent: indent, quote: quote)
        }
        if let tableID = tableBlockID, let i = blocks.firstIndex(where: { $0.id == tableID }) {
            let rows = tableRows.keys.sorted().map { r in
                (tableRows[r] ?? [:]).keys.sorted().map { tableRows[r]?[$0] ?? AttributedString() }
            }
            blocks[i].kind = .table(rows: rows)
        }
        return blocks
    }

    private static func append(
        _ blocks: inout [Block], leafID: Int, current: inout Int?, kind: Kind, text: AttributedString, indent: Int, quote: Int
    ) {
        var piece = text
        piece.presentationIntent = nil
        if leafID >= 0, leafID == current, let last = blocks.indices.last {
            blocks[last].text.append(piece)
            return
        }
        blocks.append(Block(id: leafID >= 0 ? leafID : blocks.count + 100_000, kind: kind, text: piece, indent: indent, quoteDepth: quote))
        current = leafID
    }
}
