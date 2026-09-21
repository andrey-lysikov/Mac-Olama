//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import PDFKit
import Synchronization
import UniformTypeIdentifiers
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
        let args = ToolArguments(call.argumentsJSON)
        switch call.name {
        case "list_shortcuts":
            let out = try await ToolProcess.run(configuration.binary, ["list"], timeout: configuration.timeout)
            return ToolOutput.wrap(out, source: "shortcuts list")
        case "run_shortcut":
            guard let name = args.string("name"), !name.isEmpty else { return toolFailure(missing: "name") }
            let known = try await ToolProcess.run(configuration.binary, ["list"], timeout: configuration.timeout)
                .split(whereSeparator: \.isNewline).map(String.init)
            guard known.contains(name) else { return "error: no shortcut named \"\(name)\"; call list_shortcuts" }
            let input = args.string("input")
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
            let stderr = try await ToolProcess.run(configuration.binary, arguments, stdin: stdinData, timeout: configuration.timeout)
            let output = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
            let text = output.isEmpty ? (stderr.isEmpty ? "Shortcut finished with no text output." : stderr) : output
            return ToolOutput.wrap(String(text.prefix(configuration.maxOutputCharacters)), source: "shortcut: \(name)")
        default:
            throw ConversationError.unknownTool(call.name)
        }
    }
}

// Processes

/// Runs a fixed program (no shell) with a timeout; stdout and stderr together. Cancellation terminates the child.
enum ToolProcess {
    /// One-shot flag; a reference type, so the escaping completion can hold it without copying the non-copyable Mutex.
    private final class ResumeGate: Sendable {
        private let resumed = Mutex(false)
        /// True the first time only.
        func begin() -> Bool {
            resumed.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
        }
    }

    static func run(_ binary: URL, _ arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 20) async throws -> String {
        let box = ProcessBox(binary: binary, arguments: arguments, stdin: stdin)
        // Insurance against a double resume: whatever paths inside start() ever fire, the continuation resumes once.
        let gate = ResumeGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                let finish: @Sendable (Result<String, any Error>) -> Void = { result in
                    if gate.begin() { continuation.resume(with: result) }
                }
                do { try box.start(timeout: timeout) { finish(.success($0)) } } catch { finish(.failure(error)) }
            }
        } onCancel: {
            box.terminate()
        }
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) async throws -> String {
        try await run(URL(fileURLWithPath: path), arguments, timeout: timeout)
    }
}

/// Shared output buffer: a reference type, so the pipe callbacks can hold it without copying the non-copyable Mutex.
private final class OutputBuffer: Sendable {
    private let storage = Mutex(Data())

    /// Appends a chunk and reports the total size collected so far.
    func append(_ chunk: Data) -> Int {
        storage.withLock { data in
            data.append(chunk)
            return data.count
        }
    }

    /// Appends the final drain and returns everything collected.
    func finish(with rest: Data) -> Data {
        storage.withLock { data in
            data.append(rest)
            return data
        }
    }
}

/// Owns a Process and its pipes; @unchecked because Process is not Sendable but is only touched from here.
/// Output is drained concurrently so a chatty child never deadlocks on a full pipe; stdin is written after launch.
final class ProcessBox: @unchecked Sendable {
    static let maxOutputBytes = 2 << 20

    private let process = Process()
    private let output = Pipe()
    private let stdin: Data?
    private let collected = OutputBuffer()
    /// One lock for the whole lifecycle: `run()` and `terminate()` race from different threads (cancel, timeout,
    /// output overflow), and NSTask throws uncatchable ObjC exceptions when poked in the wrong state.
    private let state = Mutex((terminated: false, launched: false))

    init(binary: URL, arguments: [String], stdin: Data?) {
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        self.stdin = stdin
        if stdin != nil { process.standardInput = Pipe() }
    }

    func start(timeout: TimeInterval, completion: @escaping @Sendable (String) -> Void) throws {
        // Cancelled before launch: the child must not run at all, and the caller must still get an answer.
        if state.withLock({ $0.terminated }) {
            completion("")
            return
        }
        let output = self.output
        let collected = self.collected
        // Raw read(2) instead of `availableData`: the drain in the termination handler may empty (or switch) this
        // descriptor while a queued handler call is still in flight, and `availableData` answers that with an
        // NSFileHandleOperationException Swift cannot catch.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            let n = read(handle.fileDescriptor, &buffer, buffer.count)
            guard n > 0 else {
                handle.readabilityHandler = nil
                return
            }
            if collected.append(Data(buffer[0..<n])) > Self.maxOutputBytes { self?.terminate() }
        }
        process.terminationHandler = { _ in
            let reader = output.fileHandleForReading
            reader.readabilityHandler = nil
            // Non-blocking drain: a grandchild inheriting the write end would make readToEnd() wait forever.
            _ = fcntl(reader.fileDescriptor, F_SETFL, O_NONBLOCK)
            var rest = Data()
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let n = read(reader.fileDescriptor, &buffer, buffer.count)
                guard n > 0 else { break }
                rest.append(contentsOf: buffer[0..<n])
            }
            let data = collected.finish(with: rest)
            var text = String(decoding: data.prefix(Self.maxOutputBytes), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if data.count > Self.maxOutputBytes { text += "\n…[output truncated]" }
            completion(text)
        }
        // Launch under the lock so a concurrent terminate() sees either "not launched yet" or "launched", never the
        // half-built NSTask state that makes `terminate()` throw.
        let launched: Bool = try state.withLock { s in
            guard !s.terminated else { return false }
            try process.run()
            s.launched = true
            return true
        }
        guard launched else {
            output.fileHandleForReading.readabilityHandler = nil
            completion("")
            return
        }
        if let stdin, let pipe = process.standardInput as? Pipe {
            let writer = pipe.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global().async {
                stdin.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(writer.fileDescriptor, raw.baseAddress! + offset, raw.count - offset)
                        if n <= 0 { break }
                        offset += n
                    }
                }
                try? writer.close()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in terminate() }
    }

    /// SIGTERM now; SIGKILL two seconds later if the child ignored it.
    func terminate() {
        let pid: pid_t? = state.withLock { s in
            s.terminated = true
            guard s.launched, process.isRunning else { return nil }
            process.terminate()
            return process.processIdentifier
        }
        // pid is captured once, under the lock: `processIdentifier` of a reaped task is 0, and kill(0, SIGKILL)
        // would take down our own process group.
        guard let pid, pid > 0 else { return }
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
