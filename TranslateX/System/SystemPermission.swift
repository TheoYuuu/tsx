import Foundation

enum SystemPermission: Equatable {
    case accessibility, screenCapture

    var name: String {
        L10n.string(self == .accessibility ? "Accessibility permission" : "Screen Recording permission")
    }

    var title: String {
        L10n.string(self == .accessibility ? "Enable selection translation" : "Enable screenshot translation")
    }

    var explanation: String {
        L10n.string(self == .accessibility
            ? "Allow TSX in System Settings → Accessibility to translate selected text with your shortcut."
            : "Allow TSX in System Settings → Screen Recording, then start Screenshot Translation again.")
    }

    var privacyNote: String {
        L10n.string(self == .accessibility
            ? "Reads only when you use the shortcut. No background collection."
            : "Captures only the area you select. Screenshots stay in memory on your Mac.")
    }

    var actionTitle: String {
        L10n.string(self == .accessibility ? "Allow Accessibility" : "Allow Screen Recording")
    }
}
