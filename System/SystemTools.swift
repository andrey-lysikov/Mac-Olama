//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import JavaScriptCore

// Tools that answer from this Mac instead of the model's memory: exact calculation, the Mac's own state, network checks.
// Each is read-only, runs fixed programs without a shell and is switched on separately in the Features menu.

/// Tools beyond web search, folders and Shortcuts, each with its own switch in the Features menu (off by default).
public enum ExtraTool: String, CaseIterable, Sendable {
    case calculator, macInfo, network, weather, location
}

// JavaScript

/// `run_javascript`: exact arithmetic, dates and conversions in JavaScriptCore. A bare context has no network, files or
/// timers (no fetch, require, XMLHttpRequest), and a time limit stops runaway loops.
public struct JavaScriptToolProvider: ToolProvider {
    public var timeLimit: TimeInterval = 3
    public var maxCodeCharacters = 8000
    public var maxOutputCharacters = 8000

    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "run_javascript",
                description:
                    "Evaluate JavaScript for exact arithmetic, percentages, statistics, date arithmetic and unit conversions. No network or file access. The value of the last expression is returned; console.log output too.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"code":{"type":"string","description":"JavaScript code, e.g. (1250 * 1.2).toFixed(2)"}},"required":["code"]}"#
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        guard let code = args.string("code"), !code.isEmpty else { return toolFailure(missing: "code") }
        guard code.count <= maxCodeCharacters else { return "error: code longer than \(maxCodeCharacters) characters" }
        let (limit, maxOutput) = (timeLimit, maxOutputCharacters)
        // Its own thread: the evaluation blocks until it ends or the time limit terminates it.
        return await Task.detached { Self.evaluate(code, timeLimit: limit, maxOutput: maxOutput) }.value
    }

    static func evaluate(_ code: String, timeLimit: TimeInterval, maxOutput: Int) -> String {
        guard let group = JSContextGroupCreate() else { return "error: JavaScript is unavailable" }
        defer { JSContextGroupRelease(group) }
        setExecutionTimeLimit?(group, timeLimit, nil, nil)
        guard let ref = JSGlobalContextCreateInGroup(group, nil), let context = JSContext(jsGlobalContextRef: ref) else {
            return "error: JavaScript is unavailable"
        }
        JSGlobalContextRelease(ref)
        let log = LogSink()
        let print: @convention(block) () -> Void = {
            log.append((JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }.joined(separator: " "))
        }
        context.evaluateScript("var console = {};")
        context.objectForKeyedSubscript("console")?.setObject(print, forKeyedSubscript: "log" as NSString)
        let value = context.evaluateScript(code)
        var out = log.lines.joined(separator: "\n")
        if let exception = context.exception {
            out += (out.isEmpty ? "" : "\n") + "error: \(exception.toString() ?? "exception")"
        } else if let value, !value.isUndefined {
            let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value])
            let text = json.flatMap { $0.isUndefined ? nil : $0.toString() } ?? value.toString() ?? ""
            out += (out.isEmpty ? "" : "\n") + "Result: \(text)"
        }
        if out.isEmpty { out = "Done (no result, no output)." }
        return out.clipped(to: maxOutput)
    }

    private typealias SetTimeLimit = @convention(c) (JSContextGroupRef, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void

    /// Exported by JavaScriptCore but not in its public headers; looked up so a missing symbol only drops the time limit.
    private static let setExecutionTimeLimit: SetTimeLimit? = {
        guard let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_LAZY),
            let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit")
        else { return nil }
        return unsafeBitCast(symbol, to: SetTimeLimit.self)
    }()

    private final class LogSink: @unchecked Sendable {
        var lines: [String] = []
        func append(_ line: String) { if lines.count < 500 { lines.append(line) } }
    }
}

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
        request.setValue("Mac-Olama/0.1", forHTTPHeaderField: "User-Agent")
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
