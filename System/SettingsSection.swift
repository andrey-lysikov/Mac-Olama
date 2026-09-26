//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

/// Everything the app itself is set to do, in the chats window next to the model library. The status menu keeps only
/// what is reached in one click; anything with a value to pick or a list to edit belongs here.
/// What a single model does — its context window, temperature, drafter, thinking — stays in the models section.
/// Every setting is one row: its name on the left, its control on the right, the way System Settings reads — its
/// switches are the small control size, so they sit level with one line of text rather than towering over it.
struct SettingsSectionView: View {
    @Environment(AppContainer.self) private var container
    /// The shortcut being edited: it reaches the app only when the tick is pressed, so a half-typed combination
    /// never becomes the live one.
    @State private var draft = GlobalHotkey.Combination(keyCode: 0, modifiers: 0)
    @State private var recording = false

    /// The page sizes offered: from a short news item to a long article. A number typed by hand would say no more.
    private static let pageSizes = [4000, 8000, 12000, 20000, 30000, 60000]
    private static let searchCounts = [3, 5, 8, 10, 12]
    /// Rounds of tools before the model must answer: one search or one page read is a round.
    private static let toolRounds = [3, 5, 10, 15, 20]
    private static let idleTimeouts: [(String, TimeInterval)] = [
        (String(localized: "1 minute"), 60), (String(localized: "5 minutes"), 300), (String(localized: "15 minutes"), 900),
        (String(localized: "1 hour"), 3600),
        // Zero means the model is loaded at launch and stays resident.
        (String(localized: "Do not unload"), 0),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group(String(localized: "Replies")) { replies }
                group(String(localized: "Voice input")) { voiceInput }
                group(String(localized: "Model Plugins")) { pluginGroups }
                group(String(localized: "Web pages")) { web }
                group(String(localized: "Unload the model automatically")) { unloading }
                group(String(localized: "Panel behaviour")) { panel }
                group(String(localized: "Model downloads")) { downloads }
                group(String(localized: "Access to the models API")) { api }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .onAppear(perform: loadDraft)
        // The field turns the shortcut off while it listens; whatever the outcome, the live one comes back.
        .onChange(of: recording) { _, listening in if !listening { container.restoreHotkey() } }
    }

    private func loadDraft() {
        draft = container.hotkey
    }

    /// The value stored (and put into the prompt) is the English name; the label is the language's own.
    private static let languages: [(String, String)] = [
        (String(localized: "Automatic"), ""),
        ("English", "English"), ("Русский", "Russian"), ("Deutsch", "German"), ("Français", "French"),
        ("Español", "Spanish"), ("Italiano", "Italian"), ("Português", "Portuguese"), ("Polski", "Polish"),
        ("Türkçe", "Turkish"), ("Українська", "Ukrainian"), ("中文", "Chinese"), ("日本語", "Japanese"), ("한국어", "Korean"),
    ]

    // Sections

    /// Dictation is recognized on this Mac in the preferred reply language, or the system's.
    private var voiceInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            switchRow(
                String(localized: "Microphone button"),
                help: String(localized: "Dictate a question next to the paperclip, in the chats window and the panel"),
                get: { container.settings.voiceInputEnabled }, set: { container.setVoiceInputEnabled($0) })
            switchRow(
                String(localized: "Send after a pause"),
                help: String(localized: "A dictated question goes out by itself when you stop speaking"),
                indented: true,
                get: { container.settings.voiceAutoSend }, set: { container.setVoiceAutoSend($0) })
        }
    }

    private var replies: some View {
        pickerRow(
            String(localized: "Preferred language"),
            help: String(localized: "Every model answers in this language unless a chat asks for another"),
            width: 160,
            get: { container.settings.preferredLanguage }, set: { container.setPreferredLanguage($0) }
        ) {
            ForEach(Self.languages, id: \.1) { name, value in Text(verbatim: name).tag(value) }
        }
    }

    /// Everything a model may reach, in one block: a line on what the switches mean, then one sub-block per kind, each
    /// under its own heading, so the groups read as parts of one set rather than as unrelated settings.
    private var pluginGroups: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "What a model may use while it answers. Each plugin is off until you turn it on."))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(PluginGroup.allCases, id: \.self) { kind in
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label(Self.title(of: kind), systemImage: Self.symbol(of: kind))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    plugins(kind)
                }
            }
        }
    }

    /// One group of plugins: its plain switches, with web search, folders and Shortcuts where they belong.
    private func plugins(_ kind: PluginGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if kind == .webSearch { webSearch }
            if kind == .files { folders }
            ForEach(kind.tools, id: \.self) { tool in
                switchRow(
                    Self.title(of: tool), help: Self.help(of: tool),
                    get: { container.isToolEnabled(tool) }, set: { container.setToolEnabled(tool, $0) })
            }
            if kind == .thisMac {
                switchRow(
                    String(localized: "Shortcuts"), help: String(localized: "The model may run yours, asking each time"),
                    get: { container.settings.shortcutsToolEnabled }, set: { container.setShortcutsToolEnabled($0) })
            }
        }
    }

    private var webSearch: some View {
        row(String(localized: "Web search")) {
            HStack(spacing: 10) {
                if container.settings.toolsEnabled {
                    picker(
                        width: 160,
                        get: { container.settings.searchProvider == "google" ? "google" : "duckduckgo" },
                        set: { container.setSearchProvider($0) }
                    ) {
                        Text(verbatim: "DuckDuckGo").tag("duckduckgo")
                        Text(verbatim: "Google").tag("google")
                    }
                }
                smallSwitch(get: { container.settings.toolsEnabled }, set: { container.setToolsEnabled($0) })
            }
        }
    }

    @ViewBuilder
    private var folders: some View {
        switchRow(
            String(localized: "Folder access"),
            help: String(localized: "The model may read these folders; writing, moving and packing files you approve"),
            get: { container.settings.fileToolsEnabled }, set: { container.setFileToolsEnabled($0) })
        ForEach(container.settings.allowedFolders, id: \.self) { path in
            row(URL(filePath: path).lastPathComponent, help: path, indented: true) {
                Button(role: .destructive) {
                    container.removeAllowedFolder(path)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(String(localized: "Remove from the list"))
            }
        }
        row(String(localized: "Folders the model may read"), indented: true) {
            Button(String(localized: "Add Folder…"), action: addFolder)
        }
    }

    private var web: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerRow(
                String(localized: "Read from a page"), help: String(localized: "A longer page is cut to this many characters"),
                width: 120,
                get: { container.settings.pageCharacters }, set: { container.setPageCharacters($0) }
            ) {
                ForEach(Self.pageSizes, id: \.self) { size in
                    Text(verbatim: "\(size / 1000)k").tag(size)
                }
            }
            pickerRow(
                String(localized: "Search results per query"), width: 120,
                get: { container.settings.searchResults }, set: { container.setSearchResults($0) }
            ) {
                ForEach(Self.searchCounts, id: \.self) { count in
                    Text(verbatim: "\(count)").tag(count)
                }
            }
            pickerRow(
                String(localized: "Requests in a row"),
                help: String(localized: "How many searches and pages the model may take before it answers"),
                width: 120,
                get: { container.settings.toolIterations }, set: { container.setToolIterations($0) }
            ) {
                ForEach(Self.toolRounds, id: \.self) { rounds in
                    Text(verbatim: "\(rounds)").tag(rounds)
                }
            }
        }
    }

    private var unloading: some View {
        row(String(localized: "After idling"), help: container.engineState.modelID) {
            HStack(spacing: 10) {
                picker(width: 160, get: { container.settings.idleUnloadSeconds }, set: { container.setIdleTimeout($0) }) {
                    ForEach(Self.idleTimeouts, id: \.1) { title, seconds in
                        Text(title).tag(seconds)
                    }
                }
                Button(String(localized: "Unload Now")) { container.unloadNow() }
                    .disabled(container.engineState.modelID == nil)
                    .fixedSize()
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            switchRow(
                String(localized: "Close the panel when it loses focus"),
                get: { container.settings.panelClosesOnFocusLoss }, set: { container.setPanelClosesOnFocusLoss($0) })
            row(String(localized: "Open the panel with"), help: String(localized: "Double-click the field, then press the keys")) {
                HStack(spacing: 8) {
                    // Only as wide as a combination needs; the buttons stay next to it at the right edge of the row.
                    ShortcutField(combination: $draft, recording: $recording)
                        .frame(width: 110, height: 22)
                    Button {
                        container.setHotkey(draft)
                        recording = false
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .help(String(localized: "Apply"))
                    .disabled(!draft.isSet || draft == container.hotkey)
                    Button {
                        container.setHotkey(.init(keyCode: SettingsDefaults.hotkeyKeyCode, modifiers: SettingsDefaults.hotkeyModifiers))
                        loadDraft()
                        recording = false
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help(String(localized: "Reset"))
                }
            }
        }
    }

    private static let speedLimits: [(String, Int)] = [
        (String(localized: "Unlimited"), 0), ("1 MB/s", 1), ("5 MB/s", 5), ("10 MB/s", 10), ("20 MB/s", 20),
        ("50 MB/s", 50), ("100 MB/s", 100),
    ]

    private var downloads: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerRow(
                String(localized: "Speed limit"), help: String(localized: "Caps how fast model files are downloaded"),
                width: 140,
                get: { container.settings.downloadSpeedLimitMBps }, set: { container.setDownloadSpeedLimit($0) }
            ) {
                ForEach(Self.speedLimits, id: \.1) { name, value in Text(name).tag(value) }
            }
            pickerRow(
                String(localized: "Parallel files"), help: String(localized: "How many files of one model are fetched at once"),
                width: 140,
                get: { container.settings.downloadConcurrentFiles }, set: { container.setDownloadConcurrentFiles($0) }
            ) {
                ForEach(1...4, id: \.self) { count in Text(String(count)).tag(count) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var api: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A busy port keeps the switch off; the port field stays open so another one can be typed.
            switchRow(
                String(localized: "Answer other programs"),
                help: container.apiPortBusy
                    ? AppContainer.portBusyText(container.settings.apiServerPort)
                    : String(localized: "Ollama and OpenAI-compatible clients reach the models through this app"),
                get: { container.settings.apiServerEnabled && !container.apiPortBusy }, set: { container.setAPIEnabled($0) }
            )
            .disabled(container.apiPortBusy)
            interfaceRow.disabled(!container.settings.apiServerEnabled && !container.apiPortBusy)
            corsRow.disabled(!container.settings.apiServerEnabled)
        }
        .onAppear { container.checkAPIPort() }
    }

    private var corsRow: some View {
        row(
            String(localized: "Browser access"),
            help: String(localized: "Which web pages may call the API from a browser (CORS)")
        ) {
            HStack(spacing: 10) {
                if container.settings.apiCORSMode == "custom" {
                    TextField(
                        String(localized: "https://example.com, …"),
                        text: Binding(get: { container.settings.apiCORSOrigins }, set: { container.setCORSOrigins($0) })
                    )
                    .frame(width: 220)
                }
                picker(width: 140, get: { container.settings.apiCORSMode }, set: { container.setCORSMode($0) }) {
                    Text(String(localized: "Localhost only")).tag("localhost")
                    Text(String(localized: "Off")).tag("off")
                    Text(String(localized: "Custom list")).tag("custom")
                }
            }
        }
    }

    private var interfaceRow: some View {
        row(String(localized: "Interface"), help: container.apiURL.absoluteString) {
            HStack(spacing: 10) {
                picker(width: 220, get: { container.settings.apiBindHost }, set: { container.setAPIBindHost($0) }) {
                    Text(String(localized: "This Mac only")).tag("127.0.0.1")
                    Text(String(localized: "All")).tag("0.0.0.0")
                    ForEach(NetworkInterfaces.addresses(), id: \.address) { interface in
                        Text(verbatim: "\(interface.name) · \(interface.address)").tag(interface.address)
                    }
                }
                // The port sits with the interface: together they are the address.
                Text(String(localized: "Port")).foregroundStyle(container.apiPortBusy ? .red : .secondary)
                TextField(
                    "",
                    value: Binding(get: { container.settings.apiServerPort }, set: { container.setAPIPort($0) }),
                    format: .number.grouping(.never)
                )
                .frame(width: 80).multilineTextAlignment(.trailing)
                .foregroundStyle(container.apiPortBusy ? .red : .primary)
                .help(
                    container.apiPortBusy
                        ? AppContainer.portBusyText(container.settings.apiServerPort)
                        : String(localized: "The port other programs connect to"))
            }
        }
    }

    // Building blocks

    // `Binding` takes `@Sendable` closures that carry their caller's isolation, so the accessors handed down to
    // these building blocks say `@MainActor @Sendable` too; the call sites stay plain `{ container.settings… }`.

    /// `Toggle(...).labelsHidden().toggleStyle(.switch).controlSize(.small)` written once; sits inside a `row`.
    private func smallSwitch(
        get: @escaping @MainActor @Sendable () -> Bool, set: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> some View {
        Toggle("", isOn: Binding(get: get, set: set))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    /// A row whose only control is a switch.
    private func switchRow(
        _ title: String, help: String? = nil, indented: Bool = false,
        get: @escaping @MainActor @Sendable () -> Bool, set: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> some View {
        row(title, help: help, indented: indented) { smallSwitch(get: get, set: set) }
    }

    /// `Picker(...).labelsHidden().frame(width:)` written once; the options stay at the call site.
    private func picker<Value: Hashable>(
        width: CGFloat, get: @escaping @MainActor @Sendable () -> Value, set: @escaping @MainActor @Sendable (Value) -> Void,
        @ViewBuilder options: () -> some View
    ) -> some View {
        Picker("", selection: Binding(get: get, set: set)) { options() }
            .labelsHidden().frame(width: width)
    }

    /// A row whose only control is a picker.
    private func pickerRow<Value: Hashable>(
        _ title: String, help: String? = nil, width: CGFloat,
        get: @escaping @MainActor @Sendable () -> Value, set: @escaping @MainActor @Sendable (Value) -> Void,
        @ViewBuilder options: () -> some View
    ) -> some View {
        row(title, help: help) { picker(width: width, get: get, set: set, options: options) }
    }

    /// One setting: its name on the left, its control right-aligned, so the controls of a section line up.
    private func row(_ title: String, help: String? = nil, indented: Bool = false, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if let help {
                    Text(help).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.leading, indented ? 18 : 0)
            Spacer(minLength: 12)
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(radius: 18)
    }

    private func addFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { container.addAllowedFolder(url) }
            container.setFileToolsEnabled(true)
        }
    }

    private static func symbol(of kind: PluginGroup) -> String {
        switch kind {
        case .webSearch: "magnifyingglass"
        case .browser: "safari"
        case .files: "folder"
        case .time: "calendar"
        case .personal: "person.crop.circle"
        case .thisMac: "desktopcomputer"
        case .places: "map"
        case .calculations: "function"
        }
    }

    private static func title(of kind: PluginGroup) -> String {
        switch kind {
        case .webSearch: String(localized: "Internet Search")
        case .browser: String(localized: "Browser")
        case .files: String(localized: "Files")
        case .time: String(localized: "Time and Tasks")
        case .personal: String(localized: "Personal")
        case .thisMac: String(localized: "This Mac")
        case .places: String(localized: "Place and Weather")
        case .calculations: String(localized: "Calculations")
        }
    }

    private static func title(of tool: ExtraTool) -> String {
        switch tool {
        case .calculator: String(localized: "Calculator")
        case .macInfo: String(localized: "About This Mac")
        case .network: String(localized: "Network Diagnostics")
        case .weather: String(localized: "Weather")
        case .location: String(localized: "Maps and Location")
        case .trips: String(localized: "Trains, Flights and Buses")
        case .browser: String(localized: "Safari Control")
        case .calendar: String(localized: "Calendar and Reminders")
        case .timers: String(localized: "Timers")
        case .screen: String(localized: "Screen and Clipboard")
        case .currency: String(localized: "Exchange Rates")
        case .contacts: String(localized: "Contacts")
        case .notes: String(localized: "Notes")
        case .mail: String(localized: "Mail Drafts")
        case .spotlight: String(localized: "Spotlight Search")
        case .macControl: String(localized: "System Control")
        case .music: String(localized: "Music")
        }
    }

    private static func help(of tool: ExtraTool) -> String {
        switch tool {
        case .calculator: String(localized: "The model computes in JavaScript instead of doing arithmetic in its head")
        case .macInfo: String(localized: "The model may read this Mac's state: battery, disk space, memory, processes")
        case .network: String(localized: "The model may run ping, traceroute, DNS and port checks from this Mac")
        case .weather: String(localized: "The model may look up the weather (Open-Meteo)")
        case .location:
            String(localized: "The model may find out where this Mac is and use Apple Maps for routes, distances and places")
        case .trips:
            String(
                localized:
                    "The model may look up trains, flights, buses and commuter trains with seats and prices (Yandex Schedules) and give links to rzd.ru and Aviasales"
            )
        case .browser:
            String(
                localized:
                    "The model may open, read and click pages in your Safari; you approve typing and sending forms. Needs Safari's Develop → Allow JavaScript from Apple Events"
            )
        case .calendar: String(localized: "The model may read your events and reminders; you approve adding new ones")
        case .timers: String(localized: "The model may remind you with a notification after a while or at a set time")
        case .screen: String(localized: "The model may read the clipboard and, with your approval each time, the text on the screen")
        case .currency: String(localized: "The model may take the official rates of the Bank of Russia (cbr.ru)")
        case .contacts: String(localized: "The model may look up phone numbers, emails and addresses in your contacts")
        case .notes: String(localized: "The model may search and read your notes; you approve new ones")
        case .mail: String(localized: "The model may prepare an email in Mail; you send it yourself")
        case .spotlight:
            String(localized: "The model may find files anywhere on this Mac by name and content; opening them still needs folder access")
        case .macControl: String(localized: "The model may change the volume and the appearance and open apps")
        case .music: String(localized: "The model may play, pause and switch tracks in Music")
        }
    }
}

/// The shortcut field of System Settings: it shows the combination, a double click starts listening, and the next key
/// press with modifiers becomes the new one. While it listens the global shortcut is off, or pressing it would open
/// the panel instead of being recorded; Esc leaves the field as it was.
private struct ShortcutField: NSViewRepresentable {
    @Binding var combination: GlobalHotkey.Combination
    @Binding var recording: Bool

    func makeNSView(context: Context) -> Recorder {
        let view = Recorder()
        view.onCapture = { captured in
            combination = captured
            recording = false
        }
        view.onRecordingChange = { recording = $0 }
        return view
    }

    func updateNSView(_ view: Recorder, context: Context) {
        view.combination = combination
        view.recording = recording
        view.needsDisplay = true
    }

    final class Recorder: NSView {
        var combination = GlobalHotkey.Combination(keyCode: 0, modifiers: 0) { didSet { needsDisplay = true } }
        var recording = false { didSet { needsDisplay = true } }
        var onCapture: ((GlobalHotkey.Combination) -> Void)?
        var onRecordingChange: ((Bool) -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 22) }

        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2 else { return }
            window?.makeFirstResponder(self)
            recording = true
            onRecordingChange?(true)
            GlobalHotkey.shared.unregister()  // the combination being pressed must reach this field, not the panel
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }
            capture(event)
        }

        /// A combination with ⌘ never arrives as `keyDown`: the menus see it first, as a key equivalent.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            capture(event)
            return true
        }

        private func capture(_ event: NSEvent) {
            recording = false
            onRecordingChange?(false)
            guard event.keyCode != 53 else { return }  // Esc: keep what was there
            let modifiers = GlobalHotkey.carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else { return }  // a key on its own would fire while typing anywhere
            onCapture?(.init(keyCode: Int(event.keyCode), modifiers: modifiers))
        }

        override func resignFirstResponder() -> Bool {
            if recording {
                recording = false
                onRecordingChange?(false)
            }
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.quaternarySystemFill).setFill()
            shape.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            shape.lineWidth = recording ? 2 : 1
            shape.stroke()
            let text =
                recording
                ? String(localized: "Press the keys") : (GlobalHotkey.describe(combination) ?? String(localized: "not set"))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
