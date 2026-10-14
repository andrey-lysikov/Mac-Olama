//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM
import os

enum MTPDrafter {
    static let logger = Logger(subsystem: "ru.lysnet.macolama", category: "mtp")

    private static let registration = Task {
        await Qwen35TextMTPRegistration.register()
        await Qwen35VLMMTPRegistration.register()
        await Gemma4AssistantRegistration.register()
    }

    static let folderName = "drafter"

    static func directory(forModel directory: URL) -> URL { directory.appending(path: folderName) }

    static func isInstalled(forModel directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: self.directory(forModel: directory).appending(path: "config.json").path)
    }

    // What counts as a drafter

    static func isDrafterType(_ modelType: String) async -> Bool {
        await registration.value
        guard await MTPDrafterTypeRegistry.shared.contains(modelType) else { return false }
        let llm = await LLMModelFactory.shared.typeRegistry.contains(modelType)
        let vlm = await VLMModelFactory.shared.typeRegistry.contains(modelType)
        return !(llm || vlm)
    }

    static func modelType(inConfig config: Data) -> String? {
        // Root `model_type` only; `text_config` may differ.
        ModelConfig(data: config)?.root["model_type"] as? String
    }

    static func isDrafter(directory: URL) async -> Bool {
        guard let config = try? Data(contentsOf: directory.appending(path: "config.json")), let type = modelType(inConfig: config)
        else { return false }
        return await isDrafterType(type)
    }

    // Loading

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
            // Common for MLX conversions: config keys kept, heads dropped.
            logger.info("\(name, privacy: .public): no drafter, the config declares heads but the weights hold none")
            return nil
        }
        logger.info("\(name, privacy: .public): loading the heads inside the checkpoint")
        return await build(from: modelDirectory, target: modelDirectory)
    }

    struct Traits: Sendable {
        var needsGreedy: Bool
    }

    static func inspect(folder: URL, target: URL) async -> Traits? {
        guard let model = await build(from: folder, target: target) else { return nil }
        return Traits(needsGreedy: model.requiresGreedySampling)
    }

    static func build(from directory: URL, target: URL) async -> (any MTPDrafterModel)? {
        let name = directory.lastPathComponent
        guard let own = try? Data(contentsOf: directory.appending(path: "config.json")) else {
            logger.error("\(name, privacy: .public): no config.json in the folder")
            return nil
        }
        let (config, sees) = aligned(own, withTargetAt: target)
        await registration.value
        do {
            let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: config)
            let model = try await MTPDrafterTypeRegistry.shared.createModel(configuration: config, modelType: base.modelType)
            // A text drafter with a vision model crashes inside the library.
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

    private static func aligned(_ config: Data, withTargetAt target: URL) -> (config: Data, seesImages: Bool) {
        let targetRoot = ModelConfig(directory: target)?.root ?? [:]
        let vision = targetRoot["vision_config"] as? [String: Any] ?? [:]
        guard var root = ModelConfig(data: config)?.root else { return (config, !vision.isEmpty) }
        let own = root["vision_config"] as? [String: Any] ?? [:]
        guard own.isEmpty != vision.isEmpty else { return (config, !own.isEmpty) }
        root["vision_config"] = vision
        guard let merged = try? JSONSerialization.data(withJSONObject: root) else { return (config, !own.isEmpty) }
        logger.info("drafter config aligned with the target, images \(vision.isEmpty ? "off" : "on", privacy: .public)")
        return (merged, !vision.isEmpty)
    }

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
                // Write beside the original and swap; keep the `.safetensors` extension.
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

    static func declaresHeads(_ configJSON: Data) -> Bool {
        guard let config = ModelConfig(data: configJSON) else { return false }
        return declaresHeads(in: config.root)
    }

    private static func declaresHeads(in value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, nested) in object {
                let name = key.lowercased()
                // Booleans bridge to `NSNumber`; not a layer count.
                if name.contains("mtp") || name.contains("nextn"), let number = nested as? NSNumber,
                    CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue > 0
                {
                    return true
                }
                if declaresHeads(in: nested) { return true }
            }
        }
        if let array = value as? [Any] { return array.contains { declaresHeads(in: $0) } }
        return false
    }

    static func carriesHeadWeights(in directory: URL) -> Bool {
        tensorNames(inModelAt: directory).contains { name in
            name.split(separator: ".").contains { $0 == "mtp" || $0.hasPrefix("nextn") }
        }
    }

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

    static func tensorNames(safetensorsHead data: Data) -> [String] {
        guard data.count > 8 else { return [] }
        let length = data.prefix(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard length > 0, Int(length) + 8 <= data.count else { return [] }
        let header = data.dropFirst(8).prefix(Int(length))
        return Array(((try? JSONSerialization.jsonObject(with: header)) as? [String: Any])?.keys ?? [:].keys)
    }
}
