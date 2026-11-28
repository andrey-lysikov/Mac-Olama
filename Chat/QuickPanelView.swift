//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

// QuickPanelView

struct QuickPanelView: View {
    @Bindable var viewModel: QuickPanelViewModel
    var onClose: () -> Void
    var onHeightChange: (CGFloat) -> Void = { _ in }
    var onMakeKey: () -> Void = {}
    var onChooseFiles: () -> Void = {}
    @Environment(AppContainer.self) private var container
    @State private var controlsHeight: CGFloat = 52
    @State private var previewedImage: ConversationStreamCoordinator.PendingImage?
    @State private var previewedDocument: DocumentInput?
    @FocusState private var inputFocused: Bool

    var body: some View {
        // Transcript above, newest exchange right over the field.
        VStack(spacing: 0) {
            if viewModel.isLoadingChat {
                Text(String(localized: "Loading…"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                Divider().padding(.horizontal, 12)
            } else if hasTranscript {
                // Its own view: it does not read `input`, so typing never re-renders the transcript.
                PanelTranscript(viewModel: viewModel, controlsHeight: controlsHeight)
                Divider().padding(.horizontal, 12)
            }
            VStack(spacing: 0) {
                // Questions asked while the model works stay pinned over the field until their turn comes.
                if !viewModel.queuedQuestions.isEmpty {
                    QueuedQuestionsView(questions: viewModel.queuedQuestions, onRemove: viewModel.removeQueued)
                        .padding(.horizontal, 16).padding(.top, 10)
                }
                if !viewModel.pendingImages.isEmpty || !viewModel.pendingDocuments.isEmpty { attachmentsRow }
                inputRow
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                controlsHeight = $0
            }
        }
        // Measure at the content's own height so the panel grows.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            onHeightChange($0)
        }
        // Width comes from the window; if short, the transcript is cut, never the field.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Also dropped by the hosting view's `safeAreaRegions`.
        .ignoresSafeArea()
        // Empty areas drag the panel.
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
        // Nothing draws past the rounded panel, whatever a reply contains.
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Liquid Glass (macOS 26): system material, tint and light/dark follow the OS automatically.
        .glassCard(radius: 20)
        .attachmentDrop(
            acceptsImages: viewModel.canAttachImages,
            onFile: { viewModel.attach(fileURL: $0) },
            onWeb: { viewModel.attach(webURL: $0) },
            onImage: { viewModel.attach(image: $0) }
        )
        .onAppear { inputFocused = true }
        .onChange(of: viewModel.focusToken) { _, _ in
            inputFocused = true
            FieldCaret.moveToEnd()
        }
        .focusOnNewAttachment(count: viewModel.pendingImages.count + viewModel.pendingDocuments.count) {
            onMakeKey()
            inputFocused = true
            FieldCaret.moveToEnd()
        }
        .onKeyPress(.escape) {
            onClose(); return .handled
        }
    }

    private var hasTranscript: Bool {
        // Only coarse state: reading the streaming text here would re-render the whole
        // panel on every stream tick. The live tail inside the transcript covers the rest.
        !viewModel.messages.isEmpty || viewModel.isGenerating || viewModel.errorMessage != nil
    }

    // Input

    private var inputRow: some View {
        HStack(alignment: .center, spacing: 10) {
            // New chat button, styled like the chats window's.
            Button(action: viewModel.clear) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(.secondary)
            .keyboardShortcut("k", modifiers: .command)
            .disabled(viewModel.messages.isEmpty && !viewModel.isGenerating && viewModel.input.isEmpty)
            if container.settings.voiceInputEnabled {
                VoiceInputButton(text: $viewModel.input, disabled: viewModel.isGenerating) { viewModel.send() }
                    .buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(.secondary)
            }
            // Documents work with any model, images only with a VLM (the dialog offers them then).
            Button(action: onChooseFiles) {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(.secondary)
            TextField(String(localized: "Ask a question…"), text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.plain)
                // Follows ⌘+ / ⌘−, slightly larger than the transcript as before (15 at the base 13).
                .font(.system(size: container.settings.chatFontSize + 2, weight: .regular))
                .lineLimit(1...6)
                .padding(.horizontal, 10).padding(.vertical, 8)  // air around the typed text, equal above and below
                .focused($inputFocused)
                .disabled(viewModel.quotaBlocked)
                .onSubmit { viewModel.send() }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }  // Shift+Enter inserts a newline
                    viewModel.send()
                    return .handled
                }
            HStack(spacing: 12) {
                modelPicker
                ContextPermissionControl(
                    used: viewModel.contextUsed, limit: viewModel.contextLimit,
                    modelName: viewModel.activeModel?.name ?? String(localized: "No model"),
                    mode: viewModel.chat.map { container.permissionMode(for: $0.id) } ?? .ask,
                    compacting: viewModel.compacting,
                    canCompact: viewModel.chat != nil && !viewModel.isGenerating && !viewModel.messages.isEmpty
                        && !viewModel.compacting,
                    isEnabled: viewModel.chat != nil,
                    onMode: { mode in
                        guard let chatID = viewModel.chat?.id else { return }
                        container.setPermissionMode(mode, for: chatID)
                    },
                    onCompact: viewModel.compact)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func modelImage(_ model: ModelDescriptor) -> Image {
        _ = ModelIcons.shared.revision
        if container.isQuotaExhausted(model) { return Image(systemName: "exclamationmark.triangle") }
        return ModelIcons.shared.menuImage(for: model, size: 16).map { Image(nsImage: $0) } ?? Image(systemName: model.source.symbol)
    }

    // "gemma-4-e4b-it-mlx-4bit" shows as "gemma-4": size, variant and quantization tails only eat the field's room.
    private func compactName(_ model: ModelDescriptor) -> String {
        func isSuffix(_ part: Substring) -> Bool {
            let p = part.lowercased()
            if ["mlx", "gguf", "it", "instruct", "chat", "base"].contains(p) { return true }
            if p.hasPrefix("q"), p.dropFirst().first?.isNumber == true { return true }
            if p.hasSuffix("bit"), p.dropLast(3).allSatisfy(\.isNumber) { return true }
            for prefix in ["bf", "fp", "int", "iq"] where p.hasPrefix(prefix) {
                if p.dropFirst(prefix.count).allSatisfy(\.isNumber) { return true }
            }
            // Parameter counts: 4b, 31b, e4b, 1.5b, 70m.
            let size = p.hasPrefix("e") ? p.dropFirst() : p[...]
            if let last = size.last, last == "b" || last == "m" {
                let digits = size.dropLast()
                if !digits.isEmpty, digits.allSatisfy({ $0.isNumber || $0 == "." }), digits.contains(where: \.isNumber) { return true }
            }
            return false
        }
        let parts = model.name.split(separator: "-", omittingEmptySubsequences: false)
        guard let cut = parts.firstIndex(where: isSuffix), cut > 0 else { return model.name }
        return parts[..<cut].joined(separator: "-")
    }

    private var modelPicker: some View {
        // No check mark: the label already shows the model.
        Menu {
            ForEach(container.models, id: \.self) { m in
                Button {
                    container.chooseModel(m, chatID: viewModel.chat?.id)
                } label: {
                    Label {
                        Text(verbatim: m.name)
                    } icon: {
                        modelImage(m)
                            .foregroundStyle(container.isQuotaExhausted(m) ? AnyShapeStyle(.red) : container.isAvailable(m) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .labelStyle(.titleAndIcon)  // macOS 26 menus hide icons otherwise
                }
                // A model whose window cannot hold this chat is not a choice for it.
                .disabled(
                    !container.isAvailable(m)
                        || (container.contextTokens(for: m).map { viewModel.contextUsed > $0 } ?? false))
            }
            if container.models.isEmpty {
                Button(String(localized: "Model Library…")) { WindowManager.shared.openModels() }
            }
        } label: {
            if let model = viewModel.activeModel {
                Label {
                    Text(verbatim: compactName(model)).font(.callout).lineLimit(1).truncationMode(.middle)
                } icon: {
                    modelImage(model)
                        .foregroundStyle(container.isQuotaExhausted(model) ? AnyShapeStyle(.red) : container.isAvailable(model) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
                .foregroundStyle(container.isAvailable(model) ? .primary : .tertiary)
            } else {
                Text(String(localized: "No model")).font(.callout)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 160)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(viewModel.isGenerating)
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(viewModel.pendingImages) { img in
                    AttachmentThumbnail(
                        image: img.thumbnail, side: 56,
                        onPreview: { previewedImage = img },
                        onRemove: { viewModel.removeImage(img.id) }
                    )
                    .popover(isPresented: previewBinding(for: img)) {
                        ImagePreviewPopover(image: img.thumbnail, isPresented: previewBinding(for: img))
                    }
                }
                ForEach(viewModel.pendingDocuments, id: \.name) { doc in
                    DocumentChip(
                        name: doc.name,
                        onPreview: { previewedDocument = doc },
                        onRemove: { viewModel.removeDocument(doc.name) }
                    )
                    .popover(isPresented: previewBinding(for: doc)) {
                        DocumentPreviewPopover(document: doc, isPresented: previewBinding(for: doc))
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    private func previewBinding(for image: ConversationStreamCoordinator.PendingImage) -> Binding<Bool> {
        Binding(
            get: { previewedImage?.id == image.id },
            set: { if !$0, previewedImage?.id == image.id { previewedImage = nil } })
    }

    private func previewBinding(for document: DocumentInput) -> Binding<Bool> {
        Binding(
            get: { previewedDocument?.name == document.name },
            set: { if !$0, previewedDocument?.name == document.name { previewedDocument = nil } })
    }
}

// PanelTranscript

/// The panel's transcript, split out of `QuickPanelView` so that typing in the field
/// (which changes the observed `input`) never re-renders the heavy message list.
private struct PanelTranscript: View {
    @Bindable var viewModel: QuickPanelViewModel
    var controlsHeight: CGFloat
    @State private var transcriptHeight: CGFloat = 0
    @State private var historyLimit = 30
    // Derived once per `messages` change; streaming ticks must not recompute them.
    @State private var exchanges: [[Message]] = []
    @State private var maps: [UUID: [TranscriptMap]] = [:]

    private func rebuildDerived() {
        var groups: [[Message]] = []
        for message in viewModel.messages {
            if ToolApprovalRecord.isApproval(message) {
                groups.append([message])
            } else if message.role != .system && message.role != .tool {
                if message.role == .user || groups.isEmpty { groups.append([message]) } else { groups[groups.count - 1].append(message) }
            }
        }
        exchanges = groups
        maps = TranscriptMaps.byAnswer(viewModel.messages)
    }

    private func isStreamedPlaceholder(_ message: Message) -> Bool {
        viewModel.isGenerating && message.id == viewModel.messages.last?.id && message.role == .assistant && message.toolCalls.isEmpty
    }

    var body: some View {
        // Only the tail is rendered; scrolling to the top pulls in older exchanges.
        let shown = exchanges.suffix(historyLimit)
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // The summary replaces the older history for the model; a divider marks the cut for the reader.
                let compactedIndex = viewModel.chat?.compactedAt.flatMap { cut in
                    exchanges.firstIndex { exchange in exchange.contains { $0.createdAt > cut } }
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { index, exchange in
                    if index == compactedIndex {
                        CompactionDivider()
                    } else if index > 0 { Divider() }
                    ForEach(Array(exchange.enumerated()), id: \.element.id) { position, message in
                        TranscriptRow(
                            message: message, position: position, context: exchange,
                            isStreamedPlaceholder: isStreamedPlaceholder(message),
                            thoughtSeconds: viewModel.thoughtSeconds[message.id]
                        ) { message, summary in
                            MessageView(message: message, summary: summary, maps: maps[message.id] ?? [])
                        }
                    }
                }
                // Its own view: streaming ticks update the tail, not this message list.
                PanelStreamTail(viewModel: viewModel)
            }
            // Top inset clears the rounded glass edge.
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                transcriptHeight = $0
            }
            .scrollTargetLayout()
        }
        // Follow the end while the user has not scrolled up.
        .followsTranscriptEnd(jumpOn: viewModel.transcriptToken) {
            guard historyLimit < exchanges.count else { return }
            // Keep the exchange that was on screen in place after older ones arrive above it.
            let anchor = shown.first?.first?.id
            historyLimit += 30
            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
        }
        // Grows with the text up to the panel's limit, then scrolls.
        .frame(height: min(max(transcriptHeight, 1), max(viewModel.heightLimit - controlsHeight - 1, 64)))
        }
        .onAppear { rebuildDerived() }
        .onChange(of: viewModel.messages) { _, _ in rebuildDerived() }
        .onChange(of: viewModel.chat?.id) { _, _ in historyLimit = 30 }
    }
}

// PanelStreamTail

/// The live part of the panel transcript: progress, approvals, errors and the streaming reply.
/// Streaming ticks invalidate this view alone — the message list above stays untouched.
private struct PanelStreamTail: View {
    @Bindable var viewModel: QuickPanelViewModel
    @Environment(AppContainer.self) private var container

    var body: some View {
        TranscriptTail(
            progress: viewModel.progress, engineState: viewModel.engineState,
            // A persisted failure shows here too, with the retry button.
            errorMessage: viewModel.errorMessage ?? viewModel.messages.last?.failure,
            approvals: NotificationService.shared.approvals(for: viewModel.chat?.id),
            onRetry: { viewModel.retryFailed() }
        ) {
            // While the model's thinking is shown, the raw stream goes in and the view splits it.
            let thinkingShown = viewModel.activeModel.map { container.showsReasoning(modelID: $0.id) } ?? false
            if !viewModel.visibleStreamingText.isEmpty || (thinkingShown && !viewModel.streamingText.isEmpty) {
                MessageView(
                    message: Message(
                        chatID: UUID(), role: .assistant,
                        text: thinkingShown ? viewModel.streamingText : viewModel.visibleStreamingText, isPartial: true,
                        modelID: thinkingShown ? viewModel.activeModel?.id : nil))
            }
        }
    }
}

// FieldCaret

@MainActor
enum FieldCaret {
    static func moveToEnd() {
        Task { @MainActor in (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
    }
}

// AttachmentStrip

struct AttachmentStrip: View {
    let attachments: [Attachment]
    @Environment(AppContainer.self) private var container

    var body: some View {
        if !attachments.isEmpty {
            HStack(spacing: 6) {
                ForEach(attachments) { att in
                    if att.kind == .document {
                        DocumentChip(name: att.displayName ?? "file")
                    } else if let image = NSImage(contentsOf: container.paths.attachments.appendingPathComponent(att.relativePath)) {
                        ZoomableThumbnail(image: image, side: 64)
                    }
                }
            }
        }
    }
}

// NoAnswerLine

struct NoAnswerLine: View {
    var body: some View {
        Label(String(localized: "The model gave no answer. Ask again or rephrase the question."), systemImage: "exclamationmark.bubble")
            .font(.callout).foregroundStyle(.secondary)
    }
}

// MessageView

struct MessageView: View {
    let message: Message
    var summary: String?
    var maps: [TranscriptMap] = []
    @Environment(AppContainer.self) private var container

    // ⌘+ / ⌘− change the setting; Observation re-renders every message at once.
    private var scaledText: CGFloat { container.settings.chatFontSize }

    private var answer: String { AnswerText.visible(message.text) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Larger mark for whose turn it is.
            Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(message.role == .user ? .secondary : Color.accentColor)
                // One line tall so the mark aligns with the first line.
                .frame(width: 30, height: scaledText * 1.3)
            VStack(alignment: .leading, spacing: 6) {
                AttachmentStrip(attachments: message.attachments)
                if message.role == .user {
                    // Text starts right after the mark.
                    Text(message.text).textSelection(.enabled).font(.system(size: scaledText))
                } else {
                    if let summary { ProgressSummaryLine(text: summary) }
                    ReasoningBlock(message: message, fontSize: scaledText)
                    // Keep the model's rationale visible when it precedes tool calls.
                    if message.toolCalls.isEmpty || !answer.isEmpty {
                        AnswerBody(message: message, answer: answer, fontSize: scaledText, noAnswerPadding: 10)
                        ForEach(Array(maps.enumerated()), id: \.offset) { _, map in TranscriptMapView(map: map, height: 170) }
                    }
                }
                if message.role == .assistant, message.toolCalls.isEmpty, !message.isPartial {
                    VStack(alignment: .leading, spacing: 2) {
                        if let pace = ChatMessageView.pace(
                            tokensPerSecond: message.tokensPerSecond, tokens: message.completionTokens, limit: nil)
                        {
                            PaceText(pace: pace)
                        }
                        TokenUsageView(message: message)
                    }
                }
            }
            // Fill the width so wide content scrolls.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 0)
            if message.role == .assistant, !message.isPartial, message.toolCalls.isEmpty {
                CopyButton(text: answer).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }
}
