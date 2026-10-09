import Carbon
import Foundation

enum ShortcutError: Error, Equatable, LocalizedError {
    case invalidShortcut
    case reservedShortcut
    case alreadyInUse
    case registrationFailed(OSStatus)
    case unregistrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidShortcut:
            L10n.string("Add Option, Control or Command to a regular key.")
        case .reservedShortcut:
            L10n.string("This shortcut is reserved for editing or macOS. Choose another combination.")
        case .alreadyInUse:
            L10n.string("This shortcut is already in use. Choose another combination.")
        case .registrationFailed:
            L10n.string("This shortcut could not be registered. Try another combination.")
        case .unregistrationFailed:
            L10n.string("This shortcut could not be changed. The previous shortcut is still active.")
        }
    }
}

@MainActor
protocol HotKeyRegistering: AnyObject {
    var onHotKey: (@MainActor (UInt32) -> Void)? { get set }
    func register(_ shortcut: GlobalShortcut, id: UInt32) throws
    func unregister(id: UInt32) throws
}

/// Own one instance for the app lifetime. A failed replacement keeps its old binding.
@MainActor
final class ShortcutManager {
    private struct Registration {
        let shortcut: GlobalShortcut
        let id: UInt32
        let handler: @MainActor () -> Void
    }

    private let registrar: any HotKeyRegistering
    private var registrations: [ShortcutAction: Registration] = [:]
    private var pendingCleanup: Set<UInt32> = []
    private var nextID: UInt32 = 1
    private var recording: (id: UUID, receive: @MainActor (GlobalShortcut) -> Void)?

    convenience init() {
        self.init(registrar: CarbonHotKeyRegistrar())
    }

    init(registrar: any HotKeyRegistering) {
        self.registrar = registrar
        registrar.onHotKey = { [weak self] id in
            guard let self, let registration = self.registrations.values.first(where: { $0.id == id }) else { return }
            if let recording = self.recording {
                recording.receive(registration.shortcut)
            } else {
                registration.handler()
            }
        }
    }

    /// Registered Carbon hot keys do not arrive as ordinary local key-down
    /// events. Route those exact keys to the active recorder without releasing
    /// their reservations or listening to any other app's keyboard input.
    func beginRecording(receive: @escaping @MainActor (GlobalShortcut) -> Void) -> UUID {
        let id = UUID()
        recording = (id, receive)
        return id
    }

    func endRecording(_ id: UUID) {
        if recording?.id == id { recording = nil }
    }

    func shortcut(for action: ShortcutAction) -> GlobalShortcut? {
        registrations[action]?.shortcut
    }

    func register(
        _ shortcut: GlobalShortcut,
        for action: ShortcutAction,
        handler: @escaping @MainActor () -> Void
    ) throws {
        guard shortcut.isValid else { throw ShortcutError.invalidShortcut }
        guard !shortcut.isReserved else { throw ShortcutError.reservedShortcut }
        let previous = registrations[action]
        if let previous, previous.shortcut == shortcut {
            registrations[action] = Registration(shortcut: shortcut, id: previous.id, handler: handler)
            return
        }
        guard !registrations.contains(where: { $0.key != action && $0.value.shortcut == shortcut }) else {
            throw ShortcutError.alreadyInUse
        }
        guard nextID < UInt32.max else { throw ShortcutError.registrationFailed(OSStatus(paramErr)) }
        let id = nextID
        nextID += 1

        // Reserve the new combination first, so a system conflict never loses the old one.
        try registrar.register(shortcut, id: id)
        if let previous {
            do {
                try registrar.unregister(id: previous.id)
            } catch {
                do {
                    try registrar.unregister(id: id)
                } catch {
                    pendingCleanup.insert(id)
                }
                throw error
            }
        }
        registrations[action] = Registration(shortcut: shortcut, id: id, handler: handler)
    }

    func unregister(for action: ShortcutAction) throws {
        guard let registration = registrations[action] else { return }
        try registrar.unregister(id: registration.id)
        registrations[action] = nil
    }

    /// Reuses existing key reservations when actions swap combinations. Newly
    /// needed keys are reserved before any obsolete reservation is removed.
    func replaceBindings(_ desired: [ShortcutAction: GlobalShortcut],
                         handler: @escaping @MainActor (ShortcutAction) -> Void) throws {
        guard Set(desired.values).count == desired.count else { throw ShortcutError.alreadyInUse }
        for shortcut in desired.values {
            guard shortcut.isValid else { throw ShortcutError.invalidShortcut }
            guard !shortcut.isReserved else { throw ShortcutError.reservedShortcut }
        }
        let original = registrations
        var reserved: [GlobalShortcut: UInt32] = [:]
        var added: [UInt32] = []
        var removed: [(ShortcutAction, Registration)] = []
        do {
            for shortcut in desired.values {
                if let existing = original.values.first(where: { $0.shortcut == shortcut }) {
                    reserved[shortcut] = existing.id
                } else {
                    guard nextID < UInt32.max else { throw ShortcutError.registrationFailed(OSStatus(paramErr)) }
                    let id = nextID; nextID += 1
                    try registrar.register(shortcut, id: id)
                    reserved[shortcut] = id; added.append(id)
                }
            }
            for (action, registration) in original where !desired.values.contains(registration.shortcut) {
                try registrar.unregister(id: registration.id)
                removed.append((action, registration))
            }
        } catch {
            for id in added {
                do { try registrar.unregister(id: id) }
                catch { pendingCleanup.insert(id) }
            }
            // Keep actual registration state truthful if macOS also rejects
            // restoring a removed key. Preferences are never committed here.
            for (action, registration) in removed {
                do { try registrar.register(registration.shortcut, id: registration.id) }
                catch { registrations[action] = nil }
            }
            throw error
        }
        registrations = Dictionary(uniqueKeysWithValues: desired.map { action, shortcut in
            (action, Registration(shortcut: shortcut, id: reserved[shortcut]!, handler: { handler(action) }))
        })
    }

    /// Attempts every binding even when one removal fails. Failed bindings stay represented.
    func unregisterAll() throws {
        recording = nil
        var firstError: (any Error)?
        for id in pendingCleanup {
            do {
                try registrar.unregister(id: id)
                pendingCleanup.remove(id)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        for action in Array(registrations.keys) {
            do {
                try unregister(for: action)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}

@MainActor
private final class CarbonHotKeyRegistrar: HotKeyRegistering {
    var onHotKey: (@MainActor (UInt32) -> Void)?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private static var nextSignature: OSType = 0x4C554D58 // LUMX
    nonisolated private let signature: OSType

    init() {
        signature = Self.nextSignature
        Self.nextSignature &+= 1
    }

    func register(_ shortcut: GlobalShortcut, id: UInt32) throws {
        try installEventHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: signature, id: id),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference
        )
        guard status == noErr, let reference else {
            if status == eventHotKeyExistsErr { throw ShortcutError.alreadyInUse }
            throw ShortcutError.registrationFailed(status)
        }
        references[id] = reference
    }

    func unregister(id: UInt32) throws {
        guard let reference = references[id] else { return }
        let status = UnregisterEventHotKey(reference)
        guard status == noErr else { throw ShortcutError.unregistrationFailed(status) }
        references[id] = nil
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard result == noErr else {
                    return OSStatus(eventNotHandledErr)
                }
                // Application-target Carbon events are delivered on the main event loop.
                // Route synchronously so a recorded key cannot become an app
                // action after a recorder has ended in the next event-loop turn.
                let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue()
                guard identifier.signature == registrar.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let id = identifier.id
                MainActor.assumeIsolated {
                    registrar.onHotKey?(id)
                }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        guard status == noErr else { throw ShortcutError.registrationFailed(status) }
    }

    isolated deinit {
        for reference in references.values { UnregisterEventHotKey(reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
