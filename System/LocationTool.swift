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
        case .notDetermined, .denied, .restricted: throw Failure.denied
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
            "error: Location Services are off for Mac-Olama. Ask the user which place they mean; they can allow Mac-Olama in System Settings → Privacy & Security → Location Services."
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
            name: here.city ?? "your location", region: nil, country: here.country, latitude: here.latitude, longitude: here.longitude)
    }
}
