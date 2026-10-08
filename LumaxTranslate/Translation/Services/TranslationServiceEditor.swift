import Foundation
import Observation

/// A single provider draft. Secrets and sample output exist only in memory;
/// a new receiver or credential invalidates the old directory synchronously.
@MainActor @Observable
final class TranslationServiceEditor {
    enum Field: Hashable { case name, key, endpoint, website, model, region, instructions, outputLimit }
    enum KeyState: Equatable { case unconfirmed, stored, missing, unavailable, addressChanged }
    enum CatalogState: Equatable { case idle, loading, loaded, empty, failed }
    enum TestState: Equatable { case idle, running, stopping, stopped, succeeded, failed }

    static let testSample = "A clear sentence is easy to understand."
    var configuration: TranslationServiceConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            var previousRequest = oldValue
            previousRequest.automaticallyTranslates = configuration.automaticallyTranslates
            previousRequest.name = configuration.name
            previousRequest.website = configuration.website
            guard previousRequest != configuration else {
                clearChangedFieldErrors(from: oldValue)
                saveFailure = nil
                return
            }
            if configuration.endpoint != oldValue.endpoint || configuration.kind != oldValue.kind {
                hideKey()
                replacementKey = ""
                removeSavedKey = false
                invalidateCatalog()
            }
            clearChangedFieldErrors(from: oldValue)
            invalidateTest()
            saveFailure = nil
        }
    }
    var replacementKey = "" {
        didSet {
            guard replacementKey != oldValue else { return }
            revealedSavedKey = nil
            keyFailure = nil
            fieldFailures[.key] = nil
            saveFailure = nil
            invalidateTest()
            invalidateCatalog()
        }
    }
    var removeSavedKey = false {
        didSet {
            guard removeSavedKey != oldValue else { return }
            hideKey()
            if removeSavedKey { replacementKey = "" }
            fieldFailures[.key] = nil
            invalidateTest()
            invalidateCatalog()
        }
    }
    // Compatibility for existing callers. Saving never changes the selection.
    var makeDefault = false
    private(set) var isNew: Bool
    let originalName: String
    private(set) var isTesting = false
    private(set) var testState: TestState = .idle
    private(set) var testResult = ""
    private(set) var testDuration: TimeInterval?
    private var failureMessage: Message?
    var errorMessage: String? { failureMessage?.text }
    private var fieldFailures: [Field: TranslationServiceConfigurationError] = [:]
    var fieldErrors: [Field: String] { fieldFailures.mapValues { $0.localizedDescription } }
    private var saveFailure: Message?
    var saveErrorMessage: String? { saveFailure?.text }
    private(set) var catalogState: CatalogState = .idle
    private var modelFailure: Message?
    var modelErrorMessage: String? { modelFailure?.text }
    private(set) var isKeyVisible = false
    private var keyFailure: Message?
    var keyErrorMessage: String? { keyFailure?.text }
    private(set) var ownsCodexOperation = false
    private var storedKeyState: KeyState = .unconfirmed
    private var apiModels: [TranslationServiceModel] = []
    @ObservationIgnored private let services: TranslationServiceStore
    @ObservationIgnored private let modelLoader: any TranslationServiceModelLoading
    @ObservationIgnored private let keyVisibilityDuration: Duration
    private var baseline: TranslationServiceConfiguration
    @ObservationIgnored private var revealedSavedKey: String?
    @ObservationIgnored private var keyVisibilityTask: Task<Void, Never>?
    @ObservationIgnored private var keyVisibilityID = UUID()
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored private var testStopTask: Task<Void, Never>?
    @ObservationIgnored private var drainID = UUID()
    @ObservationIgnored private var drainFinalState: TestState = .idle
    @ObservationIgnored private var testID = UUID()
    @ObservationIgnored private var completedSampleTest: CompletedSampleTest?
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    @ObservationIgnored private var modelID = UUID()
    @ObservationIgnored private var codexTask: Task<Void, Never>?
    @ObservationIgnored private var codexTaskID = UUID()
    @ObservationIgnored private let codexOwner = UUID()
    @ObservationIgnored private var didOpenCodex = false
    @ObservationIgnored private var closed = false

    private struct CompletedSampleTest {
        let outcome: TranslationServiceStore.SampleTestOutcome
        let completedAt: Date
        let configurationRevision: UUID?
        let usesReplacementKey: Bool
        let duration: TimeInterval?
    }

    init(
        configuration: TranslationServiceConfiguration,
        services: TranslationServiceStore,
        modelLoader: any TranslationServiceModelLoading = TranslationServiceModelCatalog(),
        keyVisibilityDuration: Duration = .seconds(30)
    ) {
        self.configuration = configuration
        self.baseline = configuration
        self.originalName = configuration.name
        self.services = services
        self.modelLoader = modelLoader
        self.keyVisibilityDuration = keyVisibilityDuration
        self.isNew = !services.configurations.contains(where: { $0.id == configuration.id })
        if isNew || configuration.kind == .codex { storedKeyState = .missing }
        trackAutomaticPreference()
    }

    deinit {
        testTask?.cancel()
        testStopTask?.cancel()
        modelTask?.cancel()
        codexTask?.cancel()
        keyVisibilityTask?.cancel()
    }

    var isDirty: Bool { configuration != baseline || !replacementKey.isEmpty || removeSavedKey }

    private func trackAutomaticPreference() {
        withObservationTracking {
            _ = services.automaticTranslationRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.synchronizeAutomaticPreference()
                self.trackAutomaticPreference()
            }
        }
    }

    /// Adopt a footer preference without discarding unrelated draft fields or
    /// an explicit, unsaved setting. Scheduling is not part of the test payload.
    private func synchronizeAutomaticPreference() {
        guard !isNew, let saved = services.configurations.first(where: { $0.id == configuration.id }),
              saved.automaticallyTranslates != baseline.automaticallyTranslates else { return }
        if configuration.automaticallyTranslates == baseline.automaticallyTranslates {
            configuration.automaticallyTranslates = saved.automaticallyTranslates
        }
        baseline.automaticallyTranslates = saved.automaticallyTranslates
    }
    var hasUnsavedChanges: Bool { isDirty }
    var canSave: Bool {
        !closed && !isTesting && (isNew || isDirty)
            && (configuration.kind != .codex || canSaveCodex)
    }
    var canTest: Bool {
        !closed && !isTesting && canConfigureModel && (try? configuration.validated()) != nil
            && (configuration.kind != .codex || canSaveCodex)
    }
    var receiver: String {
        URL(string: configuration.endpoint)?.host ?? L10n.string("the configured service")
    }
    var keyState: KeyState {
        if removeSavedKey { return .missing }
        if !isNew && (configuration.kind != baseline.kind
            || (try? configuration.validatedEndpoint()) != (try? baseline.validatedEndpoint())) {
            return .addressChanged
        }
        return storedKeyState
    }
    /// The UI binds its SecureField/TextField here, never to the stored secret.
    /// A user edit while revealing deliberately becomes a replacement draft.
    var keyFieldText: String {
        get { isKeyVisible ? (revealedSavedKey ?? replacementKey) : replacementKey }
        set { replacementKey = newValue }
    }
    var models: [TranslationServiceModel] {
        if configuration.kind == .codex {
            guard codex.modelsGeneration == codex.generation, codex.generation != nil else { return [] }
            return codex.models.map { .init(id: $0.id, name: $0.name) }
        }
        return apiModels
    }
    var codex: CodexAccountController { services.codex }
    /// Readiness uses draft/Keychain metadata only. It never reveals a saved key
    /// or treats a fetched directory as proof that translation will succeed.
    var modelSetupHint: String? {
        guard configuration.kind != .codex else { return nil }
        guard (try? configuration.validatedEndpoint()) != nil else {
            return L10n.string("Enter a valid API URL before choosing a model.")
        }
        if configuration.kind.requiresAPIKey,
           replacementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           ![KeyState.stored, .unconfirmed, .unavailable].contains(keyState) {
            return L10n.string("Add an API key first, then get models or enter a model ID.")
        }
        return nil
    }
    var canConfigureModel: Bool { !closed && modelSetupHint == nil }
    var codexModelSelectionIsValid: Bool {
        configuration.kind == .codex && codex.canUseModel(
            id: configuration.model, generation: configuration.codexAccountGeneration)
    }
    var canSaveCodex: Bool {
        codexModelSelectionIsValid && !codex.isBusy && !ownsCodexOperation
    }

    /// Called when the editor is shown. The metadata query never fetches a key.
    func refreshKeyState() {
        guard !closed, !isNew, configuration.kind != .codex else { return }
        do {
            switch try services.storedKeyPresence(for: configuration) {
            case true?: storedKeyState = .stored
            case false?: storedKeyState = .missing
            case nil: storedKeyState = .unconfirmed
            }
            keyFailure = nil
        } catch TranslationServiceConfigurationError.endpointChanged {
            // The computed addressChanged state explains this without reading.
        } catch {
            storedKeyState = .unavailable
            keyFailure = Message(safeError: error)
        }
    }

    func toggleKeyVisibility() {
        guard !closed, configuration.kind != .codex else { return }
        if isKeyVisible { hideKey(); return }
        keyFailure = nil
        do {
            if replacementKey.isEmpty {
                guard !removeSavedKey else { return }
                guard let key = try services.savedKeyForReveal(for: configuration) else {
                    storedKeyState = .missing
                    return
                }
                revealedSavedKey = key
                storedKeyState = .stored
            }
            isKeyVisible = true
            let id = UUID(), duration = keyVisibilityDuration
            keyVisibilityID = id
            keyVisibilityTask?.cancel()
            keyVisibilityTask = Task { [weak self] in
                do { try await Task.sleep(for: duration) }
                catch { return }
                guard let self, self.keyVisibilityID == id, !Task.isCancelled else { return }
                self.hideKey()
            }
        } catch {
            hideKey()
            if keyState != .addressChanged { storedKeyState = .unavailable }
            keyFailure = Message(safeError: error)
        }
    }

    func hideKey() {
        keyVisibilityID = UUID()
        keyVisibilityTask?.cancel()
        keyVisibilityTask = nil
        isKeyVisible = false
        revealedSavedKey = nil
    }

    func fetchModels() {
        guard !closed else { return }
        if configuration.kind == .codex { refreshCodexModels(); return }
        invalidateCatalog()
        do {
            guard TranslationServiceModelCatalog.supports(configuration.kind) else {
                throw TranslationServiceModelCatalogError.unsupportedService
            }
            var snapshot = configuration
            snapshot.endpoint = try configuration.validatedEndpoint().absoluteString
            let key = try services.apiKeyForModelCatalog(for: snapshot, replacement: keyReplacement)
            let id = modelID, loader = modelLoader
            catalogState = .loading
            modelTask = Task { [weak self] in
                do {
                    try Task.checkCancellation()
                    let result = try await loader.models(configuration: snapshot, apiKey: key)
                    guard let self, self.modelID == id, !Task.isCancelled else { return }
                    self.apiModels = result
                    self.catalogState = result.isEmpty ? .empty : .loaded
                    self.modelTask = nil
                } catch {
                    guard let self, self.modelID == id, !Task.isCancelled else { return }
                    self.apiModels = []
                    self.catalogState = .failed
                    self.modelFailure = Message(safeError: error)
                    self.modelTask = nil
                }
            }
        } catch {
            catalogState = .failed
            modelFailure = Message(safeError: error)
            recordFieldError(error)
        }
    }

    func cancelModelLoading() {
        invalidateCatalog()
        if configuration.kind == .codex { cancelCodexOperation() }
    }

    func chooseModel(_ id: String) {
        if configuration.kind == .codex { chooseCodexModel(id); return }
        guard !closed, apiModels.contains(where: { $0.id == id }) else { return }
        configuration.model = id
    }

    func openCodex() {
        guard !closed, configuration.kind == .codex, !didOpenCodex else { return }
        didOpenCodex = true
        refreshCodexStatus()
    }
    func refreshCodexStatus() { startCodexOperation(.status) }
    func signInCodex() { startCodexOperation(.login) }
    func refreshCodexModels() { startCodexOperation(.models) }
    func chooseCodexModel(_ id: String) {
        guard !closed, configuration.kind == .codex, !codex.isBusy, !ownsCodexOperation,
              let generation = codex.generation,
              codex.canUseModel(id: id, generation: generation) else { return }
        var updated = configuration
        updated.model = id
        updated.codexAccountGeneration = generation
        configuration = updated
    }
    func codexIdentityChanged() {
        guard configuration.kind == .codex else { return }
        invalidateTest()
        if codex.modelsGeneration != codex.generation { invalidateCatalog() }
    }
    func cancelCodexOperation() {
        guard configuration.kind == .codex, ownsCodexOperation else { return }
        codexTask?.cancel()
        let controller = codex, owner = codexOwner
        Task { await controller.cancelOperations(owner: owner) }
    }
    func signOutCodex() {
        guard !closed, configuration.kind == .codex else { return }
        invalidateTest()
        invalidateCatalog()
        let controller = codex
        // Explicit logout is shared-account work, independent of editor closure.
        Task { await controller.logout() }
    }
    private func startCodexOperation(_ operation: CodexRuntimeSession.Operation) {
        guard !closed, configuration.kind == .codex, !codex.isBusy, !ownsCodexOperation else { return }
        invalidateTest()
        if operation == .models { invalidateCatalog(); catalogState = .loading }
        let controller = codex, owner = codexOwner, taskID = UUID()
        codexTaskID = taskID
        ownsCodexOperation = true
        codexTask = Task { [weak self] in
            defer {
                if let self, self.codexTaskID == taskID {
                    self.ownsCodexOperation = false
                    self.codexTask = nil
                }
            }
            guard !Task.isCancelled else { return }
            switch operation {
            case .status: await controller.refreshStatus(owner: owner)
            case .login: await controller.login(owner: owner)
            case .models: await controller.loadModels(owner: owner)
            default: break
            }
            guard let self, self.codexTaskID == taskID, !Task.isCancelled else { return }
            if operation == .models {
                if let error = controller.error {
                    self.catalogState = .failed
                    self.modelFailure = Message(safeError: error)
                } else { self.catalogState = self.models.isEmpty ? .empty : .loaded }
            }
        }
    }

    func useDeepLEndpoint(_ endpoint: DeepLAPIEndpoint) {
        guard configuration.kind == .deepL, configuration.endpoint != endpoint.rawValue else { return }
        configuration.endpoint = endpoint.rawValue
    }
    func useQwenMTEndpoint(_ endpoint: QwenMTEndpoint) {
        guard configuration.kind == .qwenMT, configuration.endpoint != endpoint.rawValue else { return }
        configuration.endpoint = endpoint.rawValue
    }
    func useTencentEndpoint(_ endpoint: TencentTranslationEndpoint) {
        guard configuration.kind == .tencentTranslation, configuration.endpoint != endpoint.rawValue else { return }
        configuration.endpoint = endpoint.rawValue
    }

    func save() -> Bool {
        guard !closed, !isTesting else { return false }
        synchronizeAutomaticPreference()
        let tested = completedSampleTest.flatMap { test in
            test.usesReplacementKey || test.configurationRevision == services.configurationRevision(for: configuration.id)
                ? test : nil
        }
        invalidateTest()
        hideKey()
        fieldFailures = [:]
        saveFailure = nil
        do {
            try validateEditorIdentity()
            if configuration.kind == .codex, !canSaveCodex {
                throw TranslationServiceConfigurationError.codexLoginRequired
            }
            try services.save(configuration, apiKey: keyReplacement)
            if let saved = services.configurations.first(where: { $0.id == configuration.id }) {
                configuration = saved
                baseline = saved
                if let tested {
                    services.recordSampleTest(tested.outcome, for: saved, revision: services.configurationRevision(for: saved.id), completedAt: tested.completedAt, duration: tested.duration)
                }
            }
            isNew = false
            replacementKey = ""
            removeSavedKey = false
            refreshKeyState()
            return true
        } catch {
            failureMessage = Message(safeError: error)
            recordFieldError(error)
            if fieldFailures.isEmpty { saveFailure = failureMessage }
            return false
        }
    }

    func test(using injectedProvider: (any TranslationProvider)? = nil) {
        guard !closed, !isTesting else { return }
        invalidateTest()
        fieldFailures = [:]
        do {
            try validateEditorIdentity()
            if configuration.kind == .codex {
                guard !codex.isBusy, !ownsCodexOperation else { throw CodexAccountError.busy }
                // A saved request already has an explicit model and account
                // generation. Its provider validates that generation with the
                // helper; reopening the app need not first load a model list.
                let isSavedRequest = services.configurations.contains {
                    $0.id == configuration.id && TranslationServiceStore.sameRequest($0, configuration)
                }
                if !isSavedRequest, !canSaveCodex { throw TranslationServiceConfigurationError.codexLoginRequired }
            }
            let snapshot = try configuration.validated()
            let key = try services.apiKey(for: snapshot, replacement: keyReplacement)
            let configurationRevision = services.configurationRevision(for: snapshot.id)
            let usesReplacementKey = keyReplacement != nil
            let id = testID
            let request = TranslationRequest(id: id, text: Self.testSample, source: "en", target: "zh-Hans")
            let provider = injectedProvider ?? TranslationProviderFactory.make(configuration: snapshot, apiKey: key, codex: services.codex) { [weak self] text in
                guard let self, self.testID == id, self.isTesting else { return }
                self.testResult = text
            }
            let measuresSavedConfiguration = !usesReplacementKey && services.configurations.contains {
                $0.id == snapshot.id && TranslationServiceStore.sameRequest($0, snapshot)
            }
            let measuredProvider: any TranslationProvider = measuresSavedConfiguration
                ? UsageRecordingTranslationProvider(base: provider, store: services.usage,
                    configurationID: snapshot.id, model: snapshot.model, purpose: .sampleTest) : provider
            let sampleAccount = snapshot.kind == .codex ? codex : nil
            isTesting = true
            testState = .running
            testTask = Task { [weak self] in
                let start = Date()
                var startedProvider = false
                do {
                    try Task.checkCancellation()
                    // Another entry point may have acquired the shared account
                    // slot since the click. A sample must never supersede it.
                    if sampleAccount?.isBusy == true { throw CodexAccountError.busy }
                    startedProvider = true
                    let result = try await measuredProvider.translate(request)
                    guard let self, self.testID == id, !Task.isCancelled else { return }
                    self.testResult = result.text
                    self.testDuration = Date().timeIntervalSince(start)
                    self.isTesting = false
                    self.testState = .succeeded
                    self.recordCompletedTest(.succeeded, configuration: snapshot,
                                             revision: configurationRevision, usesReplacementKey: usesReplacementKey)
                    self.testTask = nil
                } catch {
                    guard let self, self.testID == id, !Task.isCancelled else { return }
                    self.testResult = ""
                    self.failureMessage = Message(safeError: error)
                    self.testDuration = Date().timeIntervalSince(start)
                    self.isTesting = false
                    self.testState = .failed
                    if startedProvider {
                        self.recordCompletedTest(.failed, configuration: snapshot,
                                                 revision: configurationRevision, usesReplacementKey: usesReplacementKey)
                    }
                    self.testTask = nil
                }
            }
        } catch {
            failureMessage = Message(safeError: error)
            testState = .failed
            recordFieldError(error)
        }
    }

    private func recordCompletedTest(_ outcome: TranslationServiceStore.SampleTestOutcome,
                                     configuration: TranslationServiceConfiguration, revision: UUID?,
                                     usesReplacementKey: Bool) {
        let completedAt = Date()
        completedSampleTest = .init(outcome: outcome, completedAt: completedAt, configurationRevision: revision, usesReplacementKey: usesReplacementKey, duration: testDuration)
        // A tested key draft cannot certify the credential still in Keychain.
        // Store equality also prevents an unsaved model/address from marking it.
        if !usesReplacementKey {
            services.recordSampleTest(outcome, for: configuration, revision: revision, completedAt: completedAt, duration: testDuration)
        }
    }

    func cancelTest() {
        guard let task = testTask else { return }
        testID = UUID()
        testTask = nil
        testResult = ""
        testDuration = nil
        failureMessage = .key("Test cancelled")
        beginDraining(task, finalState: .stopped)
    }

    private func beginDraining(_ task: Task<Void, Never>, finalState: TestState) {
        task.cancel()
        drainID = UUID()
        let id = drainID
        drainFinalState = finalState
        isTesting = true
        testState = .stopping
        testStopTask = Task { [weak self] in
            await task.value
            guard let self, self.drainID == id, !Task.isCancelled else { return }
            self.isTesting = false
            self.testState = self.closed ? .idle : self.drainFinalState
            self.testStopTask = nil
        }
    }

    /// A provider switch or temporary screenshot obscuring cancels only this
    /// editor's work, hides loaded plaintext, and retains all unsaved fields.
    func suspend() {
        invalidateTest()
        invalidateCatalog()
        hideKey()
        codexTaskID = UUID()
        codexTask?.cancel()
        codexTask = nil
        ownsCodexOperation = false
        if configuration.kind == .codex {
            let controller = codex, owner = codexOwner
            Task { await controller.cancelOperations(owner: owner) }
        }
    }
    func close() {
        suspend()
        replacementKey = ""
        removeSavedKey = false
        closed = true
        isTesting = false
        testState = .idle
    }
    private func validateEditorIdentity() throws {
        guard configuration.id == baseline.id, configuration.kind == baseline.kind else {
            throw TranslationServiceConfigurationError.unknownService
        }
    }
    private func invalidateTest() {
        completedSampleTest = nil
        testID = UUID()
        let task = testTask
        testTask = nil
        if let task {
            beginDraining(task, finalState: .idle)
        } else if testStopTask != nil {
            // Editing while Stop is draining cannot release the old request's
            // slot. Its completion still owns the transition back to idle.
            drainFinalState = .idle
            isTesting = !closed
            testState = closed ? .idle : .stopping
        } else {
            isTesting = false
            testState = .idle
        }
        testResult = ""
        testDuration = nil
        failureMessage = nil
    }
    private func invalidateCatalog() {
        modelID = UUID()
        modelTask?.cancel()
        modelTask = nil
        apiModels = []
        catalogState = .idle
        modelFailure = nil
    }
    private var keyReplacement: String? { removeSavedKey ? "" : replacementKey.isEmpty ? nil : replacementKey }
    private func clearChangedFieldErrors(from old: TranslationServiceConfiguration) {
        if configuration.name != old.name { fieldFailures[.name] = nil }
        if configuration.website != old.website { fieldFailures[.website] = nil }
        if configuration.model != old.model { fieldFailures[.model] = nil }
        if configuration.endpoint != old.endpoint { fieldFailures[.endpoint] = nil; fieldFailures[.key] = nil }
        if configuration.region != old.region { fieldFailures[.region] = nil }
        if configuration.additionalInstructions != old.additionalInstructions { fieldFailures[.instructions] = nil }
        if configuration.maximumOutputTokens != old.maximumOutputTokens { fieldFailures[.outputLimit] = nil }
    }
    private func recordFieldError(_ error: any Error) {
        guard let error = error as? TranslationServiceConfigurationError else { return }
        let field: Field
        switch error {
        case .invalidName: field = .name
        case .invalidModel, .unsupportedQwenMTModel, .unsupportedTencentModel, .codexLoginRequired: field = .model
        case .invalidEndpoint, .insecureEndpoint: field = .endpoint
        case .invalidWebsite: field = .website
        case .missingAPIKey, .invalidAPIKey, .endpointChanged, .credentialUnavailable: field = .key
        case .invalidRegion: field = .region
        case .instructionsTooLong: field = .instructions
        case .invalidOutputTokenLimit: field = .outputLimit
        case .unknownService, .storageUnavailable: return
        }
        fieldFailures[field] = error
    }
    static func safeMessage(for error: any Error) -> String {
        Message(safeError: error).text
    }

    /// Keep only recognized error types or fixed app keys. Displaying a different
    /// interface language must not retry a request or retain provider error text.
    private enum Message {
        case configuration(TranslationServiceConfigurationError)
        case remote(RemoteTranslationError)
        case catalog(TranslationServiceModelCatalogError)
        case account(CodexAccountError)
        case key(String)

        init(safeError error: any Error) {
            switch error {
            case let error as TranslationServiceConfigurationError: self = .configuration(error)
            case let error as RemoteTranslationError: self = .remote(error)
            case let error as TranslationServiceModelCatalogError: self = .catalog(error)
            case let error as CodexAccountError: self = .account(error)
            default: self = .key("Couldn’t update translation services. Please try again.")
            }
        }

        var text: String {
            switch self {
            case .configuration(let error): error.localizedDescription
            case .remote(let error): error.localizedDescription
            case .catalog(let error): error.localizedDescription
            case .account(let error): error.localizedDescription
            case .key(let key): L10n.string(key)
            }
        }
    }
}

/// A new-service flow owns one independent UUID and draft per provider. No key,
/// loaded directory or editor-owned operation crosses provider identities.
@MainActor @Observable
final class TranslationServiceDraftSession {
    private(set) var editor: TranslationServiceEditor
    private var drafts: [TranslationServiceKind: TranslationServiceEditor]
    @ObservationIgnored private let services: TranslationServiceStore
    @ObservationIgnored private let modelLoader: any TranslationServiceModelLoading

    init(
        services: TranslationServiceStore,
        configuration: TranslationServiceConfiguration? = nil,
        modelLoader: any TranslationServiceModelLoading = TranslationServiceModelCatalog()
    ) {
        self.services = services
        self.modelLoader = modelLoader
        let configuration = configuration ?? Self.newConfiguration(.openAI)
        let editor = TranslationServiceEditor(configuration: configuration, services: services, modelLoader: modelLoader)
        self.editor = editor
        self.drafts = [configuration.kind: editor]
    }
    var hasUnsavedChanges: Bool { drafts.values.contains(where: \.isDirty) }
    func selectKind(_ kind: TranslationServiceKind) {
        guard editor.isNew, kind != editor.configuration.kind else { return }
        editor.suspend()
        if let previous = drafts[kind] { editor = previous }
        else {
            let draft = TranslationServiceEditor(configuration: Self.newConfiguration(kind), services: services, modelLoader: modelLoader)
            drafts[kind] = draft
            editor = draft
        }
    }
    func add(_ kind: TranslationServiceKind = .openAI) { replace(with: Self.newConfiguration(kind)) }
    func edit(_ configuration: TranslationServiceConfiguration) { replace(with: configuration) }
    func suspend() { for draft in drafts.values { draft.suspend() } }
    func close() { for draft in drafts.values { draft.close() } }
    private static func newConfiguration(_ kind: TranslationServiceKind) -> TranslationServiceConfiguration {
        var configuration = TranslationServiceConfiguration(kind: kind)
        if kind.allowsCustomModel { configuration.model = "" }
        return configuration
    }
    private func replace(with configuration: TranslationServiceConfiguration) {
        close()
        let draft = TranslationServiceEditor(configuration: configuration, services: services, modelLoader: modelLoader)
        drafts = [configuration.kind: draft]
        editor = draft
    }
}
