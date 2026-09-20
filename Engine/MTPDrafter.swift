//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM
import os

/// Multi-token prediction: a checkpoint that ships MTP heads drafts several tokens per round and the model verifies
/// them in one pass — the same answer as plain decoding, fewer model calls. The heads sit in the model's own weight
/// files, so the drafter loads from that folder and needs no second download.
enum MTPDrafter {
    private static let logger = Logger(subsystem: "com.macolama.app", category: "mtp")

    /// The library keeps drafter types in the registry its factory reads, and every family registers its own types.
    /// Calling each registration is that API; which drafter is built is decided by the checkpoint, not by a list here.
    private static let registration = Task {
        await Qwen35TextMTPRegistration.register()
        await Qwen35VLMMTPRegistration.register()
        await Gemma4AssistantRegistration.register()
    }

    /// Where a paired drafter repository is installed: a folder inside the model's own folder, so it is deleted with
    /// the model and never shows up as a model of its own.
    static let folderName = "drafter"

    static func directory(forModel directory: URL) -> URL { directory.appending(path: folderName) }

    static func isInstalled(forModel directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: self.directory(forModel: directory).appending(path: "config.json").path)
    }

    /// The drafter for an installed model: the paired repository when one is attached, otherwise the heads inside the
    /// checkpoint itself. Nil when there are none. Never throws: speculation is an optimization, and the model has to
    /// work without it.
    static func load(modelDirectory: URL) async -> (any MTPDrafterModel)? {
        if isInstalled(forModel: modelDirectory) { return await build(from: directory(forModel: modelDirectory)) }
        let config = (try? Data(contentsOf: modelDirectory.appending(path: "config.json"))) ?? Data()
        guard declaresHeads(config), carriesHeadWeights(in: modelDirectory) else { return nil }
        return await build(from: modelDirectory)
    }

    /// Builds the drafter from a folder holding its config and weights; also the check that a freshly downloaded
    /// repository really is a drafter this engine can use.
    static func build(from directory: URL) async -> (any MTPDrafterModel)? {
        guard let config = try? Data(contentsOf: directory.appending(path: "config.json")) else { return nil }
        await registration.value
        do {
            let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: config)
            let model = try await MTPDrafterTypeRegistry.shared.createModel(configuration: config, modelType: base.modelType)
            try await loadWeights(modelDirectory: directory, model: model, perLayerQuantization: base.perLayerQuantization)
            return model
        } catch {
            let folder = directory.lastPathComponent
            logger.info("no MTP drafter in \(folder, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether this model could speculate at all: its own config announces prediction heads, so a drafter published
    /// for this checkpoint fits it. Models without them never show the switch.
    static func declaresHeads(inModel directory: URL) -> Bool {
        guard let config = try? Data(contentsOf: directory.appending(path: "config.json")) else { return false }
        return declaresHeads(config)
    }

    /// True when the config announces prediction heads. The key is found by name (`mtp_num_hidden_layers`,
    /// `num_nextn_predict_layers`), nested sections included, so no model or architecture names are kept here.
    static func declaresHeads(_ configJSON: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: configJSON) else { return false }
        return declaresHeads(in: root)
    }

    private static func declaresHeads(in value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, nested) in object {
                let name = key.lowercased()
                if name.contains("mtp") || name.contains("nextn"), let count = positiveCount(nested), count > 0 { return true }
                if declaresHeads(in: nested) { return true }
            }
        }
        if let array = value as? [Any] { return array.contains { declaresHeads(in: $0) } }
        return false
    }

    /// `mtp_use_dedicated_embeddings: true` is not a layer count: a JSON boolean bridges to `NSNumber` too.
    private static func positiveCount(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue > 0 else { return nil }
        return number.intValue
    }

    /// Whether the weights really hold the heads: MLX builds routinely drop them while keeping the config keys, and a
    /// drafter without weights either fails to load or drafts noise. The index names every tensor; without one the
    /// safetensors headers are read (8-byte little-endian length, then JSON with the tensor names).
    static func carriesHeadWeights(in directory: URL) -> Bool {
        tensorNames(inModelAt: directory).contains(where: isHeadTensor)
    }

    /// A folder holding only prediction heads: a drafter repository someone downloaded as if it were a model. It has
    /// no token embeddings and no output head, which every chat model has, so it cannot answer anything on its own.
    static func isDrafterOnly(directory: URL) -> Bool {
        let config = (try? Data(contentsOf: directory.appending(path: "config.json"))) ?? Data()
        return isDrafterOnly(tensorNames: tensorNames(inModelAt: directory), config: config)
    }

    /// The same judgement for a repository that is not downloaded yet: its config and the names of its tensors.
    static func isDrafterOnly(tensorNames names: [String], config: Data) -> Bool {
        guard !names.isEmpty, declaresHeads(config) else { return false }
        return !names.contains { $0.contains("embed_tokens") || $0.contains("lm_head") }
    }

    /// Tensor names listed by a safetensors index (`weight_map`) or by a safetensors header.
    static func tensorNames(indexJSON: Data) -> [String] {
        guard let map = (try? JSONSerialization.jsonObject(with: indexJSON) as? [String: Any])?["weight_map"] as? [String: Any]
        else { return [] }
        return Array(map.keys)
    }

    static func tensorNames(safetensorsHead data: Data) -> [String] {
        guard data.count > 8 else { return [] }
        let length = data.prefix(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }  // little-endian
        guard length > 0, Int(length) + 8 <= data.count else { return [] }
        let header = data.dropFirst(8).prefix(Int(length))
        return Array(((try? JSONSerialization.jsonObject(with: header)) as? [String: Any])?.keys ?? [:].keys)
    }

    /// Hidden size from a config, nested text section included: a drafter fits a model only if they match.
    static func hiddenSize(_ configJSON: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: configJSON) as? [String: Any] else { return nil }
        let text = root["text_config"] as? [String: Any] ?? root
        return (text["hidden_size"] as? NSNumber)?.intValue ?? (root["hidden_size"] as? NSNumber)?.intValue
    }

    static func hiddenSize(inModel directory: URL) -> Int? {
        guard let config = try? Data(contentsOf: directory.appending(path: "config.json")) else { return nil }
        return hiddenSize(config)
    }

    /// Every tensor name of a checkpoint, from the index when there is one, otherwise from the safetensors headers.
    private static func tensorNames(inModelAt directory: URL) -> [String] {
        let index = directory.appending(path: "model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
            let map = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["weight_map"] as? [String: Any]
        {
            return Array(map.keys)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "safetensors" }.flatMap { tensorNames(in: $0) }
    }

    private static func isHeadTensor(_ name: String) -> Bool {
        name.split(separator: ".").contains { $0 == "mtp" || $0.hasPrefix("nextn") }
    }

    private static func tensorNames(in file: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.read(upToCount: 8), size.count == 8 else { return [] }
        let length = size.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }  // little-endian
        guard length > 0, length < 64 << 20, let header = try? handle.read(upToCount: Int(length)) else { return [] }
        let json = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any]
        return Array(json?.keys ?? [:].keys)
    }
}
