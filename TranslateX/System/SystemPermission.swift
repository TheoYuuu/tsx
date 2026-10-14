import Foundation

enum SystemPermission: Equatable {
    case accessibility, screenCapture

    var name: String {
        L10n.string(self == .accessibility ? "Accessibility permission" : "Screen Recording permission")
    }

    var title: String {
        L10n.string(self == .accessibility ? "Allow selection translation" : "Allow screenshot translation")
    }

    var featureName: String {
        L10n.string(self == .accessibility ? "TSX selection translation" : "TSX screenshot translation")
    }

    var explanation: String {
        L10n.string(self == .accessibility
            ? "Allow TSX to read selected text when you start a translation with a shortcut or menu action. After enabling access, start selection translation again."
            : "Allow TSX to capture the screen area you select and recognize its text. After enabling access, start screenshot translation again.")
    }

    var triggerNote: String {
        L10n.string(self == .accessibility
            ? "Only reads selected text when you start a translation."
            : "Only captures the area you choose.")
    }

    var privacyNote: String {
        L10n.string(self == .accessibility
            ? "No background monitoring or saved translation history."
            : "Screenshots stay in memory by default. Copying or saving is your choice.")
    }

    var serviceNote: String {
        L10n.string(self == .accessibility
            ? "When you use an external service, the selected text is sent to that service."
            : "When you use an external service, recognized text is sent to that service. Screenshots are not uploaded.")
    }

    var actionTitle: String {
        L10n.string(self == .accessibility ? "Allow Accessibility" : "Allow Screen Recording")
    }
}
