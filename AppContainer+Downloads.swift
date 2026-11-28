//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// Download queue, shared by the download window, menu, notifications and the update checker.
extension AppContainer {
    func download(repoID: String, title: String? = nil, quantization: String? = nil, sizeBytes: Int64? = nil) {
        guard let ref = ModelReference.parse(repoID) else { return }
        download(ref, title: title, quantization: quantization, sizeBytes: sizeBytes)
    }

    func download(_ reference: ModelReference, title: String? = nil, quantization: String? = nil, sizeBytes: Int64? = nil) {
        enqueue(ActiveDownload(repoID: reference.repoID, title: title, quantization: quantization, sizeBytes: sizeBytes))
    }

    func enqueue(_ download: ActiveDownload) {
        guard downloaderIsIdle(repoID: download.repoID) else { return }
        downloads.removeAll { $0.repoID == download.repoID }
        downloads.append(download)
        startNextDownloadIfIdle()
    }

    // A download interrupted by quitting the app continues on the next launch.

    func persistDownloads() {
        let stored = downloads.filter { !$0.finished }.map {
            StoredDownload(
                repoID: $0.repoID, title: $0.title, quantization: $0.quantization, sizeBytes: $0.sizeBytes,
                paused: !($0.phase == .running || $0.phase == .queued), drafterFor: $0.drafterFor)
        }
        guard stored != persistedDownloads else { return }
        persistedDownloads = stored
        settings.pendingDownloads = try? JSONEncoder().encode(stored)
    }

    func restoreDownloads() {
        guard downloads.isEmpty, let data = settings.pendingDownloads,
            let stored = try? JSONDecoder().decode([StoredDownload].self, from: data)
        else { return }
        let installed = Set(models.map { $0.repoID.lowercased() })
        downloads = stored.filter { !installed.contains($0.repoID.lowercased()) }.map {
            ActiveDownload(
                repoID: $0.repoID, title: $0.title, quantization: $0.quantization, sizeBytes: $0.sizeBytes,
                phase: $0.paused ? .paused : .queued, drafterFor: $0.drafterFor)
        }
        startNextDownloadIfIdle()
    }

    func removeOrphanedStaging() {
        let fm = FileManager.default
        let wanted = Set(downloads.compactMap { ModelReference.parse($0.repoID)?.directoryName })
        let folders = (try? fm.contentsOfDirectory(at: paths.downloads, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !wanted.contains(folder.lastPathComponent) {
            let files = (fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL]) ?? []
            let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } / (1 << 20)
            do {
                try fm.removeItem(at: folder)
                print("dropped an abandoned download: \(folder.lastPathComponent), \(size) MB freed")
            } catch {
                print("could not drop \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    var orderedDownloads: [ActiveDownload] {
        func rank(_ d: ActiveDownload) -> Int {
            switch d.phase {
            case .running: 0
            case .paused: 1
            case .queued: 2
            case .failed, .needsToken, .needsAccess: 3
            case .finished: 4
            }
        }
        return downloads.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    func startNextDownloadIfIdle() {
        rebuildDownloaderIfIdle()
        // Start nothing while any transfer task is still winding down.
        guard downloadTasks.isEmpty, !downloads.contains(where: \.isRunning),
            let next = downloads.firstIndex(where: { $0.phase == .queued }),
            let reference = ModelReference.parse(downloads[next].repoID)
        else { return }
        downloads[next].phase = .running
        run(reference, drafterFor: downloads[next].drafterFor)
    }

    private func run(_ reference: ModelReference, drafterFor: String?) {
        let repoID = reference.repoID
        let destination = drafterFor.flatMap { target in models.first { $0.repoID == target } }
            .map { MTPDrafter.directory(forModel: $0.directory) }
        if drafterFor != nil, destination == nil {
            downloads.removeAll { $0.repoID == repoID }
            return
        }
        downloadTasks[repoID] = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in await self.downloader.download(reference, into: destination) {
                    guard let i = self.downloads.firstIndex(where: { $0.repoID == repoID }) else { break }
                    switch event {
                    case .progress(let p): self.downloads[i].progress = p
                    case .finished(let model):
                        self.downloads.removeAll { $0.repoID == repoID }
                        if let target = drafterFor, let folder = destination {
                            await self.finishDrafter(at: folder, repoID: repoID, modelRepoID: target)
                            break
                        }
                        await self.refreshModels()
                        if self.settings.activeModelID == nil { self.setActiveModel(model) }
                        self.notifyAboutDownload(
                            title: String(localized: "Model downloaded"), body: String(localized: "\(model.name) is ready to use."),
                            category: .downloadFinished)
                    case .resolved, .fileFinished: break
                    }
                }
            } catch {
                // Pause and cancel both stop; partial files are kept.
                if let i = self.downloads.firstIndex(where: { $0.repoID == repoID }), self.downloads[i].phase == .running {
                    if case HubError.gatedRepositoryRequiresToken = error {
                        self.downloads[i].phase = self.hubClient.token == nil ? .needsToken : .needsAccess
                        if self.downloads[i].phase == .needsToken { self.tokenPromptRequested = true }
                    } else {
                        self.downloads[i].phase = .failed(Self.describe(error))
                    }
                    if case HubError.cancelled = error {
                    } else {
                        self.notifyAboutDownload(
                            title: String(localized: "Download failed"), body: "\(repoID): \(Self.describe(error))")
                    }
                }
            }
            self.downloadTasks[repoID] = nil
            self.startNextDownloadIfIdle()
        }
    }

    func notifyAboutDownload(title: String, body: String, category: NotificationService.Category = .info) {
        guard !(section == .models && WindowManager.shared.isOpen(.chats)) else { return }
        NotificationService.shared.send(title: title, body: body, category: category)
    }

    private func withDownload(
        _ repoID: String, phase allowed: (ActiveDownload.Phase) -> Bool = { _ in true }, _ body: (Int) -> Void
    ) {
        guard let i = downloads.firstIndex(where: { $0.repoID == repoID }), allowed(downloads[i].phase) else { return }
        body(i)
    }

    func pauseDownload(repoID: String) {
        withDownload(repoID, phase: { $0 == .running || $0 == .queued }) { i in
            let wasRunning = downloads[i].isRunning
            downloads[i].phase = .paused
            if wasRunning { Task { await downloader.cancel(repoID: repoID) } }
        }
    }

    func resumeDownload(repoID: String) {
        withDownload(repoID, phase: { $0 == .paused || $0 == .queued }) { i in
            var entry = downloads.remove(at: i)
            entry.phase = .queued
            downloads.insert(entry, at: 0)
            guard let running = downloads.firstIndex(where: \.isRunning) else {
                startNextDownloadIfIdle()
                return
            }
            // The finished task starts the next download, which is this one.
            let preempted = downloads[running].repoID
            downloads[running].phase = .queued
            Task { await downloader.cancel(repoID: preempted) }
        }
    }

    func cancelDownload(repoID: String) {
        withDownload(repoID) { i in
            let wasRunning = downloads[i].isRunning
            downloads.remove(at: i)
            if wasRunning { Task { await downloader.cancel(repoID: repoID) } }
        }
    }

    func downloaderIsIdle(repoID: String) -> Bool {
        !downloads.contains { $0.repoID == repoID && $0.isActive }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case HubError.gatedRepositoryRequiresToken:
            String(localized: "This repository is gated. Add a Hugging Face token and accept the license on huggingface.co.")
        case HubError.notFound: String(localized: "Repository not found.")
        case HubError.insufficientDiskSpace(let need, let have):
            String(
                localized:
                    "Not enough disk space: need \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)), available \(ByteCountFormatter.string(fromByteCount: have, countStyle: .file))."
            )
        case HubError.checksumMismatch(let file): String(localized: "Checksum mismatch for \(file). Try again.")
        case HubError.unsafePath(let path): String(localized: "The repository lists an unsafe file path (\(path)) and cannot be installed.")
        case HubError.cancelled: String(localized: "Cancelled.")
        case let error as URLError
        where [
            URLError.Code.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
            .secureConnectionFailed, .dnsLookupFailed,
        ].contains(error.code):
            String(localized: "Connection failed")
        default: error.localizedDescription
        }
    }

    // Credentials

    func setHuggingFaceToken(_ token: String?) {
        let value = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = value?.isEmpty == false ? value : nil
        settings.huggingFaceToken = stored
        hubClient = HubClient(token: stored)
        downloaderNeedsRebuild = true
        rebuildDownloaderIfIdle()
    }

    func saveHuggingFaceTokenAndRetry(_ token: String) {
        setHuggingFaceToken(token)
        guard hubClient.token != nil else { return }
        let waiting = downloads.filter { $0.phase == .needsToken }
        downloads.removeAll { $0.phase == .needsToken }
        let head = downloads.firstIndex(where: { $0.phase == .queued }) ?? downloads.endIndex
        downloads.insert(
            contentsOf: waiting.map {
                var d = $0; d.phase = .queued; d.progress = nil; return d
            }, at: head)
        startNextDownloadIfIdle()
    }

    // Swap the hub client only between transfers.
    func rebuildDownloaderIfIdle() {
        guard downloaderNeedsRebuild, downloadTasks.isEmpty else { return }
        downloader = ModelDownloader(client: hubClient, paths: paths)
        downloaderNeedsRebuild = false
        applyDownloadLimits()
    }

    // Transfer limits

    func setDownloadSpeedLimit(_ mbps: Int) {
        settings.downloadSpeedLimitMBps = max(0, mbps)
        applyDownloadLimits()
    }

    func setDownloadConcurrentFiles(_ count: Int) {
        settings.downloadConcurrentFiles = min(max(count, 1), 4)
        applyDownloadLimits()
    }

    func applyDownloadLimits() {
        let bytesPerSecond = Int64(settings.downloadSpeedLimitMBps) * 1_000_000
        let files = settings.downloadConcurrentFiles
        Task { [downloader] in
            await downloader.setSpeedLimit(bytesPerSecond: bytesPerSecond)
            await downloader.setMaxConcurrentFiles(files)
        }
    }
}
