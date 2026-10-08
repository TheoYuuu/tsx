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
    @State private var usagePage: String?
    @State private var hoveredRow: String?
    @FocusState private var focusedControl: String?
    @State private var clearAllPresented = false
    @State private var checks: TranslationServiceChecksController
    @State private var accounts: TranslationAccountUsageController
    #if TRANSLATEX_VISUAL_QA
    @Environment(\.translationServiceReviewUsageState) private var reviewState
    #endif

    init(services: TranslationServiceStore,
         navigation: TranslationServiceNavigationCoordinator = .init(),
         serviceSession: TranslationServiceDraftSession? = nil,
         onPageChanged: @escaping () -> Void = {}) {
        self.services = services
        self.navigation = navigation
        self.onPageChanged = onPageChanged
        _draftSession = State(initialValue: serviceSession)
        _checks = State(initialValue: TranslationServiceChecksController(services: services))
        _accounts = State(initialValue: TranslationAccountUsageController(services: services))
    }

    private var p: TranslationServicePalette { TranslationServicePalette(theme: theme) }
    private var isConfirming: Bool { discardPresented || deleteTarget != nil }

    var body: some View {
        Group {
            if let draftSession {
                TranslationServiceEditorView(session: draftSession, finish: returnToList, saved: didSave)
            } else if let usagePage {
                TranslationServiceUsageView(
                    configuration: services.configurations.first { $0.id.uuidString == usagePage },
                    usage: services.usage, finish: { self.usagePage = nil })
                    .id(usagePage)
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
            if let reviewState, reviewState.opensUsagePage { usagePage = reviewState.configurationID.uuidString }
            #endif
        }
        .onChange(of: isConfirming) { _, value in navigation.isPresentingConfirmation = value }
        .onChange(of: usagePage) { _, _ in stopListOperations(); onPageChanged() }
        .onChange(of: draftSession?.editor.configuration.id) { _, _ in
            stopListOperations()
            onPageChanged()
        }
        .onDisappear {
            stopListOperations()
            draftSession?.close(); draftSession = nil
            pendingExit = nil; navigation.exitHandler = nil
            navigation.isPresentingConfirmation = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .translateXTranslationSettingsClosed)) { _ in
            stopListOperations()
            draftSession?.close(); draftSession = nil
            discardPresented = false; deleteTarget = nil; pendingExit = nil
            navigation.isPresentingConfirmation = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .translateXTranslationSettingsObscured)) { _ in
            stopListOperations()
            draftSession?.suspend()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            draftSession?.editor.hideKey()
        }
        .alert(L10n.string("Clear all local usage records?"), isPresented: $clearAllPresented) {
            Button(L10n.string("Cancel"), role: .cancel) {}
            Button(L10n.string("Clear records"), role: .destructive) { services.usage.clearAll() }
        } message: {
            Text(L10n.string("This removes local statistics for every service. Configurations and account allowances stay unchanged."))
        }
    }

    private var serviceList: some View {
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
            .frame(minHeight: 46).serviceDesignMetric("list.header").padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(L10n.string("Added services"))
                        Spacer()
                        Text(String(format: L10n.string("%d services"), services.configurations.count + 1))
                    }
                    .font(.system(size: 11)).foregroundStyle(p.muted).padding(.bottom, 10)

                    VStack(spacing: 10) {
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
                    } else {
                        Label(L10n.string("Switching services does not automatically send existing text."), systemImage: "info.circle")
                            .font(.system(size: 10)).foregroundStyle(p.muted)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 13)
                    }
                    if let errorMessage { TranslationServiceHint(text: errorMessage, error: true).padding(.top, 12) }
                    recordingPreferences.padding(.top, 20)
                }
                .padding(1)
                .translationServiceScrollContent()
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity, alignment: .top)
            .serviceDesignMetric("list.scroll")
            VStack(spacing: 0) {
                TranslationServiceDivider()
                Label(L10n.string("Keys stay in this Mac’s Keychain. External services receive the text you translate."), systemImage: "lock")
                    .font(.system(size: 10)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            }
        }
        .padding(.horizontal, 36).padding(.top, 17)
    }

    private func serviceRow(_ configuration: TranslationServiceConfiguration?) -> some View {
        let selected = services.selectedID == configuration?.id
        let name = configuration?.name ?? L10n.string("Apple Translation")
        let rowID = configuration?.id.uuidString ?? "apple"
        let metricID = configuration?.kind.rawValue ?? "apple"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TranslationServiceProviderMark(kind: configuration?.kind, size: 32)
                    .serviceDesignMetric("list.\(metricID).icon")
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1).translateXTooltip(name)
                        if let configuration { testIndicator(configuration) }
                    }.serviceDesignMetric("list.\(metricID).name")
                    if let url = configuration?.websiteURL {
                        Link(destination: url) {
                            Text(url.host ?? L10n.string("Service website")).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                            .font(.system(size: 11)).foregroundStyle(p.accent)
                            .translateXTooltip(url.absoluteString)
                            .accessibilityLabel(String(format: L10n.string("Open website for %@"), name))
                    } else {
                        Text(configuration.map { $0.model.isEmpty ? $0.kind.settingsName : $0.model }
                             ?? L10n.string("Translates on this Mac"))
                            .font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                accountSummary(configuration)
                    .frame(width: 96, alignment: .trailing)
                    .serviceDesignMetric("list.\(metricID).balance")
                HStack(spacing: 3) {
                    if selected {
                        Label(L10n.string("In use"), systemImage: "checkmark")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(p.muted)
                            .frame(width: 74, height: 30)
                            .background(p.fill, in: RoundedRectangle(cornerRadius: 7))
                            .serviceDesignMetric("list.\(metricID).current")
                    } else {
                        Button { select(configuration?.id) } label: {
                            Label(L10n.string("Start"), systemImage: "play")
                        }
                        .buttonStyle(ServiceListStartStyle()).focusable().focused($focusedControl, equals: rowID + ".start")
                        .accessibilityLabel(String(format: L10n.string("Use %@ for translation"), name))
                        .serviceDesignMetric("list.\(metricID).use")
                    }
                    if let configuration {
                        rowAction("Edit", symbol: "square.and.pencil", rowID: rowID) { edit(configuration) }
                            .serviceDesignMetric("list.\(metricID).edit")
                        rowAction("Copy configuration", symbol: "square.on.square", rowID: rowID) { duplicate(configuration) }
                            .serviceDesignMetric("list.\(metricID).copy")
                        checkButton(configuration, rowID: rowID)
                    }
                    rowAction("Usage", symbol: "chart.xyaxis.line", rowID: rowID) { usagePage = rowID }
                        .accessibilityLabel(String(format: L10n.string("Usage for %@"), name))
                        .serviceDesignMetric("list.\(metricID).usage")
                    if let configuration {
                        rowAction("Delete service…", symbol: "trash", rowID: rowID, destructive: true) { deleteTarget = configuration }
                            .serviceDesignMetric("list.\(metricID).delete")
                    }
                }
                .frame(width: 229, alignment: .trailing)
                .opacity(actionsVisible(rowID) ? 1 : 0)
                .allowsHitTesting(actionsVisible(rowID))
                .serviceDesignMetric("list.\(metricID).actions")
            }
            .frame(minHeight: 70)
            if let configuration, let editor = checks.editor(for: configuration.id),
               editor.testState == .failed, let message = editor.errorMessage {
                TranslationServiceHint(text: message, error: true)
            }
        }
        .padding(12)
        .background(selected ? p.accentSoft.opacity(0.45) : p.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? p.accent : p.line, lineWidth: selected ? 1.5 : 1).allowsHitTesting(false) }
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onHover { hoveredRow = $0 ? rowID : (hoveredRow == rowID ? nil : hoveredRow) }
        .focusable().focused($focusedControl, equals: rowID + ".row").focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .serviceDesignMetric("list.\(metricID)")
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
            .buttonStyle(TranslationServiceIconButtonStyle(destructive: destructive))
            .focusable().focused($focusedControl, equals: rowID + "." + title)
            .translateXTooltip(L10n.string(title)).accessibilityLabel(L10n.string(title))
    }

    private func checkButton(_ configuration: TranslationServiceConfiguration, rowID: String) -> some View {
        let state = checks.editor(for: configuration.id)?.testState
        let title = state == .running ? "Stop test" : state == .stopping ? "Stopping…" : "Check connectivity"
        return Button { checks.toggle(configuration) } label: {
            if state == .running || state == .stopping { ProgressView().controlSize(.mini) }
            else { Image(systemName: "waveform.path.ecg") }
        }
        .buttonStyle(TranslationServiceIconButtonStyle()).focusable().focused($focusedControl, equals: rowID + ".check")
        .disabled(state == .stopping || !checks.canStart(configuration.id))
        .translateXTooltip(L10n.string(title)).accessibilityLabel(L10n.string(title))
        .accessibilityHint(L10n.string("Sends a fixed translation sample. May incur charges."))
        .serviceDesignMetric("list.\(configuration.kind.rawValue).check")
    }

    @ViewBuilder private func accountSummary(_ configuration: TranslationServiceConfiguration?) -> some View {
        if let configuration, TranslationAccountUsageController.supports(configuration) {
            let state = accountState(configuration)
            VStack(alignment: .trailing, spacing: 3) {
                if let snapshot = state.snapshot, let balance = snapshot.balances.first {
                    HStack(spacing: 3) {
                        Text(L10n.string("Balance"))
                        Text(TranslationUsagePresentation.decimal(balance.total)).fontWeight(.bold).foregroundStyle(p.accent)
                        Text(balance.currency)
                    }.lineLimit(1).minimumScaleFactor(0.85)
                } else if let snapshot = state.snapshot, let used = snapshot.usedCharacters {
                    HStack(spacing: 3) {
                        Text(L10n.string("Remaining"))
                        Text(snapshot.hasUnlimitedCharacters ? L10n.string("Unlimited") :
                             snapshot.characterLimit.map { TranslationUsagePresentation.number(max(0, $0 - used)) } ?? "—")
                            .fontWeight(.bold).foregroundStyle(p.accent)
                    }.lineLimit(1).minimumScaleFactor(0.85)
                } else { Text("—").foregroundStyle(p.muted) }
                HStack(spacing: 3) {
                    Text(L10n.string(state.errorMessage != nil ? "Refresh failed" : state.isLoading ? "Fetching…" : state.snapshot == nil ? "Not queried" : "Updated"))
                        .foregroundStyle(state.errorMessage != nil ? p.error : p.muted)
                    Button { accounts.refresh(configuration) } label: {
                        if state.isLoading { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                    }
                    .buttonStyle(TranslationServiceIconButtonStyle(size: 26)).disabled(state.isLoading)
                    .focusable().focused($focusedControl, equals: configuration.id.uuidString + ".refresh")
                    .translateXTooltip(state.errorMessage ?? L10n.string("Refresh account allowance"))
                    .accessibilityLabel(L10n.string("Refresh account allowance"))
                    .serviceDesignMetric("list.\(configuration.kind.rawValue).refresh")
                }
            }
            .font(.system(size: 11)).foregroundStyle(p.muted)
            .translateXTooltip(accountDetail(state.snapshot))
        } else if configuration == nil {
            VStack(alignment: .trailing, spacing: 8) {
                Text(L10n.string("No account needed"))
                Text(L10n.string("Local translation"))
            }.font(.system(size: 11)).foregroundStyle(p.muted)
        } else { Color.clear.frame(height: 45).accessibilityHidden(true) }
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

    private var recordingPreferences: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { services.usage.isEnabled }, set: { services.usage.setEnabled($0) })) {
                Text(L10n.string("Record local usage")).font(.system(size: 11, weight: .medium))
            }.toggleStyle(.switch).controlSize(.small)
            Text(L10n.string("Keep up to 10,000 records from the last 30 days on this Mac, without translation text. Turning this off stops new records."))
                .font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                Text(L10n.string("Checks send a fixed translation sample and may incur charges."))
                    .font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L10n.string("Clear all records…")) { clearAllPresented = true }
                    .font(.system(size: 10)).foregroundStyle(p.muted).buttonStyle(TranslateXHoverButtonStyle())
                    .disabled(services.usage.records.isEmpty).fixedSize()
            }
        }.padding(14).background(p.fill.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func testIndicator(_ configuration: TranslationServiceConfiguration) -> some View {
        if checks.editor(for: configuration.id)?.testState == .running {
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        } else if services.sampleTestRecord(for: configuration.id) != nil {
            let outcome = services.sampleTestOutcome(for: configuration)
            let title = outcome == nil ? "Configuration changed · Retest needed" : outcome == .succeeded ? "Check passed" : "Check failed"
            Image(systemName: outcome == nil ? "exclamationmark.circle" : outcome == .succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 10)).foregroundStyle(outcome == nil ? p.muted : outcome == .succeeded ? p.success : p.error)
                .translateXTooltip(L10n.string(title)).accessibilityLabel(L10n.string(title))
                .serviceDesignMetric("list.\(configuration.kind.rawValue).test")
        }
    }

    @ViewBuilder private var confirmationOverlay: some View {
        if discardPresented || deleteTarget != nil {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.17).contentShape(Rectangle()).onTapGesture {}
                    TranslationServiceConfirmation(
                        title: discardPresented ? L10n.string("Discard unsaved changes?") : String(format: L10n.string("Delete %@?"), deleteTarget?.name ?? ""),
                        message: discardPresented ? L10n.string("The text and key drafts entered here will be cleared. Saved services stay unchanged.") : deletionMessage,
                        cancelTitle: discardPresented ? L10n.string("Keep editing") : L10n.string("Cancel"),
                        confirmTitle: discardPresented ? L10n.string("Discard changes") : L10n.string("Delete service"),
                        cancel: { discardPresented = false; pendingExit = nil; deleteTarget = nil },
                        confirm: confirmAction)
                }
                .frame(width: geometry.size.width, height: geometry.size.height + 103)
                .offset(y: -103)
            }
        }
    }

    private var deletionMessage: String {
        guard let target = deleteTarget else { return "" }
        let message = services.selectedID == target.id
            ? L10n.string("Apple Translation will be used after deletion. Existing text will not be sent again.")
            : L10n.string(target.kind == .codex ? "Only this configuration will be deleted. The shared ChatGPT account stays signed in." : "This configuration and its saved API key will be deleted.")
        return message + "\n" + L10n.string("This service’s local usage records will also be removed.")
    }
    private func confirmAction() {
        if discardPresented {
            let action = pendingExit
            pendingExit = nil; discardPresented = false
            draftSession?.close(); draftSession = nil
            action?()
        } else if let target = deleteTarget {
            do {
                checks.cancel(target.id); accounts.cancel(target.id)
                try services.remove(target.id); errorMessage = nil; deleteTarget = nil
                if usagePage == target.id.uuidString { usagePage = nil }
            }
            catch { errorMessage = TranslationServiceEditor.safeMessage(for: error); deleteTarget = nil }
        }
    }
    private func requestExit(_ perform: @escaping @MainActor () -> Void) {
        if draftSession?.hasUnsavedChanges == true {
            pendingExit = perform; discardPresented = true
        } else {
            draftSession?.close(); draftSession = nil; usagePage = nil
            perform()
        }
    }
    private func stopListOperations() { checks.cancelAll(); accounts.cancelAll() }
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
                Button(confirmTitle, action: confirm).buttonStyle(TranslationServiceButtonStyle(kind: .danger))
                    .focusable().focused($focusedButton, equals: .confirm)
            }.padding(.top, 20)
        }
        .padding(23).frame(width: 332)
        .background(p.popover, in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(p.line, lineWidth: 1) }
        .shadow(color: .black.opacity(0.2), radius: 22, y: 10)
        .task { focusedButton = .cancel }
        .onKeyPress(.tab) { focusedButton = focusedButton == .cancel ? .confirm : .cancel; return .handled }
        .onKeyPress(.return) { if focusedButton == .confirm { confirm() } else { cancel() }; return .handled }
        .onExitCommand(perform: cancel)
        .accessibilityElement(children: .contain)
    }
}

private struct ServiceListStartStyle: ButtonStyle {
    @Environment(\.translateXTheme) private var theme
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        let p = TranslationServicePalette(theme: theme)
        configuration.label.font(.system(size: 11, weight: .medium)).lineLimit(1)
            .frame(width: 74, height: 30).foregroundStyle(.white)
            .background(p.primary.opacity(hovered ? 0.88 : 1), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.7 : 1).onHover { hovered = $0 }.translateXControlCursor()
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
