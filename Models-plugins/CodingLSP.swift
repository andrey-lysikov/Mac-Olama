//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

public enum CodingLSPError: LocalizedError {
    case startFailed
    case timeout
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .startFailed: "The language server could not be started."
        case .timeout: "The language server request timed out."
        case .server(let message): "Language server error: \(message)"
        }
    }
}

public actor CodingLSPSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var incoming = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var publishedDiagnostics: [String: Data] = [:]
    private var started = false

    init() {}

    func start(binary: URL, arguments: [String], root: URL) async throws {
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receive(data) }
        }
        do { try process.run() } catch { throw CodingLSPError.startFailed }
        started = true
        let rootURI = root.absoluteString
        _ = try await request(
            method: "initialize",
            params: [
                "processId": ProcessInfo.processInfo.processIdentifier,
                "rootUri": rootURI,
                "workspaceFolders": [["uri": rootURI, "name": root.lastPathComponent]],
                "capabilities": [
                    "textDocument": [
                        "definition": [:],
                        "references": [:],
                        "publishDiagnostics": [:],
                        "diagnostic": [:],
                    ],
                ],
            ])
        try await notify(method: "initialized", params: [:])
    }

    func open(_ file: URL, text: String, language: String) async throws {
        try await notify(
            method: "textDocument/didOpen",
            params: [
                "textDocument": [
                    "uri": file.absoluteString,
                    "languageId": language,
                    "version": 1,
                    "text": text,
                ],
            ])
    }

    func definition(file: URL, line: Int, character: Int) async throws -> Data {
        try await request(method: "textDocument/definition", params: Self.position(file: file, line: line, character: character))
    }

    func references(file: URL, line: Int, character: Int) async throws -> Data {
        var params = Self.position(file: file, line: line, character: character)
        params["context"] = ["includeDeclaration": true]
        return try await request(method: "textDocument/references", params: params)
    }

    func diagnostics(file: URL) async throws -> Data {
        do {
            return try await request(method: "textDocument/diagnostic", params: ["textDocument": ["uri": file.absoluteString]])
        } catch {
            if let stored = publishedDiagnostics[file.absoluteString] { return stored }
            try? await Task.sleep(for: .milliseconds(500))
            if let stored = publishedDiagnostics[file.absoluteString] { return stored }
            throw error
        }
    }

    func close() async {
        guard started else { return }
        _ = try? await request(method: "shutdown", params: nil)
        try? await notify(method: "exit", params: nil)
        if process.isRunning { process.terminate() }
        started = false
    }

    private static func position(file: URL, line: Int, character: Int) -> [String: Any] {
        [
            "textDocument": ["uri": file.absoluteString],
            "position": ["line": line - 1, "character": character - 1],
        ]
    }

    private func request(method: String, params: [String: Any]?) async throws -> Data {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params ?? [:]])
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                if let pending = self.pending.removeValue(forKey: id) {
                    pending.resume(throwing: CodingLSPError.timeout)
                }
            }
        }
    }

    private func notify(method: String, params: [String: Any]?) async throws {
        try write(["jsonrpc": "2.0", "method": method, "params": params ?? [:]])
    }

    private func write(_ object: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: object)
        let header = "Content-Length: \(body.count)\r\n\r\n"
        let data = Data(header.utf8) + body
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        incoming.append(data)
        while true {
            guard let headerEnd = incoming.range(of: Data("\r\n\r\n".utf8)) else { return }
            let header = String(decoding: incoming[..<headerEnd.lowerBound], as: UTF8.self)
            guard let lengthLine = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
            else { incoming.removeAll(); return }
            let bodyStart = headerEnd.upperBound
            let bodyEnd = bodyStart + length
            guard incoming.count >= bodyEnd else { return }
            let body = incoming[bodyStart..<bodyEnd]
            incoming.removeSubrange(..<bodyEnd)
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                if let error = object["error"] as? [String: Any] {
                    continuation.resume(throwing: CodingLSPError.server(String(describing: error)))
                } else if let result = object["result"], !(result is NSNull),
                    let data = try? JSONSerialization.data(withJSONObject: result)
                {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: Data("null".utf8))
                }
            } else if object["method"] as? String == "textDocument/publishDiagnostics", let params = object["params"] as? [String: Any],
                let uri = params["uri"] as? String, let data = try? JSONSerialization.data(withJSONObject: params)
            {
                publishedDiagnostics[uri] = data
            }
        }
    }
}
