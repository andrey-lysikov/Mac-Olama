//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// SymbolButton

struct SymbolButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole?
    var size: CGFloat = 14
    var style = AnyShapeStyle(.secondary)
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(style)
        .accessibilityLabel(help)
    }
}

// Context and permission control

struct ContextPermissionControl: View {
    let used: Int
    let limit: Int?
    let modelName: String
    let mode: PermissionMode
    let compacting: Bool
    let canCompact: Bool
    let isEnabled: Bool
    let onMode: (PermissionMode) -> Void
    let onCompact: () -> Void

    private var fraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(max(Double(used) / Double(limit), 0), 1)
    }

    private var color: AnyShapeStyle {
        if let limit, used >= limit { return AnyShapeStyle(.red) }
        if fraction >= 0.9 { return AnyShapeStyle(.orange) }
        return AnyShapeStyle(Color.accentColor)
    }

    private var details: String {
        var lines = [String(localized: "Model: \(modelName)"), String(localized: "Context used: \(used.formatted()) tokens")]
        if let limit {
            lines.append(String(localized: "Context size: \(limit.formatted()) tokens"))
            lines.append(String(localized: "Context left: \(max(limit - used, 0).formatted()) tokens"))
            lines.append(String(localized: "Filled: \(fraction.formatted(.percent.precision(.fractionLength(0))))"))
        } else {
            lines.append(String(localized: "Context size is unknown"))
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        Button(action: openMenu) {
            Group {
                if compacting {
                    ProgressView().controlSize(.small)
                } else {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                            Text(verbatim: "\(Int((fraction * 100).rounded()))")
                            .font(.system(size: 7, weight: .medium)).monospacedDigit()
                            .frame(width: 14)
                    }
                }
            }
            .frame(width: 19, height: 19)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .fixedSize()
        .overlay { ContextMenuRightClick(action: openMenu, help: details) }
        .help(details)
        .accessibilityLabel(details)
    }

    private func openMenu() {
        let target = ContextPermissionMenuTarget(onMode: onMode, onCompact: onCompact)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in PermissionMode.allCases {
            let entry = NSMenuItem(title: item.title, action: #selector(ContextPermissionMenuTarget.chooseMode(_:)), keyEquivalent: "")
            entry.target = target
            entry.representedObject = item.rawValue
            entry.state = item == mode ? .on : .off
            entry.isEnabled = isEnabled
            entry.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
            if #available(macOS 27.0, *) { entry.preferredImageVisibility = .visible }
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let compactItem = NSMenuItem(
            title: String(localized: "Compact Chat"), action: #selector(ContextPermissionMenuTarget.compactChat), keyEquivalent: "")
        compactItem.target = target
        compactItem.isEnabled = canCompact
        compactItem.image = NSImage(systemSymbolName: "rectangle.compress.vertical", accessibilityDescription: compactItem.title)
        if #available(macOS 27.0, *) { compactItem.preferredImageVisibility = .visible }
        menu.addItem(compactItem)
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

private struct ContextMenuRightClick: NSViewRepresentable {
    let action: () -> Void
    let help: String

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.action = action
        view.toolTip = help
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.action = action
        view.toolTip = help
    }

    final class ClickView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .mouseMoved, .mouseEntered: self
            default: nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            MainActor.assumeIsolated { action?() }
        }
    }
}

@MainActor
private final class ContextPermissionMenuTarget: NSObject {
    let onMode: (PermissionMode) -> Void
    let onCompact: () -> Void

    init(onMode: @escaping (PermissionMode) -> Void, onCompact: @escaping () -> Void) {
        self.onMode = onMode
        self.onCompact = onCompact
    }

    @objc func chooseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = PermissionMode(rawValue: raw) else { return }
        onMode(mode)
    }

    @objc func compactChat() { onCompact() }
}

// CopyButton

struct CopyButton: View {
    let text: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
    }
}

// Attachment chips

struct DocumentChip: View {
    let name: String
    var onPreview: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Label(name, systemImage: "doc.text").lineLimit(1)
            if let onPreview {
                Button(action: onPreview) {
                    Image(systemName: "eye")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Preview"))
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Remove"))
            }
        }
        .font(.caption).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AttachmentThumbnail: View {
    let image: NSImage
    let side: CGFloat
    var onPreview: (() -> Void)?
    var onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            // The eye sits in the center and opens the preview.
            if let onPreview, hovering {
                Button(action: onPreview) {
                    Image(systemName: "eye").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white).padding(6).background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .frame(width: side, height: side)
                .accessibilityLabel(String(localized: "Preview"))
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).offset(x: 4, y: -4)
                .accessibilityLabel(String(localized: "Remove"))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// Pending attachment previews (the composer row)

struct ImagePreviewPopover: View {
    let image: NSImage
    @Binding var isPresented: Bool

    var body: some View {
        Image(nsImage: image).resizable().scaledToFit()
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { isPresented = false }
            .contextMenu {
                Button(String(localized: "Copy Image")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
            .onDrag { NSItemProvider(object: image) }
            .padding(8)
    }

    private var size: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        guard image.size.width > 0, image.size.height > 0 else { return CGSize(width: 320, height: 320) }
        let scale = min(1, screen.width * 0.6 / image.size.width, screen.height * 0.7 / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }
}

struct DocumentPreviewPopover: View {
    let document: DocumentInput
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(document.name, systemImage: "doc.text").font(.headline).lineLimit(1)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Close"))
            }
            Divider()
            ScrollView {
                Text(document.text.isEmpty ? String(localized: "The document is empty.") : document.text)
                    .font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 420, height: 360)
    }
}

// ZoomableThumbnail

struct ZoomableThumbnail: View {
    let image: NSImage
    let side: CGFloat
    @State private var hovering = false
    @State private var zoomed = false

    var body: some View {
        AttachmentThumbnail(image: image, side: side)
            .overlay(alignment: .bottomTrailing) {
                if hovering {
                    Button {
                        zoomed = true
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white).padding(5).background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain).padding(4)
                    .accessibilityLabel(String(localized: "Enlarge"))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { zoomed = true }
            .contextMenu { copyButton }
            .onDrag { NSItemProvider(object: image) }
            .popover(isPresented: $zoomed) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: zoomedSize.width, height: zoomedSize.height)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { zoomed = false }
                    .contextMenu { copyButton }
                    .onDrag { NSItemProvider(object: image) }
                    .padding(8)
            }
    }

    private var copyButton: some View {
        Button(String(localized: "Copy Image")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    private var zoomedSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let size = image.size
        guard size.width > 0, size.height > 0 else { return CGSize(width: 320, height: 320) }
        let scale = min(1, screen.width * 0.6 / size.width, screen.height * 0.7 / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

// ChoiceMenu

struct ChoiceMenu<Item: Hashable, Row: View, Footer: View, MenuLabel: View>: View {
    let items: [Item]
    let choose: (Item) -> Void
    let isEnabled: (Item) -> Bool
    let row: (Item) -> Row
    let footer: Footer
    let label: MenuLabel

    init(
        items: [Item], choose: @escaping (Item) -> Void,
        isEnabled: @escaping (Item) -> Bool = { _ in true },
        @ViewBuilder row: @escaping (Item) -> Row, @ViewBuilder footer: () -> Footer,
        @ViewBuilder label: () -> MenuLabel
    ) {
        self.items = items
        self.choose = choose
        self.isEnabled = isEnabled
        self.row = row
        self.footer = footer()
        self.label = label()
    }

    var body: some View {
        Menu {
            ForEach(items, id: \.self) { item in
                Button { choose(item) } label: { row(item) }
                    .disabled(!isEnabled(item))
            }
            footer
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
    }
}

extension ChoiceMenu where Footer == EmptyView {
    init(
        items: [Item], choose: @escaping (Item) -> Void,
        isEnabled: @escaping (Item) -> Bool = { _ in true },
        @ViewBuilder row: @escaping (Item) -> Row, @ViewBuilder label: () -> MenuLabel
    ) {
        self.init(items: items, choose: choose, isEnabled: isEnabled, row: row, footer: { EmptyView() }, label: label)
    }
}

// Attachment drop

enum AttachableTypes {
    static let documents: [UTType] = [.pdf, .text, .sourceCode, .json, .rtf]
}

private struct AttachmentDropModifier: ViewModifier {
    var acceptsImages = true
    let onFile: @MainActor (URL) -> Void
    let onWeb: @MainActor (URL) -> Void
    let onImage: @MainActor (NSImage) -> Void

    func body(content: Content) -> some View {
        content.onDrop(of: [.fileURL, .url, .image], isTargeted: nil) { providers in
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                        guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        Task { @MainActor in onFile(url) }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                        guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isWebURL
                        else { return }
                        Task { @MainActor in onWeb(url) }
                    }
                } else if acceptsImages, provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                        guard let image = image as? NSImage else { return }
                        Task { @MainActor in onImage(image) }
                    }
                }
            }
            return true
        }
    }
}

extension View {
    func attachmentDrop(
        acceptsImages: Bool = true,
        onFile: @escaping @MainActor (URL) -> Void,
        onWeb: @escaping @MainActor (URL) -> Void,
        onImage: @escaping @MainActor (NSImage) -> Void
    ) -> some View {
        modifier(AttachmentDropModifier(acceptsImages: acceptsImages, onFile: onFile, onWeb: onWeb, onImage: onImage))
    }

    func focusOnNewAttachment(count: Int, focus: @escaping @MainActor () -> Void) -> some View {
        onChange(of: count) { old, new in
            guard new > old else { return }
            focus()
        }
    }

    func glassCard(radius: CGFloat = 22) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    func searchCapsule() -> some View {
        padding(.horizontal, 12).frame(height: 38).glassEffect(.regular.interactive(), in: Capsule())
    }
}

// Byte counts

extension Int64 {
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
    var memorySizeText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .memory) }
}
