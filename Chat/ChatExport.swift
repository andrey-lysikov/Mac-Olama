//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Markdown
import UniformTypeIdentifiers
import WebKit

@MainActor
enum ChatExport {
    enum Format: Int, CaseIterable {
        case pdf, markdown, html

        var title: String {
            switch self {
            case .pdf: "PDF"
            case .markdown: "Markdown"
            case .html: "HTML"
            }
        }

        var type: UTType {
            switch self {
            case .pdf: .pdf
            case .markdown: UTType(filenameExtension: "md") ?? .plainText
            case .html: .html
            }
        }
    }

    struct Entry {
        var isUser: Bool
        var author: String
        var date: Date
        var text: String
        var images: [URL] = []
        var documents: [String] = []
    }

    static func run(chat: Chat, container: AppContainer, window: NSWindow?) {
        let panel = NSSavePanel()
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.addItems(withTitles: Format.allCases.map(\.title))
        let remembered = Format(rawValue: UserDefaults.standard.integer(forKey: formatKey)) ?? .pdf
        picker.selectItem(at: remembered.rawValue)
        let chooser = FormatChooser(panel: panel)
        picker.target = chooser
        picker.action = #selector(FormatChooser.changed(_:))
        let label = NSTextField(labelWithString: String(localized: "Format:"))
        let row = NSStackView(views: [label, picker])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = row
        panel.allowedContentTypes = [remembered.type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName(for: chat)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            _ = chooser  // lives as long as the dialog does
            guard response == .OK, let url = panel.url, let format = Format(rawValue: picker.indexOfSelectedItem) else { return }
            UserDefaults.standard.set(format.rawValue, forKey: formatKey)
            Task { await save(chat: chat, as: format, to: url, container: container, window: window) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private static let formatKey = "chatExportFormat"

    @MainActor
    private final class FormatChooser: NSObject {
        let panel: NSSavePanel
        init(panel: NSSavePanel) { self.panel = panel }
        @objc func changed(_ sender: NSPopUpButton) {
            if let format = Format(rawValue: sender.indexOfSelectedItem) { panel.allowedContentTypes = [format.type] }
        }
    }

    static func fileName(for chat: Chat) -> String {
        let title = chat.title.components(separatedBy: .newlines).joined(separator: " ")
            .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? String(localized: "Untitled chat") : String(title.prefix(80))
    }

    private static func save(chat: Chat, as format: Format, to url: URL, container: AppContainer, window: NSWindow?) async {
        do {
            let messages = try await container.chatStore.messages(chatID: chat.id)
            let entries = entries(of: messages, container: container)
            switch format {
            case .markdown: try Data(markdown(chat: chat, entries: entries).utf8).write(to: url, options: .atomic)
            case .html: try Data(html(chat: chat, entries: entries).utf8).write(to: url, options: .atomic)
            case .pdf: try await PDFWriter().write(html: html(chat: chat, entries: entries), to: url, window: window)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "The chat could not be exported")
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
        }
    }

    static func entries(of messages: [Message], container: AppContainer) -> [Entry] {
        messages.compactMap { message in
            switch message.role {
            case .user:
                var entry = Entry(isUser: true, author: String(localized: "You"), date: message.createdAt, text: message.text)
                for attachment in message.attachments {
                    switch attachment.kind {
                    case .image: entry.images.append(container.paths.attachments.appendingPathComponent(attachment.relativePath))
                    case .document: entry.documents.append(attachment.displayName ?? String(localized: "Document"))
                    }
                }
                return entry
            case .assistant:
                let text = AnswerText.visible(message.text)
                guard !text.isEmpty else { return nil }
                let model = message.modelID.flatMap { id in container.models.first { $0.id == id }?.name ?? id }
                return Entry(isUser: false, author: model ?? String(localized: "Model"), date: message.createdAt, text: text)
            default:
                return nil
            }
        }
    }

    private static func stamp(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    // Markdown

    static func markdown(chat: Chat, entries: [Entry]) -> String {
        var parts = ["# " + fileName(for: chat), "_" + stamp(chat.updatedAt) + "_"]
        for entry in entries {
            parts.append("---")
            parts.append("**\(entry.author)** · \(stamp(entry.date))")
            if !entry.documents.isEmpty { parts.append(entry.documents.map { "📎 " + $0 }.joined(separator: "  \n")) }
            if !entry.images.isEmpty {
                parts.append(String(localized: "Images attached: \(entry.images.count)"))
            }
            if !entry.text.isEmpty { parts.append(entry.text) }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    // HTML

    static func html(chat: Chat, entries: [Entry]) -> String {
        let title = escape(fileName(for: chat))
        var body = "<h1>\(title)</h1>\n<p class=\"date\">\(escape(stamp(chat.updatedAt)))</p>\n"
        for entry in entries {
            body += "<section class=\"\(entry.isUser ? "user" : "model")\">\n"
            body += "<p class=\"who\"><b>\(escape(entry.author))</b> · \(escape(stamp(entry.date)))</p>\n"
            for name in entry.documents { body += "<p class=\"file\">📎 \(escape(name))</p>\n" }
            for url in entry.images {
                guard let data = try? Data(contentsOf: url) else { continue }
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
                body += "<p><img src=\"data:\(type);base64,\(data.base64EncodedString())\" alt=\"\"></p>\n"
            }
            // A question is plain text: its line breaks are kept and nothing in it is read as markup.
            body +=
                entry.isUser
                ? "<p class=\"question\">\(escape(entry.text))</p>\n" : HTMLFormatter.format(Document(parsing: entry.text))
            body += "</section>\n"
        }
        return """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(title)</title>
            <style>\(style)</style>
            </head>
            <body>
            \(body)</body>
            </html>

            """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let style = """
        :root { color-scheme: light dark; --line: #d0d0d5; --soft: #f2f2f7; --dim: #6e6e73; }
        @media (prefers-color-scheme: dark) { :root { --line: #3a3a3c; --soft: #1c1c1e; --dim: #98989d; } }
        @media print { :root { color-scheme: light; --line: #d0d0d5; --soft: #f2f2f7; --dim: #6e6e73; } }
        /* Paper keeps the grey behind code, questions and table heads; print drops backgrounds otherwise. */
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        body { font: 15px/1.5 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; max-width: 760px; margin: 32px auto; padding: 0 20px; }
        h1 { font-size: 24px; margin: 0 0 4px; }
        h2 { font-size: 19px; } h3 { font-size: 16px; }
        .date, .who, .file { color: var(--dim); font-size: 13px; margin: 0 0 6px; }
        section { border-top: 1px solid var(--line); padding: 14px 0 6px; }
        section.user .question { background: var(--soft); border-radius: 12px; padding: 10px 14px; white-space: pre-wrap; margin: 0 0 8px; }
        img { max-width: 100%; max-height: 420px; border-radius: 8px; }
        pre { background: var(--soft); border-radius: 8px; padding: 10px 12px; overflow-x: auto; white-space: pre-wrap; word-break: break-word; }
        code { font: 13px/1.45 "SF Mono", Menlo, monospace; }
        :not(pre) > code { background: var(--soft); border-radius: 4px; padding: 1px 4px; }
        table { border-collapse: collapse; margin: 10px 0; }
        th, td { border: 1px solid var(--line); padding: 5px 10px; text-align: left; vertical-align: top; }
        th { background: var(--soft); }
        blockquote { border-left: 3px solid var(--line); margin: 8px 0; padding: 0 12px; color: var(--dim); }
        a { color: #0a66d8; }
        pre, table, img, blockquote { break-inside: avoid; }
        """
}

@MainActor
private final class PDFWriter: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Never>?
    private var printed: CheckedContinuation<Bool, Never>?

    func write(html: String, to url: URL, window: NSWindow?) async throws {
        let info = NSPrintInfo()
        info.paperSize = NSPrintInfo.shared.paperSize
        info.topMargin = 42
        info.bottomMargin = 42
        info.leftMargin = 36
        info.rightMargin = 36
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: info.paperSize.height))
        view.navigationDelegate = self
        await withCheckedContinuation { continuation in
            loaded = continuation
            view.loadHTMLString(html, baseURL: nil)
        }

        let operation = view.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // Web views print only via the modal call.
        operation.view?.frame = view.bounds
        let done = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            printed = continuation
            operation.runModal(
                for: window ?? NSWindow(), delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil)
        }
        guard done else { throw CocoaError(.fileWriteUnknown) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume()
        loaded = nil
    }

    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            printed?.resume(returning: success)
            printed = nil
        }
    }
}
