//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

// Small controls and modifiers shared by the chats window, the quick panel and the models section.

// SymbolButton

/// List actions are bare pictograms, not framed buttons. The style is a parameter because a modifier applied
/// outside this view would lose to the default one applied closer to the image.
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
        .help(help)
        .accessibilityLabel(help)
    }
}

// CopyButton

/// The copy pictogram under replies and on code cards: puts `text` on the pasteboard.
/// Button style and colour come from the surroundings, as before the extraction.
struct CopyButton: View {
    let text: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .help(String(localized: "Copy"))
    }
}

// Attachment chips

/// A document attachment as a chip; the cross removes a pending one.
struct DocumentChip: View {
    let name: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Label(name, systemImage: "doc.text").lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// An image attachment as a rounded thumbnail; the cross removes a pending one.
struct AttachmentThumbnail: View {
    let image: NSImage
    let side: CGFloat
    var onRemove: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).offset(x: 4, y: -4)
            }
        }
    }
}

// CheckedMenu

/// A borderless menu where the row in use carries the system check mark: each row is a Toggle whose binding only
/// ever selects. Shared by the chat's model picker and the per-model context and temperature menus.
struct CheckedMenu<Item: Hashable, Row: View, Footer: View, MenuLabel: View>: View {
    let items: [Item]
    let isChosen: (Item) -> Bool
    let choose: (Item) -> Void
    let isEnabled: (Item) -> Bool
    let row: (Item) -> Row
    let footer: Footer
    let label: MenuLabel

    init(
        items: [Item], isChosen: @escaping (Item) -> Bool, choose: @escaping (Item) -> Void,
        isEnabled: @escaping (Item) -> Bool = { _ in true },
        @ViewBuilder row: @escaping (Item) -> Row, @ViewBuilder footer: () -> Footer,
        @ViewBuilder label: () -> MenuLabel
    ) {
        self.items = items
        self.isChosen = isChosen
        self.choose = choose
        self.isEnabled = isEnabled
        self.row = row
        self.footer = footer()
        self.label = label()
    }

    var body: some View {
        Menu {
            ForEach(items, id: \.self) { item in
                Toggle(isOn: Binding(get: { isChosen(item) }, set: { _ in choose(item) })) { row(item) }
                    .disabled(!isEnabled(item))
            }
            footer
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
    }
}

extension CheckedMenu where Footer == EmptyView {
    init(
        items: [Item], isChosen: @escaping (Item) -> Bool, choose: @escaping (Item) -> Void,
        isEnabled: @escaping (Item) -> Bool = { _ in true },
        @ViewBuilder row: @escaping (Item) -> Row, @ViewBuilder label: () -> MenuLabel
    ) {
        self.init(items: items, isChosen: isChosen, choose: choose, isEnabled: isEnabled, row: row, footer: { EmptyView() }, label: label)
    }
}

// Attachment drop

/// Document types the attach dialogs and drops accept; images are added when the model understands them.
enum AttachableTypes {
    static let documents: [UTType] = [.pdf, .text, .sourceCode, .json, .rtf]
}

/// The three shapes a drop can take: a file, a web link (its page text becomes a document), a raw image.
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
    /// Dropping a file, a link or an image on the composer attaches it; shared by the chats window and the panel.
    func attachmentDrop(
        acceptsImages: Bool = true,
        onFile: @escaping @MainActor (URL) -> Void,
        onWeb: @escaping @MainActor (URL) -> Void,
        onImage: @escaping @MainActor (NSImage) -> Void
    ) -> some View {
        modifier(AttachmentDropModifier(acceptsImages: acceptsImages, onFile: onFile, onWeb: onWeb, onImage: onImage))
    }

    /// A new attachment (paste, drop, file picker, link) puts the caret in the field, ready for the question.
    /// `count` is the total number of pending attachments; only growth moves the focus.
    func focusOnNewAttachment(count: Int, focus: @escaping @MainActor () -> Void) -> some View {
        onChange(of: count) { old, new in
            guard new > old else { return }
            focus()
        }
    }

    /// The rounded Liquid Glass card of the composer, the models card and the settings groups.
    func glassCard(radius: CGFloat = 22) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// The glass capsule around a search field, as the stock apps draw it: interactive, so it answers the pointer the
    /// way the glass buttons beside it do.
    func searchCapsule() -> some View {
        padding(.horizontal, 10).frame(height: 30).glassEffect(.regular.interactive(), in: Capsule())
    }
}

// Byte counts

extension Int64 {
    /// `ByteCountFormatter` written once: file sizes in lists, menus and download lines.
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
    /// Memory amounts (powers of two), as the fit verdicts read them.
    var memorySizeText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .memory) }
}
