import AppKit
import Observation
import SwiftUI

extension Notification.Name {
    static let translateXTranslationSettingsClosed = Notification.Name("TranslateXTranslationSettingsClosed")
    static let translateXTranslationSettingsObscured = Notification.Name("TranslateXTranslationSettingsObscured")
}

struct TranslationServicesSettingsView: View {
    @Environment(\.translateXTheme) private var theme
    let services: TranslationServiceStore
    var navigation: TranslationServiceNavigationCoordinator = .init()
    var onPageChanged: () -> Void = {}
    @State private var draftSession: TranslationServiceDraftSession?
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var deleteTarget: TranslationServiceConfiguration?
    @State private var discardPresented = false
    @State private var pendingExit: (@MainActor () -> Void)?
    @State private var queryDraft: TranslationAccountQueryDraft?
    @State private var hoveredRow: String?
    @FocusState private var focusedControl: String?
    @State private var testPresented = false
    @State private var testTarget: TranslationServiceConfiguration?
    @State private var checks: TranslationServiceChecksController
    @State private var accounts: TranslationAccountUsageController
    #if TRANSLATEX_VISUAL_QA
    @Environment(\.translationServiceReviewUsageState) private var reviewState
    #endif

    init(services: TranslationServiceStore,
         navigation: TranslationServiceNavigationCoordinator = .init(),
         serviceSession: TranslationServiceDraftSession? = nil,
         sharedAccounts: TranslationAccountUsageController? = nil,
         onPageChanged: @escaping () -> Void = {}) {
        self.services = services
        self.navigation = navigation
        self.onPageChanged = onPageChanged
        _draftSession = State(initialValue: serviceSession)
        _checks = State(initialValue: TranslationServiceChecksController(services: services))
        _accounts = State(initialValue: sharedAccounts ?? TranslationAccountUsageController(services: services))
    }

    private var p: TranslationServicePalette { TranslationServicePalette(theme: theme) }
    private var isConfirming: Bool { discardPresented || deleteTarget != nil || testPresented }

    var body: some View {
        Group {
            if let draftSession {
                TranslationServiceEditorView(session: draftSession, finish: returnToList, saved: didSave)
            } else if let queryDraft {
                TranslationServiceUsageView(draft: queryDraft, accounts: accounts,
                    finish: { requestExit {} }, saved: {
                        self.queryDraft = nil
                        onPageChanged()
                        showNotice("Usage query configuration saved")
                    })
                    .id(queryDraft.configuration?.id.uuidString ?? "apple")
            } else {
                serviceList
            }
        }
        .foregroundStyle(p.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(isConfirming)
        .accessibilityHidden(isConfirming)
        .overlay(alignment: .bottom) {
            if let notice {
                Label(L10n.string(notice), systemImage: "checkmark")
                    .font(.system(size: 11)).padding(.horizontal, 13).padding(.vertical, 9)
                    .foregroundStyle(p.panel).background(p.ink, in: RoundedRectangle(cornerRadius: 9))
                    .padding(.bottom, 16).allowsHitTesting(false)
            }
        }
        .overlay { confirmationOverlay }
        .onAppear {
            navigation.exitHandler = requestExit; services.usage.prune()
            #if TRANSLATEX_VISUAL_QA
            if let reviewState {
                if reviewState.opensUsagePage { openQuery(services.configurations.first { $0.id == reviewState.configurationID }) }
            }
            #endif
        }
        .onChange(of: isConfirming) { _, value in navigation.isPresentingConfirmation = value }
        .onChange(of: queryDraft?.configuration?.id) { _, _ in stopListOperations(); onPageChanged() }
        .onChange(of: draftSession?.editor.configuration.id) { _, _ in
            stopListOperations()
            onPageChanged()
        }
        .onDisappear {
            stopListOperations()
            draftSession?.close(); draftSession = nil; queryDraft = nil
            pendingExit = nil; navigation.exitHandler = nil
            navigation.isPresentingConfirmation = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .translateXTranslationSettingsClosed)) { _ in
            stopListOperations()
            draftSession?.close(); draftSession = nil
            discardPresented = false; deleteTarget = nil; pendingExit = nil
            queryDraft = nil; testPresented = false; testTarget = nil
            navigation.isPresentingConfirmation = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .translateXTranslationSettingsObscured)) { _ in
            stopListOperations()
            draftSession?.suspend()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            draftSession?.editor.hideKey()
        }

    }

    private var serviceList: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string("Translation services"))
                        .font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                        .frame(height: 28, alignment: .leading).accessibilityAddTraits(.isHeader)
                        .serviceDesignMetric("settings.pageHeading")
                    Text(L10n.string("Choose a service for typing, selection and screenshot translation."))
                        .font(.system(size: 12)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button { add() } label: { Label(L10n.string("Add service"), systemImage: "plus") }
                    .buttonStyle(TranslationServiceButtonStyle(kind: .primary))
            }
            .frame(minHeight: 46).serviceDesignMetric("list.header").padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(L10n.string("Added services"))
                        Spacer()
                        Text(String(format: L10n.string("%d services"), services.configurations.count + 1))
                    }
                    .font(.system(size: 11)).foregroundStyle(p.muted).padding(.bottom, 10)

                    VStack(spacing: 9) {
                        serviceRow(nil)
                        ForEach(services.configurations) { configuration in serviceRow(configuration) }
                    }

                    if services.configurations.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "network").font(.system(size: 22)).foregroundStyle(p.muted)
                                .frame(width: 45, height: 45).background(p.fill, in: RoundedRectangle(cornerRadius: 13))
                                .padding(.bottom, 5)
                            Text(L10n.string("Connect your preferred translation service")).font(.system(size: 13, weight: .medium))
                            Text(L10n.string("Use your API key, local model or ChatGPT account. Apple Translation is always available."))
                                .font(.system(size: 11)).foregroundStyle(p.muted).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Button { add() } label: { Label(L10n.string("Add your first service"), systemImage: "plus") }
                                .buttonStyle(TranslationServiceButtonStyle(kind: .soft)).padding(.top, 10)
                        }
                        .frame(maxWidth: .infinity).padding(.horizontal, 25).padding(.top, 32)
                    }
                    if let errorMessage { TranslationServiceHint(text: errorMessage, error: true).padding(.top, 12) }

                }
                .padding(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label(L10n.string("Keys stay in Keychain. External services receive translation text."), systemImage: "lock")
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.string("Service and data details"))
                        .foregroundStyle(p.accent).fixedSize()
                        .translateXTooltip(L10n.string("Keys stay in Keychain. Only requests sent through TSX are counted. Translation text, screenshots and full responses are not saved. Pausing statistics keeps existing data. Switching services does not send existing text. Connection tests may incur provider charges."))
                }.font(.system(size: 10)).foregroundStyle(p.muted).padding(.top, 18)
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
        .translateXScrollContent()
        }
        .scrollIndicators(.automatic)
        .serviceDesignMetric("list.scroll")
    }

    private func serviceRow(_ configuration: TranslationServiceConfiguration?) -> some View {
        let selected = services.selectedID == configuration?.id
        let name = configuration?.name ?? L10n.string("Apple Translation")
        let rowID = configuration?.id.uuidString ?? "apple"
        let metricID = configuration?.kind.rawValue ?? "apple"
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    serviceIdentity(configuration).frame(minWidth: 170)
                    accountSummary(configuration)
                        .serviceDesignMetric("list.\(metricID).balance")
                        .frame(minWidth: 146, alignment: .leading)
                    serviceActions(configuration)
                        .frame(width: 205, alignment: .trailing)
                }.frame(minHeight: 50)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        serviceIdentity(configuration)
                        accountSummary(configuration)
                            .serviceDesignMetric("list.\(metricID).balance")
                    }
                    serviceActions(configuration).frame(maxWidth: .infinity, alignment: .trailing)
                }.padding(.vertical, 4)
            }
            if let configuration, let editor = checks.editor(for: configuration.id),
               editor.testState == .failed, let message = editor.errorMessage {
                TranslationServiceHint(text: message, error: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13).frame(minHeight: 78)
        .background(selected ? p.accentSoft.opacity(0.45) : p.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? p.accent : p.line, lineWidth: selected ? 2 : 1).allowsHitTesting(false) }
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onHover { hoveredRow = $0 ? rowID : (hoveredRow == rowID ? nil : hoveredRow) }
        .focusable().focused($focusedControl, equals: rowID + ".row").focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .serviceDesignMetric("list.\(metricID)")
    }

    private func serviceIdentity(_ configuration: TranslationServiceConfiguration?) -> some View {
        let name = configuration?.name ?? L10n.string("Apple Translation")
        let metricID = configuration?.kind.rawValue ?? "apple"
        return HStack(spacing: 10) {
            TranslationServiceProviderMark(kind: configuration?.kind, size: 32)
                .serviceDesignMetric("list.\(metricID).icon")
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .translateXTooltip(name).serviceDesignMetric("list.\(metricID).name")
                if let url = configuration?.websiteURL {
                    Link(destination: url) {
                        Text(url.host ?? L10n.string("Service website")).lineLimit(1).truncationMode(.middle)
                    }.font(.system(size: 11)).foregroundStyle(p.accent)
                        .translateXTooltip(url.absoluteString)
                        .accessibilityLabel(String(format: L10n.string("Open website for %@"), name))
                } else {
                    Text(configuration.map { $0.model.isEmpty ? $0.kind.settingsName : $0.model }
                         ?? L10n.string("Translates on this Mac"))
                        .font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func serviceActions(_ configuration: TranslationServiceConfiguration?) -> some View {
        let selected = services.selectedID == configuration?.id
        let name = configuration?.name ?? L10n.string("Apple Translation")
        let rowID = configuration?.id.uuidString ?? "apple"
        let metricID = configuration?.kind.rawValue ?? "apple"
        return HStack(spacing: 5) {
            Button { select(configuration?.id) } label: {
                ServiceListSelectionGlyph(selected: selected)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }
            .buttonStyle(ServiceListStartStyle()).disabled(selected)
            .opacity(actionsVisible(rowID) ? 1 : 0).allowsHitTesting(actionsVisible(rowID))
            .focusable().focused($focusedControl, equals: rowID + ".start")
            .translateXTooltip(L10n.string(selected ? "In use" : "Switch"))
            .accessibilityLabel(selected ? L10n.string("In use") : String(format: L10n.string("Use %@ for translation"), name))
            .serviceDesignMetric("list.\(metricID).use")
            if let configuration {
                rowAction("Edit", symbol: "pencil", rowID: rowID) { edit(configuration) }
                    .serviceDesignMetric("list.\(metricID).edit")
                rowAction("Copy configuration", symbol: "square.on.square", rowID: rowID) { duplicate(configuration) }
                    .serviceDesignMetric("list.\(metricID).copy")
                checkButton(configuration, rowID: rowID)
            }
            rowAction("Configure usage query", symbol: "chart.xyaxis.line", rowID: rowID) { openQuery(configuration) }
                .accessibilityLabel(String(format: L10n.string("Configure usage query for %@"), name))
                .serviceDesignMetric("list.\(metricID).usage")
            if let configuration {
                rowAction("Delete service", symbol: "trash", rowID: rowID, destructive: true) { deleteTarget = configuration }
                    .serviceDesignMetric("list.\(metricID).delete")
            }
        }.fixedSize().serviceDesignMetric("list.\(metricID).actions")
    }

    private func actionsVisible(_ rowID: String) -> Bool {
        #if TRANSLATEX_VISUAL_QA
        if reviewState?.hoveredID?.uuidString == rowID { return true }
        #endif
        return hoveredRow == rowID || focusedControl?.hasPrefix(rowID + ".") == true
    }

    private func rowAction(_ title: String, symbol: String, rowID: String, destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(TranslationServiceIconButtonStyle(size: 30, destructive: destructive))
            .opacity(actionsVisible(rowID) ? 1 : 0)
            .allowsHitTesting(actionsVisible(rowID))
            .focusable().focused($focusedControl, equals: rowID + "." + title)
            .translateXTooltip(L10n.string(title)).accessibilityLabel(L10n.string(title))
    }

    private func checkButton(_ configuration: TranslationServiceConfiguration, rowID: String) -> some View {
        let state = checks.editor(for: configuration.id)?.testState
        let title = state == .running ? "Stop test" : state == .stopping ? "Stopping" : "Test connection"
        let history = services.sampleTestOutcome(for: configuration)
        let tooltip = L10n.string(title) + (history.map { " · " + L10n.string($0 == .succeeded ? "Last sample test passed" : "Last sample test failed") } ?? "")
        return Button {
            if state == .running { checks.toggle(configuration) } else { testTarget = configuration; testPresented = true }
        } label: {
            if state == .running || state == .stopping { ProgressView().controlSize(.mini) }
            else { Image(systemName: "waveform.path.ecg") }
        }
        .buttonStyle(TranslationServiceIconButtonStyle(size: 30)).focusable().focused($focusedControl, equals: rowID + ".check")
        .opacity(actionsVisible(rowID) ? 1 : 0).allowsHitTesting(actionsVisible(rowID))
        .disabled(state == .stopping || !checks.canStart(configuration.id))
        .translateXTooltip(tooltip).accessibilityLabel(L10n.string(title))
        .serviceDesignMetric("list.\(configuration.kind.rawValue).check")
    }

    @ViewBuilder private func accountSummary(_ configuration: TranslationServiceConfiguration?) -> some View {
        if let configuration, TranslationAccountUsageController.supports(configuration),
           services.accountQueryPreferences.preferences(for: configuration.id).enabled {
            let state = accountState(configuration)
            HStack(spacing: 5) {
                Text(L10n.string(configuration.kind == .deepL ? "Remaining" : "Balance"))
                    .foregroundStyle(p.muted)
                Group {
                    if let balances = state.snapshot?.balances, !balances.isEmpty {
                        Text(balances.map { TranslationUsagePresentation.decimal($0.total) + " " + $0.currency }.joined(separator: " · "))
                            .foregroundStyle(p.accent)
                    } else if let snapshot = state.snapshot, let used = snapshot.usedCharacters {
                        Text(snapshot.hasUnlimitedCharacters ? L10n.string("Unlimited") :
                             snapshot.characterLimit.map { TranslationUsagePresentation.number(max(0, $0 - used)) } ?? "—")
                    } else {
                        Text(L10n.string(state.isLoading ? "Querying" : state.errorMessage != nil ? "Query failed" : "Not queried"))
                    }
                }.fontWeight(.medium).lineLimit(1)
                Button { accounts.refresh(configuration) } label: {
                    Group {
                        if state.isLoading { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .medium)) }
                    }.frame(width: 22, height: 24)
                }
                .buttonStyle(TranslateXTextButtonStyle()).disabled(state.isLoading)
                .focusable().focused($focusedControl, equals: configuration.id.uuidString + ".refresh")
                .translateXTooltip(state.errorMessage ?? accountDetail(state.snapshot))
                .accessibilityLabel(L10n.string("Refresh account allowance"))
                .serviceDesignMetric("list.\(configuration.kind.rawValue).refresh")
            }.font(.system(size: 11)).fixedSize(horizontal: true, vertical: false)
        } else if configuration == nil {
            Text(L10n.string("No account needed · Local translation"))
                .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize()
        } else { Color.clear.frame(width: 0, height: 24).accessibilityHidden(true) }
    }

    private func accountState(_ configuration: TranslationServiceConfiguration) -> TranslationAccountUsageController.State {
        #if TRANSLATEX_VISUAL_QA
        if let reviewState, reviewState.configurationID == configuration.id, let snapshot = reviewState.snapshot {
            return .init(snapshot: snapshot)
        }
        #endif
        return accounts.state(for: configuration.id)
    }

    private func accountDetail(_ snapshot: TranslationAccountUsageSnapshot?) -> String {
        guard let snapshot else { return L10n.string("Service-reported account allowance") }
        var lines = snapshot.balances.flatMap { balance -> [String] in
            var values = ["\(TranslationUsagePresentation.decimal(balance.total)) \(balance.currency)"]
            if let granted = balance.granted {
                values.append(L10n.string("Granted balance") + ": " + TranslationUsagePresentation.decimal(granted) + " " + balance.currency)
            }
            if let toppedUp = balance.toppedUp {
                values.append(L10n.string("Topped-up balance") + ": " + TranslationUsagePresentation.decimal(toppedUp) + " " + balance.currency)
            }
            return values
        }
        if let used = snapshot.usedCharacters {
            lines.append(L10n.string("Characters") + ": " + TranslationUsagePresentation.number(used)
                         + " / " + (snapshot.characterLimit.map(TranslationUsagePresentation.number) ?? L10n.string("Unlimited")))
        }
        lines.append(String(format: L10n.string("Updated %@"), snapshot.fetchedAt.formatted(.dateTime.locale(L10n.currentLocale))))
        lines.append(L10n.string("Account values may include other apps and may be delayed. They are not this Mac’s spending history."))
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private var confirmationOverlay: some View {
        if isConfirming {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.17).contentShape(Rectangle()).onTapGesture {}
                    TranslationServiceConfirmation(
                        title: discardPresented ? L10n.string("Discard unsaved changes?") : testPresented ? L10n.string("Test connection?") : String(format: L10n.string("Delete %@?"), deleteTarget?.name ?? ""),
                        message: discardPresented ? discardMessage : testPresented ? L10n.string("Send a short sample to check availability. A small charge may apply.") : deletionMessage,
                        cancelTitle: discardPresented ? L10n.string("Keep editing") : L10n.string("Cancel"),
                        confirmTitle: discardPresented ? L10n.string("Discard changes") : testPresented ? L10n.string("Start connection test") : L10n.string("Delete service"),
                        destructive: !testPresented,
                        cancel: { discardPresented = false; pendingExit = nil; deleteTarget = nil; testPresented = false; testTarget = nil },
                        confirm: confirmAction)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private var discardMessage: String {
        L10n.string(queryDraft == nil
            ? "The text and key drafts entered here will be cleared. Saved services stay unchanged."
            : "Unsaved query preferences will be discarded. Existing statistics stay unchanged.")
    }

    private var deletionMessage: String {
        guard let target = deleteTarget else { return "" }
        let message = services.selectedID == target.id
            ? L10n.string("Apple Translation will be used after deletion. Existing text will not be sent again.")
            : L10n.string(target.kind == .codex ? "Only this configuration will be deleted. The shared ChatGPT account stays signed in." : "This configuration and its saved API key will be deleted.")
        return message + "\n" + L10n.string("Historical usage statistics will be kept.")
    }
    private func confirmAction() {
        if testPresented {
            if let target = testTarget { checks.toggle(target) }
            testTarget = nil
            testPresented = false
        } else if discardPresented {
            let action = pendingExit
            pendingExit = nil; discardPresented = false
            draftSession?.close(); draftSession = nil; queryDraft = nil
            onPageChanged()
            action?()
        } else if let target = deleteTarget {
            do {
                checks.cancel(target.id); accounts.cancel(target.id)
                try services.remove(target.id); errorMessage = nil; deleteTarget = nil
                if queryDraft?.configuration?.id == target.id { queryDraft = nil }
            }
            catch { errorMessage = TranslationServiceEditor.safeMessage(for: error); deleteTarget = nil }
        }
    }
    private func requestExit(_ perform: @escaping @MainActor () -> Void) {
        if draftSession?.hasUnsavedChanges == true || queryDraft?.hasUnsavedChanges == true {
            pendingExit = perform; discardPresented = true
        } else {
            draftSession?.close(); draftSession = nil; queryDraft = nil
            onPageChanged()
            perform()
        }
    }
    private func stopListOperations() { checks.cancelAll(); accounts.cancelManualQueries() }
    private func openQuery(_ configuration: TranslationServiceConfiguration?) {
        stopListOperations()
        queryDraft = TranslationAccountQueryDraft(configuration: configuration, services: services)
        onPageChanged()
    }
    private func showNotice(_ message: String) {
        notice = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if notice == message { notice = nil }
        }
    }
    private func duplicate(_ configuration: TranslationServiceConfiguration) {
        var copy = configuration
        copy.id = UUID()
        copy.name = String(format: L10n.string("%@ copy"), configuration.name)
        if copy.name.count > 120 {
            copy.name = String(format: L10n.string("%@ copy"), String(configuration.name.prefix(100)))
        }
        errorMessage = nil
        draftSession = TranslationServiceDraftSession(services: services, configuration: copy)
        notice = configuration.kind == .codex ? "Configuration copied · Uses the shared ChatGPT account" : "Configuration copied · Add an API key if required"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            notice = nil
        }
    }
    private func returnToList() { requestExit {} }
    private func add() { errorMessage = nil; draftSession = TranslationServiceDraftSession(services: services) }
    private func edit(_ configuration: TranslationServiceConfiguration) {
        errorMessage = nil
        draftSession = TranslationServiceDraftSession(services: services, configuration: configuration)
    }
    private func didSave() {
        draftSession?.close(); draftSession = nil
        notice = "Configuration saved · Current service unchanged"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            notice = nil
        }
    }
    private func select(_ id: UUID?) {
        do { try services.select(id); errorMessage = nil }
        catch { errorMessage = TranslationServiceEditor.safeMessage(for: error) }
    }
}

struct TranslationServiceConfirmation: View {
    @Environment(\.translateXTheme) private var theme
    let title: String
    let message: String
    let cancelTitle: String
    let confirmTitle: String
    var destructive = true
    let cancel: () -> Void
    let confirm: () -> Void
    @FocusState private var focusedButton: Choice?
    private enum Choice { case cancel, confirm }
    var body: some View {
        let p = TranslationServicePalette(theme: theme)
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "info.circle").font(.system(size: 18)).foregroundStyle(p.muted)
                .frame(width: 36, height: 36).background(p.fill, in: RoundedRectangle(cornerRadius: 11)).padding(.bottom, 12)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            Text(message).font(.system(size: 11)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(cancelTitle, action: cancel).buttonStyle(TranslationServiceButtonStyle())
                    .focusable().focused($focusedButton, equals: .cancel)
                Button(confirmTitle, action: confirm).buttonStyle(TranslationServiceButtonStyle(kind: destructive ? .danger : .primary))
                    .focusable().focused($focusedButton, equals: .confirm)
            }.padding(.top, 20)
        }
        .padding(23).frame(width: 332)
        .background(p.popover, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(p.line, lineWidth: 1) }
        .shadow(color: .black.opacity(0.2), radius: 22, y: 10)
        .task { focusedButton = .cancel }
        .onKeyPress(.tab) { focusedButton = focusedButton == .cancel ? .confirm : .cancel; return .handled }
        .onKeyPress(.return) { if focusedButton == .confirm { confirm() } else { cancel() }; return .handled }
        .onExitCommand(perform: cancel)
        .accessibilityElement(children: .contain)
    }
}

private struct ServiceListSelectionGlyph: Shape {
    let selected: Bool

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 14
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 7) * scale, y: rect.midY + (y - 7) * scale)
        }
        return Path { path in
            if selected {
                path.move(to: point(2.3, 7.2))
                path.addLine(to: point(5.7, 10.4))
                path.addLine(to: point(11.9, 3.6))
            } else {
                let top = point(2.8, 1.4)
                let tip = point(12.1, 7)
                let bottom = point(2.8, 12.6)
                let radius = 1.1 * scale
                path.move(to: point(2.8, 7))
                path.addArc(tangent1End: top, tangent2End: tip, radius: radius)
                path.addArc(tangent1End: tip, tangent2End: bottom, radius: radius)
                path.addArc(tangent1End: bottom, tangent2End: top, radius: radius)
                path.closeSubpath()
            }
        }
    }
}

private struct ServiceListStartStyle: ButtonStyle {
    @Environment(\.translateXTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        let p = TranslationServicePalette(theme: theme)
        configuration.label.font(.system(size: 14)).frame(width: 30, height: 30)
            .foregroundStyle(enabled ? p.accent : p.muted)
            .background(enabled && hovered ? p.accentSoft : p.panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(p.line) }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(!enabled ? 0.48 : configuration.isPressed ? 0.7 : 1)
            .onHover { hovered = $0 }.translateXControlCursor()
    }
}

struct ServiceTestDate {
    static func compact(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.currentLocale) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        if calendar.isDate(date, inSameDayAs: now) { return String(format: L10n.string("Today %@"), formatter.string(from: date)) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(format: L10n.string("Yesterday %@"), formatter.string(from: date))
        }
        formatter.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMd HHmm" : "yMMMd HHmm")
        return formatter.string(from: date)
    }
    static func detail(_ date: Date, outcome: TranslationServiceStore.SampleTestOutcome) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.currentLocale; formatter.dateStyle = .full; formatter.timeStyle = .medium
        return formatter.string(from: date) + "\n" + L10n.string(outcome == .succeeded ? "Last sample test passed" : "Last sample test failed") + "\n" + L10n.string("Historical sample result, not live service availability.")
    }
}
