import Foundation
import AppKit
import Carbon.HIToolbox

/// The global "Quick Add from anywhere" chord: a virtual key code plus Carbon modifier bits, which is exactly what
/// `RegisterEventHotKey` takes. Pure value type with no UI, so the encoding and the display string are unit tested.
struct QuickAddShortcut: Equatable, Codable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier bits (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`).
    var modifiers: UInt32

    static let control = UInt32(controlKey), option = UInt32(optionKey), shift = UInt32(shiftKey), command = UInt32(cmdKey)
    private static let modifierMask = control | option | shift | command

    /// ⌃⌥Space.
    static let `default` = QuickAddShortcut(keyCode: UInt32(kVK_Space), modifiers: control | option)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    /// Converts AppKit modifier flags (from a recorded key event) to Carbon bits.
    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var bits: UInt32 = 0
        if flags.contains(.control) { bits |= Self.control }
        if flags.contains(.option) { bits |= Self.option }
        if flags.contains(.shift) { bits |= Self.shift }
        if flags.contains(.command) { bits |= Self.command }
        self.init(keyCode: UInt32(keyCode), modifiers: bits)
    }

    // MARK: Display

    /// macOS order: ⌃ ⌥ ⇧ ⌘, then the key. For example "⌃⌥Space".
    var displayString: String {
        var result = ""
        if modifiers & Self.control != 0 { result += "⌃" }
        if modifiers & Self.option != 0 { result += "⌥" }
        if modifiers & Self.shift != 0 { result += "⇧" }
        if modifiers & Self.command != 0 { result += "⌘" }
        return result + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        names[Int(code)] ?? "Key \(code)"
    }

    private static let names: [Int: String] = {
        var table: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G",
            kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N",
            kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U",
            kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() { table[code] = "F\(index + 1)" }
        return table
    }()

    // MARK: Validity

    enum Problem: Equatable {
        case needsModifier
        case reserved(String)
        var message: String {
            switch self {
            case .needsModifier: return "Include at least one of ⌃, ⌥ or ⌘ so the shortcut does not interfere with typing."
            case .reserved(let owner): return "\(owner) already uses this shortcut. Choose a different one."
            }
        }
    }

    private static let functionKeyCodes: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
    /// Chords that macOS or Taskfold's own menus own. Registering them would either fail or shadow a command.
    private static let reserved: [(QuickAddShortcut, String)] = [
        (QuickAddShortcut(keyCode: UInt32(kVK_Space), modifiers: command), "Spotlight"),
        (QuickAddShortcut(keyCode: UInt32(kVK_Space), modifiers: command | option), "Finder search"),
        (QuickAddShortcut(keyCode: UInt32(kVK_Space), modifiers: control), "Input sources"),
        (QuickAddShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: control | option | command), "Taskfold (Edit Deadlines)"),
        (QuickAddShortcut(keyCode: UInt32(kVK_Tab), modifiers: command), "the app switcher"),
        (QuickAddShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: command), "Quit"),
    ]

    /// Nil when the chord can be registered. Shift alone (or no modifier) would capture plain typing system-wide.
    var problem: Problem? {
        let hasMain = modifiers & (Self.control | Self.option | Self.command) != 0
        if !hasMain && !Self.functionKeyCodes.contains(Int(keyCode)) { return .needsModifier }
        if let match = Self.reserved.first(where: { $0.0 == self }) { return .reserved(match.1) }
        return nil
    }
}

/// Persistence for the shortcut. A cleared shortcut is stored explicitly so "no shortcut" survives a relaunch
/// instead of falling back to the default.
enum QuickAddShortcutStore {
    static let key = "quickAddShortcut"

    /// The stored shortcut, nil when the user cleared it, the default when nothing (or something unreadable) is stored.
    static func load(_ defaults: UserDefaults = .standard) -> QuickAddShortcut? {
        guard let stored = defaults.dictionary(forKey: key) else { return .default }
        if stored["cleared"] as? Bool == true { return nil }
        guard let code = (stored["keyCode"] as? NSNumber)?.intValue, let modifiers = (stored["modifiers"] as? NSNumber)?.intValue,
              code >= 0, code < 0x80, modifiers >= 0 else { return .default }
        return QuickAddShortcut(keyCode: UInt32(code), modifiers: UInt32(modifiers))
    }

    static func save(_ shortcut: QuickAddShortcut?, _ defaults: UserDefaults = .standard) {
        if let shortcut { defaults.set(["keyCode": Int(shortcut.keyCode), "modifiers": Int(shortcut.modifiers)], forKey: key) }
        else { defaults.set(["cleared": true], forKey: key) }
    }

    static func reset(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
