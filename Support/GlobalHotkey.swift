//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Carbon.HIToolbox

/// The shortcut that opens the panel while another app is in front. `RegisterEventHotKey` is the one way to catch a
/// combination system-wide without the accessibility permission a global event monitor would need, and unlike the
/// `NSServices` shortcut it can be set here instead of in System Settings, where our service cannot be given one.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// The combination as the app stores it: a virtual key code and the Carbon modifier mask.
    struct Combination: Equatable {
        var keyCode: Int
        var modifiers: Int
        var isSet: Bool { keyCode > 0 && modifiers != 0 }
    }

    /// Modifiers offered in the settings, in the order the system writes them.
    static let modifierMasks: [(symbol: String, mask: Int)] = [
        ("⌃", controlKey), ("⌥", optionKey), ("⇧", shiftKey), ("⌘", cmdKey),
    ]

    /// Names for the keys a combination is likely to use; anything else is shown by its own character.
    static let keys: [(title: String, code: Int)] = {
        var keys: [(String, Int)] = [
            ("Space", kVK_Space), ("Return", kVK_Return), ("Tab", kVK_Tab), ("⌫", kVK_Delete), ("Esc", kVK_Escape),
            ("←", kVK_LeftArrow), ("→", kVK_RightArrow), ("↑", kVK_UpArrow), ("↓", kVK_DownArrow),
        ]
        let letters: [(String, Int)] = [
            ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D), ("E", kVK_ANSI_E), ("F", kVK_ANSI_F),
            ("G", kVK_ANSI_G), ("H", kVK_ANSI_H), ("I", kVK_ANSI_I), ("J", kVK_ANSI_J), ("K", kVK_ANSI_K), ("L", kVK_ANSI_L),
            ("M", kVK_ANSI_M), ("N", kVK_ANSI_N), ("O", kVK_ANSI_O), ("P", kVK_ANSI_P), ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R),
            ("S", kVK_ANSI_S), ("T", kVK_ANSI_T), ("U", kVK_ANSI_U), ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X),
            ("Y", kVK_ANSI_Y), ("Z", kVK_ANSI_Z),
        ]
        let function: [(String, Int)] = [
            ("F1", kVK_F1), ("F2", kVK_F2), ("F3", kVK_F3), ("F4", kVK_F4), ("F5", kVK_F5), ("F6", kVK_F6), ("F7", kVK_F7),
            ("F8", kVK_F8), ("F9", kVK_F9), ("F10", kVK_F10), ("F11", kVK_F11), ("F12", kVK_F12),
        ]
        keys.append(contentsOf: letters)
        keys.append(contentsOf: function)
        return keys
    }()

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// Installs the combination, replacing whatever was registered before. An empty one leaves the app without a
    /// shortcut, which is how it ships.
    func register(_ combination: Combination, action: @escaping () -> Void) {
        unregister()
        guard combination.isSet else { return }
        self.action = action
        Self.active = self
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), Self.callback, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4D4F_4C41), id: 1)  // 'MOLA'
        RegisterEventHotKey(UInt32(combination.keyCode), UInt32(combination.modifiers), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        action = nil
    }

    /// The C handler carries no context, so it reaches the one instance that registered a key.
    private nonisolated(unsafe) static weak var active: GlobalHotkey?

    private static let callback: EventHandlerUPP = { _, _, _ in
        Task { @MainActor in GlobalHotkey.active?.action?() }
        return noErr
    }

    /// How a combination reads in the settings: ⌃⌥⇧⌘ and then the key, as menus write it.
    static func describe(_ combination: Combination) -> String? {
        guard combination.isSet else { return nil }
        let modifiers = modifierMasks.filter { combination.modifiers & $0.mask != 0 }.map(\.symbol).joined()
        return modifiers + name(ofKey: combination.keyCode)
    }

    /// A key's own name, or the character it types when the table does not name it.
    static func name(ofKey code: Int) -> String {
        if let known = keys.first(where: { $0.code == code })?.title { return known }
        return character(ofKey: code) ?? "#\(code)"
    }

    /// What the key types with no modifiers, asked of the current keyboard layout.
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
                layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &dead, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    /// The Carbon mask behind the flags of a key event.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.shift) { mask |= shiftKey }
        if flags.contains(.control) { mask |= controlKey }
        return mask
    }
}
