import Foundation

enum SystemPermission: Equatable {
    case accessibility, screenCapture

    var title: String {
        L10n.string(self == .accessibility ? "Translate your selection" : "Translate a screenshot")
    }

    var explanation: String {
        L10n.string(self == .accessibility
            ? "Allow Accessibility so TSX can read selected text when you use the shortcut. Your text isn’t collected in the background."
            : "Allow Screen Recording to recognize text in an area you select. Screenshots stay in memory on your Mac. After enabling access, start Screenshot Translation again.")
    }

    var actionTitle: String {
        L10n.string(self == .accessibility ? "Allow Accessibility" : "Allow Screen Recording")
    }
}
