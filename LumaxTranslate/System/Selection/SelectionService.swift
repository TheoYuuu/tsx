import AppKit
import OSLog
// This C framework declares kAXTrustedCheckOptionPrompt as a mutable global,
// although it is the immutable dictionary key documented by the API.
@preconcurrency import ApplicationServices

/// Only system boundaries are replaceable in tests; live uses AX and real focus.
struct SelectionEnvironment {
    typealias BeforeCopy = @MainActor @Sendable () async throws -> Void
    var isTrusted: @MainActor () -> Bool
    var sourceIsActive: @MainActor (pid_t) -> Bool
    var modifiersArePressed: @MainActor () -> Bool
    var read: @Sendable (pid_t) async throws -> AXSelectionReader.Result
    var copy: @Sendable (pid_t, UUID, BeforeCopy) async throws -> Void

    @MainActor static var live: Self {
        let reader = AXSelectionReader()
        return Self(
            isTrusted: { SelectionService.isAccessibilityTrusted },
            sourceIsActive: { NSWorkspace.shared.frontmostApplication?.processIdentifier == $0 },
            modifiersArePressed: {
                let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
                return !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty
            },
            read: { try await reader.selection(processID: $0) },
            copy: { try await reader.copy(processID: $0, candidateID: $1, beforePosting: $2) }
        )
    }
}

@MainActor
final class SelectionService {
    private static let logger = Logger(subsystem: "com.theoyuuu.LumaxTranslate", category: "Selection")
    private let environment: SelectionEnvironment
    private let clipboard: SelectionClipboard
    private var activeTask: Task<SelectedText, Error>?
    // Fixed diagnostic labels only. Never log app identities, text or clipboard data.
    private var step = "idle"
    var hasActiveCapture: Bool { activeTask != nil }

    init(environment: SelectionEnvironment = .live, clipboard: SelectionClipboard = SelectionClipboard()) {
        self.environment = environment
        self.clipboard = clipboard
    }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Call only after an explicit user action; initialization never prompts for access.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The caller must capture the source app before showing or activating a Lumax window.
    func capture(from source: NSRunningApplication) async throws -> SelectedText {
        guard activeTask == nil else { throw SelectionError.busy }
        try Task.checkCancellation()
        guard environment.isTrusted() else { throw SelectionError.accessibilityPermissionRequired }
        let processID = source.processIdentifier
        guard !source.isTerminated, processID != NSRunningApplication.current.processIdentifier else {
            throw SelectionError.sourceUnavailable
        }
        let sourceName = source.localizedName ?? source.bundleIdentifier ?? "App"
        let task = Task { try await performCapture(processID: processID, sourceName: sourceName) }
        activeTask = task
        defer { activeTask = nil }
        do {
            let selected = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let method = selected.method == .accessibility ? "accessibility" : "copy"
            Self.logger.notice("Selection completed: \(method, privacy: .public)")
            return selected
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let code = (error as? SelectionError)?.rawValue ?? "unexpected"
            Self.logger.notice("Selection stopped: step=\(self.step, privacy: .public) reason=\(code, privacy: .public)")
            throw error
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    /// Used during normal termination so a posted Copy can finish its restoration.
    /// Pasteboard IPC may be delayed by its owner; it cannot be forcibly cancelled.
    func cancelAndWait() async {
        guard let task = activeTask else { return }
        task.cancel()
        _ = try? await task.value
    }

    private func performCapture(processID: pid_t, sourceName: String) async throws -> SelectedText {
        step = "read-selection"
        try ensureSourceIsActive(processID)
        let result = try await environment.read(processID)
        try Task.checkCancellation()
        try ensureSourceIsActive(processID)
        switch result {
        case .text(let text, let bounds):
            return SelectedText(text: text, sourceName: sourceName, bounds: bounds, method: .accessibility)
        case .copyCandidate(let candidateID):
            step = "wait-shortcut-release"
            try await waitForShortcutRelease(processID: processID)
            try Task.checkCancellation()
            // An unstructured transaction finishes its bounded cleanup even if the caller
            // cancels after the copy command is posted. The outer task stays busy until then.
            let transaction = Task {
                try await copySelection(processID: processID, sourceName: sourceName, candidateID: candidateID)
            }
            do {
                let selection = try await transaction.value
                try Task.checkCancellation()
                return selection
            } catch {
                // Cancellation takes precedence over a cleanup/timeout error, so closing
                // the translation entry does not later reopen it with an obsolete error.
                try Task.checkCancellation()
                throw error
            }
        }
    }

    private func waitForShortcutRelease(processID: pid_t) async throws {
        let clock = ContinuousClock()
        // This is human key-release time, not an IPC timeout. A deliberate chord
        // commonly lasts longer than 500 ms; keep checking focus/cancellation.
        let deadline = clock.now.advanced(by: .seconds(3))
        while environment.modifiersArePressed() {
            try Task.checkCancellation()
            try ensureSourceIsActive(processID)
            guard clock.now < deadline else { throw SelectionError.shortcutStillPressed }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func copySelection(processID: pid_t, sourceName: String, candidateID: UUID) async throws -> SelectedText {
        step = "backup-clipboard"
        try ensureCaptureMayCopy(processID)
        let backup = try await clipboard.backup()
        try ensureCaptureMayCopy(processID)
        var observation = CopyObservation(initialChangeCount: backup.changeCount)
        step = "validate-and-copy"
        try await environment.copy(processID, candidateID) { [self] in
            try ensureCaptureMayCopy(processID)
            guard await clipboard.changeCount() == backup.changeCount else { throw SelectionError.clipboardChanged }
            try ensureCaptureMayCopy(processID)
        }

        step = "read-copy"
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        var text: String?
        var operationError: (any Error)?
        do {
            while clock.now < deadline {
                try ensureSourceIsActive(processID)
                let currentChangeCount = await clipboard.changeCount()
                switch observation.observe(currentChangeCount) {
                case .waiting: break
                case .interference: throw SelectionError.clipboardChanged
                case .candidate:
                    let candidateText = try await clipboard.readText(expectedChangeCount: currentChangeCount)
                    try ensureSourceIsActive(processID)
                    // A synchronous provider read cannot be killed by Task cancellation.
                    // It runs off MainActor and a late response never becomes a result.
                    guard clock.now < deadline else { throw SelectionError.copyTimedOut }
                    if let candidateText {
                        text = try SelectionText.validated(candidateText)
                    }
                }
                if text != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if text == nil {
                throw observation.copiedChangeCount == nil ? SelectionError.copyTimedOut : SelectionError.noSelection
            }
        } catch {
            operationError = error
        }

        var failureStep = step
        var restored = false
        if let copiedChangeCount = observation.copiedChangeCount, !observation.hasInterference {
            step = "restore-clipboard"
            restored = try await clipboard.restore(backup, expectedChangeCount: copiedChangeCount) { [self] in
                sourceIsActive(processID)
            }
        }
        if !restored, observation.copiedChangeCount != nil, operationError == nil {
            operationError = SelectionError.clipboardChanged
            failureStep = "restore-clipboard"
        }
        if let operationError {
            step = failureStep
            throw operationError
        }
        guard let text else { throw SelectionError.noSelection }
        return SelectedText(text: text, sourceName: sourceName, bounds: nil, method: .copy)
    }

    private func ensureSourceIsActive(_ processID: pid_t) throws {
        guard sourceIsActive(processID) else { throw SelectionError.sourceChanged }
    }

    private func ensureCaptureMayCopy(_ processID: pid_t) throws {
        guard activeTask?.isCancelled == false else { throw CancellationError() }
        try ensureSourceIsActive(processID)
    }

    private func sourceIsActive(_ processID: pid_t) -> Bool {
        environment.sourceIsActive(processID)
    }
}
