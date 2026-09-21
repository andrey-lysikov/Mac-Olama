//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import SwiftUI

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

// The message feed shared by the chats window and the quick panel: the folding of tool rounds, the live tail of a
// running reply, and the pieces of an answer both surfaces render the same way. The surfaces keep their own row
// layout (bubble in the window, avatar row in the panel) and pass it in as the `row` closure.

// TranscriptRow

/// One transcript line: tool rounds fold into one summary line above the answer they led to, and the stored copy of
/// the reply being streamed is skipped (the streamed text below stands for it, otherwise it shows as a stray "…").
struct TranscriptRow<Row: View>: View {
    let message: Message
    /// Position of the message within `context`, the visible slice the summaries are computed against.
    let position: Int
    let context: [Message]
    let isStreamedPlaceholder: Bool
    let thoughtSeconds: Int?
    @ViewBuilder let row: (Message, String?) -> Row

    var body: some View {
        if isStreamedPlaceholder {
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

/// The tail of a transcript: the streamed text, live progress of the running reply and the error. The surface passes
/// the streamed message as `streaming` (its condition differs).
struct TranscriptTail<Streaming: View>: View {
    let progress: GenerationProgress?
    let engineState: EngineState
    let errorMessage: String?
    @ViewBuilder let streaming: () -> Streaming

    var body: some View {
        streaming()
        // Under the text, not above it: the tool steps and the thinking counter scrolled out of sight over a long
        // reply, while the end of the transcript is where the eye stays.
        if let progress {
            GenerationProgressView(progress: progress, engineState: engineState)
        }
        if let errorMessage { ErrorLine(text: errorMessage) }
    }
}

// ErrorLine

/// Why the answer did not come, in red where the answer would have been, and selectable so it can be quoted.
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

// TranscriptFollow

/// Keeps the transcript on its end while a reply is thought and written, and lets go as soon as the user scrolls up
/// to read. The arrow at the bottom right brings it back and it follows again; scrolling down to the end by hand does
/// the same. `jumpOn` changes when the newest message must come into view regardless: a sent question, another chat.
struct TranscriptFollow<Jump: Equatable>: ViewModifier {
    let jumpOn: Jump
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var following = true

    /// Where the view stands. A growing transcript never moves the offset back, only the user scrolling up does,
    /// so the two are told apart without scroll phases, which the scroller's knob does not report.
    private struct Place: Equatable {
        var offset: CGFloat
        var gap: CGFloat
    }

    /// Closer than this to the end still counts as the end, so a nudge of the trackpad does not let go.
    private static var slack: CGFloat { 32 }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // While following, the anchor holds the end as text grows, without a scroll per token; while the user
            // reads, it is off, so the lines being read do not slide away under the new ones.
            .defaultScrollAnchor(following ? .bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: Place.self) { geometry in
                Place(offset: geometry.contentOffset.y, gap: max(0, geometry.contentSize.height - geometry.visibleRect.maxY))
            } action: { old, new in
                if new.gap <= Self.slack {
                    following = true
                } else if new.offset < old.offset - 1 {
                    following = false
                } else if following {
                    // What the anchor does not cover: the streamed tail swapped for the stored reply, a tool round.
                    position.scrollTo(edge: .bottom)
                }
            }
            .onChange(of: jumpOn) { _, _ in toEnd() }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if !following {
                        Button(action: toEnd) {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                        .help(String(localized: "Scroll to the end"))
                        .padding(16)
                        .transition(.opacity)
                    }
                }
                // Only the arrow fades: an animation on the scroll view itself fought the layout changing.
                .animation(.easeOut(duration: 0.15), value: following)
            }
    }

    private func toEnd() {
        following = true
        position.scrollTo(edge: .bottom)
    }
}

extension View {
    /// See `TranscriptFollow`.
    func followsTranscriptEnd(jumpOn: some Equatable) -> some View {
        modifier(TranscriptFollow(jumpOn: jumpOn))
    }
}

// ReasoningBlock

/// What the model said to itself on the way to this answer, shown quieter than the answer — only for the models
/// whose thinking the user asked to see (the eye mark in the models list). Reacts to the eye at once: the mark
/// toggles a setting this view reads, so every transcript shows or hides the thinking without a reload.
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

/// The answer of an assistant message: the visible Markdown, or the "no answer" line for an empty finished reply.
struct AnswerBody: View {
    let message: Message
    /// The reply without the model's private channels, computed once by the caller (it also feeds the copy button).
    let answer: String
    let fontSize: CGFloat
    /// The panel pads the "no answer" line; the window shows it flush.
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

/// The one line of numbers under a finished reply: `21t/s (8.2k/33k)`. Red when the reply ran into its token limit.
struct PaceText: View {
    let pace: String
    var atLimit = false

    var body: some View {
        Text(verbatim: pace)
            .font(.caption2).monospacedDigit()
            .foregroundStyle(atLimit ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
    }
}
