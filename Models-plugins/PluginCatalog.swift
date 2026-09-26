//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// The plugins a model may be given and how the settings group them.

/// Switches for the plugins beyond web search, folders and Shortcuts, each off by default. The raw values are what the
/// settings store, so a case keeps its name when its title changes: `location` is maps and location together.
public enum ExtraTool: String, CaseIterable, Sendable {
    case calculator, macInfo, network, weather, location, trips, browser
    case calendar, timers, screen, currency, contacts, notes, mail, spotlight, macControl, music
}

/// The settings' groups, by what the plugins reach. Web search, folder access and Shortcuts have switches of their own
/// with more to set, so the settings put them in by hand: web search, files and this Mac.
public enum PluginGroup: CaseIterable, Sendable {
    case webSearch, browser, files, time, personal, thisMac, places, calculations

    /// The group's plain switches, in the order the settings list them.
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
