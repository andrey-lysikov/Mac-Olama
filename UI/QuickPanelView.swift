//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

// QuickPanelView

struct QuickPanelView: View {
    @Bindable var viewModel: QuickPanelViewModel
    var onClose: () -> Void
    /// Reports the height the content wants, so the controller can grow the panel upwards as the answer streams in.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// Makes the panel key, so a file dropped from Finder can hand the keyboard to the field.
    var onMakeKey: () -> Void = {}
    /// The file dialog is run by the controller: it has to sit above the panel and keep the panel from auto-closing.
    var onChooseFiles: () -> Void = {}
    var onToggleAutoClose: () -> Void = {}
    @Environment(AppContainer.self) private var container
    @State private var transcriptHeight: CGFloat = 0
    /// Field plus attachment chips: whatever of the height limit is left goes to the transcript.
    @State private var controlsHeight: CGFloat = 52
    @FocusState private var inputFocused: Bool

    var body: some View {
        // Like a chat: the transcript above, the newest exchange at its bottom, right over the field.
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
        // Measured at its own height, not the window's: otherwise a wrapping field squeezes into the current panel
        // instead of growing it.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            onHeightChange($0)
        }
        // The window decides the width. If it is ever shorter than the content, the top of the transcript is cut, never the field.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Belt and braces: the hosting view already drops the title-bar safe area (`safeAreaRegions`).
        .ignoresSafeArea()
        // Any empty spot of the panel moves it; the field, buttons and the scrolling transcript keep their own clicks.
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
        // Nothing draws past the rounded panel, whatever a reply contains.
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Liquid Glass (macOS 26): system material, tint and light/dark follow the OS automatically.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onDrop(of: [.fileURL, .url, .image], isTargeted: nil) { providers in handleDrop(providers) }
        .onAppear { inputFocused = true }
        .onChange(of: viewModel.focusToken) { _, _ in
            inputFocused = true
            FieldCaret.moveToEnd()
        }
        // A new attachment (paste, drop, file picker, link) puts the caret in the field, ready for the question.
        .onChange(of: viewModel.pendingImages.count + viewModel.pendingDocuments.count) { old, new in
            guard new > old else { return }
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

    // The model is the one picked in the status menu; the row holds only the field and its pictograms.
    private var inputRow: some View {
        HStack(alignment: .center, spacing: 10) {
            // Attaching comes before the question, so it sits in front of the field; documents work with any model,
            // images only with a VLM (the dialog offers them then).
            Button(action: onChooseFiles) {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(.secondary)
            .help(String(localized: "Attach file"))
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
                Button {
                    container.openInChats(viewModel.chat?.id)
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .help(String(localized: "Open in Chats"))
                // Closed lock: the panel stays open when you click elsewhere.
                Button(action: onToggleAutoClose) {
                    Image(systemName: container.settings.panelClosesOnFocusLoss ? "lock.open" : "lock")
                }
                .help(
                    container.settings.panelClosesOnFocusLoss
                        ? String(localized: "Keep the panel open when you click outside it")
                        : String(localized: "Close the panel when you click outside it"))
                Button(action: viewModel.clear) {
                    Image(systemName: "eraser.line.dashed")
                }
                .keyboardShortcut("k", modifiers: .command)
                .help(String(localized: "Clear"))
                .disabled(viewModel.messages.isEmpty && viewModel.streamingText.isEmpty && viewModel.input.isEmpty)
            }
            .buttonStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(viewModel.pendingImages) { img in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: img.thumbnail)
                            .resizable().scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button {
                            viewModel.removeImage(img.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain).offset(x: 4, y: -4)
                    }
                }
                ForEach(viewModel.pendingDocuments, id: \.name) { doc in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        Text(doc.name).lineLimit(1)
                        Button {
                            viewModel.removeDocument(doc.name)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.plain)
                    }
                    .font(.caption).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    // Transcript

    /// Question-and-answer groups in chat order; the answer being streamed belongs to the last one.
    private var exchanges: [[Message]] {
        var groups: [[Message]] = []
        for message in viewModel.messages where message.role != .system && message.role != .tool {
            if message.role == .user || groups.isEmpty { groups.append([message]) } else { groups[groups.count - 1].append(message) }
        }
        return groups
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: in a viewport that starts one point tall a lazy stack renders only its bottom rows and guesses
                // the rest, so the question went missing and the measured height was wrong.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(exchanges.enumerated()), id: \.offset) { index, exchange in
                        if index > 0 { Divider() }
                        ForEach(Array(exchange.enumerated()), id: \.element.id) { position, message in
                            // Tool rounds fold into one summary line above the answer they led to.
                            if isStreamedPlaceholder(message) {
                                EmptyView()
                            } else if message.toolCalls.isEmpty {
                                MessageView(
                                    message: message,
                                    summary: message.role == .assistant
                                        ? AnswerText.summary(
                                            of: AnswerText.toolCalls(before: position, in: exchange),
                                            thoughtSeconds: viewModel.thoughtSeconds[message.id]) : nil)
                            } else if !AnswerText.isFoldedIntoAnswer(position, in: exchange) {
                                MessageView(message: message, summary: AnswerText.summary(of: message.toolCalls, thoughtSeconds: nil))
                            }
                        }
                    }
                    if let progress = viewModel.progress {
                        GenerationProgressView(progress: progress, engineState: viewModel.engineState)
                    }
                    if !viewModel.visibleStreamingText.isEmpty {
                        MessageView(
                            message: Message(chatID: UUID(), role: .assistant, text: viewModel.visibleStreamingText, isPartial: true))
                    }
                    if let error = viewModel.errorMessage {
                        // Why the answer did not come, in red where the answer would have been.
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // End of the newest answer: every scroll below goes here.
                    Color.clear.frame(height: 0).id("bottom")
                }
                // The extra top inset keeps the first lines clear of the rounded glass edge when scrolled to the start.
                .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    transcriptHeight = $0
                }
            }
            // A scroll view has no height of its own: it follows the text until the panel reaches its height limit,
            // then the text scrolls inside it.
            .frame(height: min(max(transcriptHeight, 1), max(viewModel.heightLimit - controlsHeight - 1, 64)))
            // Growing content stays pinned to its bottom, so the streamed answer never runs below the fold.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // The anchor above keeps the streamed answer in view; scrolling on every token as well made the view jump.
            .onChange(of: viewModel.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.progress?.steps.count) { _, _ in scrollToBottom(proxy) }
            // Opening the panel keeps the transcript it had last time: start at the newest exchange, not where it was left.
            .onChange(of: viewModel.transcriptToken) { _, _ in scrollToBottom(proxy) }
            // Questions put in the queue are pinned above the input: the transcript loses that much height, and
            // without this the end of the reply being written is pushed out of sight.
            .onChange(of: viewModel.queuedQuestions.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.isGenerating) { _, generating in
                guard !generating else { return }
                scrollToBottom(proxy)
            }
        }
    }

    /// The stored copy of the reply being written: the streamed text below stands for it, otherwise it shows as a stray "…".
    private func isStreamedPlaceholder(_ message: Message) -> Bool {
        viewModel.isGenerating && message.id == viewModel.messages.last?.id && message.role == .assistant && message.toolCalls.isEmpty
    }

    /// The last token, the panel growing and the stored message replacing the streamed one all land in different frames,
    /// so the scroll waits for the layout to settle before it reveals the end of the transcript.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            proxy.scrollTo("bottom", anchor: .bottom)  // no animation: it fought the panel growing at the same time
        }
    }

    // Images

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in viewModel.attach(fileURL: url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isWebURL else { return }
                    Task { @MainActor in viewModel.attach(webURL: url) }
                }
            } else if viewModel.canAttachImages, provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in viewModel.attach(image: image) }
                }
            }
        }
        return true
    }

}

// FieldCaret

/// A programmatic focus selects the whole text of a field; typing would replace it. The caret goes to the end instead.
@MainActor
enum FieldCaret {
    static func moveToEnd() {
        Task { @MainActor in (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
    }
}

// EngineActivityControl

/// Engine activity inside the input row: nothing when idle, a progress ring while loading, a Stop pictogram while generating.
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
            // The spinner says the model is working, the button next to it stops the answer.
            // Neither a spinner nor a counter here: the transcript above shows the reply being written, with its own
            // progress line. This row keeps the one thing it is for — stopping the answer.
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

/// Thumbnails and document chips of a stored message; shared by the panel and the chats window.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    @Environment(AppContainer.self) private var container

    var body: some View {
        if !attachments.isEmpty {
            HStack(spacing: 6) {
                ForEach(attachments) { att in
                    if att.kind == .document {
                        Label(att.displayName ?? "file", systemImage: "doc.text").font(.caption).padding(6)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    } else if let image = NSImage(contentsOf: container.paths.attachments.appendingPathComponent(att.relativePath)) {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

// NoAnswerLine

/// A finished reply with nothing to show (the model only thought, or derailed): said plainly instead of a blank space.
struct NoAnswerLine: View {
    var body: some View {
        Label(String(localized: "The model gave no answer. Ask again or rephrase the question."), systemImage: "exclamationmark.bubble")
            .font(.callout).foregroundStyle(.secondary)
    }
}

// MessageView

/// One message: plain text for the user, Markdown (code, tables) for the assistant.
struct MessageView: View {
    /// The same reading size as the chats window, the system's text size included.
    @ScaledMetric(relativeTo: .body) private var scaledText: CGFloat = ChatMessageView.textSize
    let message: Message
    /// What the tools and the thinking did on the way to this answer, one line above it.
    var summary: String?
    @Environment(AppContainer.self) private var container

    /// Reasoning channels and tool syntax are the model talking to itself; only the answer is shown and copied.
    private var answer: String { AnswerText.visible(message.text) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Half again the size they were: in the panel the mark says at a glance whose turn is being read.
            Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(message.role == .user ? .secondary : Color.accentColor)
                // The box is one line tall, so the mark sits on the first line of the text instead of below it.
                .frame(width: 30, height: scaledText * 1.3)
            VStack(alignment: .leading, spacing: 6) {
                AttachmentStrip(attachments: message.attachments)
                if message.role == .user {
                    // No inset on either side: the question and the answer start at one line, right after the mark.
                    Text(message.text).textSelection(.enabled).font(.system(size: scaledText))
                } else {
                    if let summary { ProgressSummaryLine(text: summary) }
                    // A reply that asked for tools has no answer of its own: its text is a preamble or echoed results.
                    if message.toolCalls.isEmpty {
                        if answer.isEmpty, !message.isPartial {
                            NoAnswerLine().padding(10)
                        } else {
                            // Same reading size as the chats window.
                            MarkdownView(markdown: answer.isEmpty ? "…" : answer, baseFontSize: scaledText)
                        }
                    }
                }
                if message.role == .assistant, message.toolCalls.isEmpty, !message.isPartial,
                    let pace = ChatMessageView.pace(
                        tokensPerSecond: message.tokensPerSecond, tokens: message.completionTokens, limit: nil)
                {
                    Text(verbatim: pace).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            // The column takes the width the panel has, so wide code or formulas scroll instead of widening the row.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 0)
            if message.role == .assistant, !message.isPartial, message.toolCalls.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(String(localized: "Copy"))
            }
        }
    }
}
