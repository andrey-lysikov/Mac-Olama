//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

public enum CodingError: LocalizedError {
    case noProject
    case invalidProject(String)
    case projectNotAllowed(String)
    case invalidPath(String)
    case invalidCommand(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noProject: "No project is bound to this chat. Ask the user for a project path, then call project_bind."
        case .invalidProject(let path): "The project is not an accessible directory: \(path)"
        case .projectNotAllowed(let path):
            "The project is not in Folder Access: \(path). Ask the user to add it in Settings → Files → Folder Access first."
        case .invalidPath(let path): "The path is outside the project or this chat's temporary directory: \(path)"
        case .invalidCommand(let message): message
        case .commandFailed(let output): output
        }
    }
}

public actor CodingProjectStore {
    private var projects: [UUID: String]
    private var states: [UUID: String]
    private var verification: [UUID: String]
    private let saveProjects: @Sendable ([String: String]) -> Void
    private let saveStates: @Sendable ([String: String]) -> Void
    private let saveVerification: @Sendable ([String: String]) -> Void

    init(
        projects: [String: String], states: [String: String], verification: [String: String],
        saveProjects: @escaping @Sendable ([String: String]) -> Void,
        saveStates: @escaping @Sendable ([String: String]) -> Void,
        saveVerification: @escaping @Sendable ([String: String]) -> Void
    ) {
        self.projects = Dictionary(uniqueKeysWithValues: projects.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        self.states = Dictionary(uniqueKeysWithValues: states.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        self.verification = Dictionary(uniqueKeysWithValues: verification.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        self.saveProjects = saveProjects
        self.saveStates = saveStates
        self.saveVerification = saveVerification
    }

    func path(for chatID: UUID) -> URL? {
        guard let path = projects[chatID] else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return nil }
        return url
    }

    func bind(chatID: UUID, path: String) throws -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw CodingError.invalidProject(path)
        }
        projects[chatID] = url.path
        states[chatID] = nil
        verification[chatID] = nil
        saveProjects(Dictionary(uniqueKeysWithValues: projects.map { ($0.key.uuidString, $0.value) }))
        saveStates(Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) }))
        saveVerification(Dictionary(uniqueKeysWithValues: verification.map { ($0.key.uuidString, $0.value) }))
        return url
    }

    func setState(_ state: String, chatID: UUID) {
        states[chatID] = String(state.prefix(8_000))
        saveStates(Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) }))
    }

    func markEdited(chatID: UUID) {
        verification[chatID] = "required"
        saveVerification(Dictionary(uniqueKeysWithValues: verification.map { ($0.key.uuidString, $0.value) }))
    }

    func needsVerification(chatID: UUID) -> Bool { verification[chatID] == "required" }

    func recordVerification(_ result: String, chatID: UUID, status: String = "unavailable") {
        let existing = states[chatID] ?? ""
        let task = existing.components(separatedBy: "\n\nLatest verification (").first ?? ""
        let entry = "Latest verification (\(status)):\n\(result.prefix(3_000))"
        states[chatID] = String((String(task.prefix(5_000)) + "\n\n" + entry).prefix(8_000))
        verification[chatID] = status
        saveStates(Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) }))
        saveVerification(Dictionary(uniqueKeysWithValues: verification.map { ($0.key.uuidString, $0.value) }))
    }

    func temporaryDirectory(chatID: UUID) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mac-Olama", isDirectory: true)
            .appendingPathComponent(chatID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func cleanupTemporaryDirectories(keeping chatIDs: Set<UUID>) {
        projects = projects.filter { chatIDs.contains($0.key) }
        states = states.filter { chatIDs.contains($0.key) }
        verification = verification.filter { chatIDs.contains($0.key) }
        saveProjects(Dictionary(uniqueKeysWithValues: projects.map { ($0.key.uuidString, $0.value) }))
        saveStates(Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) }))
        saveVerification(Dictionary(uniqueKeysWithValues: verification.map { ($0.key.uuidString, $0.value) }))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mac-Olama", isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in directories {
            if let id = UUID(uuidString: url.lastPathComponent), chatIDs.contains(id) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func context(for chatID: UUID, allowedFolders: [String]) -> String? {
        guard let root = path(for: chatID) else { return nil }
        let allowed = allowedFolders.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        guard allowed.contains(where: { root.path == $0 || root.path.hasPrefix($0 + "/") }) else { return nil }
        var parts = [
            "Coding project root: \(root.path)",
            "Work only inside this project or the chat's designated temporary directory. Use task_update for multi-step work, inspect before editing, and verify changes with builds or tests when available.",
        ]
        let agents = root.appendingPathComponent("AGENTS.md")
        if let instructions = try? String(contentsOf: agents, encoding: .utf8) {
            parts.append("Project instructions from AGENTS.md; follow them while working in this project:\n" + instructions.prefix(50_000))
        }
        return parts.joined(separator: "\n\n")
    }

    func dynamicContext(for chatID: UUID, allowedFolders: [String]) -> String? {
        guard let root = path(for: chatID) else { return nil }
        let allowed = allowedFolders.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        guard allowed.contains(where: { root.path == $0 || root.path.hasPrefix($0 + "/") }) else { return nil }
        var parts: [String] = []
        if let status = verification[chatID] { parts.append("Coding verification status: \(status)") }
        if let state = states[chatID], !state.isEmpty { parts.append("Current coding task state:\n" + state.prefix(8_000)) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

public actor CodingSnapshotStore {
    struct Entry: Codable, Sendable {
        var relativePath: String
        var before: Data?
        var after: Data?
    }
    struct Snapshot: Codable, Sendable {
        var id: UUID
        var root: String
        var entries: [Entry]
    }
    private var snapshots: [UUID: [Snapshot]]
    private let file: URL

    init(directory: URL) {
        file = directory.appendingPathComponent("snapshots.json")
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: [Snapshot]].self, from: $0) } ?? [:]
        snapshots = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func begin(chatID: UUID, root: URL, files: [URL]) -> UUID {
        let id = UUID()
        let entries = files.map { file in
            let path = file.path == root.path ? "." : String(file.path.dropFirst(root.path.count + 1))
            return Entry(relativePath: path, before: try? Data(contentsOf: file), after: nil)
        }
        snapshots[chatID, default: []].append(Snapshot(id: id, root: root.path, entries: entries))
        if let count = snapshots[chatID]?.count, count > 20 { snapshots[chatID]?.removeFirst(count - 20) }
        persist()
        return id
    }

    func complete(chatID: UUID, snapshotID: UUID, root: URL) {
        guard var all = snapshots[chatID], let index = all.lastIndex(where: { $0.id == snapshotID }) else { return }
        for entryIndex in all[index].entries.indices {
            let path = all[index].entries[entryIndex].relativePath
            all[index].entries[entryIndex].after = try? Data(contentsOf: root.appendingPathComponent(path))
        }
        snapshots[chatID] = all
        persist()
    }

    func discard(chatID: UUID, snapshotID: UUID) {
        snapshots[chatID]?.removeAll { $0.id == snapshotID }
        persist()
    }

    func latest(chatID: UUID) -> Snapshot? { snapshots[chatID]?.last }
    func remove(chatID: UUID, snapshotID: UUID) { discard(chatID: chatID, snapshotID: snapshotID) }
    func prune(keeping chatIDs: Set<UUID>) {
        snapshots = snapshots.filter { chatIDs.contains($0.key) }
        persist()
    }
}

public actor CodingTaskManager {
    struct Info: Codable, Sendable {
        var chatID: UUID
        var command: String
        var output = ""
        var status: Int32?
    }
    private var information: [String: Info]
    private var running: [String: Task<Void, Never>] = [:]
    private let file: URL

    init(directory: URL) {
        file = directory.appendingPathComponent("tasks.json")
        information = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Info].self, from: $0) } ?? [:]
        for (id, info) in information where info.status == nil {
            information[id]?.status = -1
            information[id]?.output += "\nInterrupted by application restart."
        }
        if let data = try? JSONEncoder().encode(information) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(information) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func start(
        chatID: UUID, command: String,
        operation: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> ToolProcessResult
    ) -> String {
        let id = UUID().uuidString
        information[id] = Info(chatID: chatID, command: command)
        persist()
        running[id] = Task {
            do {
                let result = try await operation { chunk in Task { await self.append(chunk, id: id) } }
                finish(id: id, output: result.output, status: result.status)
            } catch {
                finish(id: id, output: "error: \(error.localizedDescription)", status: -1)
            }
        }
        return id
    }

    private func append(_ text: String, id: String) {
        guard information[id] != nil else { return }
        information[id]?.output += text
        if let count = information[id]?.output.count, count > 2_000_000 {
            information[id]?.output = String(information[id]?.output.suffix(2_000_000) ?? "")
        }
    }

    private func finish(id: String, output: String, status: Int32) {
        if !output.isEmpty { information[id]?.output = output }
        information[id]?.status = status
        running[id] = nil
        persist()
    }

    func output(id: String, chatID: UUID) -> String {
        guard let info = information[id], info.chatID == chatID else { return "error: unknown background task \(id)" }
        let state = info.status.map { "Finished with exit code \($0)" } ?? "Running"
        return "\(info.command)\n\(state)\n\(info.output)"
    }

    func list(chatID: UUID) -> String {
        let tasks = information.filter { $0.value.chatID == chatID }
        guard !tasks.isEmpty else { return "No background tasks." }
        return tasks.keys.sorted().map { id in
            let info = tasks[id]!
            return "\(id)  \(info.status.map { "exit \($0)" } ?? "running")  \(info.command)"
        }.joined(separator: "\n")
    }

    func cancel(id: String, chatID: UUID) -> String {
        guard information[id]?.chatID == chatID, let task = running[id] else { return "Task is not running: \(id)" }
        task.cancel()
        running[id] = nil
        information[id]?.status = -1
        persist()
        return "Cancelled \(id)"
    }

    func prune(keeping chatIDs: Set<UUID>) {
        information = information.filter { chatIDs.contains($0.value.chatID) }
        persist()
    }
}

public struct CodingToolProvider: ToolProvider {
    public struct Configuration: Sendable {
        var enabled: Set<ExtraTool>
        var allowedFolders: [String]
        var projects: CodingProjectStore
        var snapshots: CodingSnapshotStore
        var tasks: CodingTaskManager
        var confirmation: (any ToolConfirmation)?
    }

    let configuration: Configuration

    public init(configuration: Configuration) { self.configuration = configuration }

    private var commonSpecs: [ToolSpec] {
        [
            ToolSpec(
                name: "project_bind",
                description: "Bind this chat to a project directory supplied by the user. Always call this before using other project tools when no project is bound.",
                parametersJSONSchema: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute path or ~ path to an existing project directory"}},"required":["path"]}"#),
            ToolSpec(
                name: "task_update",
                description: "Persist the coding goal, plan, completed steps, changed files, verification results and remaining blockers for this chat.",
                parametersJSONSchema: #"{"type":"object","properties":{"state":{"type":"string"}},"required":["state"]}"#),
        ]
    }

    public var specs: [ToolSpec] {
        var result = commonSpecs
        let enabled = configuration.enabled
        if enabled.contains(.codingFiles) {
            result += [
                ToolSpec(name: "project_read", description: "Read a project file or list a directory. Relevant nested AGENTS.md instructions are included.", parametersJSONSchema: #"{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"]}"#),
                ToolSpec(name: "project_search", description: "Search the bound project by file name and optionally text content.", parametersJSONSchema: #"{"type":"object","properties":{"query":{"type":"string"},"in_contents":{"type":"boolean"}},"required":["query"]}"#),
            ]
        }
        if enabled.contains(.codingSkills) {
            result += [
                ToolSpec(name: "list_skills", description: "List SKILL.md files in the project's .agents/skills, .claude/skills, .kimi/skills and skills directories.", parametersJSONSchema: #"{"type":"object","properties":{}}"#),
                ToolSpec(name: "read_skill", description: "Read a project SKILL.md by the exact path returned by list_skills.", parametersJSONSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#),
            ]
        }
        if enabled.contains(.codingEdit) {
            result += [
                ToolSpec(name: "edit_file", description: "Edit a project file by exact text replacement. Ambiguous replacements fail unless replace_all is true. Shows a diff for approval.", parametersJSONSchema: #"{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"]}"#),
                ToolSpec(name: "apply_patch", description: "Validate and apply a unified diff with git apply. Shows the patch for approval and supports multiple files.", parametersJSONSchema: #"{"type":"object","properties":{"patch":{"type":"string"}},"required":["patch"]}"#),
                ToolSpec(name: "rollback_latest", description: "Restore the latest snapshot made by the coding agent, skipping files subsequently changed by the user.", parametersJSONSchema: #"{"type":"object","properties":{}}"#),
                ToolSpec(
                    name: "verify_changes",
                    description: "Verify coding changes with a supplied command or an automatically detected build/test command. Requires the Commands option and user approval. Always use this after edits when verification is available.",
                    parametersJSONSchema: #"{"type":"object","properties":{"command":{"type":"string","description":"Optional exact verification command; otherwise detect from project manifests"},"timeout":{"type":"integer"}}}"#),
            ]
        }
        if enabled.contains(.codingScripts) {
            result += [
                ToolSpec(name: "create_script", description: "Create a Python, sh or bash script in the project or this chat's temporary directory. Existing content requires overwrite=true.", parametersJSONSchema: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"location":{"type":"string","enum":["project","temporary"]},"overwrite":{"type":"boolean"}},"required":["path","content"]}"#),
                ToolSpec(name: "run_script", description: "Run an existing Python, sh or bash script with its interpreter after user approval.", parametersJSONSchema: Self.runSchema(script: true)),
            ]
        }
        if enabled.contains(.codingCommands) {
            result += [
                ToolSpec(name: "run_process", description: "Run an executable with separate arguments, without a shell. Supports project/temporary cwd, timeout and background execution.", parametersJSONSchema: Self.runSchema()),
                ToolSpec(name: "run_shell", description: "Run a full command line through sh -c or bash -c after user approval. Supports pipelines and background execution.", parametersJSONSchema: #"{"type":"object","properties":{"command":{"type":"string"},"shell":{"type":"string","enum":["sh","bash"]},"cwd":{"type":"string"},"location":{"type":"string","enum":["project","temporary"]},"timeout":{"type":"integer"},"background":{"type":"boolean"}},"required":["command"]}"#),
                ToolSpec(name: "command_tasks", description: "List background coding tasks for this application.", parametersJSONSchema: #"{"type":"object","properties":{}}"#),
                ToolSpec(name: "command_output", description: "Read the current accumulated stdout and stderr of a background task.", parametersJSONSchema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#),
                ToolSpec(name: "command_cancel", description: "Cancel a running background task and its child processes.", parametersJSONSchema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#),
            ]
        }
        if enabled.contains(.codingGit) { result += Self.gitSpecs }
        if enabled.contains(.codingIndexing) {
            result += [
                ToolSpec(name: "project_index", description: "Build a bounded file map of the project and detect likely build and test commands.", parametersJSONSchema: #"{"type":"object","properties":{}}"#),
                ToolSpec(name: "project_symbols", description: "Search source files for declaration lines containing a class, function, type or other symbol name.", parametersJSONSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#),
                ToolSpec(name: "lsp_definition", description: "Find a symbol definition with the language server. Line and character are 1-based.", parametersJSONSchema: Self.lspSchema),
                ToolSpec(name: "lsp_references", description: "Find references to a symbol with the language server. Line and character are 1-based.", parametersJSONSchema: Self.lspSchema),
                ToolSpec(name: "lsp_diagnostics", description: "Get language-server diagnostics for a source file. Requires sourcekit-lsp, clangd, pyright or typescript-language-server for the file type.", parametersJSONSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#),
            ]
        }
        return result
    }

    private static func runSchema(script: Bool = false) -> String {
        if script {
            return #"{"type":"object","properties":{"path":{"type":"string"},"arguments":{"type":"array","items":{"type":"string"}},"location":{"type":"string","enum":["project","temporary"]},"cwd":{"type":"string"},"timeout":{"type":"integer"},"background":{"type":"boolean"}},"required":["path"]}"#
        }
        return #"{"type":"object","properties":{"executable":{"type":"string","description":"Executable name or absolute path; no shell syntax"},"arguments":{"type":"array","items":{"type":"string"}},"cwd":{"type":"string"},"location":{"type":"string","enum":["project","temporary"]},"timeout":{"type":"integer"},"background":{"type":"boolean"}},"required":["executable"]}"#
    }

    private static let lspSchema = #"{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"character":{"type":"integer"}},"required":["path","line","character"]}"#

    private static var gitSpecs: [ToolSpec] {
        [
            ToolSpec(
                name: "git_clone",
                description: "Clone an HTTP(S), SSH or git@ repository into a new directory inside Folder Access, then bind this chat to the clone. An absolute destination works without an existing project binding.",
                parametersJSONSchema: #"{"type":"object","properties":{"url":{"type":"string"},"path":{"type":"string","description":"New repository directory inside Folder Access; relative paths use the bound project or the sole allowed folder"},"branch":{"type":"string"},"depth":{"type":"integer"}},"required":["url","path"]}"#),
            ToolSpec(name: "git_status", description: "Show the bound project's Git status.", parametersJSONSchema: #"{"type":"object","properties":{}}"#),
            ToolSpec(name: "git_diff", description: "Show unstaged or staged Git diff, optionally for one path.", parametersJSONSchema: #"{"type":"object","properties":{"path":{"type":"string"},"staged":{"type":"boolean"}}}"#),
            ToolSpec(name: "git_log", description: "Show recent commits, optionally for one path.", parametersJSONSchema: #"{"type":"object","properties":{"limit":{"type":"integer"},"path":{"type":"string"}}}"#),
            ToolSpec(name: "git_show", description: "Show a commit or other Git object without changing the repository.", parametersJSONSchema: #"{"type":"object","properties":{"ref":{"type":"string"}},"required":["ref"]}"#),
            ToolSpec(name: "git_branch", description: "List, create, switch or delete a fully merged local branch. Mutations need approval.", parametersJSONSchema: #"{"type":"object","properties":{"action":{"type":"string","enum":["list","create","switch","delete"]},"name":{"type":"string"}},"required":["action"]}"#),
            ToolSpec(name: "git_add", description: "Stage explicit project paths after approval.", parametersJSONSchema: #"{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"}}},"required":["paths"]}"#),
            ToolSpec(name: "git_unstage", description: "Unstage explicit project paths after approval without changing their contents.", parametersJSONSchema: #"{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"}}},"required":["paths"]}"#),
            ToolSpec(name: "git_commit", description: "Commit staged changes with the supplied message after approval. Never pushes automatically.", parametersJSONSchema: #"{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}"#),
            ToolSpec(name: "git_fetch", description: "Fetch a remote after approval.", parametersJSONSchema: #"{"type":"object","properties":{"remote":{"type":"string"}}}"#),
            ToolSpec(name: "git_pull", description: "Pull with fast-forward only after approval.", parametersJSONSchema: #"{"type":"object","properties":{"remote":{"type":"string"},"branch":{"type":"string"}}}"#),
            ToolSpec(name: "git_push", description: "Push a branch after approval. Force push is not supported.", parametersJSONSchema: #"{"type":"object","properties":{"remote":{"type":"string"},"branch":{"type":"string"},"set_upstream":{"type":"boolean"}}}"#),
            ToolSpec(name: "git_stash", description: "List stashes, stash tracked changes, or pop a stash after approval.", parametersJSONSchema: #"{"type":"object","properties":{"action":{"type":"string","enum":["list","push","pop"]},"message":{"type":"string"}},"required":["action"]}"#),
            ToolSpec(name: "git_merge", description: "Merge a branch with --no-ff after approval; conflicts are reported for manual resolution.", parametersJSONSchema: #"{"type":"object","properties":{"branch":{"type":"string"}},"required":["branch"]}"#),
            ToolSpec(name: "git_rebase", description: "Rebase the current branch onto another ref after approval. Never force-pushes.", parametersJSONSchema: #"{"type":"object","properties":{"onto":{"type":"string"}},"required":["onto"]}"#),
            ToolSpec(name: "git_cherry_pick", description: "Cherry-pick explicit commits after approval; conflicts are reported for manual resolution.", parametersJSONSchema: #"{"type":"object","properties":{"commits":{"type":"array","items":{"type":"string"}}},"required":["commits"]}"#),
            ToolSpec(name: "git_tag", description: "List, create or delete local tags after approval. Remote tag deletion is not supported.", parametersJSONSchema: #"{"type":"object","properties":{"action":{"type":"string","enum":["list","create","delete"]},"name":{"type":"string"},"message":{"type":"string"}},"required":["action"]}"#),
            ToolSpec(name: "review_list", description: "List GitHub pull requests with gh or GitLab merge requests with glab when installed; otherwise return the hosting review URL from Git.", parametersJSONSchema: #"{"type":"object","properties":{"limit":{"type":"integer"}}}"#),
            ToolSpec(name: "review_create", description: "Create a PR/MR with gh/glab when installed; otherwise push with Git after approval and open the hosting review page.", parametersJSONSchema: #"{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"},"base":{"type":"string"},"draft":{"type":"boolean"}},"required":["title","body"]}"#),
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        throw CodingError.invalidCommand("Coding tools need a chat identifier.")
    }

    public func execute(_ call: ToolCall, chatID: UUID) async throws -> String {
        guard specs.contains(where: { $0.name == call.name }) else { throw ConversationError.unknownTool(call.name) }
        let args = ToolArguments(call.argumentsJSON)
        switch call.name {
        case "project_bind": return try await bind(chatID: chatID, args: args)
        case "task_update":
            _ = try await root(chatID: chatID)
            guard let state = args.string("state") else { return toolFailure(missing: "state") }
            await configuration.projects.setState(state, chatID: chatID)
            return "Coding task state saved."
        case "project_read": return try await read(chatID: chatID, args: args)
        case "project_search": return try await search(chatID: chatID, args: args)
        case "list_skills": return try await listSkills(chatID: chatID)
        case "read_skill": return try await readSkill(chatID: chatID, args: args)
        case "edit_file": return try await edit(chatID: chatID, args: args)
        case "apply_patch": return try await applyPatch(chatID: chatID, args: args)
        case "rollback_latest": return try await rollback(chatID: chatID)
        case "verify_changes": return try await verifyChanges(chatID: chatID, args: args)
        case "create_script": return try await createScript(chatID: chatID, args: args)
        case "run_script": return try await runScript(chatID: chatID, args: args)
        case "run_process": return try await runProcess(chatID: chatID, args: args)
        case "run_shell": return try await runShell(chatID: chatID, args: args)
        case "command_tasks": return await configuration.tasks.list(chatID: chatID)
        case "command_output":
            guard let id = args.string("id") else { return toolFailure(missing: "id") }
            return await configuration.tasks.output(id: id, chatID: chatID)
        case "command_cancel":
            guard let id = args.string("id") else { return toolFailure(missing: "id") }
            return await configuration.tasks.cancel(id: id, chatID: chatID)
        case "git_clone": return try await cloneRepository(chatID: chatID, args: args)
        case "git_status", "git_diff", "git_log", "git_show", "git_branch", "git_add", "git_unstage", "git_commit",
            "git_fetch", "git_pull", "git_push", "git_stash", "git_merge", "git_rebase", "git_cherry_pick", "git_tag",
            "review_list", "review_create":
            return try await git(call.name, chatID: chatID, args: args)
        case "project_index": return try await index(chatID: chatID)
        case "project_symbols": return try await symbols(chatID: chatID, args: args)
        case "lsp_definition", "lsp_references", "lsp_diagnostics": return try await languageServer(call.name, chatID: chatID, args: args)
        default: throw ConversationError.unknownTool(call.name)
        }
    }

    private func isAllowed(_ root: URL) -> Bool {
        configuration.allowedFolders.contains { folder in
            let allowed = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
            return root.path == allowed || root.path.hasPrefix(allowed + "/")
        }
    }

    private func root(chatID: UUID) async throws -> URL {
        guard let root = await configuration.projects.path(for: chatID) else { throw CodingError.noProject }
        guard isAllowed(root) else { throw CodingError.projectNotAllowed(root.path) }
        return root
    }

    private func workspace(chatID: UUID, location: String?) async throws -> URL {
        if location == "temporary" { return try await configuration.projects.temporaryDirectory(chatID: chatID) }
        return try await root(chatID: chatID)
    }

    private func resolve(_ path: String, root: URL, mustExist: Bool = true) throws -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        let candidate = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)
        let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { throw CodingError.invalidPath(path) }
        if mustExist, !FileManager.default.fileExists(atPath: url.path) { throw CodingError.invalidPath(path) }
        return url
    }

    private func relative(_ url: URL, root: URL) -> String {
        url.path == root.path ? "." : String(url.path.dropFirst(root.path.count + 1))
    }

    private func isSecret(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == ".env" || name.hasPrefix(".env.") || name == "id_rsa" || name == "id_ed25519" || name == "credentials"
            || ["pem", "p12", "pfx", "key"].contains(url.pathExtension.lowercased())
    }

    private func redact(_ text: String) -> String {
        text
            .replacing(/(sk-[A-Za-z0-9_-]{8,})/, with: "[redacted]")
            .replacing(/(gh[pousr]_[A-Za-z0-9_]{8,})/, with: "[redacted]")
            .replacing(/(Bearer )[A-Za-z0-9._~+\/-]+/, with: "$1[redacted]")
    }
}


extension CodingToolProvider {
    private func bind(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let path = args.string("path"), !path.isEmpty else { return toolFailure(missing: "path") }
        let expanded = NSString(string: path).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        guard isAllowed(candidate) else { throw CodingError.projectNotAllowed(candidate.path) }
        if let confirmation = configuration.confirmation {
            let allowed = await confirmation.confirm(
                title: String(localized: "Allow coding access to this project?"), detail: expanded, chatID: chatID,
                category: .projectAccess)
            guard allowed else { return "error: the user declined project access" }
        }
        let root = try await configuration.projects.bind(chatID: chatID, path: expanded)
        var result = "Bound this chat to \(root.path)."
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path) {
            result += " AGENTS.md was found and will be included in the coding context."
        }
        return result
    }

    private func read(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let path = args.string("path") else { return toolFailure(missing: "path") }
        let root = try await root(chatID: chatID)
        let url = try resolve(path, root: root)
        guard !isSecret(url) else { return "error: secret files are not exposed to the model" }
        var directory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        if directory.boolValue {
            let items = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted().prefix(500)
            return ToolOutput.wrap(items.joined(separator: "\n"), source: url.path)
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return "error: only UTF-8 text files can be read" }
        let offset = min(max(args.int("offset") ?? 0, 0), text.count)
        let limit = min(max(args.int("limit") ?? 12_000, 1), 20_000)
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: min(limit, text.count - offset))
        var result = ToolOutput.wrap(String(text[start..<end]), source: "\(url.path) [characters \(offset)..<\(offset + text[start..<end].count)]")
        let instructions = nestedInstructions(for: url, root: root)
        if !instructions.isEmpty { result = instructions + "\n\n" + result }
        return result
    }

    private func nestedInstructions(for file: URL, root: URL) -> String {
        var current = file.deletingLastPathComponent()
        var files: [URL] = []
        while current.path.hasPrefix(root.path), current.path != root.path {
            let candidate = current.appendingPathComponent("AGENTS.md")
            if candidate.path != root.appendingPathComponent("AGENTS.md").path, FileManager.default.fileExists(atPath: candidate.path) {
                files.append(candidate)
            }
            current = current.deletingLastPathComponent()
        }
        return files.reversed().compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map {
                "Nested project instructions from \(url.path); follow them for this file:\n" + $0.prefix(20_000)
            }
        }.joined(separator: "\n\n")
    }

    private func search(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let query = args.string("query"), !query.isEmpty else { return toolFailure(missing: "query") }
        let root = try await root(chatID: chatID)
        let files = FileToolProvider(configuration: .init(allowedFolders: [root]))
        return files.search(query: query, inContents: args.bool("in_contents") ?? false, roots: [root])
    }

    private func skillFiles(root: URL) -> [URL] {
        var result: [URL] = []
        for name in [".agents/skills", ".claude/skills", ".kimi/skills", "skills"] {
            let base = root.appendingPathComponent(name)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func listSkills(chatID: UUID) async throws -> String {
        let root = try await root(chatID: chatID)
        let files = skillFiles(root: root)
        guard !files.isEmpty else { return "No project SKILL.md files found." }
        return files.map { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return url.path }
            let frontmatter = text.hasPrefix("---") ? text.components(separatedBy: "---").dropFirst().first ?? "" : ""
            let name = frontmatter.components(separatedBy: .newlines).first { $0.hasPrefix("name:") }?
                .dropFirst(5).trimmingCharacters(in: .whitespaces)
            let description = frontmatter.components(separatedBy: .newlines).first { $0.hasPrefix("description:") }?
                .dropFirst(12).trimmingCharacters(in: .whitespaces)
            return ([url.path, name, description].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " — ")
        }.joined(separator: "\n")
    }

    private func readSkill(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let path = args.string("path") else { return toolFailure(missing: "path") }
        let root = try await root(chatID: chatID)
        let url = try resolve(path, root: root)
        guard skillFiles(root: root).contains(url) else { return "error: use an exact SKILL.md path returned by list_skills" }
        let text = try String(contentsOf: url, encoding: .utf8)
        return "Project skill \(url.path). Read referenced files with project_read; execute nothing automatically.\n" + text.prefix(20_000)
    }

    private func makeDiff(path: String, old: String, new: String) -> String {
        let removed = old.components(separatedBy: .newlines).map { "-" + $0 }.joined(separator: "\n")
        let added = new.components(separatedBy: .newlines).map { "+" + $0 }.joined(separator: "\n")
        return "--- a/\(path)\n+++ b/\(path)\n@@ exact replacement @@\n\(removed)\n\(added)"
    }

    private func edit(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let path = args.string("path"), let old = args.string("old_string"), let new = args.string("new_string") else {
            return toolFailure(missing: "path, old_string or new_string")
        }
        guard !old.isEmpty else { return "error: old_string must not be empty" }
        let root = try await root(chatID: chatID)
        let url = try resolve(path, root: root)
        guard !isSecret(url) else { return "error: secret files cannot be edited by the model" }
        let originalData = try Data(contentsOf: url)
        guard let original = String(data: originalData, encoding: .utf8) else { return "error: only UTF-8 text files can be edited" }
        let matches = original.components(separatedBy: old).count - 1
        guard matches > 0 else { return "error: old_string was not found" }
        guard matches == 1 || args.bool("replace_all") == true else {
            return "error: old_string occurs \(matches) times; make it unique or set replace_all=true"
        }
        let updated = original.replacingOccurrences(of: old, with: new)
        let relativePath = relative(url, root: root)
        guard try await approveDiff(
            chatID: chatID,
            title: String(localized: "Apply changes to \(relativePath)?"), diff: makeDiff(path: relativePath, old: old, new: new))
        else {
            return "error: the user declined the edit"
        }
        guard try Data(contentsOf: url) == originalData else { return "error: the file changed while the diff was being reviewed; read it again" }
        let snapshot = await configuration.snapshots.begin(chatID: chatID, root: root, files: [url])
        do {
            try Data(updated.utf8).write(to: url, options: .atomic)
            await configuration.snapshots.complete(chatID: chatID, snapshotID: snapshot, root: root)
            await configuration.projects.markEdited(chatID: chatID)
            return "Updated \(relativePath). \(matches) replacement(s) applied."
        } catch {
            await configuration.snapshots.discard(chatID: chatID, snapshotID: snapshot)
            throw error
        }
    }

    private func patchPaths(_ patch: String) -> [String] {
        var paths: Set<String> = []
        for line in patch.components(separatedBy: .newlines) {
            guard line.hasPrefix("+++ ") || line.hasPrefix("--- ") else { continue }
            var path = String(line.dropFirst(4)).components(separatedBy: "\t").first ?? ""
            if path.isEmpty { continue }
            if path == "/dev/null" { continue }
            if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
            paths.insert(path)
        }
        return paths.sorted()
    }

    private func applyPatch(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let patch = args.string("patch"), !patch.isEmpty else { return toolFailure(missing: "patch") }
        guard patch.count <= 500_000 else { return "error: patch is too large" }
        let root = try await root(chatID: chatID)
        let paths = patchPaths(patch)
        guard !paths.isEmpty else { return "error: no file paths found in the unified diff" }
        let files = try paths.map { try resolve($0, root: root, mustExist: false) }
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let checked = try await ToolProcess.runResult(
            git, ["apply", "--check", "--whitespace=nowarn", "-"], stdin: Data(patch.utf8), timeout: 30, directory: root)
        guard checked.status == 0 else { throw CodingError.commandFailed("Patch validation failed:\n\(redact(checked.output))") }
        guard try await approveDiff(chatID: chatID, title: String(localized: "Apply this patch?"), diff: patch) else {
            return "error: the user declined the patch"
        }
        let snapshot = await configuration.snapshots.begin(chatID: chatID, root: root, files: files)
        let result = try await ToolProcess.runResult(
            git, ["apply", "--whitespace=nowarn", "-"], stdin: Data(patch.utf8), timeout: 30, directory: root)
        guard result.status == 0 else {
            await configuration.snapshots.discard(chatID: chatID, snapshotID: snapshot)
            throw CodingError.commandFailed("Patch failed:\n\(redact(result.output))")
        }
        await configuration.snapshots.complete(chatID: chatID, snapshotID: snapshot, root: root)
        await configuration.projects.markEdited(chatID: chatID)
        return "Patch applied to \(paths.joined(separator: ", "))."
    }

    private func approveDiff(chatID: UUID, title: String, diff: String) async throws -> Bool {
        guard let confirmation = configuration.confirmation else { return false }
        return await confirmation.confirmDiff(title: title, diff: diff, chatID: chatID, category: .fileEdit)
    }

    private func rollback(chatID: UUID) async throws -> String {
        guard let snapshot = await configuration.snapshots.latest(chatID: chatID) else { return "No coding snapshot is available." }
        let project = await configuration.projects.path(for: chatID)
        let temporary = try await configuration.projects.temporaryDirectory(chatID: chatID)
        guard snapshot.root == project?.path || snapshot.root == temporary.path else {
            return "error: the latest snapshot belongs to another project"
        }
        let root = URL(fileURLWithPath: snapshot.root, isDirectory: true)
        if snapshot.root == project?.path, !isAllowed(root) { throw CodingError.projectNotAllowed(root.path) }
        let paths = snapshot.entries.map(\.relativePath).joined(separator: "\n")
        guard let confirmation = configuration.confirmation,
            await confirmation.confirm(
                title: String(localized: "Roll back the latest coding changes?"), detail: paths, chatID: chatID,
                category: .fileEdit)
        else { return "error: the user declined the rollback" }
        var restored: [String] = []
        var skipped: [String] = []
        for entry in snapshot.entries {
            let url = try resolve(entry.relativePath, root: root, mustExist: false)
            let current = try? Data(contentsOf: url)
            guard current == entry.after else {
                skipped.append(entry.relativePath)
                continue
            }
            if let before = entry.before {
                try before.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            restored.append(entry.relativePath)
        }
        await configuration.snapshots.remove(chatID: chatID, snapshotID: snapshot.id)
        if !restored.isEmpty { await configuration.projects.markEdited(chatID: chatID) }
        return "Restored: \(restored.joined(separator: ", "))\nSkipped because the user changed them: \(skipped.joined(separator: ", "))"
    }

    private func createScript(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let path = args.string("path"), let content = args.string("content") else { return toolFailure(missing: "path or content") }
        guard ["py", "sh", "bash"].contains(NSString(string: path).pathExtension.lowercased()) else {
            return "error: use a .py, .sh or .bash extension"
        }
        guard content.count <= 200_000 else { return "error: script is too large" }
        let root = try await workspace(chatID: chatID, location: args.string("location"))
        let url = try resolve(path, root: root, mustExist: false)
        guard !isSecret(url) else { return "error: secret files cannot be created by the model" }
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard !exists || args.bool("overwrite") == true else { return "error: the script exists; set overwrite=true to replace it" }
        let originalData = try? Data(contentsOf: url)
        let original = originalData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let relativePath = relative(url, root: root)
        let diff = makeDiff(path: relativePath, old: original, new: content)
        guard try await approveDiff(chatID: chatID, title: String(localized: "Create or update script \(relativePath)?"), diff: diff) else {
            return "error: the user declined the script"
        }
        guard (try? Data(contentsOf: url)) == originalData else { return "error: the script changed while it was being reviewed" }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot = await configuration.snapshots.begin(chatID: chatID, root: root, files: [url])
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
            await configuration.snapshots.complete(chatID: chatID, snapshotID: snapshot, root: root)
            await configuration.projects.markEdited(chatID: chatID)
            return "Script saved: \(url.path)"
        } catch {
            await configuration.snapshots.discard(chatID: chatID, snapshotID: snapshot)
            throw error
        }
    }
}


extension CodingToolProvider {
    private func executable(_ value: String) throws -> URL {
        if value.hasPrefix("/") {
            let url = URL(fileURLWithPath: value).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CodingError.invalidCommand("Not executable: \(value)") }
            return url
        }
        guard !value.contains("/") else { throw CodingError.invalidCommand("Use an executable name or an absolute path: \(value)") }
        for directory in ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin", "/usr/sbin", "/sbin"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(value)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw CodingError.invalidCommand("Executable not found in standard system paths: \(value)")
    }

    private func workingDirectory(chatID: UUID, args: ToolArguments) async throws -> URL {
        let root = try await workspace(chatID: chatID, location: args.string("location"))
        guard let cwd = args.string("cwd"), !cwd.isEmpty else { return root }
        let url = try resolve(cwd, root: root)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw CodingError.invalidPath(cwd)
        }
        return url
    }

    private func runScript(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let path = args.string("path") else { return toolFailure(missing: "path") }
        let root = try await workspace(chatID: chatID, location: args.string("location"))
        let script = try resolve(path, root: root)
        let interpreter: URL
        switch script.pathExtension.lowercased() {
        case "py": interpreter = try executable("python3")
        case "sh": interpreter = URL(fileURLWithPath: "/bin/sh")
        case "bash": interpreter = URL(fileURLWithPath: "/bin/bash")
        default: return "error: only .py, .sh and .bash scripts can be run"
        }
        let directory = try resolve(args.string("cwd") ?? ".", root: root)
        return try await execute(
            chatID: chatID,
            interpreter, [script.path] + (args.strings("arguments") ?? []), directory: directory,
            timeout: args.int("timeout"), background: args.bool("background") ?? false)
    }

    private func runProcess(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let value = args.string("executable") else { return toolFailure(missing: "executable") }
        let binary = try executable(value)
        let directory = try await workingDirectory(chatID: chatID, args: args)
        return try await execute(
            chatID: chatID,
            binary, args.strings("arguments") ?? [], directory: directory,
            timeout: args.int("timeout"), background: args.bool("background") ?? false)
    }

    private func runShell(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let command = args.string("command"), !command.isEmpty else { return toolFailure(missing: "command") }
        let shell = args.string("shell") ?? "sh"
        guard ["sh", "bash"].contains(shell) else { return "error: shell must be sh or bash" }
        let directory = try await workingDirectory(chatID: chatID, args: args)
        return try await execute(
            chatID: chatID,
            URL(fileURLWithPath: "/bin/\(shell)"), ["-c", command], directory: directory,
            timeout: args.int("timeout"), background: args.bool("background") ?? false)
    }

    private func execute(
        chatID: UUID, _ binary: URL, _ arguments: [String], directory: URL, timeout: Int?, background: Bool
    ) async throws -> String {
        let seconds = min(max(timeout ?? 120, 1), 3600)
        let command = ([binary.path] + arguments).joined(separator: " ")
        if let confirmation = configuration.confirmation {
            let allowed = await confirmation.confirm(
                title: String(localized: "Run this coding command?"), detail: "\(command)\n\nWorking directory: \(directory.path)",
                chatID: chatID, category: .command)
            guard allowed else { return "error: the user declined the command" }
        }
        if background {
            let id = await configuration.tasks.start(chatID: chatID, command: command) { onOutput in
                let result = try await ToolProcess.runResult(
                    binary, arguments, timeout: TimeInterval(seconds), directory: directory,
                    onOutput: { chunk in onOutput(CodingToolProvider.redactStatic(chunk)) })
                return ToolProcessResult(output: CodingToolProvider.redactStatic(result.output), status: result.status)
            }
            return "Started background task \(id). Use command_output to inspect it or command_cancel to stop it."
        }
        let result = try await ToolProcess.runResult(binary, arguments, timeout: TimeInterval(seconds), directory: directory)
        return "Exit code: \(result.status)\n" + redact(result.output).clipped(to: 40_000)
    }

    private static func redactStatic(_ text: String) -> String {
        text
            .replacing(/(sk-[A-Za-z0-9_-]{8,})/, with: "[redacted]")
            .replacing(/(gh[pousr]_[A-Za-z0-9_]{8,})/, with: "[redacted]")
            .replacing(/(Bearer )[A-Za-z0-9._~+\/-]+/, with: "$1[redacted]")
    }

    private func gitResult(root: URL, _ arguments: [String], stdin: Data? = nil) async throws -> ToolProcessResult {
        try await ToolProcess.runResult(
            URL(fileURLWithPath: "/usr/bin/git"), arguments, stdin: stdin, timeout: 120, directory: root)
    }

    private func gitOutput(_ result: ToolProcessResult) throws -> String {
        let output = redact(result.output)
        guard result.status == 0 else { throw CodingError.commandFailed(output.isEmpty ? "Git exited with \(result.status)" : output) }
        return output.clipped(to: 40_000)
    }

    private func checkedPaths(_ values: [String]?, root: URL) throws -> [String] {
        guard let values, !values.isEmpty else { throw CodingError.invalidCommand("Specify at least one project path") }
        return try values.map { relative(try resolve($0, root: root, mustExist: false), root: root) }
    }

    private func confirm(_ title: String, _ detail: String, chatID: UUID) async -> Bool {
        guard let confirmation = configuration.confirmation else { return false }
        return await confirmation.confirm(title: title, detail: detail, chatID: chatID, category: .git)
    }

    private func cloneRepository(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let url = args.string("url"), let path = args.string("path"), !url.isEmpty, !path.isEmpty else {
            return toolFailure(missing: "url or path")
        }
        guard url.hasPrefix("https://") || url.hasPrefix("http://") || url.hasPrefix("ssh://") || url.hasPrefix("git@") else {
            return "error: clone URL must use HTTP(S), SSH or git@ form"
        }
        let expanded = NSString(string: path).expandingTildeInPath
        let destination: URL
        if expanded.hasPrefix("/") {
            destination = URL(fileURLWithPath: expanded)
        } else if let project = await configuration.projects.path(for: chatID) {
            destination = project.appendingPathComponent(expanded)
        } else if configuration.allowedFolders.count == 1, let folder = configuration.allowedFolders.first {
            destination = URL(fileURLWithPath: folder).appendingPathComponent(expanded)
        } else {
            return "error: use an absolute destination inside Folder Access"
        }
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard isAllowed(target) else { throw CodingError.projectNotAllowed(target.path) }
        guard !FileManager.default.fileExists(atPath: target.path) else { return "error: the clone destination already exists" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "error: the destination parent directory does not exist"
        }
        let branch = args.string("branch")
        guard branch?.hasPrefix("-") != true else { return "error: invalid branch" }
        var arguments = ["clone"]
        if let branch { arguments += ["--branch", branch] }
        if let depth = args.int("depth") {
            guard depth > 0 else { return "error: depth must be positive" }
            arguments += ["--depth", "\(depth)"]
        }
        arguments += ["--", url, target.path]
        guard await confirm(String(localized: "Clone this repository?"), "\(url)\n→ \(target.path)", chatID: chatID) else {
            return "error: the user declined the clone"
        }
        let result = try await gitResult(root: target.deletingLastPathComponent(), arguments)
        guard result.status == 0 else { throw CodingError.commandFailed(redact(result.output)) }
        let cloned = try await configuration.projects.bind(chatID: chatID, path: target.path)
        return redact(result.output) + "\nCloned and bound this chat to \(cloned.path)."
    }

    private func git(_ name: String, chatID: UUID, args: ToolArguments) async throws -> String {
        let root = try await root(chatID: chatID)
        switch name {
        case "git_status":
            return try gitOutput(await gitResult(root: root, ["status", "--short", "--branch"]))
        case "git_diff":
            var arguments = ["diff", "--no-ext-diff", "--no-color"]
            if args.bool("staged") == true { arguments.append("--cached") }
            if let path = args.string("path") {
                arguments += ["--", try relative(resolve(path, root: root, mustExist: false), root: root)]
            }
            let output = try gitOutput(await gitResult(root: root, arguments))
            return output.isEmpty ? "No diff." : output
        case "git_log":
            let limit = min(max(args.int("limit") ?? 20, 1), 100)
            var arguments = ["log", "--oneline", "--decorate", "-n", "\(limit)"]
            if let path = args.string("path") {
                arguments += ["--", try relative(resolve(path, root: root, mustExist: false), root: root)]
            }
            return try gitOutput(await gitResult(root: root, arguments))
        case "git_show":
            guard let ref = args.string("ref"), !ref.isEmpty, !ref.hasPrefix("-") else { return toolFailure(missing: "ref") }
            return try gitOutput(await gitResult(root: root, ["show", "--no-color", ref]))
        case "git_branch":
            return try await gitBranch(chatID: chatID, root: root, args: args)
        case "git_add", "git_unstage":
            let paths = try checkedPaths(args.strings("paths"), root: root)
            guard await confirm(
                String(localized: name == "git_add" ? "Stage these paths?" : "Unstage these paths?"),
                paths.joined(separator: "\n"), chatID: chatID)
            else { return "error: the user declined the Git change" }
            let arguments = name == "git_add" ? ["add", "--"] + paths : ["restore", "--staged", "--"] + paths
            _ = try gitOutput(await gitResult(root: root, arguments))
            return (name == "git_add" ? "Staged:\n" : "Unstaged:\n") + paths.joined(separator: "\n")
        case "git_commit":
            guard let message = args.string("message"), !message.isEmpty else { return toolFailure(missing: "message") }
            let staged = try gitOutput(await gitResult(root: root, ["diff", "--cached", "--stat"]))
            guard !staged.isEmpty else { return "error: there are no staged changes" }
            guard await confirm(String(localized: "Commit staged changes?"), message + "\n\n" + staged, chatID: chatID) else {
                return "error: the user declined the commit"
            }
            return try gitOutput(await gitResult(root: root, ["commit", "-m", message]))
        case "git_fetch":
            let remote = args.string("remote") ?? "origin"
            guard !remote.hasPrefix("-") else { return "error: invalid remote" }
            guard await confirm(String(localized: "Fetch from \(remote)?"), root.path, chatID: chatID) else { return "error: the user declined the fetch" }
            return try gitOutput(await gitResult(root: root, ["fetch", "--prune", remote]))
        case "git_pull":
            let remote = args.string("remote") ?? "origin"
            guard !remote.hasPrefix("-"), args.string("branch")?.hasPrefix("-") != true else { return "error: invalid remote or branch" }
            var arguments = ["pull", "--ff-only", remote]
            if let branch = args.string("branch") { arguments.append(branch) }
            guard await confirm(String(localized: "Pull with fast-forward only?"), arguments.joined(separator: " "), chatID: chatID) else {
                return "error: the user declined the pull"
            }
            return try gitOutput(await gitResult(root: root, arguments))
        case "git_push":
            let remote = args.string("remote") ?? "origin"
            guard !remote.hasPrefix("-"), args.string("branch")?.hasPrefix("-") != true else { return "error: invalid remote or branch" }
            var arguments = ["push"]
            if args.bool("set_upstream") == true { arguments.append("--set-upstream") }
            arguments.append(remote)
            if let branch = args.string("branch") { arguments.append(branch) }
            let commits = (try? gitOutput(await gitResult(root: root, ["log", "--oneline", "@{upstream}..HEAD"]))) ?? ""
            guard await confirm(String(localized: "Push to the remote repository?"), arguments.joined(separator: " ") + "\n\n" + commits, chatID: chatID) else {
                return "error: the user declined the push"
            }
            return try gitOutput(await gitResult(root: root, arguments))
        case "git_stash", "git_merge", "git_rebase", "git_cherry_pick", "git_tag":
            return try await gitAdvanced(name, chatID: chatID, root: root, args: args)
        case "review_list", "review_create":
            return try await review(name, chatID: chatID, root: root, args: args)
        default: throw ConversationError.unknownTool(name)
        }
    }

    private func gitBranch(chatID: UUID, root: URL, args: ToolArguments) async throws -> String {
        guard let action = args.string("action") else { return toolFailure(missing: "action") }
        if action == "list" { return try gitOutput(await gitResult(root: root, ["branch", "--all", "--verbose"])) }
        guard let name = args.string("name"), !name.isEmpty, !name.hasPrefix("-") else { return toolFailure(missing: "name") }
        let checked = try await gitResult(root: root, ["check-ref-format", "--branch", name])
        guard checked.status == 0 else { return "error: invalid branch name" }
        guard ["create", "switch", "delete"].contains(action) else { return "error: action must be list, create, switch or delete" }
        guard await confirm(String(localized: "Change the current Git branch?"), action + " " + name, chatID: chatID) else {
            return "error: the user declined the branch change"
        }
        let arguments = action == "create" ? ["branch", name] : action == "switch" ? ["switch", name] : ["branch", "-d", name]
        return try gitOutput(await gitResult(root: root, arguments))
    }

    private func reviewHosting(root: URL) async throws -> (provider: String, web: String) {
        let remote = try gitOutput(await gitResult(root: root, ["remote", "get-url", "origin"])).trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let path: String
        if remote.hasPrefix("git@") {
            let value = remote.dropFirst(4)
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw CodingError.invalidCommand("Unsupported origin URL: \(remote)") }
            host = parts[0]
            path = parts[1]
        } else if let url = URL(string: remote), let parsedHost = url.host {
            host = parsedHost
            path = url.path
        } else {
            throw CodingError.invalidCommand("Unsupported origin URL: \(remote)")
        }
        let provider = host.contains("github") ? "gh" : host.contains("gitlab") ? "glab" : ""
        guard !provider.isEmpty else { throw CodingError.invalidCommand("The origin remote must be GitHub or GitLab") }
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: ".git", with: "")
        return (provider, "https://\(host)/\(cleanPath)")
    }

    private func review(_ name: String, chatID: UUID, root: URL, args: ToolArguments) async throws -> String {
        let hosting = try await reviewHosting(root: root)
        guard let binary = try? executable(hosting.provider) else {
            if name == "review_list" {
                return "Review list: \(hosting.web)/\(hosting.provider == "gh" ? "pulls" : "-/merge_requests")"
            }
            return try await reviewWithGit(chatID: chatID, hosting: hosting, root: root, args: args)
        }
        let provider = hosting.provider
        if name == "review_list" {
            let limit = min(max(args.int("limit") ?? 20, 1), 100)
            let arguments = provider == "gh" ? ["pr", "list", "--limit", "\(limit)"] : ["mr", "list", "--per-page", "\(limit)"]
            let result = try await ToolProcess.runResult(binary, arguments, timeout: 60, directory: root)
            return try gitOutput(result)
        }
        guard let title = args.string("title"), let body = args.string("body"), !title.isEmpty else { return toolFailure(missing: "title or body") }
        let base = args.string("base")
        guard base?.hasPrefix("-") != true else { return "error: invalid base branch" }
        let draft = args.bool("draft") ?? false
        let current = try gitOutput(await gitResult(root: root, ["branch", "--show-current"]))
        var arguments = provider == "gh"
            ? ["pr", "create", "--title", title, "--body", body]
            : ["mr", "create", "--yes", "--title", title, "--description", body, "--source-branch", current]
        if let base { arguments += provider == "gh" ? ["--base", base] : ["--target-branch", base] }
        if draft { arguments.append("--draft") }
        let detail = ([binary.path] + arguments).joined(separator: " ")
        guard await confirm(String(localized: "Create a pull request or merge request?"), detail, chatID: chatID) else {
            return "error: the user declined the review creation"
        }
        let result = try await ToolProcess.runResult(binary, arguments, timeout: 120, directory: root)
        return try gitOutput(result)
    }

    private func reviewWithGit(chatID: UUID, hosting: (provider: String, web: String), root: URL, args: ToolArguments) async throws -> String {
        guard let title = args.string("title"), let body = args.string("body"), !title.isEmpty else { return toolFailure(missing: "title or body") }
        let base = args.string("base") ?? "main"
        guard !base.hasPrefix("-") else { return "error: invalid base branch" }
        let current = try gitOutput(await gitResult(root: root, ["branch", "--show-current"])).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return "error: a named current branch is required" }
        let push = ["push", "--set-upstream", "origin", current]
        guard await confirm(String(localized: "Push to the remote repository?"), push.joined(separator: " "), chatID: chatID) else {
            return "error: the user declined the push"
        }
        _ = try gitOutput(await gitResult(root: root, push))
        var components = hosting.provider == "gh"
            ? URLComponents(string: "\(hosting.web)/compare/\(base)...\(current)")
            : URLComponents(string: "\(hosting.web)/-/merge_requests/new")
        if hosting.provider == "gh" {
            components?.queryItems = [URLQueryItem(name: "quick_pull", value: "1"), URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
            if args.bool("draft") == true { components?.queryItems?.append(URLQueryItem(name: "draft", value: "1")) }
        } else {
            components?.queryItems = [
                URLQueryItem(name: "merge_request[source_branch]", value: current),
                URLQueryItem(name: "merge_request[target_branch]", value: base),
                URLQueryItem(name: "merge_request[title]", value: title),
                URLQueryItem(name: "merge_request[description]", value: body),
            ]
            if args.bool("draft") == true { components?.queryItems?.append(URLQueryItem(name: "merge_request[draft]", value: "true")) }
        }
        guard let url = components?.url else { return "error: could not build the review URL" }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        return opened ? "Branch pushed; review page opened: \(url.absoluteString)" : "Branch pushed; open this review page: \(url.absoluteString)"
    }
}


extension CodingToolProvider {
    private var skippedDirectories: Set<String> { [".git", ".build", "DerivedData", "node_modules", ".next", "dist", "build", "__pycache__"] }
    private var sourceExtensions: Set<String> { ["swift", "m", "mm", "h", "c", "cpp", "py", "js", "ts", "tsx", "rs", "go", "java", "kt"] }

    private func projectFiles(root: URL, limit: Int = 5_000) -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if ["xcodeproj", "xcworkspace", "playground"].contains(url.pathExtension.lowercased()) {
                    result.append(url)
                    enumerator.skipDescendants()
                } else if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            result.append(url)
            if result.count >= limit { break }
        }
        return result
    }

    private func index(chatID: UUID) async throws -> String {
        let root = try await root(chatID: chatID)
        let files = projectFiles(root: root)
        var commands: [String] = []
        if files.contains(where: { $0.lastPathComponent == "Package.swift" }) { commands += ["swift build", "swift test"] }
        if files.contains(where: { $0.pathExtension == "xcodeproj" || $0.pathExtension == "xcworkspace" }) {
            commands.append("xcodebuild -list; select a scheme, then xcodebuild -scheme <scheme> build/test")
        }
        if files.contains(where: { $0.lastPathComponent == "package.json" }) { commands += ["inspect package.json scripts", "npm test / npm run build"] }
        if files.contains(where: { $0.lastPathComponent == "pyproject.toml" || $0.lastPathComponent == "requirements.txt" }) {
            commands.append("inspect pyproject.toml; python3 -m pytest when configured")
        }
        if files.contains(where: { $0.lastPathComponent == "Makefile" }) { commands.append("inspect Makefile targets") }
        let paths = files.prefix(500).map { relative($0, root: root) }.joined(separator: "\n")
        return "Indexed \(files.count) files (up to 500 shown).\n\nLikely verification commands:\n"
            + (commands.isEmpty ? "No standard build manifest detected." : commands.joined(separator: "\n"))
            + "\n\nFiles:\n" + paths
    }

    private func symbols(chatID: UUID, args: ToolArguments) async throws -> String {
        guard let query = args.string("query"), !query.isEmpty else { return toolFailure(missing: "query") }
        let root = try await root(chatID: chatID)
        let declarations = ["class ", "struct ", "enum ", "actor ", "protocol ", "func ", "def ", "function ", "interface ", "type ", "impl ", "trait "]
        var matches: [String] = []
        for file in projectFiles(root: root, limit: 1_000) where sourceExtensions.contains(file.pathExtension.lowercased()) {
            guard !isSecret(file), let data = try? Data(contentsOf: file), data.count < 2_000_000,
                let text = String(data: data, encoding: .utf8)
            else { continue }
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.localizedCaseInsensitiveContains(query), declarations.contains(where: { trimmed.hasPrefix($0) || trimmed.contains(" " + $0) })
                else { continue }
                matches.append("\(relative(file, root: root)):\(index + 1): \(trimmed)")
                if matches.count >= 100 { return matches.joined(separator: "\n") }
            }
        }
        return matches.isEmpty ? "No declarations matched \(query)." : matches.joined(separator: "\n")
    }
}


extension CodingToolProvider {
    private func verifyChanges(chatID: UUID, args: ToolArguments) async throws -> String {
        guard configuration.enabled.contains(.codingCommands) else {
            let message = "Verification not run: enable Coding → Commands first."
            await configuration.projects.recordVerification(message, chatID: chatID)
            return message
        }
        do {
            let root = try await root(chatID: chatID)
            guard let command = args.string("command").flatMap({ $0.isEmpty ? nil : $0 }) ?? verificationCommand(root: root) else {
                let message = "Verification not run: no build or test command was detected. Supply verify_changes.command explicitly."
                await configuration.projects.recordVerification(message, chatID: chatID)
                return message
            }
            let result = try await execute(
                chatID: chatID, URL(fileURLWithPath: "/bin/sh"), ["-c", command], directory: root,
                timeout: args.int("timeout") ?? 600, background: false)
            let status = result.hasPrefix("Exit code: 0") ? "passed" : result.hasPrefix("Exit code:") ? "failed" : "declined"
            await configuration.projects.recordVerification("$ \(command)\n\(result)", chatID: chatID, status: status)
            return result
        } catch {
            let message = "Verification not run: \(error.localizedDescription)"
            await configuration.projects.recordVerification(message, chatID: chatID)
            return message
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func verificationCommand(root: URL) -> String? {
        let files = projectFiles(root: root)
        let names = Set(files.map(\.lastPathComponent))
        if names.contains("Package.swift") {
            return files.contains(where: { $0.path.contains("/Tests/") }) ? "swift test" : "swift build"
        }
        if names.contains("Cargo.toml") { return "cargo test" }
        if names.contains("go.mod") { return "go test ./..." }
        if names.contains("package.json"), let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
            let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let scripts = manifest["scripts"] as? [String: Any]
        {
            if scripts["test"] != nil { return "npm test" }
            if scripts["build"] != nil { return "npm run build" }
        }
        if names.contains("pyproject.toml") || names.contains("requirements.txt"),
            files.contains(where: { $0.lastPathComponent.hasPrefix("test_") && $0.pathExtension == "py" })
        { return "python3 -m pytest" }
        if names.contains("Makefile"), let makefile = try? String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8) {
            if makefile.contains("\ntest:") { return "make test" }
            if makefile.contains("\nbuild:") { return "make build" }
            return "make"
        }
        let containers = files.filter { ["xcworkspace", "xcodeproj"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.pathExtension == "xcworkspace" && $1.pathExtension != "xcworkspace" }
        for container in containers {
            let schemesURL = container.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
            guard let schemes = try? FileManager.default.contentsOfDirectory(at: schemesURL, includingPropertiesForKeys: nil),
                let scheme = schemes.first(where: { $0.pathExtension == "xcscheme" })?.deletingPathExtension().lastPathComponent
            else { continue }
            let kind = container.pathExtension.lowercased() == "xcworkspace" ? "-workspace" : "-project"
            return "xcodebuild \(kind) \(shellQuote(container.path)) -scheme \(shellQuote(scheme)) -destination 'platform=macOS' build"
        }
        return nil
    }
}


extension CodingToolProvider {
    private func languageServer(_ name: String, chatID: UUID, args: ToolArguments) async throws -> String {
        guard let path = args.string("path") else { return toolFailure(missing: "path") }
        let root = try await root(chatID: chatID)
        let file = try resolve(path, root: root)
        guard !isSecret(file), let text = try? String(contentsOf: file, encoding: .utf8) else { return "error: a UTF-8 source file is required" }
        let server = try lspServer(for: file)
        let session = CodingLSPSession()
        do {
            try await session.start(binary: server.binary, arguments: server.arguments, root: root)
            try await session.open(file, text: text, language: server.language)
            let data: Data
            switch name {
            case "lsp_definition":
                guard let position = lspPosition(args) else { return toolFailure(missing: "line or character") }
                data = try await session.definition(file: file, line: position.line, character: position.character)
            case "lsp_references":
                guard let position = lspPosition(args) else { return toolFailure(missing: "line or character") }
                data = try await session.references(file: file, line: position.line, character: position.character)
            default:
                data = try await session.diagnostics(file: file)
            }
            await session.close()
            return name == "lsp_diagnostics" ? formatDiagnostics(data, root: root) : formatLocations(data, root: root)
        } catch {
            await session.close()
            throw error
        }
    }

    private func lspPosition(_ args: ToolArguments) -> (line: Int, character: Int)? {
        guard let line = args.int("line"), let character = args.int("character"), line > 0, character > 0 else { return nil }
        return (line, character)
    }

    private func lspServer(for file: URL) throws -> (binary: URL, arguments: [String], language: String) {
        switch file.pathExtension.lowercased() {
        case "swift": (URL(fileURLWithPath: "/usr/bin/xcrun"), ["sourcekit-lsp"], "swift")
        case "c": (try executable("clangd"), [], "c")
        case "h", "cpp", "cc", "cxx", "hpp", "m", "mm": (try executable("clangd"), [], "cpp")
        case "py": (try executable("pyright-langserver"), ["--stdio"], "python")
        case "js", "jsx": (try executable("typescript-language-server"), ["--stdio"], "javascript")
        case "ts", "tsx": (try executable("typescript-language-server"), ["--stdio"], "typescript")
        default: throw CodingError.invalidCommand("No language server is configured for .\(file.pathExtension) files")
        }
    }

    private func formatLocations(_ data: Data, root: URL) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return "No definition locations found." }
        let locations: [[String: Any]]
        if let location = object as? [String: Any] { locations = [location] }
        else if let list = object as? [[String: Any]] { locations = list }
        else { locations = [] }
        let lines = locations.compactMap { location -> String? in
            guard let uri = (location["uri"] ?? location["targetUri"]) as? String,
                let range = (location["range"] ?? location["targetSelectionRange"]) as? [String: Any],
                let start = range["start"] as? [String: Any], let line = start["line"] as? Int, let character = start["character"] as? Int
            else { return nil }
            let path = URL(string: uri)?.path ?? uri
            let name = path.hasPrefix(root.path) ? String(path.dropFirst(root.path.count + 1)) : path
            return "\(name):\(line + 1):\(character + 1)"
        }
        return lines.isEmpty ? "No locations found." : lines.joined(separator: "\n")
    }

    private func formatDiagnostics(_ data: Data, root: URL) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "No diagnostics." }
        let items = (object["items"] ?? object["diagnostics"]) as? [[String: Any]] ?? []
        if items.isEmpty { return "No diagnostics." }
        return items.prefix(100).map { item in
            let range = item["range"] as? [String: Any]
            let start = range?["start"] as? [String: Any]
            let line = (start?["line"] as? Int).map { $0 + 1 } ?? 0
            let character = (start?["character"] as? Int).map { $0 + 1 } ?? 0
            let severity = item["severity"] as? Int ?? 0
            let level = [1: "error", 2: "warning", 3: "info", 4: "hint"][severity] ?? "diagnostic"
            return "\(line):\(character) \(level): \(item["message"] as? String ?? "")"
        }.joined(separator: "\n")
    }
}


extension CodingToolProvider {
    private func gitAdvanced(_ name: String, chatID: UUID, root: URL, args: ToolArguments) async throws -> String {
        if name == "git_stash", args.string("action") == "list" {
            return try gitOutput(await gitResult(root: root, ["stash", "list"]))
        }
        if name == "git_tag", args.string("action") == "list" {
            return try gitOutput(await gitResult(root: root, ["tag", "--list", "--sort=-creatordate"]))
        }
        var arguments: [String] = []
        var changesWorkingTree = false
        switch name {
        case "git_stash":
            guard let action = args.string("action"), ["push", "pop"].contains(action) else { return "error: action must be list, push or pop" }
            arguments = ["stash", action]
            if action == "push", let message = args.string("message"), !message.isEmpty { arguments += ["-m", message] }
            changesWorkingTree = true
        case "git_merge":
            guard let branch = args.string("branch"), !branch.isEmpty, !branch.hasPrefix("-") else { return toolFailure(missing: "branch") }
            arguments = ["merge", "--no-ff", branch]
            changesWorkingTree = true
        case "git_rebase":
            guard let onto = args.string("onto"), !onto.isEmpty, !onto.hasPrefix("-") else { return toolFailure(missing: "onto") }
            arguments = ["rebase", onto]
            changesWorkingTree = true
        case "git_cherry_pick":
            guard let commits = args.strings("commits"), !commits.isEmpty, commits.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else {
                return toolFailure(missing: "commits")
            }
            arguments = ["cherry-pick"] + commits
            changesWorkingTree = true
        case "git_tag":
            guard let action = args.string("action"), let tag = args.string("name"), !tag.isEmpty, !tag.hasPrefix("-") else {
                return toolFailure(missing: "action or name")
            }
            guard ["create", "delete"].contains(action) else { return "error: action must be list, create or delete" }
            if action == "delete" {
                arguments = ["tag", "-d", tag]
            } else if let message = args.string("message"), !message.isEmpty {
                arguments = ["tag", "-a", tag, "-m", message]
            } else {
                arguments = ["tag", tag]
            }
        default: throw ConversationError.unknownTool(name)
        }
        guard await confirm(String(localized: "Run this Git operation?"), arguments.joined(separator: " "), chatID: chatID) else {
            return "error: the user declined the Git operation"
        }
        let output = try gitOutput(await gitResult(root: root, arguments))
        if changesWorkingTree { await configuration.projects.markEdited(chatID: chatID) }
        return output.isEmpty ? "Git operation completed: \(arguments.joined(separator: " "))" : output
    }
}
