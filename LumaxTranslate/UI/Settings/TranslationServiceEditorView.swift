import AppKit
import SwiftUI

struct TranslationServiceEditorView: View {
    @Bindable var session: TranslationServiceDraftSession
    let finish: () -> Void
    let saved: () -> Void

    var body: some View {
        TranslationServiceEditorContent(editor: session.editor, changeKind: session.selectKind,
                                        finish: finish, saved: saved)
            .id(session.editor.configuration.id)
    }
}

private struct TranslationServiceEditorContent: View {
    @Environment(\.lumaxTheme) private var theme
    @Bindable var editor: TranslationServiceEditor
    let changeKind: (TranslationServiceKind) -> Void
    let finish: () -> Void
    let saved: () -> Void
    @State private var advanced = false
    @State private var popup: Popup?
    @State private var openCatalogWhenReady = false
    @State private var keyFocused = false
    @State private var manualModelEntry = false
    @State private var popupHeight: CGFloat?
    @State private var requestedField: TranslationServiceEditor.Field?
    @State private var fieldFocusRevision = 0
    @FocusState private var focusedAction: Action?
    private enum Popup: String { case providers, models }
    private enum Action: Hashable { case provider, model, serviceOption(String) }
    private var p: TranslationServicePalette { TranslationServicePalette(theme: theme) }
    private var kind: TranslationServiceKind { editor.configuration.kind }
    private var isAccount: Bool { kind == .codex }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        identityCard.padding(.bottom, 10)
                        if isAccount { CodexAccountSettingsView(editor: editor).padding(.bottom, 12) }
                        connectionCard
                        advancedSection
                        feedback.id("service-feedback")
                        recipient.padding(.top, 1).padding(.bottom, 9)
                    }.padding(1)
                        .translationServiceScrollContent()
                }
                .scrollIndicators(.automatic)
                .serviceDesignMetric("editor.scroll")
                .onChange(of: editor.testState) { _, state in
                    if state == .succeeded || state == .failed || state == .stopped {
                        proxy.scrollTo("service-feedback", anchor: .bottom)
                    }
                }
                .onChange(of: editor.saveErrorMessage) { _, message in
                    if message != nil { proxy.scrollTo("service-feedback", anchor: .bottom) }
                }
                .onChange(of: editor.fieldErrors) { _, errors in
                    if let first = [TranslationServiceEditor.Field.name, .website, .key, .endpoint, .model, .region, .instructions, .outputLimit]
                        .first(where: { errors[$0] != nil }) {
                        if first == .instructions || first == .outputLimit { advanced = true }
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo(first, anchor: .center)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(.horizontal, 36).padding(.top, 10)
        .disabled(popup != nil)
        .accessibilityHidden(popup != nil)
        .overlayPreferenceValue(TranslationServicePopupAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if let popup, let anchor = anchors[popup.rawValue] {
                    popupOverlay(popup, anchor: geometry[anchor], size: geometry.size)
                }
            }
        }
        .onChange(of: popup) { _, _ in popupHeight = nil }
        .onAppear {
            editor.refreshKeyState()
            if isAccount { editor.openCodex() }
        }
        .onChange(of: editor.catalogState) { _, state in
            guard openCatalogWhenReady else { return }
            if state == .loaded {
                openCatalogWhenReady = false
                if !editor.models.isEmpty { popup = .models }
            } else if state == .failed || state == .empty { openCatalogWhenReady = false }
        }
        .onChange(of: editor.codex.identityRevision) { _, _ in editor.codexIdentityChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in editor.hideKey() }
        .onExitCommand { if popup != nil { closePopup() } else { finish() } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { editor.hideKey(); finish() } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .regular))
                    .foregroundStyle(p.muted).frame(width: 32, height: 32)
                    .background(p.fill, in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(p.line, lineWidth: 1) }
            }
            .buttonStyle(LumaxHoverButtonStyle()).help(L10n.string("Back to services"))
            .accessibilityLabel(L10n.string("Back to services"))
            .serviceDesignMetric("button.back")
            .frame(width: 40, alignment: .leading)
            Text(editor.isNew ? L10n.string("Add service") : editor.originalName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .help(editor.isNew ? L10n.string("Add service") : editor.originalName)
                .accessibilityAddTraits(.isHeader)
            Color.clear.frame(width: 40, height: 1).accessibilityHidden(true)
        }
        .frame(height: 38).serviceDesignMetric("editor.header")
    }

    private var identityCard: some View {
        TranslationServiceCard {
            TranslationServiceFormRow(title: "Provider") {
                if editor.isNew {
                    Button { editor.hideKey(); popup = .providers } label: { providerIdentity }
                        .buttonStyle(LumaxHoverButtonStyle()).focusable().focused($focusedAction, equals: .provider)
                        .translationServicePopupAnchor(Popup.providers.rawValue)
                        .accessibilityLabel(L10n.string("Choose a provider"))
                } else {
                    providerIdentity.accessibilityLabel(kind.settingsName + ", " + L10n.string("Provider cannot be changed while editing"))
                }
            }
            TranslationServiceDivider()
            TranslationServiceFormRow(title: "Service name") {
                TranslationServiceField(title: "Service name", text: $editor.configuration.name,
                                        placeholder: "Name this configuration", invalid: editor.fieldErrors[.name] != nil,
                                        onFocusChanged: { if $0 { editor.hideKey() } }, focusRequest: focusRequest(for: .name))
                    .serviceDesignMetric("field.name")
                fieldError(.name)
            }.id(TranslationServiceEditor.Field.name)
            TranslationServiceDivider()
            TranslationServiceFormRow(title: "Service website", optional: true) {
                TranslationServiceField(title: "Service website", text: $editor.configuration.website,
                                        placeholder: "https://example.com", invalid: editor.fieldErrors[.website] != nil,
                                        onFocusChanged: { if $0 { editor.hideKey() } }, focusRequest: focusRequest(for: .website))
                    .serviceDesignMetric("field.website")
                if editor.fieldErrors[.website] != nil { fieldError(.website) }
                else { TranslationServiceHint(text: L10n.string("Website or account console opened in your browser. Separate from the API URL.")) }
            }.id(TranslationServiceEditor.Field.website)
        }
        .serviceDesignMetric("identity.group")
    }

    private var providerIdentity: some View {
        HStack(spacing: 9) {
            TranslationServiceProviderMark(kind: kind, size: 23)
            Text(kind.settingsName).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 2)
            Text(kind.connectionLabel).font(.system(size: 10)).foregroundStyle(p.muted).fixedSize()
            if isAccount { TranslationServiceExperimentalBadge() }
            Image(systemName: editor.isNew ? "chevron.down" : "lock")
                .font(.system(size: 12)).foregroundStyle(p.muted).padding(.leading, 4)
        }
        .padding(.horizontal, 8).frame(height: 34)
        .background(editor.isNew ? p.fill : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(editor.isNew ? p.line.opacity(0.34) : .clear, lineWidth: 1) }
        .contentShape(Rectangle())
    }

    private var connectionCard: some View {
        TranslationServiceCard {
            if !isAccount {
                keyRow
                if kind == .deepL || kind == .qwenMT || kind == .tencentTranslation || kind == .azureTranslator {
                    TranslationServiceDivider()
                    specificRow
                }
                TranslationServiceDivider()
                TranslationServiceFormRow(title: kind == .googleCloud ? "Translation URL" : "API URL") {
                    TranslationServiceField(title: "API URL", text: $editor.configuration.endpoint,
                                            placeholder: "https://api.example.com/v1", invalid: editor.fieldErrors[.endpoint] != nil,
                                            onFocusChanged: { if $0 { editor.hideKey() } }, focusRequest: focusRequest(for: .endpoint))
                        .serviceDesignMetric("field.endpoint")
                    if let message = editor.fieldErrors[.endpoint] { TranslationServiceHint(text: message, error: true) }
                    else if editor.keyState == .addressChanged && editor.replacementKey.isEmpty {
                        TranslationServiceHint(text: L10n.string("The old address’s key will not be sent here."), error: true)
                    }
                }.id(TranslationServiceEditor.Field.endpoint)
                if kind.requiresModel { TranslationServiceDivider() }
            }
            if kind.requiresModel { modelRow }
        }
        .serviceDesignMetric("connection.group")
    }

    private var keyRow: some View {
        TranslationServiceFormRow(title: "API Key", optional: !kind.requiresAPIKey) {
            ZStack(alignment: .trailing) {
                TranslationServiceSecretInput(text: $editor.keyFieldText, visible: editor.isKeyVisible,
                                              placeholder: keyPlaceholder, ink: p.ink, muted: p.muted,
                                              blur: editor.hideKey, focusChanged: { keyFocused = $0 }, moveFocus: moveKeyFocus)
                    .frame(height: 32)
                    .background(editor.fieldErrors[.key] != nil || editor.keyErrorMessage != nil ? p.errorFill : p.fill, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(editor.fieldErrors[.key] != nil || editor.keyErrorMessage != nil ? p.error.opacity(0.5) : p.line.opacity(0.34), lineWidth: 1) }
                Button { focusedAction = nil; editor.toggleKeyVisibility() } label: {
                    Image(systemName: editor.isKeyVisible ? "eye.slash" : "eye")
                        .font(.system(size: 14)).frame(width: 28, height: 28)
                }
                .buttonStyle(LumaxHoverButtonStyle()).foregroundStyle(p.muted)
                .disabled(!canRevealKey)
                .opacity(canRevealKey ? 1 : 0.42)
                .padding(.trailing, 3)
                .accessibilityLabel(L10n.string(editor.isKeyVisible ? "Hide API key" : "Show API key"))
                .help(L10n.string(editor.isKeyVisible ? "Hide API key" : "Show API key"))
            }
            .overlay {
                if keyFocused {
                    RoundedRectangle(cornerRadius: 7).stroke(p.accent.opacity(0.72), lineWidth: 2)
                        .padding(-1).allowsHitTesting(false)
                }
            }
            .serviceDesignMetric("field.key")
            TranslationServiceHint(text: keyHint, error: editor.fieldErrors[.key] != nil || editor.keyErrorMessage != nil || editor.keyState == .addressChanged)
            if !kind.requiresAPIKey && !editor.isNew && (editor.keyState == .stored || editor.removeSavedKey) {
                Button(L10n.string(editor.removeSavedKey ? "Keep saved key" : "Remove saved key")) { editor.removeSavedKey.toggle() }
                    .font(.system(size: 10)).buttonStyle(LumaxHoverButtonStyle()).foregroundStyle(p.accent)
            }
        }.id(TranslationServiceEditor.Field.key)
    }

    private var keyPlaceholder: String {
        if editor.keyState == .stored { return "Saved key" }
        if editor.keyState == .unconfirmed || editor.keyState == .unavailable { return "Key status unconfirmed" }
        return kind.requiresAPIKey ? "Paste API key" : "Optional, if required by the service"
    }
    private var canRevealKey: Bool {
        !editor.replacementKey.isEmpty || !editor.isNew && !editor.removeSavedKey
            && [.stored, .unconfirmed, .unavailable].contains(editor.keyState)
    }
    private var keyHint: String {
        if let message = editor.fieldErrors[.key] ?? editor.keyErrorMessage { return message }
        if editor.isKeyVisible { return L10n.string("Hidden automatically after 30 seconds or when you leave this field.") }
        if editor.removeSavedKey { return L10n.string("The saved key will be removed when you save.") }
        if !editor.replacementKey.isEmpty { return L10n.string(editor.isNew ? "Saved only in this Mac’s Keychain" : "The new key replaces the saved key after saving") }
        switch editor.keyState {
        case .stored: return L10n.string("Use the eye to view it; enter a new key to replace it")
        case .addressChanged: return L10n.string("The address changed. Enter the key again.")
        case .unavailable: return L10n.string("The saved key cannot be read right now. Try again or enter a new key.")
        case .unconfirmed: return L10n.string("The saved key’s status is not confirmed. Enter a key if needed.")
        case .missing:
            if !editor.isNew && kind.requiresAPIKey { return L10n.string("No saved key was found. Enter it again.") }
            return L10n.string(kind.requiresAPIKey ? "Saved only in this Mac’s Keychain" : "A key is unnecessary if the service allows anonymous access")
        }
    }

    @ViewBuilder private var specificRow: some View {
        switch kind {
        case .deepL:
            TranslationServiceFormRow(title: "API plan") {
                segmented(DeepLAPIEndpoint.allCases.map { ($0.rawValue, $0.displayName) }, selected: editor.configuration.endpoint) { raw in
                    if let endpoint = DeepLAPIEndpoint(rawValue: raw) { editor.useDeepLEndpoint(endpoint) }
                }
            }
        case .qwenMT:
            TranslationServiceFormRow(title: "Service region") {
                segmented(QwenMTEndpoint.allCases.map { ($0.rawValue, $0.displayName) }, selected: qwenRegion) { raw in
                    if let endpoint = QwenMTEndpoint(rawValue: raw) { editor.useQwenMTEndpoint(endpoint) }
                }
            }
        case .tencentTranslation:
            TranslationServiceFormRow(title: "Service region") {
                segmented(TencentTranslationEndpoint.allCases.map { ($0.rawValue, $0.displayName) }, selected: editor.configuration.endpoint) { raw in
                    if let endpoint = TencentTranslationEndpoint(rawValue: raw) { editor.useTencentEndpoint(endpoint) }
                }
            }
        case .azureTranslator:
            TranslationServiceFormRow(title: "Resource region") {
                TranslationServiceField(title: "Resource region", text: $editor.configuration.region,
                                        placeholder: "For example eastus; leave blank for Global", invalid: editor.fieldErrors[.region] != nil,
                                        onFocusChanged: { if $0 { editor.hideKey() } }, focusRequest: focusRequest(for: .region))
                if let message = editor.fieldErrors[.region] { TranslationServiceHint(text: message, error: true) }
                else { TranslationServiceHint(text: L10n.string("Use the resource’s region, not your current location.")) }
            }.id(TranslationServiceEditor.Field.region)
        default: EmptyView()
        }
    }
    private var qwenRegion: String {
        editor.configuration.endpoint.contains("dashscope-intl") ? QwenMTEndpoint.singapore.rawValue :
        editor.configuration.endpoint.contains("dashscope.aliyuncs.com") ? QwenMTEndpoint.beijing.rawValue : ""
    }

    private var modelRow: some View {
        TranslationServiceFormRow(title: "Model") {
            if !kind.allowsCustomModel && !isAccount {
                HStack(spacing: 7) {
                    Image(systemName: "lock").font(.system(size: 11))
                    Text(editor.configuration.model).font(.system(size: 11))
                    Text(L10n.string("Fixed model")).font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(p.fill, in: RoundedRectangle(cornerRadius: 4))
                }
                .foregroundStyle(p.muted).frame(height: 32).serviceDesignMetric("field.model")
            } else {
                HStack(spacing: 7) {
                    if manualModelEntry && !isAccount {
                        TranslationServiceField(title: "Model ID", text: $editor.configuration.model,
                                                placeholder: "Enter the exact model ID", invalid: editor.fieldErrors[.model] != nil,
                                                onFocusChanged: { if $0 { editor.hideKey() } }, focusRequest: focusRequest(for: .model))
                            .disabled(!editor.canConfigureModel)
                            .serviceDesignMetric("field.model")
                    } else {
                        Button { editor.hideKey(); popup = .models } label: {
                            HStack(spacing: 8) {
                                Text(isAccount ? accountModelName : editor.configuration.model.isEmpty
                                     ? L10n.string("Choose a model") : editor.configuration.model)
                                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(editor.configuration.model.isEmpty ? p.muted : p.ink)
                                Spacer(minLength: 3)
                                Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(p.muted)
                            }
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(p.fill, in: RoundedRectangle(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(p.line.opacity(0.34), lineWidth: 1) }
                        }
                        .buttonStyle(LumaxHoverButtonStyle())
                        .disabled(isAccount ? editor.models.isEmpty : !editor.canConfigureModel)
                        .focusable().focused($focusedAction, equals: .model)
                        .accessibilityLabel(L10n.string("Show model list"))
                        .accessibilityValue(editor.configuration.model)
                        .translationServicePopupAnchor(Popup.models.rawValue).serviceDesignMetric("field.model")
                    }
                    Button {
                        if editor.catalogState == .loading {
                            openCatalogWhenReady = false; editor.cancelModelLoading()
                        } else { loadModels() }
                    } label: {
                        HStack(spacing: 5) {
                            if editor.catalogState == .loading { ProgressView().controlSize(.mini) }
                            else if editor.catalogState == .loaded { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                            Text(L10n.string(editor.catalogState == .loading ? "Cancel" : editor.catalogState == .loaded ? "Refresh" : "Get models"))
                        }
                    }
                    .buttonStyle(TranslationServiceButtonStyle(kind: .soft, minimumWidth: 82))
                    .disabled(isAccount ? (editor.catalogState != .loading && (editor.codex.status != .signedIn || editor.codex.isBusy)) : !editor.canConfigureModel)
                    .accessibilityLabel(L10n.string(editor.catalogState == .loading ? "Cancel model loading" : "Get models"))
                }
                HStack(alignment: .top, spacing: 10) {
                    TranslationServiceHint(text: modelHint, error: editor.fieldErrors[.model] != nil || editor.catalogState == .failed || editor.catalogState == .empty)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !isAccount && editor.canConfigureModel {
                        Button(L10n.string(manualModelEntry ? "Choose from model list" : "Enter model ID manually")) {
                            editor.hideKey(); focusedAction = nil
                            manualModelEntry.toggle()
                            if manualModelEntry { requestedField = .model; fieldFocusRevision &+= 1 }
                            else { popup = .models }
                        }
                        .font(.system(size: 10)).foregroundStyle(p.accent).fixedSize()
                        .buttonStyle(LumaxHoverButtonStyle())
                    }
                }
            }
        }.id(TranslationServiceEditor.Field.model)
    }
    private var accountModelName: String {
        guard editor.codexModelSelectionIsValid else { return L10n.string("Choose an account model") }
        return editor.models.first(where: { $0.id == editor.configuration.model })?.name ?? editor.configuration.model
    }
    private var modelHint: String {
        if let setup = editor.modelSetupHint { return setup }
        if let message = editor.fieldErrors[.model] ?? editor.modelErrorMessage { return message }
        switch editor.catalogState {
        case .loaded:
            if isAccount {
                return String(format: L10n.string(editor.codexModelSelectionIsValid ? "%d models loaded · Current account model selected" : "%d models loaded · Choose a model"), editor.models.count)
            }
            return String(format: L10n.string("%d models loaded · Choose from the list"), editor.models.count)
        case .empty: return L10n.string(isAccount ? "This account returned no available models. Check your account eligibility." : "No models returned. You can enter a model ID.")
        case .failed: return L10n.string(isAccount ? "Couldn’t load models. Refresh this account’s model list." : "Couldn’t get models. Check the address and permissions, or enter an ID.")
        default: return L10n.string(isAccount ? "Sign in, load available models, then choose from the list." : "Get models to browse available IDs, or choose manual entry.")
        }
    }

    private var advancedSection: some View {
        VStack(spacing: 0) {
            Button {
                editor.hideKey(); advanced.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: advanced ? "chevron.down" : "chevron.right").font(.system(size: 10))
                    Text(L10n.string("Advanced settings")).font(.system(size: 11))
                    Spacer(minLength: 4)
                    Text(advanced ? L10n.string("Collapse") : advancedSummary)
                        .font(.system(size: 10))
                        .foregroundStyle(!advanced && editor.configuration.automaticallyTranslates ? p.accent : p.muted)
                        .lineLimit(1)
                }
                .foregroundStyle(p.muted).padding(.horizontal, 2).frame(height: 39).contentShape(Rectangle())
            }
            .buttonStyle(LumaxHoverButtonStyle())
            .accessibilityValue(L10n.string(advanced ? "Expanded" : "Collapsed"))
            if advanced {
                TranslationServiceCard {
                    HStack(alignment: .center, spacing: 15) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.string("Automatic bidirectional translation")).font(.system(size: 12))
                            Text(L10n.string(isAccount ? "Edit either side to update the other. Automatic requests use account allowance." : "Edit either side to update the other. Automatic requests may incur charges."))
                                .font(.system(size: 10)).foregroundStyle(p.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button { editor.configuration.automaticallyTranslates.toggle() } label: {
                            Circle().fill(.white).frame(width: 14, height: 14)
                                .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                                .frame(width: 27, height: 18, alignment: editor.configuration.automaticallyTranslates ? .trailing : .leading)
                                .padding(.horizontal, 2)
                                .background(editor.configuration.automaticallyTranslates ? p.accent : p.color(theme.isDark ? 0x5d6878 : 0xcad0da), in: Capsule())
                        }
                        .buttonStyle(LumaxHoverButtonStyle())
                        .accessibilityLabel(L10n.string("Automatic bidirectional translation"))
                        .accessibilityValue(L10n.string(editor.configuration.automaticallyTranslates ? "On" : "Off"))
                    }
                    .padding(.vertical, 11).frame(minHeight: 52)
                    if kind.supportsAdditionalInstructions {
                        TranslationServiceDivider()
                        TranslationServiceFormRow(title: "Additional instructions") {
                            TranslationTextEditor(text: $editor.configuration.additionalInstructions,
                                                      onEdit: { _, _ in }, onSubmit: {}, fontSize: 12, lineSpacing: 4,
                                                      accessibilityID: "service.instructions")
                                .padding(.horizontal, 5).padding(.vertical, 5).frame(height: 65)
                                .background(p.fill, in: RoundedRectangle(cornerRadius: 6))
                                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(p.line.opacity(0.34), lineWidth: 1) }
                                .overlay(alignment: .topLeading) {
                                    if editor.configuration.additionalInstructions.isEmpty {
                                        Text(L10n.string("Optional, for example: Keep technical terms in English"))
                                            .font(.system(size: 11)).foregroundStyle(p.muted)
                                            .padding(.horizontal, 10).padding(.top, 8).allowsHitTesting(false)
                                    }
                                }
                                .accessibilityLabel(L10n.string("Additional translation instructions"))
                            fieldError(.instructions)
                        }.id(TranslationServiceEditor.Field.instructions)
                    }
                    if kind == .claude {
                        TranslationServiceDivider()
                        TranslationServiceFormRow(title: "Output limit") {
                            Menu {
                                ForEach(outputTokenChoices, id: \.self) { limit in
                                    Button(String(limit)) { editor.configuration.maximumOutputTokens = limit }
                                }
                            } label: {
                                HStack {
                                    Text(String(editor.configuration.maximumOutputTokens))
                                    Spacer()
                                    Image(systemName: "chevron.down").font(.system(size: 11))
                                }
                                .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 32)
                                .background(p.fill, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).lumaxControlCursor()
                            .accessibilityLabel(L10n.string("Maximum response tokens"))
                            if let message = editor.fieldErrors[.outputLimit] { TranslationServiceHint(text: message, error: true) }
                            else { TranslationServiceHint(text: L10n.string("Overlong results are reported as incomplete and never continued automatically.")) }
                        }.id(TranslationServiceEditor.Field.outputLimit)
                    }
                }.padding(.bottom, 7)
            }
        }
    }
    private var advancedSummary: String {
        let status = L10n.string(editor.configuration.automaticallyTranslates ? "Automatic translation on" : "Automatic translation off")
        return status + (kind.supportsAdditionalInstructions ? " · " + L10n.string("Instructions optional") : "")
    }
    private var outputTokenChoices: [Int] {
        Array(Set([1_024, 2_048, 4_096, 8_192, 16_384, 32_768, 65_536, 131_072, editor.configuration.maximumOutputTokens])).sorted()
    }

    @ViewBuilder private var feedback: some View {
        if let message = editor.saveErrorMessage {
            errorCard(title: "Couldn’t save right now", message: message, retry: "Save again", action: save)
        } else if editor.testState == .failed {
            errorCard(title: "Test did not complete", message: editor.errorMessage ?? L10n.string("Translation couldn’t finish. Please try again."), retry: "Test again") { editor.test() }
        } else if editor.testState == .succeeded || editor.testState == .running && !editor.testResult.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: editor.testState == .succeeded ? "checkmark" : "ellipsis")
                    Text(L10n.string(editor.testState == .succeeded ? "Sample translation completed" : "Receiving sample translation…"))
                        .fontWeight(.medium)
                    Spacer(minLength: 4)
                    if let duration = editor.testDuration {
                        Text(String(format: L10n.string("%.1f s"), duration)).font(.system(size: 10)).foregroundStyle(p.muted).monospacedDigit()
                    }
                }.font(.system(size: 11)).foregroundStyle(p.success)
                Rectangle().fill(p.success.opacity(0.15)).frame(height: 1).padding(.top, 8).padding(.bottom, 7)
                sampleLine("English", text: TranslationServiceEditor.testSample, muted: true)
                sampleLine("Simplified Chinese", text: editor.testResult, muted: false).padding(.top, 3)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(p.successFill, in: RoundedRectangle(cornerRadius: 9))
            .padding(.top, 7).padding(.bottom, 10)
            .accessibilityElement(children: .contain)
        } else if editor.testState == .stopped {
            Text(L10n.string("Test stopped. Usage already incurred at the service may still be charged."))
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
                .background(p.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(p.line, lineWidth: 1) }
                .padding(.top, 7).padding(.bottom, 10)
        } else if let message = editor.errorMessage, editor.fieldErrors.isEmpty {
            TranslationServiceHint(text: message, error: true).padding(.vertical, 8)
        }
    }
    private func sampleLine(_ title: String, text: String, muted: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(L10n.string(title)).font(.system(size: 10)).foregroundStyle(p.muted).frame(width: 54, alignment: .leading)
            Text(text).font(.system(size: 11)).foregroundStyle(muted ? p.muted : p.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func errorCard(title: String, message: String, retry: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(L10n.string(title), systemImage: "exclamationmark.triangle").font(.system(size: 11, weight: .medium))
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            Button(L10n.string(retry), action: action).font(.system(size: 10)).foregroundStyle(p.accent).buttonStyle(LumaxHoverButtonStyle()).padding(.top, 2)
        }
        .foregroundStyle(p.error).padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.errorFill, in: RoundedRectangle(cornerRadius: 9))
        .padding(.top, 7).padding(.bottom, 10)
    }

    private var recipient: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isAccount ? "checkmark.shield" : "lock").font(.system(size: 11)).padding(.top, 2)
            Text(isAccount ? L10n.string("Translation sends text to OpenAI. Saving does not change the current service.")
                 : String(format: L10n.string("Translation sends text to %@."), editor.receiver))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10)).foregroundStyle(p.muted).lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            TranslationServiceDivider()
            HStack(spacing: 9) {
                Button {
                    editor.hideKey(); popup = nil
                    if editor.testState == .running { editor.cancelTest() } else { editor.test() }
                } label: {
                    HStack(spacing: 6) {
                        if editor.testState == .running || editor.testState == .stopping { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "play").font(.system(size: 13)) }
                        Text(L10n.string(editor.testState == .running ? "Stop test" : editor.testState == .stopping ? "Stopping…" : "Test translation"))
                    }
                }
                .buttonStyle(TranslationServiceButtonStyle(minimumWidth: 90))
                .disabled(editor.testState == .stopping || editor.testState != .running && !editor.canTest)
                .serviceDesignMetric("button.test")
                Text(L10n.string(editor.testState == .running ? "Translating the public sample…" : editor.testState == .stopping ? "Stopping…" : !editor.canTest ? "Complete the connection settings before testing." : "Public sample · May incur charges"))
                    .font(.system(size: 10)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 155, alignment: .leading)
                Spacer(minLength: 0)
                if editor.isDirty {
                    HStack(spacing: 5) {
                        Circle().fill(p.muted).frame(width: 4, height: 4)
                        Text(L10n.string("Unsaved"))
                    }.font(.system(size: 10)).foregroundStyle(p.muted).fixedSize()
                }
                Button(L10n.string("Cancel"), action: finish).buttonStyle(TranslationServiceButtonStyle(kind: .quiet))
                Button(L10n.string("Save"), action: save)
                    .buttonStyle(TranslationServiceButtonStyle(kind: .primary, minimumWidth: 68))
                    .disabled(!editor.canSave).serviceDesignMetric("button.save")
            }
            .frame(height: 60)
        }.serviceDesignMetric("footer")
    }
    private func save() {
        editor.hideKey(); popup = nil
        if editor.save() { saved() }
    }
    @ViewBuilder private func fieldError(_ field: TranslationServiceEditor.Field) -> some View {
        if let message = editor.fieldErrors[field] { TranslationServiceHint(text: message, error: true) }
    }
    private func segmented(_ choices: [(String, String)], selected: String, choose: @escaping (String) -> Void) -> some View {
        HStack(spacing: 3) {
            ForEach(choices, id: \.0) { choice in
                Button { editor.hideKey(); choose(choice.0) } label: {
                    Text(choice.1).font(.system(size: 11)).foregroundStyle(choice.0 == selected ? p.ink : p.muted)
                        .padding(.horizontal, 12).frame(height: 25)
                        .background(choice.0 == selected ? p.panel : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(LumaxHoverButtonStyle()).focusable().focused($focusedAction, equals: .serviceOption(choice.0))
                .accessibilityAddTraits(choice.0 == selected ? .isSelected : [])
            }
        }.padding(3).background(p.fill, in: RoundedRectangle(cornerRadius: 8)).fixedSize()
    }

    @ViewBuilder private func popupOverlay(_ type: Popup, anchor: CGRect, size: CGSize) -> some View {
        let width = min(type == .providers ? max(anchor.width, 440) : max(anchor.width, 310), size.width - 48)
        let height = popupHeight ?? (type == .providers ? 374 : min(CGFloat(editor.models.count) * (isAccount ? 46 : 33), 139) + 156)
        let left = max(24, min(anchor.minX, size.width - width - 24))
        let top = anchor.maxY + 6 + height <= size.height - 14 ? anchor.maxY + 6 : max(8, min(anchor.minY - height - 6, size.height - height - 8))
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { closePopup() }
            Group {
                if type == .providers {
                    TranslationServiceProviderPicker(selected: kind, choose: { value in popup = nil; changeKind(value) }, dismiss: closePopup)
                } else {
                    TranslationServiceModelPicker(models: editor.models, selected: editor.configuration.model,
                                                  account: isAccount, choose: { value in editor.chooseModel(value); manualModelEntry = false; closePopup() }, dismiss: closePopup,
                                                  manualEntry: isAccount ? nil : {
                        popup = nil; focusedAction = nil; manualModelEntry = true
                        requestedField = .model; fieldFocusRevision &+= 1
                    }, loadModels: isAccount ? nil : { loadModels() })
                }
            }
            .frame(width: width)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { popupHeight = $0 }
            .offset(x: left, y: top)
        }
        .accessibilityElement(children: .contain)
    }
    private func loadModels() {
        editor.hideKey(); popup = nil; focusedAction = nil
        manualModelEntry = false; openCatalogWhenReady = true
        editor.fetchModels()
    }
    private func closePopup() {
        let previous = popup
        popup = nil
        focusedAction = previous == .providers ? .provider : .model
    }
    private func focusRequest(for field: TranslationServiceEditor.Field) -> Int {
        requestedField == field ? fieldFocusRevision : 0
    }
    private func moveKeyFocus(backward: Bool) {
        editor.hideKey()
        focusedAction = nil
        if backward {
            requestedField = .name
        } else {
            switch kind {
            case .azureTranslator: requestedField = .region
            case .deepL:
                requestedField = nil
                focusedAction = .serviceOption(DeepLAPIEndpoint(rawValue: editor.configuration.endpoint)?.rawValue ?? DeepLAPIEndpoint.free.rawValue)
            case .qwenMT:
                requestedField = nil
                focusedAction = .serviceOption(qwenRegion.isEmpty ? QwenMTEndpoint.beijing.rawValue : qwenRegion)
            case .tencentTranslation:
                requestedField = nil
                focusedAction = .serviceOption(TencentTranslationEndpoint(rawValue: editor.configuration.endpoint)?.rawValue ?? TencentTranslationEndpoint.guangzhou.rawValue)
            default: requestedField = .endpoint
            }
        }
        fieldFocusRevision &+= 1
    }
}
