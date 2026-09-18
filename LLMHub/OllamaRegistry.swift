//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// Ollama registry as a second model source. Only `*-mlx*` tags are usable: they store safetensors, one tensor per blob,
// plus config/tokenizer JSON layers. Weights quantized by modelopt (hf_quant_config.json) may not load in mlx-swift-lm (V19).

// References

/// Where a model comes from and how to address it there.
public enum ModelReference: Sendable, Hashable {
    case huggingFace(repoID: String)
    case ollama(name: String, tag: String)

    public var source: ModelSource {
        switch self {
        case .huggingFace: .huggingFace;
        case .ollama: .ollama
        }
    }

    /// Stored in `ModelManifest.repoID`: `org/repo` or `name:tag`.
    public var repoID: String {
        switch self {
        case .huggingFace(let id): id
        case .ollama(let name, let tag): "\(name):\(tag)"
        }
    }

    public var directoryName: String {
        switch self {
        case .huggingFace(let id): ModelDescriptor.directoryName(forRepo: id)
        case .ollama(let name, let tag): "ollama--\(name)--\(tag)".replacingOccurrences(of: "/", with: "--")
        }
    }

    /// `org/repo`, HF URLs → Hugging Face; `name:tag` (tag containing "mlx") or `ollama.com/library/name:tag` → Ollama.
    public static func parse(_ input: String) -> ModelReference? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "ollama.com/library/") {
            let rest = String(s[range.upperBound...]).split(separator: "/").first.map(String.init) ?? ""
            return parseOllama(rest)
        }
        if s.contains("huggingface.co") || (s.contains("/") && !s.contains(":")) {
            return HubClient.parseRepoID(s).map { .huggingFace(repoID: $0) }
        }
        return parseOllama(s)
    }

    static func parseOllama(_ s: String) -> ModelReference? {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return .ollama(name: parts[0], tag: parts[1])
    }

    /// Reconstructs a reference from a manifest (`source` + `repoID`).
    public init(manifest: ModelManifest) {
        switch manifest.source ?? .huggingFace {
        case .huggingFace: self = .huggingFace(repoID: manifest.repoID)
        case .ollama: self = ModelReference.parseOllama(manifest.repoID) ?? .huggingFace(repoID: manifest.repoID)
        }
    }
}

// Registry types

public struct OllamaLibraryEntry: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
}

public struct OllamaTag: Sendable, Hashable, Identifiable {
    public var id: String { tag }
    public var tag: String
    public var sizeText: String
    public var isMLX: Bool
    public var sizeBytes: Int64? {
        let t = sizeText.uppercased()
        guard let n = Double(t.replacingOccurrences(of: "GB", with: "").replacingOccurrences(of: "MB", with: "")) else { return nil }
        return Int64(n * (t.hasSuffix("GB") ? 1e9 : 1e6))
    }
}

public struct OllamaManifest: Sendable, Decodable {
    public struct Layer: Sendable, Decodable, Hashable {
        public var mediaType: String
        public var size: Int64
        public var digest: String
        public var name: String?
        public var isTensor: Bool { mediaType == "application/vnd.ollama.image.tensor" }
        public var isJSON: Bool { mediaType == "application/vnd.ollama.image.json" }
    }
    public var layers: [Layer]
    public var config: Layer
    /// Registry digest of the manifest itself (from `Docker-Content-Digest`); used for update checks.
    public var digest: String = ""

    enum CodingKeys: String, CodingKey { case layers, config }

    public var tensorLayers: [Layer] { layers.filter(\.isTensor) }
    public var jsonLayers: [Layer] { layers.filter(\.isJSON) }
    public var totalBytes: Int64 { layers.reduce(0) { $0 + $1.size } }
    /// True when the tag stores safetensors tensors (an MLX-style tag), false for GGUF.
    public var isSafetensors: Bool { !tensorLayers.isEmpty && jsonLayers.contains { $0.name == "config.json" } }
}

// Client

/// ollama.com has no public search API: search and tag lists are scraped from HTML; manifests/blobs come from the registry.
public struct OllamaRegistryClient: Sendable {
    public let registryURL: URL
    public let siteURL: URL
    let http: any HubHTTPClient

    public init(
        registryURL: URL = URL(string: "https://registry.ollama.ai")!, siteURL: URL = URL(string: "https://ollama.com")!,
        http: any HubHTTPClient = URLSessionHubHTTPClient()
    ) {
        self.registryURL = registryURL
        self.siteURL = siteURL
        self.http = http
    }

    static func namespaced(_ name: String) -> String { name.contains("/") ? name : "library/\(name)" }

    public func manifestURL(name: String, tag: String) -> URL {
        registryURL.appendingPathComponent("v2/\(Self.namespaced(name))/manifests/\(tag)")
    }

    public func blobURL(name: String, digest: String) -> URL {
        registryURL.appendingPathComponent("v2/\(Self.namespaced(name))/blobs/\(digest)")
    }

    func get(_ url: URL, accept: String) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("Mac-Olama/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.data(for: r)
        switch response.statusCode {
        case 200: return (data, response)
        case 404: throw HubError.notFound(url.path)
        default: throw HubError.httpStatus(response.statusCode, url: url.absoluteString)
        }
    }

    public func manifest(name: String, tag: String) async throws -> OllamaManifest {
        let (data, response) = try await get(
            manifestURL(name: name, tag: tag), accept: "application/vnd.docker.distribution.manifest.v2+json")
        var m = try JSONDecoder().decode(OllamaManifest.self, from: data)
        m.digest =
            response.value(forHTTPHeaderField: "Docker-Content-Digest") ?? "sha256:" + SHA256Hasher.hex(of: data)
        return m
    }

    public func search(_ query: String) async throws -> [OllamaLibraryEntry] {
        var c = URLComponents(url: siteURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, _) = try await get(c.url!, accept: "text/html")
        return Self.parseSearch(html: String(decoding: data, as: UTF8.self))
    }

    public func tags(name: String) async throws -> [OllamaTag] {
        let (data, _) = try await get(siteURL.appendingPathComponent("library/\(name)/tags"), accept: "text/html")
        return Self.parseTags(html: String(decoding: data, as: UTF8.self), name: name)
    }

    /// Links `/library/<name>` in search results; the description is the first `<p>` inside the link block.
    static func parseSearch(html: String) -> [OllamaLibraryEntry] {
        guard let linkRE = try? NSRegularExpression(pattern: #"href="/library/([a-z0-9._\-/]+)""#),
            let pRE = try? NSRegularExpression(pattern: #"<p[^>]*>([\s\S]*?)</p>"#)
        else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        var out: [OllamaLibraryEntry] = []
        for m in linkRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            guard !name.contains(":"), !seen.contains(name) else { continue }
            seen.insert(name)
            let window = NSRange(location: m.range.location, length: min(3000, ns.length - m.range.location))
            var description = ""
            if let pm = pRE.firstMatch(in: html, range: window) {
                description = ns.substring(with: pm.range(at: 1))
                    .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            out.append(OllamaLibraryEntry(name: name, description: String(description.prefix(160))))
        }
        return out
    }

    /// Tag rows: `<a href="/library/<name>:<tag>">` followed by "MLX 7.7GB …" or "GGUF 8.1GB …".
    static func parseTags(html: String, name: String) -> [OllamaTag] {
        let text = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var seen = Set<String>()
        var out: [OllamaTag] = []
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let re = try? NSRegularExpression(pattern: "\(escaped):([A-Za-z0-9._\\-]+) (MLX|GGUF|Safetensors)? ?([0-9.]+[GM]B)") else {
            return []
        }
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let tr = Range(m.range(at: 1), in: text), let sr = Range(m.range(at: 3), in: text) else { continue }
            let tag = String(text[tr])
            guard !seen.contains(tag) else { continue }
            seen.insert(tag)
            let format = Range(m.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            out.append(OllamaTag(tag: tag, sizeText: String(text[sr]), isMLX: format == "MLX" || tag.contains("mlx")))
        }
        return out
    }
}

// Safetensors assembly

/// Quantization scheme of an Ollama MLX blob (`__metadata__.quant_type`), mapped to MLX's `quantization` config.
/// Values follow ollama/mlx/quant/quant.go: nvfp4 g16, mxfp4 g32, mxfp8 g32, int4/int8 g64 affine.
public struct OllamaQuantScheme: Sendable, Equatable, Codable {
    public var quantType: String
    public var groupSize: Int
    public var bits: Int
    public var mode: String
    /// nvfp4 carries a per-tensor `global_scale` that mlx-swift's QuantizedLinear cannot apply → convert on first load.
    public var needsConversion: Bool { mode == "nvfp4" }

    public init?(quantType: String) {
        switch quantType.lowercased() {
        case "nvfp4": self.init(quantType: quantType, groupSize: 16, bits: 4, mode: "nvfp4")
        case "mxfp4": self.init(quantType: quantType, groupSize: 32, bits: 4, mode: "mxfp4")
        case "mxfp8": self.init(quantType: quantType, groupSize: 32, bits: 8, mode: "mxfp8")
        case "int4": self.init(quantType: quantType, groupSize: 64, bits: 4, mode: "affine")
        case "int8": self.init(quantType: quantType, groupSize: 64, bits: 8, mode: "affine")
        default: return nil
        }
    }

    init(quantType: String, groupSize: Int, bits: Int, mode: String) {
        self.quantType = quantType
        self.groupSize = groupSize
        self.bits = bits
        self.mode = mode
    }

    /// Marker file written next to config.json when weights must be re-quantized before MLX can load them.
    public static let conversionMarker = "conversion.json"
}

/// Merges Ollama tensor blobs (each a small safetensors file, possibly with scale/global_scale companions) into shards.
/// Renames MLX-runner names to mlx-swift-lm names: `X.weight.scale` → `X.scales`, `X.weight.global_scale` → `X.global_scale`.
public enum SafetensorsMerger {
    public struct Entry: Sendable {
        public var name: String
        public var dtype: String
        public var shape: [Int]
        public var data: Data
    }

    public struct Parsed: Sendable {
        public var entries: [Entry]
        public var quantType: String?
    }

    /// Parses a safetensors blob with one or more tensors; `__metadata__.quant_type` is surfaced when present.
    public static func parse(_ blob: Data, fallbackName: String) throws -> Parsed {
        guard blob.count >= 8 else { throw HubError.checksumMismatch(file: fallbackName) }
        let headerLength = Int(blob.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian)
        guard blob.count >= 8 + headerLength,
            let header = try JSONSerialization.jsonObject(with: blob.subdata(in: 8..<(8 + headerLength))) as? [String: Any]
        else {
            throw HubError.checksumMismatch(file: fallbackName)
        }
        let base = 8 + headerLength
        var entries: [Entry] = []
        for (name, meta) in header where name != "__metadata__" {
            guard let dict = meta as? [String: Any], let dtype = dict["dtype"] as? String, let shape = dict["shape"] as? [Int],
                let offsets = dict["data_offsets"] as? [Int], offsets.count == 2, base + offsets[1] <= blob.count
            else {
                throw HubError.checksumMismatch(file: fallbackName)
            }
            entries.append(
                Entry(name: rename(name), dtype: dtype, shape: shape, data: blob.subdata(in: (base + offsets[0])..<(base + offsets[1]))))
        }
        entries.sort { $0.name < $1.name }
        let quantType = (header["__metadata__"] as? [String: Any])?["quant_type"] as? String
        return Parsed(entries: entries, quantType: quantType)
    }

    static func rename(_ name: String) -> String {
        if name.hasSuffix(".weight.scale") { return String(name.dropLast(".weight.scale".count)) + ".scales" }
        if name.hasSuffix(".weight.global_scale") { return String(name.dropLast(".weight.global_scale".count)) + ".global_scale" }
        return name
    }

    /// Writes one safetensors file from entries (caller shards to keep files under a few GB).
    public static func write(_ entries: [Entry], to url: URL) throws {
        var header: [String: Any] = ["__metadata__": ["format": "mlx", "producer": "Mac-Olama"]]
        var offset = 0
        for e in entries {
            header[e.name] = ["dtype": e.dtype, "shape": e.shape, "data_offsets": [offset, offset + e.data.count]]
            offset += e.data.count
        }
        var headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while headerData.count % 8 != 0 { headerData.append(0x20) }  // pad to 8 bytes like the reference implementation
        var out = Data()
        var length = UInt64(headerData.count).littleEndian
        out.append(Data(bytes: &length, count: 8))
        out.append(headerData)
        for e in entries { out.append(e.data) }
        try out.write(to: url, options: .atomic)
    }

    /// Adds MLX `quantization` block to config.json so mlx-swift-lm quantizes matching layers on load.
    public static func patchConfig(at url: URL, scheme: OllamaQuantScheme) throws {
        guard var config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { return }
        config["quantization"] = ["group_size": scheme.groupSize, "bits": scheme.bits, "mode": scheme.mode]
        config["quantization_config"] = nil
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

// Streaming writer

/// Writes a safetensors file one tensor at a time: data goes to a temp file, the header is composed at `finish()`.
/// Peak memory is one tensor, which keeps NVFP4 → affine conversion of multi-GB shards within reach of 16 GB Macs.
public final class SafetensorsStreamWriter {
    private let destination: URL
    private let dataURL: URL
    private let handle: FileHandle
    private var header: [String: Any] = ["__metadata__": ["format": "mlx", "producer": "Mac-Olama"]]
    private var offset = 0

    public init(destination: URL) throws {
        self.destination = destination
        dataURL = destination.appendingPathExtension("data.part")
        FileManager.default.createFile(atPath: dataURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: dataURL)
    }

    public func append(name: String, dtype: String, shape: [Int], data: Data) throws {
        try handle.write(contentsOf: data)
        header[name] = ["dtype": dtype, "shape": shape, "data_offsets": [offset, offset + data.count]]
        offset += data.count
    }

    /// Composes header + data into `destination` (streams the data file in 8 MB chunks) and removes the temp file.
    public func finish() throws {
        try handle.close()
        var headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while headerData.count % 8 != 0 { headerData.append(0x20) }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var length = UInt64(headerData.count).littleEndian
        try out.write(contentsOf: Data(bytes: &length, count: 8))
        try out.write(contentsOf: headerData)
        let input = try FileHandle(forReadingFrom: dataURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try FileManager.default.removeItem(at: dataURL)
    }

    public func cancel() {
        try? handle.close()
        try? FileManager.default.removeItem(at: dataURL)
    }
}
