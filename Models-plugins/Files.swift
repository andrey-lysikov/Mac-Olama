//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

// Files: read, search, recognize, write, move and pack inside user-approved folders, and find anything with Spotlight. Every path is canonicalised and must sit
// under an allowed folder; side effects go through `ToolConfirmation`.

// Files

public struct FileToolProvider: ToolProvider {
    public struct Configuration: Sendable {
        public var allowedFolders: [URL]
        public var maxFileCharacters = 20_000
        public var maxWrittenCharacters = 200_000
        public var maxRecognizedPages = 10
        /// Writing a file and opening one (or a link) are the only side effects here; both ask the user first.
        public var confirmation: (any ToolConfirmation)?
        public var maxResults = 25
        public var maxContentScanFiles = 400
        public var skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Library", ".Trash"]
        public var textExtensions: Set<String> = [
            "txt", "md", "markdown", "json", "yaml", "yml", "csv", "tsv", "xml", "html", "htm", "swift", "py", "js", "ts",
            "rs", "go", "java", "kt", "c", "h", "cpp", "m", "mm", "sh", "toml", "ini", "cfg", "log", "rtf", "tex", "sql", "plist",
        ]
        public init(allowedFolders: [URL], confirmation: (any ToolConfirmation)? = nil) {
            self.allowedFolders = allowedFolders.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            self.confirmation = confirmation
        }
    }

    let configuration: Configuration
    public init(configuration: Configuration) { self.configuration = configuration }

    public var specs: [ToolSpec] {
        let folders = configuration.allowedFolders.map(\.path).joined(separator: ", ")
        return [
            ToolSpec(
                name: "read_file",
                description:
                    "Read a text file from the user's allowed folders (\(folders)). Returns up to \(configuration.maxFileCharacters) characters.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute path or path relative to an allowed folder"}},"required":["path"]}"#
            ),
            ToolSpec(
                name: "search_files",
                description:
                    "Find files in the user's allowed folders (\(folders)) by name, optionally also by text content. Returns paths, sizes and dates.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"query":{"type":"string","description":"Case-insensitive substring to match"},"in_contents":{"type":"boolean","description":"Also search inside text files (slower)"},"folder":{"type":"string","description":"Restrict to one allowed folder"}},"required":["query"]}"#
            ),
            ToolSpec(
                name: "recognize_text",
                description:
                    "Read the text of an image or a scanned PDF from the allowed folders (\(folders)) with on-device recognition. Use it when a file is not plain text.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"path":{"type":"string","description":"Path to a png, jpg, heic, tiff or pdf file"}},"required":["path"]}"#
            ),
            ToolSpec(
                name: "write_file",
                description:
                    "Write a text file inside the allowed folders (\(folders)). The user approves every write. Existing files are replaced unless append is true.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"path":{"type":"string","description":"Path inside an allowed folder"},"content":{"type":"string"},"append":{"type":"boolean","description":"Append instead of replacing"}},"required":["path","content"]}"#
            ),
            ToolSpec(
                name: "open_item",
                description:
                    "Open a file from the allowed folders (\(folders)) in its usual app, or open an http(s) link in the browser. The user approves every open.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"target":{"type":"string","description":"File path inside an allowed folder, or an http(s) URL"}},"required":["target"]}"#
            ),
            ToolSpec(
                name: "move_file",
                description:
                    "Move or rename a file or folder inside the allowed folders (\(folders)). The user approves every move; an existing file is never replaced.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"from":{"type":"string","description":"What to move"},"to":{"type":"string","description":"New path, or an allowed folder to move it into"}},"required":["from","to"]}"#
            ),
            ToolSpec(
                name: "make_archive",
                description:
                    "Pack a file or folder from the allowed folders (\(folders)) into a .zip next to it. The user approves it first.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"path":{"type":"string"},"to":{"type":"string","description":"Name or path of the archive; default <name>.zip next to it"}},"required":["path"]}"#
            ),
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        guard !configuration.allowedFolders.isEmpty else {
            return "error: no folders are allowed; ask the user to add one in the Mac-Olama menu → Features → Folder Access"
        }
        switch call.name {
        case "read_file":
            guard let path = args.string("path"), let url = resolve(path) else { return "error: path is outside the allowed folders" }
            return try readFile(url)
        case "search_files":
            guard let query = args.string("query"), !query.isEmpty else { return toolFailure(missing: "query") }
            let inContents = args.bool("in_contents") ?? false
            let roots: [URL]
            if let folder = args.string("folder"), let r = resolve(folder) { roots = [r] } else { roots = configuration.allowedFolders }
            return search(query: query, inContents: inContents, roots: roots)
        case "recognize_text":
            guard let path = args.string("path"), let url = resolve(path) else { return "error: path is outside the allowed folders" }
            return try await recognizeText(url)
        case "write_file":
            guard let path = args.string("path"), let content = args.string("content") else {
                return toolFailure(missing: "path or content")
            }
            return await writeFile(path: path, content: content, append: args.bool("append") ?? false)
        case "open_item":
            guard let target = args.string("target") else { return toolFailure(missing: "target") }
            return await openItem(target)
        case "move_file":
            guard let from = args.string("from"), let to = args.string("to") else { return toolFailure(missing: "from or to") }
            return await move(from: from, to: to)
        case "make_archive":
            guard let path = args.string("path") else { return toolFailure(missing: "path") }
            return try await archive(path, to: args.string("to"))
        default:
            throw ConversationError.unknownTool(call.name)
        }
    }

    /// Absolute paths must lie under an allowed folder; relative paths are tried against each allowed folder.
    func resolve(_ path: String) -> URL? {
        let expanded = NSString(string: path).expandingTildeInPath
        let candidates: [URL] =
            expanded.hasPrefix("/")
            ? [URL(fileURLWithPath: expanded)] : configuration.allowedFolders.map { $0.appendingPathComponent(expanded) }
        for c in candidates {
            let canonical = c.standardizedFileURL.resolvingSymlinksInPath()
            if configuration.allowedFolders.contains(where: { canonical.path == $0.path || canonical.path.hasPrefix($0.path + "/") }),
                FileManager.default.fileExists(atPath: canonical.path)
            {
                return canonical
            }
        }
        return nil
    }

    func readFile(_ url: URL) throws -> String {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted().prefix(200) ?? []
            return ToolOutput.wrap("Directory listing:\n" + items.joined(separator: "\n"), source: url.path)
        }
        let ext = url.pathExtension.lowercased()
        guard ext.isEmpty || configuration.textExtensions.contains(ext) else { return "error: only text files can be read (\(ext))" }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return "error: not a text file"
        }
        return ToolOutput.wrap(text.clipped(to: configuration.maxFileCharacters), source: url.path)
    }

    /// Where a new file may go: the folder it lands in must be an allowed one, and the name must be a plain file name.
    func resolveForWriting(_ path: String) -> URL? {
        let expanded = NSString(string: path).expandingTildeInPath
        let name = (expanded as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("/") else { return nil }
        let parent = (expanded as NSString).deletingLastPathComponent
        let folders: [URL] =
            expanded.hasPrefix("/") || !parent.isEmpty
            ? [URL(fileURLWithPath: parent.isEmpty ? "/" : parent)] : configuration.allowedFolders
        for folder in folders {
            let canonical = folder.standardizedFileURL.resolvingSymlinksInPath()
            guard configuration.allowedFolders.contains(where: { canonical.path == $0.path || canonical.path.hasPrefix($0.path + "/") })
            else { continue }
            return canonical.appendingPathComponent(name)
        }
        return nil
    }

    func recognizeText(_ url: URL) async throws -> String {
        let images: [CGImage]
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { return "error: the PDF could not be opened" }
            images = (0..<min(document.pageCount, configuration.maxRecognizedPages)).compactMap { index in
                guard let page = document.page(at: index) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                let size = CGSize(width: bounds.width * 2, height: bounds.height * 2)  // 144 dpi: enough for small print
                return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        } else if type?.conforms(to: .image) == true {
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return "error: the image could not be opened"
            }
            images = [image]
        } else {
            return "error: only images and PDFs can be recognized"
        }
        guard !images.isEmpty else { return "error: nothing to recognize in this file" }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        var pages: [String] = []
        for (index, image) in images.enumerated() {
            let lines = try await request.perform(on: image).compactMap { $0.topCandidates(1).first?.string }
            guard !lines.isEmpty else { continue }
            pages.append(images.count > 1 ? "— page \(index + 1) —\n" + lines.joined(separator: "\n") : lines.joined(separator: "\n"))
        }
        guard !pages.isEmpty else { return "No text was recognized in \(url.lastPathComponent)." }
        let text = pages.joined(separator: "\n\n")
        return ToolOutput.wrap(text.clipped(to: configuration.maxFileCharacters), source: "recognize_text: \(url.path)")
    }

    func writeFile(path: String, content: String, append: Bool) async -> String {
        guard content.count <= configuration.maxWrittenCharacters else {
            return "error: content longer than \(configuration.maxWrittenCharacters) characters"
        }
        guard let url = resolveForWriting(path) else { return "error: path is outside the allowed folders" }
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard configuration.textExtensions.contains(url.pathExtension.lowercased()) else { return "error: only text files can be written" }
        if let confirmation = configuration.confirmation {
            let action =
                append && exists ? String(localized: "Append to") : exists ? String(localized: "Replace") : String(localized: "Create")
            let allowed = await confirmation.confirm(
                title: String(localized: "\(action) file \(url.lastPathComponent)?"),
                detail: "\(url.path)\n\(content.prefix(200))")
            guard allowed else { return "error: the user declined the write" }
        }
        do {
            if append, exists, let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(content.utf8))
            } else {
                try Data(content.utf8).write(to: url, options: .atomic)
            }
            return "Wrote \(content.count) characters to \(url.path)."
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    func openItem(_ target: String) async -> String {
        let url: URL
        if let link = URL(string: target), ["http", "https"].contains(link.scheme ?? "") {
            url = link
        } else if let file = resolve(target) {
            url = file
        } else {
            return "error: open a file inside the allowed folders or an http(s) link"
        }
        if let confirmation = configuration.confirmation {
            let allowed = await confirmation.confirm(
                title: String(localized: "Open \(url.lastPathComponent)?"), detail: url.absoluteString)
            guard allowed else { return "error: the user declined to open it" }
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        return opened ? "Opened \(url.absoluteString)." : "error: the system could not open it"
    }

    /// Both ends inside the allowed folders; a folder as the target takes the item in under its own name.
    func move(from: String, to: String) async -> String {
        guard let source = resolve(from) else { return "error: \(from) is not inside the allowed folders" }
        var destination: URL
        if let folder = resolve(to), (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            destination = folder.appendingPathComponent(source.lastPathComponent)
        } else if let target = resolveForWriting(to.contains("/") ? to : source.deletingLastPathComponent().appendingPathComponent(to).path)
        {
            destination = target
        } else {
            return "error: \(to) is not inside the allowed folders"
        }
        destination = destination.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return "error: \(destination.path) already exists; it is never replaced"
        }
        let renaming = source.deletingLastPathComponent() == destination.deletingLastPathComponent()
        guard let confirmation = configuration.confirmation else { return "error: moving needs the user's approval" }
        let title =
            renaming
            ? String(localized: "Rename \(source.lastPathComponent) to \(destination.lastPathComponent)?")
            : String(localized: "Move \(source.lastPathComponent)?")
        guard await confirmation.confirm(title: title, detail: "\(source.path)\n→ \(destination.path)") else {
            return "error: the user declined the move"
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return "Moved \(source.path) to \(destination.path)."
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    /// A zip made by ditto, the way Finder's Compress makes one; it lands inside the allowed folders.
    func archive(_ path: String, to target: String?) async throws -> String {
        guard let source = resolve(path) else { return "error: \(path) is not inside the allowed folders" }
        var name = target ?? source.lastPathComponent + ".zip"
        if !name.lowercased().hasSuffix(".zip") { name += ".zip" }
        guard
            let destination = resolveForWriting(
                name.contains("/") ? name : source.deletingLastPathComponent().appendingPathComponent(name).path)
        else { return "error: the archive would land outside the allowed folders" }
        guard !FileManager.default.fileExists(atPath: destination.path) else { return "error: \(destination.path) already exists" }
        guard let confirmation = configuration.confirmation else { return "error: making an archive needs the user's approval" }
        guard
            await confirmation.confirm(
                title: String(localized: "Pack \(source.lastPathComponent) into \(destination.lastPathComponent)?"),
                detail: destination.path)
        else { return "error: the user declined the archive" }
        let out = try await ToolProcess.run(
            URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path],
            timeout: 120)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return "error: the archive was not made (\(out.prefix(200)))"
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        return "Made \(destination.path)" + (size.map { " (\($0))." } ?? ".")
    }

    func search(query: String, inContents: Bool, roots: [URL]) -> String {
        let needle = query.lowercased()
        var hits: [(URL, Int64, Date)] = []
        var scanned = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        outer: for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])
            else { continue }
            for case let url as URL in e {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if configuration.skippedDirectories.contains(url.lastPathComponent) { e.skipDescendants() }
                    continue
                }
                let name = url.lastPathComponent
                var matched = name.lowercased().contains(needle)
                if !matched, inContents, scanned < configuration.maxContentScanFiles,
                    configuration.textExtensions.contains(url.pathExtension.lowercased()),
                    (values?.fileSize ?? 0) < 2_000_000
                {
                    scanned += 1
                    if let text = try? String(contentsOf: url, encoding: .utf8), text.lowercased().contains(needle) { matched = true }
                }
                if matched {
                    hits.append((url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast))
                    if hits.count >= configuration.maxResults { break outer }
                }
            }
        }
        if hits.isEmpty { return "No files matched \"\(query)\"." }
        let df = ISO8601DateFormatter()
        let body = hits.sorted { $0.2 > $1.2 }.map {
            "\($0.0.path)  (\(ByteCountFormatter.string(fromByteCount: $0.1, countStyle: .file)), \(df.string(from: $0.2)))"
        }.joined(separator: "\n")
        return ToolOutput.wrap(body, source: "search_files: \(query)")
    }
}

// Spotlight

/// `spotlight_search`: files anywhere on this Mac by name and content, as the Spotlight menu finds them (mdfind). It
/// only lists them: reading or opening one still needs its folder among the allowed ones.
public struct SpotlightToolProvider: ToolProvider {
    public var limit = 20

    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "spotlight_search",
                description:
                    "Find files anywhere on this Mac by name or content with Spotlight: path, size, date changed. It only lists them; read_file and open_item work in the allowed folders.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"query":{"type":"string","description":"Words to find in names or contents"},"kind":{"type":"string","enum":["any","document","pdf","image","presentation","spreadsheet","folder","music","movie"],"description":"Default any"}},"required":["query"]}"#
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        guard let query = args.string("query")?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return toolFailure(missing: "query")
        }
        let kind = args.string("kind").flatMap { $0 == "any" ? nil : $0 }
        // "kind:pdf" is read the way the Spotlight menu reads it; the query stays one argument, never a shell string.
        let arguments = kind.map { ["-interpret", "\(query) kind:\($0)"] } ?? [query]
        let out = try await ToolProcess.run(URL(fileURLWithPath: "/usr/bin/mdfind"), arguments, timeout: 15)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // What the user keeps, not the system's and the apps' own files that match any word.
        let paths = out.split(separator: "\n").map(String.init).filter { path in
            path.hasPrefix("/") && !path.contains("/Library/") && !path.contains("/.") && !path.contains(".app/")
                && !path.hasPrefix("/System/") && !path.hasPrefix("/private/")
        }
        guard !paths.isEmpty else { return "Spotlight found nothing for \"\(query)\"." }
        let lines = paths.prefix(limit).map { path -> String in
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var line = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : Substring(path)
            if let size = values?.fileSize { line += ", " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
            if let date = values?.contentModificationDate { line += ", changed " + ToolDate.string(date, time: false) }
            return "- " + line
        }
        let more = paths.count > limit ? "\n…and \(paths.count - limit) more; narrow the words or the kind" : ""
        return ToolOutput.wrap((["Spotlight found for \"\(query)\":"] + lines).joined(separator: "\n") + more, source: "spotlight_search")
    }
}
