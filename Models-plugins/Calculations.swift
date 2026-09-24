//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import JavaScriptCore

// Exact numbers instead of the model's arithmetic.

// JavaScript

/// `run_javascript`: exact arithmetic, dates and conversions in JavaScriptCore. A bare context has no network, files or
/// timers (no fetch, require, XMLHttpRequest), and a time limit stops runaway loops.
public struct JavaScriptToolProvider: ToolProvider {
    public var timeLimit: TimeInterval = 3
    public var maxCodeCharacters = 8000
    public var maxOutputCharacters = 8000

    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "run_javascript",
                description:
                    "Evaluate JavaScript for exact arithmetic, percentages, statistics, date arithmetic and unit conversions. No network or file access. The value of the last expression is returned; console.log output too.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"code":{"type":"string","description":"JavaScript code, e.g. (1250 * 1.2).toFixed(2)"}},"required":["code"]}"#
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        guard let code = args.string("code"), !code.isEmpty else { return toolFailure(missing: "code") }
        guard code.count <= maxCodeCharacters else { return "error: code longer than \(maxCodeCharacters) characters" }
        let (limit, maxOutput) = (timeLimit, maxOutputCharacters)
        // Its own thread: the evaluation blocks until it ends or the time limit terminates it.
        return await Task.detached { Self.evaluate(code, timeLimit: limit, maxOutput: maxOutput) }.value
    }

    static func evaluate(_ code: String, timeLimit: TimeInterval, maxOutput: Int) -> String {
        guard let group = JSContextGroupCreate() else { return "error: JavaScript is unavailable" }
        defer { JSContextGroupRelease(group) }
        setExecutionTimeLimit?(group, timeLimit, nil, nil)
        guard let ref = JSGlobalContextCreateInGroup(group, nil), let context = JSContext(jsGlobalContextRef: ref) else {
            return "error: JavaScript is unavailable"
        }
        JSGlobalContextRelease(ref)
        let log = LogSink()
        let print: @convention(block) () -> Void = {
            log.append((JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }.joined(separator: " "))
        }
        context.evaluateScript("var console = {};")
        context.objectForKeyedSubscript("console")?.setObject(print, forKeyedSubscript: "log" as NSString)
        let value = context.evaluateScript(code)
        var out = log.lines.joined(separator: "\n")
        if let exception = context.exception {
            out += (out.isEmpty ? "" : "\n") + "error: \(exception.toString() ?? "exception")"
        } else if let value, !value.isUndefined {
            let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value])
            let text = json.flatMap { $0.isUndefined ? nil : $0.toString() } ?? value.toString() ?? ""
            out += (out.isEmpty ? "" : "\n") + "Result: \(text)"
        }
        if out.isEmpty { out = "Done (no result, no output)." }
        return out.clipped(to: maxOutput)
    }

    private typealias SetTimeLimit = @convention(c) (JSContextGroupRef, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void

    /// Exported by JavaScriptCore but not in its public headers; looked up so a missing symbol only drops the time limit.
    private static let setExecutionTimeLimit: SetTimeLimit? = {
        guard let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_LAZY),
            let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit")
        else { return nil }
        return unsafeBitCast(symbol, to: SetTimeLimit.self)
    }()

    private final class LogSink: @unchecked Sendable {
        var lines: [String] = []
        func append(_ line: String) { if lines.count < 500 { lines.append(line) } }
    }
}

// Exchange rates

/// `currency_rate`: the official rates of the Bank of Russia for a day (cbr.ru, free, no key); any pair goes through
/// the rouble, as the bank publishes every currency against it.
public struct CurrencyToolProvider: ToolProvider {
    public var ratesURL = URL(string: "https://www.cbr.ru/scripts/XML_daily.asp")!

    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "currency_rate",
                description:
                    "Official exchange rate of the Bank of Russia for a day and the amount converted: any pair of currencies it lists (USD, EUR, CNY, …) and RUB.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"from":{"type":"string","description":"ISO code, e.g. USD"},"to":{"type":"string","description":"ISO code, default RUB"},"amount":{"type":"number","description":"Default 1"},"date":{"type":"string","description":"Local date, e.g. 2026-09-01; default today"}},"required":["from"]}"#
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        guard let from = args.string("from")?.uppercased(), !from.isEmpty else { return toolFailure(missing: "from") }
        let to = args.string("to")?.uppercased().nonEmptyCode ?? "RUB"
        let amount = args.double("amount") ?? 1
        let day = args.string("date").flatMap(ToolDate.parse) ?? .now
        var components = URLComponents(url: ratesURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "date_req", value: Self.bankDate(day))]
        guard let url = components?.url else { return "error: bad date" }
        let table: Table
        do {
            let (data, response) = try await HTTP.get(url, userAgent: HTTP.appUserAgent, accept: nil)
            guard response.statusCode == 200, let parsed = Self.parse(data) else {
                return "error: the Bank of Russia did not give its rates (HTTP \(response.statusCode))"
            }
            table = parsed
        } catch {
            return "error: the Bank of Russia did not answer (\(error.localizedDescription))"
        }
        guard let rateFrom = table.rates[from], let rateTo = table.rates[to] else {
            let unknown = table.rates[from] == nil ? from : to
            return "error: the Bank of Russia has no rate for \(unknown); it lists " + table.rates.keys.sorted().joined(separator: ", ")
        }
        let result = amount * rateFrom / rateTo
        return
            "\(Self.number(amount)) \(from) = \(Self.number(result)) \(to) at the official rate of the Bank of Russia set for \(table.date)"
            + (from == "RUB" || to == "RUB" ? "" : ", through the rouble") + " (cbr.ru)."
    }

    struct Table: Equatable {
        /// The day the rates were set for, as the bank writes it (a weekend keeps Friday's).
        var date: String
        /// Roubles for one unit of each currency, RUB itself included.
        var rates: [String: Double]
    }

    /// The bank's XML: `<Valute><CharCode>USD</CharCode><Nominal>1</Nominal><Value>81,2345</Value>`, in windows-1251.
    static func parse(_ data: Data) -> Table? {
        guard let text = String(data: data, encoding: .windowsCP1251) ?? String(data: data, encoding: .utf8),
            let date = text.firstMatch(of: /<ValCurs Date="([^"]+)"/)?.1
        else { return nil }
        var rates = ["RUB": 1.0]
        for valute in text.matches(of: /<Valute\b[^>]*>(.*?)<\/Valute>/.dotMatchesNewlines()) {
            let item = String(valute.1)
            guard let code = item.firstMatch(of: /<CharCode>([A-Z]{3})<\/CharCode>/)?.1,
                let nominal = item.firstMatch(of: /<Nominal>(\d+)<\/Nominal>/).flatMap({ Double($0.1) }),
                let value = item.firstMatch(of: /<Value>([\d,\.]+)<\/Value>/)?.1.replacingOccurrences(of: ",", with: "."),
                let roubles = Double(value), nominal > 0
            else { continue }
            rates[String(code)] = roubles / nominal
        }
        return rates.count > 1 ? Table(date: String(date), rates: rates) : nil
    }

    private static func bankDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: date)
    }

    /// Money reads with two decimals; a rate below one keeps enough digits to mean something.
    private static func number(_ value: Double) -> String {
        abs(value) >= 1 || value == 0 ? String(format: "%.2f", value) : String(format: "%.6f", value)
    }
}

extension String {
    fileprivate var nonEmptyCode: String? { isEmpty ? nil : self }
}
