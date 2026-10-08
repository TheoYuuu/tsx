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
    @Environment(\.lumaxTheme) private var theme

    func makeNSView(context: Context) -> LanguageMenuControl { LanguageMenuControl() }

    func updateNSView(_ control: LanguageMenuControl, context: Context) {
        control.languages = languages
        control.includeAuto = includeAuto
        control.selection = selection
        control.displayTitle = displayTitle
        control.onSelect = { selection = $0 }
        control.isEnabled = enabled
        control.hoverCursor = theme.hoverCursor
        control.labelFont = .systemFont(ofSize: prominent ? 14 : 12, weight: prominent ? .semibold : .regular)
        control.contentTintColor = NSColor(theme.ink)
        control.setAccessibilityLabel(label)
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

    var labelFont = NSFont.systemFont(ofSize: 14, weight: .semibold)

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
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 3, height: 30)
    }

    func refreshTitle() {
        let name = displayTitle ?? (selection == "auto" ? L10n.string("Detect language") : LanguageCatalog.displayName(for: selection))
        let title = NSMutableAttributedString(string: name + "  ", attributes: [
            .font: labelFont,
            .foregroundColor: contentTintColor ?? NSColor.labelColor
        ])
        if let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            let attachment = NSTextAttachment()
            attachment.image = image
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
