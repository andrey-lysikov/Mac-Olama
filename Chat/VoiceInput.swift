//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Speech
import SwiftUI

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

// VoiceInput

/// Dictation into the composer, recognized on this Mac by the system's speech analyzer: the words appear as they are
/// said, and the question then goes out like a typed one, so a spoken command reaches the plugins the same way.
@MainActor
@Observable
final class VoiceInput {
    enum State: Equatable { case idle, preparing, listening, failed(String) }

    private(set) var state: State = .idle
    /// What has been said so far: the settled words, then the guess for the ones still being spoken.
    private(set) var transcript = ""
    /// Loudness of the last moment, 0…1, for the button's waveform.
    private(set) var level: Double = 0
    /// Called with the whole transcript once listening stops, by the button or by a pause.
    @ObservationIgnored var onFinish: ((String) -> Void)?

    @ObservationIgnored private var settled = ""
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var feed: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?
    @ObservationIgnored private var silenceWatch: Task<Void, Never>?
    @ObservationIgnored private var lastVoice = ContinuousClock.now
    @ObservationIgnored private var heardVoice = false

    /// Quieter than this counts as silence; a pause this long after speech ends the dictation.
    private static let voiceLevel = 0.06
    private static let pause: Duration = .seconds(2)
    private static let longest: Duration = .seconds(120)

    func toggle(language: String) {
        switch state {
        case .listening: Task { await stop() }
        case .preparing: break
        case .idle, .failed: Task { await start(language: language) }
        }
    }

    func start(language: String) async {
        state = .preparing
        transcript = ""
        settled = ""
        heardVoice = false
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            PrivacySettings.ask(.microphone)
            return fail(
                String(localized: "Mac-Olama may not use the microphone: allow it in System Settings → Privacy & Security → Microphone."))
        }
        let wanted = Self.locale(for: language)
        do {
            // The transcriber for long speech first; the dictation one knows more languages.
            let module: any SpeechModule
            if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
                let transcriber = SpeechTranscriber(
                    locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
                module = transcriber
                results = Task { [weak self] in
                    do { for try await result in transcriber.results { self?.take(result.text, final: result.isFinal) } } catch {}
                }
            } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
                let dictation = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
                module = dictation
                results = Task { [weak self] in
                    do { for try await result in dictation.results { self?.take(result.text, final: result.isFinal) } } catch {}
                }
            } else {
                return fail(
                    String(
                        localized:
                            "This Mac cannot recognize speech in \(wanted.localizedString(forIdentifier: wanted.identifier) ?? wanted.identifier)."
                    ))
            }
            // The language's model is downloaded by macOS the first time, then kept.
            if let download = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await download.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                return fail(String(localized: "Speech recognition has no audio format for this microphone."))
            }
            let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [module])
            try await analyzer.start(inputSequence: input)
            let engine = AVAudioEngine()
            try Self.tap(engine, into: feed, as: format) { [weak self] level in
                Task { @MainActor in self?.heard(level) }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.analyzer = analyzer
            self.feed = feed
            lastVoice = .now
            state = .listening
            watchForSilence()
        } catch {
            teardown()
            fail(String(localized: "Speech recognition did not start: \(error.localizedDescription)"))
        }
    }

    func stop() async {
        guard state == .listening else { return }
        silenceWatch?.cancel()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        feed?.finish()
        // The last words settle only once the end of the audio is known.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        teardown()
        state = .idle
        level = 0
        onFinish?(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Recognition

    private func take(_ text: AttributedString, final: Bool) {
        let words = String(text.characters).trimmingCharacters(in: .whitespaces)
        if final {
            if !words.isEmpty { settled += (settled.isEmpty ? "" : " ") + words }
            transcript = settled
        } else {
            transcript = settled + (settled.isEmpty || words.isEmpty ? "" : " ") + words
        }
    }

    private func heard(_ loudness: Double) {
        level = min(1, loudness * 6)
        if loudness > Self.voiceLevel {
            lastVoice = .now
            heardVoice = true
        }
    }

    /// Stops after a pause once something was said, and after two minutes in any case.
    private func watchForSilence() {
        let started = ContinuousClock.now
        silenceWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.state == .listening else { return }
                let paused = self.heardVoice && !self.transcript.isEmpty && self.lastVoice.duration(to: .now) > Self.pause
                if paused || started.duration(to: .now) > Self.longest {
                    await self.stop()
                    return
                }
            }
        }
    }

    private func teardown() {
        engine = nil
        analyzer = nil
        feed = nil
        results = nil
        silenceWatch = nil
    }

    private func fail(_ message: String) {
        state = .failed(message)
        level = 0
    }

    // Audio

    /// The microphone into the analyzer, converted to the format it wants. Not on the main actor: the tap runs on the
    /// audio thread, and a closure made on the main actor would be taken for a main-actor one and trap there.
    private nonisolated static func tap(
        _ engine: AVAudioEngine, into feed: AsyncStream<AnalyzerInput>.Continuation, as format: AVAudioFormat,
        level: @escaping @Sendable (Double) -> Void
    ) throws {
        let input = engine.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, let converter = AVAudioConverter(from: natural, to: format) else {
            throw CocoaError(.featureUnsupported)
        }
        let pipe = AudioPipe(converter: converter, format: format, feed: feed)
        input.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
            level(pipe.loudness(of: buffer))
            pipe.push(buffer)
        }
    }

    /// The preferred reply language names the dictation language too; without one, the system's language.
    static func locale(for language: String) -> Locale {
        let known = [
            "English": "en-US", "Russian": "ru-RU", "German": "de-DE", "French": "fr-FR", "Spanish": "es-ES", "Italian": "it-IT",
            "Portuguese": "pt-BR", "Polish": "pl-PL", "Turkish": "tr-TR", "Ukrainian": "uk-UA", "Chinese": "zh-CN",
            "Japanese": "ja-JP", "Korean": "ko-KR",
        ]
        return known[language].map { Locale(identifier: $0) } ?? Locale.current
    }
}

/// Owned by the audio thread once the tap starts: the converter is touched there only, one buffer at a time.
private final class AudioPipe: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    let feed: AsyncStream<AnalyzerInput>.Continuation

    init(converter: AVAudioConverter, format: AVAudioFormat, feed: AsyncStream<AnalyzerInput>.Continuation) {
        self.converter = converter
        self.format = format
        self.feed = feed
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var handed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if handed {
                status.pointee = .noDataNow
                return nil
            }
            handed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, converted.frameLength > 0 { feed.yield(AnalyzerInput(buffer: converted)) }
    }

    /// Root mean square of the first channel.
    func loudness(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        return Double((sum / Float(buffer.frameLength)).squareRoot())
    }
}

// VoiceInputButton

/// The microphone next to the paperclip: press to speak, press again or pause to stop. The words go into the field
/// after what was typed; with sending after a pause on, the question then goes out by itself.
struct VoiceInputButton: View {
    @Binding var text: String
    var disabled: Bool
    var onSend: () -> Void
    @Environment(AppContainer.self) private var container
    @State private var voice = VoiceInput()
    /// What was typed before speaking; the dictation goes after it.
    @State private var typed = ""
    @State private var showsFailure = false

    var body: some View {
        Button(action: toggle) {
            switch voice.state {
            case .idle: Image(systemName: "mic")
            case .preparing: ProgressView().controlSize(.small)
            case .listening:
                Image(systemName: "waveform", variableValue: voice.level).foregroundStyle(.red)
            case .failed: Image(systemName: "mic.slash")
            }
        }
        .help(help)
        .disabled(disabled && voice.state != .listening)
        .onChange(of: voice.transcript) { _, said in
            guard voice.state == .listening || voice.state == .idle else { return }
            text = typed.isEmpty ? said : typed + (typed.hasSuffix(" ") || said.isEmpty ? "" : " ") + said
        }
        .onChange(of: voice.state) { _, state in
            if case .failed = state { showsFailure = true }
        }
        .popover(isPresented: $showsFailure, arrowEdge: .top) {
            if case .failed(let message) = voice.state {
                Text(message).font(.callout).padding(12).frame(maxWidth: 300).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var help: String {
        switch voice.state {
        case .listening: String(localized: "Listening… press again or pause to stop")
        case .preparing: String(localized: "Getting speech recognition ready…")
        default: String(localized: "Dictate")
        }
    }

    private func toggle() {
        if voice.state != .listening { typed = text }
        voice.onFinish = { said in
            if container.settings.voiceAutoSend, !said.isEmpty { onSend() }
        }
        voice.toggle(language: container.settings.preferredLanguage)
    }
}
