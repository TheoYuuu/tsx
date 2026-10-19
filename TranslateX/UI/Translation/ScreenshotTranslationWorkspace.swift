import AppKit
import SwiftUI

/// Screenshot editing lives in the existing main window. Stable OCR region IDs
/// link image hit targets, native text editors, generated text and corrections.
struct ScreenshotTranslationWorkspace: View {
    @Bindable var model: TranslationModel
    let catalog: LanguageCatalog?
    var compact = false
    var save: (ScreenshotOutput) -> Void = { _ in }
    @Environment(\.translateXTheme) private var theme
    @Environment(\.translationLayout) private var layout
    #if TRANSLATEX_VISUAL_QA
    @Environment(\.translationReviewCaptureMode) private var reviewCaptureMode
    #endif
    @State private var sourceText = false
    @State private var targetImage = false
    @State private var selectedRegion: UUID?
    @State private var zoom: CGFloat = 1
    @State private var renderedImage: ScreenshotRenderedImage?
    @State private var isRendering = false
    @State private var renderFailed = false
    @State private var renderRetry = 0

    private struct RenderRequest: Equatable {
        let document: ScreenshotDocument?
        let retry: Int
    }

    var body: some View {
        if let document = model.screenshot {
            TranslationSplitLayout(orientation: layout) {
                pane(document, side: .source)
                Rectangle().fill(theme.divider).accessibilityHidden(true)
                pane(document, side: .target).background(theme.secondaryCard)
            }
            .background(theme.workspace)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.divider, lineWidth: 1).allowsHitTesting(false) }
            .serviceDesignMetric(compact ? "quick.screenshotContent" : "main.screenshotContent")
            #if TRANSLATEX_VISUAL_QA
            .onAppear { targetImage = reviewCaptureMode == "image"; sourceText = false }
            #endif
            .task(id: RenderRequest(document: targetImage ? document : nil, retry: renderRetry)) {
                guard targetImage, !document.translations.isEmpty else {
                    renderedImage = nil; isRendering = false; renderFailed = false
                    return
                }
                isRendering = true; renderFailed = false
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                let rendered = await ScreenshotImageRenderer.renderPreview(document)
                guard !Task.isCancelled else { return }
                renderedImage = rendered; isRendering = false; renderFailed = rendered == nil
            }
            .onChange(of: document.id) {
                selectedRegion = nil; zoom = 1; sourceText = false; targetImage = false; renderedImage = nil
            }
        }
    }

    private func pane(_ document: ScreenshotDocument, side: TranslationSide) -> some View {
        let imageVisible = side == .source ? !sourceText : targetImage
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                language(side)
                    // Align the native popup's visible border, not its inset alignment rect.
                    .padding(.leading, catalog == nil ? 0 : 5)
                Spacer(minLength: 2)
                tabs(side)
                CopyButton(text: side == .source ? document.sourceText : document.translatedText,
                           label: side == .source ? "Copy original" : "Copy translation", size: 26, outlined: true)
                    .disabled(model.isComposing)
            }.frame(height: 30)
            if imageVisible { imageCanvas(document, side: side) }
            else { regionEditors(document, side: side) }
            footer(document, side: side, imageVisible: imageVisible)
        }.padding(10)
    }

    private func tabs(_ side: TranslationSide) -> some View {
        HStack(spacing: 1) {
            if side == .source {
                tab("Image", selected: !sourceText, id: "sourceImage") { sourceText = false }
                tab("Original", selected: sourceText, id: "sourceText") { sourceText = true }
            } else {
                tab("Translation", selected: !targetImage, id: "targetText") { targetImage = false }
                tab("Translated image", selected: targetImage, id: "targetImage") { targetImage = true }
            }
        }.padding(2).background(theme.control, in: RoundedRectangle(cornerRadius: 7))
            .disabled(model.isComposing)
    }

    private func tab(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.string(title)).font(.system(size: 11, weight: selected ? .medium : .regular)).lineLimit(1)
                .padding(.horizontal, 7).frame(height: 24)
                .foregroundStyle(selected ? theme.ink : theme.muted)
                .background(selected ? theme.card : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).translateXControlCursor().accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("screenshot.\(id)")
    }

    private func language(_ side: TranslationSide) -> some View {
        return Group {
            if let catalog {
                LanguageMenu(label: L10n.string(side == .source ? "Source language" : "Target language"),
                    selection: side == .source ? $model.source : $model.target,
                    languages: catalog.languages(for: model.serviceConfiguration, asTarget: side == .target),
                    includeAuto: side == .source, prominent: false, enabled: !model.isComposing, maximumWidth: 150)
            } else {
                Text(LanguageCatalog.displayName(for: side == .source ? model.source : model.target)).font(.system(size: 12))
            }
        }.fixedSize(horizontal: true, vertical: true)
    }

    private func footer(_ document: ScreenshotDocument, side: TranslationSide, imageVisible: Bool) -> some View {
        HStack(spacing: 5) {
            if side == .target, targetImage, isRendering {
                ProgressView().controlSize(.mini)
                Text(L10n.string("Generating translated image…"))
            } else if side == .target, targetImage, renderFailed {
                Button(L10n.string("Failed to prepare translated image. Retry.")) { renderRetry += 1 }
                    .buttonStyle(.plain).foregroundStyle(theme.accent).translateXControlCursor()
            } else {
                Text(L10n.string(side == .source ? (sourceText ? "Correct recognized text, then retranslate a region" : "Select an image region to find its translation")
                                 : "Edit text to update the translated image"))
            }
            Spacer(minLength: 1)
            if imageVisible {
                icon("minus", "Zoom out") { zoom = max(1, zoom - 0.25) }.disabled(zoom <= 1 || model.isComposing)
                Button("\(Int(zoom * 100))%") { zoom = 1 }.buttonStyle(.plain).translateXControlCursor()
                    .translateXTooltip(L10n.string("Fit image")).disabled(model.isComposing)
                icon("plus", "Zoom in") { zoom = min(3, zoom + 0.25) }.disabled(zoom >= 3 || model.isComposing)
            }
            if side == .target {
                ScreenshotActionMenu(title: "Save", savesImage: true, items: [
                    ScreenshotMenuItem(title: "Save translated image", enabled: !document.translations.isEmpty) { save(.translatedImage) },
                    ScreenshotMenuItem(title: "Save original image") { save(.originalImage) }
                ]).disabled(model.isComposing)
                    .translateXTooltip(L10n.string("Save")).accessibilityLabel(Text(L10n.string("Save")))
                    .accessibilityIdentifier("screenshot.save")
            }
        }.font(.system(size: 10)).foregroundStyle(theme.muted).lineLimit(1).frame(height: 28)
    }

    private func regionEditors(_ document: ScreenshotDocument, side: TranslationSide) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if document.regions.isEmpty {
                        Text(model.phase == .recognizing ? "Recognizing text…" : "No recognized text")
                            .font(.system(size: 13)).foregroundStyle(theme.muted)
                    }
                    ForEach(Array(document.regions.enumerated()), id: \.element.id) { index, region in
                        regionEditor(region, index: index, document: document, side: side).id(region.id)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    // Extend only the scroll viewport; region cards keep their existing width.
                    .padding(.trailing, 10).translateXScrollContent()
            }
            .padding(.trailing, -10)
            .onChange(of: selectedRegion) { if let selectedRegion { proxy.scrollTo(selectedRegion, anchor: .center) } }
            .onAppear { if let selectedRegion { proxy.scrollTo(selectedRegion, anchor: .center) } }
        }.accessibilityIdentifier("screenshot.\(side == .source ? "originalText" : "translatedText")")
    }

    private func regionEditor(_ region: ScreenshotRegion, index: Int, document: ScreenshotDocument, side: TranslationSide) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(index + 1)").monospacedDigit().frame(minWidth: 18, minHeight: 18)
                    .background(theme.control, in: RoundedRectangle(cornerRadius: 4))
                Text(L10n.string(side == .source ? "Recognized text" : document.isTranslationEdited(region.id) ? "Edited translation" : "Translation"))
                if side == .source, region.confidence < 0.5 {
                    Image(systemName: "exclamationmark.triangle").translateXTooltip(L10n.string("Check recognized text"))
                }
                Spacer(minLength: 2)
                if side == .source {
                    Button { model.submitScreenshotRegion(region.id) } label: {
                        HStack(spacing: 4) { ScreenshotSymbol(symbol: .retranslate); Text(L10n.string("Retranslate")) }
                            .padding(.horizontal, 5).frame(height: 24)
                    }.buttonStyle(ScreenshotIconButtonStyle(tint: theme.accent))
                        .disabled(model.isBusy || model.isComposing || !model.canTranslate || model.needsSourceLanguage || model.needsReverseLanguage)
                        .translateXTooltip(L10n.string("Retranslate this region"))
                        .accessibilityIdentifier("screenshot.retranslate.\(region.id)")
                } else if document.isTranslationEdited(region.id) {
                    icon("arrow.uturn.backward", "Restore this translation") { model.restoreScreenshotRegionTranslation(region.id) }
                        .disabled(model.isComposing)
                }
            }.font(.system(size: 10)).foregroundStyle(theme.muted).frame(height: 24)
            ScreenshotRegionEditor(
                text: side == .source ? region.text : document.translations[region.id] ?? "",
                placeholder: side == .source ? "" : L10n.string("Translation pending"),
                fontSize: region.role == .heading ? (compact ? 18 : 20) : (compact ? 14 : 16),
                accessibilityName: side == .source ? "Original text" : "Translation, editable",
                onEdit: { value, composing in
                    // Keep typing and scrolling independent. Image clicks select
                    // a region; an edit must not scroll its own editor mid-input.
                    model.editScreenshotRegion(region.id, text: value, side: side, isComposing: composing)
                },
                onSubmit: { if model.isBusy { model.cancel() } else { model.submitScreenshotRegion(region.id) } },
                canUndo: { model.canUndoWorkspaceChange }, canRedo: { model.canRedoWorkspaceChange },
                undo: { model.undoWorkspaceChange() }, redo: { model.redoWorkspaceChange() },
                onCancel: { if model.isBusy { model.cancel(); return true }; return false }
            ).accessibilityIdentifier("screenshot.region.\(side).\(region.id)")
        }
        .padding(8)
        .background(selectedRegion == region.id ? theme.accent.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selectedRegion == region.id ? theme.accent.opacity(0.45) : theme.divider.opacity(0.5), lineWidth: 1).allowsHitTesting(false) }
    }

    private func imageCanvas(_ document: ScreenshotDocument, side: TranslationSide) -> some View {
        GeometryReader { geometry in
            let size = ScreenshotDocument.fittedSize(image: document.pixelSize, available: geometry.size, zoom: zoom)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Image(nsImage: NSImage(cgImage: side == .target ? renderedImage?.image ?? document.image : document.image, size: document.pixelSize))
                        .resizable().interpolation(.high).frame(width: size.width, height: size.height)
                        .accessibilityLabel(Text(L10n.string(side == .source ? "Original image" : "Translated image")))
                    ForEach(Array(document.regions.enumerated()), id: \.element.id) { index, region in
                        regionOverlay(region, index: index, document: document, size: size, side: side)
                    }
                }
                .frame(width: size.width, height: size.height)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .center)
                .padding(.trailing, 10)
                .translateXScrollContent()
            }.padding(.trailing, -10)
                .accessibilityIdentifier(side == .source ? "screenshot.preview" : "screenshot.imageCanvas")
        }
    }

    private func regionOverlay(_ region: ScreenshotRegion, index: Int, document: ScreenshotDocument, size: CGSize, side: TranslationSide) -> some View {
        let card = ScreenshotDocument.displayBounds(region.bounds, in: size)
        let selected = selectedRegion == region.id
        let overflows = side == .target && renderedImage?.overflowRegionIDs.contains(region.id) == true
        return Button {
            selectedRegion = region.id
            targetImage = false
        } label: {
            Rectangle().fill(selected ? theme.accent.opacity(0.1) : .clear)
                .overlay { Rectangle().strokeBorder(overflows ? .orange : theme.accent.opacity(selected ? 0.8 : 0.3), style: StrokeStyle(lineWidth: 1, dash: overflows ? [3, 2] : [])) }
                .overlay(alignment: .topLeading) {
                    if card.minX >= 18 && card.height >= 12 {
                        Text("\(index + 1)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 14, height: 12).background(theme.accent, in: RoundedRectangle(cornerRadius: 2))
                            .offset(x: -17)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).translateXControlCursor().disabled(model.isComposing)
        .frame(width: max(1, card.width), height: max(1, card.height)).position(x: card.midX, y: card.midY)
        .accessibilityLabel(Text(side == .source ? region.text : document.translations[region.id] ?? L10n.string("Translation pending")))
        .translateXTooltip(L10n.string(overflows ? "Screenshot full text" : "Edit region"))
        .accessibilityIdentifier("screenshot.imageRegion.\(side).\(region.id)")
    }

    private func icon(_ symbol: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 26) }
            .buttonStyle(ScreenshotIconButtonStyle()).accessibilityLabel(Text(L10n.string(key))).translateXTooltip(L10n.string(key))
    }
}

/// OCR paragraph height is a mask, not a font size or a fixed two-line preview.
/// Line metrics follow the original screenshot scale; overflow stays in details.
@MainActor
struct ScreenshotOverlayMetrics {
    let frame: CGRect
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let lineLimit: Int

    init(region: ScreenshotRegion, imageSize: CGSize) {
        let rect = ScreenshotDocument.displayBounds(region.bounds, in: imageSize)
        let lines = (region.lineBounds.isEmpty ? [region.bounds] : region.lineBounds).sorted { $0.midY > $1.midY }
        let heights = lines.map(\.height).sorted()
        let glyphHeight = heights[heights.count / 2] * imageSize.height
        fontSize = min(28, max(7, glyphHeight * 1.12))
        let font = NSFont.systemFont(ofSize: fontSize)
        let naturalHeight = ceil(font.ascender - font.descender + font.leading)
        let advances = zip(lines, lines.dropFirst()).map { ($0.midY - $1.midY) * imageSize.height }.filter { $0 > 0 }.sorted()
        let advance = advances.isEmpty ? fontSize * 1.3 : advances[advances.count / 2]
        let pitch = max(naturalHeight, min(fontSize * 1.45, advance))
        lineSpacing = max(0, pitch - naturalHeight)
        let x = max(0, rect.minX - 2), y = max(0, rect.minY - 2)
        frame = CGRect(x: x, y: y, width: min(imageSize.width - x, max(36, rect.width + 4)),
            height: min(imageSize.height - y, max(naturalHeight + 4, rect.height + 4)))
        lineLimit = max(1, Int(floor(max(0, frame.height - 4 - naturalHeight) / pitch)) + 1)
    }
}

/// One reading scroll surface with naturally sized native paragraph editors.
/// Font/paragraph metrics match the normal translation editors (1.3 line height).
private struct ScreenshotRegionEditor: View {
    let text: String
    let placeholder: String
    let fontSize: CGFloat
    let accessibilityName: String
    let onEdit: (String, Bool) -> Void
    let onSubmit: () -> Void
    var canUndo: () -> Bool = { false }
    var canRedo: () -> Bool = { false }
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var onCancel: () -> Bool = { false }
    @Environment(\.translateXTheme) private var theme
    @State private var width: CGFloat = 240
    private var height: CGFloat {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = fontSize * 1.3; style.maximumLineHeight = fontSize * 1.3
        let measured = (text.isEmpty ? " " : text).boundingRect(with: CGSize(width: max(40, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: style])
        return max(fontSize * 1.3 + 8, ceil(measured.height) + 8)
    }
    var body: some View {
        TranslationTextEditor(text: Binding(get: { text }, set: { _ in }), onEdit: onEdit, onSubmit: onSubmit,
            fontSize: fontSize, accessibilityID: "screenshot.paragraph", accessibilityName: accessibilityName,
            managesWorkspaceUndo: true, canUndoWorkspace: canUndo, canRedoWorkspace: canRedo,
            undoWorkspace: undo, redoWorkspace: redo, onCancel: onCancel)
            .frame(height: height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .topLeading) {
                if text.isEmpty { Text(placeholder).font(.system(size: fontSize)).foregroundStyle(theme.faint).allowsHitTesting(false) }
            }
    }
}
