import Carbon
import Foundation

enum ShortcutAction: String, Codable, CaseIterable, Sendable {
    case selection
    case input
    case ocr

    var defaultShortcut: GlobalShortcut {
        let key: Int
        switch self {
        case .selection: key = kVK_ANSI_T
        case .input: key = kVK_ANSI_I
        case .ocr: key = kVK_ANSI_O
        }
        return GlobalShortcut(
            keyCode: UInt32(key), modifiers: UInt32(optionKey)
        )
    }
}

/// Modifier bits use Carbon's constants, not NSEvent.ModifierFlags raw values.
struct GlobalShortcut: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    var isValid: Bool {
        let allowed = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let required = UInt32(cmdKey | controlKey | optionKey)
        return Self.keyNames[keyCode] != nil
            && modifiers & required != 0
            && modifiers & ~allowed == 0
    }

    /// Keep common editing, window and system commands available to their apps.
    /// This is separate from syntactic validity so an old saved preference can
    /// remain visible with a useful error instead of silently changing its value.
    var isReserved: Bool {
        let command = UInt32(cmdKey)
        let shift = UInt32(shiftKey)
        let control = UInt32(controlKey)
        let option = UInt32(optionKey)
        if modifiers == command || modifiers == command | shift {
            let standardKeys: Set<UInt32> = [
                UInt32(kVK_ANSI_A), UInt32(kVK_ANSI_B), UInt32(kVK_ANSI_C),
                UInt32(kVK_ANSI_D), UInt32(kVK_ANSI_E), UInt32(kVK_ANSI_F),
                UInt32(kVK_ANSI_G), UInt32(kVK_ANSI_H), UInt32(kVK_ANSI_I),
                UInt32(kVK_ANSI_K), UInt32(kVK_ANSI_L),
                UInt32(kVK_ANSI_M), UInt32(kVK_ANSI_N), UInt32(kVK_ANSI_O),
                UInt32(kVK_ANSI_P), UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_R), UInt32(kVK_ANSI_S),
                UInt32(kVK_ANSI_T), UInt32(kVK_ANSI_U), UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_W),
                UInt32(kVK_ANSI_X), UInt32(kVK_ANSI_Y), UInt32(kVK_ANSI_Z), UInt32(kVK_ANSI_Comma),
                UInt32(kVK_ANSI_Grave), UInt32(kVK_Tab), UInt32(kVK_Return),
                UInt32(kVK_Space), UInt32(kVK_Delete), UInt32(kVK_ForwardDelete),
                UInt32(kVK_LeftArrow), UInt32(kVK_RightArrow),
                UInt32(kVK_UpArrow), UInt32(kVK_DownArrow)
            ]
            if standardKeys.contains(keyCode) { return true }
        }
        if modifiers == control || modifiers == control | shift {
            let editingKeys: Set<UInt32> = [
                UInt32(kVK_ANSI_A), UInt32(kVK_ANSI_B), UInt32(kVK_ANSI_D),
                UInt32(kVK_ANSI_E), UInt32(kVK_ANSI_F), UInt32(kVK_ANSI_H),
                UInt32(kVK_ANSI_K), UInt32(kVK_ANSI_L), UInt32(kVK_ANSI_N),
                UInt32(kVK_ANSI_O), UInt32(kVK_ANSI_P), UInt32(kVK_ANSI_T),
                UInt32(kVK_ANSI_U), UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_W),
                UInt32(kVK_ANSI_Y), UInt32(kVK_Tab), UInt32(kVK_Space),
                UInt32(kVK_LeftArrow), UInt32(kVK_RightArrow),
                UInt32(kVK_UpArrow), UInt32(kVK_DownArrow)
            ]
            if editingKeys.contains(keyCode) { return true }
        }
        if modifiers == command | shift || modifiers == command | shift | control {
            if [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].contains(Int(keyCode)) { return true }
        }
        if modifiers == command | option {
            if [kVK_Escape, kVK_ANSI_H, kVK_ANSI_M].contains(Int(keyCode)) { return true }
        }
        if modifiers == option || modifiers == option | shift {
            let wordEditingKeys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow,
                                   kVK_DownArrow, kVK_Delete, kVK_ForwardDelete]
            if wordEditingKeys.contains(Int(keyCode)) { return true }
        }
        if modifiers == command | option | shift, keyCode == UInt32(kVK_ANSI_V) { return true }
        if modifiers == command | control,
           [kVK_ANSI_Q, kVK_ANSI_F, kVK_Space].contains(Int(keyCode)) { return true }
        return false
    }

    /// Physical ANSI key labels keep saved shortcuts stable across keyboard layouts.
    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (Self.keyNames[keyCode] ?? "?")
    }

    var displayKeys: [String] {
        var keys: [String] = []
        if modifiers & UInt32(controlKey) != 0 { keys.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { keys.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { keys.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { keys.append("⌘") }
        keys.append(Self.keyNames[keyCode] ?? "?")
        return keys
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'",
        40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "⇥", 49: "␣", 50: "`", 51: "⌫", 53: "⎋",
        64: "F17", 65: "⌨.", 67: "⌨*", 69: "⌨+", 71: "⌧", 75: "⌨/",
        76: "⌤", 78: "⌨−", 79: "F18", 80: "F19", 81: "⌨=", 82: "⌨0",
        83: "⌨1", 84: "⌨2", 85: "⌨3", 86: "⌨4", 87: "⌨5", 88: "⌨6",
        89: "⌨7", 90: "F20", 91: "⌨8", 92: "⌨9", 93: "¥", 94: "_", 95: "⌨,",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦",
        118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
