import AppKit
import SwiftUI

/// Same native checkmark, hover and keyboard behavior as LanguageMenu.
/// Choosing a service affects only the next request.
struct TranslationServicePicker: View {
    let model: TranslationModel
    var maximumWidth: CGFloat = 160
    var openSettings: () -> Void = {}
    @Environment(\.translateXTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    private var highlighted: Bool { hovered && enabled && !model.isComposing }
    private var fill: Color {
        let tint = theme.isDark ? Color(red: 0.17, green: 0.22, blue: 0.32) : Color(red: 0.86, green: 0.91, blue: 0.98)
        return tint.opacity(theme.isGlass ? (highlighted ? 0.8 : 0.6) : (highlighted ? 1 : 0.75))
    }

    var body: some View {
        NativeTranslationServicePicker(model: model, maximumWidth: maximumWidth, openSettings: openSettings)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.increaseContrast ? theme.divider : theme.accent.opacity(highlighted ? 0.32 : 0.14), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
    }
}

private struct NativeTranslationServicePicker: NSViewRepresentable {
    let model: TranslationModel
    let maximumWidth: CGFloat
    let openSettings: () -> Void
    @Environment(\.translateXTheme) private var theme

    func makeNSView(context: Context) -> TranslationServiceMenuControl { TranslationServiceMenuControl() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranslationServiceMenuControl, context: Context) -> CGSize? {
        // NSPopUpButton otherwise refuses a width below its intrinsic title,
        // even when the shared toolbar allocates a smaller service slot.
        CGSize(width: min(proposal.width ?? maximumWidth, nsView.intrinsicContentSize.width), height: 28)
    }
    func updateNSView(_ control: TranslationServiceMenuControl, context: Context) {
        control.maximumWidth = maximumWidth
        control.font = .systemFont(ofSize: 13)
        let enabled = context.environment.isEnabled && !model.isComposing
        control.contentTintColor = NSColor(enabled ? theme.ink : theme.disabledInk)
        control.hoverCursor = theme.hoverCursor
        control.isEnabled = enabled
        control.configure(title: model.serviceDisplayName, selectedID: model.serviceConfiguration?.id,
                          services: model.availableServices, select: { model.selectService($0) }, manage: openSettings)
    }
}

@MainActor
final class TranslationServiceMenuControl: NSPopUpButton, NSMenuDelegate {
    var maximumWidth: CGFloat = 160
    var hoverCursor: HoverCursor = .pointingHand {
        didSet { if oldValue != hoverCursor { window?.invalidateCursorRects(for: self) } }
    }
    private var selectService: ((UUID?) -> Void)?
    private var manage: (() -> Void)?
    private var displayName = ""
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize { NSSize(width: min(maximumWidth, ceil((displayName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width) + 40), height: 28) }
    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: hoverCursor == .pointingHand ? .pointingHand : .arrow) }
    }
    init() {
        super.init(frame: .zero, pullsDown: true)
        cell = TranslationServiceMenuCell(textCell: "", pullsDown: true)
        isBordered = false; alignment = .left
        preferredEdge = isFlipped ? .maxY : .minY
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        cell?.lineBreakMode = .byTruncatingTail
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(L10n.string("Translation service"))
    }
    required init?(coder: NSCoder) { nil }

    func configure(title: String, selectedID: UUID?, services: [TranslationServiceConfiguration],
                   select: @escaping (UUID?) -> Void, manage: @escaping () -> Void) {
        selectService = select; self.manage = manage; displayName = title
        let options = NSMenu(); options.delegate = self; options.font = .systemFont(ofSize: 13); options.minimumWidth = 214
        let display = NSMenuItem(title: title, action: nil, keyEquivalent: ""); display.isHidden = true
        options.addItem(display)
        options.addItem(choice(L10n.string("Apple Translation"), id: nil, selected: selectedID == nil))
        for service in services { options.addItem(choice(service.name, id: service.id, selected: selectedID == service.id)) }
        options.addItem(.separator())
        let management = NSMenuItem(title: L10n.string("Manage translation services…"), action: #selector(manageServices), keyEquivalent: "")
        management.target = self; options.addItem(management)
        menu = options; refreshDisplay(); setAccessibilityValue(title); invalidateIntrinsicContentSize()
    }
    override func layout() { super.layout(); refreshDisplay() }
    private func refreshDisplay() {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let available = max(12, (bounds.width > 0 ? bounds.width : intrinsicContentSize.width) - 40)
        var name = displayName
        if (name as NSString).size(withAttributes: [.font: font]).width > available {
            while !name.isEmpty && ((name + "…") as NSString).size(withAttributes: [.font: font]).width > available { name.removeLast() }
            name += "…"
        }
        let value = NSMutableAttributedString(string: name + "  ", attributes: [.font: font, .foregroundColor: contentTintColor ?? .labelColor])
        let arrow = NSTextAttachment(); arrow.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        arrow.bounds = NSRect(x: 0, y: 1, width: 8, height: 6); value.append(NSAttributedString(attachment: arrow))
        menu?.items.first?.attributedTitle = value
    }
    private func choice(_ title: String, id: UUID?, selected: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = id; item.state = selected ? .on : .off
        return item
    }
    @objc private func choose(_ item: NSMenuItem) { guard isEnabled else { return }; selectService?(item.representedObject as? UUID) }
    @objc private func manageServices() { guard isEnabled else { return }; manage?() }
    func confinementRect(for menu: NSMenu, on screen: NSScreen?) -> NSRect {
        guard let window, let screen = screen ?? window.screen else { return .zero }
        return LanguageMenuControl.menuConfinementRect(anchor: window.convertToScreen(convert(bounds, to: nil)), visibleFrame: screen.visibleFrame)
    }
}

/// Keep padding inside the native hit target so the entire service surface,
/// including its edges, opens the same keyboard-accessible menu.
private final class TranslationServiceMenuCell: NSPopUpButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle(title, withFrame: frame.insetBy(dx: 8, dy: 0), in: controlView)
    }
}
