//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

// QuickPanelView

struct QuickPanelView: View {
    @Bindable var viewModel: QuickPanelViewModel
    var onClose: () -> Void
    /// Reports the height the content wants, so the controller can grow the panel downwards as the answer streams in.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @State private var transcriptHeight: CGFloat = 0
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            if !viewModel.pendingImages.isEmpty || !viewModel.pendingDocuments.isEmpty { attachmentsRow }
            if hasTranscript {
                Divider().padding(.horizontal, 12)
                transcript
            }
        }
        .frame(maxWidth: .infinity)  // the window decides the width; the user can drag its edges
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            onHeightChange($0)
        }
        // Liquid Glass (macOS 26): system material, tint and light/dark follow the OS automatically.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onDrop(of: [.fileURL, .url, .image], isTargeted: nil) { providers in handleDrop(providers) }
        .onAppear { inputFocused = true }
        .onKeyPress(.escape) {
            onClose(); return .handled
        }
    }

    private var hasTranscript: Bool {
        !viewModel.messages.isEmpty || !viewModel.visibleStreamingText.isEmpty || viewModel.activity != nil
            || viewModel.errorMessage != nil
    }

    // Input

    // The model is the one picked in the status menu; the row holds only the field and its pictograms.
    private var inputRow: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField(String(localized: "Ask the local model…"), text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .lineLimit(1...6)
                .padding(10)  // air around the typed text inside the field
                .focused($inputFocused)
                .onSubmit { viewModel.send() }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }  // Shift+Enter inserts a newline
                    viewModel.send()
                    return .handled
                }
            HStack(spacing: 12) {
                EngineActivityControl(state: viewModel.engineState, onStop: viewModel.stop)
                if viewModel.canAttachImages {
                    Button {
                        chooseFile()
                    } label: {
                        Image(systemName: "photo.badge.plus")
                    }
                    .help(String(localized: "Attach image"))
                }
                Button {
                    WindowManager.shared.open(.chats)
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .help(String(localized: "Open in Chats"))
                .disabled(viewModel.messages.isEmpty)
                Button(action: viewModel.clear) {
                    Image(systemName: "xmark.circle")
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
        .padding(.vertical, 12)
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
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    // Transcript

    /// Panel only: the newest exchange is on top. Inside an exchange the order stays natural (question, then its answers),
    /// and the answer being streamed belongs to the newest one.
    private var exchanges: [[Message]] {
        var groups: [[Message]] = []
        for message in viewModel.messages where message.role != .system && message.role != .tool {
            if message.role == .user || groups.isEmpty { groups.append([message]) } else { groups[groups.count - 1].append(message) }
        }
        return groups.reversed()
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 0).id("top")
                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.callout)
                    }
                    ForEach(Array(exchanges.enumerated()), id: \.offset) { index, exchange in
                        ForEach(exchange) { message in MessageView(message: message) }
                        if index == 0, let activity = viewModel.activity { ToolActivityLine(activity: activity, isRunning: true) }
                        if index == 0, !viewModel.visibleStreamingText.isEmpty {
                            MessageView(
                                message: Message(chatID: UUID(), role: .assistant, text: viewModel.visibleStreamingText, isPartial: true))
                        }
                        // End of the newest answer: the anchor the view scrolls to once generation finishes.
                        if index == 0 { Color.clear.frame(height: 0).id("answerEnd") }
                        if index < exchanges.count - 1 { Divider() }
                    }
                }
                // The extra bottom inset keeps the last lines clear of the rounded glass edge when scrolled to the end.
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 24)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    transcriptHeight = $0
                }
            }
            // A scroll view has no height of its own: it follows the text until the panel reaches half of the screen,
            // then the text scrolls inside it.
            .frame(height: min(max(transcriptHeight, 1), max(viewModel.maxPanelHeight - 96, 64)))
            // A new question jumps back to the top, where the newest exchange is; the stored answer arrives through the
            // same change, so only a question moves the view.
            .onChange(of: viewModel.messages.count) { _, _ in
                if viewModel.messages.last?.role == .user { proxy.scrollTo("top", anchor: .top) }
            }
            // Opening the panel keeps the transcript it had last time: start at the newest exchange, not where it was left.
            .onChange(of: viewModel.transcriptToken) { _, _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    proxy.scrollTo("top", anchor: .top)
                }
            }
            // When the answer is complete, show its end, so nothing stays hidden below the fold.
            .onChange(of: viewModel.isGenerating) { _, generating in
                guard !generating else { return }
                scrollToAnswerEnd(proxy)
            }
        }
    }

    /// The last token, the panel growing and the stored message replacing the streamed one all land in different frames,
    /// so the scroll waits for the layout to settle before it reveals the end of the answer.
    private func scrollToAnswerEnd(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("answerEnd", anchor: .bottom) }
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

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf, .text, .sourceCode, .json, .rtf]
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { viewModel.attach(fileURL: url) }
        }
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
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

// ToolActivityLine

/// What the model went off to do, in one line: the tool call and its result never appear in the transcript.
struct ToolActivityLine: View {
    let activity: AnswerText.Activity
    var isRunning = false

    var body: some View {
        HStack(spacing: 8) {
            if isRunning { ProgressView().controlSize(.small) } else { Image(systemName: activity.symbol) }
            Text(activity.text).lineLimit(2).truncationMode(.middle)
        }
        .font(.callout).foregroundStyle(.secondary)
    }
}

// MessageView

/// One message: plain text for the user, Markdown (code, tables) for the assistant.
struct MessageView: View {
    let message: Message
    @Environment(AppContainer.self) private var container

    /// Reasoning channels and tool syntax are the model talking to itself; only the answer is shown and copied.
    private var answer: String { AnswerText.visible(message.text) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                .foregroundStyle(message.role == .user ? .secondary : Color.accentColor)
                .frame(width: 20, height: 20)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                AttachmentStrip(attachments: message.attachments)
                if message.role == .user {
                    Text(message.text).textSelection(.enabled)
                } else {
                    // A reply that only asked for tools keeps its notes and nothing else: the call is not readable content.
                    ForEach(AnswerText.activities(of: message, searchProvider: container.settings.searchProvider)) {
                        ToolActivityLine(activity: $0)
                    }
                    if !answer.isEmpty || message.toolCalls.isEmpty {
                        MarkdownView(markdown: answer.isEmpty && message.isPartial ? "…" : answer)
                            .padding(10)  // air around the answer text
                    }
                }
                if message.role == .assistant, let tps = message.tokensPerSecond, !message.isPartial {
                    Text(String(localized: "\(Int(tps)) tok/s"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if message.role == .assistant, !message.isPartial {
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
