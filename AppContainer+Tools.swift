//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// Tool providers, hotkey and voice input settings.
extension AppContainer {
    private func updateToolSetting<V>(_ keyPath: ReferenceWritableKeyPath<AppSettings, V>, to value: V) {
        settings[keyPath: keyPath] = value
        updateTools()
    }

    func permissionMode(for chatID: UUID) -> PermissionMode { settings.permissionMode(for: chatID) }

    func setPermissionMode(_ mode: PermissionMode, for chatID: UUID) { settings.setPermissionMode(mode, for: chatID) }

    func setToolsEnabled(_ enabled: Bool) { updateToolSetting(\.toolsEnabled, to: enabled) }

    func setSearchProvider(_ provider: String) { updateToolSetting(\.searchProvider, to: provider) }

    func setFileToolsEnabled(_ enabled: Bool) { updateToolSetting(\.fileToolsEnabled, to: enabled) }

    func isToolEnabled(_ tool: ExtraTool) -> Bool { settings.extraTools.contains(tool.rawValue) }

    func setToolEnabled(_ tool: ExtraTool, _ enabled: Bool) {
        toggle(tool.rawValue, in: \.extraTools, on: enabled)
        // Request permission while in settings.
        if enabled {
            switch tool {
            case .location: LocationService.shared.requestPermission()
            case .calendar: CalendarAccess.request()
            case .contacts: ContactsAccess.request()
            case .screen: ScreenAccess.request()
            default: break
            }
        }
        updateTools()
    }

    var hotkey: GlobalHotkey.Combination {
        .init(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
    }

    var chatsHotkey: GlobalHotkey.Combination {
        .init(keyCode: settings.chatsHotkeyKeyCode, modifiers: settings.chatsHotkeyModifiers)
    }

    func restoreHotkey() { hotkeyChanged?() }

    func setHotkey(_ combination: GlobalHotkey.Combination) {
        settings.hotkeyKeyCode = combination.keyCode
        settings.hotkeyModifiers = combination.modifiers
        hotkeyChanged?()
    }

    func setChatsHotkey(_ combination: GlobalHotkey.Combination) {
        settings.chatsHotkeyKeyCode = combination.keyCode
        settings.chatsHotkeyModifiers = combination.modifiers
        hotkeyChanged?()
    }

    func setToolIterations(_ rounds: Int) {
        settings.toolIterations = min(max(rounds, 1), 100)
        applyConversationConfiguration()
    }

    func setPageCharacters(_ characters: Int) { updateToolSetting(\.pageCharacters, to: min(max(characters, 2000), 60000)) }

    func setSearchResults(_ count: Int) { updateToolSetting(\.searchResults, to: min(max(count, 3), 12)) }

    func setVoiceInputEnabled(_ enabled: Bool) { settings.voiceInputEnabled = enabled }
    func setVoiceAutoSend(_ sends: Bool) { settings.voiceAutoSend = sends }

    func setShortcutsToolEnabled(_ enabled: Bool) { updateToolSetting(\.shortcutsToolEnabled, to: enabled) }

    func addAllowedFolder(_ url: URL) {
        var list = settings.allowedFolders
        let path = url.standardizedFileURL.path
        if !list.contains(path) { list.append(path) }
        updateToolSetting(\.allowedFolders, to: list)
    }

    func removeAllowedFolder(_ path: String) {
        updateToolSetting(\.allowedFolders, to: settings.allowedFolders.filter { $0 != path })
    }

    func updateTools() {
        var providers: [any ToolProvider] = []
        if settings.toolsEnabled {
            let provider: any SearchProvider = settings.searchProvider == "google" ? GoogleProvider() : DuckDuckGoProvider()
            var web = WebToolProvider.Configuration()
            web.maxPageCharacters = settings.pageCharacters
            web.maxResults = settings.searchResults
            providers.append(WebToolProvider(provider: provider, configuration: web))
        }
        if settings.fileToolsEnabled, !settings.allowedFolders.isEmpty {
            providers.append(
                FileToolProvider(
                    configuration: .init(
                        allowedFolders: settings.allowedFolders.map { URL(fileURLWithPath: $0) }, confirmation: NotificationService.shared))
            )
        }
        // Enabled tools are permitted; only file changes still ask.
        for tool in ExtraTool.allCases where isToolEnabled(tool) {
            switch tool {
            case .calculator: providers.append(JavaScriptToolProvider())
            case .macInfo: providers.append(MacInfoToolProvider())
            case .network: providers.append(NetworkToolProvider())
            case .weather:
                var weather = WeatherToolProvider()
                weather.usesCurrentPlace = isToolEnabled(.location)
                providers.append(weather)
            case .location: providers += [LocationToolProvider(), MapsToolProvider()]
            case .trips:
                var trips = TripsToolProvider()
                trips.usesCurrentPlace = isToolEnabled(.location)
                providers.append(trips)
            case .browser:
                providers.append(SafariToolProvider(configuration: .init(pageCharacters: settings.pageCharacters)))
            case .calendar: providers.append(CalendarToolProvider())
            case .timers: providers.append(TimerToolProvider())
            case .screen: providers.append(ScreenToolProvider())
            case .currency: providers.append(CurrencyToolProvider())
            case .contacts: providers.append(ContactsToolProvider())
            case .notes: providers.append(NotesToolProvider())
            case .mail: providers.append(MailToolProvider())
            case .spotlight: providers.append(SpotlightToolProvider())
            case .macControl: providers.append(MacControlToolProvider())
            case .music: providers.append(MusicToolProvider())
            case .codingFiles, .codingSkills, .codingEdit, .codingScripts, .codingCommands, .codingGit, .codingIndexing: break
            }
        }
        let codingFeatures = Set(PluginGroup.coding.tools.filter { isToolEnabled($0) })
        if !codingFeatures.isEmpty {
            providers.append(
                CodingToolProvider(
                    configuration: .init(
                        enabled: codingFeatures, allowedFolders: settings.allowedFolders,
                        projects: codingProjects, snapshots: codingSnapshots, tasks: codingTasks,
                        confirmation: NotificationService.shared)))
        }
        if settings.shortcutsToolEnabled {
            providers.append(ShortcutToolProvider())
        }
        let tools: any ToolProvider = CompositeToolProvider(providers)
        toolSpecs = tools.specs
        Task { await conversation.setTools(tools) }
    }
}
