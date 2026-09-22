//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import MapKit
import SwiftUI

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

// TranscriptMap

/// A map a tool answered with: the points of a route or the places found, stored with the tool's result so the feed
/// draws it as it was, without asking Maps again. The model never reads it: `ToolMapNote.strip` cuts it from the context.
struct TranscriptMap: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        var lat: Double
        var lon: Double
        var name: String?
        /// The user's own place, drawn as "You are here".
        var here: Bool?

        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    }

    enum Kind: String, Codable, Sendable { case route, places }

    var kind: Kind
    /// driving, walking or transit, for a route.
    var mode: String?
    var points: [Point]
    /// The route's line as [lat, lon] pairs, thinned to a few hundred; nil when Maps gave no route.
    var line: [[Double]]?

    /// The same points in Yandex Maps, which builds its own route there. Only the points leave the app: showing
    /// Yandex's data in it would need Yandex's own map, the condition of its API.
    var yandexURL: URL? {
        var components = URLComponents(string: "https://yandex.ru/maps/")
        switch kind {
        case .route:
            let travel = mode == "walking" ? "pd" : mode == "transit" ? "mt" : "auto"
            components?.queryItems = [
                URLQueryItem(name: "rtext", value: points.map { "\($0.lat),\($0.lon)" }.joined(separator: "~")),
                URLQueryItem(name: "rtt", value: travel),
            ]
        case .places:
            // Yandex writes a placemark longitude first.
            var items = [URLQueryItem(name: "pt", value: points.map { "\($0.lon),\($0.lat)" }.joined(separator: "~"))]
            if let only = points.first, points.count == 1 {
                items += [URLQueryItem(name: "ll", value: "\(only.lon),\(only.lat)"), URLQueryItem(name: "z", value: "15")]
            }
            components?.queryItems = items
        }
        return components?.url
    }

    /// A route line for storing: every few points of Maps' polyline, the last one kept, five decimals (about a metre).
    static func line(of polyline: MKPolyline, limit: Int = 300) -> [[Double]] {
        let count = polyline.pointCount
        guard count > 1 else { return [] }
        let points = polyline.points()
        let step = max(1, Int((Double(count) / Double(limit)).rounded(.up)))
        let indices = Array(stride(from: 0, to: count, by: step)) + ((count - 1) % step == 0 ? [] : [count - 1])
        return indices.map { index in
            let coordinate = points[index].coordinate
            return [(coordinate.latitude * 1e5).rounded() / 1e5, (coordinate.longitude * 1e5).rounded() / 1e5]
        }
    }
}

// ToolMapNote

/// How a map rides along with a tool's result: one tagged line at its end, cut out before the model sees it.
enum ToolMapNote {
    private static let open = "<mac-olama-map>"
    private static let close = "</mac-olama-map>"

    static func append(_ map: TranscriptMap, to text: String) -> String {
        guard let data = try? JSONEncoder().encode(map), let json = String(data: data, encoding: .utf8) else { return text }
        return text + "\n" + open + json + close
    }

    static func strip(_ text: String) -> String {
        guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else {
            return text
        }
        var stripped = text
        stripped.removeSubrange(start.lowerBound..<end.upperBound)
        return stripped.trimmingCharacters(in: .newlines)
    }

    static func map(in text: String) -> TranscriptMap? {
        guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return try? JSONDecoder().decode(TranscriptMap.self, from: Data(text[start.upperBound..<end.lowerBound].utf8))
    }
}

// TranscriptMaps

/// The maps the tool rounds before each answer brought, keyed by that answer. A tool result is parsed once.
@MainActor
enum TranscriptMaps {
    /// Bounded: it would otherwise keep an entry for every tool result ever shown, deleted chats included. An evicted one
    /// is parsed again from the message.
    private static let parsed: NSCache<NSUUID, Parsed> = {
        let cache = NSCache<NSUUID, Parsed>()
        cache.countLimit = 500
        return cache
    }()

    /// `NSCache` holds objects; a message without a map is remembered too, so it is not scanned again.
    private final class Parsed {
        let map: TranscriptMap?
        init(_ map: TranscriptMap?) { self.map = map }
    }

    static func byAnswer(_ messages: [Message]) -> [UUID: [TranscriptMap]] {
        var result: [UUID: [TranscriptMap]] = [:]
        var pending: [TranscriptMap] = []
        for message in messages {
            switch message.role {
            case .user:
                pending = []
            case .tool:
                if let map = map(of: message) { pending.append(map) }
            case .assistant where message.toolCalls.isEmpty:
                if !pending.isEmpty { result[message.id] = pending }
                pending = []
            default:
                break
            }
        }
        return result
    }

    private static func map(of message: Message) -> TranscriptMap? {
        if let known = parsed.object(forKey: message.id as NSUUID) { return known.map }
        let map = ToolMapNote.map(in: message.text)
        parsed.setObject(Parsed(map), forKey: message.id as NSUUID)
        return map
    }
}

// TranscriptMapView

/// A route or the places found, under the answer. It takes no clicks or scrolling, so the feed keeps scrolling over
/// it; the buttons open it in Apple Maps or in Yandex Maps for anything more.
struct TranscriptMapView: View {
    let map: TranscriptMap
    var height: CGFloat

    var body: some View {
        Map(initialPosition: position, interactionModes: []) {
            ForEach(Array(map.points.enumerated()), id: \.offset) { _, point in
                if point.here == true {
                    Marker(String(localized: "You are here"), systemImage: "location.fill", coordinate: point.coordinate)
                } else {
                    Marker(point.name ?? "", coordinate: point.coordinate)
                }
            }
            if let line = map.line, line.count > 1 {
                MapPolyline(coordinates: line.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) })
                    .stroke(Color.accentColor, lineWidth: 4)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 6) {
                Button(String(localized: "Maps"), systemImage: "map", action: openInAppleMaps)
                    .help(String(localized: "Open in Apple Maps"))
                if let url = map.yandexURL {
                    Button(String(localized: "Yandex Maps"), systemImage: "arrow.up.right") { NSWorkspace.shared.open(url) }
                        .help(String(localized: "Open in Yandex Maps"))
                }
            }
            .buttonStyle(.glass).controlSize(.small)
            .padding(8)
        }
    }

    /// A lone point would be drawn at the closest zoom; a street's width around it reads better.
    private var position: MapCameraPosition {
        guard map.points.count == 1, map.line == nil, let point = map.points.first else { return .automatic }
        return .region(MKCoordinateRegion(center: point.coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))
    }

    private func openInAppleMaps() {
        let items = map.points.map { point in
            let item = MKMapItem(location: CLLocation(latitude: point.lat, longitude: point.lon), address: nil)
            item.name = point.here == true ? String(localized: "You are here") : point.name
            return item
        }
        var options: [String: Any] = [:]
        if map.kind == .route {
            options[MKLaunchOptionsDirectionsModeKey] =
                map.mode == "walking"
                ? MKLaunchOptionsDirectionsModeWalking
                : map.mode == "transit" ? MKLaunchOptionsDirectionsModeTransit : MKLaunchOptionsDirectionsModeDriving
        }
        MKMapItem.openMaps(with: items, launchOptions: options)
    }
}
