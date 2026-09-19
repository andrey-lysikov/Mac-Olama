//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX

// Ollama `*-mlx` tags ship NVFP4 weights with a `global_scale` that MLXNN's QuantizedLinear cannot use, so on first
// load they are re-quantized once to affine 4-bit/g64, the format mlx-community publishes.

public enum OllamaImportError: Error {
    case missingScheme
    case unsupportedDType(String)
}

public enum OllamaImportConverter {
    /// True when the model folder still carries the conversion marker written by `ModelDownloader`.
    public static func needsConversion(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(OllamaQuantScheme.conversionMarker).path)
    }

    /// Rewrites every shard tensor by tensor (safetensors loads lazily; only the current tensor is materialised):
    /// NVFP4 (weight/scales/global_scale) → affine 4-bit (weight/scales/biases). `progress` is 0...1 over tensors.
    public static func convert(directory: URL, progress: @Sendable (Double) -> Void) throws {
        let markerURL = directory.appendingPathComponent(OllamaQuantScheme.conversionMarker)
        let scheme = try JSONCoding.decoder.decode(OllamaQuantScheme.self, from: Data(contentsOf: markerURL))
        guard let sourceMode = QuantizationMode(rawValue: scheme.mode) else { throw OllamaImportError.missingScheme }
        let targetGroup = 64
        let targetBits = 4

        let shards = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let totalTensors = try shards.reduce(0) { $0 + (try loadArrays(url: $1).count) }
        var done = 0

        for shard in shards {
            let arrays = try loadArrays(url: shard)  // lazy: nothing is read until evaluated
            let converted = shard.deletingPathExtension().appendingPathExtension("converted.safetensors")
            let writer = try SafetensorsStreamWriter(destination: converted)
            do {
                for name in arrays.keys.sorted() {
                    guard let array = arrays[name] else { continue }
                    if name.hasSuffix(".global_scale") { done += 1; continue }
                    if name.hasSuffix(".weight"), let scales = arrays[String(name.dropLast(".weight".count)) + ".scales"] {
                        let base = String(name.dropLast(".weight".count))
                        let full = dequantized(
                            array, scales: scales, biases: nil, groupSize: scheme.groupSize, bits: scheme.bits,
                            mode: sourceMode, globalScale: arrays[base + ".global_scale"])
                        let (wq, s, b) = quantized(full, groupSize: targetGroup, bits: targetBits, mode: .affine)
                        eval(wq, s, b ?? s)
                        try writer.append(name: name, dtype: try dtypeName(wq.dtype), shape: wq.shape, data: wq.asData(access: .copy).data)
                        try writer.append(
                            name: base + ".scales", dtype: try dtypeName(s.dtype), shape: s.shape, data: s.asData(access: .copy).data)
                        if let b {
                            try writer.append(
                                name: base + ".biases", dtype: try dtypeName(b.dtype), shape: b.shape, data: b.asData(access: .copy).data)
                        }
                    } else if name.hasSuffix(".scales"), arrays[String(name.dropLast(".scales".count)) + ".weight"] != nil {
                        // written together with its weight above
                    } else {
                        eval(array)
                        try writer.append(
                            name: name, dtype: try dtypeName(array.dtype), shape: array.shape, data: array.asData(access: .copy).data)
                    }
                    done += 1
                    progress(Double(done) / Double(max(1, totalTensors)))
                    if done % 16 == 0 { Memory.clearCache() }
                }
                try writer.finish()
            } catch {
                writer.cancel()
                throw error
            }
            _ = try FileManager.default.replaceItemAt(shard, withItemAt: converted)
            Memory.clearCache()
        }

        try SafetensorsMerger.patchConfig(
            at: directory.appendingPathComponent("config.json"),
            scheme: OllamaQuantScheme(quantType: "int4") ?? scheme)
        try FileManager.default.removeItem(at: markerURL)
        if var manifest = try? ModelManifest.load(from: directory) {
            manifest.quantization = "4-bit affine (converted from \(scheme.quantType))"
            manifest.files = manifest.files.map { entry in
                var e = entry
                if e.path.hasSuffix(".safetensors"),
                    let size = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(e.path).path)[.size]
                        as? NSNumber
                {
                    e.sizeBytes = size.int64Value
                    e.sha256 = nil
                }
                return e
            }
            try? manifest.save(to: directory)
        }
    }

    /// safetensors dtype names for the types produced by quantization and pass-through tensors.
    static func dtypeName(_ dtype: DType) throws -> String {
        switch dtype {
        case .uint32: "U32"
        case .uint8: "U8"
        case .float32: "F32"
        case .float16: "F16"
        case .bfloat16: "BF16"
        case .int32: "I32"
        case .int64: "I64"
        case .bool: "BOOL"
        default: throw OllamaImportError.unsupportedDType("\(dtype)")
        }
    }
}
