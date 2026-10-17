import AppKit
import SwiftUI

enum ScreenshotOutput {
    case originalText, translatedText, originalImage, translatedImage
}

/// A captured image starts at its screen position. Only the compact controls
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
    var onImageDrag: (ScreenshotImageDragEvent) -> Void = { _ in }
    @Binding var showsFullText: Bool
    var onManageServices: () -> Void = {}
    let onClose: () -> Void
    let onRecapture: () -> Void
    let onEditInMain: () -> Void
    let onCopy: (ScreenshotOutput) -> Void
    let onSave: (ScreenshotOutput) -> Void

    @Environment(\.translateXTheme) private var theme
    @State private var showsOriginal = false
    @State private var controlsWidth: CGFloat = 660

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
        .frame(width: toolbarWidth, height: imageSize.height + ScreenshotOverlayPlacement.toolbarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screenshotOverlay")
        .onChange(of: model.screenshot?.id) {
            showsOriginal = false
            showsFullText = false
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
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color(.sRGB, red: 179 / 255, green: 207 / 255, blue: 242 / 255), lineWidth: 1.5)
                                .allowsHitTesting(false)
                        }
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                        .overlay { ScreenshotImageDragSurface(onDrag: onImageDrag) }
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
        .overlay(alignment: .bottom) { contextualFeedback.padding(8) }
        .offset(x: imageOffsetX)
        .accessibilityIdentifier("screenshotOverlay.image")
    }

    private var toolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ScreenshotServicePicker(model: model, openSettings: onManageServices)
                    .disabled(model.isComposing || model.phase == .recognizing)
                    .accessibilityIdentifier("screenshotOverlay.service")
                HStack(spacing: 0) {
                    language(.source)
                    icon("arrow.right", "Swap languages", id: "swapLanguages") { model.swapScreenshotLanguages() }
                        .disabled(!model.canSwapLanguages || model.phase == .recognizing)
                    language(.target)
                }
                .padding(1)
                .frame(height: 30)
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.divider, lineWidth: theme.increaseContrast ? 1 : 0.5).allowsHitTesting(false) }
                Rectangle().fill(theme.divider).frame(width: 1, height: 18).padding(.horizontal, 3).accessibilityHidden(true)
                primary
                compare
                icon("doc.text", "View full translation", id: "fullText") { showsFullText = true }
                    .disabled(model.screenshot?.regions.isEmpty != false)
                icon("doc.on.doc", "Copy translation", id: "copy") { onCopy(.translatedText) }
                    .disabled(!hasTranslation)
                saveMenu
                moreMenu
                close
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controlsWidth = $0 }
        }
        .scrollIndicators(.hidden)
        .frame(width: min(controlsWidth, toolbarWidth), height: 44)
        .background {
            RoundedRectangle(cornerRadius: 11).fill(theme.card)
                .shadow(color: .black.opacity(theme.isDark ? 0.13 : 0.10), radius: 10, y: 3)
        }
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(theme.edge, lineWidth: theme.increaseContrast ? 1 : 0.5).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.string("Translation toolbar")))
        .accessibilityIdentifier("screenshotOverlay.toolbar")
        .popover(isPresented: $showsFullText, arrowEdge: toolbarAbove ? .bottom : .top) { fullText }
    }

    private func language(_ side: TranslationSide) -> some View {
        LanguageMenu(label: L10n.string(side == .source ? "Source language" : "Target language"),
            selection: side == .source ? $model.source : $model.target,
            languages: catalog.languages(for: model.serviceConfiguration, asTarget: side == .target),
            includeAuto: side == .source, prominent: false,
            enabled: !model.isComposing && model.phase != .recognizing,
            displayTitle: side == .source && model.source == "auto" ? model.resolvedSource.map {
                String(format: L10n.string("Auto · %@"), LanguageCatalog.displayName(for: $0))
            } : nil, maximumWidth: 116, grouped: true)
            .fixedSize()
            .translateXTooltip(L10n.string(side == .source ? "Source language" : "Target language"))
            .accessibilityIdentifier("screenshotOverlay.\(side == .source ? "sourceLanguage" : "targetLanguage")")
    }

    private var primary: some View {
        let title = requesting ? "Stop" : needsRecapture ? "Capture again" : "Retranslate"
        return Button {
            if requesting { model.cancel() }
            else if needsRecapture { onRecapture() }
            else { model.submit() }
        } label: {
            Group {
                if requesting { Image(systemName: "stop.fill").font(.system(size: 12)) }
                else if needsRecapture { Image(systemName: "viewfinder").font(.system(size: 16)) }
                else { ScreenshotSymbol(symbol: .retranslate) }
            }.frame(width: 30, height: 30)
        }
        .buttonStyle(ScreenshotIconButtonStyle(tint: requesting ? nil : theme.accent))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!requesting && !needsRecapture && !canSubmit)
        .accessibilityLabel(Text(L10n.string(title)))
        .translateXTooltip(L10n.string(title))
        .accessibilityIdentifier("screenshotOverlay.submit")
    }

    private var close: some View {
        icon("xmark", "Close · Esc", id: "close", tint: .red, action: onClose)
    }

    private var compare: some View {
        icon("photo", showsOriginal ? "Show translation" : "Show original", id: "compare", selected: showsOriginal) {
            showsOriginal.toggle()
        }.disabled(!hasTranslation)
    }

    private var saveMenu: some View {
        ScreenshotActionMenu(title: "Save", savesImage: true, items: [
            ScreenshotMenuItem(title: "Save translated image", enabled: hasTranslation) { onSave(.translatedImage) },
            ScreenshotMenuItem(title: "Save original image") { onSave(.originalImage) }
        ])
        .translateXTooltip(L10n.string("Save"))
        .accessibilityIdentifier("screenshotOverlay.save")
    }

    private var moreMenu: some View {
        ScreenshotActionMenu(title: "More actions", items: [
            ScreenshotMenuItem(title: "Copy translated image", symbol: "photo.on.rectangle", enabled: hasTranslation) { onCopy(.translatedImage) },
            ScreenshotMenuItem(title: "Copy original", symbol: "list.clipboard", enabled: model.screenshot?.sourceText.isEmpty == false) { onCopy(.originalText) },
            ScreenshotMenuItem(title: "Copy original image", symbol: "photo") { onCopy(.originalImage) },
            .separator,
            ScreenshotMenuItem(title: "Edit in main window", symbol: "macwindow", enabled: model.phase != .recognizing, action: onEditInMain),
            ScreenshotMenuItem(title: "Capture again", symbol: "viewfinder", action: onRecapture)
        ])
        .translateXTooltip(L10n.string("More actions"))
        .accessibilityIdentifier("screenshotOverlay.more")
    }

    private func icon(_ symbol: String, _ key: String, id: String, tint: Color? = nil, selected: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15)).frame(width: 30, height: 28) }
            .buttonStyle(ScreenshotIconButtonStyle(tint: tint, selected: selected))
            .accessibilityLabel(Text(L10n.string(key)))
            .translateXTooltip(L10n.string(key))
            .accessibilityIdentifier("screenshotOverlay.\(id)")
    }

    @ViewBuilder private var contextualFeedback: some View {
        if requesting || showsRenderFeedback || model.hasTranslationFailure || model.phase == .noText || operationMessage != nil || overflowCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                if requesting || showsRenderFeedback || model.hasTranslationFailure || model.phase == .noText || operationMessage != nil {
                    HStack(spacing: 6) {
                        if requesting || (showsRenderFeedback && isRendering) { ProgressView().controlSize(.mini) }
                        Text(feedbackDetail).font(.system(size: 11)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        if showsRenderFeedback && renderFailed && !isRendering {
                            Button(L10n.string("Retry"), action: onRetryRender).buttonStyle(.plain).foregroundStyle(theme.accent)
                        }
                    }.accessibilityIdentifier("screenshotOverlay.feedback")
                }
                if overflowCount > 0 {
                    Button { showsFullText = true } label: {
                        Label(overflowMessage, systemImage: "doc.text").font(.system(size: 11)).lineLimit(2)
                    }.buttonStyle(.plain).translateXControlCursor().foregroundStyle(theme.accent)
                        .accessibilityIdentifier("screenshotOverlay.overflowNotice")
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.edge, lineWidth: 1).allowsHitTesting(false) }
            .frame(maxWidth: max(1, min(imageSize.width - 16, 400)))
        }
    }

    private var fullText: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.string("Full translation")).font(.system(size: 13, weight: .semibold))
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
            HStack {
                Text(LanguageCatalog.displayName(for: model.target)).font(.system(size: 11)).foregroundStyle(theme.muted)
                Spacer()
                CopyButton(text: model.screenshot?.translatedText ?? "", label: "Copy translation", size: 30).disabled(!hasTranslation)
            }
        }
        .padding(14)
        .frame(width: min(440, max(280, toolbarWidth - 24)))
        .environment(\.translateXTheme, theme)
        .accessibilityIdentifier("screenshotOverlay.fullTextContent")
    }
}

/// This surface belongs only to the image layer. The overflow buttons and
/// contextual actions above it retain their own mouse handling.
private struct ScreenshotImageDragSurface: NSViewRepresentable {
    let onDrag: (ScreenshotImageDragEvent) -> Void

    func makeNSView(context: Context) -> ScreenshotImageDragView { ScreenshotImageDragView() }
    func updateNSView(_ view: ScreenshotImageDragView, context: Context) { view.onDrag = onDrag }
}

@MainActor
final class ScreenshotImageDragView: NSView {
    var onDrag: (ScreenshotImageDragEvent) -> Void = { _ in }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onDrag(.began(window.convertPoint(toScreen: event.locationInWindow)))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        onDrag(.moved(window.convertPoint(toScreen: event.locationInWindow)))
    }
    override func mouseUp(with event: NSEvent) { onDrag(.ended) }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { onDrag(.ended) }
        super.viewWillMove(toWindow: newWindow)
    }
}
