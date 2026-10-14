//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct GenerationProgress: Equatable {
    struct Step: Equatable, Identifiable {
        let id: Int
        var activity: AnswerText.Activity
        var done = false
    }

    private(set) var steps: [Step] = []
    private(set) var thinkingSince: Date? = .now
    private(set) var thinkingTokens = 0
    private(set) var firstThinkingToken: Date?
    private(set) var hiddenTokens = 0
    private(set) var thoughtSeconds: TimeInterval = 0
    private(set) var tokens = 0
    private var generatedCount: Int?
    private(set) var firstToken: Date?
    private(set) var answeringSince: Date?

    mutating func toolStarted(_ activity: AnswerText.Activity) {
        endThinking()
        answeringSince = nil
        steps.append(Step(id: steps.count, activity: activity))
    }

    mutating func toolFinished(detail: String? = nil) {
        if let last = steps.indices.last {
            steps[last].done = true
            if let detail { steps[last].activity.text = detail }
        }
        thinkingSince = .now
        thinkingTokens = 0
        firstThinkingToken = nil
        tokens = 0
        generatedCount = nil
        firstToken = nil
        answeringSince = nil
    }

    mutating func token(answerStarted: Bool) {
        if firstToken == nil { firstToken = .now }
        // Chunks count only until the engine's first count.
        if generatedCount == nil { tokens += 1 }
        if answerStarted {
            endThinking()
            if answeringSince == nil { answeringSince = .now }
        } else if thinkingSince != nil {
            if firstThinkingToken == nil { firstThinkingToken = .now }
            thinkingTokens += 1
            hiddenTokens += 1
        }
    }

    mutating func generated(_ count: Int) {
        generatedCount = count
        guard count > tokens else { return }
        if firstToken == nil { firstToken = .now }
        tokens = count
    }

    mutating func endThinking() {
        guard let since = thinkingSince else { return }
        thoughtSeconds += Date.now.timeIntervalSince(since)
        thinkingSince = nil
    }

    var reportedThoughtSeconds: Int? { hiddenTokens > 0 ? max(1, Int(thoughtSeconds.rounded())) : nil }
}

extension AnswerText {
    static func summary(of calls: [ToolCall], thoughtSeconds: Int?) -> String? {
        let searches = calls.filter { $0.name == "web_search" }.count
        let pages = calls.filter { $0.name == "fetch_url" }.count
        // Other tools by name, once each, in order.
        var others: [String] = []
        for call in calls where call.name != "web_search" && call.name != "fetch_url" && !others.contains(call.name) {
            others.append(call.name)
        }
        var parts: [String] = []
        if searches > 0 { parts.append(String(localized: "Searches: \(searches)")) }
        if pages > 0 { parts.append(String(localized: "Pages read: \(pages)")) }
        if !others.isEmpty { parts.append(String(localized: "Tools used: \(others.joined(separator: ", "))")) }
        if let thoughtSeconds { parts.append(String(localized: "Thought for \(thoughtSeconds) s")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func toolCalls(before index: Int, in messages: [Message]) -> [ToolCall] {
        var calls: [ToolCall] = []
        var i = index - 1
        while i >= 0, isToolStep(messages[i]) {
            calls = messages[i].toolCalls + calls
            i -= 1
        }
        return calls
    }

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

struct GenerationProgressView: View {
    let progress: GenerationProgress
    let engineState: EngineState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // While the answer streams, only the speed stays.
            if progress.answeringSince == nil {
                ForEach(progress.steps) { step in
                    HStack(spacing: 8) {
                        if step.done { Image(systemName: "checkmark").frame(width: 16) } else { ProgressView().controlSize(.small) }
                        // A finished step keeps its wording, without the ellipsis that says it is still running.
                        Text(step.done ? step.activity.text.replacingOccurrences(of: "…", with: "") : step.activity.text)
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
            }
            if case .loading(_, let fraction) = engineState {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Loading model… \(fraction.formatted(.percent.precision(.fractionLength(0))))"))
                }
            } else if let since = progress.thinkingSince {
                LiveLine(thinking: true, since: since, tokens: progress.tokens, firstToken: progress.firstToken)
            } else if let since = progress.answeringSince {
                // The counter continues through the answer.
                LiveLine(thinking: false, since: since, tokens: progress.tokens, firstToken: progress.firstToken)
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }
}

private struct LiveLine: View {
    let thinking: Bool
    let since: Date
    let tokens: Int
    let firstToken: Date?

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text(seconds: seconds))
                    .monospacedDigit()
            }
        }
    }

    private func text(seconds: Int) -> String {
        switch (thinking, tokens > 0) {
        case (true, true): String(localized: "Thinking · \(seconds) s · Tokens: \(speed(at: .now))/s (\(tokens))")
        case (true, false): String(localized: "Thinking · \(seconds) s")
        case (false, true): String(localized: "Answering · \(seconds) s · Tokens: \(speed(at: .now))/s (\(tokens))")
        case (false, false): String(localized: "Answering · \(seconds) s")
        }
    }

    private func speed(at date: Date) -> Int {
        guard let firstToken else { return 0 }
        return Int((Double(tokens) / max(date.timeIntervalSince(firstToken), 1)).rounded())
    }
}

struct ProgressSummaryLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary).lineLimit(2)
    }
}

// Questions asked while the model is still busy

struct QueuedQuestion: Identifiable, Equatable {
    let id = UUID()
    var chatID: UUID?
    var text: String
    var images: [ImageInput]
    var documents: [DocumentInput]

    var summary: String {
        guard text.isEmpty else { return text }
        var parts = documents.map(\.name)
        if !images.isEmpty { parts.append(String(localized: "Images: \(images.count)")) }
        return parts.joined(separator: ", ")
    }
}

struct QueuedQuestionsView: View {
    @ScaledMetric(relativeTo: .body) private var scaledText: CGFloat = ChatMessageView.textSize
    let questions: [QueuedQuestion]
    var onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(questions) { question in
                HStack(alignment: .center, spacing: 8) {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 3) {
                        // A waiting question is read next to the answers, so it keeps their size.
                        Text(verbatim: question.summary).lineLimit(3).font(.system(size: scaledText))
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
