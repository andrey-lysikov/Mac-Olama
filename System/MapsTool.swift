//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import CoreLocation
import Foundation
import MapKit

// Maps

/// `get_route`, `search_places` and `geocode`: Apple Maps through MapKit, no key. They share one switch with
/// `get_location`, so a start or a search centre left out is where this Mac is.
public struct MapsToolProvider: ToolProvider {
    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "get_route",
                description:
                    "Distance by road and travel time between two places, from Apple Maps: by car (up to three routes with the roads they take and tolls), on foot, or by public transport (time only). Also gives the straight-line distance.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"to":{"type":"string","description":"Destination: a city, address or place name, or \"lat, lon\""},"from":{"type":"string","description":"Start, in the same form. Leave it out to start where the user is now"},"mode":{"type":"string","enum":["driving","walking","transit"],"description":"How to travel (default driving)"}},"required":["to"]}"#
            ),
            ToolSpec(
                name: "search_places",
                description:
                    "Places of a kind near a point, from Apple Maps, nearest first: name, address, straight-line distance, phone and website when known. For a pharmacy, a café, a petrol station, a bank branch and the like.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"query":{"type":"string","description":"What to look for, e.g. pharmacy or Sberbank ATM"},"near":{"type":"string","description":"City, address or place to search around. Leave it out to search around the user"},"limit":{"type":"integer","description":"How many places, 1 to 10 (default 5)"}},"required":["query"]}"#
            ),
            ToolSpec(
                name: "geocode",
                description:
                    "The full address and coordinates of a place name or address, or the address at coordinates, from Apple Maps.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"query":{"type":"string","description":"An address or place name, or coordinates as \"lat, lon\""}},"required":["query"]}"#
            ),
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        let text = { (key: String) in args.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        do {
            switch call.name {
            case "get_route":
                guard let to = text("to") else { return toolFailure(missing: "to") }
                return try await MapLookup.route(from: text("from"), to: to, mode: text("mode") ?? "driving")
            case "search_places":
                guard let query = text("query") else { return toolFailure(missing: "query") }
                let limit = args.int("limit") ?? text("limit").flatMap { Int($0) } ?? 5
                return try await MapLookup.places(query, near: text("near"), limit: min(max(limit, 1), 10))
            case "geocode":
                guard let query = text("query") else { return toolFailure(missing: "query") }
                return try await MapLookup.geocode(query)
            default:
                throw ConversationError.unknownTool(call.name)
            }
        } catch let failure as LocationService.Failure {
            return failure.toolText
        } catch let error as ConversationError {
            throw error
        } catch {
            return "error: Apple Maps did not answer (\(error.localizedDescription))"
        }
    }
}

/// The MapKit side. Its requests answer on the main actor, so the whole lookup runs there.
@MainActor
enum MapLookup {
    /// A place the tools talk about: what to call it in the answer, and where it is.
    struct Point {
        var label: String
        var location: CLLocation
        var item: MKMapItem
        /// What its marker on the feed's map says; nil for the user's own place, which is marked as such.
        var name: String?
        var isUser = false

        var mapPoint: TranscriptMap.Point {
            let point = location.coordinate
            return TranscriptMap.Point(lat: point.latitude, lon: point.longitude, name: name, here: isUser ? true : nil)
        }
    }

    static func route(from start: String?, to end: String, mode: String) async throws -> String {
        guard let destination = try await find(end) else { return notFound(end) }
        let origin: Point
        if let start {
            guard let found = try await find(start) else { return notFound(start) }
            origin = found
        } else {
            origin = try await here()
        }
        let request = MKDirections.Request()
        request.source = origin.item
        request.destination = destination.item
        request.transportType = mode == "walking" ? .walking : mode == "transit" ? .transit : .automobile
        request.requestsAlternateRoutes = mode == "driving"
        let how = mode == "walking" ? "on foot" : mode == "transit" ? "by public transport" : "by car"
        var lines = ["Route from \(origin.label) to \(destination.label), \(how) (Apple Maps):"]
        var map = TranscriptMap(kind: .route, mode: mode, points: [origin.mapPoint, destination.mapPoint])
        do {
            if mode == "transit" {
                // Apple Maps gives public transport as a travel time, not as a route to follow.
                let eta = try await MKDirections(request: request).calculateETA()
                lines.append("About \(duration(eta.expectedTravelTime)), \(distance(eta.distance)).")
            } else {
                let routes = try await MKDirections(request: request).calculate().routes
                map.line = routes.first.map { TranscriptMap.line(of: $0.polyline) }
                for (index, route) in routes.prefix(3).enumerated() {
                    var parts = [distance(route.distance), "about " + duration(route.expectedTravelTime)]
                    if !route.name.isEmpty { parts.append("via " + route.name) }
                    if route.hasTolls { parts.append("tolls") }
                    lines.append("\(index + 1). " + parts.joined(separator: ", "))
                    lines += route.advisoryNotices.map { "   Note: " + $0 }
                }
            }
        } catch {
            // Maps refuses a route when a road is closed (Krasnodar to Khadyzhensk by car, while on foot it has one):
            // its reason and the straight line still give the model something true to say.
            let reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
            lines.append("Apple Maps gives no route \(how) right now: \(reason). Another mode of travel may still have one.")
        }
        lines.append("Straight-line distance: " + distance(origin.location.distance(from: destination.location)))
        return ToolMapNote.append(map, to: ToolOutput.wrap(lines.joined(separator: "\n"), source: "get_route: \(end)"))
    }

    static func places(_ query: String, near centre: String?, limit: Int) async throws -> String {
        let around: Point
        if let centre {
            guard let found = try await find(centre) else { return notFound(centre) }
            around = found
        } else {
            around = try await here()
        }
        let request = MKLocalSearch.Request(
            naturalLanguageQuery: query,
            region: MKCoordinateRegion(center: around.location.coordinate, latitudinalMeters: 10_000, longitudinalMeters: 10_000))
        request.resultTypes = .pointOfInterest
        let found = try await MKLocalSearch(request: request).start().mapItems
            .map { ($0, $0.location.distance(from: around.location)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
        guard !found.isEmpty else { return "Apple Maps found no \(query) near \(around.label)." }
        var lines = ["\(query) near \(around.label) (Apple Maps), nearest first, distances in a straight line:"]
        for (index, (item, meters)) in found.enumerated() {
            var parts = [label(of: item), distance(meters) + " away"]
            if let phone = item.phoneNumber { parts.append(phone) }
            if let url = item.url { parts.append(url.absoluteString) }
            lines.append("\(index + 1). " + parts.joined(separator: "; "))
        }
        let marks = found.map { item, _ in Point(label: label(of: item), location: item.location, item: item, name: item.name).mapPoint }
        let map = TranscriptMap(kind: .places, points: [around.mapPoint] + marks)
        return ToolMapNote.append(map, to: ToolOutput.wrap(lines.joined(separator: "\n"), source: "search_places: \(query)"))
    }

    static func geocode(_ query: String) async throws -> String {
        if let location = coordinates(query) {
            guard let request = MKReverseGeocodingRequest(location: location), let item = try await request.mapItems.first else {
                return "Apple Maps knows no address at \(query)."
            }
            let map = TranscriptMap(kind: .places, points: [Point(label: query, location: location, item: item, name: item.name).mapPoint])
            return ToolMapNote.append(map, to: ToolOutput.wrap("At \(query) (Apple Maps): \(label(of: item))", source: "geocode: \(query)"))
        }
        let items = (try? await MKGeocodingRequest(addressString: query)?.mapItems) ?? []
        guard !items.isEmpty else { return notFound(query) }
        let lines = items.prefix(3).enumerated().map { index, item in
            let point = item.location.coordinate
            return "\(index + 1). \(label(of: item)) — " + String(format: "%.5f, %.5f", point.latitude, point.longitude)
        }
        let marks = items.prefix(3).map { Point(label: label(of: $0), location: $0.location, item: $0, name: $0.name ?? query).mapPoint }
        let text = ToolOutput.wrap((["\(query) (Apple Maps):"] + lines).joined(separator: "\n"), source: "geocode: \(query)")
        return ToolMapNote.append(TranscriptMap(kind: .places, points: Array(marks)), to: text)
    }

    // Places

    /// Where the user is, from Location Services: the start or the search centre the model left out.
    private static func here() async throws -> Point {
        let place = try await LocationService.shared.current()
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let label = "the user's location" + ((place.label ?? place.city).map { " (\($0))" } ?? "")
        return Point(label: label, location: location, item: MKMapItem(location: location, address: nil), isUser: true)
    }

    /// A city, an address or coordinates; a landmark or a business is not an address, so the local search tries next.
    private static func find(_ text: String) async throws -> Point? {
        if let location = coordinates(text) {
            return Point(label: text, location: location, item: MKMapItem(location: location, address: nil), name: text)
        }
        let item: MKMapItem?
        if let geocoded = try? await MKGeocodingRequest(addressString: text)?.mapItems.first {
            item = geocoded
        } else {
            item = try? await MKLocalSearch(request: MKLocalSearch.Request(naturalLanguageQuery: text)).start().mapItems.first
        }
        return item.map { Point(label: label(of: $0), location: $0.location, item: $0, name: $0.name ?? text) }
    }

    private static func notFound(_ text: String) -> String {
        "error: Apple Maps found no place called \"\(text)\"; try another spelling or add the region or country"
    }

    /// "lat, lon" typed or passed on by the model.
    private static func coordinates(_ text: String) -> CLLocation? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]), abs(lat) <= 90, abs(lon) <= 180 else {
            return nil
        }
        return CLLocation(latitude: lat, longitude: lon)
    }

    /// Its name with the address, the way Maps lists a result: "Аптека 36,6, улица Мира, 12, Краснодар, Россия".
    private static func label(of item: MKMapItem) -> String {
        let address = item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true)
        switch (item.name, address) {
        case (let name?, let address?) where !address.hasPrefix(name): return "\(name), \(address)"
        case (_, let address?): return address
        case (let name?, nil): return name
        case (nil, nil):
            return String(format: "%.5f, %.5f", item.location.coordinate.latitude, item.location.coordinate.longitude)
        }
    }

    // Numbers the model repeats

    private static func distance(_ meters: CLLocationDistance) -> String {
        switch meters {
        case ..<1000: String(format: "%.0f m", meters)
        case ..<10_000: String(format: "%.1f km", meters / 1000)
        default: String(format: "%.0f km", meters / 1000)
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(max(minutes, 1)) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
