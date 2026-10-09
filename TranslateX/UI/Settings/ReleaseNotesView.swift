import SwiftUI

struct ReleaseNotesView: View {
    @Environment(\.translateXTheme) private var theme
    let updates: AppUpdateController
    let mode: AppReleaseNotesMode
    var location: AppReleaseNotesLocation = .settings
    var maximumHeight: CGFloat? = nil
    let onDismiss: () -> Void
    @FocusState private var acknowledgementFocused: Bool
    @State private var contentHeight: CGFloat = 96
    @State private var headerHeight: CGFloat = 108
    @State private var footerHeight: CGFloat = 80
    private var p: TranslationServicePalette { .init(theme: theme) }
    private var isCompact: Bool { location == .mainWindow }
    private var horizontalPadding: CGFloat { isCompact ? 20 : 26 }
    private var notesHeight: CGFloat {
        let preferred = min(isCompact ? 320 : 360, max(44, contentHeight))
        guard let maximumHeight else { return preferred }
        return max(0, min(preferred, maximumHeight - headerHeight - footerHeight))
    }
    private var entries: [AppRelease] {
        if case .installed(let version) = mode { return updates.releases.entries.filter { $0.version == version } }
        return updates.releases.entries
    }
    private var title: String { L10n.string(mode == .recent ? "Recent updates" : "What's new") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: isCompact ? 21 : 23)).foregroundStyle(p.accent)
                Text(title).font(.system(size: isCompact ? 17 : 19, weight: .semibold))
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 12)) }
                    .buttonStyle(TranslationServiceButtonStyle(kind: .quiet))
                    .accessibilityLabel(L10n.string("Close"))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, isCompact ? 20 : 24).padding(.bottom, isCompact ? 16 : 20)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { headerHeight = $0 }
            ScrollView {
                VStack(alignment: .leading, spacing: isCompact ? 18 : 23) {
                    if updates.releases.failed {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L10n.string("Could not refresh release notes. Showing saved notes."))
                                .font(.system(size: 11)).foregroundStyle(p.muted)
                            Spacer()
                            Button(L10n.string("Retry")) { Task { await updates.releases.load(force: true) } }
                                .buttonStyle(TranslateXTextButtonStyle()).font(.system(size: 11))
                        }
                    }
                    if entries.isEmpty {
                        if updates.releases.isLoading {
                            HStack { ProgressView().controlSize(.small); Text(L10n.string("Loading release notes")).font(.system(size: 12)) }
                        } else {
                            Text(L10n.string("Release notes are not available here yet. You can view them on GitHub."))
                                .font(.system(size: 12)).foregroundStyle(p.muted)
                        }
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, release in
                        if index > 0 { Rectangle().fill(p.line).frame(height: 1) }
                        VStack(alignment: .leading, spacing: isCompact ? 11 : 14) {
                            HStack(spacing: 8) {
                                Text(verbatim: "v" + release.version).font(.system(size: isCompact ? 15 : 17, weight: .semibold))
                                if release.version == updates.currentVersion {
                                    Text(L10n.string("Current version")).font(.system(size: 10))
                                        .foregroundStyle(p.accent).padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 5))
                                }
                                Spacer()
                                Link(destination: release.url) { Label(L10n.string("Details"), systemImage: "arrow.up.right") }
                                    .buttonStyle(TranslateXTextButtonStyle()).font(.system(size: 11))
                            }
                            if let notes = release.localizedNotes(languageIdentifier: L10n.currentLanguageIdentifier) {
                                ReleaseMarkdownContent(text: ReleaseNotesLocalization.removingRedundantTitle(notes, version: release.version))
                            } else {
                                Text(L10n.string("Release notes are not available in this language yet."))
                                    .font(.system(size: 12)).foregroundStyle(p.muted)
                            }
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding).padding(.bottom, 10)
                .translateXScrollContent()
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { contentHeight = $0 }
            }
            .frame(height: notesHeight)
            HStack(spacing: 10) {
                Spacer()
                if case .installed = mode {
                    Button(L10n.string("View all versions")) { updates.showRecentReleaseNotes(in: location) }
                        .buttonStyle(TranslationServiceButtonStyle())
                } else {
                    Link(L10n.string("View full release notes"), destination: URL(string: "https://github.com/TheoYuuu/tsx/releases")!)
                        .buttonStyle(TranslationServiceButtonStyle())
                }
                Button(L10n.string("Got it"), action: onDismiss)
                    .buttonStyle(TranslationServiceButtonStyle(kind: .primary, minimumWidth: 76))
                    .keyboardShortcut(.defaultAction).focused($acknowledgementFocused)
            }
            .padding(isCompact ? 20 : 24)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { footerHeight = $0 }
        }
        .foregroundStyle(p.ink)
        .frame(maxWidth: isCompact ? 480 : 570)
        .background(p.popover, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(p.line) }
        .onAppear { acknowledgementFocused = true }
        .task { await updates.loadReleaseNotes() }
    }
}

/// Startup notes stay over the translation workspace. Only the release text
/// scrolls; the title and dismissal controls remain inside the available area.
struct MainReleaseNotesOverlay: View {
    @Environment(\.translateXTheme) private var theme
    let updates: AppUpdateController
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            if let mode = updates.mainReleaseNotesPresentation {
                ZStack {
                    Color.black.opacity(theme.isDark ? 0.46 : 0.23).ignoresSafeArea()
                        .contentShape(Rectangle()).onTapGesture {}
                    ReleaseNotesView(updates: updates, mode: mode, location: .mainWindow,
                                     maximumHeight: max(0, geometry.size.height - 40), onDismiss: onDismiss)
                        .frame(width: min(480, max(0, geometry.size.width - 40)))
                        .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.12), radius: 24, y: 8)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .ignoresSafeArea()
        .onExitCommand(perform: onDismiss)
    }
}

/// Renders release text without a web view, scripts, remote images or HTML.
/// Inline Markdown preserves links/emphasis from the actual public notes.
struct ReleaseMarkdownContent: View {
    @Environment(\.translateXTheme) private var theme
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                let value = line.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && value != "---" {
                    if value.hasPrefix("#") {
                        Text(verbatim: value.drop(while: { $0 == "#" || $0 == " " }).description)
                            .font(.system(size: 12, weight: .semibold)).padding(.top, 5)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            if value.hasPrefix("- ") { Text("•").accessibilityHidden(true) }
                            Text(inline(value.hasPrefix("- ") ? String(value.dropFirst(2)) : value))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        .font(.system(size: 12)).lineSpacing(3).foregroundStyle(theme.muted)
                    }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            url.scheme == "https" ? .systemAction : .discarded
        })
    }
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
