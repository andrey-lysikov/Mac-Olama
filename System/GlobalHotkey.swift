//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    struct Combination: Equatable {
        var keyCode: Int
        var modifiers: Int
        var isSet: Bool { keyCode >= 0 && modifiers != 0 }
    }

    static let modifierMasks: [(symbol: String, mask: Int)] = [
        ("⌃", controlKey), ("⌥", optionKey), ("⇧", shiftKey), ("⌘", cmdKey),
    ]

    static let keys: [(title: String, code: Int)] = [
        ("F1", kVK_F1), ("F2", kVK_F2), ("F3", kVK_F3), ("F4", kVK_F4), ("F5", kVK_F5), ("F6", kVK_F6), ("F7", kVK_F7),
        ("F8", kVK_F8), ("F9", kVK_F9), ("F10", kVK_F10), ("F11", kVK_F11), ("F12", kVK_F12),
    ]

    private var handler: EventHandlerRef?
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]

    @discardableResult
    func register(_ combination: Combination, id: UInt32 = 1, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        guard combination.isSet else { return false }
        guard installHandlerIfNeeded() else { return false }

        actions[id] = action
        Self.active = self

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4F_4C41), id: id)  // 'MOLA'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combination.keyCode), UInt32(combination.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            actions[id] = nil
            let description = Self.describe(combination) ?? "?"
            if status == OSStatus(eventHotKeyExistsErr) {
                print("Hotkey \(description) (slot \(id)) is already in use")
            } else {
                print(
                    "RegisterEventHotKey failed for \(description) (slot \(id)): \(status)")
            }
            return false
        }
        hotKeys[id] = ref
        return true
    }

    func unregister(id: UInt32? = nil) {
        for (key, ref) in hotKeys where id == nil || key == id { UnregisterEventHotKey(ref) }
        if let id { hotKeys[id] = nil; actions[id] = nil } else { hotKeys.removeAll(); actions.removeAll() }
    }

    private func installHandlerIfNeeded() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), Self.callback, 1, &spec, nil, &handler)
        guard status == noErr else {
            handler = nil
            return false
        }
        return true
    }

    private nonisolated(unsafe) static weak var active: GlobalHotkey?

    private func performAction(id: UInt32) {
        actions[id]?()
    }

    private static let callback: EventHandlerUPP = { _, event, _ in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        // Имя параметра — kEventParamDirectObject ('----'),
        // а 'hkid' (typeEventHotKeyID) — это его ТИП.
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr, hotKeyID.signature == OSType(0x4D4F_4C41) else {
            return OSStatus(eventNotHandledErr)
        }
        let id = hotKeyID.id
        Task { @MainActor in GlobalHotkey.active?.performAction(id: id) }
        return noErr
    }

    static func describe(_ combination: Combination) -> String? {
        guard combination.isSet else { return nil }
        let modifiers = modifierMasks.filter { combination.modifiers & $0.mask != 0 }.map(\.symbol).joined()
        return modifiers + name(ofKey: combination.keyCode)
    }

    static func name(ofKey code: Int) -> String {
        if let known = keys.first(where: { $0.code == code })?.title { return known }
        switch character(ofKey: code) {
        case " ": return "Space"
        case "\r", "\n": return "Return"
        case "\t": return "Tab"
        case "\u{7F}": return "⌫"
        case "\u{1B}": return "Esc"
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
        case let character?: return character
        case nil: return "#\(code)"
        }
    }

    private static func character(ofKey code: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                // Нужна маска (1 << bit), а не номер бита, иначе dead keys не отключаются.
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &dead, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.shift) { mask |= shiftKey }
        if flags.contains(.control) { mask |= controlKey }
        return mask
    }
}
