import SwiftUI

struct ReleaseNotesView: View {
    @Environment(\.translateXTheme) private var theme
    let updates: AppUpdateController
    let mode: AppReleaseNotesMode
    var location: AppReleaseNotesLocation = .settings
    var maximumHeight: CGFloat? = nil
    let onDismiss: () -> Void
    @FocusState private var acknowledgementFocused: Bool
    private var p: ReleaseDialogPalette { .init(theme: theme) }
    private var entries: [AppRelease] {
        if case .installed(let version) = mode { return updates.releases.entries.filter { $0.version == version } }
        return updates.releases.entries
    }

    var body: some View {
        CompactUpdateDialog(title: L10n.string(mode == .recent ? "Recent updates" : "Update complete"),
                            maximumHeight: maximumHeight, onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 0) {
                if updates.releases.failed {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.string("Could not refresh release notes. Showing saved notes."))
                            .font(.system(size: 11)).foregroundStyle(p.secondary)
                        Spacer()
                        Button(L10n.string("Retry")) { Task { await updates.releases.load(force: true) } }
                            .buttonStyle(ReleaseDialogTextStyle())
                    }.padding(.bottom, 18)
                }
                if entries.isEmpty {
                    if updates.releases.isLoading {
                        HStack { ProgressView().controlSize(.small); Text(L10n.string("Loading release notes")).font(.system(size: 12)) }
                    } else {
                        Text(L10n.string("Release notes are not available here yet. You can view them on GitHub."))
                            .font(.system(size: 12)).foregroundStyle(p.secondary)
                    }
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, release in
                    if index > 0 { Rectangle().fill(p.line).frame(height: 1).padding(.top, 24).padding(.bottom, 21) }
                    ReleaseVersionHeading(version: release.version,
                                          badge: release.version == updates.currentVersion ? L10n.string("Current version") : nil,
                                          publishedAt: release.publishedAt)
                    if let notes = release.localizedNotes(languageIdentifier: L10n.currentLanguageIdentifier) {
                        ReleaseMarkdownContent(text: ReleaseNotesPresentation.content(notes, version: release.version))
                            .padding(.top, 18)
                    } else {
                        Text(L10n.string("Release notes are not available in this language yet."))
                            .font(.system(size: 12)).foregroundStyle(p.secondary).padding(.top, 18)
                    }
                    if mode == .recent, index > 0 {
                        Link(destination: release.url) {
                            HStack(spacing: 4) { Text(L10n.string("Version details")); Image(systemName: "arrow.up.right") }
                        }
                        .buttonStyle(ReleaseDialogTextStyle()).padding(.leading, 14).padding(.top, 12)
                    }
                }
            }
        } footer: {
            ReleaseDialogFooter {
                if case .installed = mode {
                    Button { updates.showRecentReleaseNotes(in: location) } label: {
                        HStack(spacing: 4) { Text(L10n.string("View all versions")); Image(systemName: "arrow.right") }
                    }.buttonStyle(ReleaseDialogTextStyle())
                } else { ReleaseHistoryLink() }
            } actions: {
                Button(L10n.string("Got it"), action: onDismiss)
                    .buttonStyle(ReleaseDialogButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction).focused($acknowledgementFocused)
            }
        }
        .id(mode)
        .onAppear { acknowledgementFocused = true }
        .task { await updates.loadReleaseNotes() }
    }
}

struct ReleaseHistoryLink: View {
    var body: some View {
        Link(destination: URL(string: "https://github.com/TheoYuuu/tsx/releases")!) {
            HStack(spacing: 4) { Text(L10n.string("Full release history")); Image(systemName: "arrow.up.right") }
        }.buttonStyle(ReleaseDialogTextStyle())
    }
}

/// One stable host for updates and installed notes. An update temporarily
/// takes precedence without acknowledging notes the user has not read.
struct MainReleaseNotesOverlay: View {
    @Environment(\.translateXTheme) private var theme
    let updates: AppUpdateController
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            if updates.isPresentingMainModal {
                ZStack {
                    Color.black.opacity(theme.isDark ? 0.46 : 0.23).ignoresSafeArea()
                        .contentShape(Rectangle()).onTapGesture {}
                    if updates.showsMainUpdate, let presentation = updates.updatePresentation {
                        AppUpdateInstallationView(updates: updates, presentation: presentation,
                                                      maximumHeight: max(0, geometry.size.height - 40))
                            .frame(width: min(520, max(0, geometry.size.width - 40)))
                    } else if let mode = updates.mainReleaseNotesPresentation {
                        ReleaseNotesView(updates: updates, mode: mode, location: .mainWindow,
                                     maximumHeight: max(0, geometry.size.height - 40), onDismiss: onDismiss)
                        .frame(width: min(520, max(0, geometry.size.width - 40)))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .ignoresSafeArea()
        .onExitCommand {
            if updates.showsMainUpdate { updates.dismissUpdate() }
            else { onDismiss() }
        }
    }
}

/// Renders published text without web content, scripts or remote images.
struct ReleaseMarkdownContent: View {
    @Environment(\.translateXTheme) private var theme
    let text: String
    private var p: ReleaseDialogPalette { .init(theme: theme) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                let value = line.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && value != "---" {
                    if value.hasPrefix("#") {
                        Text(verbatim: value.drop(while: { $0 == "#" || $0 == " " }).description)
                            .font(.system(size: 13, weight: .medium)).frame(minHeight: 21)
                    } else {
                        let bullet = value.hasPrefix("- ") || value.hasPrefix("* ")
                        let item = ReleaseNotesPresentation.item(bullet ? String(value.dropFirst(2)) : value)
                        HStack(alignment: .top, spacing: 8) {
                            if bullet {
                                Circle().fill(p.muted).frame(width: 3, height: 3)
                                    .frame(width: 6, height: 21).accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                if let title = item.title {
                                    Text(inline(title)).font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(p.ink).frame(minHeight: 21)
                                }
                                if !item.detail.isEmpty {
                                    Text(inline(item.detail)).font(.system(size: 12)).lineSpacing(6)
                                        .foregroundStyle(p.secondary).frame(minHeight: 21)
                                }
                            }.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in url.scheme == "https" ? .systemAction : .discarded })
    }
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
