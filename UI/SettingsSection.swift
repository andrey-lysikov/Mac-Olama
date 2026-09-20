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
                group(String(localized: "Model permissions")) { permissions }
                group(String(localized: "Web pages")) { web }
                group(String(localized: "Unload the model automatically")) { unloading }
                group(String(localized: "Panel behaviour")) { panel }
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

    // Sections

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(String(localized: "Web search")) {
                HStack(spacing: 10) {
                    if container.settings.toolsEnabled {
                        Picker(
                            "",
                            selection: Binding(
                                get: { container.settings.searchProvider == "google" ? "google" : "duckduckgo" },
                                set: { container.setSearchProvider($0) })
                        ) {
                            Text(verbatim: "DuckDuckGo").tag("duckduckgo")
                            Text(verbatim: "Google").tag("google")
                        }
                        .labelsHidden().frame(width: 160)
                    }
                    Toggle("", isOn: Binding(get: { container.settings.toolsEnabled }, set: { container.setToolsEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            row(String(localized: "Folder access")) {
                Toggle("", isOn: Binding(get: { container.settings.fileToolsEnabled }, set: { container.setFileToolsEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
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
            row(String(localized: "Shortcuts"), help: String(localized: "The model may run yours, asking each time")) {
                Toggle(
                    "", isOn: Binding(get: { container.settings.shortcutsToolEnabled }, set: { container.setShortcutsToolEnabled($0) })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            ForEach(ExtraTool.allCases, id: \.self) { tool in
                row(Self.title(of: tool), help: Self.help(of: tool)) {
                    Toggle("", isOn: Binding(get: { container.isToolEnabled(tool) }, set: { container.setToolEnabled(tool, $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    private var web: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(String(localized: "Read from a page"), help: String(localized: "A longer page is cut to this many characters")) {
                Picker("", selection: Binding(get: { container.settings.pageCharacters }, set: { container.setPageCharacters($0) })) {
                    ForEach(Self.pageSizes, id: \.self) { size in
                        Text(verbatim: "\(size / 1000)k").tag(size)
                    }
                }
                .labelsHidden().frame(width: 120)
            }
            row(String(localized: "Search results per query")) {
                Picker("", selection: Binding(get: { container.settings.searchResults }, set: { container.setSearchResults($0) })) {
                    ForEach(Self.searchCounts, id: \.self) { count in
                        Text(verbatim: "\(count)").tag(count)
                    }
                }
                .labelsHidden().frame(width: 120)
            }
            row(
                String(localized: "Requests in a row"),
                help: String(localized: "How many searches and pages the model may take before it answers")
            ) {
                Picker("", selection: Binding(get: { container.settings.toolIterations }, set: { container.setToolIterations($0) })) {
                    ForEach(Self.toolRounds, id: \.self) { rounds in
                        Text(verbatim: "\(rounds)").tag(rounds)
                    }
                }
                .labelsHidden().frame(width: 120)
            }
        }
    }

    private var unloading: some View {
        row(String(localized: "After idling"), help: container.engineState.modelID) {
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { container.settings.idleUnloadSeconds }, set: { container.setIdleTimeout($0) })) {
                    ForEach(Self.idleTimeouts, id: \.1) { title, seconds in
                        Text(title).tag(seconds)
                    }
                }
                .labelsHidden().frame(width: 160)
                Button(String(localized: "Unload Now")) { container.unloadNow() }
                    .disabled(container.engineState.modelID == nil)
                    .fixedSize()
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(String(localized: "Close the panel when it loses focus")) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { container.settings.panelClosesOnFocusLoss }, set: { container.setPanelClosesOnFocusLoss($0) })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
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

    private var api: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(
                String(localized: "Answer other programs"),
                help: String(localized: "Ollama and OpenAI-compatible clients reach the models through this app")
            ) {
                Toggle("", isOn: Binding(get: { container.settings.apiServerEnabled }, set: { container.setAPIEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            interfaceRow.disabled(!container.settings.apiServerEnabled)
        }
    }

    private var interfaceRow: some View {
        row(String(localized: "Interface"), help: container.apiURL.absoluteString) {
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { container.settings.apiBindHost }, set: { container.setAPIBindHost($0) })) {
                    Text(String(localized: "This Mac only")).tag("127.0.0.1")
                    Text(String(localized: "All")).tag("0.0.0.0")
                    ForEach(NetworkInterfaces.addresses(), id: \.address) { interface in
                        Text(verbatim: "\(interface.name) · \(interface.address)").tag(interface.address)
                    }
                }
                .labelsHidden().frame(width: 220)
                // The port sits with the interface: together they are the address, and a busy one moves to the next free.
                Text(String(localized: "Port")).foregroundStyle(.secondary)
                TextField(
                    "",
                    value: Binding(get: { container.settings.apiServerPort }, set: { container.setAPIPort($0) }),
                    format: .number.grouping(.never)
                )
                .frame(width: 80).multilineTextAlignment(.trailing)
                .help(String(localized: "A busy port moves the server to the next free one"))
            }
        }
    }

    // Building blocks

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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    private static func title(of tool: ExtraTool) -> String {
        switch tool {
        case .calculator: String(localized: "Calculator")
        case .macInfo: String(localized: "About This Mac")
        case .network: String(localized: "Network Diagnostics")
        case .weather: String(localized: "Weather")
        }
    }

    private static func help(of tool: ExtraTool) -> String {
        switch tool {
        case .calculator: String(localized: "The model computes in JavaScript instead of doing arithmetic in its head")
        case .macInfo: String(localized: "The model may read this Mac's state: battery, disk space, memory, processes")
        case .network: String(localized: "The model may run ping, traceroute, DNS and port checks from this Mac")
        case .weather: String(localized: "The model may look up the weather (Open-Meteo)")
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
