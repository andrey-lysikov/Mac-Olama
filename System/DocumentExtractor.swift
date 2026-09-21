//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// What ⌘V should attach instead of pasting text: copied files, or a copied image (screenshot, image from a browser).
/// A text field's own paste only understands strings, so both windows ask here first.
@MainActor
enum PasteboardAttachments {
    enum Content {
        case files([URL])
        case image(NSImage)
        case webURL(URL)
    }

    static func read(from pasteboard: NSPasteboard = .general) -> Content? {
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        // An explicitly copied link (`public.url`, browser "Copy Link"): the page becomes an attachment.
        // A URL typed or selected as plain text stays a text paste, so links can still be quoted verbatim.
        if pasteboard.availableType(from: [.URL]) != nil,
            let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first(where: \.isWebURL)
        {
            return .webURL(url)
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
        guard pasteboard.availableType(from: imageTypes) != nil, let image = NSImage(pasteboard: pasteboard) else { return nil }
        return .image(image)
    }
}

extension URL {
    var isWebURL: Bool { ["http", "https"].contains(scheme?.lowercased() ?? "") }
}

/// Downloads a page and turns it into a document attachment, so models without web tools can read it too.
/// Used by paste and drop in both windows.
enum WebPageDocument {
    static func fetch(_ url: URL) async throws -> DocumentInput {
        func document(title: String, markdown: String) -> DocumentInput {
            let name = title.isEmpty ? (url.host ?? url.absoluteString) : title
            return DocumentInput(name: name, text: "URL: \(url.absoluteString)\n\n\(markdown)")
        }
        let content: WebFetch.Content
        do {
            content = try await WebFetch.readable(
                url: url, maxCharacters: DocumentExtractor.maxCharacters, isRaw: { $0.contains("pdf") })
        } catch WebFetch.FetchError.status {
            throw URLError(.badServerResponse)
        }
        switch content {
        case .plain(let data):
            return DocumentInput(
                name: url.host ?? url.absoluteString, text: DocumentExtractor.clip(String(decoding: data, as: UTF8.self)))
        case .page(let title, let markdown):
            return document(title: title, markdown: markdown)
        case .other(let data, _, let finalURL):
            if let extracted = DocumentExtractor.extract(data: data, name: url.lastPathComponent, type: .pdf),
                case .document(let doc) = extracted
            {
                return doc
            }
            // A PDF that would not parse always fell through to the HTML reader; keep that.
            let page = try PageExtractor.extract(
                html: String(decoding: data, as: UTF8.self), url: finalURL, maxCharacters: DocumentExtractor.maxCharacters)
            return document(title: page.title, markdown: page.markdown)
        }
    }
}

/// Turns a dropped/picked file into either an image (for VLMs) or extracted text (any model).
enum DocumentExtractor {
    enum Extracted {
        case image(NSImage)
        case document(DocumentInput)
    }

    static let maxCharacters = 60_000
    static let textTypes: [UTType] = [
        .plainText, .utf8PlainText, .sourceCode, .json, .xml, .yaml, .html, .commaSeparatedText, .rtf, .script, .shellScript,
    ]

    /// URL-specific here: the RTF reader, the type gate and the size cap; the decoding itself is shared with
    /// `extract(data:name:type:)`.
    static func extract(url: URL) -> Extracted? {
        guard let type = UTType(filenameExtension: url.pathExtension) ?? UTType(mimeType: "text/plain") else { return nil }
        if type.conforms(to: .image) || type.conforms(to: .pdf) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            switch extract(data: data, name: url.lastPathComponent, type: type) {
            case .image(let image): return .image(image)
            // Only a PDF's text layer may come back as text, and an empty layer answered nil here — it still does.
            case .document(let doc) where type.conforms(to: .pdf) && !doc.text.isEmpty: return .document(doc)
            default: return nil
            }
        }
        if type.conforms(to: .rtf) || url.pathExtension.lowercased() == "rtf",
            let attributed = try? NSAttributedString(
                url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        {
            return .document(DocumentInput(name: url.lastPathComponent, text: clip(attributed.string)))
        }
        if textTypes.contains(where: { type.conforms(to: $0) }) || type.conforms(to: .text) || url.pathExtension.isEmpty {
            guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else { return nil }
            if let extracted = extract(data: data, name: url.lastPathComponent, type: nil) { return extracted }
            // The Latin-1 fallback is for files only: pasted data was always UTF-8.
            guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
            return .document(DocumentInput(name: url.lastPathComponent, text: clip(text)))
        }
        return nil
    }

    static func extract(data: Data, name: String, type: UTType?) -> Extracted? {
        if let type, type.conforms(to: .image), let image = NSImage(data: data) { return .image(image) }
        if let type, type.conforms(to: .pdf), let pdf = PDFDocument(data: data), let text = pdf.string {
            return .document(DocumentInput(name: name, text: clip(text)))
        }
        if let text = String(data: data, encoding: .utf8) { return .document(DocumentInput(name: name, text: clip(text))) }
        return nil
    }

    static func clip(_ text: String) -> String { text.clipped(to: maxCharacters) }
}
