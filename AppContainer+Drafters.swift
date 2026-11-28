//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// MTP drafters installed next to their models.
extension AppContainer {
    static func drafterFolders(in list: [ModelDescriptor]) async -> [ModelDescriptor] {
        var found: [ModelDescriptor] = []
        for model in list where !model.source.isRemote {
            if await MTPDrafter.isDrafter(directory: model.directory) { found.append(model) }
        }
        return found
    }

    func attachStrayDrafters(in list: [ModelDescriptor]) async -> Bool {
        let strays = await Self.drafterFolders(in: list)
        guard !strays.isEmpty else { return false }
        let chatModels = list.filter { model in !model.source.isRemote && !strays.contains { $0.id == model.id } }
        var moved = false
        for drafter in strays {
            // Drafter name derived from its base model.
            let base = drafter.baseModel?.lowercased().replacingOccurrences(of: "-assistant", with: "")
            guard let base,
                let target = chatModels.first(where: {
                    $0.baseModel?.lowercased() == base && !MTPDrafter.isInstalled(forModel: $0.directory)
                })
            else {
                print(
                    "\(drafter.repoID): a drafter without its model here, waiting in the list")
                continue
            }
            let destination = MTPDrafter.directory(forModel: target.directory)
            do {
                try FileManager.default.moveItem(at: drafter.directory, to: destination)
            } catch {
                print("\(drafter.repoID): could not attach — \(error.localizedDescription)")
                continue
            }
            print(
                "\(drafter.repoID): attached to \(target.repoID)")
            moved = true
            setSpeculative(true, for: target)
            notifySpeculationOn(target)
        }
        return moved
    }

    func notifySpeculationOn(_ model: ModelDescriptor) {
        notifyAboutDownload(
            title: String(localized: "Faster answers are on"),
            body: String(localized: "\(model.name) drafts several tokens per round; its answers no longer vary."),
            category: .downloadFinished)
    }

    func deleteStrayDrafter(_ drafter: ModelDescriptor) {
        try? FileManager.default.removeItem(at: drafter.directory)
        Task { await refreshModels() }
    }

    func canSpeculate(_ model: ModelDescriptor) -> Bool {
        guard !model.source.isRemote else { return false }
        return model.baseModel?.isEmpty == false || drafterIsInstalled(for: model)
    }

    func drafterIsInstalled(for model: ModelDescriptor) -> Bool { MTPDrafter.isInstalled(forModel: model.directory) }

    func installedDrafterRepo(for model: ModelDescriptor) -> String? {
        try? ModelManifest.load(from: MTPDrafter.directory(forModel: model.directory)).repoID
    }

    func isSpeculative(_ model: ModelDescriptor) -> Bool { settings.speculativeModels.contains(model.id) }

    func drafterNeedsGreedy(_ model: ModelDescriptor) -> Bool { settings.greedyDrafters.contains(model.id) }

    func setSpeculative(_ on: Bool, for model: ModelDescriptor) {
        print("\(model.repoID): speculation \(on ? "on" : "off")")
        toggle(model.id, in: \.speculativeModels, on: on)
        applyConversationConfiguration()
        forgetDrafter(of: model)
    }

    func drafterCandidates(for model: ModelDescriptor) async -> [String] {
        guard let base = model.baseModel, !base.isEmpty else {
            print("\(model.repoID): no base model recorded, nothing to look for")
            return []
        }
        let client = hubClient
        let name = base.split(separator: "/").last.map(String.init) ?? base
        async let tagged = try? client.drafters(baseModel: base, limit: 20)
        async let named = try? client.search(query: name, limit: 50)
        var seen = Set<String>()
        let found = ((await tagged) ?? []) + ((await named) ?? [])
        var fitting: [String] = []
        for candidate in found where seen.insert(candidate.id).inserted {
            guard let type = await drafterType(of: candidate, client: client) else { continue }
            print("\(candidate.id): drafter of type \(type)")
            fitting.append(candidate.id)
            if fitting.count == 8 { break }
        }
        print(
            "\(model.repoID): \(found.count) repositories seen, \(fitting.count) usable drafters")
        return fitting
    }

    private func drafterType(of candidate: HubModelSummary, client: HubClient) async -> String? {
        for tag in candidate.tags ?? [] where await MTPDrafter.isDrafterType(tag) { return tag }
        guard let config = try? await client.config(repoID: candidate.id), let type = MTPDrafter.modelType(inConfig: config),
            await MTPDrafter.isDrafterType(type)
        else { return nil }
        return type
    }

    func drafterDownload(for model: ModelDescriptor) -> ActiveDownload? {
        downloads.first { $0.drafterFor == model.repoID }
    }

    func drafterVerdict(for model: ModelDescriptor) -> String? { drafterVerdicts[model.repoID] }

    func installDrafter(repoID: String, for model: ModelDescriptor) {
        drafterVerdicts[model.repoID] = nil
        // Hub-provided name; a parse failure is a bug.
        guard let reference = ModelReference.parse(repoID) else {
            print("not a repository name: \(repoID)")
            return
        }
        let id = reference.repoID
        guard downloaderIsIdle(repoID: id) else { return }
        print("drafter queued: \(id) for \(model.repoID)")
        enqueue(ActiveDownload(repoID: id, title: model.name, drafterFor: model.repoID))
    }

    func setNeedsGreedy(_ needed: Bool, for model: ModelDescriptor) {
        toggle(model.id, in: \.greedyDrafters, on: needed)
        applyConversationConfiguration()
    }

    func removeDrafter(for model: ModelDescriptor) {
        print("\(model.repoID): drafter removed")
        try? FileManager.default.removeItem(at: MTPDrafter.directory(forModel: model.directory))
        setNeedsGreedy(false, for: model)
        setSpeculative(false, for: model)
    }

    func finishDrafter(at folder: URL, repoID: String, modelRepoID: String) async {
        guard let model = models.first(where: { $0.repoID == modelRepoID }) else { return }
        let traits = await MTPDrafter.inspect(folder: folder, target: model.directory)
        if traits == nil {
            try? FileManager.default.removeItem(at: folder)
            print("drafter rejected: \(repoID) is not usable for \(model.repoID)")
            drafterVerdicts[model.repoID] = String(localized: "\(repoID) does not hold prediction heads for \(model.name).")
            notifyAboutDownload(
                title: String(localized: "Not an MTP drafter"),
                body: String(localized: "\(repoID) does not hold prediction heads for \(model.name)."))
            return
        }
        print("drafter installed: \(repoID) for \(model.repoID)")
        setNeedsGreedy(traits?.needsGreedy == true, for: model)
        drafterVerdicts[model.repoID] = nil
        setSpeculative(true, for: model)
        await refreshModels()
        notifySpeculationOn(model)
    }

    private func forgetDrafter(of model: ModelDescriptor) {
        guard engineState.modelID == model.id else { return }
        Task { await engineManager.unloadLocal() }
    }
}
