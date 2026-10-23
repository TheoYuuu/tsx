import SwiftUI

struct InputTranslationView: View {
    @Bindable var model: TranslationModel
    let catalog: LanguageCatalog
    let translateSelection: () -> Void
    let translateScreenshot: () -> Void
    let openSettings: () -> Void
    var manageServices: () -> Void = {}
    var editorReady: (NSTextView) -> Void = { _ in }
    var translationEditorReady: (NSTextView) -> Void = { _ in }
    var updates: AppUpdateController? = nil
    var restorePrevious: () -> Void = {}
    var saveScreenshot: (ScreenshotOutput) -> Void = { _ in }
    var screenshotReturn: ScreenshotReturnState? = nil
    var returnToScreenshot: () -> Void = {}
    var speechSession: TranslationSpeechSession? = nil
    @Environment(\.translateXTheme) private var theme
    @Environment(\.translationLayout) private var layout

    private var showsUpdateModal: Bool { updates?.isPresentingMainModal == true }
    private var canReturnToScreenshot: Bool {
        guard let documentID = screenshotReturn?.documentID else { return false }
        return documentID == model.screenshot?.id
    }

    var body: some View {
        workspace
            .disabled(showsUpdateModal)
            .allowsHitTesting(!showsUpdateModal)
            .accessibilityHidden(showsUpdateModal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                WindowTrafficLights().frame(width: 58, height: 14)
                    .serviceDesignMetric("main.trafficLights")
                Text(model.sourceName.isEmpty ? L10n.string("Typed input") : model.sourceName)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .translateXTooltip(model.sourceName.isEmpty ? L10n.string("Typed input") : model.sourceName)
                    .accessibilityIdentifier("translation.source")
                Spacer()
                if let updates, updates.isAvailable, updates.availableVersion != nil {
                    MainUpdateEntry(updates: updates)
                }
                if model.canRestorePreviousWorkspace || canReturnToScreenshot {
                    HStack(spacing: 8) {
                        if model.canRestorePreviousWorkspace {
                            MainTitlebarActionButton(title: "Restore previous translation", icon: .history,
                                                    action: restorePrevious)
                                .disabled(model.isComposing)
                                .translateXTooltip(L10n.string("Restore the content replaced by the last capture"))
                                .accessibilityIdentifier("translation.restorePrevious")
                                .serviceDesignMetric("main.restorePrevious")
                        }
                        if canReturnToScreenshot {
                            MainTitlebarActionButton(title: "Return to floating window", icon: .floatingWindow,
                                                    action: returnToScreenshot)
                                .disabled(model.isComposing || model.phase == .recognizing)
                                .translateXTooltip(L10n.string("Keep current edits and return to the screenshot floating window"))
                                .accessibilityIdentifier("translation.returnToScreenshot")
                                .serviceDesignMetric("main.returnToScreenshot")
                        }
                    }
                }
            }
            .padding(.horizontal, 12).frame(height: 44)
            .serviceDesignMetric("main.titlebar")
            TranslationCommandBar(model: model, translateSelection: translateSelection,
                                  translateScreenshot: translateScreenshot, openSettings: openSettings, manageServices: manageServices)
                .padding(.horizontal, 12).padding(.bottom, 10)
            Group {
                if model.screenshot != nil {
                    ScreenshotTranslationWorkspace(model: model, catalog: catalog, save: saveScreenshot)
                } else {
                    TranslationWorkspace(model: model, catalog: catalog, editorReady: editorReady,
                                         translationEditorReady: translationEditorReady, speechSession: speechSession)
                }
            }.padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(minWidth: layout.minimumSize(for: .main).width, minHeight: layout.minimumSize(for: .main).height)
        .overlay(alignment: .bottomLeading) { AppleTranslationHost(model: model) }
        .task { await catalog.load() }
    }

}

private struct MainTitlebarActionButton: View {
    let title: String
    let icon: MainTitlebarActionIcon.Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                MainTitlebarActionIcon(kind: icon)
                    .stroke(style: StrokeStyle(lineWidth: 1.7 * 15 / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)
                Text(L10n.string(title)).font(.system(size: 12)).lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(width: L10n.currentLanguageIdentifier == "zh-Hans" ? 112 : nil, height: 28)
            .fixedSize()
        }
        .buttonStyle(MainTitlebarActionButtonStyle())
        .accessibilityLabel(Text(L10n.string(title)))
    }
}

private struct MainTitlebarActionButtonStyle: ButtonStyle {
    @Environment(\.translateXTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? theme.ink : theme.disabledInk)
            .background {
                RoundedRectangle(cornerRadius: 7).fill(theme.card)
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.ink.opacity(enabled && (hovered || configuration.isPressed)
                                           ? (configuration.isPressed ? 0.12 : 0.06) : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7).strokeBorder(theme.divider, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
            .translateXControlCursor()
    }
}

/// Lucide 1.17.0 history and picture-in-picture-2, using the same 24 pt source canvas.
/// Attribution and licenses are included in Resources/ScreenshotIconNotices.txt.
private struct MainTitlebarActionIcon: Shape {
    enum Kind { case history, floatingWindow }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .history:
            path.move(to: CGPoint(x: 3, y: 12))
            path.addCurve(to: CGPoint(x: 12, y: 21), control1: CGPoint(x: 3, y: 16.970563), control2: CGPoint(x: 7.029437, y: 21))
            path.addCurve(to: CGPoint(x: 21, y: 12), control1: CGPoint(x: 16.970563, y: 21), control2: CGPoint(x: 21, y: 16.970563))
            path.addCurve(to: CGPoint(x: 12, y: 3), control1: CGPoint(x: 21, y: 7.029437), control2: CGPoint(x: 16.970563, y: 3))
            path.addCurve(to: CGPoint(x: 5.26, y: 5.74), control1: CGPoint(x: 9.483952, y: 3.009465), control2: CGPoint(x: 7.068969, y: 3.991224))
            path.addLine(to: CGPoint(x: 3, y: 8))
            path.move(to: CGPoint(x: 3, y: 3))
            path.addLine(to: CGPoint(x: 3, y: 8))
            path.addLine(to: CGPoint(x: 8, y: 8))
            path.move(to: CGPoint(x: 12, y: 7))
            path.addLine(to: CGPoint(x: 12, y: 12))
            path.addLine(to: CGPoint(x: 16, y: 14))
        case .floatingWindow:
            path.move(to: CGPoint(x: 21, y: 9))
            path.addLine(to: CGPoint(x: 21, y: 6))
            path.addCurve(to: CGPoint(x: 19, y: 4), control1: CGPoint(x: 21, y: 4.895431), control2: CGPoint(x: 20.104569, y: 4))
            path.addLine(to: CGPoint(x: 4, y: 4))
            path.addCurve(to: CGPoint(x: 2, y: 6), control1: CGPoint(x: 2.895431, y: 4), control2: CGPoint(x: 2, y: 4.895431))
            path.addLine(to: CGPoint(x: 2, y: 16))
            path.addCurve(to: CGPoint(x: 4, y: 18), control1: CGPoint(x: 2, y: 17.1), control2: CGPoint(x: 2.9, y: 18))
            path.addLine(to: CGPoint(x: 8, y: 18))
            path.addRoundedRect(in: CGRect(x: 12, y: 13, width: 10, height: 7), cornerSize: CGSize(width: 2, height: 2))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// A short, infrequent wave gives a discovered update some presence while
/// preserving the label's intrinsic width and a stable click target.
private struct MainUpdateEntry: View {
    let updates: AppUpdateController
    @Environment(\.translateXTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @FocusState private var focused: Bool
    @State private var hovered = false
    @State private var visible = false
    @State private var waving = false
    @State private var waveStarted = Date()
    @State private var restoresFocusAfterUpdate = false
    private var p: TranslationServicePalette { .init(theme: theme) }
    private var characters: [Character] { Array(L10n.string("New version available")) }
    private var animates: Bool {
        visible && activeState == .key && !reduceMotion && !hovered && !focused
            && !updates.isPresentingMainModal && !updates.isChecking
    }

    var body: some View {
        Button(action: showUpdate) {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !animates || !waving)) { context in
                let elapsed = context.date.timeIntervalSince(waveStarted)
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                        .offset(y: lift(index: 0, elapsed: elapsed))
                    HStack(spacing: 0) {
                        ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                            Text(verbatim: String(character))
                                .fixedSize()
                                .offset(y: lift(index: index + 1, elapsed: elapsed))
                        }
                    }.font(.system(size: 12, weight: .medium))
                }
                .fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 6)
                .serviceDesignMetric("main.updateLabel")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.accent)
        .background(hovered ? p.accent.opacity(0.14) : p.accentSoft, in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
        .updateDialogKeyboardAction(action: showUpdate)
        .focused($focused)
        .onHover { hovered = $0 }
        .translateXControlCursor()
        .accessibilityLabel(L10n.string("New version available"))
        .accessibilityValue(String(format: L10n.string("New version v%@ is available"), updates.availableVersion ?? ""))
        .accessibilityIdentifier("main.updateAvailable")
        .serviceDesignMetric("main.updateAvailable")
        .background(TranslateXWindowVisibility { visible = $0 })
        .onChange(of: updates.isPresentingMainModal) { _, presenting in
            guard !presenting, restoresFocusAfterUpdate else { return }
            restoresFocusAfterUpdate = false
            // Re-enable the workspace before returning focus to this entry.
            DispatchQueue.main.async {
                guard !updates.isPresentingMainModal else { return }
                focused = true
            }
        }
        .task(id: animates) {
            waving = false
            guard animates else { return }
            do {
                try await Task.sleep(for: .seconds(1))
                while !Task.isCancelled {
                    waveStarted = Date(); waving = true
                    let duration = 0.42 + Double(characters.count) * 0.065
                    try await Task.sleep(for: .seconds(duration))
                    waving = false
                    try await Task.sleep(for: .seconds(max(3, 6 - duration)))
                }
            } catch { waving = false }
        }
    }

    private func showUpdate() {
        restoresFocusAfterUpdate = true
        focused = false
        updates.performUpdateAction()
    }

    private func lift(index: Int, elapsed: TimeInterval) -> CGFloat {
        guard animates, waving else { return 0 }
        let progress = (elapsed - Double(index) * 0.065) / 0.42
        guard progress > 0, progress < 1 else { return 0 }
        return -2 * pow(sin(progress * .pi), 2)
    }
}
