//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM
import os

/// Multi-token prediction: a drafter proposes several tokens per round and the model verifies them in one pass — the
/// same answer as plain decoding, fewer model calls. Drafters come in two shapes, so nothing here guesses from names
/// or tensors: the library's own registries decide. Qwen ships prediction heads (`qwen3_5_mtp`), Gemma ships a small
/// assistant model (`gemma4_unified_assistant`), and a checkpoint may also carry its heads inside its own weights.
enum MTPDrafter {
    static let logger = Logger(subsystem: "ru.lysnet.macolama", category: "mtp")

    /// Every family registers its drafter types with the library; this runs once and is awaited before any question.
    private static let registration = Task {
        await Qwen35TextMTPRegistration.register()
        await Qwen35VLMMTPRegistration.register()
        await Gemma4AssistantRegistration.register()
    }

    /// Where a paired drafter is installed: inside the model's own folder, so it is deleted with the model and never
    /// appears as a model of its own.
    static let folderName = "drafter"

    static func directory(forModel directory: URL) -> URL { directory.appending(path: folderName) }

    static func isInstalled(forModel directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: self.directory(forModel: directory).appending(path: "config.json").path)
    }

    // What counts as a drafter

    /// An architecture only a drafter uses: the drafter registry knows it and neither model factory does. `qwen3_5`
    /// sits in both registries — it is a chat model that can also be read as a drafter — so it is not one by itself.
    static func isDrafterType(_ modelType: String) async -> Bool {
        await registration.value
        guard await MTPDrafterTypeRegistry.shared.contains(modelType) else { return false }
        let llm = await LLMModelFactory.shared.typeRegistry.contains(modelType)
        let vlm = await VLMModelFactory.shared.typeRegistry.contains(modelType)
        return !(llm || vlm)
    }

    static func modelType(inConfig config: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: config) as? [String: Any])?["model_type"] as? String
    }

    /// Whether a folder holds a drafter rather than a chat model.
    static func isDrafter(directory: URL) async -> Bool {
        guard let config = try? Data(contentsOf: directory.appending(path: "config.json")), let type = modelType(inConfig: config)
        else { return false }
        return await isDrafterType(type)
    }

    // Loading

    /// The drafter for an installed model: the paired repository when one is attached, otherwise the heads inside the
    /// checkpoint itself. Nil when there are none — speculation is an optimization and the model works without it.
    static func load(modelDirectory: URL) async -> (any MTPDrafterModel)? {
        let name = modelDirectory.lastPathComponent
        if isInstalled(forModel: modelDirectory) {
            logger.info("\(name, privacy: .public): loading the paired drafter")
            return await build(from: directory(forModel: modelDirectory), target: modelDirectory)
        }
        let config = (try? Data(contentsOf: modelDirectory.appending(path: "config.json"))) ?? Data()
        guard declaresHeads(config) else {
            logger.info("\(name, privacy: .public): no drafter, the config declares no prediction heads")
            return nil
        }
        guard carriesHeadWeights(in: modelDirectory) else {
            // The usual case for MLX conversions: the config keeps the keys, the heads themselves were dropped.
            logger.info("\(name, privacy: .public): no drafter, the config declares heads but the weights hold none")
            return nil
        }
        logger.info("\(name, privacy: .public): loading the heads inside the checkpoint")
        return await build(from: modelDirectory, target: modelDirectory)
    }

    /// What a built drafter demands of the request, for the rest of the app: MLX types stay inside `Engine/`.
    struct Traits: Sendable {
        /// The library drops speculation at any temperature but 0 for such a drafter (Qwen's prediction heads).
        var needsGreedy: Bool
    }

    /// Builds the drafter once to see whether it works and what it needs; used when a drafter is installed.
    static func inspect(folder: URL, target: URL) async -> Traits? {
        guard let model = await build(from: folder, target: target) else { return nil }
        return Traits(needsGreedy: model.requiresGreedySampling)
    }

    /// Builds the drafter from a folder holding its config and weights; also the check that a freshly downloaded
    /// repository really is a drafter this engine can use.
    static func build(from directory: URL, target: URL) async -> (any MTPDrafterModel)? {
        let name = directory.lastPathComponent
        guard let own = try? Data(contentsOf: directory.appending(path: "config.json")) else {
            logger.error("\(name, privacy: .public): no config.json in the folder")
            return nil
        }
        let vision = targetVision(at: target)
        let sees = !vision.isEmpty
        let config = aligned(own, withTargetVision: vision)
        await registration.value
        do {
            let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: config)
            let model = try await MTPDrafterTypeRegistry.shared.createModel(configuration: config, modelType: base.modelType)
            // A text drafter paired with a vision model does not fail, it stops the process from inside the library.
            guard String(reflecting: type(of: model)).hasPrefix("MLXVLM") == sees else {
                logger.error("\(name, privacy: .public): drafter built for the other kind of target, not using it")
                return nil
            }
            alignTensorNames(in: directory, to: model)
            try await loadWeights(modelDirectory: directory, model: model, perLayerQuantization: base.perLayerQuantization)
            logger.info("\(name, privacy: .public): drafter ready, type \(base.modelType, privacy: .public)")
            return model
        } catch {
            logger.error("\(name, privacy: .public): drafter not built — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func targetVision(at directory: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return root["vision_config"] as? [String: Any] ?? [:]
    }

    /// The library chooses the text or the vision drafter by one thing: whether the drafter's config carries a
    /// non-empty `vision_config`. Drafters published for a vision model often ship an empty one, and the text drafter
    /// then meets a vision target and stops the process from inside. So that whole section is taken from the model
    /// the drafter will serve — the real one, because the vision drafter decodes it.
    private static func aligned(_ config: Data, withTargetVision vision: [String: Any]) -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: config) as? [String: Any] else { return config }
        let own = root["vision_config"] as? [String: Any] ?? [:]
        guard own.isEmpty != vision.isEmpty else { return config }
        root["vision_config"] = vision
        guard let merged = try? JSONSerialization.data(withJSONObject: root) else { return config }
        logger.info("drafter config aligned with the target, images \(vision.isEmpty ? "off" : "on", privacy: .public)")
        return merged
    }

    /// A drafter published on its own names its tensors the way its predictor sees them (`fc.weight`), while the model
    /// keeps that predictor under one module and expects `mtp.fc.weight` — the same weights inside a checkpoint do
    /// carry the prefix. Nothing loads otherwise: the model's own `sanitize` keeps only prefixed keys. So the files
    /// are rewritten once, here, with the name of the module they belong to.
    private static func alignTensorNames(in directory: URL, to model: any MTPDrafterModel) {
        let roots = Set(model.children().flattened().map { $0.0.split(separator: ".").first.map(String.init) ?? $0.0 })
        guard roots.count == 1, let root = roots.first else { return }
        let names = tensorNames(inModelAt: directory)
        guard !names.isEmpty, !names.contains(where: { $0.hasPrefix(root + ".") }) else { return }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "safetensors" }
        do {
            for file in files {
                let (arrays, metadata) = try loadArraysAndMetadata(url: file)
                let renamed = Dictionary(uniqueKeysWithValues: arrays.map { ("\(root).\($0.key)", $0.value) })
                // Written beside the original and swapped in: the file being read must not be the file being written.
                // The staging name keeps the `.safetensors` extension, which is what picks the format on save.
                let staged = directory.appending(path: "renaming-" + file.lastPathComponent)
                try save(arrays: renamed, metadata: metadata, url: staged)
                _ = try fm.replaceItemAt(file, withItemAt: staged)
            }
            try rewriteIndex(in: directory, prefix: root)
            logger.info("\(directory.lastPathComponent, privacy: .public): tensors renamed under \(root, privacy: .public)")
        } catch {
            logger.error("\(directory.lastPathComponent, privacy: .public): renaming failed — \(error.localizedDescription)")
        }
    }

    /// The index lists every tensor by name; it has to agree with the files after they are rewritten.
    private static func rewriteIndex(in directory: URL, prefix: String) throws {
        let url = directory.appending(path: "model.safetensors.index.json")
        guard let data = try? Data(contentsOf: url),
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let map = json["weight_map"] as? [String: Any]
        else { return }
        json["weight_map"] = Dictionary(uniqueKeysWithValues: map.map { ("\(prefix).\($0.key)", $0.value) })
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    // Heads inside a checkpoint

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
                if name.contains("mtp") || name.contains("nextn"), positiveCount(nested) != nil { return true }
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

    /// Whether the weights really hold the heads: MLX builds routinely drop them while keeping the config keys.
    static func carriesHeadWeights(in directory: URL) -> Bool {
        tensorNames(inModelAt: directory).contains { name in
            name.split(separator: ".").contains { $0 == "mtp" || $0.hasPrefix("nextn") }
        }
    }

    /// Tensor names of a checkpoint: from the safetensors index when there is one, otherwise from the file headers.
    private static func tensorNames(inModelAt directory: URL) -> [String] {
        if let data = try? Data(contentsOf: directory.appending(path: "model.safetensors.index.json")) {
            let names = tensorNames(indexJSON: data)
            if !names.isEmpty { return names }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "safetensors" }.flatMap { file -> [String] in
            guard let mapped = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
            return tensorNames(safetensorsHead: Data(mapped.prefix(1 << 20)))
        }
    }

    static func tensorNames(indexJSON: Data) -> [String] {
        guard let map = (try? JSONSerialization.jsonObject(with: indexJSON) as? [String: Any])?["weight_map"] as? [String: Any]
        else { return [] }
        return Array(map.keys)
    }

    /// A safetensors file starts with the header's length (8 bytes, little-endian) and then that JSON.
    static func tensorNames(safetensorsHead data: Data) -> [String] {
        guard data.count > 8 else { return [] }
        let length = data.prefix(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard length > 0, Int(length) + 8 <= data.count else { return [] }
        let header = data.dropFirst(8).prefix(Int(length))
        return Array(((try? JSONSerialization.jsonObject(with: header)) as? [String: Any])?.keys ?? [:].keys)
    }
}
