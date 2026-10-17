//
//  KeyShortcut.swift
//  Nidus
//
//  A global keyboard shortcut, as a value, and the small manager that keeps
//  one registered. The registering itself is behind a protocol
//  (HotKeyRegistrar) so the tests never register a real hotkey; the app's
//  implementation is in App/FocusCapture.swift.
//
//  Nothing here watches the keyboard. A registered hotkey asks macOS to say
//  when that one combination is pressed, which needs no Input Monitoring or
//  Accessibility permission, and Nidus hears of no other key.
//
//  No DroppyKit import: this file also compiles into the tests.
//

import Foundation

struct KeyShortcut: Codable, Equatable, Sendable {
    struct Modifiers: OptionSet, Codable, Equatable, Sendable {
        let rawValue: UInt8
        static let command = Modifiers(rawValue: 1)
        static let control = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let shift = Modifiers(rawValue: 8)
    }

    /// The virtual key code (the key's place, not its letter).
    let keyCode: UInt16
    let modifiers: Modifiers
    /// What that key is called on the keyboard it was recorded on: "N",
    /// "Space", "F5".
    let key: String

    /// nil unless the combination can be a shortcut: a key you could type
    /// into a field must be held with ⌘, ⌃ or ⌥ (Shift alone isn't enough),
    /// or turning the shortcut on would take that key from every app.
    init?(keyCode: UInt16, modifiers: Modifiers, key: String) {
        let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 12,
              !modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(UInt16.self, forKey: .keyCode)
        let modifiers = try c.decode(Modifiers.self, forKey: .modifiers)
        let key = try c.decode(String.self, forKey: .key)
        guard let shortcut = KeyShortcut(keyCode: code, modifiers: modifiers, key: key) else {
            throw DecodingError.dataCorruptedError(forKey: .modifiers, in: c, debugDescription: "not a usable shortcut")
        }
        self = shortcut
    }

    enum CodingKeys: String, CodingKey { case keyCode, modifiers, key }

    /// "⌃⌥⌘N": the Mac's order, control, option, shift, command.
    var display: String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "\u{2303}" }
        if modifiers.contains(.option) { glyphs += "\u{2325}" }
        if modifiers.contains(.shift) { glyphs += "\u{21E7}" }
        if modifiers.contains(.command) { glyphs += "\u{2318}" }
        return glyphs + key
    }

    /// Said aloud: "Control Option Command N".
    var spoken: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        return (words + [key]).joined(separator: " ")
    }

    // MARK: Naming keys

    /// The name of a key that has no character of its own, by virtual key
    /// code; nil for the rest, which are named by what they type.
    static func specialName(forKeyCode code: UInt16) -> String? {
        special[code]
    }

    /// What a recorded key is called: its own name if it has one, else the
    /// character it types, upper-cased. nil when it types nothing printable.
    static func name(forKeyCode code: UInt16, characters: String?) -> String? {
        if let name = special[code] { return name }
        guard let first = characters?.unicodeScalars.first(where: { !$0.properties.isWhitespace
                  && $0.properties.generalCategory != .control }) else { return nil }
        return String(first).uppercased()
    }

    private static let special: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 71: "Clear", 76: "Enter",
        115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}

// MARK: - Keeping one registered

/// Registers a global hotkey with the system. One at a time.
@MainActor
protocol HotKeyRegistrar: AnyObject {
    /// True when the system accepted the combination; false when another app
    /// has it, or it can't be registered. `handler` runs on the main actor
    /// each time it is pressed.
    func register(_ shortcut: KeyShortcut, handler: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

/// The capture shortcut: off until the person sets one. Setting registers it,
/// clearing or replacing it first lets go of the old one, and stopping (Nidus
/// quitting) lets go of it too.
@MainActor
final class CaptureShortcut {
    private let registrar: HotKeyRegistrar
    private let onPress: @MainActor () -> Void
    /// The shortcut asked for, whether or not the system accepted it.
    private(set) var current: KeyShortcut?
    /// The system refused `current` (another app has it).
    private(set) var isRefused = false

    init(registrar: HotKeyRegistrar, onPress: @escaping @MainActor () -> Void) {
        self.registrar = registrar
        self.onPress = onPress
    }

    /// nil turns it off. Returns whether the shortcut is now live; nil is not.
    @discardableResult
    func apply(_ shortcut: KeyShortcut?) -> Bool {
        registrar.unregister()
        current = shortcut
        isRefused = false
        guard let shortcut else { return false }
        isRefused = !registrar.register(shortcut) { [onPress] in onPress() }
        return !isRefused
    }

    func stop() {
        registrar.unregister()
        current = nil
        isRefused = false
    }
}
