import ApplicationServices
import Carbon.HIToolbox
import Foundation
import OSLog

/// A complete Copy chord. Construction is separate from posting so tests can
/// verify its terminal modifier state without sending input to any application.
struct SelectionCopyEvents {
    private let source: CGEventSource
    let keyDown: CGEvent
    let keyUp: CGEvent

    init() throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else {
            throw SelectionError.copyUnavailable
        }
        self.source = source
        keyDown = down
        keyUp = up
        down.flags = .maskCommand
        // We synthesize Command only for Copy; the final event must not leave it
        // held in session state. The real shortcut-release guard stays in place.
        up.flags = []
    }

    func post(to processID: pid_t) {
        // Never redirect to whichever process happens to be frontmost now.
        keyDown.postToPid(processID)
        keyUp.postToPid(processID)
    }
}

/// AX calls are synchronous IPC. Keep them off the main actor, with both a per-call
/// timeout and a deadline between calls. No AX objects cross the actor boundary.
actor AXSelectionReader {
    private let logger = Logger(subsystem: "com.lumax.tsx", category: "Selection")
    enum Result: Sendable {
        case text(String, bounds: CGRect?)
        case copyCandidate(UUID)
    }

    private struct Candidate {
        let id: UUID
        let processID: pid_t
        let element: AXUIElement
    }

    private var candidate: Candidate?
    private let clock = ContinuousClock()
    private let messagingTimeout: Float = 0.15

    func selection(processID: pid_t) throws -> Result {
        candidate = nil
        let deadline = clock.now.advanced(by: .milliseconds(900))
        let element = try focusedElement(processID: processID, deadline: deadline)
        try verifyNonSecure(element, deadline: deadline)

        let selected = try attribute(element, kAXSelectedTextAttribute, deadline: deadline) as? String
        if let selected, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let range = selectionRange(try? attribute(element, kAXSelectedTextRangeAttribute, deadline: deadline))
            return .text(try SelectionText.validated(selected), bounds: try bounds(element, range: range, deadline: deadline))
        }
        let range = selectionRange(try attribute(element, kAXSelectedTextRangeAttribute, deadline: deadline))
        // An explicitly empty selection must not trigger apps' "copy current line" behavior.
        if range?.length == 0 || (selected != nil && range == nil) { throw SelectionError.noSelection }

        if let range, range.length > 0 {
            var mutableRange = range
            if let parameter = AXValueCreate(.cfRange, &mutableRange),
               let selected = try parameterizedAttribute(
                   element, kAXStringForRangeParameterizedAttribute, parameter: parameter, deadline: deadline
               ) as? String {
                return .text(try SelectionText.validated(selected), bounds: try bounds(element, range: range, deadline: deadline))
            }
        }

        // Unsupported selected-text attributes are common in browser/PDF content.
        // Only a known, non-secure focused element qualifies for the controlled fallback.
        let id = UUID()
        candidate = Candidate(id: id, processID: processID, element: element)
        return .copyCandidate(id)
    }

    func copy(
        processID: pid_t, candidateID: UUID,
        beforePosting: @MainActor @Sendable () async throws -> Void
    ) async throws {
        defer { candidate = nil }
        guard let candidate, candidate.id == candidateID, candidate.processID == processID else {
            throw SelectionError.sourceChanged
        }
        let deadline = clock.now.advanced(by: .milliseconds(600))
        let currentElement = try focusedElement(processID: processID, deadline: deadline)
        guard CFEqual(currentElement, candidate.element) else { throw SelectionError.sourceChanged }
        try verifyNonSecure(currentElement, deadline: deadline)
        try check(deadline)
        guard !IsSecureEventInputEnabled() else { throw SelectionError.secureInput }
        try await beforePosting()
        try check(deadline)
        let events = try SelectionCopyEvents()
        events.post(to: processID)
    }

    private func focusedElement(processID: pid_t, deadline: ContinuousClock.Instant) throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        guard let focusedApp = element(try attribute(system, kAXFocusedApplicationAttribute, deadline: deadline)) else {
            throw SelectionError.sourceUnavailable
        }
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(focusedApp, &actualPID) == .success, actualPID == processID else {
            throw SelectionError.sourceChanged
        }
        guard let focused = element(try attribute(focusedApp, kAXFocusedUIElementAttribute, deadline: deadline)) else {
            throw SelectionError.sourceUnavailable
        }
        return focused
    }

    private func verifyNonSecure(_ element: AXUIElement, deadline: ContinuousClock.Instant) throws {
        guard !IsSecureEventInputEnabled() else { throw SelectionError.secureInput }
        guard let role = try attribute(element, kAXRoleAttribute, deadline: deadline) as? String, !role.isEmpty else {
            throw SelectionError.sourceUnavailable
        }
        let subrole = try attribute(element, kAXSubroleAttribute, deadline: deadline) as? String
        guard role != "AXSecureTextField", subrole != "AXSecureTextField" else {
            throw SelectionError.secureInput
        }
        // Web accessibility implementations may report the secure field as an ancestor.
        var parent = self.element(try attribute(element, kAXParentAttribute, deadline: deadline))
        for _ in 0..<3 {
            guard let current = parent else { break }
            let parentRole = try attribute(current, kAXRoleAttribute, deadline: deadline) as? String
            let parentSubrole = try attribute(current, kAXSubroleAttribute, deadline: deadline) as? String
            guard parentRole != "AXSecureTextField", parentSubrole != "AXSecureTextField" else {
                throw SelectionError.secureInput
            }
            parent = self.element(try attribute(current, kAXParentAttribute, deadline: deadline))
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String, deadline: ContinuousClock.Instant) throws -> CFTypeRef? {
        try check(deadline)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return try checkedValue(value, error: error, attribute: name)
    }

    private func parameterizedAttribute(
        _ element: AXUIElement, _ name: String, parameter: CFTypeRef, deadline: ContinuousClock.Instant
    ) throws -> CFTypeRef? {
        try check(deadline)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value)
        return try checkedValue(value, error: error, attribute: name)
    }

    private func checkedValue(_ value: CFTypeRef?, error: AXError, attribute: String) throws -> CFTypeRef? {
        // Attribute names here are API constants, never selection/app/element values.
        switch error {
        case .success, .attributeUnsupported, .parameterizedAttributeUnsupported, .noValue, .notImplemented: break
        default: logger.notice("AX request stopped: attribute=\(attribute, privacy: .public) code=\(error.rawValue, privacy: .public)")
        }
        switch error {
        case .success: return value
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .noValue, .notImplemented: return nil
        case .apiDisabled: throw SelectionError.accessibilityPermissionRequired
        case .cannotComplete: throw SelectionError.sourceUnresponsive
        default: throw SelectionError.sourceUnavailable
        }
    }

    private func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw SelectionError.sourceUnresponsive }
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func selectionRange(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    private func bounds(_ element: AXUIElement, range: CFRange?, deadline: ContinuousClock.Instant) throws -> CGRect? {
        guard var range, let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        // Position is optional; unsupported or slow geometry must not discard valid text.
        guard let value = try? parameterizedAttribute(
            element, kAXBoundsForRangeParameterizedAttribute, parameter: parameter, deadline: deadline
        ), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite, !rect.isEmpty else { return nil }
        return rect
    }
}
