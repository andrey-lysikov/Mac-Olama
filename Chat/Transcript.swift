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

struct TranscriptTail<Streaming: View>: View {
    let progress: GenerationProgress?
    let engineState: EngineState
    let errorMessage: String?
    @ViewBuilder let streaming: () -> Streaming

    var body: some View {
        streaming()
        // Progress below the text, where the eye stays.
        if let progress {
            GenerationProgressView(progress: progress, engineState: engineState)
        }
        if let errorMessage { ErrorLine(text: errorMessage) }
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

// TranscriptFollow

struct TranscriptFollow<Jump: Equatable>: ViewModifier {
    let jumpOn: Jump
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
            .onScrollPhaseChange { _, phase, context in
                let wasUser = userScrolling
                userScrolling = phase == .interacting || phase == .decelerating
                // On gesture end: at the bottom follow, otherwise stay.
                if wasUser, !userScrolling { following = Self.gap(context.geometry) <= Self.slack }
            }
            .onScrollGeometryChange(for: Place.self) { geometry in
                Place(offset: geometry.contentOffset.y, gap: Self.gap(geometry), height: geometry.contentSize.height)
            } action: { old, new in
                if new.gap <= Self.slack {
                    following = true
                } else if userScrolling || (new.offset < old.offset - 1 && new.height >= old.height - 1) {
                    // A gesture or knob drag up means the user scrolled away.
                    following = false
                } else if following {
                    // Cases the anchor misses: tail swap, tool round.
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

    private static func gap(_ geometry: ScrollGeometry) -> CGFloat {
        max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
    }

    private func toEnd() {
        following = true
        position.scrollTo(edge: .bottom)
    }
}

extension View {
    func followsTranscriptEnd(jumpOn: some Equatable) -> some View {
        modifier(TranscriptFollow(jumpOn: jumpOn))
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
