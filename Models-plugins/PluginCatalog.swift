//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

public enum ExtraTool: String, CaseIterable, Sendable {
    case calculator, macInfo, network, weather, location, trips, browser
    case calendar, timers, screen, currency, contacts, notes, mail, spotlight, macControl, music
}

public enum PluginGroup: CaseIterable, Sendable {
    case webSearch, browser, files, time, personal, thisMac, places, calculations

    public var tools: [ExtraTool] {
        switch self {
        case .webSearch: []
        case .browser: [.browser]
        case .files: [.spotlight]
        case .time: [.calendar, .timers]
        case .personal: [.contacts, .notes, .mail]
        case .thisMac: [.macInfo, .network, .macControl, .music, .screen]
        case .places: [.location, .trips, .weather]
        case .calculations: [.calculator, .currency]
        }
    }
}
