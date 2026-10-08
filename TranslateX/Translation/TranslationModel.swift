import Foundation
import CoreGraphics
import NaturalLanguage
import Observation
import Translation

enum TranslationPhase: Equatable {
    case empty, waiting, composing, recognizing, translating, preparingLanguages, completed, unchanged, noText, cancelled
    case failed(String)
}

/// Keep the app-owned message identity, never infer it from translated text.
/// User input and provider output remain ordinary, unlocalized strings.
enum TranslationFailureMessage: Equatable {
    case key(String)
    case translation(TranslationFailure)
    case remote(RemoteTranslationError)
    case account(CodexAccountError)

    var text: String {
        switch self {
        case .key(let key): L10n.string(key)
        case .translation(let failure): failure.message
        case .remote(let error): error.errorDescription ?? L10n.string("Unable to complete translation")
        case .account(let error): error.localizedDescription
        }
    }
}

enum TranslationSide: Equatable {
    case source, target
    var opposite: Self { self == .source ? .target : .source }
}

/// Content moves between hosts; requests and Apple sessions never do.
struct TranslationHandoff {
    let text: String
    let translatedText: String
    let source: String
    let target: String
    let detectedSource: String?
    let inputSide: TranslationSide
    let partialSide: TranslationSide?
    let translationWasEdited: Bool
    let phase: TranslationPhase
    let completedResult: TranslationResult?
    let serviceConfiguration: TranslationServiceConfiguration?
    let serviceRevision: Int
    var screenshot: ScreenshotDocument? = nil
    var failureMessage: TranslationFailureMessage? = nil
}

@MainActor @Observable
final class TranslationModel {
    var text = "" {
        didSet {
            guard text != oldValue, !isUpdatingContext else { return }
            contentChanged(on: .source)
        }
    }
    private(set) var translatedText = ""
    var source = "auto" {
        didSet { if source != oldValue, !isUpdatingContext { languageChanged() } }
    }
    var target = "zh-Hans" {
        didSet { if target != oldValue, !isUpdatingContext { languageChanged() } }
    }
    private var storedSourceName = ""
    private var isScreenshotSource = false
    var sourceName: String {
        get { isScreenshotSource ? L10n.string("Screenshot") : storedSourceName }
        set { storedSourceName = newValue; isScreenshotSource = false }
    }
    func useScreenshotSourceName() { isScreenshotSource = true }
    private(set) var inputSide: TranslationSide = .source
    private(set) var detectedSource: String?
    private(set) var partialSide: TranslationSide?
    private(set) var translationWasEdited = false
    private(set) var isComposing = false
    private(set) var result: TranslationResult?
    private var previousResult: TranslationResult?
    private var storedPhase: TranslationPhase = .empty
    private var failureMessage: TranslationFailureMessage?
    private(set) var phase: TranslationPhase {
        get {
            if case .failed = storedPhase, let failureMessage { return .failed(failureMessage.text) }
            return storedPhase
        }
        set { storedPhase = newValue; failureMessage = nil }
    }
    private(set) var request: TranslationRequest?
    private(set) var configuration: TranslationSession.Configuration?
    private(set) var serviceConfiguration: TranslationServiceConfiguration?
    private(set) var partialText = ""
    private(set) var serviceRevision = 0
    private(set) var screenshot: ScreenshotDocument?
    private var statusMessageKey = ""
    var statusMessage: String { statusMessageKey.isEmpty ? "" : L10n.string(statusMessageKey) }
    private var automaticPreference = true
    @ObservationIgnored private var accountIdentityRevision = 0
    @ObservationIgnored private let services: TranslationServiceStore?
    @ObservationIgnored private var recognitionCancellation: (() -> Void)?
    @ObservationIgnored private var remoteTask: Task<Void, Never>?
    @ObservationIgnored private let remoteProvider: RemoteProviderFactory
    @ObservationIgnored private var lastConfiguration: TranslationSession.Configuration?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    let automaticallyTranslates: Bool
    @ObservationIgnored private let updateInterval: Duration
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var isUpdatingContext = false
    @ObservationIgnored private var contentRevision = 0
    @ObservationIgnored private var requestSide: TranslationSide = .source
    @ObservationIgnored private var requestWasAutomatic = false
    @ObservationIgnored private var requestPolicyRevision = 0
    @ObservationIgnored private var requestSnapshot: WorkspaceSnapshot?
    @ObservationIgnored private var verifiedSnapshot: WorkspaceSnapshot?
    private var undoSnapshot: WorkspaceSnapshot?
    private var redoSnapshot: WorkspaceSnapshot?

    private struct WorkspaceSnapshot: Equatable {
        let text: String
        let translatedText: String
        let source: String
        let target: String
        let detectedSource: String?
        let inputSide: TranslationSide
        let partialSide: TranslationSide?
        let translationWasEdited: Bool
        var screenshot: ScreenshotDocument? = nil
    }

    typealias RemoteProviderFactory = @MainActor (
        TranslationServiceConfiguration, String?, @escaping @MainActor @Sendable (String) -> Void
    ) -> any TranslationProvider

    init(
        automaticallyTranslates: Bool = false,
        updateInterval: Duration = .milliseconds(650),
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        services: TranslationServiceStore? = nil,
        remoteProvider: RemoteProviderFactory? = nil
    ) {
        self.automaticallyTranslates = automaticallyTranslates
        self.updateInterval = updateInterval
        self.sleep = sleep
        self.services = services
        self.remoteProvider = remoteProvider ?? { configuration, key, partial in
            TranslationProviderFactory.make(configuration: configuration, apiKey: key, codex: services?.codex, onPartial: partial)
        }
        serviceConfiguration = services?.selectedConfiguration
        serviceRevision = services?.revision ?? 0
        accountIdentityRevision = services?.codex.identityRevision ?? 0
        automaticPreference = services?.selectedConfiguration?.automaticallyTranslates ?? services?.appleAutomaticallyTranslates ?? true
        trackServiceChanges()
    }

    deinit { remoteTask?.cancel(); updateTask?.cancel() }

    var usesAutomaticTranslation: Bool { automaticallyTranslates && automaticPreference }
    var usesAppleTranslation: Bool { serviceConfiguration == nil }
    var destinationSide: TranslationSide { inputSide.opposite }
    var resolvedSource: String? { source == "auto" ? detectedSource : source }
    var inputNeedsNoTranslation: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !Self.containsLetters(inputText)
    }
    var needsSourceLanguage: Bool { usesAppleTranslation && inputSide == .source && source == "auto" && resolvedSource == nil && canTranslate && !inputNeedsNoTranslation }
    var needsReverseLanguage: Bool { inputSide == .target && resolvedSource == nil && canTranslate && !inputNeedsNoTranslation }
    var isBusy: Bool { phase == .waiting || phase == .recognizing || phase == .translating || phase == .preparingLanguages }
    var canTranslate: Bool { !isComposing && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSwapLanguages: Bool { !isComposing && resolvedSource != nil }
    var canClear: Bool { !isComposing && (!text.isEmpty || !translatedText.isEmpty || screenshot != nil) }
    var canUndoWorkspaceChange: Bool { !isComposing && !isBusy && undoSnapshot != nil }
    var canRedoWorkspaceChange: Bool { !isComposing && !isBusy && redoSnapshot != nil }
    var displayedResult: TranslationResult? { result ?? previousResult }
    var serviceDisplayName: String { serviceConfiguration?.name ?? L10n.string("Apple Translation") }
    var availableServices: [TranslationServiceConfiguration] { services?.configurations ?? [] }
    var serviceModelName: String? {
        guard let serviceConfiguration, serviceConfiguration.kind.requiresModel else { return nil }
        return serviceConfiguration.model
    }
    private var isServiceCurrent: Bool { serviceRevision == (services?.revision ?? 0) }
    private var inputText: String { inputSide == .source ? text : translatedText }
    private var canSynchronizeUnchangedInput: Bool {
        if inputNeedsNoTranslation { return true }
        guard resolvedSource.map({ Self.isSameLanguage($0, target) }) == true else { return false }
        // The selected/dominant language alone cannot certify a mixed passage.
        // A Chinese sentence containing an English label still needs translation.
        return Self.foreignScriptSample(inputText, target: target) == nil
            && Self.detectLanguage(inputText, target: target).map { Self.isSameLanguage($0, target) } == true
    }
    private var translationInput: String { usesAppleTranslation ? inputText.trimmingCharacters(in: .whitespacesAndNewlines) : inputText }
    private var hasActiveRequest: Bool { request != nil && (phase == .translating || phase == .preparingLanguages) }

    func selectService(_ id: UUID?) {
        do { try services?.select(id); synchronizeService() }
        catch { fail(localized: "Unable to select this service. Check its settings.") }
    }

    func setAutomaticTranslation(_ enabled: Bool) {
        guard !isComposing else { return }
        do {
            if let services { try services.setAutomaticTranslation(enabled, for: services.selectedID) }
            applyAutomaticPreference(enabled)
            serviceConfiguration = services?.selectedConfiguration
        } catch {
            statusMessageKey = "Unable to save automatic translation. Try again."
        }
    }

    private func applyAutomaticPreference(_ enabled: Bool) {
        guard automaticPreference != enabled else { return }
        if isBusy && phase != .recognizing { cancel() }
        automaticPreference = enabled
        // Enabling is a preference, not permission to resend the current passage.
        statusMessageKey = enabled ? "Automatic translation on · Applies to your next edit" : "Automatic translation off · Both sides remain editable"
    }

    private func trackServiceChanges() {
        guard let services else { return }
        withObservationTracking {
            _ = services.revision
            _ = services.automaticTranslationRevision
            _ = services.selectedConfiguration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.synchronizeService()
                self?.trackServiceChanges()
            }
        }
    }

    /// Config, identity and preference changes never send the existing passage.
    private func synchronizeService() {
        guard let services else { return }
        let routeChanged = !isServiceCurrent
        if routeChanged {
            let wasRecognizing = phase == .recognizing
            let identityChanged = accountIdentityRevision != services.codex.identityRevision
            let accountFailure = identityChanged && hasActiveRequest && serviceConfiguration?.kind == .codex
                && serviceConfiguration == services.selectedConfiguration ? services.codex.error : nil
            invalidateRequest()
            forgetUndo()
            result = nil
            verifiedSnapshot = nil
            previousResult = nil
            phase = wasRecognizing ? .recognizing : .empty
            if let accountFailure { recordFailure(.account(accountFailure)) }
            serviceRevision = services.revision
            accountIdentityRevision = services.codex.identityRevision
            lastConfiguration = nil
            statusMessageKey = "Service changed · Edit or translate to continue"
        }
        serviceConfiguration = services.selectedConfiguration
        let preference = serviceConfiguration?.automaticallyTranslates ?? services.appleAutomaticallyTranslates
        if routeChanged { automaticPreference = preference }
        else { applyAutomaticPreference(preference) }
    }

    func text(on side: TranslationSide) -> String { side == .source ? text : translatedText }

    private func setText(_ value: String, on side: TranslationSide) {
        isUpdatingContext = true
        if side == .source { text = value } else { translatedText = value }
        isUpdatingContext = false
    }

    /// Only this human-input entry point schedules automatic work. Binding echoes,
    /// streamed chunks, completions, handoffs and undo never enter it.
    func editingChanged(_ value: String, isComposing: Bool, side: TranslationSide = .source) {
        let changed = value != text(on: side) || self.isComposing != isComposing
        guard changed else { return }
        self.isComposing = isComposing
        screenshot = nil
        setText(value, on: side)
        contentChanged(on: side)
        if isComposing { phase = .composing }
        else { scheduleTranslation() }
    }

    private func contentChanged(on side: TranslationSide) {
        invalidateRequest()
        forgetUndo()
        inputSide = side
        previousResult = result ?? previousResult
        result = nil
        verifiedSnapshot = nil
        statusMessageKey = ""
        phase = .empty
        if side == .target { translationWasEdited = true }
        if side == partialSide { partialSide = nil }
        if side == .source { detectedSource = Self.detectLanguage(text, target: target) }
    }

    func captureServiceIntent() -> Int { synchronizeService(); return serviceRevision }

    func submitCapturedText(_ value: String, serviceRevision capturedRevision: Int) {
        synchronizeService()
        clear(keepingUndo: false)
        text = value
        guard capturedRevision == serviceRevision else {
            fail(localized: "The translation service changed. Translate again to use the selected service.")
            return
        }
        submit()
    }

    func submitCapturedDocument(_ document: ScreenshotDocument, serviceRevision capturedRevision: Int) {
        synchronizeService()
        recognitionCancellation = nil
        clear(keepingUndo: false)
        screenshot = document
        setText(document.sourceText, on: .source)
        detectedSource = Self.detectLanguage(text, target: target)
        guard capturedRevision == serviceRevision else {
            fail(localized: "The translation service changed. Translate again to use the selected service.")
            return
        }
        submit()
    }

    /// Screenshot edits remain attached to stable region coordinates. Editing
    /// output is a correction, not an instruction to translate pixels backwards.
    func editScreenshotRegion(_ id: UUID, text value: String, side: TranslationSide, isComposing: Bool = false) {
        guard var document = screenshot, let index = document.regions.firstIndex(where: { $0.id == id }) else { return }
        let old = side == .source ? document.regions[index].text : document.translations[id] ?? ""
        guard value != old || self.isComposing != isComposing else { return }
        self.isComposing = isComposing
        let previous = snapshot()
        invalidateRequest()
        if side == .source { document.regions[index].text = value }
        else { document.translations[id] = value }
        screenshot = document
        setText(document.sourceText, on: .source)
        setText(document.translatedText, on: .target)
        inputSide = .source
        detectedSource = Self.detectLanguage(text, target: target)
        result = nil; previousResult = nil; verifiedSnapshot = nil
        translationWasEdited = side == .target
        partialSide = nil; phase = .empty; statusMessageKey = ""
        undoSnapshot = previous; redoSnapshot = nil
        if isComposing { phase = .composing }
        else if side == .source { scheduleTranslation() }
    }

    func submit() { submit(automatic: false) }

    private func submit(automatic: Bool) {
        synchronizeService()
        guard !isComposing, !automatic || usesAutomaticTranslation else { return }
        invalidateRequest()
        statusMessageKey = ""
        guard canTranslate else { phase = .empty; return }
        let input = translationInput
        guard input.count <= SelectionText.maximumLength else {
            fail(localized: "This text is too long. Try a smaller passage."); return
        }
        // Recheck auto detection after a target/service change. Never use a
        // previous provider's detected language to certify a local copy.
        if inputSide == .source, source == "auto" { detectedSource = Self.detectLanguage(inputText, target: target) }
        if canSynchronizeUnchangedInput {
            synchronizeUnchangedInput()
            return
        }
        // A nil Apple source opens the system language-selection sheet. Keep an
        // unresolved language in the existing pane header instead.
        guard !needsSourceLanguage, !needsReverseLanguage else { phase = .empty; return }
        let to = inputSide == .target ? resolvedSource! : target
        var from = inputSide == .target ? target : (source == "auto" ? (usesAppleTranslation ? resolvedSource : nil) : source)
        // Equal pane languages do not mean every word is already translated.
        // Resolve the foreign portion rather than asking Apple for an invalid
        // same-language session. Other explicit language pairs stay unchanged.
        if let selected = from, Self.isSameLanguage(selected, to),
           let foreign = Self.detectLanguage(input, target: to), !Self.isSameLanguage(foreign, to) {
            from = foreign
        }
        guard !usesAppleTranslation || from != nil else {
            // A previous provider may have identified text that Apple cannot.
            detectedSource = nil
            phase = .empty
            return
        }
        let next = TranslationRequest(id: UUID(), text: input, source: from, target: to)
        request = next
        requestSide = inputSide
        requestWasAutomatic = automatic
        requestPolicyRevision = services?.automaticTranslationRevision ?? 0
        requestSnapshot = snapshot()
        previousResult = result ?? previousResult
        result = nil
        verifiedSnapshot = nil
        phase = .translating
        if let serviceConfiguration {
            lastConfiguration = nil
            do {
                let key = try services?.apiKey(for: serviceConfiguration.id)
                let provider = remoteProvider(serviceConfiguration, key) { [weak self] value in
                    guard let self, self.isCurrent(next), self.phase == .translating, self.screenshot == nil else { return }
                    self.partialText = value
                    self.partialSide = self.requestSide.opposite
                    self.setText(value, on: self.requestSide.opposite)
                }
                remoteTask = Task { [weak self] in await self?.run(next, provider: provider) }
            } catch {
                fail(localized: "Unable to read this service’s API key. Open Translation services to update it.")
            }
        } else {
            let nextConfiguration = TranslationSession.Configuration(source: from.map { Locale.Language(identifier: $0) }, target: Locale.Language(identifier: to))
            if var previous = lastConfiguration, previous.source == nextConfiguration.source, previous.target == nextConfiguration.target {
                previous.invalidate()
                configuration = previous
            } else { configuration = nextConfiguration }
            lastConfiguration = configuration
        }
    }

    private func synchronizeUnchangedInput() {
        let previous = snapshot()
        let value = inputText
        if text(on: destinationSide) != value {
            undoSnapshot = previous
            redoSnapshot = nil
        }
        setText(value, on: destinationSide)
        if inputSide == .source {
            translationWasEdited = false
            if let document = screenshot { screenshot?.translations = Dictionary(uniqueKeysWithValues: document.regions.map { ($0.id, $0.text) }) }
        }
        // This is an exact local copy, not a provider result or a detected language.
        result = nil
        previousResult = nil
        verifiedSnapshot = nil
        partialSide = nil
        phase = .unchanged
    }

    private func isCurrent(_ captured: TranslationRequest) -> Bool {
        isServiceCurrent && requestPolicyRevision == (services?.automaticTranslationRevision ?? 0)
            && request?.id == captured.id && inputSide == requestSide && !isComposing && captured.text == translationInput
    }

    func run(_ captured: TranslationRequest, provider: any TranslationProvider) async {
        guard isCurrent(captured) else { return }
        let provider: any TranslationProvider = services.map {
            UsageRecordingTranslationProvider(base: provider, store: $0.usage,
                configurationID: serviceConfiguration?.id, model: serviceConfiguration?.model ?? "")
        } ?? provider
        do {
            let translated: TranslationResult
            if let document = screenshot, inputSide == .source {
                translated = try await translateScreenshot(document, request: captured, provider: provider)
            } else { translated = try await provider.translate(captured) }
            guard !Task.isCancelled, isCurrent(captured) else { return }
            undoSnapshot = requestSnapshot
            redoSnapshot = nil
            setText(translated.text, on: requestSide.opposite)
            if requestSide == .source {
                translationWasEdited = false
                detectedSource = translated.source.map(LanguageCatalog.canonicalIdentifier) ?? detectedSource
            } else { detectedSource = captured.target }
            result = translated
            previousResult = nil
            partialText = ""
            partialSide = nil
            phase = .completed
            statusMessageKey = requestWasAutomatic ? "Updated automatically" : "Updated"
            verifiedSnapshot = snapshot()
        } catch {
            guard isCurrent(captured) else { return }
            if let remoteError = error as? RemoteTranslationError, !Task.isCancelled {
                recordFailure(.remote(remoteError))
            } else if let codexError = error as? CodexAccountError, !Task.isCancelled {
                recordFailure(.account(codexError))
            } else {
                let failure = TranslationFailure.classify(error, preparingLanguages: phase == .preparingLanguages)
                if failure == .cancelled || Task.isCancelled { phase = .cancelled }
                else if failure == .noText { phase = .noText }
                else { recordFailure(.translation(failure)) }
            }
            // An unfinished fragment remains editable but never becomes a result.
            if partialSide != nil { undoSnapshot = requestSnapshot }
            request = nil
            configuration = nil
        }
    }

    private func translateScreenshot(_ document: ScreenshotDocument, request captured: TranslationRequest,
                                     provider: any TranslationProvider) async throws -> TranslationResult {
        for region in document.regions {
            try Task.checkCancellation()
            guard isCurrent(captured), screenshot?.id == document.id else { throw CancellationError() }
            let value: String
            if !Self.containsLetters(region.text) || region.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value = region.text
            } else if Self.foreignScriptSample(region.text, target: captured.target) == nil,
                      Self.detectLanguage(region.text, target: captured.target).map({ Self.isSameLanguage($0, captured.target) }) == true {
                value = region.text
            } else {
                let response = try await provider.translate(TranslationRequest(id: region.id, text: region.text,
                    source: captured.source, target: captured.target))
                guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      LanguageCatalog.canonicalIdentifier(response.target) == LanguageCatalog.canonicalIdentifier(captured.target) else { throw RemoteTranslationError.invalidResponse }
                value = response.text
            }
            try Task.checkCancellation()
            guard isCurrent(captured), screenshot?.id == document.id else { throw CancellationError() }
            screenshot?.translations[region.id] = value
            if let screenshot { setText(screenshot.translatedText, on: .target) }
            partialSide = .target
        }
        return TranslationResult(text: screenshot?.translatedText ?? "", source: captured.source, target: captured.target)
    }

    func markPreparing(_ captured: TranslationRequest) { if isCurrent(captured) { phase = .preparingLanguages } }
    func beginRecognition(image: CGImage? = nil, cancellation: (() -> Void)? = nil) {
        clear(keepingUndo: false)
        if let image { screenshot = ScreenshotDocument(image: image) }
        phase = .recognizing
        recognitionCancellation = cancellation
    }

    func fail(_ message: String) {
        cancelRecognition()
        invalidateRequest()
        result = nil
        verifiedSnapshot = nil
        phase = .failed(message)
    }
    func fail(_ message: String, for captured: TranslationRequest) { if isCurrent(captured) { fail(message) } }

    func fail(localized key: String) {
        fail("")
        recordFailure(.key(key))
    }

    func fail(localized key: String, for captured: TranslationRequest) {
        if isCurrent(captured) { fail(localized: key) }
    }

    private func recordFailure(_ message: TranslationFailureMessage) {
        storedPhase = .failed("")
        failureMessage = message
    }

    func cancel() {
        let wasBusy = isBusy
        cancelRecognition()
        if hasActiveRequest, partialSide != nil { undoSnapshot = requestSnapshot }
        invalidateRequest()
        if wasBusy { phase = .cancelled; statusMessageKey = "" }
    }

    func clear(keepingUndo: Bool = true) {
        let previous = snapshot()
        cancelRecognition()
        invalidateRequest()
        screenshot = nil
        setText("", on: .source)
        setText("", on: .target)
        detectedSource = nil
        partialSide = nil
        inputSide = .source
        translationWasEdited = false
        result = nil
        previousResult = nil
        verifiedSnapshot = nil
        phase = .empty
        statusMessageKey = ""
        undoSnapshot = keepingUndo && (!previous.text.isEmpty || !previous.translatedText.isEmpty || previous.screenshot != nil) ? previous : nil
        redoSnapshot = nil
    }

    func swapLanguages() {
        guard canSwapLanguages, let newTarget = resolvedSource else { return }
        let previous = snapshot()
        invalidateRequest()
        isUpdatingContext = true
        screenshot = nil
        source = target
        target = LanguageCatalog.canonicalIdentifier(newTarget)
        text = previous.translatedText
        translatedText = previous.text
        isUpdatingContext = false
        detectedSource = source
        inputSide = .source
        partialSide = previous.partialSide?.opposite
        translationWasEdited = false
        result = nil; previousResult = nil; verifiedSnapshot = nil
        phase = .empty
        statusMessageKey = "Swapped · Edit or translate to continue"
        undoSnapshot = previous; redoSnapshot = nil
    }

    @discardableResult func undoWorkspaceChange() -> Bool {
        guard canUndoWorkspaceChange, let previous = undoSnapshot else { return false }
        redoSnapshot = snapshot()
        undoSnapshot = nil
        restore(previous)
        return true
    }
    @discardableResult func redoWorkspaceChange() -> Bool {
        guard canRedoWorkspaceChange, let next = redoSnapshot else { return false }
        undoSnapshot = snapshot()
        redoSnapshot = nil
        restore(next)
        return true
    }

    private func snapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(text: text, translatedText: translatedText, source: source, target: target, detectedSource: detectedSource,
                          inputSide: inputSide, partialSide: partialSide, translationWasEdited: translationWasEdited, screenshot: screenshot)
    }
    private func restore(_ value: WorkspaceSnapshot) {
        invalidateRequest()
        isUpdatingContext = true
        text = value.text; translatedText = value.translatedText; source = value.source; target = value.target
        isUpdatingContext = false
        screenshot = value.screenshot
        detectedSource = value.detectedSource; inputSide = value.inputSide; partialSide = value.partialSide
        translationWasEdited = value.translationWasEdited
        result = nil; previousResult = nil; verifiedSnapshot = nil
        phase = .empty
        statusMessageKey = "Restored · Continue editing"
    }
    private func cancelRecognition() {
        let callback = recognitionCancellation
        recognitionCancellation = nil
        callback?()
    }
    private func forgetUndo() { undoSnapshot = nil; redoSnapshot = nil }
    private func invalidateRequest() {
        contentRevision &+= 1
        updateTask?.cancel(); updateTask = nil
        remoteTask?.cancel(); remoteTask = nil
        request = nil
        configuration = nil
        partialText = ""
        requestSnapshot = nil
    }
    private func languageChanged() {
        if phase == .recognizing { return }
        invalidateRequest(); forgetUndo()
        result = nil; verifiedSnapshot = nil; previousResult = nil
        phase = .empty; statusMessageKey = ""
        if inputSide == .source { detectedSource = Self.detectLanguage(text, target: target) }
        scheduleTranslation()
    }
    private func scheduleTranslation() {
        guard usesAutomaticTranslation, canTranslate, isServiceCurrent else { return }
        if canSynchronizeUnchangedInput { submit(automatic: true); return }
        guard !needsSourceLanguage, !needsReverseLanguage else { return }
        phase = .waiting
        let scheduledRevision = contentRevision
        let sleep = sleep, delay = updateInterval
        updateTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await sleep(delay)
                guard !Task.isCancelled, let self, self.contentRevision == scheduledRevision else { return }
                self.updateTask = nil
                self.submit(automatic: true)
            } catch { }
        }
    }

    func makeHandoff() -> TranslationHandoff? {
        guard !isComposing, screenshot != nil || !(text + translatedText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var completed: TranslationResult?
        if isServiceCurrent, phase == .completed, verifiedSnapshot == snapshot(), let result {
            let expectedTarget = inputSide == .source ? target : resolvedSource
            let expectedSource = inputSide == .source ? (source == "auto" ? nil : source) : target
            if expectedTarget.map(LanguageCatalog.canonicalIdentifier) == LanguageCatalog.canonicalIdentifier(result.target),
               expectedSource == nil || expectedSource.map(LanguageCatalog.canonicalIdentifier) == result.source.map(LanguageCatalog.canonicalIdentifier),
               !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { completed = result }
        }
        return TranslationHandoff(text: text, translatedText: translatedText, source: source, target: target, detectedSource: detectedSource,
            inputSide: inputSide, partialSide: partialSide, translationWasEdited: translationWasEdited, phase: phase,
            completedResult: completed, serviceConfiguration: serviceConfiguration, serviceRevision: serviceRevision, screenshot: screenshot, failureMessage: failureMessage)
    }
    func acceptHandoff(_ handoff: TranslationHandoff?) {
        guard let handoff else { return }
        synchronizeService()
        invalidateRequest(); forgetUndo()
        isComposing = false
        restore(WorkspaceSnapshot(text: handoff.text, translatedText: handoff.translatedText, source: handoff.source, target: handoff.target,
            detectedSource: handoff.detectedSource, inputSide: handoff.inputSide, partialSide: handoff.partialSide, translationWasEdited: handoff.translationWasEdited, screenshot: handoff.screenshot))
        sourceName = ""
        lastConfiguration = nil
        statusMessageKey = ""
        var handoffConfiguration = handoff.serviceConfiguration
        handoffConfiguration?.website = serviceConfiguration?.website ?? ""
        if handoffConfiguration == serviceConfiguration, handoff.serviceRevision == serviceRevision {
            if let completed = handoff.completedResult {
                result = completed; phase = .completed; verifiedSnapshot = snapshot()
            } else {
                switch handoff.phase {
                case .waiting, .translating, .preparingLanguages: phase = .cancelled
                case .completed: phase = .empty
                default:
                    phase = handoff.phase
                    if case .failed = handoff.phase { failureMessage = handoff.failureMessage }
                }
            }
        } else { phase = .empty }
        // Expanding a window never resends content or turns a fragment into a result.
    }

    static func isSameLanguage(_ source: String, _ target: String) -> Bool {
        // Meaningful region/script variants remain distinct (en → en-GB,
        // pt → pt-PT, Hans → Hant); Foundation aliases still collapse.
        LanguageCatalog.canonicalIdentifier(source) == LanguageCatalog.canonicalIdentifier(target)
    }

    static func detectLanguage(_ text: String, target: String? = nil) -> String? {
        guard containsLetters(text) else { return nil }
        // Names/identifiers such as HelloKitty can dominate NL's whole-passage
        // result. Expand word boundaries for recognition only; the provider gets
        // the original text, including punctuation, names and line breaks.
        let normalized = text.replacingOccurrences(
            of: #"(?<=[\p{Ll}\p{Nd}])(?=\p{Lu})"#, with: " ", options: .regularExpression
        )
        let sample = target.flatMap { foreignScriptSample(normalized, target: $0) } ?? normalized
        // A complete phrase is better evidence than an isolated name, including
        // all-lowercase/uppercase names with no visible camel-case boundaries.
        // Do not let that single token outvote a clearly identified sentence.
        var contextualLanguage: (language: String, length: Int)?
        let lines = sample.components(separatedBy: .newlines)
        if lines.count > 1 {
            for line in lines {
                let words = line.components(separatedBy: CharacterSet.letters.inverted).filter { containsLetters($0) }
                guard words.count >= 2,
                      let candidate = recognizeSample(line, target: target, allowsLatinFallback: false),
                      target.map({ !isSameLanguage(candidate, $0) }) ?? true else { continue }
                let length = words.joined().count
                if length > (contextualLanguage?.length ?? 0) { contextualLanguage = (candidate, length) }
            }
        }
        let language = contextualLanguage?.language ?? recognizeSample(sample, target: target)
        // Scripts alone cannot distinguish e.g. English and French. When the
        // dominant language matches the destination, look for a foreign sentence
        // before declaring the entire passage unchanged.
        if let target, let language, isSameLanguage(language, target) {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = normalized
            var foreign: String?
            tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
                // Newlines also delimit labels without sentence punctuation.
                for line in normalized[range].components(separatedBy: .newlines) where containsLetters(line) {
                    if let candidate = recognizeSample(line, target: target), !isSameLanguage(candidate, target) {
                        foreign = candidate
                        return false
                    }
                }
                return true
            }
            if let foreign { return foreign }
        }
        return language
    }

    /// Remove only letters belonging to the destination's writing system from
    /// the detection sample. Keep the whole original passage in the request so
    /// Apple/remote models retain context and already-translated text.
    private static func foreignScriptSample(_ text: String, target: String) -> String? {
        guard let script = Locale.Language(identifier: target).script?.identifier else { return nil }
        let pattern: String
        switch script {
        case "Hans", "Hant": pattern = #"\p{Han}"#
        case "Jpan": pattern = #"[\p{Han}\p{Hiragana}\p{Katakana}]"#
        case "Kore": pattern = #"[\p{Han}\p{Hangul}]"#
        default: pattern = "\\p{\(script)}"
        }
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let foreign = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        return containsLetters(foreign) ? foreign : nil
    }

    private static func recognizeSample(_ text: String, target: String?, allowsLatinFallback: Bool = true) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        if let resolved = resolveLanguage(
            text,
            dominant: recognizer.dominantLanguage,
            hypotheses: hypotheses,
            target: target
        ) { return resolved }

        // Short Latin words have little statistical evidence (even "hello" is
        // low confidence). Use a clear leading candidate, otherwise English as
        // the bounded fallback for short ASCII words. This is a usable default,
        // not a confidence claim; the source menu remains editable. Confident
        // non-English detection above is never restricted to installed languages.
        guard allowsLatinFallback,
              text.range(of: #"[\p{L}&&\P{Latin}]"#, options: .regularExpression) == nil,
              containsLetters(text) else { return nil }
        let ranked = hypotheses.sorted { $0.value > $1.value }
        // Interface labels provide little context. A weak non-English lead is
        // not decisive when English remains plausible (for example, several
        // short navigation labels). Prefer the existing bounded English default
        // in that case, without overriding confident detection or words such as
        // Bonjour/Hallo whose hypotheses do not meaningfully include English.
        let letters = text.replacingOccurrences(of: #"\P{L}"#, with: "", options: .regularExpression).unicodeScalars
        let isShortASCII = letters.count <= 40 && letters.allSatisfy(\.isASCII)
        if isShortASCII, hypotheses[.english, default: 0] >= 0.1 { return "en" }
        if let first = ranked.first, first.value >= 0.35,
           first.value >= (ranked.dropFirst().first?.value ?? 0) * 2 {
            return LanguageCatalog.canonicalIdentifier(first.key.rawValue)
        }
        // Unicode marks (including emoji variation selectors/keycaps) are not
        // letters and must not disqualify an otherwise ASCII recognition sample.
        if isShortASCII { return "en" }
        return nil
    }

    static func resolveLanguage(
        _ text: String,
        dominant language: NLLanguage?,
        hypotheses: [NLLanguage: Double],
        target: String? = nil
    ) -> String? {
        guard containsLetters(text), let language, let confidence = hypotheses[language] else { return nil }
        if confidence >= 0.65 {
            return LanguageCatalog.canonicalIdentifier(language.rawValue)
        }

        // Shared Han characters can split otherwise strong Chinese confidence
        // between scripts. Only resolve that narrow ambiguity: other languages,
        // mixed-script text and passages with distinct Hans/Hant forms still use
        // the existing confidence threshold or our inline language picker.
        // Require some context: short Han words can also be Japanese. This length
        // floor reduces that risk without claiming to disambiguate every passage.
        guard language == .simplifiedChinese || language == .traditionalChinese,
              hypotheses[.simplifiedChinese, default: 0] + hypotheses[.traditionalChinese, default: 0] >= 0.95,
              text.replacingOccurrences(of: #"\P{Han}"#, with: "", options: .regularExpression).count >= 8,
              text.range(of: #"[\p{L}&&\P{Han}]"#, options: .regularExpression) == nil,
              chineseScriptFormsAreIdentical(text) else { return nil }

        // Both scripts represent this unchanged passage. Match a Chinese target
        // so an already-readable passage receives the normal same-language state.
        if let target {
            let canonical = LanguageCatalog.canonicalIdentifier(target)
            if canonical == "zh-Hans" || canonical == "zh-Hant" { return canonical }
        }
        return LanguageCatalog.canonicalIdentifier(language.rawValue)
    }

    private static func containsLetters(_ text: String) -> Bool {
        // CharacterSet.letters also includes combining marks, such as emoji
        // variation selectors and keycaps. Only Unicode letter categories count.
        text.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
            default: false
            }
        }
    }

    private static func chineseScriptFormsAreIdentical(_ text: String) -> Bool {
        ["Hans-Hant", "Hant-Hans"].allSatisfy { identifier in
            let transformed = NSMutableString(string: text)
            let succeeded = transformed.applyTransform(
                StringTransform(identifier), reverse: false,
                range: NSRange(location: 0, length: transformed.length), updatedRange: nil
            )
            return succeeded && transformed as String == text
        }
    }
}
