//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import SwiftUI

// How long a reply takes is unknown in advance, so progress is shown as what has really happened: finished tool steps,
// the running one, and the thinking stretch with its time and hidden tokens. A finished reply keeps one summary line.

/// What a running reply has done so far. Fed by `ConversationEvent`s in the panel and the chats window.
struct GenerationProgress: Equatable {
    struct Step: Equatable, Identifiable {
        let id: Int
        var activity: AnswerText.Activity
        var done = false
    }

    private(set) var steps: [Step] = []
    /// Start of the current stretch without visible text (prompt processing, reasoning); nil while a tool runs or the answer streams.
    private(set) var thinkingSince: Date? = .now
    /// Hidden tokens of the current stretch, shown next to its time.
    private(set) var thinkingTokens = 0
    /// First hidden token of the current stretch: the speed is counted from it, so prompt processing does not drag it down.
    private(set) var firstThinkingToken: Date?
    /// Hidden tokens of the whole reply: without them the model did not reason, and the summary does not claim it did.
    private(set) var hiddenTokens = 0
    private(set) var thoughtSeconds: TimeInterval = 0

    mutating func toolStarted(_ activity: AnswerText.Activity) {
        endThinking()
        steps.append(Step(id: steps.count, activity: activity))
    }

    mutating func toolFinished() {
        if let last = steps.indices.last { steps[last].done = true }
        thinkingSince = .now
        thinkingTokens = 0
        firstThinkingToken = nil
    }

    /// `answerStarted`: the visible answer is no longer empty, so the thinking stretch is over.
    mutating func token(answerStarted: Bool) {
        if answerStarted {
            endThinking()
        } else if thinkingSince != nil {
            if firstThinkingToken == nil { firstThinkingToken = .now }
            thinkingTokens += 1
            hiddenTokens += 1
        }
    }

    mutating func endThinking() {
        guard let since = thinkingSince else { return }
        thoughtSeconds += Date.now.timeIntervalSince(since)
        thinkingSince = nil
    }

    /// Seconds to remember for the summary of the finished reply, nil when the model answered without reasoning.
    var reportedThoughtSeconds: Int? { hiddenTokens > 0 ? max(1, Int(thoughtSeconds.rounded())) : nil }
}

extension AnswerText {
    /// One line for a finished reply: what the tools did and how long the model thought.
    static func summary(of calls: [ToolCall], thoughtSeconds: Int?) -> String? {
        let searches = calls.filter { $0.name == "web_search" }.count
        let pages = calls.filter { $0.name == "fetch_url" }.count
        let others = calls.count - searches - pages
        var parts: [String] = []
        if searches > 0 { parts.append(String(localized: "Searches: \(searches)")) }
        if pages > 0 { parts.append(String(localized: "Pages read: \(pages)")) }
        if others > 0 { parts.append(String(localized: "Tools used: \(others)")) }
        if let thoughtSeconds { parts.append(String(localized: "Thought for \(thoughtSeconds) s")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Tool calls made on the way to `messages[index]`: the tool-asking replies right before it (tool results are skipped).
    static func toolCalls(before index: Int, in messages: [Message]) -> [ToolCall] {
        var calls: [ToolCall] = []
        var i = index - 1
        while i >= 0, isToolStep(messages[i]) {
            calls = messages[i].toolCalls + calls
            i -= 1
        }
        return calls
    }

    /// A tool-asking reply folds into the summary above the answer it led to; it stays visible only if no answer followed.
    static func isFoldedIntoAnswer(_ index: Int, in messages: [Message]) -> Bool {
        var i = index + 1
        while i < messages.count, isToolStep(messages[i]) { i += 1 }
        return i < messages.count && messages[i].role == .assistant
    }

    private static func isToolStep(_ message: Message) -> Bool {
        message.role == .tool || (message.role == .assistant && !message.toolCalls.isEmpty)
    }
}

// Views

/// Live progress of the running reply: steps with a checkmark or a spinner, then the model loading or thinking.
struct GenerationProgressView: View {
    let progress: GenerationProgress
    let engineState: EngineState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(progress.steps) { step in
                HStack(spacing: 8) {
                    if step.done { Image(systemName: "checkmark").frame(width: 16) } else { ProgressView().controlSize(.small) }
                    Text(step.done ? String(step.activity.text.trimmingSuffix("…")) : step.activity.text)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            if case .loading(_, let fraction) = engineState {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Loading model… \(fraction.formatted(.percent.precision(.fractionLength(0))))"))
                }
            } else if let since = progress.thinkingSince {
                ThinkingLine(since: since, tokens: progress.thinkingTokens, firstToken: progress.firstThinkingToken)
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }
}

/// "Thinking · 14 s · Tokens: 27/s (380)", ticking every second.
private struct ThinkingLine: View {
    let since: Date
    let tokens: Int
    let firstToken: Date?

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(
                    tokens > 0
                        ? String(localized: "Thinking · \(seconds) s · Tokens: \(speed(at: .now))/s (\(tokens))")
                        : String(localized: "Thinking · \(seconds) s")
                )
                .monospacedDigit()
            }
        }
    }

    /// Tokens per second since the first one; the first second is counted whole so a burst does not show a wild number.
    private func speed(at date: Date) -> Int {
        guard let firstToken else { return 0 }
        return Int((Double(tokens) / max(date.timeIntervalSince(firstToken), 1)).rounded())
    }
}

/// What a finished reply did on its way, in one line above the answer.
struct ProgressSummaryLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary).lineLimit(2)
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> Substring {
        hasSuffix(suffix) ? dropLast(suffix.count) : Substring(self)
    }
}

// Questions asked while the model is still busy

/// A question sent while a reply is being written: it waits and goes out, in order, once the reply is finished,
/// so each one sees the answers before it.
struct QueuedQuestion: Identifiable, Equatable {
    let id = UUID()
    /// The chat the question belongs to (chats window); the panel always asks in its own chat.
    var chatID: UUID?
    var text: String
    var images: [ImageInput]
    var documents: [DocumentInput]

    /// What the bubble shows: the text, or the attachments when there is no text.
    var summary: String {
        guard text.isEmpty else { return text }
        var parts = documents.map(\.name)
        if !images.isEmpty { parts.append(String(localized: "Images: \(images.count)")) }
        return parts.joined(separator: ", ")
    }
}

/// Waiting questions under the running reply, each with a way to take it back.
struct QueuedQuestionsView: View {
    let questions: [QueuedQuestion]
    var onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(questions) { question in
                HStack(alignment: .center, spacing: 8) {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(verbatim: question.summary).lineLimit(3)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Label(String(localized: "Queued"), systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                    Button {
                        onRemove(question.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(String(localized: "Remove from queue"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
