import Foundation

struct SelectedText: Sendable {
    enum Method: Sendable {
        case accessibility
        case copy
    }

    let text: String
    let sourceName: String
    /// Accessibility screen coordinates, with the origin at the primary display's top left.
    let bounds: CGRect?
    let method: Method
}

enum SelectionError: String, Error, Equatable, Sendable {
    case accessibilityPermissionRequired
    case sourceUnavailable
    case sourceChanged
    case sourceUnresponsive
    case secureInput
    case noSelection
    case copyUnavailable
    case shortcutStillPressed
    case copyTimedOut
    case clipboardUnavailable
    case clipboardChanged
    case clipboardRestoreFailed
    case textTooLong
    case busy
}

/// A permission failure needs its recovery page, while other failures keep the
/// retry/input flow. Only fixed message keys leave the selection error boundary.
enum SelectionFailure: Equatable, Sendable {
    case accessibilityPermissionRequired
    case message(String)

    init(_ error: any Error) {
        switch error as? SelectionError {
        case .accessibilityPermissionRequired:
            self = .accessibilityPermissionRequired
        case .noSelection:
            self = .message("No text is selected. Select some text and try again, or type to translate.")
        case .secureInput:
            self = .message("Protected fields can’t be read. Use input translation for other text.")
        case .sourceChanged, .clipboardChanged:
            self = .message("The selection or clipboard changed. Select your text and try again.")
        case .textTooLong:
            self = .message("This selection is too long. Try a smaller passage.")
        case .busy:
            self = .message("The previous selection is still finishing. Try again in a moment.")
        case .shortcutStillPressed:
            self = .message("Release the shortcut keys, then try again.")
        case .sourceUnresponsive:
            self = .message("This app took too long to respond. Try again, or use input translation.")
        case .copyTimedOut:
            self = .message("This app didn’t respond to Copy. Select text and try again, or use input translation.")
        case .clipboardUnavailable:
            self = .message("Your clipboard couldn’t be backed up, so nothing was copied. Use input translation or try again after your next copy.")
        case .clipboardRestoreFailed:
            self = .message("Your previous clipboard couldn’t be restored. Copy the content you want to keep again.")
        default:
            self = .message("This app didn’t provide selected text. Try again, or use input translation.")
        }
    }
}

enum SelectionText {
    static let maximumLength = 50_000

    static func validated(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SelectionError.noSelection }
        guard trimmed.count <= maximumLength else { throw SelectionError.textTooLong }
        return trimmed
    }
}

/// Tracks a single copy operation. A second owner change invalidates the operation;
/// it must never be mistaken for another result from the same copy command.
struct CopyObservation: Sendable {
    enum Change: Equatable {
        case waiting
        case candidate
        case interference
    }

    let initialChangeCount: Int
    private(set) var copiedChangeCount: Int?
    private(set) var hasInterference = false

    mutating func observe(_ changeCount: Int) -> Change {
        guard !hasInterference else { return .interference }
        if let copiedChangeCount {
            guard copiedChangeCount == changeCount else {
                hasInterference = true
                return .interference
            }
            return .candidate
        }
        guard changeCount != initialChangeCount else { return .waiting }
        // More than one ownership change may happen before the first poll. Its
        // final contents cannot safely be attributed to our Copy or restored.
        guard changeCount == initialChangeCount &+ 1 else {
            hasInterference = true
            return .interference
        }
        copiedChangeCount = changeCount
        return .candidate
    }

    func mayRestore(currentChangeCount: Int, sourceIsStillActive: Bool) -> Bool {
        !hasInterference && sourceIsStillActive && copiedChangeCount == currentChangeCount
    }
}
