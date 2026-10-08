import Observation

/// One settings-window owner routes tab and window exits through the live draft.
/// The view presents confirmation; AppKit still owns the actual window action.
@MainActor @Observable
final class TranslationServiceNavigationCoordinator {
    var isPresentingConfirmation = false
    private(set) var servicesRequestID = 0
    @ObservationIgnored var exitHandler: ((@escaping @MainActor () -> Void) -> Void)?

    /// Opening the service tab does not discard an editor already open there.
    func showServices() { servicesRequestID &+= 1 }

    func requestExit(perform action: @escaping @MainActor () -> Void) {
        if let exitHandler { exitHandler(action) }
        else { action() }
    }
}
