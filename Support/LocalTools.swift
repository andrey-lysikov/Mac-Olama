//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import PDFKit
import Vision

// Local tools: read/search files inside user-approved folders and run user-made Shortcuts.
// Every path is canonicalised and must sit under an allowed folder; side effects go through `ToolConfirmation`.

/// Asks the user before a tool with side effects runs (the app shows a notification with Allow/Deny).
public protocol ToolConfirmation: Sendable {
    func confirm(title: String, detail: String) async -> Bool
}

/// Runs several providers as one; tool names must be unique across them.
public struct CompositeToolProvider: ToolProvider {
    let providers: [any ToolProvider]
    public init(_ providers: [any ToolProvider]) { self.providers = providers }
    public var specs: [ToolSpec] { providers.flatMap(\.specs) }
    public func execute(_ call: ToolCall) async throws -> String {
        guard let p = providers.first(where: { $0.specs.contains { $0.name == call.name } }) else {
            throw ConversationError.unknownTool(call.name)
        }
        return try await p.execute(call)
    }
}

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
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        guard !configuration.allowedFolders.isEmpty else {
            return "error: no folders are allowed; ask the user to add one in the Mac-Olama menu → Features → Folder Access"
        }
        switch call.name {
        case "read_file":
            guard let path = args["path"] as? String, let url = resolve(path) else { return "error: path is outside the allowed folders" }
            return try readFile(url)
        case "search_files":
            guard let query = args["query"] as? String, !query.isEmpty else { return "error: missing query" }
            let inContents = args["in_contents"] as? Bool ?? false
            let roots: [URL]
            if let folder = args["folder"] as? String, let r = resolve(folder) { roots = [r] } else { roots = configuration.allowedFolders }
            return search(query: query, inContents: inContents, roots: roots)
        case "recognize_text":
            guard let path = args["path"] as? String, let url = resolve(path) else { return "error: path is outside the allowed folders" }
            return try await recognizeText(url)
        case "write_file":
            guard let path = args["path"] as? String, let content = args["content"] as? String else {
                return "error: missing path or content"
            }
            return await writeFile(path: path, content: content, append: args["append"] as? Bool ?? false)
        case "open_item":
            guard let target = args["target"] as? String else { return "error: missing target" }
            return await openItem(target)
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
            return WebToolProvider.wrap("Directory listing:\n" + items.joined(separator: "\n"), source: url.path)
        }
        let ext = url.pathExtension.lowercased()
        guard ext.isEmpty || configuration.textExtensions.contains(ext) else { return "error: only text files can be read (\(ext))" }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return "error: not a text file"
        }
        let clipped =
            text.count > configuration.maxFileCharacters ? String(text.prefix(configuration.maxFileCharacters)) + "\n…[truncated]" : text
        return WebToolProvider.wrap(clipped, source: url.path)
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
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else { return "error: the PDF could not be opened" }
            images = (0..<min(document.pageCount, configuration.maxRecognizedPages)).compactMap { index in
                guard let page = document.page(at: index) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                let size = CGSize(width: bounds.width * 2, height: bounds.height * 2)  // 144 dpi: enough for small print
                return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp":
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return "error: the image could not be opened"
            }
            images = [image]
        default:
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
        let clipped =
            text.count > configuration.maxFileCharacters ? String(text.prefix(configuration.maxFileCharacters)) + "\n…[truncated]" : text
        return WebToolProvider.wrap(clipped, source: "recognize_text: \(url.path)")
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
        return WebToolProvider.wrap(body, source: "search_files: \(query)")
    }
}

// Shortcuts

/// Runs user-created Shortcuts via `/usr/bin/shortcuts`. The user builds the shortcut; macOS asks for its permissions.
public struct ShortcutToolProvider: ToolProvider {
    public struct Configuration: Sendable {
        public var binary = URL(fileURLWithPath: "/usr/bin/shortcuts")
        public var timeout: TimeInterval = 120
        public var maxOutputCharacters = 8000
        public var confirmation: (any ToolConfirmation)?
        public init(confirmation: (any ToolConfirmation)? = nil) { self.confirmation = confirmation }
    }

    let configuration: Configuration
    public init(configuration: Configuration = .init()) { self.configuration = configuration }

    public var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: configuration.binary.path) }

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "list_shortcuts", description: "List the names of the user's Shortcuts (Apple Shortcuts app) that can be run.",
                parametersJSONSchema: #"{"type":"object","properties":{}}"#),
            ToolSpec(
                name: "run_shortcut",
                description:
                    "Run one of the user's Shortcuts by exact name, optionally passing text input. The user is asked to approve each run. Returns the shortcut's text output.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"name":{"type":"string","description":"Exact shortcut name from list_shortcuts"},"input":{"type":"string","description":"Optional text passed as input"}},"required":["name"]}"#
            ),
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        guard isAvailable else { return "error: the shortcuts command is not available on this system" }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "list_shortcuts":
            let out = try await run(["list"], stdin: nil)
            return WebToolProvider.wrap(out, source: "shortcuts list")
        case "run_shortcut":
            guard let name = args["name"] as? String, !name.isEmpty else { return "error: missing name" }
            let known = try await run(["list"], stdin: nil).split(whereSeparator: \.isNewline).map(String.init)
            guard known.contains(name) else { return "error: no shortcut named \"\(name)\"; call list_shortcuts" }
            let input = args["input"] as? String
            if let confirmation = configuration.confirmation {
                let allowed = await confirmation.confirm(
                    title: "Run shortcut “\(name)”?", detail: input.map { "Input: \($0.prefix(200))" } ?? "No input")
                guard allowed else { return "error: the user declined to run the shortcut" }
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macolama-shortcut-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: tmp) }
            var arguments = ["run", name, "--output-path", tmp.path]
            var stdinData: Data?
            if let input { arguments += ["--input-path", "-"]; stdinData = Data(input.utf8) }
            let stderr = try await run(arguments, stdin: stdinData)
            let output = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
            let text = output.isEmpty ? (stderr.isEmpty ? "Shortcut finished with no text output." : stderr) : output
            return WebToolProvider.wrap(String(text.prefix(configuration.maxOutputCharacters)), source: "shortcut: \(name)")
        default:
            throw ConversationError.unknownTool(call.name)
        }
    }

    /// Runs the binary with a timeout; returns combined stdout+stderr text.
    func run(_ arguments: [String], stdin: Data?) async throws -> String {
        let box = ProcessBox(binary: configuration.binary, arguments: arguments, stdin: stdin)
        let timeout = configuration.timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do { try box.start(timeout: timeout) { continuation.resume(returning: $0) } } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// Owns a Process and its pipes; @unchecked because Process is not Sendable but is only touched from here.
final class ProcessBox: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()

    init(binary: URL, arguments: [String], stdin: Data?) {
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
    }

    func start(timeout: TimeInterval, completion: @escaping @Sendable (String) -> Void) throws {
        let output = self.output
        process.terminationHandler = { _ in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            completion(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in terminate() }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
