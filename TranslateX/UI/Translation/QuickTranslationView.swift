import SwiftUI

struct QuickTranslationView: View {
    @Bindable var model: TranslationModel
    let close: () -> Void
    let openInput: () -> Void
    let canOpenInput: () -> Bool
    let permission: SystemPermission?
    let requestPermission: () -> Void
    let cancel: () -> Void
    let retry: () -> Void
    var translateSelection: () -> Void = {}
    var translateScreenshot: () -> Void = {}
    var openSettings: () -> Void = {}
    var manageServices: () -> Void = {}
    var catalog: LanguageCatalog? = nil
    var editorReady: (NSTextView) -> Void = { _ in }
    var translationEditorReady: (NSTextView) -> Void = { _ in }
    @Environment(\.translateXTheme) private var theme
    @Environment(\.translationLayout) private var layout

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).frame(height: 38)
            if let permission {
                permissionContent(permission).padding(20)
            } else if model.showsQuickWorkspace {
                TranslationCommandBar(model: model, compact: true, translateSelection: translateSelection,
                                      translateScreenshot: translateScreenshot, openSettings: openSettings, manageServices: manageServices)
                    .padding(.horizontal, 12).padding(.bottom, 10)
                Group {
                    if model.screenshot != nil {
                        ScreenshotTranslationWorkspace(model: model, catalog: catalog, compact: true, recapture: translateScreenshot)
                    } else {
                        TranslationWorkspace(model: model, catalog: catalog, compact: true, editorReady: editorReady,
                                             translationEditorReady: translationEditorReady)
                    }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            } else {
                TranslationResultView(model: model, retry: retry, compact: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 20).padding(.top, 15)
                footer.padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottomLeading) { AppleTranslationHost(model: model) }
        .task { await catalog?.load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.sourceName.isEmpty ? L10n.string("Quick translation") : model.sourceName)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.muted).lineLimit(1)
            Spacer(minLength: 0)
            TranslateXIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Open in main window", size: 28, action: openInput)
                .disabled(!canOpenInput())
            TranslateXIconButton(symbol: "xmark", label: "Close", size: 28, action: close)
        }.frame(height: 28)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TranslationServicePicker(model: model, openSettings: manageServices)
            Spacer(minLength: 4)
            if model.isBusy {
                Button("Cancel", action: cancel).buttonStyle(TranslateXButtonStyle(kind: .quiet))
            } else {
                Button("Type to translate", action: openInput).buttonStyle(TranslateXButtonStyle())
            }
        }.frame(height: 32)
    }

    private func permissionContent(_ permission: SystemPermission) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: permission == .accessibility ? "accessibility" : "viewfinder")
                    .font(.system(size: 24)).foregroundStyle(theme.accent)
                    .frame(width: 43, height: 43)
                    .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                    .padding(.bottom, 18)
                Text(permission.title).font(.system(size: 19, weight: .semibold)).padding(.bottom, 10)
                Text(permission.explanation)
                    .font(.system(size: 13)).lineSpacing(5).foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 21)
                Button(permission.actionTitle, action: requestPermission).buttonStyle(TranslateXButtonStyle(kind: .primary))
                Button("Use input translation", action: openInput)
                    .buttonStyle(.link).translateXControlCursor().font(.system(size: 12)).padding(.top, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 3)
            .translateXScrollContent()
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension TranslationModel {
    var showsQuickWorkspace: Bool { screenshot != nil || !text.isEmpty || !translatedText.isEmpty || phase == .empty || phase == .composing }
}
