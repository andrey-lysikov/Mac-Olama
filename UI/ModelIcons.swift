//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreImage
import SwiftUI
import os

// ModelIcons

/// A model's icon is the avatar of its author (the owner of the base model: Google, Qwen…) with the avatar of the community
/// that built this copy (mlx-community, lmstudio-community…) in the corner. Avatars come from Hugging Face for both hubs
/// (ModelScope uses the same account names), are turned greyscale like every other pictogram and cached in `icons/`.
@MainActor
@Observable
final class ModelIcons {
    static let shared = ModelIcons()

    /// Bumped when an avatar arrives: views reading an icon redraw, menus pick it up the next time they are built.
    private(set) var revision = 0
    @ObservationIgnored var directory = AppPaths.standard().icons
    @ObservationIgnored private var avatars: [String: NSImage] = [:]
    @ObservationIgnored private var unavailable: Set<String> = []
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var composed: [String: NSImage] = [:]
    nonisolated private static let logger = Logger(subsystem: "com.macolama.app", category: "icons")

    /// The account's avatar, or nil while it loads (or when the account has none).
    func avatar(_ owner: String) -> NSImage? {
        _ = revision
        let key = owner.lowercased()
        if let image = avatars[key] { return image }
        if unavailable.contains(key) { return nil }
        if let image = NSImage(contentsOf: file(for: key)) {
            avatars[key] = image
            return image
        }
        load(owner, key: key)
        return nil
    }

    /// Author's avatar with the community's in the lower right corner, or the community's alone when the author is unknown.
    func icon(for owners: ModelOwners, size: CGFloat) -> NSImage? {
        let author = owners.author.flatMap(avatar)
        let community = owners.community.flatMap(avatar)
        guard let main = author ?? community else { return nil }
        let badge = author != nil ? community : nil
        let key = "\(owners.author ?? "")|\(owners.community ?? "")|\(size)|\(badge != nil)"
        if let image = composed[key] { return image }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = rect.width * 0.22
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            main.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            if let badge {
                // A ring in the window colour separates the badge from the author's avatar under it.
                let side = rect.width * 0.55
                let badgeRect = NSRect(x: rect.maxX - side, y: rect.minY, width: side, height: side)
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
                let inner = badgeRect.insetBy(dx: side * 0.1, dy: side * 0.1)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: inner).addClip()
                badge.draw(in: inner)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        composed[key] = image
        return image
    }

    private func file(for key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    private func load(_ owner: String, key: String) {
        guard loading.insert(key).inserted else { return }
        Task {
            let png = await Self.fetchGreyscalePNG(owner: owner)
            loading.remove(key)
            guard let png, let image = NSImage(data: png) else {
                unavailable.insert(key)  // until the next launch: no avatar, or no network right now
                return
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? png.write(to: file(for: key), options: .atomic)
            avatars[key] = image
            composed.removeAll()
            revision += 1
        }
    }

    /// An account is either an organisation or a user; Hugging Face answers `{"avatarUrl": …}` for the right one.
    nonisolated private static func fetchGreyscalePNG(owner: String) async -> Data? {
        for kind in ["organizations", "users"] {
            guard let api = URL(string: "https://huggingface.co/api/\(kind)/\(owner)/avatar"),
                let (data, response) = try? await URLSession.shared.data(from: api),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let link = (json["avatarUrl"] as? String).flatMap(URL.init(string:)),
                let (imageData, _) = try? await URLSession.shared.data(from: link)
            else { continue }
            if let png = greyscalePNG(imageData, side: 64) { return png }
        }
        logger.info("No avatar for \(owner, privacy: .public)")
        return nil
    }

    /// Square, greyscale, `side` pixels: small enough to keep in the cache folder, sharp at 20 pt on Retina.
    nonisolated private static func greyscalePNG(_ data: Data, side: Int) -> Data? {
        guard let input = CIImage(data: data), let filter = CIFilter(name: "CIPhotoEffectMono") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage, output.extent.width > 0, output.extent.height > 0,
            let cg = CIContext().createCGImage(output, from: output.extent),
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Centre-crop to a square, as the hubs show avatars.
        let scale = CGFloat(side) / min(output.extent.width, output.extent.height)
        let drawn = CGSize(width: output.extent.width * scale, height: output.extent.height * scale)
        context.interpolationQuality = .high
        context.draw(
            cg,
            in: CGRect(
                x: (CGFloat(side) - drawn.width) / 2, y: (CGFloat(side) - drawn.height) / 2, width: drawn.width, height: drawn.height))
        guard let square = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: square).representation(using: .png, properties: [:])
    }

    /// For menus built by AppKit: the icon, or the hub's symbol until the avatar has arrived.
    func menuImage(for model: ModelDescriptor, size: CGFloat) -> NSImage? {
        if model.source != .remote, let icon = icon(for: model.owners, size: size) { return icon }
        let image = NSImage(systemSymbolName: model.source.symbol, accessibilityDescription: model.source.displayName)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular))
        image?.isTemplate = true
        return image
    }
}

// ModelIconView

/// The model icon in SwiftUI lists; the hub's symbol stands in until the avatars arrive (and for models served over the API).
struct ModelIconView: View {
    let owners: ModelOwners?
    let source: ModelSource
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let owners, source != .remote, let image = ModelIcons.shared.icon(for: owners, size: size) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: source.symbol).font(.system(size: size * 0.7)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .help(helpText)
    }

    private var helpText: String {
        [owners?.author, owners?.community].compactMap { $0 }.joined(separator: " · ")
    }
}
