import AppKit
import SwiftUI

/// Both capture modes share the same local image and editable region records.
/// The provider receives text only; there is no background repair or image upload.
struct ScreenshotTranslationWorkspace: View {
    @Bindable var model: TranslationModel
    let catalog: LanguageCatalog?
    var compact = false
    var recapture: () -> Void = {}
    @Environment(\.translateXTheme) private var theme
    @Environment(\.translationLayout) private var layout
    #if TRANSLATEX_VISUAL_QA
    @Environment(\.translationReviewCaptureMode) private var reviewCaptureMode
    #endif
    @State private var imageMode = false
    @State private var showsOriginal = false
    @State private var editsSource = false
    @State private var zoom: CGFloat = 1
    @State private var selectedRegion: UUID?

    var body: some View {
        if let document = model.screenshot {
            VStack(spacing: 8) {
                modeBar
                if imageMode {
                    HStack(spacing: 8) {
                        language(.source)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(theme.faint).accessibilityHidden(true)
                        language(.target)
                        Spacer(minLength: 0)
                        CopyButton(text: model.translatedText, label: "Copy translation", size: 26).disabled(model.isComposing)
                    }.frame(height: 28).padding(.horizontal, 10)
                }
                Group {
                    if imageMode {
                        imageCanvas(document, overlays: true)
                    } else {
                        TranslationSplitLayout(orientation: layout) {
                            sourcePane(document)
                            Rectangle().fill(theme.divider).accessibilityHidden(true)
                            translatedPane(document).background(theme.secondaryCard)
                        }
                    }
                }
                .background(theme.workspace)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.divider, lineWidth: 1).allowsHitTesting(false) }
                .serviceDesignMetric(compact ? "quick.screenshotContent" : "main.screenshotContent")
            }
            #if TRANSLATEX_VISUAL_QA
            .onAppear {
                imageMode = reviewCaptureMode == "image" || reviewCaptureMode == "original"
                showsOriginal = reviewCaptureMode == "original"
            }
            #endif
            .onChange(of: imageMode) { selectedRegion = nil }
            .onChange(of: showsOriginal) { selectedRegion = nil }
            .onChange(of: zoom) { selectedRegion = nil }
            .onChange(of: document.id) { zoom = 1; selectedRegion = nil; showsOriginal = false; editsSource = false }
        }
    }

    private var modeBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { modes; Spacer(minLength: 2); imageControls; recaptureButton }
            VStack(spacing: 5) {
                HStack { modes; Spacer(); recaptureButton }
                if imageMode { HStack { Spacer(); imageControls } }
            }
        }.padding(.horizontal, 4)
    }
    private var modes: some View {
        HStack(spacing: 2) {
            modeButton("Text mode", selected: !imageMode) { imageMode = false }
            modeButton("Image mode", selected: imageMode) { imageMode = true }
        }.padding(3).background(theme.control, in: RoundedRectangle(cornerRadius: 10))
            .disabled(model.isComposing)
    }
    private func modeButton(_ key: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.string(key)).font(.system(size: 11, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? theme.ink : theme.muted)
                .padding(.horizontal, 11).frame(height: 24)
                .background(selected ? theme.card : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).translateXControlCursor().accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("screenshot.\(key == "Text mode" ? "textMode" : "imageMode")")
    }
    @ViewBuilder private var imageControls: some View {
        if imageMode {
            HStack(spacing: 4) {
                Button { showsOriginal.toggle() } label: {
                    Text(L10n.string(showsOriginal ? "Show translation" : "Show original"))
                        .font(.system(size: 11)).padding(.horizontal, 7).frame(height: 26)
                }.buttonStyle(.plain).translateXControlCursor().accessibilityIdentifier("screenshot.compare")
                icon("minus", "Zoom out") { zoom = max(0.5, zoom - 0.25) }.disabled(zoom <= 0.5)
                Text("\(Int(zoom * 100))%").font(.system(size: 10).monospacedDigit()).foregroundStyle(theme.muted)
                    .frame(width: 34).accessibilityLabel(Text(L10n.string("Zoom")))
                icon("plus", "Zoom in") { zoom = min(3, zoom + 0.25) }.disabled(zoom >= 3)
                icon("arrow.up.left.and.arrow.down.right", "Fit image") { zoom = 1 }
            }.disabled(model.isComposing)
        }
    }
    private var recaptureButton: some View {
        Button(action: recapture) {
            Text("Capture again").font(.system(size: 11)).foregroundStyle(theme.muted)
                .padding(.horizontal, 5).frame(height: 28)
        }.buttonStyle(.plain).translateXControlCursor().disabled(model.isComposing)
    }
    private func icon(_ symbol: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 26) }
            .buttonStyle(TranslateXIconButtonStyle()).accessibilityLabel(Text(L10n.string(key))).translateXTooltip(L10n.string(key))
    }
    private func language(_ side: TranslationSide) -> some View {
        Group {
            if let catalog {
                LanguageMenu(label: L10n.string(side == .source ? "Source language" : "Target language"),
                    selection: side == .source ? $model.source : $model.target,
                    languages: catalog.languages(for: model.serviceConfiguration, asTarget: side == .target),
                    includeAuto: side == .source, prominent: false, enabled: !model.isComposing)
            } else {
                Text(LanguageCatalog.displayName(for: side == .source ? model.source : model.target)).font(.system(size: 12, weight: .medium))
            }
        }.fixedSize()
    }
    private func sourcePane(_ document: ScreenshotDocument) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                language(.source)
                Spacer(minLength: 2)
                icon(editsSource ? "photo" : "pencil", editsSource ? "Show screenshot" : "Edit recognized text") { editsSource.toggle() }
                    .disabled(model.isComposing || document.regions.isEmpty)
                icon("arrow.up.left.and.arrow.down.right", "Expand image") { imageMode = true; showsOriginal = true; zoom = 1 }
                CopyButton(text: document.sourceText, label: "Copy original", size: 26).disabled(model.isComposing)
            }.frame(height: 28)
            if editsSource { regionEditors(document, side: .source) }
            else { imageCanvas(document, overlays: false) }
        }.padding(compact ? 12 : 16)
    }
    private func translatedPane(_ document: ScreenshotDocument) -> some View {
        VStack(spacing: 8) {
            HStack {
                language(.target)
                Spacer(minLength: 2)
                CopyButton(text: model.translatedText, label: "Copy translation", size: 26).disabled(model.isComposing)
            }.frame(height: 28)
            regionEditors(document, side: .target)
        }.padding(compact ? 12 : 16)
    }
    private func regionEditors(_ document: ScreenshotDocument, side: TranslationSide) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if document.regions.isEmpty {
                    Text(model.phase == .recognizing ? "Recognizing text…" : "No recognized text")
                        .font(.system(size: 13)).foregroundStyle(theme.muted).padding(.top, 8)
                }
                ForEach(document.readingGroups) { group in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(group.regions) { region in
                            ScreenshotRegionEditor(
                                text: side == .source ? region.text : document.translations[region.id] ?? "",
                                placeholder: side == .source ? "" : L10n.string("Translation pending"),
                                fontSize: region.role == .heading ? (compact ? 18 : 20) : (compact ? 14 : 16),
                                accessibilityName: side == .source ? "Original text" : "Translation, editable",
                                onEdit: { model.editScreenshotRegion(region.id, text: $0, side: side, isComposing: $1) },
                                onSubmit: primaryAction,
                                canUndo: { model.canUndoWorkspaceChange }, canRedo: { model.canRedoWorkspaceChange },
                                undo: { model.undoWorkspaceChange() }, redo: { model.redoWorkspaceChange() },
                                onCancel: { if model.isBusy { model.cancel(); return true }; return false }
                            )
                            .frame(maxWidth: region.role == .price ? 74 : .infinity)
                            .accessibilityIdentifier("screenshot.region.\(side).\(region.id)")
                        }
                    }.padding(.bottom, group.regions.first?.role == .listItem ? 5 : 13)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).translateXScrollContent()
        }.accessibilityIdentifier("screenshot.\(side == .source ? "originalText" : "translatedText")")
    }

    private func imageCanvas(_ document: ScreenshotDocument, overlays: Bool) -> some View {
        GeometryReader { geometry in
            let size = ScreenshotDocument.fittedSize(image: document.pixelSize,
                available: CGSize(width: max(1, geometry.size.width - 20), height: max(1, geometry.size.height - 20)), zoom: overlays ? zoom : 1)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Image(nsImage: NSImage(cgImage: document.image, size: document.pixelSize))
                        .resizable().frame(width: size.width, height: size.height)
                        .accessibilityLabel(Text(L10n.string("Captured image")))
                    if overlays {
                        ForEach(document.regions) { region in
                            regionOverlay(region, document: document, size: size)
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .center)
            }.accessibilityIdentifier(overlays ? "screenshot.imageCanvas" : "screenshot.preview")
        }
    }
    private func regionOverlay(_ region: ScreenshotRegion, document: ScreenshotDocument, size: CGSize) -> some View {
        let translated = document.translations[region.id]
        let metrics = ScreenshotOverlayMetrics(region: region, imageSize: size)
        let card = metrics.frame
        return Button { selectedRegion = region.id } label: {
            Group {
                if !showsOriginal, let translated, translated != region.text {
                    Text(translated).font(.system(size: metrics.fontSize))
                        .lineSpacing(metrics.lineSpacing).lineLimit(metrics.lineLimit).truncationMode(.tail)
                        .foregroundStyle(theme.ink).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 3).padding(.vertical, 2)
                        // The mask must hide source glyphs even in glass mode.
                        .background(theme.isDark ? Color(white: 0.12) : Color.white)
                } else { Color.clear }
            }
            .frame(width: card.width, height: card.height)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.accent.opacity(showsOriginal ? 0 : 0.18), lineWidth: 0.7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).translateXControlCursor()
        .accessibilityLabel(Text(showsOriginal ? region.text : translated ?? L10n.string("Translation pending")))
        .translateXTooltip(L10n.string("Edit region"))
        .position(x: card.midX, y: card.midY)
        .popover(isPresented: Binding(get: { selectedRegion == region.id }, set: { if !$0 { selectedRegion = nil } }), arrowEdge: .trailing) {
            regionDetail(region, translated: translated ?? "")
        }
    }
    private func primaryAction() {
        if model.phase == .recognizing || model.phase == .translating || model.phase == .preparingLanguages { model.cancel() }
        else { model.submit() }
    }
    private func regionDetail(_ region: ScreenshotRegion, translated: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Region translation").font(.system(size: 13, weight: .semibold))
                Spacer()
                CopyButton(text: translated, label: "Copy translation", size: 26)
                icon("xmark", "Close") { selectedRegion = nil }
            }
            ScrollView {
                Text(region.text).font(.system(size: 12)).foregroundStyle(theme.muted).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 100)
            Divider()
            TranslationTextEditor(text: Binding(get: { model.screenshot?.translations[region.id] ?? "" }, set: { _ in }),
                onEdit: { model.editScreenshotRegion(region.id, text: $0, side: .target, isComposing: $1) },
                onSubmit: { selectedRegion = nil }, fontSize: 15, accessibilityID: "screenshot.regionDetail", accessibilityName: "Translation, editable",
                managesWorkspaceUndo: true,
                canUndoWorkspace: { model.canUndoWorkspaceChange }, canRedoWorkspace: { model.canRedoWorkspaceChange },
                undoWorkspace: { model.undoWorkspaceChange() }, redoWorkspace: { model.redoWorkspaceChange() },
                onCancel: { selectedRegion = nil; return true })
                .frame(height: 140)
            if region.confidence < 0.5 {
                Text("Check recognized text").font(.system(size: 11)).foregroundStyle(theme.muted)
            }
        }.padding(16).frame(width: 300).environment(\.translateXTheme, theme)
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
