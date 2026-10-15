import SwiftUI

/// A single presentation slot replaces the check dialog with the existing
/// installation view. Release notes and installation progress keep their layout.
struct AppUpdateDialogView: View {
    let updates: AppUpdateController
    let presentation: AppUpdatePresentation
    let dialogSize: CGSize

    var body: some View {
        Group {
            if presentation.usesCheckDialog {
                AppUpdateCheckDialog(updates: updates, phase: presentation.phase)
                    .frame(width: min(360, dialogSize.width))
            } else {
                AppUpdateInstallationView(updates: updates, presentation: presentation, dialogSize: dialogSize)
            }
        }
        // Never retain an outgoing check view during an animated transition.
        .transaction { $0.animation = nil }
    }
}

struct AppUpdateCheckDialog: View {
    @Environment(\.translateXTheme) private var theme
    let updates: AppUpdateController
    let phase: AppUpdatePresentation.Phase
    @FocusState private var primaryFocused: Bool
    private var p: ReleaseDialogPalette { .init(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string(phase == .checking ? "Checking for updates"
                            : phase == .current ? "You're up to date" : "Could not check for updates"))
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .serviceDesignMetric("update.check.title")
            if phase == .checking {
                ProgressView().progressViewStyle(.linear).tint(p.blue)
                    .accessibilityLabel(L10n.string("Checking for updates"))
                    .padding(.top, 18)
            } else {
                Text(L10n.string(phase == .current ? "The latest available version is already installed."
                                 : "Unable to connect to the update server. Please try again later."))
                    .font(.system(size: 12)).foregroundStyle(p.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if phase == .checking {
                    Button(L10n.string("Cancel")) { updates.dismissUpdate() }
                        .buttonStyle(UpdateCheckButtonStyle()).keyboardShortcut(.cancelAction)
                        .focused($primaryFocused).serviceDesignMetric("update.check.cancel")
                } else if phase == .failed {
                    Button(L10n.string("Close")) { updates.dismissUpdate() }
                        .buttonStyle(UpdateCheckButtonStyle()).keyboardShortcut(.cancelAction)
                        .serviceDesignMetric("update.check.close")
                    Button(L10n.string("Retry")) { updates.retryUpdate() }
                        .buttonStyle(UpdateCheckButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                        .focused($primaryFocused).serviceDesignMetric("update.check.retry")
                } else {
                    Button(L10n.string("Got it")) { updates.dismissUpdate() }
                        .buttonStyle(UpdateCheckButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                        .focused($primaryFocused)
                }
            }.padding(.top, 20)
        }
        .padding(.horizontal, 24).padding(.top, 23).padding(.bottom, 20)
        .foregroundStyle(p.ink).frame(maxWidth: .infinity)
        .background(p.paper, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(p.line).allowsHitTesting(false) }
        .shadow(color: .black.opacity(theme.isDark ? 0.21 : 0.08), radius: 30, y: 10)
        .serviceDesignMetric("update.check.dialog")
        .onAppear { primaryFocused = true }
        .onChange(of: phase) { _, _ in primaryFocused = true }
    }
}

private struct UpdateCheckButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.translateXTheme) private var theme
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let p = ReleaseDialogPalette(theme: theme)
        configuration.label.font(.system(size: 12, weight: .medium))
            .frame(width: 64, height: 34)
            .foregroundStyle(primary ? .white : p.ink)
            .background(primary ? p.primary.opacity(configuration.isPressed ? 0.8 : hovered ? 0.95 : 1) : p.surface,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? .clear : hovered ? p.muted : p.line) }
            .contentShape(RoundedRectangle(cornerRadius: 8)).onHover { hovered = $0 }.translateXControlCursor()
    }
}
