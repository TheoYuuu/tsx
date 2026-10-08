import Foundation
import Observation

/// List checks own separate, disposable editors. They never save a draft or
/// change the selected provider, and never receive the user's translation text.
@MainActor @Observable
final class TranslationServiceChecksController {
    private(set) var editors: [UUID: TranslationServiceEditor] = [:]
    private var revisions: [UUID: UUID] = [:]
    @ObservationIgnored private let services: TranslationServiceStore
    @ObservationIgnored private let testProvider: ((TranslationServiceConfiguration) -> any TranslationProvider)?

    init(services: TranslationServiceStore,
         testProvider: ((TranslationServiceConfiguration) -> any TranslationProvider)? = nil) {
        self.services = services
        self.testProvider = testProvider
    }

    func editor(for id: UUID) -> TranslationServiceEditor? {
        guard let revision = services.configurationRevision(for: id), revisions[id] == revision else { return nil }
        return editors[id]
    }

    func toggle(_ configuration: TranslationServiceConfiguration) {
        guard let saved = services.configurations.first(where: { $0.id == configuration.id }),
              TranslationServiceStore.sameRequest(saved, configuration),
              services.configurationRevision(for: configuration.id) != nil else { return }
        if revisions[configuration.id] != services.configurationRevision(for: configuration.id) {
            cancel(configuration.id)
        }
        if let editor = editors[configuration.id], editor.testState == .running {
            editor.cancelTest()
            return
        }
        guard editors[configuration.id]?.testState != .stopping else { return }
        // Keep a single explicit sample request in flight from this list.
        guard !editors.values.contains(where: \.isTesting) else { return }
        editors[configuration.id]?.close()
        let editor = TranslationServiceEditor(configuration: saved, services: services)
        editors[configuration.id] = editor
        revisions[configuration.id] = services.configurationRevision(for: configuration.id)
        editor.test(using: testProvider?(saved))
    }

    func canStart(_ id: UUID) -> Bool {
        !editors.contains { $0.key != id && $0.value.isTesting }
    }

    func cancel(_ id: UUID) {
        editors.removeValue(forKey: id)?.close()
        revisions[id] = nil
    }

    func cancelAll() {
        for editor in editors.values { editor.close() }
        editors.removeAll()
        revisions.removeAll()
    }
}
