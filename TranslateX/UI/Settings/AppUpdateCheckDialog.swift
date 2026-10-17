import SwiftUI

/// The check and installation flows share one presentation slot and modal shell.
struct AppUpdateDialogView: View {
    let updates: AppUpdateController
    let presentation: AppUpdatePresentation
    let dialogSize: CGSize

    private var resolvedSize: CGSize {
        let showsNotes = !presentation.usesCheckDialog
            && (presentation.phase == .available || presentation.phase == .ready)
        return CGSize(width: min(showsNotes ? UpdateDialogLayout.notesWidth : UpdateDialogLayout.taskWidth, dialogSize.width), height: dialogSize.height)
    }

    var body: some View {
        Group {
            if presentation.usesCheckDialog {
                AppUpdateCheckDialog(updates: updates, presentation: presentation, dialogSize: resolvedSize)
            } else {
                AppUpdateInstallationView(updates: updates, presentation: presentation, dialogSize: resolvedSize)
            }
        }
        .frame(width: resolvedSize.width)
        // Never retain an outgoing check view during an animated transition.
        .transaction { $0.animation = nil }
    }
}

struct AppUpdateCheckDialog: View {
    @Environment(\.translateXTheme) private var theme
    let updates: AppUpdateController
    let presentation: AppUpdatePresentation
    let dialogSize: CGSize
    private var p: ReleaseDialogPalette { .init(theme: theme) }
    private var phase: AppUpdatePresentation.Phase { presentation.phase }

    var body: some View {
        CompactUpdateDialog(title: title, maximumHeight: dialogSize.height,
                            minimumHeight: UpdateDialogLayout.compactHeight,
                            maximumWidth: dialogSize.width, titleMetricKey: "update.check.title",
                            updatePhase: phase,
                            onDismiss: updates.dismissUpdate) {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 12)).foregroundStyle(p.secondary)
                    .frame(minHeight: 20, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(secondaryMessage)
                    .font(.system(size: 11)).foregroundStyle(p.muted)
                    .frame(minHeight: 17, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if phase == .checking {
                    ProgressView().progressViewStyle(.linear).tint(p.blue)
                        .frame(height: 5)
                        .accessibilityLabel(L10n.string("Checking for updates"))
                }
            }
        } footer: {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if phase == .checking {
                    Button(L10n.string("Cancel")) { updates.dismissUpdate() }
                        .buttonStyle(ReleaseDialogButtonStyle(fixedWidth: 64))
                        .updateDialogKeyboardAction(action: updates.dismissUpdate)
                        .keyboardShortcut(.cancelAction)
                        .serviceDesignMetric("update.check.cancel")
                } else if phase == .failed {
                    Button(L10n.string("Close")) { updates.dismissUpdate() }
                        .buttonStyle(ReleaseDialogButtonStyle(fixedWidth: 64))
                        .updateDialogKeyboardAction(action: updates.dismissUpdate)
                        .keyboardShortcut(.cancelAction)
                        .serviceDesignMetric("update.check.close")
                    Button(L10n.string("Retry")) { updates.retryUpdate() }
                        .buttonStyle(ReleaseDialogButtonStyle(primary: true, fixedWidth: 64))
                        .updateDialogKeyboardAction(action: updates.retryUpdate)
                        .keyboardShortcut(.defaultAction)
                        .serviceDesignMetric("update.check.retry")
                } else {
                    Button(L10n.string("Got it")) { updates.dismissUpdate() }
                        .buttonStyle(ReleaseDialogButtonStyle(primary: true, fixedWidth: 64))
                        .updateDialogKeyboardAction(action: updates.dismissUpdate)
                        .keyboardShortcut(.defaultAction)
                        .serviceDesignMetric("update.check.gotIt")
                }
            }
        }
        .serviceDesignMetric("update.check.dialog")
        .onExitCommand { updates.dismissUpdate() }
    }

    private var title: String {
        L10n.string(phase == .checking ? "Checking for updates"
                    : phase == .current ? "You're up to date" : "Could not check for updates")
    }

    private var message: String {
        switch phase {
        case .checking:
            return L10n.string("Connecting to the update server")
        case .current:
            return L10n.string("The latest available version is already installed.")
        default:
            return presentation.errorMessage
                ?? L10n.string("Unable to connect to the update server. Please try again later.")
        }
    }

    private var secondaryMessage: String {
        if phase == .failed { return L10n.string("Your current version is still available.") }
        return String(format: L10n.string("Current version v%@"), updates.currentVersion)
    }
}
