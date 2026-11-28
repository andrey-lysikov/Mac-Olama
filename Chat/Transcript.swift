//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import SwiftUI

// TranscriptRow

struct TranscriptRow<Row: View>: View {
    let message: Message
    let position: Int
    let context: [Message]
    let isStreamedPlaceholder: Bool
    let thoughtSeconds: Int?
    @ViewBuilder let row: (Message, String?) -> Row

    var body: some View {
        if let approval = ToolApprovalRecord.record(from: message) {
            ToolApprovalHistoryCard(record: approval)
        } else if isStreamedPlaceholder {
            EmptyView()
        } else if message.toolCalls.isEmpty {
            row(
                message,
                message.role == .assistant
                    ? AnswerText.summary(of: AnswerText.toolCalls(before: position, in: context), thoughtSeconds: thoughtSeconds)
                    : nil)
        } else if !AnswerText.isFoldedIntoAnswer(position, in: context) {
            // A reply that only asked for tools and got no answer after it: shown with its own summary.
            row(message, AnswerText.summary(of: message.toolCalls, thoughtSeconds: nil))
        }
    }
}

// TranscriptTail

struct TranscriptTail<Streaming: View>: View {
    let progress: GenerationProgress?
    let engineState: EngineState
    let errorMessage: String?
    var approvals: [ToolApprovalRequest] = []
    var onRetry: (() -> Void)? = nil
    @ViewBuilder let streaming: () -> Streaming

    var body: some View {
        streaming()
        // Progress below the text, where the eye stays.
        if let progress {
            GenerationProgressView(progress: progress, engineState: engineState)
        }
        ForEach(approvals) { request in
            ToolApprovalCard(request: request)
        }
        if let errorMessage {
            HStack(alignment: .top, spacing: 8) {
                ErrorLine(text: errorMessage)
                if let onRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// ToolApprovalCard

struct ToolApprovalCard: View {
    let request: ToolApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: request.isDiff ? "doc.text.magnifyingglass" : "shield")
                .font(.callout.weight(.semibold))
            if request.isDiff {
                ScrollView {
                    Text(request.detail)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 320)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text(request.detail).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button(String(localized: "Allow")) { NotificationService.shared.resolveApproval(id: request.id, allowed: true) }
                    .buttonStyle(.glass)
                Button(String(localized: "Deny"), role: .destructive) {
                    NotificationService.shared.resolveApproval(id: request.id, allowed: false)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// ToolApprovalHistoryCard

struct ToolApprovalHistoryCard: View {
    let record: ToolApprovalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(record.request.title, systemImage: record.allowed ? "checkmark.shield" : "xmark.shield")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(record.decidedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(
                record.allowed
                    ? String(localized: record.automatic ? "Allowed Automatically" : "Allowed")
                    : String(localized: "Denied")
            )
            .font(.callout.weight(.medium)).foregroundStyle(record.allowed ? .green : .red)
            if record.request.isDiff {
                ScrollView {
                    Text(record.request.detail)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 320)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text(record.request.detail).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// ErrorLine

struct ErrorLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red).font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// CompactionDivider

struct CompactionDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Divider()
            Text(String(localized: "Compacted")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// TranscriptFollow

struct TranscriptFollow<Jump: Equatable>: ViewModifier {
    let jumpOn: Jump
    var onNearTop: (() -> Void)? = nil
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var following = true
    @State private var userScrolling = false

    private struct Place: Equatable {
        var offset: CGFloat
        var gap: CGFloat
        var height: CGFloat
    }

    private static var slack: CGFloat { 32 }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Anchor the end while following; off while the user reads.
            .defaultScrollAnchor(following ? .bottom : nil, for: .sizeChanges)
            // Lazy rows do not exist yet on the first pass: scroll after the layout lands.
            .onAppear { DispatchQueue.main.async { toEnd() } }
            .onScrollPhaseChange { _, phase, context in
                let wasUser = userScrolling
                let scrolling = phase == .interacting || phase == .decelerating
                if scrolling != userScrolling { userScrolling = scrolling }
                // On gesture end: at the bottom follow, otherwise stay.
                if wasUser, !userScrolling { following = Self.gap(context.geometry) <= Self.slack }
            }
            .onScrollGeometryChange(for: Place.self) { geometry in
                Place(offset: geometry.contentOffset.y, gap: Self.gap(geometry), height: geometry.contentSize.height)
            } action: { old, new in
                // Once per crossing, not on every frame at the top.
                if new.offset <= 0, old.offset > 0 { onNearTop?() }
                if new.gap <= Self.slack {
                    if !following, !userScrolling { following = true }
                } else if userScrolling || (new.offset < old.offset - 1 && new.height >= old.height - 1) {
                    // A gesture or knob drag up means the user scrolled away.
                    if following { following = false }
                } else if following, !userScrolling {
                    // Cases the anchor misses: tail swap, tool round. Never fight an active gesture.
                    position.scrollTo(edge: .bottom)
                }
            }
            .onChange(of: jumpOn) { _, _ in DispatchQueue.main.async { toEnd() } }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if !following {
                        Button(action: toEnd) {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                        .padding(16)
                        .transition(.opacity)
                    }
                }
                // Only the arrow fades: an animation on the scroll view itself fought the layout changing.
                .animation(.easeOut(duration: 0.15), value: following)
            }
    }

    private static func gap(_ geometry: ScrollGeometry) -> CGFloat {
        max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
    }

    private func toEnd() {
        // A deliberate jump (another chat, a new question) also ends any gesture still in progress.
        userScrolling = false
        following = true
        position.scrollTo(edge: .bottom)
    }
}

extension View {
    func followsTranscriptEnd(jumpOn: some Equatable, onNearTop: (() -> Void)? = nil) -> some View {
        modifier(TranscriptFollow(jumpOn: jumpOn, onNearTop: onNearTop))
    }
}

// ReasoningBlock

struct ReasoningBlock: View {
    let message: Message
    let fontSize: CGFloat
    @Environment(AppContainer.self) private var container

    private var reasoning: String? {
        guard let id = message.modelID, container.showsReasoning(modelID: id) else { return nil }
        let text = AnswerText.reasoning(message.text)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        if let reasoning {
            Text(reasoning)
                .font(.system(size: fontSize - 2)).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// AnswerBody

struct AnswerBody: View {
    let message: Message
    let answer: String
    let fontSize: CGFloat
    var noAnswerPadding: CGFloat = 0

    var body: some View {
        if answer.isEmpty, !message.isPartial {
            NoAnswerLine().padding(noAnswerPadding)
        } else {
            MarkdownView(markdown: answer.isEmpty ? "…" : answer, baseFontSize: fontSize, streaming: message.isPartial)
        }
    }
}

// PaceText

struct PaceText: View {
    let pace: String
    var atLimit = false

    var body: some View {
        Text(verbatim: pace)
            .font(.caption2).monospacedDigit()
            .foregroundStyle(atLimit ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
    }
}

struct TokenUsageView: View {
    let message: Message

    var body: some View {
        if let prompt = message.promptTokens {
            let cached = min(message.cachedTokens ?? 0, prompt)
            let fresh = prompt - cached
            let output = message.outputTokens ?? message.completionTokens ?? 0
            let rounds = message.toolRounds ?? 1
            Text(
                String(
                    localized:
                        "↑ \(ChatMessageView.compact(fresh)) + \(ChatMessageView.compact(cached)) cached · ↓ \(ChatMessageView.compact(output)) · \(rounds) calls")
            )
            .font(.caption2).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}
