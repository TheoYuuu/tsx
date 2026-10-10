import SwiftUI

struct AboutSettingsView: View {
    @Environment(\.translateXTheme) private var theme
    let updates: AppUpdateController
    @AppStorage("TSXSupportPromptDismissed") private var supportDismissed = false
    private var p: TranslationServicePalette { .init(theme: theme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("About")).font(.system(size: 21, weight: .semibold))
                    Text(L10n.string("Version information and software updates"))
                        .font(.system(size: 12)).foregroundStyle(p.muted)
                }.padding(.bottom, 5)
                VStack(spacing: 0) {
                    identity
                    if updates.availableVersion != nil || updates.lastCheckFailed {
                        HStack(spacing: 8) {
                            Image(systemName: updates.lastCheckFailed ? "exclamationmark.circle" : "square.and.arrow.down")
                                .font(.system(size: 13))
                            Text(updateNotice).font(.system(size: 11))
                            Spacer()
                        }
                        .foregroundStyle(updates.lastCheckFailed ? p.error : p.accent)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background { Rectangle().fill(updates.lastCheckFailed ? p.fill : p.accentSoft) }
                        .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 1) }
                    }
                    links
                    if !supportDismissed { support }
                }
                .background(p.panel, in: RoundedRectangle(cornerRadius: 14))
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(p.line) }
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.string("Automatic updates")).font(.system(size: 12, weight: .medium))
                        Text(L10n.string(!updates.isAvailable
                                        ? "Online updates are disabled in this development build."
                                        : updates.automaticUpdatesEnabled
                                        ? "At launch, check, download and install updates, then restart."
                                        : "Check at launch. You choose when to install."))
                            .font(.system(size: 11)).foregroundStyle(p.muted)
                    }
                    Spacer()
                    Toggle(L10n.string("Automatic updates"), isOn: Binding(
                        get: { updates.automaticUpdatesEnabled }, set: { updates.setAutomaticUpdates($0) }
                    ))
                    .toggleStyle(TranslateXSwitchStyle()).disabled(!updates.isAvailable || !updates.started)
                }
                .padding(.horizontal, 18).padding(.vertical, 13).frame(minHeight: 62)
                .background(p.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(p.line) }
                Text(L10n.string("Free and open source · MIT License"))
                    .font(.system(size: 11)).foregroundStyle(p.muted)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .translateXScrollContent()
        }
        .foregroundStyle(p.ink)
    }

    private var identity: some View {
        HStack(spacing: 12) {
            TranslateXBrandMark(size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text("TSX").font(.system(size: 18, weight: .semibold))
                Text(verbatim: "v" + updates.currentVersion).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(p.muted).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(p.panel, in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(p.line) }
            }
            Spacer(minLength: 16)
            Button { updates.performUpdateAction() } label: {
                HStack(spacing: 7) {
                    if updates.isChecking { ProgressView().controlSize(.mini) }
                    else { Image(systemName: updates.availableVersion == nil ? "arrow.clockwise" : "square.and.arrow.down") }
                    Text(updateActionTitle)
                }
            }
            .buttonStyle(TranslationServiceButtonStyle(kind: .primary))
            .disabled(!updates.canCheckForUpdates || updates.isChecking)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    private var links: some View {
        HStack(spacing: 9) {
            Link(destination: AppUpdateLinks.productPage(languageIdentifier: L10n.currentLanguageIdentifier)) {
                Label(L10n.string("Official website"), systemImage: "globe")
            }
            .buttonStyle(TranslationServiceButtonStyle())
            Link(destination: URL(string: "https://github.com/TheoYuuu/tsx/releases")!) {
                Label(L10n.string("Release notes"), systemImage: "arrow.up.right.square")
            }
            .buttonStyle(TranslationServiceButtonStyle())
            Button { updates.showRecentReleaseNotes() } label: {
                Label(L10n.string("Recent updates"), systemImage: "sparkles")
            }
            .buttonStyle(TranslationServiceButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 1) }
    }

    private var support: some View {
        HStack(spacing: 11) {
            Image(systemName: "star.fill").font(.system(size: 17))
                .foregroundStyle(p.color(theme.isDark ? 0xffc778 : 0xd69124))
            Text(L10n.string("If TSX has helped you, please give it a Star on GitHub. It means a lot to us."))
                .font(.system(size: 11)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Link(destination: URL(string: "https://github.com/TheoYuuu/tsx")!) {
                HStack(spacing: 6) {
                    Image("GitHubMark").renderingMode(.template).resizable().frame(width: 14, height: 14)
                    Text(L10n.string("Star on GitHub"))
                }
            }
            .buttonStyle(TranslationServiceButtonStyle())
            Button { supportDismissed = true } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                .buttonStyle(TranslationServiceButtonStyle(kind: .quiet))
                .accessibilityLabel(L10n.string("Dismiss support message"))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background { Rectangle().fill(p.color(theme.isDark ? 0x3d342a : 0xfff5eb)) }
        .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 1) }
    }

    private var updateActionTitle: String {
        if updates.isChecking { return L10n.string("Checking for updates") }
        if let version = updates.availableVersion { return String(format: L10n.string("Update to v%@"), version) }
        if updates.lastCheckFailed { return L10n.string("Retry update check") }
        return L10n.string("Check for updates")
    }
    private var updateNotice: String {
        if updates.lastCheckFailed { return L10n.string("Could not check for updates. Please try again.") }
        return String(format: L10n.string("New version v%@ is available"), updates.availableVersion ?? "")
    }
}

/// Recent notes stay in Settings; installation remains in the main window.
struct SettingsUpdateOverlay: View {
    @Environment(\.translateXTheme) private var theme
    let updates: AppUpdateController

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(theme.isDark ? 0.46 : 0.23).ignoresSafeArea()
                    .contentShape(Rectangle()).onTapGesture {}
                if let mode = updates.releaseNotesPresentation {
                    ReleaseNotesView(updates: updates, mode: mode, maximumHeight: max(0, geometry.size.height - 40)) {
                        updates.dismissReleaseNotes()
                    }.frame(width: min(520, max(0, geometry.size.width - 40)))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onExitCommand { updates.dismissReleaseNotes() }
    }
}

struct AppUpdateInstallationView: View {
    @Environment(\.translateXTheme) private var theme
    let updates: AppUpdateController
    let presentation: AppUpdatePresentation
    var maximumHeight: CGFloat? = nil
    @FocusState private var primaryFocused: Bool
    private var p: ReleaseDialogPalette { .init(theme: theme) }
    private var busy: Bool { [.checking, .downloading, .extracting, .installing].contains(presentation.phase) }
    private var canDismiss: Bool { ![.extracting, .installing].contains(presentation.phase) }
    private var showsNotes: Bool { [.available, .ready].contains(presentation.phase) }
    private var release: AppRelease? { updates.releases.entries.first { $0.version == presentation.version } }

    var body: some View {
        CompactUpdateDialog(title: title, maximumHeight: maximumHeight, canDismiss: canDismiss,
                            onDismiss: { updates.dismissUpdate() }) {
            VStack(alignment: .leading, spacing: 0) {
                if let version = presentation.version {
                    ReleaseVersionHeading(version: version, badge: L10n.string("New version"),
                                          publishedAt: release?.publishedAt ?? presentation.publishedAt,
                                          currentVersion: updates.currentVersion)
                }
                if showsNotes {
                    if let notes = release?.localizedNotes(languageIdentifier: L10n.currentLanguageIdentifier), !notes.isEmpty {
                        ReleaseMarkdownContent(text: ReleaseNotesPresentation.content(notes, version: presentation.version ?? ""))
                            .padding(.top, 18)
                    } else {
                        Text(L10n.string("Release notes are not available here yet. You can view them on GitHub."))
                            .font(.system(size: 12)).foregroundStyle(p.secondary).padding(.top, 18)
                    }
                }
                if let status {
                    Text(status).font(.system(size: 12)).foregroundStyle(p.secondary).lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, presentation.version == nil ? 0 : 18)
                }
                if busy {
                    Group {
                        if let progress = presentation.progress { ProgressView(value: progress).tint(p.blue) }
                        else { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                    }.padding(.top, 18)
                }
            }
        } footer: {
            ReleaseDialogFooter { ReleaseHistoryLink() } actions: { actions }
        }
        .onAppear { primaryFocused = true; updates.continueAutomaticUpdate() }
        .onChange(of: presentation) { _, _ in updates.continueAutomaticUpdate() }
        .task { await updates.loadReleaseNotes() }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if presentation.phase == .failed {
                Button(L10n.string("Close")) { updates.dismissUpdate() }
                    .buttonStyle(ReleaseDialogButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L10n.string("Retry")) { updates.dismissUpdate(); updates.checkForUpdates() }
                    .buttonStyle(ReleaseDialogButtonStyle(primary: true)).focused($primaryFocused)
                    .keyboardShortcut(.defaultAction)
            } else if presentation.phase == .current {
                Button(L10n.string("Got it")) { updates.dismissUpdate() }
                    .buttonStyle(ReleaseDialogButtonStyle(primary: true)).focused($primaryFocused)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.string(busy ? "Cancel" : "Later")) { updates.dismissUpdate() }
                    .buttonStyle(ReleaseDialogButtonStyle()).disabled(!canDismiss).keyboardShortcut(.cancelAction)
                if presentation.informationOnly, let url = presentation.informationURL {
                    Link(L10n.string("View details"), destination: url).buttonStyle(ReleaseDialogButtonStyle(primary: true))
                } else if !busy {
                    Button(L10n.string("Update now")) { updates.installPendingUpdate() }
                        .buttonStyle(ReleaseDialogButtonStyle(primary: true)).focused($primaryFocused)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var title: String {
        switch presentation.phase {
        case .available, .ready: return L10n.string("New version available")
        case .current: return L10n.string("You're up to date")
        case .checking: return L10n.string("Checking for updates")
        case .failed: return L10n.string("Update could not be completed")
        default: return String(format: L10n.string("Update to v%@"), presentation.version ?? updates.currentVersion)
        }
    }
    private var status: String? {
        if presentation.informationOnly { return L10n.string("This update requires a separate download. View its details to continue.") }
        switch presentation.phase {
        case .available, .ready: return nil
        case .checking: return L10n.string("Connecting to the update server")
        case .downloading: return L10n.string("Downloading the update")
        case .extracting: return L10n.string("Verifying and preparing the update")
        case .installing: return L10n.string("Installing the update")
        case .failed: return L10n.string("Please try again later. Your current version is unchanged.")
        case .current: return L10n.string("The latest available version is already installed.")
        }
    }
}
