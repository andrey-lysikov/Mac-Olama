//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreImage
import ImageIO
import SwiftUI

// ModelIcons

@MainActor
@Observable
final class ModelIcons {
    static let shared = ModelIcons()

    private(set) var revision = 0
    @ObservationIgnored var directory = AppPaths.standard().icons
    @ObservationIgnored private let avatars: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()
    @ObservationIgnored private var unavailable: Set<String> = []
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private let composed: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    func avatar(_ owner: String) -> NSImage? {
        _ = revision
        let key = owner.lowercased()
        if let image = avatars.object(forKey: key as NSString) { return image }
        if unavailable.contains(key) { return nil }
        if let image = NSImage(contentsOf: file(for: key)) {
            avatars.setObject(image, forKey: key as NSString)
            return image
        }
        load(owner, key: key)
        return nil
    }

    func icon(for owners: ModelOwners, size: CGFloat) -> NSImage? {
        let author = owners.author.flatMap(avatar)
        let community = owners.community.flatMap(avatar)
        guard let main = author ?? community else { return nil }
        let badge = author != nil ? community : nil
        let key = "\(owners.author ?? "")|\(owners.community ?? "")|\(size)|\(badge != nil)"
        if let image = composed.object(forKey: key as NSString) { return image }
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
        composed.setObject(image, forKey: key as NSString)
        return image
    }

    static func rounded(_ image: NSImage, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22).addClip()
            image.draw(in: rect)
            return true
        }
    }

    private func file(for key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + "-colour.png")
    }

    private func load(_ owner: String, key: String) {
        guard loading.insert(key).inserted else { return }
        Task {
            let png = await Self.fetchPNG(owner: owner)
            loading.remove(key)
            guard let png, let image = NSImage(data: png) else {
                unavailable.insert(key)  // until next launch
                return
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? png.write(to: file(for: key), options: .atomic)
            avatars.setObject(image, forKey: key as NSString)
            composed.removeAllObjects()
            revision += 1
        }
    }

    nonisolated private static func fetchPNG(owner: String) async -> Data? {
        for kind in ["organizations", "users"] {
            guard let api = URL(string: "https://huggingface.co/api/\(kind)/\(owner)/avatar"),
                let (data, response) = try? await URLSession.shared.data(from: api),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let link = (json["avatarUrl"] as? String).flatMap(URL.init(string:)),
                let (imageData, imageResponse) = try? await URLSession.shared.data(from: link),
                let http = imageResponse as? HTTPURLResponse, http.statusCode == 200,
                http.mimeType?.hasPrefix("image/") != false
            else { continue }
            if let png = squarePNG(imageData, side: 64) { return png }
        }
        return nil
    }

    nonisolated private static func squarePNG(_ data: Data, side: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(source) != nil,
            let output = CIImage(data: data), output.extent.width > 0, output.extent.height > 0,
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

    func providerImage(_ provider: CloudProvider, size: CGFloat) -> NSImage? {
        guard let image = NSImage(named: provider.iconName) else { return nil }
        return Self.rounded(image, side: size)
    }

    func menuImage(for model: ModelDescriptor, size: CGFloat) -> NSImage? {
        if let provider = CloudProvider(source: model.source), let image = providerImage(provider, size: size) { return image }
        if !model.source.isRemote, let icon = icon(for: model.owners, size: size) { return icon }
        let image = NSImage(systemSymbolName: model.source.symbol, accessibilityDescription: model.source.displayName)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular))
        image?.isTemplate = true
        return image
    }
}

// ModelIconView

struct ModelIconView: View {
    let owners: ModelOwners?
    let source: ModelSource
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let provider = CloudProvider(source: source), let image = ModelIcons.shared.providerImage(provider, size: size) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if let owners, !source.isRemote, let image = ModelIcons.shared.icon(for: owners, size: size) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: source.symbol).font(.system(size: size * 0.7)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
