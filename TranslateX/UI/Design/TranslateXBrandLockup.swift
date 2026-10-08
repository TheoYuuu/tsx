import SwiftUI

/// Preserves the developer's signature artwork with the approved system-font name.
struct TranslateXBrandLockup: View {
    @Environment(\.translateXTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image("DeveloperSignature")
                .renderingMode(theme.isDark ? .template : .original)
                .resizable().scaledToFit()
                .frame(width: 84, height: 31)
                .foregroundStyle(theme.ink)
                .serviceDesignMetric("main.brandSignature")
            Text(verbatim: "Translate")
                .font(.system(size: 14, weight: .medium))
                .tracking(0.5).foregroundStyle(theme.ink)
                .frame(height: 20).offset(y: 1)
                .serviceDesignMetric("main.brandName")
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TSX")
        .serviceDesignMetric("main.brand")
    }
}
