import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The key you hold to talk.
///
/// Two shapes, because push-to-talk wants both. A *modifier-only* hotkey (hold fn, or
/// right ⌥) is the nicest to hold down and cannot collide with typing. A *combo*
/// (⌃⌥ + Space) is there when every modifier is already spoken for.
struct Hotkey: Codable, Equatable, Sendable, Hashable {
    var keyCode: Int
    /// `CGEventFlags` raw value, masked to the device-independent modifier bits.
    var modifiers: UInt64
    /// True when the key *is* a modifier, so it is tracked through flag changes.
    var isModifierOnly: Bool

    static let modifierMask: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers & Self.modifierMask) }

    // MARK: - Presets

    static let fn = Hotkey(keyCode: 63, modifiers: CGEventFlags.maskSecondaryFn.rawValue, isModifierOnly: true)
    static let rightOption = Hotkey(keyCode: kVK_RightOption, modifiers: CGEventFlags.maskAlternate.rawValue, isModifierOnly: true)
    static let rightCommand = Hotkey(keyCode: kVK_RightCommand, modifiers: CGEventFlags.maskCommand.rawValue, isModifierOnly: true)
    static let rightControl = Hotkey(keyCode: kVK_RightControl, modifiers: CGEventFlags.maskControl.rawValue, isModifierOnly: true)

    /// Combos, for when every spare modifier is already taken. These suit toggle mode,
    /// where the key is tapped rather than held.
    static let optionCommandD = Hotkey(
        keyCode: kVK_ANSI_D,
        modifiers: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue,
        isModifierOnly: false
    )
    /// Hyper: ⌃⌥⇧⌘ together, which nothing else on macOS claims.
    static let hyperD = Hotkey(
        keyCode: kVK_ANSI_D,
        modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskShift.rawValue | CGEventFlags.maskCommand.rawValue,
        isModifierOnly: false
    )

    /// Modifier-only presets: the ones that are pleasant to hold down.
    static let holdPresets: [Hotkey] = [.fn, .rightOption, .rightCommand, .rightControl]

    /// Combo presets. Every one carries at least one modifier, so it cannot fire while
    /// you type. These suit toggle mode, where the key is tapped rather than held.
    static let comboPresets: [Hotkey] = [.optionCommandD, .hyperD]

    static let presets: [Hotkey] = holdPresets + comboPresets

    var isPreset: Bool { Self.presets.contains(self) }

    // MARK: - Building from an event

    /// A modifier being held on its own.
    static func modifierOnly(keyCode: Int) -> Hotkey? {
        guard let flag = modifierFlag(forKeyCode: keyCode) else { return nil }
        return Hotkey(keyCode: keyCode, modifiers: flag.rawValue, isModifierOnly: true)
    }

    /// A regular key plus whatever modifiers were held with it.
    static func combo(keyCode: Int, flags: CGEventFlags) -> Hotkey {
        Hotkey(keyCode: keyCode, modifiers: flags.rawValue & modifierMask, isModifierOnly: false)
    }

    static func modifierFlag(forKeyCode keyCode: Int) -> CGEventFlags? {
        switch keyCode {
        case 63: .maskSecondaryFn
        case kVK_Command, kVK_RightCommand: .maskCommand
        case kVK_Option, kVK_RightOption: .maskAlternate
        case kVK_Control, kVK_RightControl: .maskControl
        case kVK_Shift, kVK_RightShift: .maskShift
        default: nil
        }
    }

    // MARK: - Display

    var label: String {
        if isModifierOnly { return Self.modifierName(keyCode) }
        return Self.modifierSymbols(flags) + Self.keyName(keyCode)
    }

    private static func modifierName(_ keyCode: Int) -> String {
        switch keyCode {
        case 63: "fn (globe)"
        case kVK_Command: "Left ⌘"
        case kVK_RightCommand: "Right ⌘"
        case kVK_Option: "Left ⌥"
        case kVK_RightOption: "Right ⌥"
        case kVK_Control: "Left ⌃"
        case kVK_RightControl: "Right ⌃"
        case kVK_Shift: "Left ⇧"
        case kVK_RightShift: "Right ⇧"
        default: "Key \(keyCode)"
        }
    }

    private static func modifierSymbols(_ flags: CGEventFlags) -> String {
        var out = ""
        if flags.contains(.maskSecondaryFn) { out += "fn " }
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskShift) { out += "⇧" }
        if flags.contains(.maskCommand) { out += "⌘" }
        return out
    }

    private static func keyName(_ keyCode: Int) -> String {
        if let named = names[keyCode] { return named }
        return "Key \(keyCode)"
    }

    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Esc",
        kVK_Delete: "Delete", kVK_ForwardDelete: "Fwd Delete",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11",
        kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
    ]
}
