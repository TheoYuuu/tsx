import SwiftUI

/// Shared by the main and quick windows. Both native editors stay mounted when
/// direction, status, theme or split orientation changes.
struct TranslationWorkspace: View {
    @Bindable var model: TranslationModel
    let catalog: LanguageCatalog?
    var compact = false
    var editorReady: (NSTextView) -> Void = { _ in }
    var translationEditorReady: (NSTextView) -> Void = { _ in }
    @Environment(\.translateXTheme) private var theme
    @Environment(\.translationLayout) private var layout

    private var metricPrefix: String { compact ? "quick" : "main" }
    private var fontSize: CGFloat { compact ? 16 : 19 }

    var body: some View {
        TranslationSplitLayout(orientation: layout) {
            pane(.source)
                .serviceDesignMetric("\(metricPrefix).sourceColumn")
            Rectangle().fill(theme.divider).accessibilityHidden(true)
            pane(.target)
                .background(theme.secondaryCard)
                .serviceDesignMetric("\(metricPrefix).resultColumn")
        }
        .background(theme.workspace)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 14))
        .overlay { RoundedRectangle(cornerRadius: compact ? 12 : 14).strokeBorder(theme.isGlass ? theme.edge : theme.divider, lineWidth: 1).allowsHitTesting(false) }
        .overlay(alignment: .center) {
            Button { model.swapLanguages() } label: {
                Image(systemName: layout == .stacked ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
                    .font(.system(size: 11))
                    .frame(width: compact ? 26 : 28, height: compact ? 26 : 28)
            }
            .buttonStyle(TranslateXIconButtonStyle())
            .background(theme.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.divider, lineWidth: 0.75).allowsHitTesting(false))
            .translateXTooltip(L10n.string("Swap both sides")).accessibilityLabel("Swap languages")
            .disabled(!model.canSwapLanguages)
            .serviceDesignMetric("\(metricPrefix).swap")
        }
    }

    private func pane(_ side: TranslationSide) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: compact ? 7 : 9) {
                languageMenu(side)
                if side == .source, model.source == "auto", let detected = model.resolvedSource {
                    Text(LanguageCatalog.displayName(for: detected)).font(.system(size: 11)).foregroundStyle(theme.muted).lineLimit(1)
                }
                Spacer(minLength: 2)
                CopyButton(text: model.text(on: side), label: side == .source ? "Copy original" : "Copy translation", size: compact ? 28 : 32)
                    .disabled(model.isComposing)
            }
            .frame(height: compact ? 28 : 30)
            .padding(.bottom, compact || layout == .stacked ? 12 : 23)
            editor(side)
                .serviceDesignMetric("\(metricPrefix).\(side == .source ? "sourceEditor" : "targetEditor")")
        }
        .padding(.horizontal, compact ? 16 : 24)
        .padding(.top, compact ? 12 : layout == .stacked ? 13 : 18)
        .padding(.bottom, compact ? 14 : layout == .stacked ? 15 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("\(metricPrefix).\(side == .source ? "sourceColumn" : "resultColumn")")
    }

    private func editor(_ side: TranslationSide) -> some View {
        TranslationTextEditor(
            text: Binding(get: { model.text(on: side) }, set: { _ in }),
            onEdit: { model.editingChanged($0, isComposing: $1, side: side) },
            onSubmit: primaryAction,
            onReady: side == .source ? editorReady : translationEditorReady,
            fontSize: fontSize,
            accessibilityID: compact ? (side == .source ? "translation.quick.input" : "translation.quick.output") : (side == .source ? "translation.input" : "translation.output"),
            accessibilityName: side == .source ? "Original text" : "Translation, editable",
            managesWorkspaceUndo: true,
            canUndoWorkspace: { model.canUndoWorkspaceChange }, canRedoWorkspace: { model.canRedoWorkspaceChange },
            undoWorkspace: { model.undoWorkspaceChange() }, redoWorkspace: { model.redoWorkspaceChange() },
            onCancel: { if model.isBusy { model.cancel(); return true }; return false }
        )
        .overlay(alignment: .topLeading) {
            if model.text(on: side).isEmpty {
                Text(side == .source ? "Type or paste text…" : "Your translation appears here.\nYou can also type directly…")
                    .font(.system(size: 16)).lineSpacing(2)
                    .foregroundStyle(theme.faint).padding(.top, 2).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func languageMenu(_ side: TranslationSide) -> some View {
        if let catalog {
            LanguageMenu(label: L10n.string(side == .source ? "Source language" : "Target language"),
                selection: side == .source ? $model.source : $model.target,
                languages: catalog.languages(for: model.serviceConfiguration, asTarget: side == model.destinationSide),
                includeAuto: side == .source && model.inputSide == .source,
                prominent: !compact, enabled: !model.isComposing)
                .fixedSize()
        } else {
            Text(LanguageCatalog.displayName(for: side == .source ? model.source : model.target))
                .font(.system(size: 12, weight: .medium))
        }
    }

    private func primaryAction() {
        if model.phase == .translating || model.phase == .preparingLanguages { model.cancel() }
        else { model.submit() }
    }
}

extension TranslationModel {
    var hasTranslationFailure: Bool { if case .failed = phase { return true }; return false }
    var workspaceActionTitle: String {
        if phase == .recognizing || phase == .translating || phase == .preparingLanguages { return L10n.string("Stop") }
        if phase == .cancelled { return L10n.string("Translate again") }
        if hasTranslationFailure { return L10n.string("Try again") }
        if usesAutomaticTranslation { return L10n.string("Translate now") }
        return L10n.string("Translate")
    }
    var workspaceFeedback: String {
        switch phase {
        case .waiting: return L10n.string("Updates after you pause typing")
        case .composing: return L10n.string("Entering text…")
        case .recognizing: return L10n.string("Recognizing text…")
        case .translating: return L10n.string("Translating…")
        case .preparingLanguages: return L10n.string("Apple may ask to download language files. Keep this window open.")
        case .cancelled:
            if partialSide == destinationSide { return L10n.string("Stopped · Incomplete text retained") }
            return L10n.string(text(on: destinationSide).isEmpty ? "Stopped · No translation yet" : "Stopped · Existing text retained")
        case .failed(let message): return message
        case .unchanged: return L10n.string("Synced · No translation needed")
        case .noText: return L10n.string("No translatable text was found")
        default:
            if needsSourceLanguage { return L10n.string("Language unclear · Choose the original language") }
            if needsReverseLanguage { return L10n.string("Choose a language to translate back") }
            if !statusMessage.isEmpty { return statusMessage }
            if partialSide == destinationSide { return L10n.string("Incomplete text retained") }
            return ""
        }
    }
}
