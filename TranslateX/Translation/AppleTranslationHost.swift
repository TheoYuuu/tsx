import SwiftUI
import Translation

/// The view owns the system session; neither a window controller nor the model retains it.
struct AppleTranslationHost: View {
    let model: TranslationModel

    var body: some View {
        let captured = model.request
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .translationTask(model.configuration) { session in
                guard let captured else { return }
                if let source = captured.source {
                    let availability = await LanguageCatalog.status(source: source, target: captured.target)
                    guard !Task.isCancelled, model.request?.id == captured.id else { return }
                    if availability == .unsupported {
                        model.fail(localized: "This language pair isn’t available. Choose another language.", for: captured)
                        return
                    }
                    if availability == .supported { model.markPreparing(captured) }
                }
                await model.run(captured, provider: AppleLocalTranslationProvider(session: session))
            }
    }
}
