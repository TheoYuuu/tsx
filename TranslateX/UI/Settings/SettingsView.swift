import SwiftUI

/// Stable settings navigation shared by menu commands and the settings window.
@MainActor @Observable
final class SettingsNavigation {
    var requestedTab: Int?
    func showAbout() { requestedTab = 5 }
}

struct SettingsView: View {
    @Environment(\.translateXTheme) private var theme
    @Bindable var preferences: AppPreferences
    let shortcuts: ShortcutSettings
    let permissions: PermissionStatus
    let catalog: LanguageCatalog
    let defaultTargetChanged: () -> Void
    let appearanceChanged: () -> Void
    var interfaceLanguageChanged: () -> Void = {}
    var services: TranslationServiceStore? = nil
    var serviceNavigation = TranslationServiceNavigationCoordinator()
    var updates: AppUpdateController? = nil
    var accounts: TranslationAccountUsageController? = nil
    var navigation = SettingsNavigation()
    @State var serviceSession: TranslationServiceDraftSession? = nil
    @State var tab = 0
    @State private var resetFailed = false

    private var p: TranslationServicePalette { .init(theme: theme) }
    private var showsUpdateModal: Bool { tab == 5 && updates?.releaseNotesPresentation != nil }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    WindowTrafficLights().frame(width: 58, height: 14)
                    Text("Settings").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.muted)
                    Spacer()
                }
                .padding(.horizontal, 22).frame(height: 48)
                .serviceDesignMetric("settings.titlebar")
                Rectangle().fill(p.line).frame(height: 1)
                HStack(spacing: 0) {
                    sidebar
                        .disabled(serviceNavigation.isPresentingConfirmation)
                        .accessibilityHidden(serviceNavigation.isPresentingConfirmation)
                    Rectangle().fill(p.line).frame(width: 1)
                    page.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .disabled(showsUpdateModal).accessibilityHidden(showsUpdateModal)
            if showsUpdateModal, let updates { SettingsUpdateOverlay(updates: updates) }
        }
        .foregroundStyle(p.ink)
        .background(theme.isGlass ? Color.clear : theme.isDark ? p.color(0x232833) : Color.white)
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: serviceNavigation.servicesRequestID, initial: true) { _, request in
            if request > 0, tab != 3, !showsUpdateModal { tab = 3 }
        }
        .onChange(of: navigation.requestedTab, initial: true) { _, request in
            guard let request else { return }
            selectTab(request)
            navigation.requestedTab = nil
        }
        .onChange(of: tab) { old, new in
            shortcuts.endRecording()
            if old == 3, new != 3 { serviceSession = nil }
        }
        .onChange(of: preferences.appearance) { _, _ in appearanceChanged() }
        .onChange(of: preferences.material) { _, _ in appearanceChanged() }
        .onChange(of: preferences.interfaceLanguage) { _, _ in interfaceLanguageChanged() }
        .task { permissions.refresh(); await catalog.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
        .onDisappear { shortcuts.endRecording() }
    }

    @ViewBuilder private var page: some View {
        if tab == 3, let services {
            TranslationServicesSettingsView(services: services, navigation: serviceNavigation,
                                            serviceSession: serviceSession, sharedAccounts: accounts)
        } else if tab == 4, let services {
            UsageDashboardView(store: services)
        } else if tab == 5, let updates {
            AboutSettingsView(updates: updates)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch tab {
                        case 1: shortcutSettings
                        case 2: permissionsPage
                        default: general
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("settingsContent").translateXScrollContent()
                }
                .onChange(of: tab) { _, _ in proxy.scrollTo("settingsContent", anchor: .top) }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preferences").font(.system(size: 11)).foregroundStyle(p.muted)
                .padding(.horizontal, 10).padding(.bottom, 9)
            VStack(spacing: 3) {
                tabButton("General", symbol: "gearshape", index: 0)
                if services != nil {
                    tabButton("Translation services", symbol: "globe", index: 3, compactTitle: "settings.navigation.services")
                    tabButton("Usage statistics", symbol: "chart.bar.xaxis", index: 4, compactTitle: "settings.navigation.usage", iconSize: 14)
                }
                tabButton("Shortcuts", symbol: "command.square", index: 1)
                tabButton("Permissions", symbol: "lock.shield", index: 2)
                if updates != nil { tabButton("About", symbol: "info.square", index: 5) }
            }.accessibilityElement(children: .contain).accessibilityLabel(Text("Settings categories"))
            Spacer(minLength: 16)
            HStack(spacing: 7) {
                TranslateXBrandMark(size: 18)
                Text("TSX · v\(updates?.currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 11)).foregroundStyle(p.muted)
            }.padding(.horizontal, 9)
        }
        .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 14)
        .frame(width: 184)
        .frame(maxHeight: .infinity)
        .background(p.color(theme.isDark ? 0x252d39 : 0xfafbfe).opacity(theme.isGlass ? 0.32 : 1))
        .serviceDesignMetric("settings.tabs")
    }

    private func selectTab(_ index: Int) {
        guard !showsUpdateModal || index == tab else { return }
        if tab == 3, index != tab { serviceNavigation.requestExit { tab = index } }
        else { tab = index }
    }

    private func tabButton(_ title: LocalizedStringKey, symbol: String, index: Int, compactTitle: LocalizedStringKey? = nil, iconSize: CGFloat = 16) -> some View {
        Button { selectTab(index) } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).resizable().scaledToFit()
                    .frame(width: iconSize, height: iconSize).frame(width: 20, height: 20)
                Text(compactTitle ?? title).font(.system(size: 13, weight: tab == index ? .medium : .regular))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).frame(height: 38)
        }
        .buttonStyle(SettingsNavigationButtonStyle(selected: tab == index))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(tab == index ? [.isSelected] : [])
        .accessibilityIdentifier("settings.tab.\(index)")
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupCaption("Language")
            group {
                HStack { Text("Interface language"); Spacer(); interfaceLanguagePicker }.frame(minHeight: 52)
                separator
                HStack { Text("Default target language"); Spacer(); targetLanguageMenu }.frame(minHeight: 52)
            }.font(.system(size: 13)).serviceDesignMetric("settings.interfaceLanguage")
            if !catalog.languages(for: services?.selectedConfiguration).isEmpty,
               !catalog.languages(for: services?.selectedConfiguration).contains(where: { $0.id == preferences.defaultTarget }) {
                Label(LocalizedStringKey(services?.selectedConfiguration == nil
                      ? "This language is unavailable on this Mac. Choose another target language."
                      : "This language is unavailable for the selected service. Choose another target language."), systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            groupCaption("Window and appearance").padding(.top, 16)
            group {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Translation window layout")
                        Text("Two equal panes in the main and quick translation windows.")
                            .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    segmented("Translation window layout", selection: $preferences.translationLayout,
                              choices: [(.sideBySide, "Side by side"), (.stacked, "Stacked")])
                        .fixedSize().accessibilityIdentifier("settings.translationLayout")
                }.padding(.vertical, 10).frame(minHeight: 62)
                separator
                HStack {
                    Text("Material"); Spacer()
                    segmented("Material", selection: $preferences.material, choices: [(.light, "Solid color"), (.glass, "Liquid Glass")])
                }.frame(minHeight: 52)
                separator
                HStack {
                    Text("Appearance"); Spacer()
                    segmented("Appearance", selection: $preferences.appearance,
                              choices: [(.system, "Follow System"), (.light, "Light"), (.dark, "Dark")])
                }.frame(minHeight: 52)
                separator
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Use pointing cursor")
                        Text("Show a pointing hand when hovering over interactive elements.")
                            .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Use pointing cursor", isOn: $preferences.usesPointingCursor)
                        .toggleStyle(TranslateXSwitchStyle()).accessibilityIdentifier("settings.pointingCursor")
                }.padding(.vertical, 10).frame(minHeight: 62)
            }.font(.system(size: 13))
        }
    }

    private var interfaceLanguagePicker: some View {
        LanguageMenu(label: L10n.string("Interface language"), selection: Binding(
            get: { preferences.interfaceLanguage.rawValue },
            set: { if let language = AppInterfaceLanguage(rawValue: $0) { preferences.interfaceLanguage = language } }
        ), languages: AppInterfaceLanguage.allCases.map { language in
            TranslationLanguage(id: language.rawValue, name: language == .system ? L10n.string("Follow System") : language == .english ? "English" : "简体中文")
        }, prominent: false, minimumWidth: 144)
        .accessibilityIdentifier("settings.interfaceLanguage").serviceDesignMetric("settings.interfaceLanguage.control")
    }

    private var targetLanguageMenu: some View {
        LanguageMenu(label: L10n.string("Default target language"), selection: Binding(
            get: { preferences.defaultTarget }, set: { preferences.setDefaultTarget($0); defaultTargetChanged() }
        ), languages: catalog.languages(for: services?.selectedConfiguration), prominent: false,
           enabled: !catalog.languages(for: services?.selectedConfiguration).isEmpty, minimumWidth: 144)
            .fixedSize().translateXTooltip(L10n.string("Used for new selection and screenshot translations, and when the input workspace is empty."))
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                pageHeading("Shortcuts", description: "Click a combination to change it. Esc cancels.")
                Spacer()
                Button { resetFailed = !shortcuts.resetAll() } label: {
                    Label("Restore defaults", systemImage: "arrow.counterclockwise")
                }.buttonStyle(TranslationServiceButtonStyle())
                    .disabled(!shortcuts.hasCustomizedCombinations)
                    .accessibilityIdentifier("settings.shortcuts.resetAll")
            }.padding(.bottom, 16)
            HStack {
                Text("Function"); Spacer()
                Text("Combination").frame(width: 130)
                Text("Enable").frame(width: 36)
            }.font(.system(size: 11)).foregroundStyle(p.muted).padding(.horizontal, 17).padding(.bottom, 8)
            group {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    if action != ShortcutAction.allCases.first { separator }
                    shortcutRow(action)
                }
            }
            if resetFailed {
                Text("Some shortcuts could not be restored. Check the affected shortcuts and try again.")
                    .font(.system(size: 11)).foregroundStyle(p.error).padding(.top, 10)
            }
            Text(shortcuts.recordingAction == nil
                 ? "Turning off a shortcut keeps its combination."
                 : "Waiting for keys · Esc cancels without changing the shortcut.")
                .font(.system(size: 11)).foregroundStyle(p.muted).padding(.top, 12)
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let enabled = shortcuts.isEnabled(action)
        let error = shortcuts.error(for: action)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Group {
                    switch action {
                    case .selection: TranslateXActionIcon(symbol: .selection).frame(width: 22, height: 22)
                    case .input: TranslateXActionIcon(symbol: .input).frame(width: 22, height: 22)
                    case .ocr: Image(systemName: "viewfinder").font(.system(size: 20))
                    }
                }.foregroundStyle(p.muted).frame(width: 32, height: 32)
                    .background(p.fill, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.settingsTitle).font(.system(size: 13, weight: .medium))
                    Text(enabled ? action.settingsDescription : L10n.string("Disabled · combination kept"))
                        .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                ShortcutRecorder(action: action, settings: shortcuts).frame(width: 130, height: 32)
                Toggle(action.settingsTitle, isOn: Binding(
                    get: { shortcuts.isEnabled(action) }, set: { _ = shortcuts.setEnabled($0, for: action) }
                )).toggleStyle(TranslateXSwitchStyle()).labelsHidden().padding(.leading, 12)
                    .translateXTooltip(L10n.string("Enable or pause this shortcut"))
            }.frame(minHeight: 62)
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(p.error)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 43).padding(.bottom, 10)
            }
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeading("Permissions", description: "Enable the permissions needed for selection and screenshot translation.")
                .padding(.bottom, 16)
            group {
                permissionRow(.accessibility, title: "Accessibility", symbol: "accessibility", detail: "Read selected text when you start a translation.")
                separator
                permissionRow(.screenCapture, title: "Screen Recording", symbol: "viewfinder", detail: "Recognize text only in the screen area you select.")
            }
            Label("Permissions are used only for actions you start. Translation text and screenshots are not saved.", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
        }
    }

    private func permissionRow(_ permission: SystemPermission, title: LocalizedStringKey, symbol: String, detail: LocalizedStringKey) -> some View {
        let granted = permissions.isGranted(permission)
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(p.muted)
                .frame(width: 36, height: 36).background(p.fill, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Label(granted ? "Authorized" : "Not authorized", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(granted ? p.success : p.color(theme.isDark ? 0xf1c987 : 0x956410))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(granted ? p.successFill : p.color(theme.isDark ? 0x413a2b : 0xfff8e9), in: RoundedRectangle(cornerRadius: 6))
            Button {
                if granted { permissions.openSettings(permission) } else { permissions.request(permission) }
            } label: {
                HStack(spacing: 6) {
                    Text(granted ? "Manage" : "Authorize")
                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                }
            }.buttonStyle(TranslationServiceButtonStyle(kind: granted ? .regular : .primary))
                .accessibilityLabel(granted ? L10n.string("Open System Settings") : permission.actionTitle)
        }.padding(.vertical, 12).frame(minHeight: 74)
    }

    private func pageHeading(_ title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                .accessibilityAddTraits(.isHeader).serviceDesignMetric("settings.pageHeading")
            Text(description).font(.system(size: 12)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func groupCaption(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted)
            .padding(.bottom, 7).accessibilityAddTraits(.isHeader)
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content).padding(.horizontal, 17)
            .background(p.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(p.line).allowsHitTesting(false) }
    }
    private var separator: some View { Rectangle().fill(p.line).frame(height: 1).accessibilityHidden(true) }

    private func segmented<Value: Hashable>(_ title: LocalizedStringKey, selection: Binding<Value>, choices: [(Value, LocalizedStringKey)]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                Button { selection.wrappedValue = choice.0 } label: {
                    Text(choice.1).font(.system(size: 11, weight: selection.wrappedValue == choice.0 ? .medium : .regular))
                        .foregroundStyle(selection.wrappedValue == choice.0 ? p.ink : p.muted)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(selection.wrappedValue == choice.0 ? p.panel : .clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(TranslateXHoverButtonStyle(radius: 5))
                    .accessibilityAddTraits(selection.wrappedValue == choice.0 ? [.isSelected] : [])
            }
        }.padding(3).background(p.fill, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain).accessibilityLabel(Text(title))
    }
}

private struct SettingsNavigationButtonStyle: ButtonStyle {
    @Environment(\.translateXTheme) private var theme
    let selected: Bool
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        let p = TranslationServicePalette(theme: theme)
        configuration.label
            .foregroundStyle(selected || hovered ? p.accent : p.muted)
            .background(selected ? p.color(theme.isDark ? 0x294564 : 0xdfebff)
                        : hovered ? p.color(theme.isDark ? 0x334960 : 0xeaf1fc) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8)).onHover { hovered = $0 }
            .opacity(configuration.isPressed ? 0.8 : 1).translateXControlCursor()
    }
}

private extension ShortcutAction {
    var settingsTitle: String {
        switch self {
        case .selection: L10n.string("Translate selection")
        case .input: L10n.string("Open translation window")
        case .ocr: L10n.string("Screenshot Translation")
        }
    }
    var settingsDescription: String {
        switch self {
        case .selection: L10n.string("Read the selection and show its translation")
        case .input: L10n.string("Open the workspace to continue writing")
        case .ocr: L10n.string("Capture an area to recognize and translate")
        }
    }
}
