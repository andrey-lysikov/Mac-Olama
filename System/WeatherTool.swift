//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// Weather

/// `get_weather`: current conditions and a daily forecast from Open-Meteo (free, no key; data under CC BY 4.0, so the
/// source is named in every result). A place name is turned into coordinates by Open-Meteo's own geocoder.
public struct WeatherToolProvider: ToolProvider {
    public var geocodingURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search")!
    public var forecastURL = URL(string: "https://api.open-meteo.com/v1/forecast")!

    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "get_weather",
                description:
                    "Current weather and a daily forecast (up to 7 days) for a place: temperature, feels-like, conditions, precipitation and its probability, wind, humidity, pressure. Data from Open-Meteo.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"location":{"type":"string","description":"City or place name, e.g. Moscow; add the country if ambiguous"},"days":{"type":"integer","description":"Days of forecast, 1 to 7 (default 3)"}},"required":["location"]}"#
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        guard let location = args.string("location")?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty else {
            return "error: missing location; ask the user which city"
        }
        let days = min(max(args.int("days") ?? 3, 1), 7)
        do {
            guard let place = try Self.parsePlace(try await get(geocodeQuery(location))) else {
                return "error: no place called \"\(location)\"; try another spelling or add the country"
            }
            let forecast = try await get(forecastQuery(place, days: days))
            return ToolOutput.wrap(try Self.format(place: place, forecast: forecast), source: "get_weather: \(location)")
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

    private func get(_ url: URL?) async throws -> Data {
        guard let url else { throw URLError(.badURL) }
        let (data, response) = try await HTTP.get(url, userAgent: "Mac-Olama/0.1", accept: nil)
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
    }

    static func parsePlace(_ data: Data) throws -> Place? {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let first = (json?["results"] as? [[String: Any]])?.first, let name = first["name"] as? String,
            let latitude = first["latitude"] as? Double, let longitude = first["longitude"] as? Double
        else { return nil }
        return Place(
            name: name, region: first["admin1"] as? String, country: first["country"] as? String, latitude: latitude, longitude: longitude)
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
