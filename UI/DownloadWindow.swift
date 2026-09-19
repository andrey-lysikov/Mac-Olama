//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
import SwiftUI

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
                return Image(nsImage: Self.rounded(avatar, side: 14))
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

        /// The picker is drawn by AppKit: the logo goes in as a small rounded image.
        @MainActor private static func rounded(_ image: NSImage, side: CGFloat) -> NSImage {
            NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22).addClip()
                image.draw(in: rect)
                return true
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
        var address = "http://localhost:11434"
        var token = ""
        var isSaving = false
        var error: String?
    }

    private let container: AppContainer
    var hub: Hub = .huggingFace
    var remoteDrafts: [RemoteDraft] = []
    var query = ""
    /// On by default: only MLX builds are listed. Off widens the search to every repository (MLX builds still come first).
    var mlxOnly = true { didSet { if mlxOnly != oldValue, hasSearched { search() } } }
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
            ? try await container.hubClient.search(query: parts[1], author: parts[0], limit: 40, mlxOnly: mlxOnly)
            : try await container.hubClient.search(query: q, limit: 40, mlxOnly: mlxOnly)
        try Task.checkCancellation()
        rows = found.filter { !mlxOnly || $0.isMLX }.map {
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
        let found = try await container.modelScopeClient.search(query: q, limit: 40, mlxOnly: mlxOnly)
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
            rows[i].detailsLoaded = true
        }
    }

    private func apply(info: HubModelInfo, classification: HubModelClassification?, to row: inout Row) {
        row.sizeBytes = info.totalBytes
        row.quantization = classification?.quantization
        row.kind = classification?.kind
        row.contextLength = classification?.contextLength
        row.detailsLoaded = true
    }

    // Order: MLX builds first, then models that fit, the uncertain ones, those that will not run; newest first inside each group.

    var sortedRows: [Row] {
        func rank(_ row: Row) -> Int {
            switch verdict(for: row) {
            case .fits: 0
            case .unknown: 1
            case .tooLarge: 2
            }
        }
        return rows.enumerated().sorted { a, b in
            if a.element.isMLX != b.element.isMLX { return a.element.isMLX }
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
        let fit = ModelFitReport.evaluate(modelBytes: bytes, contextLength: row.contextLength, hardware: hardware)
        let machine = "\(hardware.chipName), \(hardware.memoryGB) GB"
        let needed = ByteCountFormatter.string(fromByteCount: Int64(hardware.memoryBytes) - fit.memoryAfterLoadBytes, countStyle: .memory)
        let limit = ByteCountFormatter.string(fromByteCount: Int64(hardware.wiredLimitBytes), countStyle: .memory)
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
        let speed = Int(fit.estimatedTokensPerSecond)
        if fit.fit == .tight {
            return .unknown(
                String(localized: "Fits, but tightly: needs about \(needed) of \(limit); expect ~\(speed) tok/s and little memory left."))
        }
        let left = ByteCountFormatter.string(fromByteCount: max(0, fit.memoryAfterLoadBytes), countStyle: .memory)
        return .fits(String(localized: "Fits \(machine): ~\(speed) tok/s, about \(left) left for the system."))
    }

    func destination(for repoID: String) -> String {
        guard let reference = ModelReference.parse(repoID) else { return "" }
        return (container.paths.models.appendingPathComponent(reference.directoryName).path as NSString).abbreviatingWithTildeInPath
    }
}

// ModelLibraryView

/// Model library, shown in the detail area of the chats window: hub search in the toolbar, results on top,
/// and a permanent list of downloaded models at the bottom with running downloads above them.
struct ModelLibraryView: View {
    @Environment(AppContainer.self) private var container
    @State private var viewModel: DownloadViewModel?
    @State private var showsSettings = false

    var body: some View {
        Group {
            if let viewModel { content(viewModel) } else { ProgressView().onAppear { viewModel = DownloadViewModel(container: container) } }
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
        // Any action that hits a gated repository opens the token popover, exactly as if the key button had been pressed.
        .onChange(of: container.tokenPromptRequested, initial: true) { _, requested in
            guard requested else { return }
            showsSettings = true
            container.tokenPromptRequested = false
        }
        // No window title here: the search group starts at the left edge of the detail column.
        .toolbar(removing: .title)
        .toolbar {
            // Fixed spacers keep every control in its own glass capsule; without them macOS 26 merges neighbours into one.
            ToolbarItem(placement: .navigation) {
                Picker(String(localized: "Hub"), selection: $vm.hub) {
                    ForEach(DownloadViewModel.Hub.allCases) { hub in
                        Label {
                            Text(verbatim: hub.title)
                        } icon: {
                            hub.icon
                        }
                        // Toolbars default to icon-only labels; the hub names must stay visible.
                        .labelStyle(.titleAndIcon)
                        .tag(hub)
                    }
                }
                .labelsHidden().fixedSize()
            }
            ToolbarSpacer(.fixed, placement: .navigation)
            // The search capsule holds the field and, inside it on the right, the magnifier that runs the search.
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    // VERIFY(macOS26): suggestions are expected to drop down as soon as the empty field gets focus.
                    TextField(vm.hub.prompt, text: $vm.query)
                        .textFieldStyle(.plain).frame(minWidth: 120, idealWidth: 280, maxWidth: 280)
                        // Without a placeholder the field would reach VoiceOver unlabelled.
                        .accessibilityLabel(String(localized: "Search"))
                        .textInputSuggestions {
                            if vm.query.isEmpty {
                                ForEach(vm.suggestions, id: \.self) { name in
                                    Text(verbatim: name).textInputCompletion(name)
                                }
                            }
                        }
                        .onChange(of: vm.query) { _, _ in vm.queryChanged() }
                        .onSubmit { vm.search() }
                    // "Connect by API" adds a model instead of searching: a check mark, not a magnifier.
                    Button {
                        vm.search()
                    } label: {
                        Image(systemName: vm.hub == .api ? "checkmark.circle" : "magnifyingglass")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(
                        vm.hub == .api
                            ? String(localized: "Add this model: enter its server address below")
                            : vm.hub == .link
                                ? String(localized: "Check that the model exists and show its size") : String(localized: "Search")
                    )
                    .accessibilityLabel(vm.hub == .api ? String(localized: "Add") : String(localized: "Search"))
                }
                .padding(.horizontal, 8)
            }
            ToolbarSpacer(.fixed, placement: .navigation)
            // A bare checkbox: no glass capsule of its own, and therefore nothing for the search capsule to merge with.
            ToolbarItem(placement: .navigation) {
                Toggle(String(localized: "MLX models only"), isOn: $vm.mlxOnly)
                    .toggleStyle(.checkbox)
                    .disabled(vm.hub == .link || vm.hub == .api)
                    .help(String(localized: "Show only models built for MLX. Turn off to search every repository; MLX builds stay on top."))
            }
            .sharedBackgroundVisibility(.hidden)
            // With the title removed nothing stretches between the groups, so the push to the right edge is explicit.
            ToolbarSpacer(.flexible)
            // The token button is the only control at the right edge.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsSettings.toggle()
                } label: {
                    Label(String(localized: "Hugging Face Token"), systemImage: "key")
                }
                .help(String(localized: "Access token for gated Hugging Face repositories"))
                .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                    TokenSettingsView(isPresented: $showsSettings).environment(container)
                }
            }
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
        if let sizeBytes, sizeBytes > 0 { facts.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)) }
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
    private func detail(repoID: String, kind: ModelKind?, contextLength: Int?) -> String {
        var parts = [repoID]
        if let kind { parts.append(kind == .vlm ? String(localized: "text, images → text") : String(localized: "text → text")) }
        if let contextLength, contextLength > 0 { parts.append(String(localized: "up to \(contextLength / 1024)k context")) }
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
            if let viewModel {
                ForEach(Bindable(viewModel).remoteDrafts) { $draft in
                    Divider()
                    RemoteDraftRow(
                        draft: $draft, onSave: { viewModel.saveRemote(draft.id) }, onCancel: { viewModel.cancelRemote(draft.id) })
                }
            }
            if installedModels.isEmpty, downloads.isEmpty, broken.isEmpty, viewModel?.remoteDrafts.isEmpty ?? true {
                Text("No models yet. Click the empty search field to see recommended models, or search a hub.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
    }

    /// A folder that cannot be loaded, as in the status menu's "Damaged": download it again (resumes) or delete it.
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
        return HStack(alignment: .center, spacing: 14) {
            rowText(
                source: model.source, owners: model.owners, repoID: model.repoID, sizeBytes: model.sizeBytes,
                quantization: model.quantization, detail: detail(repoID: model.repoID, kind: model.kind, contextLength: model.contextLength)
            )
            .opacity(unavailable ? 0.4 : 1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 14) {
                    contextPicker(model).disabled(unavailable)
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

    /// Context window saved for this model; sizes the model cannot reach are not offered.
    private func contextPicker(_ model: ModelDescriptor) -> some View {
        let maximum = model.contextLength
        let sizes = [131_072, 65536, 32768, 16384, 8192, 4096].filter { size in maximum.map { size < $0 } ?? true }
        let selection = Binding<Int>(
            get: {
                let saved = container.settings.modelContextTokens[model.id] ?? 0
                return sizes.contains(saved) ? saved : 0
            },
            set: { container.setContextTokens($0, for: model) })
        return Picker(String(localized: "Context"), selection: selection) {
            Text(maximum.map { String(localized: "Maximum (\($0 / 1024)k)") } ?? String(localized: "Maximum")).tag(0)
            ForEach(sizes, id: \.self) { Text(verbatim: "\($0 / 1024)k").tag($0) }
        }
        .labelsHidden().fixedSize()
        .help(String(localized: "Context window for this model"))
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
                    detail: viewModel?.destination(for: download.repoID) ?? "")
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
            if let p = download.progress {
                ProgressView(value: p.fraction)
                Text(
                    verbatim:
                        "\(p.fraction.formatted(.percent.precision(.fractionLength(0)))) · \(ByteCountFormatter.string(fromByteCount: p.bytesReceived, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: p.bytesTotal, countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: Int64(p.bytesPerSecond), countStyle: .file))/s · \(p.currentFile)"
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

    /// List actions are bare pictograms, not framed buttons.
    private func symbolButton(_ symbol: String, _ help: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol).font(.system(size: Self.pictogramSize)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
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
                    TextField(String(localized: "Address and port, e.g. http://localhost:11434"), text: $draft.address)
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
                Button(action: onSave) {
                    Image(systemName: "checkmark.circle").font(.system(size: 14)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(String(localized: "Save: check the model on the server and add it"))
                .disabled(
                    draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.address.trimmingCharacters(in: .whitespaces).isEmpty
                )
                .keyboardShortcut(.defaultAction)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle").font(.system(size: 14)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(String(localized: "Cancel"))
        }
        .padding(.vertical, 12)
    }
}
