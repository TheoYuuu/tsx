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

    private var showsReleaseNotes: Bool { updates?.mainReleaseNotesPresentation != nil }

    var body: some View {
        workspace
            .disabled(showsReleaseNotes)
            .allowsHitTesting(!showsReleaseNotes)
            .accessibilityHidden(showsReleaseNotes)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                WindowTrafficLights().frame(width: 58, height: 14)
                    .serviceDesignMetric("main.trafficLights")
                Spacer()
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
