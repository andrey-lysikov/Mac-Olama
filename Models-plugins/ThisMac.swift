//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import ScreenCaptureKit
import Vision

// Tools that answer from this Mac instead of the model's memory, and act on it: its own state, network checks, the
// user's Shortcuts, the volume, the appearance and apps, Music, the clipboard and the text on the screen.

// Mac info

/// `mac_info`: the state of this Mac, read with public APIs and stock read-only command-line tools.
public struct MacInfoToolProvider: ToolProvider {
    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "mac_info",
                description:
                    "Read the state of this Mac: overview (model, chip, macOS, memory, uptime, load, temperature state), battery, storage (volumes and free space), memory (pressure and usage), processes (top by CPU and by memory), network (active interfaces and addresses).",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"topic":{"type":"string","enum":["overview","battery","storage","memory","processes","network"]}},"required":["topic"]}"#
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        let topic = args.string("topic") ?? "overview"
        let text: String
        switch topic {
        case "battery": text = try await ToolProcess.run("/usr/bin/pmset", ["-g", "batt"])
        case "storage": text = Self.storage()
        case "memory":
            let pressure = try await ToolProcess.run("/usr/bin/memory_pressure", [])
            let summary = pressure.split(separator: "\n").suffix(3).joined(separator: "\n")
            text = "Physical memory: \(Self.bytes(Int64(ProcessInfo.processInfo.physicalMemory)))\n\(summary)"
        case "processes":
            let cpu = try await ToolProcess.run("/bin/ps", ["-Aceo", "pid,pcpu,pmem,rss,comm", "-r"])
            let memory = try await ToolProcess.run("/bin/ps", ["-Aceo", "pid,pcpu,pmem,rss,comm", "-m"])
            text =
                "Top by CPU:\n" + cpu.split(separator: "\n").prefix(11).joined(separator: "\n") + "\n\nTop by memory:\n"
                + memory.split(separator: "\n").prefix(11).joined(separator: "\n")
        case "network": text = try await ToolProcess.run("/usr/sbin/scutil", ["--nwi"])
        default: text = Self.overview()
        }
        // Process names and volume names come from outside the app.
        return ToolOutput.wrap(text, source: "mac_info: \(topic)")
    }

    static func overview() -> String {
        let info = ProcessInfo.processInfo
        var load = [Double](repeating: 0, count: 3)
        let loaded = getloadavg(&load, 3) == 3
        let uptime = Duration.seconds(info.systemUptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))
        let thermal: String =
            switch info.thermalState {
            case .nominal: "nominal"
            case .fair: "fair"
            case .serious: "serious (throttling)"
            case .critical: "critical"
            @unknown default: "unknown"
            }
        return [
            "Model: \(HardwareProfile.sysctlString("hw.model") ?? "unknown")",
            "Chip: \(HardwareProfile.sysctlString("machdep.cpu.brand_string") ?? "unknown"), \(info.processorCount) cores (\(info.activeProcessorCount) active)",
            "macOS: \(info.operatingSystemVersionString)",
            "Memory: \(bytes(Int64(info.physicalMemory)))",
            "Uptime: \(uptime)",
            loaded ? String(format: "Load average: %.2f %.2f %.2f (1, 5, 15 min)", load[0], load[1], load[2]) : "Load average: unknown",
            "Thermal state: \(thermal)",
            "Low Power Mode: \(info.isLowPowerModeEnabled ? "on" : "off")",
        ].joined(separator: "\n")
    }

    static func storage() -> String {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let lines = volumes.compactMap { url -> String? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let total = values.volumeTotalCapacity, total > 0 else {
                return nil
            }
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            return "\(values.volumeName ?? url.path) (\(url.path)): \(bytes(free)) free of \(bytes(Int64(total)))"
        }
        return lines.isEmpty ? "No volumes found." : lines.joined(separator: "\n")
    }

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

// Network

/// `network_check`: ping, traceroute, DNS, an HTTP request, a TCP port and the speed test macOS ships. Fixed programs, no
/// shell; the host is checked to be a plain name or address. Local and private addresses need the user's approval.
public struct NetworkToolProvider: ToolProvider {
    public var confirmation: (any ToolConfirmation)?

    public init(confirmation: (any ToolConfirmation)? = nil) { self.confirmation = confirmation }

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "network_check",
                description:
                    "Measure the network from this Mac: ping (4 packets), traceroute (route, up to 20 hops), dns (addresses of a name), http (status, redirects and headers of a site), port (is a TCP port open), speed (internet speed test, about 20 s; no host). Report the measured numbers.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"action":{"type":"string","enum":["ping","traceroute","dns","http","port","speed"]},"host":{"type":"string","description":"Domain name or IP address, e.g. ya.ru; for http a URL is accepted too"},"port":{"type":"integer","description":"TCP port for the port action"}},"required":["action"]}"#
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        let action = args.string("action") ?? ""
        if action == "speed" {
            return ToolOutput.wrap(
                try await ToolProcess.run("/usr/bin/networkQuality", [], timeout: 60), source: "network_check: speed")
        }
        var raw = (args.string("host") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "http", let url = URL(string: raw), let host = url.host() { raw = host }
        guard let host = Self.validHost(raw) else { return "error: host must be a domain name or an IP address" }
        if host.contains(":") { return "error: IPv6 addresses are not supported" }
        if Self.isLocal(host), let confirmation {
            let allowed = await confirmation.confirm(
                title: String(localized: "Check a local address?"), detail: "\(action) \(host)")
            guard allowed else { return "error: the user declined checking a local address" }
        }
        let text: String
        switch action {
        case "ping":
            text = try await ToolProcess.run("/sbin/ping", ["-c", "4", host], timeout: 20)
        case "traceroute":
            text = try await ToolProcess.run("/usr/sbin/traceroute", ["-m", "20", "-q", "1", "-w", "2", host], timeout: 60)
        case "dns":
            text = try await ToolProcess.run("/usr/bin/dig", ["+short", "+time=3", "+tries=1", host, "A"], timeout: 15)
        case "port":
            guard let port = args.int("port"), (1...65535).contains(port) else { return "error: port must be 1–65535" }
            text = try await ToolProcess.run("/usr/bin/nc", ["-z", "-v", "-G", "5", "-w", "5", host, String(port)], timeout: 15)
        case "http":
            text = await Self.http(URL(string: args.string("host").flatMap { $0.contains("://") ? $0 : nil } ?? "https://\(host)"))
        default:
            return "error: unknown action \(action)"
        }
        return ToolOutput.wrap(text.isEmpty ? "No output." : text, source: "network_check: \(action) \(host)")
    }

    /// A plain host name or IPv4 address: letters, digits, dots, hyphens; never a leading dash (an option).
    /// Colons survive validation only to be rejected explicitly as unsupported IPv6.
    static func validHost(_ host: String) -> String? {
        let host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"),
            host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-:".contains($0)) })
        else { return nil }
        return host
    }

    /// This Mac, its network and link-local ranges: checking them from a page's suggestion would probe the user's own net.
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".localhost") || h == "::1" { return true }
        if h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") { return h.contains(":") }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (0, _), (192, 168), (169, 254): return true
        case (172, 16...31), (100, 64...127): return true
        default: return false
        }
    }

    /// Status, time, final address after redirects and the headers that describe the server.
    static func http(_ url: URL?) async -> String {
        guard let url, ["http", "https"].contains(url.scheme ?? "") else { return "error: not an http(s) address" }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.setValue(HTTP.appUserAgent, forHTTPHeaderField: "User-Agent")
        let start = ContinuousClock.now
        do {
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let elapsed = start.duration(to: .now)
            guard let http = response as? HTTPURLResponse else { return "error: not an HTTP response" }
            let wanted = ["server", "content-type", "location", "strict-transport-security", "cache-control", "date", "via", "x-cache"]
            let headers = http.allHeaderFields.compactMap { key, value -> String? in
                guard let name = (key as? String)?.lowercased(), wanted.contains(name) else { return nil }
                return "\(name): \(value)"
            }.sorted()
            return
                ([
                    "Status: \(http.statusCode)", "Final URL: \(http.url?.absoluteString ?? url.absoluteString)",
                    "Time: \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))",
                ] + headers)
                .joined(separator: "\n")
        } catch {
            return "error: \(error.localizedDescription)"
        }
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

// System control

/// `mac_control`: the volume, dark or light appearance, and opening an app. Small, undoable changes, so none asks.
public struct MacControlToolProvider: ToolProvider {
    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "mac_control",
                description:
                    "Change this Mac's sound volume (0–100), mute or unmute it, switch dark or light appearance, open an app by name, or report the current volume and appearance.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"action":{"type":"string","enum":["status","volume","mute","unmute","dark_mode","light_mode","open_app"]},"value":{"type":"string","description":"Volume 0–100, or the app's name"}},"required":["action"]}"#
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        guard let action = args.string("action") else { return toolFailure(missing: "action") }
        switch action {
        case "open_app":
            guard let name = args.string("value"), !name.isEmpty else { return toolFailure(missing: "value (the app's name)") }
            return await Self.open(name)
        case "status", "volume", "mute", "unmute", "dark_mode", "light_mode":
            let level = args.double("value").map { Int(min(max($0, 0), 100)) }
            if action == "volume", level == nil { return "error: give the volume as a number from 0 to 100" }
            let change: String
            switch action {
            case "volume": change = "app.setVolume(null, { outputVolume: \(level ?? 50) });"
            case "mute", "unmute": change = "app.setVolume(null, { outputMuted: \(action == "mute") });"
            // Only a change goes through System Events: reading the appearance needs no permission to control it.
            case "dark_mode", "light_mode":
                change = "Application('System Events').appearancePreferences.darkMode = \(action == "dark_mode");"
            default: change = ""
            }
            let out = try await JXA.run(
                """
                const app = Application.currentApplication();
                app.includeStandardAdditions = true;
                \(change)
                const v = app.getVolumeSettings();
                return v.outputVolume + ' ' + v.outputMuted;
                """)
            if out.hasPrefix("ERROR:") { return JXA.failure(out, app: action.hasSuffix("_mode") ? "System Events" : "this Mac") }
            let parts = out.split(separator: " ")
            let dark =
                action == "dark_mode" || (action != "light_mode" && UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
            return "Volume \(parts.first ?? "?") of 100" + (parts.last == "true" ? ", muted" : "") + "; appearance "
                + (dark ? "dark." : "light.")
        default:
            return "error: unknown action \(action)"
        }
    }

    /// An app by the name the user sees, in their language too ("Калькулятор"), found by Spotlight.
    private static func open(_ name: String) async -> String {
        let quoted = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        // The name shown is localized ("Калькулятор"), the bundle's file name is not ("Calculator.app"): either one will do.
        let query =
            "kMDItemContentType == 'com.apple.application-bundle' && (kMDItemDisplayName == '\(quoted)'cd || kMDItemFSName == '\(quoted).app'cd)"
        let found = (try? await ToolProcess.run(URL(fileURLWithPath: "/usr/bin/mdfind"), [query], timeout: 10)) ?? ""
        let path = found.split(separator: "\n").map(String.init).first { $0.hasSuffix(".app") && !$0.contains("/Library/") }
        guard let path else { return "error: there is no app called \"\(name)\" on this Mac" }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
            return "Opened \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)."
        } catch {
            return "error: \(name) did not open (\(error.localizedDescription))"
        }
    }
}

// Music

/// `music_control`: play, pause, the next or previous track, and what is playing, in the Music app.
public struct MusicToolProvider: ToolProvider {
    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "music_control", description: "Control the Music app: play, pause, next or previous track, or say what is playing.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"action":{"type":"string","enum":["now_playing","play","pause","next","previous"]}},"required":["action"]}"#
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let action = ToolArguments(call.argumentsJSON).string("action") ?? "now_playing"
        let command =
            ["play": "m.play();", "pause": "m.pause();", "next": "m.nextTrack();", "previous": "m.previousTrack();"][action] ?? ""
        let out = try await JXA.run(
            """
            const m = Application('Music');
            // Asking what plays must not start Music; only play does.
            if (\(action == "play" ? "false" : "true") && !m.running()) return 'NOT_RUNNING';
            \(command)
            delay(0.3);
            let track = '';
            try { const t = m.currentTrack; track = t.name() + ' — ' + t.artist() + (t.album() ? ' (' + t.album() + ')' : ''); } catch (e) {}
            return m.playerState() + '|' + track;
            """)
        if out == "NOT_RUNNING" { return "Music is not running." }
        if out.hasPrefix("ERROR:") { return JXA.failure(out, app: "Music") }
        let parts = out.split(separator: "|", maxSplits: 1).map(String.init)
        let state = parts.first ?? ""
        let track = parts.count > 1 && !parts[1].isEmpty ? ": " + parts[1] : ""
        return "Music is \(state)\(track)."
    }
}

// Clipboard and screen

enum ScreenAccess {
    /// Asks when the user turns the switch on; macOS then lists Mac-Olama under Screen Recording.
    static func request() { if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() } }
}

/// `clipboard_read`, `clipboard_write` and `screen_read`. The clipboard is read as text, never what a password manager
/// marked as concealed; the screen is read as recognized text, on this Mac, after the user approves each look.
public struct ScreenToolProvider: ToolProvider {
    public var confirmation: (any ToolConfirmation)?
    public var maxCharacters = 12_000

    public init(confirmation: (any ToolConfirmation)?) { self.confirmation = confirmation }

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "clipboard_read", description: "The text the user copied last (the clipboard), or what else it holds.",
                parametersJSONSchema: #"{"type":"object","properties":{}}"#),
            ToolSpec(
                name: "clipboard_write", description: "Put text on the clipboard, for the user to paste.",
                parametersJSONSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#),
            ToolSpec(
                name: "screen_read",
                description:
                    "Read the text on the user's screen right now (recognized on this Mac), with the app in front. The user approves every look.",
                parametersJSONSchema: #"{"type":"object","properties":{}}"#),
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        switch call.name {
        case "clipboard_read":
            return await Self.readClipboard(limit: maxCharacters)
        case "clipboard_write":
            guard let text = ToolArguments(call.argumentsJSON).string("text") else { return toolFailure(missing: "text") }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return "Put \(text.count) characters on the clipboard."
        case "screen_read":
            // macOS asks by itself the first time; after a refusal its privacy pane opens, on every call until allowed.
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                PrivacySettings.ask(.screen)
                return
                    "error: Mac-Olama may not see the screen. A notification now asks the user to allow Mac-Olama in System Settings → Privacy & Security → Screen & System Audio Recording; ask again once they have."
            }
            let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName } ?? "?"
            guard let confirmation else { return "error: reading the screen needs the user's approval" }
            guard await confirmation.confirm(title: String(localized: "Read the text on the screen?"), detail: front) else {
                return "error: the user declined; do not try this another way"
            }
            return try await readScreen(front: front)
        default:
            throw ConversationError.unknownTool(call.name)
        }
    }

    @MainActor
    private static func readClipboard(limit: Int) -> String {
        let board = NSPasteboard.general
        let types = board.types ?? []
        // The marker password managers put on what they copy (nspasteboard.org).
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) {
            return "error: the clipboard holds something a password manager marked as secret; it is not read"
        }
        if let text = board.string(forType: .string), !text.isEmpty {
            return ToolOutput.wrap(text.clipped(to: limit), source: "clipboard")
        }
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            return "The clipboard holds files: " + files.map(\.path).joined(separator: ", ")
        }
        return types.contains(.png) || types.contains(.tiff) ? "The clipboard holds an image, no text." : "The clipboard is empty."
    }

    /// The main display without Mac-Olama's own windows, at its full pixel size, read by Vision.
    private func readScreen(front: String) async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            return "error: no display to read"
        }
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let settings = SCStreamConfiguration()
        settings.width = Int(CGFloat(display.width) * CGFloat(filter.pointPixelScale))
        settings.height = Int(CGFloat(display.height) * CGFloat(filter.pointPixelScale))
        settings.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: settings)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        let lines = try await request.perform(on: image).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return "The screen shows no readable text; \(front) is in front." }
        let text = "In front: \(front)\n\n" + lines.joined(separator: "\n")
        return ToolOutput.wrap(text.clipped(to: maxCharacters), source: "screen_read")
    }
}
