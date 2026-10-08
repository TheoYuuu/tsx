import AppKit
import SwiftUI

/// One toolbar for both windows. Its center is independent of the widths of
/// either action group; resizing keeps the existing editors mounted.
struct TranslationCommandBar: View {
    @Bindable var model: TranslationModel
    var compact = false
    var translateSelection: () -> Void = {}
    var translateScreenshot: () -> Void = {}
    var openSettings: () -> Void = {}
    var manageServices: () -> Void = {}
    @Environment(\.lumaxTheme) private var theme
    @State private var availableWidth: CGFloat = 940
    private var prefix: String { compact ? "quick" : "main" }
    private var tight: Bool { availableWidth <= 716 }
    private var requesting: Bool { model.phase == .recognizing || model.phase == .translating || model.phase == .preparingLanguages }
    private var canSubmit: Bool { model.canTranslate && !model.needsSourceLanguage && !model.needsReverseLanguage }

    var body: some View {
        TranslationToolbarLayout(tight: tight) {
            TranslationServicePicker(model: model, maximumWidth: compact ? 136 : 160, openSettings: manageServices)
                .lumaxTooltip(model.serviceDisplayName)
                .serviceDesignMetric("\(prefix).service")
            HStack(spacing: 6) {
                AutomaticTranslationCapsule(model: model, tight: tight)
                    .serviceDesignMetric("\(prefix).automatic")
                primary.serviceDesignMetric("\(prefix).primary")
            }.fixedSize()
            feedback.serviceDesignMetric("\(prefix).feedback")
            HStack(spacing: tight ? 2 : 4) {
                toolbarIcon("text.cursor", label: "Translate selection", action: translateSelection)
                    .serviceDesignMetric("\(prefix).captureSelection")
                toolbarIcon("viewfinder", label: "Screenshot Translation", action: translateScreenshot)
                    .serviceDesignMetric("\(prefix).captureScreenshot")
            }
            HStack(spacing: tight ? 2 : 4) {
                toolbarIcon("arrow.uturn.backward", label: "Undo", tooltip: model.isComposing ? "Finish typing to undo" : model.canUndoWorkspaceChange ? "Undo" : "Nothing to undo") { model.undoWorkspaceChange() }
                    .disabled(!model.canUndoWorkspaceChange || model.isComposing)
                    .accessibilityIdentifier("translation.undo")
                    .serviceDesignMetric("\(prefix).undo")
                Button("Clear") { model.clear() }
                    .font(.system(size: 11)).foregroundStyle(theme.muted)
                    .padding(.horizontal, tight ? 4 : 6).frame(height: 28)
                    .buttonStyle(.plain).lumaxControlCursor()
                    .disabled(!model.canClear)
                    .lumaxTooltip(L10n.string("Clear both sides"))
                    .serviceDesignMetric("\(prefix).clear")
                toolbarIcon("gearshape", label: "Settings", action: openSettings)
                    .serviceDesignMetric("\(prefix).settings")
            }.fixedSize()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .background(theme.control.opacity(theme.isGlass ? 0.55 : 0.46), in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(theme.divider, lineWidth: 1).allowsHitTesting(false) }
        .serviceDesignMetric("\(prefix).commandBar")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Translation toolbar")
    }

    private func toolbarIcon(_ symbol: String, label: String, tooltip: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if symbol == "text.cursor" { LumaxActionIcon(symbol: .selection).frame(width: 16, height: 16) }
                else { Image(systemName: symbol).font(.system(size: 14)) }
            }.frame(width: 28, height: 28)
        }
        .buttonStyle(LumaxIconButtonStyle())
        .accessibilityLabel(Text(L10n.string(label))).lumaxTooltip(L10n.string(tooltip ?? label))
    }

    private var primary: some View {
        Button { if requesting { model.cancel() } else { model.submit() } } label: {
            HStack(spacing: 5) {
                Text(model.workspaceActionTitle).font(.system(size: 11, weight: .medium))
                if !tight { Text(requesting ? "esc" : "⌘ ↩").font(.system(size: 9)).opacity(0.7) }
            }
            .foregroundStyle(!requesting && canSubmit ? Color.white : theme.muted)
            .padding(.horizontal, tight ? 13 : 16)
            .frame(minWidth: tight ? 72 : 82).frame(height: 28)
            .background(!requesting && canSubmit ? theme.accent : theme.control, in: Capsule())
        }
        .buttonStyle(LumaxHoverButtonStyle(radius: 15))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSubmit && !requesting)
        .accessibilityIdentifier("translation.submit")
        .lumaxTooltip(L10n.string(requesting ? "Stop" : model.inputSide == .source ? "Update the translation" : "Translate back"))
    }

    private var feedback: some View {
        HStack(spacing: 5) {
            if !model.toolbarFeedback.isEmpty { TranslationStatusLight(phase: model.phase) }
            Text(model.toolbarFeedback).font(.system(size: 10)).lineLimit(1)
        }
        .foregroundStyle(model.hasTranslationFailure ? Color.orange : theme.muted)
        .frame(maxWidth: .infinity).frame(height: 28).contentShape(Rectangle()).focusable(!model.workspaceFeedback.isEmpty)
        .focusEffectDisabled()
        .lumaxTooltip(model.workspaceFeedback.isEmpty ? model.toolbarFeedback : model.workspaceFeedback)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(model.workspaceFeedback.isEmpty ? model.toolbarFeedback : model.workspaceFeedback))
        .accessibilityIdentifier("translation.feedback")
    }
}

struct TranslationToolbarLayout: Layout {
    var tight: Bool
    private var centerWidth: CGFloat { tight ? 96 : 112 }
    private func twoRows(_ width: CGFloat, _ subviews: Subviews) -> Bool {
        let actions = subviews[1].sizeThatFits(.unspecified).width
        let readableService = min(subviews[0].sizeThatFits(.unspecified).width, 96)
        return width <= 596 || width < (readableService + 6 + actions) * 2 + centerWidth + 34
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 940
        return CGSize(width: width, height: subviews.count == 5 && twoRows(width, subviews) ? 72 : 42)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let double = twoRows(bounds.width, subviews)
        let left = bounds.minX + 9, right = bounds.maxX - 9
        let side = (bounds.width - 18 - centerWidth - 16) / 2
        func place(_ i: Int, x: CGFloat, y: CGFloat, width: CGFloat? = nil) {
            subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                              proposal: ProposedViewSize(width: width ?? sizes[i].width, height: 28))
        }
        if double {
            place(0, x: left, y: bounds.minY + 7, width: max(42, min(sizes[0].width, right - left - sizes[1].width - 10)))
            place(1, x: right - sizes[1].width, y: bounds.minY + 7)
            place(2, x: bounds.midX - centerWidth / 2, y: bounds.minY + 37, width: centerWidth)
            place(3, x: left, y: bounds.minY + 37)
            place(4, x: right - sizes[4].width, y: bounds.minY + 37)
        } else {
            let service = min(sizes[0].width, side - sizes[1].width - 6)
            place(0, x: left, y: bounds.minY + 7, width: service)
            place(1, x: left + service + 6, y: bounds.minY + 7)
            place(2, x: bounds.midX - centerWidth / 2, y: bounds.minY + 7, width: centerWidth)
            place(3, x: right - sizes[4].width - 6 - sizes[3].width, y: bounds.minY + 7)
            place(4, x: right - sizes[4].width, y: bounds.minY + 7)
        }
    }
}

private struct AutomaticTranslationCapsule: View {
    @Bindable var model: TranslationModel
    let tight: Bool
    @Environment(\.lumaxTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if LUMAX_VISUAL_QA
    @Environment(\.translationReviewReduceMotion) private var reviewReduceMotion
    private var motionReduced: Bool { reviewReduceMotion ?? reduceMotion }
    #else
    private var motionReduced: Bool { reduceMotion }
    #endif
    @State private var visible = false
    // AppKit hosts these views outside a SwiftUI Scene; its scenePhase is not
    // the visibility of this window. The native probe owns the animation gate.
    private var animates: Bool { model.usesAutomaticTranslation && !motionReduced && visible }
    var body: some View {
        Button { model.setAutomaticTranslation(!model.usesAutomaticTranslation) } label: {
            Text("Auto translate").font(.system(size: tight ? 10 : 11, weight: .medium))
                .foregroundStyle(model.usesAutomaticTranslation ? Color.white : theme.muted)
                .padding(.horizontal, 13).frame(minWidth: tight ? 74 : 84).frame(height: 28)
                .background {
                    if model.usesAutomaticTranslation {
                        LinearGradient(colors: [Color(red: 0.04, green: 0.44, blue: 0.96), Color(red: 0.29, green: 0.36, blue: 0.98), Color(red: 0.52, green: 0.31, blue: 0.93)], startPoint: .leading, endPoint: .trailing)
                        TimelineView(.animation(minimumInterval: 1 / 24, paused: !animates)) { timeline in
                            Canvas { context, size in
                                let time = motionReduced ? 0 : timeline.date.timeIntervalSinceReferenceDate
                                for i in 0..<16 {
                                    let progress = (time / (3.8 + Double(i % 8) * 0.35) + Double(i) / 16).truncatingRemainder(dividingBy: 1)
                                    let diameter = i % 3 == 0 ? 2.2 : 1.5
                                    let x = progress * (size.width + 8) - 4
                                    let y = Double((i * 7) % 22) + 2 + sin(progress * .pi * 2 + Double(i)) * 1.3
                                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)), with: .color(.white.opacity(0.65 * sin(progress * .pi))))
                                }
                            }
                        }.allowsHitTesting(false)
                    } else { Capsule().strokeBorder(theme.divider, lineWidth: 1) }
                }.clipShape(Capsule())
        }
        .buttonStyle(LumaxHoverButtonStyle(radius: 15)).disabled(model.isComposing)
        .accessibilityRepresentation {
            Toggle("Automatic bidirectional translation", isOn: Binding(get: { model.usesAutomaticTranslation }, set: { model.setAutomaticTranslation($0) }))
                .disabled(model.isComposing).accessibilityIdentifier("translation.automatic")
        }
        .lumaxTooltip(L10n.string("Auto translate after typing"))
        .background(LumaxWindowVisibility { visible = $0 })
        .onDisappear { visible = false }
    }
}

extension TranslationModel {
    var toolbarFeedback: String {
        switch phase {
        case .waiting: return L10n.string("Waiting for input")
        case .composing: return L10n.string("Entering text…")
        case .recognizing: return L10n.string("Recognizing text…")
        case .translating: return L10n.string("Translating…")
        case .preparingLanguages: return L10n.string("Preparing languages")
        case .cancelled: return L10n.string("Stopped")
        case .failed: return L10n.string(screenshot?.regions.isEmpty == true ? "Recognition failed" : "Translation failed")
        case .unchanged: return L10n.string("Synced")
        case .completed: return L10n.string("Updated")
        default:
            if needsSourceLanguage || needsReverseLanguage { return L10n.string("Check language") }
            if !statusMessage.isEmpty { return L10n.string("Ready to translate") }
            return ""
        }
    }
}
