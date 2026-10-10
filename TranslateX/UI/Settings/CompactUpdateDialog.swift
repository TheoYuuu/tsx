import SwiftUI

/// Shared geometry for available, installed and historical release notes.
/// The scroll area alone yields space when the parent window is resized.
struct CompactUpdateDialog<Content: View, Footer: View>: View {
    @Environment(\.translateXTheme) private var theme
    let title: String
    var maximumHeight: CGFloat? = nil
    var canDismiss = true
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer
    @State private var contentHeight: CGFloat = 160
    @State private var headerHeight: CGFloat = 74
    @State private var footerHeight: CGFloat = 80
    private var p: ReleaseDialogPalette { .init(theme: theme) }
    private var scrollHeight: CGFloat {
        min(contentHeight, max(0, (maximumHeight ?? 650) - headerHeight - footerHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                HStack(spacing: 9) {
                    Image("AppBrand").resizable().interpolation(.high).scaledToFit()
                        .frame(width: 32, height: 32).padding(.leading, -4).accessibilityHidden(true)
                    Text(title).font(.system(size: 18, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .serviceDesignMetric("update.title")
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .regular))
                }
                .buttonStyle(ReleaseDialogCloseStyle()).disabled(!canDismiss)
                .accessibilityLabel(L10n.string("Close"))
                .padding(.trailing, -4)
            }
            .padding(.horizontal, 24).padding(.top, 21).padding(.bottom, 21)
            .serviceDesignMetric("update.header")
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollView {
                content().frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .translateXScrollContent(overlayVerticalIndicator: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { contentHeight = $0 }
            }
            .frame(height: scrollHeight).serviceDesignMetric("update.notes")
            footer().padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 22)
                .fixedSize(horizontal: false, vertical: true)
                .serviceDesignMetric("update.actions")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .foregroundStyle(p.ink).frame(maxWidth: 520)
        .background(p.paper, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(p.line).allowsHitTesting(false) }
        .shadow(color: .black.opacity(theme.isDark ? 0.21 : 0.08), radius: 30, y: 10)
        .serviceDesignMetric("update.dialog")
    }
}

struct ReleaseVersionHeading: View {
    @Environment(\.translateXTheme) private var theme
    let version: String
    var badge: String? = nil
    let publishedAt: Date?
    var currentVersion: String? = nil
    private var p: ReleaseDialogPalette { .init(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    versionLabel.fixedSize()
                    Spacer(minLength: 0)
                    publication.fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) { versionLabel; publication }
            }
            if let currentVersion {
                Text(String(format: L10n.string("Current version v%@"), currentVersion))
                    .font(.system(size: 11)).foregroundStyle(p.muted).frame(minHeight: 18)
            }
        }.serviceDesignMetric("update.version")
    }

    private var versionLabel: some View {
        HStack(spacing: 8) {
            Text(verbatim: "v" + version).font(.system(size: 16, weight: .semibold)).frame(minHeight: 23)
            if let badge {
                Text(badge).font(.system(size: 10)).foregroundStyle(p.blue)
                    .padding(.horizontal, 6).frame(height: 19)
                    .background(p.blueSoft, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
    @ViewBuilder private var publication: some View {
        if let publishedAt { ReleasePublicationLabel(date: publishedAt) }
    }
}

private struct ReleasePublicationLabel: View {
    @Environment(\.translateXTheme) private var theme
    let date: Date
    @State private var visible = true
    var body: some View {
        Group {
            if visible {
                TimelineView(.periodic(from: .now, by: 30)) { context in label(now: context.date) }
            } else { label(now: .now) }
        }
        .background(TranslateXWindowVisibility { visible = $0 }.frame(width: 0, height: 0))
    }
    private func label(now: Date) -> some View {
        Text(ReleasePublicationTime.label(for: date, now: now))
            .font(.system(size: 12)).foregroundStyle(ReleaseDialogPalette(theme: theme).secondary)
            .frame(minHeight: 20).focusable().focusEffectDisabled()
            .translateXTooltip(ReleasePublicationTime.precise(date, locale: L10n.currentLocale, timeZone: .autoupdatingCurrent))
    }
}

struct ReleaseDialogFooter<Leading: View, Actions: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { leading().fixedSize(); Spacer(minLength: 0); actions().fixedSize() }
            VStack(alignment: .leading, spacing: 14) {
                leading()
                HStack { Spacer(minLength: 0); actions() }
            }
        }
    }
}

struct ReleaseDialogTextStyle: ButtonStyle {
    @Environment(\.translateXTheme) private var theme
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        let p = ReleaseDialogPalette(theme: theme)
        configuration.label.font(.system(size: 11))
            .foregroundStyle(hovered || configuration.isPressed ? p.blue : p.secondary)
            .frame(minHeight: 20).contentShape(Rectangle())
            .onHover { hovered = $0 }.translateXControlCursor()
    }
}

struct ReleaseDialogButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.translateXTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        let p = ReleaseDialogPalette(theme: theme)
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 13)
            .frame(minWidth: primary ? 92 : 64).frame(height: 34)
            .foregroundStyle(enabled ? (primary ? .white : p.ink) : p.muted)
            .background(primary && enabled ? p.primary.opacity(configuration.isPressed ? 0.8 : hovered ? 0.95 : 1) : p.surface,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(primary && enabled ? .clear : hovered && enabled ? p.muted : p.line)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8)).onHover { hovered = $0 }.translateXControlCursor()
    }
}

private struct ReleaseDialogCloseStyle: ButtonStyle {
    @Environment(\.translateXTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        let p = ReleaseDialogPalette(theme: theme)
        configuration.label.frame(width: 28, height: 28)
            .foregroundStyle(hovered ? p.ink : p.muted).opacity(enabled ? 1 : 0.4)
            .background(hovered && enabled ? p.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(hovered && enabled ? p.line : .clear) }
            .contentShape(RoundedRectangle(cornerRadius: 7)).onHover { hovered = $0 }.translateXControlCursor()
    }
}

struct ReleaseDialogPalette {
    let theme: TranslateXTheme
    private var base: TranslationServicePalette { .init(theme: theme) }
    private func color(_ light: UInt32, _ dark: UInt32) -> Color { base.color(theme.isDark ? dark : light) }
    var paper: Color { color(0xffffff, 0x252a34) }
    var ink: Color { color(0x29313e, 0xeff3f9) }
    var secondary: Color { theme.increaseContrast ? ink : color(0x647287, 0xb6c3d6) }
    var muted: Color { theme.increaseContrast ? ink : color(0x738094, 0xa5b1c4) }
    var line: Color { theme.increaseContrast ? base.line : color(0xe0e8f2, 0x414c5e) }
    var surface: Color { color(0xf4f7fc, 0x303a49) }
    var blue: Color { color(0x0878fa, 0x73b4ff) }
    var blueSoft: Color { color(0xecf4ff, 0x263f60) }
    var primary: Color { color(0x087bff, 0x1e7bed) }
}
