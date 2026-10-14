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
    @State private var transcriptHeight: CGFloat = 0
    @State private var controlsHeight: CGFloat = 52
    @FocusState private var inputFocused: Bool

    var body: some View {
        // Transcript above, newest exchange right over the field.
        VStack(spacing: 0) {
            if hasTranscript {
                transcript
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
        !viewModel.messages.isEmpty || !viewModel.visibleStreamingText.isEmpty || viewModel.progress != nil
            || viewModel.errorMessage != nil
    }

    // Input

    // Model comes from the status menu.
    private var inputRow: some View {
        HStack(alignment: .center, spacing: 10) {
            // New chat button, styled like the chats window's.
            Button(action: viewModel.clear) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(.secondary)
            .keyboardShortcut("k", modifiers: .command)
            .help(String(localized: "New Chat"))
            .disabled(viewModel.messages.isEmpty && viewModel.streamingText.isEmpty && viewModel.input.isEmpty)
            if container.settings.voiceInputEnabled {
                VoiceInputButton(text: $viewModel.input, disabled: viewModel.isGenerating) { viewModel.send() }
                    .buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(.secondary)
            }
            TextField(String(localized: "Ask a question…"), text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .lineLimit(1...6)
                .padding(.horizontal, 10).padding(.vertical, 8)  // air around the typed text, equal above and below
                .focused($inputFocused)
                .onSubmit { viewModel.send() }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }  // Shift+Enter inserts a newline
                    viewModel.send()
                    return .handled
                }
            HStack(spacing: 12) {
                EngineActivityControl(state: viewModel.engineState, onStop: viewModel.stop)
                contextUsage
                // Documents work with any model, images only with a VLM (the dialog offers them then).
                Button(action: onChooseFiles) {
                    Image(systemName: "paperclip")
                }
                .help(String(localized: "Attach file"))
                Button {
                    container.openInChats(viewModel.chat?.id)
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .help(String(localized: "Open in Chats"))
            }
            .buttonStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var contextUsage: some View {
        if let limit = viewModel.contextLimit, limit > 0 {
            let used = min(viewModel.contextUsed, limit)
            Text(verbatim: ChatMessageView.contextLeft(limit - used))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(used > limit * 9 / 10 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .help(String(localized: "Context left for this chat, estimated"))
        }
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(viewModel.pendingImages) { img in
                    AttachmentThumbnail(image: img.thumbnail, side: 56) { viewModel.removeImage(img.id) }
                }
                ForEach(viewModel.pendingDocuments, id: \.name) { doc in
                    DocumentChip(name: doc.name) { viewModel.removeDocument(doc.name) }
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    // Transcript

    private var exchanges: [[Message]] {
        var groups: [[Message]] = []
        for message in viewModel.messages where message.role != .system && message.role != .tool {
            if message.role == .user || groups.isEmpty { groups.append([message]) } else { groups[groups.count - 1].append(message) }
        }
        return groups
    }

    private var transcript: some View {
        // All messages: maps ride on hidden tool results.
        let maps = TranscriptMaps.byAnswer(viewModel.messages)
        return ScrollView {
            // Not lazy: a lazy stack in a tiny viewport mismeasured rows.
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(exchanges.enumerated()), id: \.offset) { index, exchange in
                    if index > 0 { Divider() }
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
                TranscriptTail(
                    progress: viewModel.progress, engineState: viewModel.engineState, errorMessage: viewModel.errorMessage
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
            // Top inset clears the rounded glass edge.
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                transcriptHeight = $0
            }
        }
        // Follow the end while the user has not scrolled up.
        .followsTranscriptEnd(jumpOn: viewModel.transcriptToken)
        // Grows with the text up to the panel's limit, then scrolls.
        .frame(height: min(max(transcriptHeight, 1), max(viewModel.heightLimit - controlsHeight - 1, 64)))
    }

    private func isStreamedPlaceholder(_ message: Message) -> Bool {
        viewModel.isGenerating && message.id == viewModel.messages.last?.id && message.role == .assistant && message.toolCalls.isEmpty
    }

}

// FieldCaret

@MainActor
enum FieldCaret {
    static func moveToEnd() {
        Task { @MainActor in (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
    }
}

// EngineActivityControl

struct EngineActivityControl: View {
    let state: EngineState
    var onStop: () -> Void

    var body: some View {
        switch state {
        case .unloaded, .ready:
            EmptyView()
        case .loading(_, let progress):
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 2.5)
                Circle().trim(from: 0, to: max(0.03, progress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: progress)
            }
            .frame(width: 16, height: 16)
            .help(String(localized: "Loading model… \(progress.formatted(.percent.precision(.fractionLength(0))))"))
        case .generating(_, _, let tps):
            // This row only stops the answer; progress is in the transcript.
            HStack(spacing: 8) {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .help(String(localized: "Generating · \(Int(tps)) tok/s — click to stop"))
            }
        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
        }
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
    @ScaledMetric(relativeTo: .body) private var scaledText: CGFloat = ChatMessageView.textSize
    let message: Message
    var summary: String?
    var maps: [TranscriptMap] = []
    @Environment(AppContainer.self) private var container

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
                    // Tool-asking replies have no answer of their own.
                    if message.toolCalls.isEmpty {
                        AnswerBody(message: message, answer: answer, fontSize: scaledText, noAnswerPadding: 10)
                        ForEach(Array(maps.enumerated()), id: \.offset) { _, map in TranscriptMapView(map: map, height: 170) }
                    }
                }
                if message.role == .assistant, message.toolCalls.isEmpty, !message.isPartial,
                    let pace = ChatMessageView.pace(
                        tokensPerSecond: message.tokensPerSecond, tokens: message.completionTokens, limit: nil)
                {
                    PaceText(pace: pace)
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
