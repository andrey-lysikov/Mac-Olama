//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import CoreLocation
import Foundation
import MapKit

// Location

/// Where this Mac is, from Location Services: the one source for `get_location` and for `get_weather` asked without a
/// place. Nothing is looked up until a model calls one of them, and the coordinates are cut to about a kilometre.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    /// What the tools report: the place in words for the model, coordinates for a forecast.
    struct Place: Sendable {
        var city: String?
        /// City with its region and country, as Maps writes it: "Cupertino, CA, United States".
        var label: String?
        var country: String?
        var latitude: Double
        var longitude: Double
        var timeZone: TimeZone
    }

    enum Failure: Error {
        case denied
        case unavailable(String)
    }

    private let manager = CLLocationManager()
    private var fixes: [UUID: CheckedContinuation<CLLocation, any Error>] = [:]
    private var decisions: [UUID: CheckedContinuation<Void, Never>] = [:]

    private override init() {
        super.init()
        manager.delegate = self
        // A kilometre is all a city, a forecast or a time zone needs, and it comes faster than a precise fix.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Asks macOS when the user turns the switch on, so the prompt comes then and never in the middle of an answer.
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func current() async throws -> Place {
        if manager.authorizationStatus == .notDetermined {
            requestPermission()
            await decision(within: 60)
        }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            PrivacySettings.ask(.location)
            throw Failure.denied
        case .notDetermined: throw Failure.denied
        default: break
        }
        return await describe(try await fix(within: 30))
    }

    // Waiting for macOS

    /// The permission prompt may be left unanswered; after the time is up the tool says the place is unknown.
    private func decision(within seconds: Double) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            decisions[id] = continuation
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                decisions.removeValue(forKey: id)?.resume()
            }
        }
    }

    /// A recent fix macOS holds is used at once; otherwise updates run until one comes. Not `requestLocation()`: it
    /// gives up in about ten seconds with "location unknown", shorter than a Mac may need to place itself by Wi-Fi.
    private func fix(within seconds: Double) async throws -> CLLocation {
        if let known = manager.location, -known.timestamp.timeIntervalSinceNow < 600,
            (0...3000).contains(known.horizontalAccuracy)
        {
            return known
        }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            fixes[id] = continuation
            manager.startUpdatingLocation()
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard let waiting = fixes.removeValue(forKey: id) else { return }
                if fixes.isEmpty { manager.stopUpdatingLocation() }
                waiting.resume(
                    throwing: Failure.unavailable(
                        "no position within \(Int(seconds)) s; a Mac finds it from nearby Wi-Fi networks"))
            }
        }
    }

    private func finish(_ result: Result<CLLocation, any Error>) {
        manager.stopUpdatingLocation()
        let waiting = fixes.values
        fixes.removeAll()
        for continuation in waiting { continuation.resume(with: result) }
    }

    /// The name comes from the rounded coordinates too, so no more than a kilometre's precision leaves the Mac.
    private func describe(_ location: CLLocation) async -> Place {
        let latitude = (location.coordinate.latitude * 100).rounded() / 100
        let longitude = (location.coordinate.longitude * 100).rounded() / 100
        var place = Place(latitude: latitude, longitude: longitude, timeZone: .current)
        if let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)),
            let item = try? await request.mapItems.first
        {
            place.city = item.addressRepresentations?.cityName
            place.label = item.addressRepresentations?.cityWithContext(.full)
            place.country = item.addressRepresentations?.regionName
            if let zone = item.timeZone { place.timeZone = zone }
        }
        return place
    }

    // CLLocationManagerDelegate: called on the main thread, where the manager was made.

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { finish(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let code = (error as? CLError)?.code
        // "Unknown right now": the updates keep trying, as Core Location documents, so the wait goes on until the
        // time limit instead of ending here.
        guard code != .locationUnknown else { return }
        MainActor.assumeIsolated {
            finish(.failure(code == .denied ? Failure.denied : Failure.unavailable(error.localizedDescription)))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard self.manager.authorizationStatus != .notDetermined else { return }
            let waiting = decisions.values
            decisions.removeAll()
            for continuation in waiting { continuation.resume() }
        }
    }
}

extension LocationService.Failure {
    /// What the model reads instead of a place: why, and what to do rather than guess.
    var toolText: String {
        switch self {
        case .denied:
            "error: Location Services are off for Mac-Olama. A notification now asks the user to allow Mac-Olama in System Settings → Privacy & Security → Location Services; meanwhile ask which place they mean."
        case .unavailable(let reason):
            "error: this Mac's location is unknown right now (\(reason)). Ask the user which place they mean."
        }
    }
}

/// `get_location`: the city, country, time zone with the local time and rounded coordinates of this Mac, for answers
/// that depend on where the user is. Off by default; macOS asks for permission when the switch is turned on.
public struct LocationToolProvider: ToolProvider {
    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "get_location",
                description:
                    "Where the user is now: city, region, country, time zone with the local time, and coordinates rounded to about 1 km, from this Mac's Location Services. Call it when the answer depends on the user's place and they did not name one: weather, local time, what is nearby, local news or events.",
                parametersJSONSchema: #"{"type":"object","properties":{}}"#
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        do {
            let place = try await LocationService.shared.current()
            let map = TranscriptMap(kind: .places, points: [TranscriptMap.Point(lat: place.latitude, lon: place.longitude, here: true)])
            return ToolMapNote.append(map, to: ToolOutput.wrap(Self.format(place), source: "get_location"))
        } catch let failure as LocationService.Failure {
            return failure.toolText
        }
    }

    static func format(_ place: LocationService.Place, now: Date = .now) -> String {
        let style = Date.ISO8601FormatStyle(timeZone: place.timeZone).year().month().day()
        let clock = now.formatted(style.time(includingFractionalSeconds: false))
        return [
            "Location of this Mac (Location Services): " + (place.label ?? place.city ?? "place name unknown"),
            String(format: "Coordinates: %.2f, %.2f (rounded to about 1 km)", place.latitude, place.longitude),
            "Time zone: \(place.timeZone.identifier), local time \(clock)",
        ].joined(separator: "\n")
    }
}

extension WeatherToolProvider {
    /// The forecast place for a question that names none: this Mac's.
    static func currentPlace() async throws -> Place {
        let here = try await LocationService.shared.current()
        return Place(
            name: here.city ?? "your location", region: nil, country: here.country, latitude: here.latitude, longitude: here.longitude,
            timeZone: TimeZone.current.identifier)
    }
}

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

// Trips

/// `find_trips`: trains, flights, buses and commuter trains between two places on a day, from Yandex Schedules
/// (rasp.yandex.ru, no key). Its search page carries the timetable with Russian Railways' seats and prices as JSON;
/// buying is left to the user, through links to rzd.ru, Aviasales and the schedule itself.
public struct TripsToolProvider: ToolProvider {
    public var scheduleURL = URL(string: "https://rasp.yandex.ru/search/")!
    public var suggestURL = URL(string: "https://suggests.rasp.yandex.net/all_suggests")!
    public var railwayStationsURL = URL(string: "https://pass.rzd.ru/suggester")!
    public var airportCodesURL = URL(string: "https://autocomplete.travelpayouts.com/places2")!
    /// The location switch is on too: a trip without a start begins in the city this Mac is in.
    public var usesCurrentPlace = false
    /// A busy line (Moscow to Saint Petersburg) has a hundred departures a day; the rest stay behind the link.
    static let listed = 30

    public init() {}

    public var specs: [ToolSpec] {
        let from =
            usesCurrentPlace
            ? #""from":{"type":"string","description":"Start: a city, station or airport. Leave it out to start in the user's city"}"#
            : #""from":{"type":"string","description":"Start: a city, station or airport"}"#
        return [
            ToolSpec(
                name: "find_trips",
                description:
                    "Timetable of long-distance and commuter trains, flights and intercity buses between two places on a day, from Yandex Schedules: departure and arrival times, stations, travel time, carrier; for trains the free seats and prices by class (Russian Railways), for commuter trains the fare. Gives links to buy on rzd.ru and Aviasales. Use it for travel by rail, air or bus; get_route is for car, walking and city transit.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"# + from
                    + #","to":{"type":"string","description":"Destination: a city, station or airport"},"date":{"type":"string","description":"Day of departure, YYYY-MM-DD (default today)"},"transport":{"type":"string","enum":["any","train","plane","bus","suburban"],"description":"train = long-distance trains, suburban = commuter trains (elektrichka, Lastochka); default any"}},"required":["#
                    + (usesCurrentPlace ? #""to"]}"# : #""from","to"]}"#)
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        let text = { (key: String) in args.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        guard let to = text("to") else { return toolFailure(missing: "to") }
        let transport = text("transport").flatMap { ["train", "plane", "bus", "suburban"].contains($0) ? $0 : nil }
        let day = text("date").flatMap(ToolDate.parse) ?? .now
        do {
            let from: String
            if let start = text("from") {
                from = start
            } else if usesCurrentPlace, let city = try await LocationService.shared.current().city {
                from = city
            } else {
                return toolFailure(missing: "from")
            }
            // The page reads plain names itself and knows cities its suggester misses ("Париж"); a name it cannot
            // place (an airport, "Шереметьево") is a 404, and then the suggester's keys are asked for instead.
            var page = searchPage([("fromName", from), ("toName", to)], day: day, transport: transport)
            var search = try await timetable(page)
            if search?.context.from.title?.nonEmpty == nil || search?.context.to.title?.nonEmpty == nil {
                async let origin = point(from)
                async let destination = point(to)
                guard let origin = try await origin else { return notFound(from) }
                guard let destination = try await destination else { return notFound(to) }
                page = searchPage([("fromId", origin), ("toId", destination)], day: day, transport: transport)
                search = try await timetable(page)
            }
            guard let search else {
                return "error: Yandex Schedules gave no timetable; the user can open \(page.absoluteString)"
            }
            let links = await links(for: search, day: day, page: page)
            return ToolOutput.wrap(Self.format(search, day: day, links: links), source: "find_trips: \(from) — \(to)")
        } catch let failure as LocationService.Failure {
            return failure.toolText
        } catch {
            return "error: Yandex Schedules did not answer (\(error.localizedDescription))"
        }
    }

    private func notFound(_ name: String) -> String {
        "error: Yandex Schedules knows no city, station or airport called \"\(name)\"; try another spelling or a nearby city"
    }

    // Requests

    /// The timetable a search page carries, or nil when the page is not one (an unknown place, a captcha).
    private func timetable(_ page: URL) async throws -> Search? {
        let (data, response) = try await HTTP.get(page, timeout: 20)
        guard response.statusCode == 200, let state = Self.state(in: String(decoding: data, as: UTF8.self)) else { return nil }
        return try? JSONDecoder().decode(Schedule.self, from: state).search
    }

    /// The schedule's own key for a name: "c213" for Moscow, "s9600213" for Sheremetyevo. The suggester lists streets
    /// and stops too, so the same name wins, a city before a station, then any city, then whatever comes first.
    private func point(_ name: String) async throws -> String? {
        var c = URLComponents(url: suggestURL, resolvingAgainstBaseURL: false)
        c?.queryItems = [
            URLQueryItem(name: "format", value: "old"), URLQueryItem(name: "part", value: name),
            URLQueryItem(name: "lang", value: "ru"), URLQueryItem(name: "national_version", value: "ru"),
        ]
        guard let url = c?.url else { return nil }
        // [query, [[key, title, context, slug], …]]
        let (data, _) = try await HTTP.get(url)
        let found = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        let keys = ((found?[safe: 1] as? [[Any]]) ?? []).compactMap { entry -> (key: String, title: String)? in
            guard let key = entry.first as? String, let title = entry[safe: 1] as? String else { return nil }
            return (key, title)
        }
        let same = keys.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        let city = { (list: [(key: String, title: String)]) in list.first { $0.key.hasPrefix("c") } }
        return (city(same) ?? same.first ?? city(keys) ?? keys.first)?.key
    }

    private func searchPage(_ places: [(String, String)], day: Date, transport: String?) -> URL {
        let base = transport.map { scheduleURL.appending(path: $0 + "/") } ?? scheduleURL
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)
        c?.queryItems = places.map { URLQueryItem(name: $0.0, value: $0.1) } + [URLQueryItem(name: "when", value: Self.isoDay(day))]
        return c?.url ?? base
    }

    /// Where to buy: the same search on rzd.ru for trains and on Aviasales for flights. A link that cannot be made
    /// is left out; the schedule's own page is always there.
    private func links(for search: Search, day: Date, page: URL) async -> [String] {
        let kinds = Set(search.segments.map(\.transport.code))
        let from = search.context.from.title ?? "", to = search.context.to.title ?? ""
        async let railway = kinds.contains("train") ? railwayLink(search, from: from, to: to, day: day) : nil
        // Searched from an airport, the flight's own cities go to Aviasales: "Шереметьево" is no city code.
        let flight = search.segments.first { $0.transport.code == "plane" }
        async let flights =
            kinds.contains("plane")
            ? flightsLink(
                from: flight?.stationFrom.settlement?.title ?? from, to: flight?.stationTo.settlement?.title ?? to, day: day) : nil
        return ["Timetable: " + page.absoluteString] + [await railway, await flights].compactMap { $0 }
    }

    /// Russian Railways' codes of the two cities, so every station of each is searched; a city its suggester does
    /// not name exactly falls back to the stations of the first train.
    private func railwayLink(_ search: Search, from: String, to: String, day: Date) async -> String? {
        let train = search.segments.first { $0.transport.code == "train" }
        async let start = railwayCode(from)
        async let end = railwayCode(to)
        guard let start = await start ?? train?.stationFrom.codes?.express,
            let end = await end ?? train?.stationTo.codes?.express
        else { return nil }
        return "Russian Railways: https://ticket.rzd.ru/searchresults/v/1/\(start)/\(end)/\(Self.isoDay(day))"
    }

    private func railwayCode(_ city: String) async -> String? {
        var c = URLComponents(url: railwayStationsURL, resolvingAgainstBaseURL: false)
        c?.queryItems = [
            URLQueryItem(name: "stationNamePart", value: city.uppercased()), URLQueryItem(name: "lang", value: "ru"),
            URLQueryItem(name: "compactMode", value: "y"),
        ]
        guard let url = c?.url, let data = try? await HTTP.get(url, timeout: 10).0,
            let stations = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }
        let name = city.uppercased()
        return stations.first { $0["n"] as? String == name }.flatMap { ($0["c"] as? NSNumber)?.stringValue }
    }

    /// Aviasales takes city codes and the day as DDMM: MOW0110KRR1 is Moscow to Krasnodar on 1 October, one adult.
    private func flightsLink(from: String, to: String, day: Date) async -> String? {
        async let start = airportCode(from)
        async let end = airportCode(to)
        guard let start = await start, let end = await end else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "ddMM"
        return "Aviasales: https://www.aviasales.ru/search/\(start)\(formatter.string(from: day))\(end)1"
    }

    private func airportCode(_ city: String) async -> String? {
        var c = URLComponents(url: airportCodesURL, resolvingAgainstBaseURL: false)
        c?.queryItems = [
            URLQueryItem(name: "term", value: city), URLQueryItem(name: "locale", value: "ru"),
            URLQueryItem(name: "types[]", value: "city"),
        ]
        guard let url = c?.url, let data = try? await HTTP.get(url, timeout: 10).0,
            let places = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }
        return places.first?["code"] as? String
    }

    // The page's timetable

    struct Schedule: Decodable { var search: Search }

    struct Search: Decodable {
        struct Context: Decodable {
            struct Place: Decodable { var title: String? }
            var from: Place
            var to: Place
        }
        var context: Context
        var segments: [Segment]
    }

    struct Segment: Decodable {
        struct Transport: Decodable {
            struct Model: Decodable { var title: String? }
            var code: String
            var model: Model?
        }
        struct Station: Decodable {
            struct Codes: Decodable { var express: String? }
            struct Settlement: Decodable { var title: String? }
            var title: String
            var timezone: String?
            var codes: Codes?
            var settlement: Settlement?
        }
        struct Company: Decodable {
            var title: String?
            var ufsTitle: String?
        }
        struct Tariffs: Decodable {
            struct Fare: Decodable {
                struct Price: Decodable {
                    var value: Double
                    var currency: String
                }
                var price: Price?
                var seats: Int?
                var title: String?
            }
            var classes: [String: Fare]?
        }
        var transport: Transport
        var number: String?
        var title: String?
        var departure: String?
        var arrival: String?
        var duration: Double?
        var stationFrom: Station
        var stationTo: Station
        var company: Company?
        var tariffs: Tariffs?
        var isTransfer: Bool?
        var transferStations: String?
        var segments: [Segment]?
        var isGone: Bool?
        var cancelType: String?
    }

    /// The JSON the page assigns to `window.INITIAL_STATE`, cut out by matching braces outside strings.
    static func state(in html: String) -> Data? {
        guard let marker = html.range(of: "window.INITIAL_STATE =") else { return nil }
        let bytes = Array(html.utf8[marker.upperBound...])
        var depth = 0, start: Int?, inString = false, escaped = false
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"):
                if start == nil { start = index }
                depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0, let start { return Data(bytes[start...index]) }
            default: break
            }
        }
        return nil
    }

    // What the model reads

    static func format(_ search: Search, day: Date, links: [String]) -> String {
        let from = search.context.from.title ?? "?", to = search.context.to.title ?? "?"
        // The page runs on into the small hours of the next day; those are that day's trips.
        let trips = search.segments.filter { $0.isGone != true && localTime($0.departure, $0.stationFrom.timezone).hasPrefix(isoDay(day)) }
            .sorted { ($0.departure ?? "") < ($1.departure ?? "") }
        var lines = ["\(from) — \(to), \(isoDay(day)) (Yandex Schedules; local times of each station):"]
        if trips.isEmpty { lines.append("No trains, flights or buses found for this day.") }
        for (index, trip) in trips.prefix(listed).enumerated() {
            lines.append("\(index + 1). " + describe(trip))
            if trip.isTransfer == true {
                lines += (trip.segments ?? []).map { "   leg: " + leg($0) }
            }
        }
        if trips.count > listed {
            lines.append("…and \(trips.count - listed) more; narrow by transport or see the timetable link.")
        }
        lines.append("Prices change and seats sell out; the user buys on the sites below.")
        return (lines + links).joined(separator: "\n")
    }

    private static func describe(_ trip: Segment) -> String {
        var text = kind(trip.transport.code)
        if trip.isTransfer == true {
            text += " with changes (\(plain(trip.transferStations ?? trip.title ?? "")))"
        } else {
            if let number = trip.number?.nonEmpty { text += " " + number }
            if let title = trip.title?.nonEmpty { text += " " + plain(title) }
            if let carrier = trip.company?.title ?? trip.company?.ufsTitle { text += ", " + plain(carrier) }
            if let model = trip.transport.model?.title { text += ", " + model }
        }
        text += ": " + times(trip)
        if let duration = trip.duration { text += ", " + travelTime(duration) }
        if trip.cancelType != nil { text += ". CANCELLED" }
        let fares = (trip.tariffs?.classes ?? [:])
            .compactMap { key, fare in fare.price.map { (key, fare, $0) } }
            .sorted { $0.2.value < $1.2.value }
            .map { key, fare, price in
                var line = "\(fare.title.map(plain) ?? seatClass(key)) from \(String(format: "%.0f", price.value)) \(price.currency)"
                if let seats = fare.seats { line += " (seats left: \(seats))" }
                return line
            }
        if !fares.isEmpty { text += ". " + fares.joined(separator: "; ") }
        return text
    }

    private static func leg(_ leg: Segment) -> String {
        [kind(leg.transport.code), leg.number, leg.company?.title].compactMap { $0?.nonEmpty }.joined(separator: " ")
            + ": " + times(leg)
    }

    private static func times(_ trip: Segment) -> String {
        "\(localTime(trip.departure, trip.stationFrom.timezone)) \(plain(trip.stationFrom.title)) → "
            + "\(localTime(trip.arrival, trip.stationTo.timezone)) \(plain(trip.stationTo.title))"
    }

    private static func kind(_ code: String) -> String {
        switch code {
        case "train": "Train"
        case "suburban": "Commuter train"
        case "plane": "Flight"
        case "bus": "Bus"
        case "water": "Boat"
        default: code
        }
    }

    /// Russian Railways' classes by the names travellers use.
    private static func seatClass(_ key: String) -> String {
        switch key {
        case "platzkarte": "platzkart (open sleeper)"
        case "compartment": "kupe (4-berth compartment)"
        case "suite": "SV (2-berth sleeper)"
        case "soft": "lux"
        case "sitting": "seat"
        case "common": "common car"
        default: key
        }
    }

    private static func localTime(_ iso: String?, _ zone: String?) -> String {
        guard let iso, let date = try? Date(iso, strategy: .iso8601) else { return "?" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func travelTime(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        let days = minutes / 1440, hours = minutes % 1440 / 60
        let rest = [days > 0 ? "\(days) d" : nil, hours > 0 ? "\(hours) h" : nil, minutes % 60 > 0 ? "\(minutes % 60) min" : nil]
        return rest.compactMap { $0 }.joined(separator: " ")
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Names reach the page's JSON HTML-escaped: "Экспресс &quot;Ласточка&quot;".
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// Weather

/// `get_weather`: current conditions and a daily forecast from Open-Meteo (free, no key; data under CC BY 4.0, so the
/// source is named in every result). A place name is turned into coordinates by Open-Meteo's own geocoder.
public struct WeatherToolProvider: ToolProvider {
    public var geocodingURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search")!
    public var forecastURL = URL(string: "https://api.open-meteo.com/v1/forecast")!
    /// Fallback when Open-Meteo fails: ProjectEOL's MCP server with NOAA GFS, as System Spinner uses it.
    public var projectEolURL = URL(string: "https://weatherapi.projecteol.ru/mcp/")!
    /// The location switch is on too: a call without a place means where the user is, found by Location Services,
    /// so a question about the weather "here" takes one round instead of asking the city first.
    public var usesCurrentPlace = false

    public init() {}

    public var specs: [ToolSpec] {
        let place =
            usesCurrentPlace
            ? #""location":{"type":"string","description":"City or place name, e.g. Moscow; add the country if ambiguous. Leave it out for where the user is now"}"#
            : #""location":{"type":"string","description":"City or place name, e.g. Moscow; add the country if ambiguous"}"#
        return [
            ToolSpec(
                name: "get_weather",
                description:
                    "Current weather and a daily forecast (up to 7 days) for a place: temperature, feels-like, conditions, precipitation and its probability, wind, humidity, pressure. Data from Open-Meteo, or from NOAA GFS through ProjectEOL when Open-Meteo is down.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"# + place
                    + #","days":{"type":"integer","description":"Days of forecast, 1 to 7 (default 3)"}}"#
                    + (usesCurrentPlace ? "}" : #","required":["location"]}"#)
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        let location = args.string("location")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !location.isEmpty || usesCurrentPlace else { return "error: missing location; ask the user which city" }
        let days = min(max(args.int("days") ?? 3, 1), 7)
        do {
            let place: Place
            if location.isEmpty {
                place = try await Self.currentPlace()
            } else if let found = try await findPlace(location) {
                place = found
            } else {
                return "error: no place called \"\(location)\"; try another spelling or add the country"
            }
            let text: String
            do {
                text = try Self.format(place: place, forecast: try await get(forecastQuery(place, days: days)))
            } catch {
                let forecast = try await callProjectEol("get_weather_forecast", arguments: projectEolForecastArguments(place, days: days))
                text = try Self.formatProjectEol(place: place, days: days, forecast: forecast)
            }
            return ToolOutput.wrap(text, source: "get_weather: \(place.name)")
        } catch let failure as LocationService.Failure {
            return failure.toolText
        } catch {
            return "error: weather service unavailable (\(error.localizedDescription))"
        }
    }

    // Requests

    private func geocodeQuery(_ name: String) -> URL? {
        var c = URLComponents(url: geocodingURL, resolvingAgainstBaseURL: false)
        // Place names come back in the user's language when the geocoder has them.
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        c?.queryItems = [
            URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: language), URLQueryItem(name: "format", value: "json"),
        ]
        return c?.url
    }

    private func forecastQuery(_ place: Place, days: Int) -> URL? {
        var c = URLComponents(url: forecastURL, resolvingAgainstBaseURL: false)
        c?.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(
                name: "current",
                value:
                    "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_gusts_10m,wind_direction_10m,surface_pressure"
            ),
            URLQueryItem(
                name: "daily",
                value:
                    "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,wind_speed_10m_max"),
            URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: String(days)),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
        ]
        return c?.url
    }

    private func findPlace(_ name: String) async throws -> Place? {
        do {
            return try Self.parsePlace(try await get(geocodeQuery(name)))
        } catch {
            return try Self.parseProjectEolPlace(try await callProjectEol("search_locations", arguments: ["query": name, "limit": 1]))
        }
    }

    private func projectEolForecastArguments(_ place: Place, days: Int) -> [String: Any] {
        [
            // Decimals, or 55.76 goes out as 55.759999999999998.
            "latitude": NSDecimalNumber(string: String(format: "%.2f", place.latitude)),
            "longitude": NSDecimalNumber(string: String(format: "%.2f", place.longitude)),
            "hours": min(days * 24, 168),
            "parameters": Self.projectEolParameters,
        ]
    }

    /// One MCP `tools/call` to ProjectEOL; the answer is plain JSON-RPC.
    private func callProjectEol(_ tool: String, arguments: [String: Any]) async throws -> Data {
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments] as [String: Any],
        ]
        var request = URLRequest(url: projectEolURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(HTTP.appUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// Open-Meteo only. 5 s, not the usual 15: a slow answer is not worth waiting for when ProjectEOL can stand in.
    private func get(_ url: URL?) async throws -> Data {
        guard let url else { throw URLError(.badURL) }
        let (data, response) = try await HTTP.get(url, timeout: 5, userAgent: HTTP.appUserAgent, accept: nil)
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    // Parsing and wording (static, so the tests can feed recorded answers)

    struct Place: Equatable {
        var name: String
        var region: String?
        var country: String?
        var latitude: Double
        var longitude: Double
        /// IANA name; ProjectEOL answers in UTC and its hours are put into this zone's days.
        var timeZone: String? = nil
    }

    static func parsePlace(_ data: Data) throws -> Place? {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let first = (json?["results"] as? [[String: Any]])?.first, let name = first["name"] as? String,
            let latitude = first["latitude"] as? Double, let longitude = first["longitude"] as? Double
        else { return nil }
        return Place(
            name: name, region: first["admin1"] as? String, country: first["country"] as? String, latitude: latitude, longitude: longitude,
            timeZone: first["timezone"] as? String)
    }

    static func format(place: Place, forecast data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let label = [place.name, place.region == place.name ? nil : place.region, place.country].compactMap { $0 }.joined(separator: ", ")
        var lines = [String(format: "Weather for %@ (%.2f, %.2f)", label, place.latitude, place.longitude)]
        if let now = json["current"] as? [String: Any] {
            let number = { (key: String) in (now[key] as? NSNumber)?.doubleValue }
            var parts: [String] = []
            if let t = number("temperature_2m") {
                parts.append(
                    String(format: "%.1f°C", t) + (number("apparent_temperature").map { String(format: " (feels like %.1f°C)", $0) } ?? ""))
            }
            if let code = (now["weather_code"] as? NSNumber)?.intValue { parts.append(describe(code)) }
            if let h = number("relative_humidity_2m") { parts.append(String(format: "humidity %.0f%%", h)) }
            if let w = number("wind_speed_10m") {
                var wind = String(format: "wind %.1f m/s", w)
                if let d = number("wind_direction_10m") { wind += " from the " + compass(d) }
                if let g = number("wind_gusts_10m") { wind += String(format: ", gusts %.0f m/s", g) }
                parts.append(wind)
            }
            if let p = number("precipitation"), p > 0 { parts.append(String(format: "precipitation %.1f mm", p)) }
            if let p = number("surface_pressure") { parts.append(String(format: "pressure %.0f hPa (%.0f mmHg)", p, p * 0.750062)) }
            lines.append("Now (\(now["time"] as? String ?? "local time")): " + parts.joined(separator: ", "))
        }
        if let daily = json["daily"] as? [String: Any], let dates = daily["time"] as? [String] {
            let column = { (key: String, i: Int) -> Double? in ((daily[key] as? [Any])?[safe: i] as? NSNumber)?.doubleValue }
            lines.append("Forecast:")
            for (i, date) in dates.enumerated() {
                var day = "\(date): "
                if let lo = column("temperature_2m_min", i), let hi = column("temperature_2m_max", i) {
                    day += String(format: "%.0f…%.0f°C", lo, hi)
                }
                if let code = column("weather_code", i) { day += ", " + describe(Int(code)) }
                if let sum = column("precipitation_sum", i) {
                    day += String(format: ", precipitation %.1f mm", sum)
                    if let chance = column("precipitation_probability_max", i) { day += String(format: " (chance %.0f%%)", chance) }
                }
                if let wind = column("wind_speed_10m_max", i) { day += String(format: ", wind up to %.0f m/s", wind) }
                lines.append(day)
            }
        }
        lines.append("Source: Open-Meteo.com (CC BY 4.0).")
        return lines.joined(separator: "\n")
    }

    // ProjectEOL (NOAA GFS): hourly, then 3-hourly values in UTC and SI units

    static let projectEolParameters = [
        "surface.air_temperature_2m", "surface.relative_humidity_2m", "surface.eastward_wind_10m", "surface.northward_wind_10m",
        "surface.wind_speed_of_gust", "surface.surface_air_pressure", "surface.cloud_area_fraction", "surface.precipitation_flux",
    ]

    static func projectEolContent(_ data: Data) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let result = json?["result"] as? [String: Any], result["isError"] as? Bool != true,
            let content = result["structuredContent"] as? [String: Any]
        else { throw URLError(.cannotParseResponse) }
        return content
    }

    static func parseProjectEolPlace(_ data: Data) throws -> Place? {
        guard let first = (try projectEolContent(data)["results"] as? [[String: Any]])?.first, let name = first["name"] as? String,
            let latitude = (first["latitude"] as? NSNumber)?.doubleValue, let longitude = (first["longitude"] as? NSNumber)?.doubleValue
        else { return nil }
        // The country comes as an ISO code.
        let country = (first["country"] as? String).map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
        return Place(
            name: name, region: nil, country: country, latitude: latitude, longitude: longitude, timeZone: first["timezone"] as? String)
    }

    static func formatProjectEol(place: Place, days: Int, forecast data: Data) throws -> String {
        let iso = ISO8601DateFormatter()
        let points: [(time: Date, values: [String: Double])] =
            (try projectEolContent(data)["forecast"] as? [[String: Any]] ?? []).compactMap { point in
                guard let time = (point["time"] as? String).flatMap(iso.date(from:)), let values = point["values"] as? [String: Any]
                else { return nil }
                return (time, values.compactMapValues { (($0 as? [String: Any])?["value"] as? NSNumber)?.doubleValue })
            }
        guard !points.isEmpty else { throw URLError(.cannotParseResponse) }

        let zone = place.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = zone
        let celsius = { (values: [String: Double]) in values["surface.air_temperature_2m"].map { $0 - 273.15 } }
        let wind = { (values: [String: Double]) -> (speed: Double, from: Double)? in
            guard let u = values["surface.eastward_wind_10m"], let v = values["surface.northward_wind_10m"] else { return nil }
            return ((u * u + v * v).squareRoot(), (atan2(-u, -v) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
        }
        // The flux is kg/m²/s, i.e. mm/s of water; each value stands until the next one.
        let rain = { (i: Int) -> Double in
            let step = i + 1 < points.count ? points[i + 1].time.timeIntervalSince(points[i].time) : 3600
            return max(0, points[i].values["surface.precipitation_flux"] ?? 0) * step
        }

        let label = [place.name, place.region == place.name ? nil : place.region, place.country].compactMap { $0 }.joined(separator: ", ")
        var lines = [String(format: "Weather for %@ (%.2f, %.2f)", label, place.latitude, place.longitude)]

        let now = points[0].values
        var parts: [String] = []
        if let t = celsius(now) { parts.append(String(format: "%.1f°C", t)) }
        let rate = max(0, now["surface.precipitation_flux"] ?? 0) * 3600
        parts.append(condition(cloud: now["surface.cloud_area_fraction"] ?? 0, rain: rate, rainAbove: 0.1, celsius: celsius(now)))
        if let h = now["surface.relative_humidity_2m"] { parts.append(String(format: "humidity %.0f%%", h)) }
        if let w = wind(now) {
            var text = String(format: "wind %.1f m/s from the ", w.speed) + compass(w.from)
            if let g = now["surface.wind_speed_of_gust"] { text += String(format: ", gusts %.0f m/s", g) }
            parts.append(text)
        }
        if rate > 0.05 { parts.append(String(format: "precipitation %.1f mm/h", rate)) }
        if let p = now["surface.surface_air_pressure"].map({ $0 / 100 }) {
            parts.append(String(format: "pressure %.0f hPa (%.0f mmHg)", p, p * 0.750062))
        }
        local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        lines.append("Now (\(local.string(from: points[0].time))): " + parts.joined(separator: ", "))

        local.dateFormat = "yyyy-MM-dd"
        var dates: [String] = []
        var byDate: [String: [Int]] = [:]
        for i in points.indices {
            let date = local.string(from: points[i].time)
            if byDate[date] == nil {
                guard dates.count < days else { break }
                dates.append(date)
            }
            byDate[date, default: []].append(i)
        }
        lines.append("Forecast:")
        for date in dates {
            let hours = byDate[date] ?? []
            let temperatures = hours.compactMap { celsius(points[$0].values) }
            let clouds = hours.compactMap { points[$0].values["surface.cloud_area_fraction"] }
            let sum = hours.reduce(0) { $0 + rain($1) }
            var day = "\(date): "
            if let lo = temperatures.min(), let hi = temperatures.max() { day += String(format: "%.0f…%.0f°C", lo, hi) }
            let cloud = clouds.isEmpty ? 0 : clouds.reduce(0, +) / Double(clouds.count)
            day += ", " + condition(cloud: cloud, rain: sum, rainAbove: 1, celsius: temperatures.max())
            day += String(format: ", precipitation %.1f mm", sum)
            if let top = hours.compactMap({ wind(points[$0].values)?.speed }).max() { day += String(format: ", wind up to %.0f m/s", top) }
            lines.append(day)
        }
        lines.append("Source: NOAA GFS through ProjectEOL (Open-Meteo did not answer); times are local.")
        return lines.joined(separator: "\n")
    }

    /// GFS has no weather code: the words come from cloud cover (0…1) and rain, snow when it stays below freezing.
    static func condition(cloud: Double, rain: Double, rainAbove: Double, celsius: Double?) -> String {
        if rain >= rainAbove { return (celsius ?? 1) <= 0 ? "snow" : "rain" }
        return cloud < 0.2 ? "clear sky" : cloud < 0.6 ? "partly cloudy" : "overcast"
    }

    /// WMO weather interpretation codes, as Open-Meteo documents them.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "clear sky"
        case 1: "mainly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "fog"
        case 51, 53, 55: "drizzle"
        case 56, 57: "freezing drizzle"
        case 61: "light rain"
        case 63: "rain"
        case 65: "heavy rain"
        case 66, 67: "freezing rain"
        case 71: "light snow"
        case 73: "snow"
        case 75: "heavy snow"
        case 77: "snow grains"
        case 80, 81: "rain showers"
        case 82: "violent rain showers"
        case 85, 86: "snow showers"
        case 95: "thunderstorm"
        case 96, 99: "thunderstorm with hail"
        default: "weather code \(code)"
        }
    }

    static func compass(_ degrees: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        return names[Int((degrees.truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8]
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
