//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import MacOlama

// Tools that answer from this Mac: the parts that decide what runs and how an answer is worded.

@Suite struct JavaScriptToolTests {
    private func run(_ code: String) async throws -> String {
        try await JavaScriptToolProvider().execute(ToolCall(id: "1", name: "run_javascript", argumentsJSON: "{\"code\":\(quoted(code))}"))
    }

    private func quoted(_ text: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [text], options: .fragmentsAllowed)) ?? Data(), as: UTF8.self)
            .dropFirst().dropLast().description
    }

    @Test func arithmeticIsExact() async throws {
        #expect(try await run("(0.1 + 0.2).toFixed(2)").contains("0.30"))
        #expect(try await run("[1,2,3].reduce((a,b)=>a+b,0)").contains("Result: 6"))
    }

    @Test func consoleOutputIsReturned() async throws {
        let out = try await run("console.log('hi', 42); 'done'")
        #expect(out.contains("hi 42"))
        #expect(out.contains("Result: \"done\""))
    }

    @Test func errorsComeBackAsText() async throws {
        #expect(try await run("nope()").contains("error:"))
    }

    @Test func runawayLoopIsStopped() async throws {
        let started = Date()
        let out = try await run("while (true) {}")
        #expect(out.contains("error:"))
        #expect(Date().timeIntervalSince(started) < 10)  // the time limit, not a hang
    }

    @Test func thereIsNoNetworkOrFileAccess() async throws {
        let out = try await run("[typeof fetch, typeof require, typeof XMLHttpRequest].join(',')")
        #expect(out.contains("undefined,undefined,undefined"))
    }
}

@Suite struct NetworkToolTests {
    @Test func hostsAreChecked() {
        #expect(NetworkToolProvider.validHost("ya.ru") == "ya.ru")
        #expect(NetworkToolProvider.validHost("[2a02:6b8::2:242]") == "2a02:6b8::2:242")
        #expect(NetworkToolProvider.validHost("-c 100 evil") == nil)  // no options, no spaces
        #expect(NetworkToolProvider.validHost("ya.ru; rm -rf /") == nil)
        #expect(NetworkToolProvider.validHost("") == nil)
    }

    @Test func localAddressesAreRecognized() {
        for host in ["localhost", "127.0.0.1", "192.168.1.1", "10.0.0.5", "172.20.3.4", "169.254.1.1", "printer.local", "::1", "fe80::1"] {
            #expect(NetworkToolProvider.isLocal(host), "\(host) should count as local")
        }
        for host in ["ya.ru", "8.8.8.8", "172.32.0.1", "example.com"] {
            #expect(!NetworkToolProvider.isLocal(host), "\(host) should not count as local")
        }
    }
}

@Suite struct WeatherToolTests {
    private let geocoding = Data(
        """
        {"results":[{"name":"Москва","latitude":55.75,"longitude":37.62,"country":"Россия","admin1":"Москва","timezone":"Europe/Moscow"}]}
        """.utf8)
    private let forecast = Data(
        """
        {"current":{"time":"2026-09-20T09:00","temperature_2m":11.7,"apparent_temperature":10.8,"relative_humidity_2m":89,
        "precipitation":0.0,"weather_code":1,"wind_speed_10m":1.56,"wind_gusts_10m":4.4,"wind_direction_10m":225,"surface_pressure":1002.7},
        "daily":{"time":["2026-09-20","2026-09-21"],"weather_code":[3,61],"temperature_2m_max":[19.7,18.8],
        "temperature_2m_min":[9.7,13.5],"precipitation_sum":[0.0,4.3],"precipitation_probability_max":[10,80],
        "wind_speed_10m_max":[4.1,6.2]}}
        """.utf8)

    @Test func placeIsParsed() throws {
        let place = try WeatherToolProvider.parsePlace(geocoding)
        #expect(place == WeatherToolProvider.Place(name: "Москва", region: "Москва", country: "Россия", latitude: 55.75, longitude: 37.62))
        #expect(try WeatherToolProvider.parsePlace(Data(#"{"generationtime_ms":0.1}"#.utf8)) == nil)
    }

    @Test func forecastReadsAsSentences() throws {
        guard let place = try WeatherToolProvider.parsePlace(geocoding) else { return #expect(Bool(false)) }
        let text = try WeatherToolProvider.format(place: place, forecast: forecast)
        #expect(text.contains("Москва, Россия"))
        #expect(text.contains("11.7°C (feels like 10.8°C)"))
        #expect(text.contains("mainly clear"))
        #expect(text.contains("from the south-west"))
        #expect(text.contains("2026-09-21: 14…19°C, light rain, precipitation 4.3 mm (chance 80%)"))
        #expect(text.contains("Open-Meteo"))
    }

    @Test func weatherCodesAndDirections() {
        #expect(WeatherToolProvider.describe(0) == "clear sky")
        #expect(WeatherToolProvider.describe(95) == "thunderstorm")
        #expect(WeatherToolProvider.describe(123) == "weather code 123")
        #expect(WeatherToolProvider.compass(0) == "north")
        #expect(WeatherToolProvider.compass(350) == "north")
        #expect(WeatherToolProvider.compass(90) == "east")
    }
}

@Suite struct MacInfoToolTests {
    @Test func overviewNamesTheMachine() {
        let text = MacInfoToolProvider.overview()
        #expect(text.contains("macOS:"))
        #expect(text.contains("Chip:"))
        #expect(text.contains("Thermal state:"))
    }

    @Test func storageListsTheStartupVolume() {
        #expect(MacInfoToolProvider.storage().contains("free of"))
    }
}

@Suite struct FileWriteTests {
    @Test func writesStayInsideAllowedFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FileToolProvider(configuration: .init(allowedFolders: [root]))
        #expect(provider.resolveForWriting("notes.md")?.lastPathComponent == "notes.md")
        #expect(provider.resolveForWriting(root.appendingPathComponent("a.txt").path) != nil)
        #expect(provider.resolveForWriting("/etc/hosts") == nil)
        #expect(provider.resolveForWriting("../escape.txt") == nil)
        #expect(provider.resolveForWriting("") == nil)
    }
}
