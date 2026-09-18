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
/// Used by paste and drop in both windows and by the Safari extension button.
enum WebPageDocument {
    static func fetch(_ url: URL) async throws -> DocumentInput {
        let (data, http) = try await HTTP.get(url)
        guard http.statusCode < 400 else { throw URLError(.badServerResponse) }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("json") || contentType.contains("text/plain") {
            let name = url.host ?? url.absoluteString
            return DocumentInput(name: name, text: DocumentExtractor.clip(String(decoding: data, as: UTF8.self)))
        }
        if contentType.contains("pdf"), let extracted = DocumentExtractor.extract(data: data, name: url.lastPathComponent, type: .pdf),
            case .document(let doc) = extracted
        {
            return doc
        }
        let page = try PageExtractor.extractText(
            html: String(decoding: data, as: UTF8.self), maxCharacters: DocumentExtractor.maxCharacters)
        let name = page.title.isEmpty ? (url.host ?? url.absoluteString) : page.title
        return DocumentInput(name: name, text: "URL: \(url.absoluteString)\n\n\(page.text)")
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

    static func extract(url: URL) -> Extracted? {
        guard let type = UTType(filenameExtension: url.pathExtension) ?? UTType(mimeType: "text/plain") else { return nil }
        if type.conforms(to: .image), let image = NSImage(contentsOf: url) { return .image(image) }
        if type.conforms(to: .pdf) {
            guard let pdf = PDFDocument(url: url), let text = pdf.string, !text.isEmpty else { return nil }
            return .document(DocumentInput(name: url.lastPathComponent, text: clip(text)))
        }
        if type.conforms(to: .rtf) || url.pathExtension.lowercased() == "rtf" {
            if let attributed = try? NSAttributedString(
                url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            {
                return .document(DocumentInput(name: url.lastPathComponent, text: clip(attributed.string)))
            }
        }
        if textTypes.contains(where: { type.conforms(to: $0) }) || type.conforms(to: .text) || url.pathExtension.isEmpty {
            guard let data = try? Data(contentsOf: url), data.count < 20_000_000,
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { return nil }
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

    static func clip(_ text: String) -> String {
        text.count > maxCharacters ? String(text.prefix(maxCharacters)) + "\n…[truncated]" : text
    }
}
