import AppKit
import SwiftUI

/// A native menu with a trailing disclosure mark. SwiftUI's macOS Menu otherwise
/// extracts the label's image and moves it before the text on newer systems.
struct LanguageMenu: NSViewRepresentable {
    let label: String
    @Binding var selection: String
    let languages: [TranslationLanguage]
    var includeAuto = false
    var prominent = true
    var enabled = true
    var displayTitle: String? = nil
    var minimumWidth: CGFloat = 0
    @Environment(\.translateXTheme) private var theme

    func makeNSView(context: Context) -> LanguageMenuControl { LanguageMenuControl() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LanguageMenuControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    func updateNSView(_ control: LanguageMenuControl, context: Context) {
        control.languages = languages
        control.includeAuto = includeAuto
        control.selection = selection
        control.displayTitle = displayTitle
        control.minimumWidth = minimumWidth
        control.onSelect = { selection = $0 }
        control.isEnabled = enabled && context.environment.isEnabled
        control.hoverCursor = theme.hoverCursor
        control.labelFont = .systemFont(ofSize: 12, weight: prominent ? .semibold : .regular)
        control.contentTintColor = NSColor(theme.ink)
        control.setAccessibilityLabel(label)
        control.fillColor = NSColor(theme.card)
        control.edgeColor = NSColor(theme.divider)
        control.refreshTitle()
    }
}

@MainActor
final class LanguageMenuControl: NSPopUpButton, NSMenuDelegate {
    var languages: [TranslationLanguage] = []
    var includeAuto = false
    var selection = "auto"
    var displayTitle: String?
    var onSelect: ((String) -> Void)?
    var hoverCursor: HoverCursor = .pointingHand {
        didSet { if hoverCursor != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: hoverCursor == .pointingHand ? .pointingHand : .arrow) }
    }

    var minimumWidth: CGFloat = 0
    var fillColor = NSColor.controlBackgroundColor
    var edgeColor = NSColor.separatorColor

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        fillColor.withAlphaComponent(fillColor.alphaComponent * (isEnabled ? 1 : 0.5)).setFill(); shape.fill()
        edgeColor.setStroke(); shape.lineWidth = 1; shape.stroke()
        let title = NSMutableAttributedString(attributedString: attributedTitle)
        // The native display item includes the disclosure attachment. Draw it
        // separately so wide controls keep the arrow at the trailing edge.
        if title.length > 0, title.attribute(.attachment, at: title.length - 1, effectiveRange: nil) != nil {
            title.deleteCharacters(in: NSRange(location: title.length - 1, length: 1))
        }
        let size = title.size()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 10, y: 0, width: max(0, bounds.width - 34), height: bounds.height)).addClip()
        title.draw(at: NSPoint(x: 10, y: (bounds.height - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        if let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            let ink = contentTintColor ?? .labelColor
            image.withSymbolConfiguration(.init(paletteColors: [ink.withAlphaComponent(ink.alphaComponent * (isEnabled ? 1 : 0.45))]))?
                .draw(in: NSRect(x: bounds.width - 19, y: (bounds.height - 7) / 2, width: 9, height: 7))
        }
    }

    var labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect, pullsDown: true)
        isBordered = false
        // AppKit also uses this font for menu rows when tracking starts.
        // The attributed button label has its own font below.
        font = .systemFont(ofSize: 13)
        // Pull-down tracking anchors to the control's edge and handles screen
        // confinement/scrolling. A popup or a manually positioned context menu
        // can place its rows over the label instead.
        preferredEdge = isFlipped ? .maxY : .minY
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        alignment = .left
        focusRingType = .default
        setAccessibilityRole(.popUpButton)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(minimumWidth, ceil(attributedTitle.size().width) + 22), height: 30)
    }

    func refreshTitle() {
        let name = displayTitle ?? languages.first(where: { $0.id == selection })?.name ?? (selection == "auto" ? L10n.string("Detect language") : LanguageCatalog.displayName(for: selection))
        let ink = contentTintColor ?? NSColor.labelColor
        let labelColor = ink.withAlphaComponent(ink.alphaComponent * (isEnabled ? 1 : 0.45))
        let title = NSMutableAttributedString(string: name + "  ", attributes: [
            .font: labelFont,
            .foregroundColor: labelColor
        ])
        if let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            let attachment = NSTextAttachment()
            attachment.image = image.withSymbolConfiguration(.init(paletteColors: [labelColor]))
            attachment.bounds = NSRect(x: 0, y: 1, width: 9, height: 7)
            title.append(NSAttributedString(attachment: attachment))
        }
        // A native pull-down uses its first, hidden item as the button title.
        // Give it a dedicated title so no real language (including Auto) is lost.
        let displayItem = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        displayItem.attributedTitle = title
        displayItem.isHidden = true
        let choices = selectionMenu()
        choices.insertItem(displayItem, at: 0)
        menu = choices
        setAccessibilityValue(name)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func selectionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.font = .systemFont(ofSize: 13)
        menu.delegate = self
        if includeAuto {
            menu.addItem(item(name: L10n.string("Detect language"), id: "auto"))
            menu.addItem(.separator())
        }
        if selection != "auto", !languages.contains(where: { $0.id == selection }) {
            menu.addItem(item(name: LanguageCatalog.displayName(for: selection), id: selection))
        }
        for language in languages { menu.addItem(item(name: language.name, id: language.id)) }
        return menu
    }

    func confinementRect(for menu: NSMenu, on screen: NSScreen?) -> NSRect {
        guard let window, let screen = screen ?? window.screen else { return .zero }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        return Self.menuConfinementRect(anchor: anchor, visibleFrame: screen.visibleFrame)
    }

    static func menuConfinementRect(anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let gap: CGFloat = 4
        let below = max(0, min(visibleFrame.height, anchor.minY - gap - visibleFrame.minY))
        let above = max(0, min(visibleFrame.height, visibleFrame.maxY - anchor.maxY - gap))
        // Keep long-menu scrolling on one side of the button. Near the bottom
        // edge prefer the space above rather than a nearly unusable short list.
        if below >= 144 || below >= above {
            return NSRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: below)
        }
        return NSRect(x: visibleFrame.minX, y: visibleFrame.maxY - above, width: visibleFrame.width, height: above)
    }

    private func item(name: String, id: String) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.state = id == selection ? .on : .off
        return item
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard isEnabled, let id = item.representedObject as? String else { return }
        onSelect?(id)
    }
}
