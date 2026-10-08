import SwiftUI

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
    @State var serviceSession: TranslationServiceDraftSession? = nil
    @State var tab = 0

    private var servicePalette: TranslationServicePalette { .init(theme: theme) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                WindowTrafficLights().frame(width: 58, height: 14)
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.muted)
                Spacer()
            }
            .padding(.horizontal, 22)
            .frame(height: 64)
            .serviceDesignMetric("settings.titlebar")

            tabs
                .disabled(serviceNavigation.isPresentingConfirmation)
                .accessibilityHidden(serviceNavigation.isPresentingConfirmation)
                .serviceDesignMetric("settings.tabs")
                .padding(.bottom, 19)

            if tab == 3, let services {
                TranslationServicesSettingsView(services: services, navigation: serviceNavigation, serviceSession: serviceSession)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            switch tab {
                            case 1: shortcutSettings
                            case 2: privacy
                            default: general
                            }
                        }
                        .padding(.horizontal, 36)
                        .padding(.top, 10)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("settingsContent")
                        .translateXScrollContent()
                    }
                    .onChange(of: tab) { _, _ in proxy.scrollTo("settingsContent", anchor: .top) }
                }
            }
        }
        .foregroundStyle(theme.ink)
        .background {
            if tab == 3, !theme.isGlass {
                (theme.isDark ? servicePalette.color(0x262d39) : .white)
            }
        }
        .frame(minWidth: 620, minHeight: 540)
        .onChange(of: serviceNavigation.servicesRequestID, initial: true) { _, request in
            if request > 0, tab != 3 { tab = 3 }
        }
        .onChange(of: tab) { old, new in
            shortcuts.endRecording()
            // An injected opening draft is consumed by this visit. Leaving
            // closes it; a later visit must open the current saved list.
            if old == 3, new != 3 { serviceSession = nil }
        }
        .onChange(of: preferences.appearance) { _, _ in appearanceChanged() }
        .onChange(of: preferences.material) { _, _ in appearanceChanged() }
        .onChange(of: preferences.interfaceLanguage) { _, _ in interfaceLanguageChanged() }
        .task { permissions.refresh(); await catalog.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .onDisappear { shortcuts.endRecording() }
    }

    private var tabs: some View {
        HStack(spacing: 3) {
            tabButton("General", symbol: "gearshape", index: 0)
            if services != nil { tabButton("Translation services", symbol: "globe", index: 3) }
            tabButton("Shortcuts", symbol: "keyboard", index: 1)
            tabButton("Privacy", symbol: "hand.raised", index: 2)
        }
        .padding(4)
        .background(theme.control, in: Capsule())
        .overlay {
            Capsule().strokeBorder(theme.isGlass ? Color.white.opacity(0.44) : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    private func tabButton(_ title: LocalizedStringKey, symbol: String, index: Int) -> some View {
        Button {
            if tab == 3, index != tab {
                serviceNavigation.requestExit { tab = index }
            } else { tab = index }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 16, height: 16)
                ZStack {
                    Text(title).font(.system(size: 12, weight: .medium)).hidden()
                    Text(title).font(.system(size: 12, weight: tab == index ? .medium : .regular))
                }
            }
            .foregroundStyle(tab == index ? theme.accent : theme.muted)
                .padding(.horizontal, services == nil ? 19 : 13)
            .frame(height: 32)
            .background {
                if tab == index {
                    Capsule()
                        .fill(theme.card)
                        .shadow(color: Color.black.opacity(0.07), radius: 3, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(TranslateXHoverButtonStyle(radius: 16))
        .accessibilityAddTraits(tab == index ? [.isSelected] : [])
        .accessibilityIdentifier("settings.tab.\(index)")
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeading("General", description: "Make TSX feel at home.")

            group {
                HStack(spacing: 16) {
                    Text("Interface language")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                    interfaceLanguagePicker
                        .fixedSize()
                }
                .padding(.top, 14)
                Text("Choose the language used in TSX. Changes apply immediately.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
                    .padding(.bottom, 15)
            }
            .serviceDesignMetric("settings.interfaceLanguage")
            .padding(.bottom, 24)

            groupCaption("Translation preferences")
            group {
                HStack(spacing: 12) {
                    Text("Default target language")
                    Spacer(minLength: 12)
                    targetLanguageMenu
                }
                .frame(minHeight: 52)
                .font(.system(size: 13))
            }
            Text("Used for new selection and screenshot translations, and when the input workspace is empty.")
                .font(.system(size: 11))
                .lineSpacing(3)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 3)
                .padding(.top, 9)
            if !catalog.languages(for: services?.selectedConfiguration).isEmpty,
               !catalog.languages(for: services?.selectedConfiguration).contains(where: { $0.id == preferences.defaultTarget }) {
                Label(LocalizedStringKey(services?.selectedConfiguration == nil
                      ? "This language is unavailable on this Mac. Choose another target language."
                      : "This language is unavailable for the selected service. Choose another target language."), systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            groupCaption("Interface")
                .padding(.top, 24)
            group {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Translation window layout")
                        Text("Two equal panes in the main and quick translation windows.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    segmented("Translation window layout", selection: $preferences.translationLayout,
                              choices: [(.sideBySide, "Side by side"), (.stacked, "Stacked")])
                        .fixedSize()
                        .accessibilityIdentifier("settings.translationLayout")
                }
                .padding(.vertical, 14)
                .frame(minHeight: 72)
                separator
                HStack(spacing: 12) {
                    Text("Material")
                    Spacer(minLength: 12)
                    segmented("Material", selection: $preferences.material,
                              choices: [(.light, "Pure Light"), (.glass, "Liquid Glass")])
                }
                .frame(minHeight: 52)
                separator
                HStack(spacing: 12) {
                    Text("Appearance")
                    Spacer(minLength: 12)
                    segmented("Appearance", selection: $preferences.appearance,
                              choices: [(.system, "Follow System"), (.light, "Light"), (.dark, "Dark")])
                }
                .frame(minHeight: 52)
                separator
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use pointing cursor")
                        Text("Show a pointing hand when hovering over interactive elements.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Use pointing cursor", isOn: $preferences.usesPointingCursor)
                        .toggleStyle(SettingsSwitchStyle())
                        .accessibilityIdentifier("settings.pointingCursor")
                }
                .padding(.vertical, 14)
                .frame(minHeight: 72)
            }
            .font(.system(size: 13))
            if let updates, updates.isAvailable {
                groupCaption("Software updates").padding(.top, 24)
                group {
                    HStack {
                        Text("TSX")
                        Spacer()
                        Button("Check for Updates…") { updates.checkForUpdates() }
                            .disabled(!updates.canCheckForUpdates)
                            .accessibilityIdentifier("settings.updates.check")
                    }.frame(minHeight: 52)
                    separator
                    HStack(spacing: 20) {
                        Text("Automatically check for updates")
                        Spacer(minLength: 0)
                        Toggle("Automatically check for updates", isOn: Binding(
                            get: { updates.automaticallyChecksForUpdates },
                            set: { updates.setAutomaticChecks($0) }
                        )).toggleStyle(SettingsSwitchStyle())
                            .accessibilityIdentifier("settings.updates.automaticChecks")
                    }.frame(minHeight: 52)
                    separator
                    HStack(spacing: 20) {
                        Text("Download updates and install when quitting")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Toggle("Download updates and install when quitting", isOn: Binding(
                            get: { updates.automaticallyDownloadsUpdates },
                            set: { updates.setAutomaticDownloads($0) }
                        )).toggleStyle(SettingsSwitchStyle())
                            .disabled(!updates.automaticallyChecksForUpdates)
                            .accessibilityIdentifier("settings.updates.automaticDownloads")
                    }.frame(minHeight: 52)
                }.font(.system(size: 13))
                Text("Updates connect to lumaxspace.com and GitHub. Copy any text you want to keep before installing and restarting.")
                    .font(.system(size: 11)).foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 9)
            }
        }
    }

    private var interfaceLanguagePicker: some View {
        HStack(spacing: 2) {
            ForEach(AppInterfaceLanguage.allCases, id: \.self) { language in
                segment(interfaceLanguageLabel(language), value: language, selection: $preferences.interfaceLanguage)
                    .accessibilityIdentifier("settings.interfaceLanguage.option.\(language.rawValue)")
                    .serviceDesignMetric("settings.interfaceLanguage.option.\(language.rawValue)")
            }
        }
        .padding(3)
        .background(theme.control, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Interface language"))
        .accessibilityIdentifier("settings.interfaceLanguage")
    }

    private func interfaceLanguageLabel(_ language: AppInterfaceLanguage) -> Text {
        switch language {
        case .system: Text("Follow System")
        case .simplifiedChinese: Text(verbatim: "简体中文")
        case .english: Text(verbatim: "English")
        }
    }

    private var targetLanguageMenu: some View {
        LanguageMenu(label: L10n.string("Default target language"), selection: Binding(
            get: { preferences.defaultTarget },
            set: { preferences.setDefaultTarget($0); defaultTargetChanged() }
        ), languages: catalog.languages(for: services?.selectedConfiguration), prominent: false,
           enabled: !catalog.languages(for: services?.selectedConfiguration).isEmpty)
            .fixedSize()
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeading("Shortcuts", description: "Click a combination to change it. Esc cancels.", bottomPadding: 22)
            group {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    if action != ShortcutAction.allCases.first { separator }
                    shortcutRow(action)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "info.circle").font(.system(size: 12))
                Text(shortcuts.recordingAction == nil
                     ? "Turning off a shortcut keeps its combination."
                     : "Waiting for keys · Esc cancels without changing the shortcut.")
                    .font(.system(size: 11))
            }
            .foregroundStyle(theme.muted)
            .padding(.top, 15)
            Text("If a combination is unavailable, your previous setting is kept.")
                .font(.system(size: 10))
                .foregroundStyle(theme.muted)
                .padding(.top, 7)
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let enabled = shortcuts.isEnabled(action)
        let error = shortcuts.error(for: action)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Group {
                    switch action {
                    case .selection: TranslateXActionIcon(symbol: .selection)
                    case .input: TranslateXActionIcon(symbol: .input)
                    case .ocr: Image(systemName: "viewfinder").font(.system(size: 20))
                    }
                }
                .foregroundStyle(theme.muted)
                .frame(width: 24, height: 23)
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.settingsTitle)
                        .font(.system(size: 13, weight: .medium))
                    Text(enabled ? action.settingsDescription : L10n.string("Disabled · combination kept"))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ShortcutRecorder(action: action, settings: shortcuts)
                    .frame(width: 146, height: 34)
                Toggle(action.settingsTitle, isOn: Binding(
                    get: { shortcuts.isEnabled(action) },
                    set: { _ = shortcuts.setEnabled($0, for: action) }
                ))
                .toggleStyle(SettingsSwitchStyle())
                .labelsHidden()
                .frame(width: 32)
                .help("Enable or pause this shortcut")
                Button { _ = shortcuts.reset(for: action) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12))
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TranslateXHoverButtonStyle())
                .foregroundStyle(theme.muted)
                .opacity(shortcuts.rememberedShortcut(for: action) == action.defaultShortcut ? 0.27 : 1)
                .disabled(shortcuts.rememberedShortcut(for: action) == action.defaultShortcut)
                .help("Restore this shortcut’s default combination")
                .accessibilityLabel(Text(String(format: L10n.string("Reset %@ shortcut"), action.settingsTitle)))
            }
            .frame(minHeight: error == nil ? 82 : 60)
            if let error {
                Text(error + (shortcuts.recordingAction == action
                    ? " " + String(format: L10n.string("Previous shortcut kept: %@."),
                                   shortcuts.rememberedShortcut(for: action).displayString) : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.isDark ? Color.orange : Color(red: 0.58, green: 0.38, blue: 0.14))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36)
                    .padding(.bottom, 10)
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeading("Privacy", description: "Permissions serve only the actions you start.", bottomPadding: 15)
            group {
                permissionRow(.accessibility, title: "Accessibility", symbol: "accessibility")
                separator
                permissionRow(.screenCapture, title: "Screen Recording", symbol: "viewfinder")
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 15))
                    .frame(width: 16, height: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TSX does not save translation text or screenshots.")
                    Text("Service keys stay in Keychain. External services receive the text you choose to translate and apply their own data policies.")
                }
                .font(.system(size: 11))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(theme.muted)
            .padding(.top, 16)
        }
    }

    private func permissionRow(_ permission: SystemPermission, title: LocalizedStringKey, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label {
                    Text(title).font(.system(size: 13, weight: .medium))
                } icon: {
                    Image(systemName: symbol).font(.system(size: 16))
                }
                Spacer()
                permissionBadge(isGranted: permissions.isGranted(permission))
            }
            Text(permission.explanation)
                .font(.system(size: 11))
                .lineSpacing(4)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 9)
                .padding(.bottom, 12)
            if permissions.isGranted(permission) {
                Button("Open System Settings") { permissions.openSettings(permission) }
                    .buttonStyle(TranslateXButtonStyle(kind: .secondary))
            } else {
                Button(permission.actionTitle) { permissions.request(permission) }
                    .buttonStyle(TranslateXButtonStyle(kind: .primary))
            }
        }
        .padding(.vertical, 16)
    }

    private func permissionBadge(isGranted: Bool) -> some View {
        HStack(spacing: 4) {
            if isGranted {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
            }
            Text(LocalizedStringKey(isGranted ? "Enabled" : "Not enabled"))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(isGranted ? permissionGrantedColor : theme.muted)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isGranted ? Color.green.opacity(0.09) : theme.control, in: Capsule())
    }

    private var permissionGrantedColor: Color {
        theme.isDark ? Color(red: 0.49, green: 0.84, blue: 0.63) : Color(red: 0.20, green: 0.47, blue: 0.36)
    }

    private func pageHeading(_ title: LocalizedStringKey, description: LocalizedStringKey, bottomPadding: CGFloat = 24) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.4)
                .frame(height: 28, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .serviceDesignMetric("settings.pageHeading")
            Text(description)
                .font(.system(size: 12))
                .lineSpacing(4)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 7)
        .padding(.bottom, bottomPadding)
    }

    private func groupCaption(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.muted)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.horizontal, 17)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 17))
            .overlay {
                RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(theme.divider, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    private var separator: some View {
        Rectangle().fill(theme.divider).frame(height: 1).accessibilityHidden(true)
    }

    private func segmented<Value: Hashable>(
        _ title: LocalizedStringKey, selection: Binding<Value>, choices: [(Value, LocalizedStringKey)]
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                segment(Text(choice.1), value: choice.0, selection: selection)
            }
        }
        .padding(3)
        .background(theme.control, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private func segment<Value: Hashable>(_ label: Text, value: Value, selection: Binding<Value>) -> some View {
        Button { selection.wrappedValue = value } label: {
            label
                .font(.system(size: 11, weight: selection.wrappedValue == value ? .medium : .regular))
                .foregroundStyle(selection.wrappedValue == value ? theme.ink : theme.muted)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background {
                    if selection.wrappedValue == value {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(theme.card)
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(TranslateXHoverButtonStyle())
        .accessibilityAddTraits(selection.wrappedValue == value ? [.isSelected] : [])
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

/// Fixed geometry from the approved settings design, with native toggle semantics.
private struct SettingsSwitchStyle: ToggleStyle {
    @Environment(\.translateXTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? theme.accent : theme.muted.opacity(0.30))
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.20), radius: 1, y: 1)
                        .frame(width: 15, height: 15)
                        .padding(2)
                }
                .frame(width: 32, height: 19)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(TranslateXHoverButtonStyle())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}
