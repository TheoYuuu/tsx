import SwiftUI

struct TranslationResultView: View {
    let model: TranslationModel
    var retry: (() -> Void)? = nil
    var compact = false
    @Environment(\.translateXTheme) private var theme

    var body: some View {
        Group {
            if model.displayedResult != nil || !model.partialText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    // Preserve the scroll view's identity during continuous edits.
                    ScrollView {
                        Text(model.partialText.isEmpty ? (model.displayedResult?.text ?? "") : model.partialText)
                            .font(.system(size: compact ? 16 : 20)).lineSpacing(compact ? 8 : 13)
                            .tracking(0.3)
                            .foregroundStyle(theme.ink).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .translateXScrollContent()
                    }
                    if model.automaticallyTranslates || !model.partialText.isEmpty {
                        updateStatus.font(.system(size: 11)).foregroundStyle(theme.muted)
                            .frame(minHeight: 20, alignment: .leading)
                    }
                }
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        emptyResultContent
                            .frame(minHeight: geometry.size.height, alignment: .topLeading)
                            .translateXScrollContent()
                    }
                }
            }
        }.accessibilityIdentifier("translation.result")
    }

    @ViewBuilder
    private var emptyResultContent: some View {
        switch model.phase {
        case .empty:
            VStack(spacing: 15) {
                Image(systemName: "text.bubble").font(.system(size: 30, weight: .light))
                Text("Your translation appears here").font(.system(size: 13))
            }.foregroundStyle(theme.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .waiting:
            state("Updating translation…", symbol: "ellipsis.bubble", loading: true)
        case .composing:
            state("Finish entering your text to translate", symbol: "keyboard")
        case .recognizing:
            state("Recognizing text…", symbol: "viewfinder", loading: true,
                  detail: "Text recognition stays on your Mac. The first scan may take longer.")
        case .translating:
            state("Translating…", symbol: "text.bubble", loading: true,
                  detail: model.usesAppleTranslation ? "Translating this passage on your Mac." : "Waiting for your selected translation service.")
        case .preparingLanguages:
            state("Preparing language files…", symbol: "arrow.down.circle", loading: true,
                  detail: "Apple may ask to download language files. Keep this window open.")
        case .unchanged:
            Text(model.text(on: model.destinationSide))
                .font(.system(size: compact ? 16 : 19)).lineSpacing(2)
                .foregroundStyle(theme.ink).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .noText:
            state("No translatable text was found", symbol: "text.magnifyingglass",
                  detail: "Select an area that contains clear text and try again.", canRetry: true)
        case .completed:
            EmptyView()
        case .cancelled:
            VStack(alignment: .leading, spacing: 12) {
                Text("Stopped · No translation yet").font(.system(size: 12)).foregroundStyle(theme.muted)
                retryButton
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: failurePresentation(message).symbol).font(.system(size: 24, weight: .regular)).foregroundStyle(theme.muted)
                Text(failurePresentation(message).title).font(.system(size: 16, weight: .semibold))
                Text(message).font(.system(size: 12)).lineSpacing(5).foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                retryButton
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func failurePresentation(_ message: String) -> (title: LocalizedStringKey, symbol: String) {
        if message == L10n.string("The selection or clipboard changed. Select your text and try again.") {
            return ("Content has changed", "lock.shield")
        }
        if message == L10n.string("Protected fields can’t be read. Use input translation for other text.") {
            return ("This text is protected", "lock.shield")
        }
        if message == L10n.string("No text is selected. Select some text and try again, or type to translate.")
            || message == L10n.string("This app didn’t provide selected text. Try again, or use input translation.") {
            return ("Couldn’t get selected text", "cursorarrow")
        }
        return ("Unable to complete translation", "exclamationmark.bubble")
    }

    @ViewBuilder
    private var updateStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch model.phase {
            case .completed, .empty:
                Text(" ").accessibilityHidden(true)
            case .composing:
                Text("Finish entering your text to translate")
            case .preparingLanguages:
                Text("Apple may ask to download language files. Keep this window open.")
            case .failed(let message):
                Text(message)
                retryButton
            case .cancelled:
                Text("Translation cancelled")
                retryButton
            case .noText:
                Text("No translatable text was found")
                retryButton
            default:
                ProgressView().controlSize(.mini)
                Text("Updating translation…")
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var retryButton: some View {
        if model.canTranslate || retry != nil {
            Button("Try again", action: retryTranslation)
                .buttonStyle(TranslateXButtonStyle())
                .accessibilityIdentifier("translation.retry")
        }
    }

    func retryTranslation() {
        if let retry { retry() } else { model.submit() }
    }

    private func state(_ title: LocalizedStringKey, symbol: String, loading: Bool = false,
                       detail: LocalizedStringKey? = nil, canRetry: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if loading { ProgressView().controlSize(.small) }
            else { Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(theme.muted) }
            Text(title).font(.system(size: 16, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12)).lineSpacing(5).foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canRetry { retryButton }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CopyButton: View {
    let text: String
    let label: String
    var size: CGFloat = 32
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Group {
                if copied {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .medium))
                } else {
                    CopyOutline()
                        .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                        .frame(width: 18, height: 18)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(TranslateXIconButtonStyle())
        .translateXTooltip(L10n.string(label))
        .accessibilityLabel(Text(L10n.string(label)))
        .disabled(text.isEmpty)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// The two simple rounded sheets from the approved design, without folded corners.
private struct CopyOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 8, y: 8, width: 12, height: 13), cornerSize: CGSize(width: 2, height: 2))
        path.move(to: CGPoint(x: 16, y: 8))
        path.addLine(to: CGPoint(x: 16, y: 4))
        path.addQuadCurve(to: CGPoint(x: 15, y: 3), control: CGPoint(x: 16, y: 3))
        path.addLine(to: CGPoint(x: 4, y: 3))
        path.addQuadCurve(to: CGPoint(x: 3, y: 4), control: CGPoint(x: 3, y: 3))
        path.addLine(to: CGPoint(x: 3, y: 16))
        path.addQuadCurve(to: CGPoint(x: 4, y: 17), control: CGPoint(x: 3, y: 17))
        path.addLine(to: CGPoint(x: 8, y: 17))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}
