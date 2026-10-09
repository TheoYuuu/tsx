import AppKit
import SwiftUI

// Content uses the shared scroll anchor. The outer page owns its scrollbar.
extension View {
    func translationServiceScrollContent() -> some View {
        translateXScrollContent()
    }
}

struct TranslationServiceIconButtonStyle: ButtonStyle {
    @Environment(\.translateXTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var size: CGFloat = 28
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        let p = TranslationServicePalette(theme: theme)
        configuration.label.font(.system(size: 13))
            .frame(width: size, height: size)
            .foregroundStyle(destructive ? p.error : hovered ? p.accent : p.muted)
            .background(hovered ? p.fill : p.panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(p.line) }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
            .onHover { hovered = $0 }.translateXControlCursor()
    }
}

/// Colors for the approved service settings surface. The window continues to
/// use the application's native material; these are only content surfaces.
struct TranslationServicePalette {
    let theme: TranslateXTheme
    var ink: Color { color(theme.isDark ? 0xedf0f5 : 0x262d39) }
    var muted: Color { color(theme.isDark ? 0xadb7c7 : 0x6c798c) }
    var fill: Color { color(theme.isDark ? 0x293544 : 0xf2f7fc).opacity(theme.isGlass ? 0.55 : 1) }
    var line: Color { color(theme.increaseContrast ? (theme.isDark ? 0x8391a5 : 0x899bad) : (theme.isDark ? 0x3e4d60 : 0xdfe8f1)) }
    var panel: Color { color(theme.isDark ? 0x303946 : 0xffffff).opacity(theme.isGlass ? (theme.isDark ? 0.62 : 0.68) : 1) }
    var accent: Color { color(theme.isDark ? 0x4a99ff : 0x0875f5) }
    var accentSoft: Color { color(theme.isDark ? 0x30455e : 0xedf4fe) }
    var primary: Color { color(theme.isDark ? 0x176dde : 0x0875f5) }
    var error: Color { color(theme.isDark ? 0xf1a59b : 0xd7473d) }
    var errorFill: Color { color(theme.isDark ? 0x4d393b : 0xfff2ef) }
    var success: Color { color(theme.isDark ? 0x8dcdb1 : 0x25846f) }
    var successFill: Color { color(theme.isDark ? 0x304b43 : 0xedf8f3) }
    var popover: Color { color(theme.isDark ? 0x303946 : theme.isGlass ? 0xf5f8fc : 0xffffff) }

    func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct TranslationServiceButtonStyle: ButtonStyle {
    enum Kind { case regular, primary, quiet, soft, danger }
    var kind: Kind = .regular
    var minimumWidth: CGFloat? = nil
    @Environment(\.translateXTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let p = TranslationServicePalette(theme: theme)
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, kind == .quiet ? 9 : 12)
            .frame(height: 32)
            .frame(minWidth: minimumWidth)
            .foregroundStyle(foreground(p))
            .background(background(p, pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(kind == .regular || kind == .primary && !enabled ? p.line : .clear, lineWidth: 1) }
            .opacity(enabled || kind == .primary ? 1 : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
            .translateXControlCursor()
    }

    private func foreground(_ p: TranslationServicePalette) -> Color {
        if !enabled { return p.muted }
        switch kind {
        case .primary, .danger: return .white
        case .soft: return p.accent
        case .quiet: return hovered ? p.accent : p.muted
        case .regular: return p.ink
        }
    }
    private func background(_ p: TranslationServicePalette, pressed: Bool) -> Color {
        if !enabled { return kind == .primary ? p.fill : kind == .quiet ? .clear : p.panel }
        switch kind {
        case .primary: return p.primary.opacity(pressed ? 0.8 : hovered ? 0.9 : 1)
        case .danger: return p.error.opacity(pressed ? 0.8 : hovered ? 0.9 : 1)
        case .soft: return hovered || pressed ? p.accent.opacity(0.18) : p.accentSoft
        case .quiet: return .clear
        case .regular: return hovered || pressed ? p.fill : p.panel
        }
    }
}

struct TranslationServiceCard<Content: View>: View {
    @Environment(\.translateXTheme) private var theme
    var horizontalPadding: CGFloat = 15
    @ViewBuilder var content: () -> Content
    var body: some View {
        let p = TranslationServicePalette(theme: theme)
        VStack(spacing: 0, content: content)
            .padding(.horizontal, horizontalPadding + 1)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(p.line, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct TranslationServiceFormRow<Content: View>: View {
    @Environment(\.translateXTheme) private var theme
    let title: String
    var optional = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(title)).font(.system(size: 12, weight: .medium))
                if optional { Text(L10n.string("Optional")).font(.system(size: 9)).foregroundStyle(TranslationServicePalette(theme: theme).muted) }
            }
            .padding(.top, 7)
            .frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 5, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 52, alignment: .top)
    }
}

struct TranslationServiceDivider: View {
    @Environment(\.translateXTheme) private var theme
    var body: some View { Rectangle().fill(TranslationServicePalette(theme: theme).line.opacity(0.63)).frame(height: 1).accessibilityHidden(true) }
}

struct TranslationServiceHint: View {
    @Environment(\.translateXTheme) private var theme
    let text: String
    var error = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if error { Image(systemName: "exclamationmark.circle").font(.system(size: 11)) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10.5))
        .lineSpacing(2)
        .padding(.vertical, 1.6)
        .foregroundStyle(error ? TranslationServicePalette(theme: theme).error : TranslationServicePalette(theme: theme).muted)
        .accessibilityElement(children: .combine)
    }
}

struct TranslationServiceField: View {
    @Environment(\.translateXTheme) private var theme
    let title: String
    @Binding var text: String
    var placeholder = ""
    var invalid = false
    var secure = false
    var trailingPadding: CGFloat = 10
    var onFocusChanged: ((Bool) -> Void)? = nil
    var focusRequest = 0
    @FocusState private var focused: Bool

    var body: some View {
        let p = TranslationServicePalette(theme: theme)
        Group {
            if secure { SecureField(L10n.string(placeholder), text: $text) }
            else { TextField(L10n.string(placeholder), text: $text) }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(p.ink)
        .padding(.leading, 10)
        .padding(.trailing, trailingPadding)
        .frame(height: 32)
        .background(invalid ? p.errorFill : p.fill, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(invalid ? p.error.opacity(0.5) : p.line.opacity(0.34), lineWidth: 1) }
        .overlay { if focused { RoundedRectangle(cornerRadius: 7).stroke(p.accent.opacity(0.72), lineWidth: 2).padding(-1) } }
        .focused($focused)
        .onChange(of: focused) { _, value in onFocusChanged?(value) }
        .task(id: focusRequest) {
            guard focusRequest != 0 else { return }
            // A newly inserted manual-model field must join the focus tree
            // before the click's original button relinquishes first responder.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
        }
        .accessibilityLabel(L10n.string(title))
    }
}

struct TranslationServiceProviderMark: View {
    @Environment(\.translateXTheme) private var theme
    var kind: TranslationServiceKind? = nil
    var size: CGFloat = 34
    var body: some View {
        let p = TranslationServicePalette(theme: theme)
        Group {
            if let asset = kind?.providerLogo {
                Image(asset)
                    .renderingMode(kind?.usesMonochromeLogo == true ? .template : .original)
                    .resizable().scaledToFit()
                    .frame(width: size * 0.64, height: size * 0.64)
            } else if kind == nil {
                Image("MenuBarIcon").renderingMode(.template)
                    .resizable().scaledToFit()
                    .frame(width: size * 0.64, height: size * 0.64)
            } else {
                // User-supplied compatible endpoints have no vendor identity.
                Image(systemName: "network")
                    .font(.system(size: size * 0.52, weight: .medium))
            }
        }
        .foregroundStyle(markColor(p))
        .frame(width: size, height: size)
        .background(markFill(p), in: RoundedRectangle(cornerRadius: size > 25 ? 9 : 6))
        .overlay { RoundedRectangle(cornerRadius: size > 25 ? 9 : 6).strokeBorder(p.line, lineWidth: 1) }
        .accessibilityHidden(true)
    }
    private func markColor(_ p: TranslationServicePalette) -> Color {
        switch kind {
        case .deepL: p.color(theme.isDark ? 0xc1cddd : 0x36567e)
        default: kind == nil ? p.accent : p.ink
        }
    }
    private func markFill(_ p: TranslationServicePalette) -> Color {
        guard !theme.isDark else { return p.color(0x1e2836) }
        switch kind {
        case .deepSeek: return p.color(0xeff4ff)
        case .claude: return p.color(0xfbf1e9)
        case .deepL: return p.color(0xeef3f8)
        case nil: return p.accentSoft
        default: return p.fill.opacity(0.5)
        }
    }
}

/// Replaces the secure control without interpreting the old control's teardown
/// as a user blur. The displayed saved-key copy never becomes a replacement
/// unless an actual text-edit notification arrives from the active control.
struct TranslationServiceSecretInput: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Binding var text: String
    let visible: Bool
    let placeholder: String
    let ink: Color
    let muted: Color
    let blur: @MainActor () -> Void
    var focusChanged: @MainActor (Bool) -> Void = { _ in }
    var moveFocus: (@MainActor (_ backward: Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> Container {
        let view = Container()
        context.coordinator.container = view
        configure(view, coordinator: context.coordinator)
        return view
    }
    func updateNSView(_ view: Container, context: Context) {
        context.coordinator.parent = self
        configure(view, coordinator: context.coordinator)
    }
    private func configure(_ view: Container, coordinator: Coordinator) {
        if view.field == nil || view.visible != visible {
            let previous = view.field
            let hadFocus = previous?.currentEditor() != nil
            let field: NSTextField = visible ? FocusReportingTextField() : FocusReportingSecureTextField()
            let transitionID = UUID()
            view.transitionID = transitionID
            view.isSwitchingField = true
            // Publish the new field first: old-field end-editing notifications
            // are then safely ignored by the delegate.
            view.field = field
            view.visible = visible
            previous?.removeFromSuperview()
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.isEnabled = enabled
            field.font = .systemFont(ofSize: 12)
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.delegate = coordinator
            let didFocus: @MainActor () -> Void = { [weak coordinator, weak field] in
                guard let coordinator, let field,
                      coordinator.container?.field === field else { return }
                coordinator.reportFocus(true)
            }
            (field as? FocusReportingTextField)?.didFocus = didFocus
            (field as? FocusReportingSecureTextField)?.didFocus = didFocus
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setAccessibilityLabel(L10n.string("API Key"))
            view.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
                field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -39),
                field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                field.heightAnchor.constraint(equalToConstant: 18)
            ])
            field.stringValue = text
            let shouldFocus = enabled && (hadFocus || visible)
            // Let SwiftUI finish its focus transaction before moving the
            // AppKit field editor. Moving it synchronously from updateNSView
            // can make SwiftUI restore the previous control and hide the key.
            DispatchQueue.main.async { [weak view, weak field] in
                guard let view, let field, view.transitionID == transitionID,
                      view.field === field else { return }
                if shouldFocus && field.isEnabled { view.window?.makeFirstResponder(field) }
                view.isSwitchingField = false
            }
        }
        guard let field = view.field else { return }
        field.isEnabled = enabled
        if !enabled, field.currentEditor() != nil { view.window?.makeFirstResponder(nil) }
        if !enabled {
            // AppKit can end editing as part of disabling without sending the
            // text delegate a blur. Clear the shown copy after this update.
            DispatchQueue.main.async { [weak view, weak field, weak coordinator] in
                guard let view, let field, let coordinator,
                      view.field === field, !field.isEnabled else { return }
                coordinator.reportFocus(false)
                if coordinator.parent.visible { coordinator.parent.blur() }
            }
        }
        field.textColor = NSColor(ink)
        field.placeholderAttributedString = NSAttributedString(string: L10n.string(placeholder), attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(muted)
        ])
        if field.stringValue != text { field.stringValue = text }
    }

    final class Container: NSView {
        var field: NSTextField?
        var visible = false
        var transitionID = UUID()
        var isSwitchingField = false
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 32) }
    }
    // NSTextField's begin-editing notification can wait for an actual edit.
    // First-responder acceptance is the event needed for the focus outline.
    final class FocusReportingTextField: NSTextField {
        var didFocus: (@MainActor () -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { didFocus?() }
            return accepted
        }
    }
    final class FocusReportingSecureTextField: NSSecureTextField {
        var didFocus: (@MainActor () -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { didFocus?() }
            return accepted
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TranslationServiceSecretInput
        weak var container: Container?
        private var reportedFocus = false
        init(parent: TranslationServiceSecretInput) { self.parent = parent }
        func reportFocus(_ focused: Bool) {
            guard focused != reportedFocus else { return }
            reportedFocus = focused
            parent.focusChanged(focused)
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  field === container?.field else { return }
            reportFocus(true)
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field === container?.field else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let backward = commandSelector == #selector(NSResponder.insertBacktab(_:))
            guard backward || commandSelector == #selector(NSResponder.insertTab(_:)),
                  let container, let field = container.field, control === field,
                  field.isEnabled, let moveFocus = parent.moveFocus else { return false }
            // SwiftUI's neighboring fields are not in this embedded control's
            // native key-view loop. End this field editor before requesting
            // their SwiftUI focus, so a secure/plain update cannot reclaim it.
            container.transitionID = UUID()
            container.isSwitchingField = false
            guard field.window?.makeFirstResponder(nil) == true else { return true }
            reportFocus(false)
            moveFocus(backward)
            return true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let container, field === container.field,
                  !container.isSwitchingField else { return }
            let transitionID = container.transitionID
            // End-editing can be part of a same-turn secure/plain replacement.
            // Only a settled blur from the still-active control hides the key.
            DispatchQueue.main.async { [weak self, weak container, weak field] in
                guard let self, let container, let field,
                      container.transitionID == transitionID,
                      container.field === field, !container.isSwitchingField,
                      field.currentEditor() == nil else { return }
                self.reportFocus(false)
                self.parent.blur()
            }
        }
    }
}

extension TranslationServiceKind {
    var settingsName: String {
        switch self {
        case .openAICompatible: L10n.string("OpenAI-compatible")
        case .qwenMT: "Qwen-MT"
        case .googleCloud: "Google Cloud"
        case .tencentTranslation: L10n.string("Tencent Translation")
        default: displayName
        }
    }
    var providerLogo: String? {
        switch self {
        case .openAI, .codex: "ProviderOpenAI"
        case .deepSeek: "ProviderDeepSeek"
        case .openAICompatible: nil
        case .ollama: "ProviderOllama"
        case .deepL: "ProviderDeepL"
        case .azureTranslator: "ProviderAzure"
        case .claude: "ProviderClaude"
        case .qwenMT: "ProviderQwen"
        case .googleCloud: "ProviderGoogleCloud"
        case .tencentTranslation: "ProviderTencentCloud"
        }
    }
    var usesMonochromeLogo: Bool { [.openAI, .codex, .ollama, .deepL].contains(self) }
    var connectionLabel: String {
        if self == .codex { return L10n.string("Account sign-in") }
        if [.deepL, .azureTranslator, .qwenMT, .googleCloud, .tencentTranslation].contains(self) { return L10n.string("Dedicated translation") }
        if self == .ollama { return L10n.string("Local model") }
        return "API Key"
    }
}

struct TranslationServiceExperimentalBadge: View {
    @Environment(\.translateXTheme) private var theme
    var body: some View {
        let p = TranslationServicePalette(theme: theme)
        Text(L10n.string("Experimental")).font(.system(size: 9))
            .foregroundStyle(p.color(theme.isDark ? 0xd9c28c : 0x967438))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(p.color(theme.isDark ? 0x4b4436 : 0xfcf2dd), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct TranslationServicePopupAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

extension View {
    func translationServicePopupAnchor(_ name: String) -> some View {
        anchorPreference(key: TranslationServicePopupAnchorKey.self, value: .bounds) { [name: $0] }
    }
}
