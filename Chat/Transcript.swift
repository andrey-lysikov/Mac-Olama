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

/// The tail of a transcript: live progress of the running reply, the streamed text, the error, and the anchor
/// every scroll below aims at. The surface passes the streamed message as `streaming` (its condition differs).
struct TranscriptTail<Streaming: View>: View {
    let progress: GenerationProgress?
    let engineState: EngineState
    let errorMessage: String?
    /// Height of the anchor line; the window keeps 1 pt, the panel 0.
    var anchorHeight: CGFloat = 0
    @ViewBuilder let streaming: () -> Streaming

    var body: some View {
        if let progress {
            GenerationProgressView(progress: progress, engineState: engineState)
        }
        streaming()
        if let errorMessage { ErrorLine(text: errorMessage) }
        Color.clear.frame(height: anchorHeight).id("bottom")
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

// TranscriptScroll

/// The last token, the layout growing and the stored message replacing the streamed one land in different frames,
/// so the jump to the transcript's end waits for the layout to settle. No animation: it fought the layout changing.
@MainActor
enum TranscriptScroll {
    static func toBottom(_ proxy: ScrollViewProxy, after milliseconds: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            proxy.scrollTo("bottom", anchor: .bottom)
        }
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
