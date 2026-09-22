//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

// DownloadViewModel

/// Search across hubs for the models window. Downloads themselves are owned by AppContainer.
@MainActor
@Observable
final class DownloadViewModel {
    enum Hub: String, CaseIterable, Identifiable {
        case huggingFace, modelScope, link, api
        var id: String { rawValue }
        /// The hub a search goes to; nil for the entries that do not search.
        var source: ModelSource? {
            switch self {
            case .huggingFace: .huggingFace
            case .modelScope: .modelScope
            case .link, .api: nil
            }
        }
        var title: String {
            switch self {
            case .huggingFace, .modelScope: source?.displayName ?? ""
            case .link: String(localized: "By Link")
            case .api: String(localized: "Connect by API")
            }
        }
        /// The hub's own logo (greyscale, like the model icons), a symbol until it has loaded.
        @MainActor var icon: Image {
            if let owner = source?.avatarOwner, let avatar = ModelIcons.shared.avatar(owner) {
                // The picker is drawn by AppKit: the logo goes in as a small rounded image.
                return Image(nsImage: ModelIcons.rounded(avatar, side: 14))
            }
            switch self {
            case .huggingFace, .modelScope: return Image(systemName: "shippingbox")
            case .link: return Image(systemName: "link")
            case .api: return Image(systemName: "network")
            }
        }
        /// The search hubs stay bare: the dropdown of recommended models is the hint. A link has to be typed exactly.
        var prompt: String {
            switch self {
            case .huggingFace, .modelScope: ""
            case .link: String(localized: "Repository or link")
            case .api: String(localized: "Model name")
            }
        }

    }

    /// One result line; the same shape for both hubs.
    struct Row: Identifiable, Equatable {
        var id: String { repoID }
        var repoID: String  // `org/repo` or `modelscope:org/repo`
        var source: ModelSource
        /// Author of the base model and the community that built this copy: the row's icon.
        var owners: ModelOwners
        var title: String
        var sizeBytes: Int64?
        var quantization: String?
        var kind: ModelKind?
        var contextLength: Int?
        var isGated = false
        var detailsLoaded = false
        var isMLX = true
        var lastModified: Date?
        /// From the repository's config.json, once the details have loaded: the exact cost of the attention cache.
        var kvCache: KVCacheProfile?
    }

    enum Verdict: Equatable {
        /// `tooLarge` is the red verdict: the model will likely not fit, or cannot run here at all. Only the latter blocks the download.
        case fits(String), unknown(String), tooLarge(String)
        var symbol: String {
            switch self {
            case .fits: "checkmark.circle.fill"
            case .unknown: "questionmark.circle.fill"
            case .tooLarge: "exclamationmark.triangle.fill"
            }
        }
        var detail: String {
            switch self {
            case .fits(let s), .unknown(let s), .tooLarge(let s): s
            }
        }
    }

    /// A model being connected by API: typed into the models card, checked against the server on save.
    struct RemoteDraft: Identifiable {
        let id = UUID()
        var name: String
        var address = "http://localhost:8080"
        var token = ""
        var isSaving = false
        var error: String?
    }

    private let container: AppContainer
    var hub: Hub = .huggingFace
    var remoteDrafts: [RemoteDraft] = []
    var query = ""
    private(set) var rows: [Row] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var hasSearched = false
    private var searchTask: Task<Void, Never>?
    private var detailTasks: [String: Task<Void, Never>] = [:]

    init(container: AppContainer) {
        self.container = container
    }

    /// Names offered by the empty search field. "By Link" needs an exact identifier, so it offers nothing.
    var suggestions: [String] { hub == .link || hub == .api ? [] : RecommendedModels.names }

    /// A suggestion was taken from the dropdown: swap the family name for this hub's search text and search right away.
    func queryChanged() {
        guard let source = hub.source, let text = RecommendedModels.query(for: query, in: source) else { return }
        query = text
        search()
    }

    func search() {
        if hub == .api { return addRemoteDraft() }
        searchTask?.cancel()
        detailTasks.values.forEach { $0.cancel() }
        detailTasks = [:]
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchError = nil
        guard !q.isEmpty else {
            rows = []
            hasSearched = false
            isSearching = false
            return
        }
        isSearching = true
        hasSearched = true
        rows = []
        let hub = hub
        searchTask = Task {
            do {
                switch hub {
                case .huggingFace: try await searchHuggingFace(q)
                case .modelScope: try await searchModelScope(q)
                case .link: try await resolveLink(q)
                case .api: break
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A gated repository hit while searching or checking a link asks for the token the same way a download does.
                if case HubError.gatedRepositoryRequiresToken = error, container.hubClient.token == nil {
                    container.tokenPromptRequested = true
                } else {
                    searchError = AppContainer.describe(error)
                }
            }
            guard !Task.isCancelled else { return }
            isSearching = false
        }
    }

    // Connect by API

    /// The name typed in the search field opens a row in the models card for the address and the token.
    private func addRemoteDraft() {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            searchError = String(localized: "Type the model's name as the server knows it, e.g. qwen3:8b.")
            return
        }
        searchError = nil
        remoteDrafts.append(RemoteDraft(name: name))
        query = ""
    }

    func saveRemote(_ id: UUID) {
        guard let index = remoteDrafts.firstIndex(where: { $0.id == id }) else { return }
        remoteDrafts[index].isSaving = true
        remoteDrafts[index].error = nil
        let draft = remoteDrafts[index]
        Task {
            do {
                try await container.connectRemote(model: draft.name, address: draft.address, token: draft.token)
                remoteDrafts.removeAll { $0.id == id }
            } catch {
                guard let i = remoteDrafts.firstIndex(where: { $0.id == id }) else { return }
                remoteDrafts[i].isSaving = false
                remoteDrafts[i].error = "\(error)"
            }
        }
    }

    func cancelRemote(_ id: UUID) {
        remoteDrafts.removeAll { $0.id == id }
    }

    // `org/name` narrows the search to that author, so a recommended repository comes back first.
    private func searchHuggingFace(_ q: String) async throws {
        let parts = q.split(separator: "/", maxSplits: 1).map(String.init)
        let found =
            parts.count == 2
            ? try await container.hubClient.search(query: parts[1], author: parts[0], limit: 40)
            : try await container.hubClient.search(query: q, limit: 40)
        try Task.checkCancellation()
        rows = found.filter(\.isMLX).map {
            Row(
                repoID: $0.id, source: .huggingFace,
                owners: ModelOwners(repoID: $0.id, baseModel: ModelOwners.baseModel(fromTags: $0.tags ?? [])),
                title: $0.displayName, isGated: $0.isGated, isMLX: $0.isMLX, lastModified: $0.lastModified)
        }
        // The order depends on every row's verdict, so details are fetched for all rows up front (URLSession queues them per host).
        for row in rows { loadDetails(for: row.repoID) }
    }

    // ModelScope's search already carries the size and the base model; the config is read per row for kind and context.
    private func searchModelScope(_ q: String) async throws {
        let found = try await container.modelScopeClient.search(query: q, limit: 40)
        try Task.checkCancellation()
        rows = found.map { Self.row(modelScope: $0) }
        for row in rows { loadDetails(for: row.repoID) }
    }

    private static func row(modelScope model: ModelScopeModel) -> Row {
        let repoID = ModelScopeClient.prefix + model.id
        return Row(
            repoID: repoID, source: .modelScope, owners: ModelOwners(repoID: repoID, baseModel: model.baseModel),
            title: model.displayName, sizeBytes: model.storageSize, isMLX: model.isMLX, lastModified: model.lastUpdated)
    }

    /// "By link": checks that the model exists and reports its name and size as a single row.
    private func resolveLink(_ q: String) async throws {
        guard let reference = ModelReference.parse(q) else {
            searchError = String(localized: "Enter mlx-community/Qwen3.5-9B-MLX-4bit or a huggingface.co / modelscope.cn link")
            return
        }
        switch reference {
        case .huggingFace(let repoID):
            let info = try await container.hubClient.info(repoID: repoID)
            try Task.checkCancellation()
            var row = Row(
                repoID: info.id, source: .huggingFace,
                owners: ModelOwners(repoID: info.id, baseModel: ModelOwners.baseModel(fromTags: info.tags ?? [])),
                title: info.id.split(separator: "/").last.map(String.init) ?? info.id, isGated: info.gated?.isGated ?? false,
                isMLX: info.tags?.contains("mlx") == true)
            apply(info: info, classification: try? await container.hubClient.classify(repoID: repoID), to: &row)
            rows = [row]
        case .modelScope(let repoID):
            let info = try await container.modelScopeClient.info(repoID: repoID)
            try Task.checkCancellation()
            rows = [Self.row(modelScope: info)]
            loadDetails(for: rows[0].repoID)
        }
    }

    /// Lazily fetches size and classification for a row to avoid flooding HF with requests.
    func loadDetails(for repoID: String) {
        guard detailTasks[repoID] == nil, let row = rows.first(where: { $0.repoID == repoID }), !row.detailsLoaded else { return }
        if case .modelScope(let id) = ModelReference.parse(repoID) { return loadModelScopeDetails(for: repoID, hubRepoID: id) }
        detailTasks[repoID] = Task {
            defer { detailTasks[repoID] = nil }
            async let info = container.hubClient.info(repoID: repoID)
            async let cls = container.hubClient.classify(repoID: repoID)
            let loadedInfo = try? await info
            let classification = try? await cls
            guard !Task.isCancelled, let i = rows.firstIndex(where: { $0.repoID == repoID }) else { return }
            if let loadedInfo {
                apply(info: loadedInfo, classification: classification, to: &rows[i])
            } else {
                rows[i].detailsLoaded = true
            }
        }
    }

    /// The size came with the search; the config gives the kind, the context and the quantization.
    private func loadModelScopeDetails(for repoID: String, hubRepoID: String) {
        detailTasks[repoID] = Task {
            defer { detailTasks[repoID] = nil }
            let classification = (try? await container.modelScopeClient.config(repoID: hubRepoID)).map {
                HubModelClassification.classify(configJSON: $0)
            }
            guard !Task.isCancelled, let i = rows.firstIndex(where: { $0.repoID == repoID }) else { return }
            rows[i].quantization = classification?.quantization
            rows[i].kind = classification?.kind
            rows[i].contextLength = classification?.contextLength
            rows[i].kvCache = classification?.kvCache
            rows[i].detailsLoaded = true
        }
    }

    private func apply(info: HubModelInfo, classification: HubModelClassification?, to row: inout Row) {
        row.sizeBytes = info.totalBytes
        row.quantization = classification?.quantization
        row.kind = classification?.kind
        row.contextLength = classification?.contextLength
        row.kvCache = classification?.kvCache
        row.detailsLoaded = true
    }

    // Order: models that fit, the uncertain ones, those that will not run; newest first inside each group.

    var sortedRows: [Row] {
        func rank(_ row: Row) -> Int {
            switch verdict(for: row) {
            case .fits: 0
            case .unknown: 1
            case .tooLarge: 2
            }
        }
        return rows.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            let (da, db) = (a.element.lastModified ?? .distantPast, b.element.lastModified ?? .distantPast)
            return da != db ? da > db : a.offset < b.offset
        }
        .map(\.element)
    }

    // Verdict

    func verdict(for row: Row) -> Verdict {
        guard row.detailsLoaded else { return .unknown(String(localized: "Checking size and architecture…")) }
        guard let bytes = row.sizeBytes, bytes > 0 else { return .unknown(String(localized: "Model size is unknown.")) }
        let hardware = container.hardware
        let fit = ModelFitReport.evaluate(
            modelBytes: bytes, contextLength: row.contextLength, hardware: hardware, kvCache: row.kvCache,
            availableBytes: HardwareProfile.availableMemoryBytes())
        let machine = "\(hardware.chipName), \(hardware.memoryGB) GB"
        let needed = (Int64(hardware.memoryBytes) - fit.memoryAfterLoadBytes).memorySizeText
        let limit = Int64(hardware.wiredLimitBytes).memorySizeText
        if fit.fit == .no {
            return .tooLarge(String(localized: "Won't fit: needs about \(needed), but \(machine) can give a model at most \(limit)."))
        }
        if row.isGated, container.hubClient.token == nil {
            return .unknown(
                String(localized: "Gated repository: add a Hugging Face access token (key button in the toolbar) to download it."))
        }
        if !row.isMLX {
            return .unknown(
                String(localized: "Not an MLX build: it may be large and may fail to load. Prefer an MLX conversion of this model."))
        }
        if fit.warnings.contains("memory-busy") {
            let free = Int64(HardwareProfile.availableMemoryBytes()).memorySizeText
            return .unknown(
                String(
                    localized:
                        "Would fit (about \(needed) of \(limit)), but only \(free) is free right now: close some apps or expect swapping."
                ))
        }
        if fit.fit == .tight {
            return .unknown(
                String(localized: "Fits, but tightly: needs about \(needed) of \(limit); little memory will be left."))
        }
        let left = max(0, fit.memoryAfterLoadBytes).memorySizeText
        return .fits(String(localized: "Fits \(machine): about \(left) left for the system."))
    }

    func destination(for repoID: String) -> String {
        guard let reference = ModelReference.parse(repoID) else { return "" }
        return (container.paths.models.appendingPathComponent(reference.directoryName).path as NSString).abbreviatingWithTildeInPath
    }
}

// ModelLibraryView

// ModelLibraryHeader

/// The controls that used to sit in the window's toolbar: hub, search, the MLX checkbox and the token key. The chats
/// window draws them itself in its title row, so nothing of them is ever folded into a "»" overflow menu.
struct ModelLibraryHeader: View {
    @Bindable var viewModel: DownloadViewModel
    @Environment(AppContainer.self) private var container
    @State private var showsToken = false

    var body: some View {
        HStack(spacing: 10) {
            Picker(String(localized: "Hub"), selection: $viewModel.hub) {
                ForEach(DownloadViewModel.Hub.allCases) { hub in
                    Label {
                        Text(verbatim: hub.title)
                    } icon: {
                        hub.icon
                    }
                    .labelStyle(.titleAndIcon)
                    .tag(hub)
                }
            }
            .labelsHidden().fixedSize()
            // The search capsule holds the field and, inside it on the right, the magnifier that runs the search.
            HStack(spacing: 6) {
                // VERIFY(macOS26): suggestions are expected to drop down as soon as the empty field gets focus.
                TextField(viewModel.hub.prompt, text: $viewModel.query)
                    .textFieldStyle(.plain).frame(minWidth: 120, idealWidth: 240, maxWidth: 280)
                    .accessibilityLabel(String(localized: "Search"))
                    .textInputSuggestions {
                        if viewModel.query.isEmpty {
                            ForEach(viewModel.suggestions, id: \.self) { name in
                                Text(verbatim: name).textInputCompletion(name)
                            }
                        }
                    }
                    .onChange(of: viewModel.query) { _, _ in viewModel.queryChanged() }
                    .onSubmit { viewModel.search() }
                // "By link" and "Connect by API" take an exact name instead of searching: a check mark, not a magnifier.
                Button {
                    viewModel.search()
                } label: {
                    Image(systemName: viewModel.hub == .api || viewModel.hub == .link ? "checkmark.circle" : "magnifyingglass")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(
                    viewModel.hub == .api
                        ? String(localized: "Add this model: enter its server address below")
                        : viewModel.hub == .link
                            ? String(localized: "Check that the model exists and show its size") : String(localized: "Search")
                )
                .accessibilityLabel(viewModel.hub == .api ? String(localized: "Add") : String(localized: "Search"))
            }
            .searchCapsule()
            Spacer(minLength: 8)
            Button {
                showsToken.toggle()
            } label: {
                Image(systemName: "key").font(.system(size: 16)).frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(String(localized: "Access token for gated Hugging Face repositories"))
            .accessibilityLabel(String(localized: "Hugging Face Token"))
            .popover(isPresented: $showsToken, arrowEdge: .bottom) {
                TokenSettingsView(isPresented: $showsToken).environment(container)
            }
        }
        // Any action that hits a gated repository opens the token popover, exactly as if the key button had been pressed.
        .onChange(of: container.tokenPromptRequested, initial: true) { _, requested in
            guard requested else { return }
            showsToken = true
            container.tokenPromptRequested = false
        }
    }
}

// ModelLibraryView

/// Model library, shown in the right column of the chats window: results on top, and a permanent list of downloaded
/// models at the bottom with running downloads above them. Its controls live in the window's title row.
struct ModelLibraryView: View {
    @Bindable var viewModel: DownloadViewModel
    @Environment(AppContainer.self) private var container
    /// The model whose MTP popover is open and the drafters the hub offers for it.
    @State private var drafterTarget: String?
    @State private var drafterCandidates: [String] = []
    @State private var drafterSearch: Task<Void, Never>?
    @State private var drafterSearching = false

    var body: some View {
        content(viewModel)
            // Only here, and once a minute: this is the section that shows whether a connected server answers, so a
            // server that comes back is noticed without asking it from every window all the time.
            .task {
                while !Task.isCancelled {
                    container.checkModelAvailability(force: true)
                    try? await Task.sleep(for: .seconds(60))
                }
            }
    }

    private func content(_ vm: DownloadViewModel) -> some View {
        @Bindable var vm = vm
        return VStack(spacing: 0) {
            if let error = vm.searchError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
            }
            if vm.hasSearched {
                ScrollView {
                    LazyVStack(spacing: 0) { results(vm) }.padding(.horizontal, 16).padding(.vertical, 4)
                }
                .frame(minHeight: 80, maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            // Laid out first: the card takes what its rows need and the results list above shrinks to what is left.
            library.layoutPriority(1)
        }
    }

    // Results

    @ViewBuilder
    private func results(_ vm: DownloadViewModel) -> some View {
        // A row that is downloading lives at the top of the library list instead.
        let visible = vm.sortedRows.filter { row in !container.downloads.contains { $0.repoID == row.repoID } }
        ForEach(visible) { row in
            resultRow(row, vm)
            Divider()
        }
        if vm.isSearching {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(12)
        } else if visible.isEmpty, vm.searchError == nil {
            Text("Nothing found.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
        }
    }

    private func resultRow(_ row: DownloadViewModel.Row, _ vm: DownloadViewModel) -> some View {
        let verdict = vm.verdict(for: row)
        let installed = container.models.contains { $0.repoID.lowercased() == row.repoID.lowercased() }
        return HStack(spacing: 14) {
            rowText(
                source: row.source, owners: row.owners, repoID: row.repoID, sizeBytes: row.sizeBytes, quantization: row.quantization,
                detail: detail(repoID: row.repoID, kind: row.kind, contextLength: row.contextLength), gated: row.isGated)
            Spacer(minLength: 8)
            // The reason is a plain tooltip; the app shortens the system tooltip delay so it appears as soon as the pointer stops.
            Image(systemName: verdict.symbol)
                .font(.system(size: Self.pictogramSize))
                .foregroundStyle(.secondary)  // monochrome: the shape (check, question mark, triangle) carries the verdict
                .help(verdict.detail)
                .accessibilityLabel(verdict.detail)
            if installed {
                Image(systemName: "checkmark").font(.system(size: Self.pictogramSize)).foregroundStyle(.secondary).frame(width: 24)
                    .help(String(localized: "Installed"))
            } else {
                symbolButton("arrow.down.circle", String(localized: "Download")) {
                    container.download(repoID: row.repoID, title: row.title, quantization: row.quantization, sizeBytes: row.sizeBytes)
                }
            }
        }
        .padding(.vertical, 12)
    }

    /// Left: the model's icon, two lines tall. Line 1: model name (large), size and quantization. Line 2: full identifier with its
    /// owner, input → output, maximum context. The first line is a single attributed Text so every part shares one baseline.
    private func rowText(
        source: ModelSource?, owners: ModelOwners?, repoID: String, sizeBytes: Int64?, quantization: String?, detail: String,
        gated: Bool = false
    ) -> some View {
        var line = AttributedString()
        var name = AttributedString(repoID.split(separator: "/").last.map(String.init) ?? repoID)
        name.font = .title3.weight(.semibold)
        var facts: [String] = []
        if let sizeBytes, sizeBytes > 0 { facts.append(sizeBytes.fileSizeText) }
        if let quantization, !quantization.isEmpty { facts.append(quantization) }
        var tail = AttributedString(facts.isEmpty ? "" : "   " + facts.joined(separator: "   "))
        tail.font = .body
        tail.foregroundColor = .secondary
        line.append(name)
        line.append(tail)
        return HStack(alignment: .center, spacing: 12) {
            if let source { ModelIconView(owners: owners, source: source, size: 24) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(line).font(.title3).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if gated { Image(systemName: "lock.fill").foregroundStyle(.secondary).help(String(localized: "Gated: requires token")) }
                }
                if !detail.isEmpty {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// "lmstudio-community/Qwen3-8B-MLX-4bit · text, images → text · up to 32k context".
    /// Whether a drafter is installed for a model, and whether it is in use: the row says so in words, the pictogram
    /// repeats it, so a model with MTP is told apart at a glance.
    enum DrafterMark { case none, off, on }

    private func detail(repoID: String, kind: ModelKind?, contextLength: Int?, drafter: DrafterMark = .none) -> String {
        var parts = [repoID]
        if let kind { parts.append(kind == .vlm ? String(localized: "text, images → text") : String(localized: "text → text")) }
        if let contextLength, contextLength > 0 { parts.append(String(localized: "up to \(contextLength / 1024)k context")) }
        switch drafter {
        case .none: break
        case .off: parts.append(String(localized: "MTP off"))
        case .on: parts.append(String(localized: "MTP"))
        }
        return parts.joined(separator: " · ")
    }

    // Library: always visible. Running and waiting downloads come first, then the downloaded models.

    /// One rounded glass card anchored at the bottom, the same shape as the chat composer. Downloaded and downloading models
    /// are always shown in full; it scrolls only if they cannot fit in the window at all.
    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Downloaded Models").font(.headline).padding(.bottom, 4)
            ViewThatFits(in: .vertical) {
                libraryRows
                ScrollView { libraryRows }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassCard(radius: 22)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
    }

    /// Downloads of models that are not installed yet get rows of their own; an update of an installed model is shown
    /// inside that model's row instead.
    private var newDownloads: [AppContainer.ActiveDownload] {
        let installed = Set(container.models.map { $0.repoID.lowercased() })
        return container.orderedDownloads.filter { !installed.contains($0.repoID.lowercased()) }
    }

    private var installedModels: [ModelDescriptor] { container.models }

    private var libraryRows: some View {
        VStack(spacing: 0) {
            let downloads = newDownloads
            ForEach(Array(downloads.enumerated()), id: \.element.id) { index, download in
                if index > 0 { Divider() }
                downloadRow(download)
            }
            ForEach(Array(installedModels.enumerated()), id: \.element.id) { index, model in
                if index > 0 || !downloads.isEmpty { Divider() }
                installedRow(model)
            }
            // A broken model being downloaded again already has its download row above.
            let broken = container.brokenModels.filter { model in
                let repoID = ModelReference(directoryName: model.id)?.repoID.lowercased()
                return !downloads.contains { $0.repoID.lowercased() == repoID }
            }
            ForEach(Array(broken.enumerated()), id: \.element.id) { index, model in
                if index > 0 || !downloads.isEmpty || !installedModels.isEmpty { Divider() }
                brokenRow(model)
            }
            ForEach(Array(container.strayDrafters.enumerated()), id: \.element.id) { _, drafter in
                Divider()
                strayDrafterRow(drafter)
            }
            ForEach(Bindable(viewModel).remoteDrafts) { $draft in
                Divider()
                RemoteDraftRow(
                    draft: $draft, onSave: { viewModel.saveRemote(draft.id) }, onCancel: { viewModel.cancelRemote(draft.id) })
            }
            if installedModels.isEmpty, downloads.isEmpty, broken.isEmpty, viewModel.remoteDrafts.isEmpty {
                Text("No models yet. Click the empty search field to see recommended models, or search a hub.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
    }

    /// A folder that cannot be loaded, as in the status menu's "Damaged": download it again (resumes) or delete it.
    /// A drafter that was downloaded as if it were a model: it holds prediction heads only, so it answers nothing and
    /// waits here until its model is installed, at which point it attaches by itself.
    private func strayDrafterRow(_ drafter: ModelDescriptor) -> some View {
        HStack(alignment: .center, spacing: 14) {
            rowText(
                source: drafter.source, owners: drafter.owners, repoID: drafter.repoID, sizeBytes: drafter.sizeBytes,
                quantization: drafter.quantization,
                detail: drafter.baseModel.map { String(localized: "MTP drafter · attaches itself to \($0)") }
                    ?? String(localized: "MTP drafter · not a chat model"))
            Spacer(minLength: 8)
            Image(systemName: "bolt").font(.system(size: Self.pictogramSize)).foregroundStyle(.secondary)
            symbolButton("trash", String(localized: "Delete Model"), role: .destructive) { container.deleteStrayDrafter(drafter) }
        }
        .padding(.vertical, 12)
    }

    private func brokenRow(_ model: ModelCatalog.BrokenModel) -> some View {
        let reference = ModelReference(directoryName: model.id)
        return HStack(alignment: .center, spacing: 14) {
            rowText(
                source: reference?.source, owners: reference.map { ModelOwners(repoID: $0.repoID, baseModel: nil) },
                repoID: reference?.repoID ?? model.id, sizeBytes: nil, quantization: nil,
                detail: String(localized: "Damaged — download again or delete"))
            Spacer(minLength: 8)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: Self.pictogramSize)).foregroundStyle(.secondary)
                .help(model.reason)
            if reference != nil {
                symbolButton("arrow.down.circle", String(localized: "Download Again")) { container.redownload(model) }
            }
            symbolButton("trash", String(localized: "Delete Model"), role: .destructive) { container.deleteBroken(model) }
        }
        .padding(.vertical, 12)
    }

    private func installedRow(_ model: ModelDescriptor) -> some View {
        let update = container.downloads.first { $0.repoID.lowercased() == model.repoID.lowercased() }
        // A model connected by API whose server does not answer: greyed out like in the menu, with a button to check again.
        let unavailable = !container.isAvailable(model)
        // Spelled out rather than nested in the call: the type checker gives up on the expression otherwise.
        var drafter = DrafterMark.none
        if container.drafterIsInstalled(for: model) { drafter = container.isSpeculative(model) ? .on : .off }
        // No context here: this row has a menu for it, and the number would only repeat what the menu shows.
        let detailText = detail(repoID: model.repoID, kind: model.kind, contextLength: nil, drafter: drafter)
        return HStack(alignment: .center, spacing: 14) {
            rowText(
                source: model.source, owners: model.owners, repoID: model.repoID, sizeBytes: model.sizeBytes,
                quantization: model.quantization, detail: detailText
            )
            .opacity(unavailable ? 0.4 : 1)
            .layoutPriority(1)  // a narrow window shortens the controls on the right, not the model's name
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 14) {
                    contextPicker(model).disabled(unavailable)
                    temperaturePicker(model).disabled(unavailable)
                    reasoningButton(model)
                    if container.canSpeculate(model) { speculationButton(model) }
                    if model.source == .remote {
                        // Served elsewhere: nothing to update here, the server owns the model; only its availability is checked.
                        if unavailable {
                            let checking = container.isCheckingAvailability
                            symbolButton("arrow.clockwise", String(localized: "Check whether the server answers")) {
                                container.checkModelAvailability(force: true)
                            }
                            .symbolEffect(.rotate, isActive: checking)
                            .disabled(checking)
                        }
                    } else if let update {
                        // While the new revision downloads, the update pictogram turns into pause/continue and "cancel the update".
                        transferControls(update)
                        symbolButton("xmark.circle", String(localized: "Cancel Update")) { container.cancelDownload(repoID: update.repoID) }
                    } else {
                        // Always there: checks the hub for a newer revision of this model and downloads it when there is one.
                        let checking = container.updates.checkingModels.contains(model.repoID)
                        symbolButton(
                            "arrow.triangle.2.circlepath",
                            container.updates.pendingModelUpdates[model.repoID] != nil
                                ? String(localized: "Update available: click to download")
                                : String(localized: "Check for an update and download it")
                        ) {
                            container.updates.checkAndUpdate(model)
                        }
                        .symbolEffect(.rotate, isActive: checking)
                        .disabled(checking)
                    }
                    symbolButton("trash", String(localized: "Delete Model"), role: .destructive) { container.deleteModel(model) }
                        .disabled(update != nil)
                }
                if let update { updateProgress(update) }
                if unavailable {
                    Text("The server does not answer").font(.caption).foregroundStyle(.secondary)
                }
                if let status = updateStatus(model) {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 12)
    }

    /// Small progress line at the bottom right of an installed model's row while its update downloads.
    @ViewBuilder
    private func updateProgress(_ update: AppContainer.ActiveDownload) -> some View {
        HStack(spacing: 8) {
            switch update.phase {
            case .running:
                Text(
                    update.progress.map { $0.fraction.formatted(.percent.precision(.fractionLength(0))) } ?? String(localized: "Starting…"))
                ProgressView(value: update.progress?.fraction ?? 0).frame(width: 160)
            case .queued:
                Text("Waiting for the current download to finish")
            case .paused:
                Text("Paused")
                ProgressView(value: update.progress?.fraction ?? 0).frame(width: 160)
            case .failed(let message):
                Text(message).foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
            case .needsToken, .needsAccess:
                Text("Waiting for a Hugging Face access token")
            case .finished:
                EmptyView()
            }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).controlSize(.small)
    }

    /// Context window saved for this model; sizes the model cannot reach are not offered. Drawn like the chat's model
    /// picker — a borderless menu showing just the current choice — so the row keeps its space for the model's name.
    private func contextPicker(_ model: ModelDescriptor) -> some View {
        let maximum = model.contextLength
        let sizes = [131_072, 65536, 32768, 16384, 8192, 4096].filter { size in maximum.map { size < $0 } ?? true }
        let saved = container.settings.modelContextTokens[model.id] ?? 0
        let chosen = sizes.contains(saved) ? saved : 0
        let maximumTitle = maximum.map { String(localized: "Maximum (\($0 / 1024)k)") } ?? String(localized: "Maximum")
        // The row in use carries the check mark, as the model menu does; 0 stands for the maximum.
        return CheckedMenu(
            items: [0] + sizes,
            isChosen: { $0 == chosen },
            choose: { container.setContextTokens($0, for: model) },
            row: { size in size == 0 ? Text(maximumTitle) : Text(verbatim: "\(size / 1024)k") }
        ) {
            Text(verbatim: chosen == 0 ? (maximum.map { "\($0 / 1024)k" } ?? String(localized: "Maximum")) : "\(chosen / 1024)k")
                .font(.callout)
        }
        .fixedSize()
        .help(String(localized: "Context window for this model"))
    }

    /// What the update check is doing or found, written under the row's controls the way an unreachable server is.
    private func updateStatus(_ model: ModelDescriptor) -> String? {
        if container.updates.checkingModels.contains(model.repoID) { return String(localized: "Checking for an update…") }
        if container.updates.pendingModelUpdates[model.repoID] != nil { return String(localized: "An update is available") }
        switch container.updates.modelCheckResults[model.repoID] {
        case .upToDate: return String(localized: "No update: the hub has the same revision")
        case .unreachable: return String(localized: "The hub did not answer")
        case .noRevision: return String(localized: "No recorded revision: download the model again to compare")
        case nil: return nil
        }
    }

    /// Sampling temperature saved for this model. Until one is picked the model answers with the temperature its own
    /// `generation_config.json` asks for, or MLX's default; a model served elsewhere, with its server's. Drawn like the
    /// context menu, so the row stays short.
    private func temperaturePicker(_ model: ModelDescriptor) -> some View {
        let standard = container.defaultTemperature(for: model)
        let chosen = container.temperature(for: model)
        // Only a drafter that cannot verify sampled tokens fixes the temperature at zero; others leave it alone.
        let greedy = container.isSpeculative(model) && container.drafterNeedsGreedy(model)
        let shown = greedy ? 0 : (chosen ?? standard?.value)
        let choices: [Double?] = [nil] + Self.temperatures.map { Optional($0) }
        return CheckedMenu(
            items: choices,
            isChosen: { $0 == chosen },
            choose: { container.setTemperature($0, for: model) },
            row: { value in
                // A model served elsewhere keeps no config here, so there is nothing of its own to follow.
                value.map { Text(verbatim: Self.temperatureText($0)) }
                    ?? Text(
                        standard.map {
                            let text = Self.temperatureText($0.value)
                            return $0.fromModel ? String(localized: "From the model (\(text))") : String(localized: "Default (\(text))")
                        } ?? String(localized: "Set by the server"))
            }
        ) {
            Text(verbatim: (shown.map(Self.temperatureText) ?? "–") + "t").font(.callout)
        }
        .fixedSize()
        .disabled(greedy)
        .help(
            greedy
                ? String(localized: "This drafter only verifies greedy decoding, so the temperature stays at 0")
                : String(localized: "Sampling temperature for this model"))
    }

    /// The usual steps: exact answers at 0, everyday chat around 0.6–0.8, loose writing above 1.
    private static let temperatures: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2]

    private static func temperatureText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US")))
    }

    /// Whether the chat shows what this model says to itself before answering. Off by default: the thinking is long
    /// and it is not the answer.
    private func reasoningButton(_ model: ModelDescriptor) -> some View {
        let shown = container.showsReasoning(modelID: model.id)
        return symbolButton(
            shown ? "eye" : "eye.slash",
            shown ? String(localized: "The chat shows how this model thinks") : String(localized: "Show how this model thinks"),
            style: shown ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
        ) {
            container.setShowsReasoning(!shown, for: model)
        }
    }

    /// Multi-token prediction for this model: the drafter's weights, installed inside the model's folder, and greedy
    /// decoding, which its verification needs. Both live behind one pictogram, next to the context window.
    private func speculationButton(_ model: ModelDescriptor) -> some View {
        let installed = container.drafterIsInstalled(for: model)
        let on = installed && container.isSpeculative(model)
        let help =
            installed
            ? (on ? String(localized: "Faster answers are on") : String(localized: "A drafter is installed, MTP is off"))
            : String(localized: "Faster answers (MTP): needs a drafter for this model")
        return symbolButton(
            installed ? "bolt.fill" : "bolt", help,
            style: on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
        ) {
            drafterTarget = drafterTarget == model.id ? nil : model.id
            if drafterTarget != nil, !installed { findDrafters(for: model) }
        }
        .popover(
            isPresented: Binding(get: { drafterTarget == model.id }, set: { if !$0 { drafterTarget = nil } }), arrowEdge: .bottom
        ) {
            speculationSettings(model, installed: installed)
        }
    }

    private func speculationSettings(_ model: ModelDescriptor, installed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Faster answers (MTP)")).font(.headline)
            if installed {
                // Which drafter is in place, and the way back: removing it returns this window to the hub's list.
                HStack(spacing: 8) {
                    Text(verbatim: container.installedDrafterRepo(for: model) ?? String(localized: "Installed drafter"))
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    symbolButton("trash", String(localized: "Remove Drafter"), role: .destructive) {
                        container.removeDrafter(for: model)
                        findDrafters(for: model)
                    }
                }
                Toggle(
                    String(localized: "Draft several tokens per round"),
                    isOn: Binding(get: { container.isSpeculative(model) }, set: { container.setSpeculative($0, for: model) })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                Text(String(localized: "The model verifies every drafted token, so answers stay the same but stop varying."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let download = container.drafterDownload(for: model) {
                // Installing right now: the same row as any download, but said here, where the button was pressed.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: download.repoID).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                if let error = download.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let progress = download.progress, progress.bytesTotal > 0 {
                    ProgressView(value: Double(progress.bytesReceived), total: Double(progress.bytesTotal))
                }
            } else {
                Text(String(localized: "Prediction heads are published as a small separate repository for this checkpoint."))
                    .font(.caption).foregroundStyle(.secondary)
                if let verdict = container.drafterVerdict(for: model) {
                    Text(verdict).font(.caption).foregroundStyle(.red)
                }
                if drafterSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Looking for a drafter…")).font(.callout)
                    }
                } else if drafterCandidates.isEmpty {
                    Text(String(localized: "The hub lists no MLX drafter for this model.")).font(.callout)
                }
                // Found by the base model the hub records, so the repository never has to be typed out.
                // Picked like a model in the search list: the same pictogram starts the download.
                ForEach(drafterCandidates, id: \.self) { candidate in
                    HStack(spacing: 8) {
                        Text(verbatim: candidate).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        symbolButton("arrow.down.circle", String(localized: "Download")) {
                            container.installDrafter(repoID: candidate, for: model)
                            drafterTarget = nil
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 640, alignment: .leading)
    }

    /// Asks the hub which drafters were published for this checkpoint and keeps the ones that fit it.
    private func findDrafters(for model: ModelDescriptor) {
        drafterSearch?.cancel()
        drafterCandidates = []
        drafterSearching = true
        drafterSearch = Task {
            let found = await container.drafterCandidates(for: model)
            guard !Task.isCancelled else { return }
            drafterCandidates = found
            drafterSearching = false
        }
    }

    /// Top line: the model and, at the right, its controls. Below: the progress bar across the full width, then the status text.
    private func downloadRow(_ download: AppContainer.ActiveDownload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                // While downloading, the second line says where the files are going.
                rowText(
                    source: ModelReference.parse(download.repoID)?.source,
                    owners: ModelOwners(repoID: download.repoID, baseModel: nil), repoID: download.repoID,
                    sizeBytes: download.sizeBytes ?? download.progress?.bytesTotal, quantization: download.quantization,
                    detail: download.drafterFor.map { String(localized: "MTP drafter for \($0)") }
                        ?? viewModel.destination(for: download.repoID))
                Spacer(minLength: 8)
                downloadControls(download)
            }
            downloadStatus(download)
        }
        .padding(.vertical, 12)
    }

    /// Pictogram controls: pause/continue for the transfer, cancel for anything not finished.
    @ViewBuilder
    private func downloadControls(_ download: AppContainer.ActiveDownload) -> some View {
        HStack(spacing: 12) {
            transferControls(download)
            switch download.phase {
            case .failed, .needsToken, .needsAccess:
                symbolButton("arrow.clockwise.circle", String(localized: "Try Again")) {
                    container.download(
                        repoID: download.repoID, title: download.title, quantization: download.quantization, sizeBytes: download.sizeBytes)
                }
            case .running, .paused, .queued, .finished:
                EmptyView()
            }
            symbolButton("xmark.circle", String(localized: "Cancel")) { container.cancelDownload(repoID: download.repoID) }
        }
    }

    /// Pause and continue for a transfer in flight. A model still waiting its turn gets them too: Continue pushes it ahead
    /// of whatever is running, Pause takes it out of the queue until it is asked for again.
    @ViewBuilder
    private func transferControls(_ download: AppContainer.ActiveDownload) -> some View {
        switch download.phase {
        case .running:
            symbolButton("pause.circle", String(localized: "Pause")) { container.pauseDownload(repoID: download.repoID) }
        case .paused:
            symbolButton("play.circle", String(localized: "Continue")) { container.resumeDownload(repoID: download.repoID) }
        case .queued:
            symbolButton("play.circle", String(localized: "Download this one first")) { container.resumeDownload(repoID: download.repoID) }
            symbolButton("pause.circle", String(localized: "Pause")) { container.pauseDownload(repoID: download.repoID) }
        case .failed, .needsToken, .needsAccess, .finished:
            EmptyView()
        }
    }

    @ViewBuilder
    private func downloadStatus(_ download: AppContainer.ActiveDownload) -> some View {
        switch download.phase {
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        case .needsToken:
            Text("Waiting for a Hugging Face access token").font(.caption).foregroundStyle(.secondary)
        case .needsAccess:
            redLink(
                String(localized: "Your Hugging Face account has no access to this model yet. Click to open its page and request access.")
            ) {
                if let url = URL(string: "https://huggingface.co/\(download.repoID)") { NSWorkspace.shared.open(url) }
            }
        case .finished:
            Text("Done").font(.caption).foregroundStyle(.green)
        case .queued:
            Text("Waiting for the current download to finish").font(.caption).foregroundStyle(.secondary)
        case .paused:
            ProgressView(value: download.progress?.fraction ?? 0)
            Text("Paused").font(.caption).foregroundStyle(.secondary)
        case .running:
            if let p = download.progress, p.bytesTotal > 0 {  // until the hub has reported the size there is nothing to show
                ProgressView(value: p.fraction)
                Text(
                    verbatim:
                        "\(p.fraction.formatted(.percent.precision(.fractionLength(0)))) · \(p.bytesReceived.fileSizeText) / \(p.bytesTotal.fileSizeText) · \(Int64(p.bytesPerSecond).fileSizeText)/s · \(p.currentFile)"
                )
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                ProgressView().progressViewStyle(.linear)
                Text("Starting…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func redLink(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.caption).foregroundStyle(.red).underline().multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    /// Shared by every pictogram in the lists (actions, verdicts, marks); halved from 28 pt at the customer's request.
    private static let pictogramSize: CGFloat = 14

    /// The shared `SymbolButton` with this window's pictogram size and short argument labels.
    private func symbolButton(
        _ symbol: String, _ help: String, role: ButtonRole? = nil, style: AnyShapeStyle = AnyShapeStyle(.secondary),
        action: @escaping () -> Void
    ) -> some View {
        SymbolButton(symbol: symbol, help: help, role: role, size: Self.pictogramSize, style: style, action: action)
    }
}

// TokenSettingsView

/// The Hugging Face access token is a secret and cannot live in a menu, so it stays in a popover of the models section.
/// The popover also opens by itself whenever a download needs the token; saving it resumes those downloads.
struct TokenSettingsView: View {
    @Binding var isPresented: Bool
    @Environment(AppContainer.self) private var container
    @State private var hfToken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Hugging Face Access Token").font(.headline)
                Spacer()
                // The globe opens the page where a token is created.
                Button {
                    if let url = URL(string: "https://huggingface.co/settings/tokens") { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "globe").font(.title3)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link)
                .help(String(localized: "Get a token on huggingface.co"))
                .accessibilityLabel(String(localized: "Get a token on huggingface.co"))
            }
            Text("Needed only for gated models. Create a token with the Read role and paste it here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(String(localized: "Access token"), text: $hfToken, prompt: Text(verbatim: "hf_…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button(String(localized: "Save Token"), action: save).buttonStyle(.glass)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { hfToken = container.settings.huggingFaceToken ?? "" }
        // Coming back from the browser with a copied token: offer it right away.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if hfToken.isEmpty, let copied = NSPasteboard.general.string(forType: .string), copied.hasPrefix("hf_") {
                hfToken = copied.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func save() {
        container.saveHuggingFaceTokenAndRetry(hfToken)
        isPresented = false
    }
}

// RemoteDraftRow

/// "Connect by API" row in the models card: the model's name, then the server address and an optional token.
/// Save checks the server and the model; on success the row turns into an ordinary model row.
private struct RemoteDraftRow: View {
    @Binding var draft: DownloadViewModel.RemoteDraft
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "network").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                TextField(String(localized: "Model name"), text: $draft.name)
                    .textFieldStyle(.roundedBorder).font(.title3)
                HStack(spacing: 8) {
                    TextField(String(localized: "Address and port, e.g. http://localhost:8080"), text: $draft.address)
                        .textFieldStyle(.roundedBorder)
                    SecureField(String(localized: "Token (optional)"), text: $draft.token)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                if let error = draft.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
            .disabled(draft.isSaving)
            if draft.isSaving {
                ProgressView().controlSize(.small).frame(width: 24)
            } else {
                SymbolButton(
                    symbol: "checkmark.circle", help: String(localized: "Save: check the model on the server and add it"),
                    action: onSave
                )
                .disabled(
                    draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.address.trimmingCharacters(in: .whitespaces).isEmpty
                )
                .keyboardShortcut(.defaultAction)
            }
            SymbolButton(symbol: "xmark.circle", help: String(localized: "Cancel"), action: onCancel)
        }
        .padding(.vertical, 12)
    }
}
