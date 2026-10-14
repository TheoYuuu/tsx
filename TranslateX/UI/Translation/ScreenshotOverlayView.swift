import AppKit
import SwiftUI

enum ScreenshotOutput {
    case originalText, translatedText, originalImage, translatedImage
}

/// A captured image stays at its screen position. Only the compact controls
/// below (or above) it use the app's appearance; the image keeps its own colors.
@MainActor
struct ScreenshotOverlayView: View {
    @Bindable var model: TranslationModel
    let catalog: LanguageCatalog
    let rendered: ScreenshotRenderedImage?
    let imageSize: CGSize
    let toolbarWidth: CGFloat
    var toolbarAbove = false
    var imageOffsetX: CGFloat = 0
    var operationMessage: String? = nil
    var isRendering = false
    var renderFailed = false
    var onRetryRender: () -> Void = {}
    @Binding var showsFullText: Bool
    @Binding var showsStatus: Bool
    let onClose: () -> Void
    let onRecapture: () -> Void
    let onEditInMain: () -> Void
    let onCopy: (ScreenshotOutput) -> Void
    let onSave: (ScreenshotOutput) -> Void

    @Environment(\.translateXTheme) private var theme
    @State private var showsOriginal = false

    private var narrow: Bool { toolbarWidth < 480 }
    private var requesting: Bool { model.phase == .recognizing || model.phase == .translating || model.phase == .preparingLanguages }
    private var canSubmit: Bool { model.canTranslate && !model.needsSourceLanguage && !model.needsReverseLanguage }
    private var needsRecapture: Bool { !requesting && model.screenshot?.regions.isEmpty == true }
    private var hasTranslation: Bool { model.screenshot?.translations.values.contains(where: { !$0.isEmpty }) == true }
    private var overflowCount: Int { rendered?.overflowRegionIDs.count ?? 0 }
    private var overflowMessage: String { String(format: L10n.string("%d passages need the full-text view"), overflowCount) }
    private var showsRenderFeedback: Bool { !showsOriginal && hasTranslation && (isRendering || renderFailed) }
    private var feedback: String {
        if showsRenderFeedback {
            return L10n.string(isRendering ? "Generating translated image…" : "Failed to prepare translated image. Retry.")
        }
        if let operationMessage, !operationMessage.isEmpty { return operationMessage }
        if model.phase == .noText { return L10n.string("No recognized text") }
        return model.toolbarFeedback.isEmpty ? L10n.string("Ready to translate") : model.toolbarFeedback
    }
    private var feedbackDetail: String {
        showsRenderFeedback ? feedback : operationMessage ?? (model.workspaceFeedback.isEmpty ? feedback : model.workspaceFeedback)
    }

    var body: some View {
        VStack(spacing: 8) {
            if toolbarAbove { toolbar }
            image
                .frame(width: toolbarWidth, alignment: .leading)
            if !toolbarAbove { toolbar }
        }
        .frame(width: toolbarWidth, height: imageSize.height + 110)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screenshotOverlay")
        .onChange(of: model.screenshot?.id) {
            showsOriginal = false
            showsFullText = false
            showsStatus = false
        }
    }

    private var image: some View {
        Group {
            if let document = model.screenshot {
                let size = ScreenshotDocument.fittedSize(image: document.pixelSize, available: imageSize)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: NSImage(cgImage: showsOriginal || !hasTranslation ? document.image : rendered?.image ?? document.image,
                                          size: document.pixelSize))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .accessibilityLabel(Text(L10n.string(showsOriginal ? "Original image" : "Translated image")))
                    if !showsOriginal, let rendered {
                        ForEach(document.regions.filter { rendered.overflowRegionIDs.contains($0.id) }) { region in
                            let bounds = ScreenshotDocument.displayBounds(region.bounds, in: size)
                            Button { showsFullText = true } label: {
                                Rectangle().fill(Color.clear)
                                    .overlay { Rectangle().strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(width: max(1, bounds.width), height: max(1, bounds.height))
                            .position(x: bounds.midX, y: bounds.midY)
                            .translateXControlCursor()
                            .translateXTooltip(L10n.string("Screenshot full text"))
                            .accessibilityLabel(Text(L10n.string("Screenshot full text")))
                            .accessibilityIdentifier("screenshotOverlay.overflow.\(region.id)")
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .frame(width: imageSize.width, height: imageSize.height)
            } else {
                Color.clear.frame(width: imageSize.width, height: imageSize.height)
            }
        }
        .offset(x: imageOffsetX)
        .accessibilityIdentifier("screenshotOverlay.image")
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                language(.source)
                icon("arrow.left.arrow.right", "Swap languages", id: "swapLanguages") { model.swapScreenshotLanguages() }
                    .disabled(!model.canSwapLanguages || model.phase == .recognizing)
                language(.target)
                if !narrow { primary; close }
            }.frame(height: 30)
            HStack(spacing: narrow ? 4 : 8) {
                if narrow { primary }
                compare
                copyMenu
                saveMenu
                icon("text.alignleft", "Screenshot full text", id: "fullText") { showsFullText = true }
                    .disabled(model.screenshot?.regions.isEmpty != false)
                Spacer(minLength: 0)
                moreMenu
                if narrow { close }
            }.frame(height: 26)
            feedbackRow.frame(height: 16)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: toolbarWidth, height: 102)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(theme.edge, lineWidth: 1).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.string("Translation toolbar")))
        .accessibilityIdentifier("screenshotOverlay.toolbar")
        .popover(isPresented: $showsFullText, arrowEdge: toolbarAbove ? .bottom : .top) { fullText }
    }

    private func language(_ side: TranslationSide) -> some View {
        let selection = side == .source ? $model.source : $model.target
        let value = side == .source ? model.source : model.target
        let title = L10n.string(side == .source ? "Source language" : "Target language")
        let languages = catalog.languages(for: model.serviceConfiguration, asTarget: side == .target)
        return Menu {
            Picker(title, selection: selection) {
                if side == .source { Text(L10n.string("Detect language")).tag("auto") }
                if value != "auto", !languages.contains(where: { $0.id == value }) {
                    Text(LanguageCatalog.displayName(for: value)).tag(value)
                }
                ForEach(languages) { language in Text(language.name).tag(language.id) }
            }
        } label: {
            Text(value == "auto" ? L10n.string("Detect language") : LanguageCatalog.displayName(for: value))
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(theme.control, in: RoundedRectangle(cornerRadius: 7))
        .disabled(model.isComposing || model.phase == .recognizing)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("screenshotOverlay.\(side == .source ? "sourceLanguage" : "targetLanguage")")
    }

    private var primary: some View {
        Button {
            if requesting { model.cancel() }
            else if needsRecapture { onRecapture() }
            else { model.submit() }
        } label: {
            Text(L10n.string(requesting ? "Stop" : needsRecapture ? "Capture again" : model.hasTranslationFailure ? "Retry" : "Translate"))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minWidth: narrow ? 60 : 72, minHeight: 26)
                .foregroundStyle(requesting ? theme.ink : .white)
                .background(requesting ? theme.control : theme.accent, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .translateXControlCursor()
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!requesting && !needsRecapture && !canSubmit)
        .accessibilityIdentifier("screenshotOverlay.submit")
    }

    private var close: some View {
        icon("xmark", "Close · Esc", id: "close", action: onClose)
    }

    private var compare: some View {
        Button { showsOriginal.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: showsOriginal ? "photo" : "square.on.square")
                if !narrow { Text(L10n.string(showsOriginal ? "Show translation" : "Show original")) }
            }
            .font(.system(size: 11))
            .frame(minWidth: 26, minHeight: 26)
        }
        .buttonStyle(.plain)
        .translateXControlCursor()
        .disabled(!hasTranslation)
        .accessibilityLabel(Text(L10n.string(showsOriginal ? "Show translation" : "Show original")))
        .translateXTooltip(L10n.string(showsOriginal ? "Show translation" : "Show original"))
        .accessibilityIdentifier("screenshotOverlay.compare")
    }

    private var copyMenu: some View {
        Menu {
            Button(L10n.string("Copy original")) { onCopy(.originalText) }.disabled(model.screenshot?.sourceText.isEmpty != false)
            Button(L10n.string("Copy translation")) { onCopy(.translatedText) }.disabled(!hasTranslation)
            Divider()
            Button(L10n.string("Copy original image")) { onCopy(.originalImage) }
            Button(L10n.string("Copy translated image")) { onCopy(.translatedImage) }.disabled(!hasTranslation || rendered == nil)
        } label: { menuLabel("doc.on.doc", "Copy") }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(Text(L10n.string("Copy")))
        .translateXTooltip(L10n.string("Copy"))
        .accessibilityIdentifier("screenshotOverlay.copy")
    }

    private var saveMenu: some View {
        Menu {
            Button(L10n.string("Save original image")) { onSave(.originalImage) }
            Button(L10n.string("Save translated image")) { onSave(.translatedImage) }.disabled(!hasTranslation || rendered == nil)
        } label: { menuLabel("square.and.arrow.down", "Save") }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(Text(L10n.string("Save")))
        .translateXTooltip(L10n.string("Save"))
        .accessibilityIdentifier("screenshotOverlay.save")
    }

    private var moreMenu: some View {
        Menu {
            Button(L10n.string("Open in main window"), action: onEditInMain)
                .disabled(model.phase == .recognizing)
            Button(L10n.string("Capture again"), action: onRecapture)
        } label: { Image(systemName: "ellipsis").frame(width: 20, height: 26) }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(Text(L10n.string("More actions")))
        .translateXTooltip(L10n.string("More actions"))
        .accessibilityIdentifier("screenshotOverlay.more")
    }

    private func menuLabel(_ symbol: String, _ key: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            if !narrow { Text(L10n.string(key)) }
        }.font(.system(size: 11)).frame(minHeight: 26)
    }

    private func icon(_ symbol: String, _ key: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 26) }
            .buttonStyle(TranslateXIconButtonStyle())
            .accessibilityLabel(Text(L10n.string(key)))
            .translateXTooltip(L10n.string(key))
            .accessibilityIdentifier("screenshotOverlay.\(id)")
    }

    private var feedbackRow: some View {
        HStack(spacing: 6) {
            if overflowCount > 0 {
                Button { showsFullText = true } label: {
                    Label(overflowMessage, systemImage: "text.badge.plus")
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.isDark ? Color.orange : Color(red: 0.58, green: 0.31, blue: 0.02))
                .translateXControlCursor()
                .accessibilityIdentifier("screenshotOverlay.overflowNotice")
                Spacer(minLength: 0)
            }
            if overflowCount == 0 || !narrow || operationMessage != nil || model.hasTranslationFailure || model.phase == .noText || requesting || showsRenderFeedback {
                Button {
                    if showsRenderFeedback && renderFailed && !isRendering { onRetryRender() }
                    else { showsStatus = true }
                } label: {
                    HStack(spacing: 4) {
                        if requesting || (showsRenderFeedback && isRendering) { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10) }
                        else if showsRenderFeedback && renderFailed { Image(systemName: "exclamationmark.triangle") }
                        else { TranslationStatusLight(phase: model.phase) }
                        Text(feedback).lineLimit(1)
                    }.font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.hasTranslationFailure || model.phase == .noText || (showsRenderFeedback && renderFailed) ? Color.orange : theme.muted)
                .translateXTooltip(feedbackDetail)
                .accessibilityLabel(Text(feedbackDetail))
                .accessibilityIdentifier("screenshotOverlay.status")
                .popover(isPresented: $showsStatus) {
                    Text(feedbackDetail)
                        .font(.system(size: 12)).textSelection(.enabled).padding(14).frame(width: min(320, toolbarWidth - 20))
                }
            }
            if overflowCount == 0 { Spacer(minLength: 0) }
        }
    }

    private var fullText: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.string("Screenshot full text")).font(.system(size: 13, weight: .semibold))
                Spacer()
                icon("xmark", "Close", id: "closeFullText") { showsFullText = false }
            }
            if overflowCount > 0 {
                Text(L10n.string("Long passages remain unchanged in the image. Open the full text to read their translations."))
                    .font(.system(size: 11)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let document = model.screenshot {
                        ForEach(document.regions) { region in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(region.text).font(.system(size: 12)).foregroundStyle(theme.muted)
                                Text(document.translations[region.id] ?? L10n.string("Translation pending"))
                                    .font(.system(size: 14)).foregroundStyle(theme.ink)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            Divider()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
            }.frame(height: 300)
            Button(L10n.string("Open in main window"), action: onEditInMain)
                .buttonStyle(TranslateXButtonStyle(kind: .quiet))
        }
        .padding(14)
        .frame(width: min(440, max(280, toolbarWidth - 24)))
        .environment(\.translateXTheme, theme)
        .accessibilityIdentifier("screenshotOverlay.fullTextContent")
    }
}
