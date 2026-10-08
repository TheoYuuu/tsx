import Foundation
import Observation

/// Commits preferences only after the system accepts the corresponding change.
/// A configured shortcut can differ from its effective value after a startup
/// conflict, so menus must use effectiveShortcut(for:).
@MainActor @Observable
final class ShortcutSettings {
    private(set) var recordingAction: ShortcutAction?
    private(set) var candidate: GlobalShortcut?
    private var effectiveBindings: [ShortcutAction: GlobalShortcut] = [:]
    private var errors: [ShortcutAction: ShortcutError] = [:]

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let manager: ShortcutManager
    @ObservationIgnored private let onAction: @MainActor (ShortcutAction) -> Void
    @ObservationIgnored private let onBindingsChanged: @MainActor () -> Void
    @ObservationIgnored private var recordingID: UUID?
    @ObservationIgnored private var errorBeforeRecording: ShortcutError?

    init(
        preferences: AppPreferences,
        manager: ShortcutManager,
        onAction: @escaping @MainActor (ShortcutAction) -> Void,
        onBindingsChanged: @escaping @MainActor () -> Void
    ) {
        self.preferences = preferences
        self.manager = manager
        self.onAction = onAction
        self.onBindingsChanged = onBindingsChanged
    }

    /// Register independently: a collision on one action leaves the others usable.
    /// Repeating start also retries a startup conflict without rewriting settings.
    func start() {
        endRecording()
        for action in ShortcutAction.allCases {
            _ = apply(configuredShortcut(for: action), for: action, persist: false)
        }
    }

    func configuredShortcut(for action: ShortcutAction) -> GlobalShortcut? {
        preferences.shortcut(for: action)
    }

    func rememberedShortcut(for action: ShortcutAction) -> GlobalShortcut {
        preferences.rememberedShortcut(for: action)
    }

    func isEnabled(_ action: ShortcutAction) -> Bool {
        configuredShortcut(for: action) != nil
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for action: ShortcutAction) -> Bool {
        endRecording()
        return update(enabled ? rememberedShortcut(for: action) : nil, for: action)
    }

    func effectiveShortcut(for action: ShortcutAction) -> GlobalShortcut? {
        effectiveBindings[action]
    }

    func error(for action: ShortcutAction) -> String? { errors[action]?.errorDescription }

    @discardableResult
    func update(_ shortcut: GlobalShortcut?, for action: ShortcutAction) -> Bool {
        let succeeded = apply(shortcut, for: action, persist: true)
        if succeeded, recordingAction == action { finishRecording(restoreError: false) }
        return succeeded
    }

    @discardableResult
    func reset(for action: ShortcutAction) -> Bool {
        endRecording()
        if !isEnabled(action) {
            preferences.setPausedShortcut(action.defaultShortcut, for: action)
            errors[action] = nil
            onBindingsChanged()
            return true
        }
        return update(action.defaultShortcut, for: action)
    }

    @discardableResult
    func beginRecording(for action: ShortcutAction) -> UUID {
        endRecording()
        errorBeforeRecording = errors[action]
        errors[action] = nil
        recordingAction = action
        let id = manager.beginRecording { [weak self] shortcut in
            guard let self, let id = self.recordingID else { return }
            self.record(shortcut, token: id)
        }
        recordingID = id
        return id
    }

    func isRecording(_ token: UUID) -> Bool { recordingID == token }

    /// A token prevents an old view's late teardown from ending the next row's recording.
    func endRecording(_ token: UUID? = nil) {
        if let token, token != recordingID { return }
        finishRecording(restoreError: true)
    }

    private func finishRecording(restoreError: Bool) {
        if restoreError, let recordingAction { errors[recordingAction] = errorBeforeRecording }
        if let recordingID { manager.endRecording(recordingID) }
        recordingID = nil
        candidate = nil
        recordingAction = nil
        errorBeforeRecording = nil
    }

    func record(_ shortcut: GlobalShortcut, token: UUID) {
        guard recordingID == token, let action = recordingAction else { return }
        candidate = shortcut
        _ = update(shortcut, for: action)
    }

    private func apply(_ shortcut: GlobalShortcut?, for action: ShortcutAction, persist: Bool) -> Bool {
        do {
            if let shortcut {
                try manager.register(shortcut, for: action) { [weak self] in self?.onAction(action) }
            } else {
                try manager.unregister(for: action)
            }
            if persist { preferences.setShortcut(shortcut, for: action) }
            effectiveBindings[action] = manager.shortcut(for: action)
            errors[action] = nil
            onBindingsChanged()
            return true
        } catch {
            effectiveBindings[action] = manager.shortcut(for: action)
            errors[action] = (error as? ShortcutError) ?? .registrationFailed(-1)
            return false
        }
    }
}
