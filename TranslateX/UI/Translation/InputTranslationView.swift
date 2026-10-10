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
    @Environment(\.translateXTheme) private var theme
    @Environment(\.translationLayout) private var layout

    private var showsUpdateModal: Bool { updates?.isPresentingMainModal == true }

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
                Spacer()
                if let updates, updates.isAvailable, updates.availableVersion != nil {
                    MainUpdateEntry(updates: updates)
                }
            }
            .padding(.horizontal, 22).frame(height: 44)
            .serviceDesignMetric("main.titlebar")
            TranslationCommandBar(model: model, translateSelection: translateSelection,
                                  translateScreenshot: translateScreenshot, openSettings: openSettings, manageServices: manageServices)
                .padding(.horizontal, 12).padding(.bottom, 10)
            Group {
                if model.screenshot != nil {
                    ScreenshotTranslationWorkspace(model: model, catalog: catalog, recapture: translateScreenshot)
                } else {
                    TranslationWorkspace(model: model, catalog: catalog, editorReady: editorReady,
                                         translationEditorReady: translationEditorReady)
                }
            }.padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(minWidth: layout.minimumSize(for: .main).width, minHeight: layout.minimumSize(for: .main).height)
        .overlay(alignment: .bottomLeading) { AppleTranslationHost(model: model) }
        .task { await catalog.load() }
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
    private var p: TranslationServicePalette { .init(theme: theme) }
    private var characters: [Character] { Array(L10n.string("New version available")) }
    private var animates: Bool {
        visible && activeState == .key && !reduceMotion && !hovered && !focused
            && !updates.isPresentingMainModal && !updates.isChecking
    }

    var body: some View {
        Button { updates.performUpdateAction() } label: {
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
        .focused($focused)
        .onHover { hovered = $0 }
        .accessibilityLabel(L10n.string("New version available"))
        .accessibilityValue(String(format: L10n.string("New version v%@ is available"), updates.availableVersion ?? ""))
        .accessibilityIdentifier("main.updateAvailable")
        .serviceDesignMetric("main.updateAvailable")
        .background(TranslateXWindowVisibility { visible = $0 })
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

    private func lift(index: Int, elapsed: TimeInterval) -> CGFloat {
        guard animates, waving else { return 0 }
        let progress = (elapsed - Double(index) * 0.065) / 0.42
        guard progress > 0, progress < 1 else { return 0 }
        return -2 * pow(sin(progress * .pi), 2)
    }
}
