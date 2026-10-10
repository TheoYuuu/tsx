import SwiftUI

struct QuickTranslationView: View {
    static let permissionWindowSize = NSSize(width: 440, height: 320)
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
            header
            if let permission {
                permissionContent(permission)
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
            if permission != nil {
                Image(systemName: "macwindow").font(.system(size: 13))
                    .foregroundStyle(theme.muted).accessibilityHidden(true)
            }
            Text(model.sourceName.isEmpty ? L10n.string("Quick translation") : model.sourceName)
                .font(.system(size: permission == nil ? 11 : 12, weight: .medium))
                .foregroundStyle(theme.muted).lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                windowControl(symbol: "arrow.up.left.and.arrow.down.right", label: "Open in main window", action: openInput)
                    .disabled(!canOpenInput())
                windowControl(symbol: "xmark", label: "Close", action: close)
            }
        }
        .padding(.leading, 20).padding(.trailing, 14)
        .frame(height: permission == nil ? 38 : 52)
        .background(permission == nil ? Color.clear : theme.secondaryCard)
        .overlay(alignment: .bottom) {
            if permission != nil { Rectangle().fill(theme.divider).frame(height: 1) }
        }
    }

    private func windowControl(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // SF Symbols have different intrinsic bounds at the same font size.
            // Fit their visible glyphs into one square, independently of the hit area.
            Image(systemName: symbol).resizable().scaledToFit()
                .frame(width: 16, height: 16)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(TranslateXIconButtonStyle())
        .translateXTooltip(L10n.string(label))
        .accessibilityLabel(Text(L10n.string(label)))
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        Image(systemName: permission == .accessibility ? "accessibility" : "viewfinder")
                            .font(.system(size: 27)).foregroundStyle(theme.accent)
                            .frame(width: 46, height: 46)
                            .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(permission.name).font(.system(size: 11)).foregroundStyle(theme.muted)
                            Text(permission.title).font(.system(size: 19, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(permission.explanation)
                        .font(.system(size: 13)).lineSpacing(5).foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 19)
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "checkmark.shield").font(.system(size: 13))
                            .padding(.top, 1).accessibilityHidden(true)
                        Text(permission.privacyNote).font(.system(size: 11)).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }.foregroundStyle(theme.muted).padding(.top, 15)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26).padding(.top, 25).padding(.bottom, 20)
                .translateXScrollContent()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { inputButton; permissionButton }
                VStack(alignment: .trailing, spacing: 8) { permissionButton; inputButton }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 26).padding(.bottom, 24)
        }
    }

    private var inputButton: some View {
        Button(action: openInput) { Text("Use input translation").frame(minHeight: 34) }
            .buttonStyle(TranslateXButtonStyle())
            .overlay { RoundedRectangle(cornerRadius: theme.buttonRadius).strokeBorder(theme.edge, lineWidth: 0.75).allowsHitTesting(false) }
            .disabled(!canOpenInput())
    }

    private var permissionButton: some View {
        Button(action: requestPermission) {
            HStack(spacing: 7) {
                Text("Go to System Settings")
                Image(systemName: "arrow.up.right").font(.system(size: 11)).accessibilityHidden(true)
            }.frame(minHeight: 34)
        }.buttonStyle(TranslateXButtonStyle(kind: .primary))
    }
}

extension TranslationModel {
    var showsQuickWorkspace: Bool { screenshot != nil || !text.isEmpty || !translatedText.isEmpty || phase == .empty || phase == .composing }
}
