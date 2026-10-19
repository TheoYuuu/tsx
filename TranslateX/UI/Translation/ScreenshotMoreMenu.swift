import AppKit

@MainActor
enum ScreenshotMoreMenuLayout {
    static let minimumWidth: CGFloat = 168
    static let borderWidth: CGFloat = 1
    static let padding: CGFloat = 6
    static let rowInset = borderWidth + padding
    static let rowHeight: CGFloat = 34
    static let rowPadding: CGFloat = 9
    static let iconSize: CGFloat = 15
    static let iconTextGap: CGFloat = 9
    static let textX = rowPadding + iconSize + iconTextGap
    static let separatorMargin: CGFloat = 7
    static let separatorInset = rowInset + separatorMargin
    static let separatorSpacing: CGFloat = 11
    static let anchorGap: CGFloat = 9
    static var font: NSFont { .systemFont(ofSize: 12) }

    static func width(for titles: [String]) -> CGFloat {
        let textWidth = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(minimumWidth, ceil(textWidth) + rowInset * 2 + textX + rowPadding)
    }

    static func iconRect(in bounds: NSRect) -> NSRect {
        NSRect(x: rowPadding, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
    }

    static func textRect(in bounds: NSRect, height: CGFloat) -> NSRect {
        NSRect(x: textX, y: (bounds.height - height) / 2,
               width: max(0, bounds.width - textX - rowPadding), height: height)
    }
}

/// A compact action menu with explicit row icons. Its lifetime belongs to the
/// toolbar button, including when the screenshot is replaced or dismissed.
@MainActor
final class ScreenshotMoreMenuPanel: NSPanel {
    static let didOpen = Notification.Name("ScreenshotMoreMenuDidOpen")
    static let didClose = Notification.Name("ScreenshotMoreMenuDidClose")
    private weak var owner: ScreenshotActionMenuControl?
    private let surface = ScreenshotMoreMenuSurface()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var selectedIndex: Int? { surface.selectedIndex }
    private(set) var anchorFrameInScreen: NSRect = .zero
    var rowFrames: [NSRect] { surface.rowFrames }
    var separatorFrames: [NSRect] { surface.separatorFrames }

    init(owner: ScreenshotActionMenuControl, entries: [ScreenshotMenuItem]) {
        self.owner = owner
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        identifier = NSUserInterfaceItemIdentifier("screenshotOverlay.moreMenu")
        title = L10n.string("More actions")
        contentView = surface
        update(entries: entries, owner: owner)
    }
    func update(entries: [ScreenshotMenuItem], owner: ScreenshotActionMenuControl) {
        surface.update(entries: entries, owner: owner)
    }
    func present(relativeTo button: NSView, in parent: NSWindow, toolbarFrameInWindow: NSRect? = nil, selectFirst: Bool) {
        let anchor = parent.convertToScreen(toolbarFrameInWindow ?? button.convert(button.bounds, to: nil))
        anchorFrameInScreen = anchor
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? parent.screen
        let available = screen?.visibleFrame ?? parent.frame
        setFrame(Self.placement(anchor: anchor, size: surface.fittingSize, visibleFrame: available), display: false)
        level = parent.level
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(surface)
        if selectFirst { surface.moveSelection(by: 1) }
        NotificationCenter.default.addObserver(self, selector: #selector(parentClosed), name: NSWindow.willCloseNotification, object: parent)
        NotificationCenter.default.addObserver(self, selector: #selector(parentClosed), name: NSApplication.didResignActiveNotification, object: nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.window !== self {
                    let onButton = event.window === self.owner?.window && self.owner.map {
                        $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
                    } == true
                    self.owner?.dismissMoreMenu()
                    // The opening button toggles closed rather than immediately reopening.
                    return onButton
                }
                return false
            }
            return consumed ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.owner?.dismissMoreMenu() }
        }
    }
    static func placement(anchor: NSRect, size: NSSize, visibleFrame: NSRect) -> NSRect {
        let safe = visibleFrame.insetBy(dx: 6, dy: 6)
        let width = min(size.width, safe.width), height = min(size.height, safe.height)
        let x = min(max(safe.minX, anchor.maxX - width), safe.maxX - width)
        let below = anchor.minY - ScreenshotMoreMenuLayout.anchorGap - height
        let y = below >= safe.minY ? below : min(anchor.maxY + ScreenshotMoreMenuLayout.anchorGap, safe.maxY - height)
        return NSRect(x: x, y: max(safe.minY, y), width: width, height: height)
    }
    @objc private func parentClosed() { owner?.dismissMoreMenu() }
    override func cancelOperation(_ sender: Any?) { owner?.dismissMoreMenu() }
    func dismiss() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        NotificationCenter.default.removeObserver(self)
        let parent = self.parent
        let wasKey = isKeyWindow
        parent?.removeChildWindow(self)
        orderOut(nil)
        if wasKey, NSApp.isActive, parent?.isVisible == true { parent?.makeKey(); parent?.makeFirstResponder(owner) }
    }
}

@MainActor
private final class ScreenshotMoreMenuSurface: NSView {
    private weak var owner: ScreenshotActionMenuControl?
    private var rows: [ScreenshotMoreMenuRow] = []
    private var separators: [CGFloat] = []
    private var preferredWidth = ScreenshotMoreMenuLayout.minimumWidth
    private(set) var selectedIndex: Int?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var fittingSize: NSSize {
        NSSize(width: preferredWidth,
               height: rows.reduce(ScreenshotMoreMenuLayout.rowInset * 2) { $0 + $1.frame.height }
                   + CGFloat(separators.count) * ScreenshotMoreMenuLayout.separatorSpacing)
    }
    var rowFrames: [NSRect] { rows.map(\.frame) }
    var separatorFrames: [NSRect] {
        separators.map { NSRect(x: ScreenshotMoreMenuLayout.separatorInset, y: $0 - 0.5,
                                width: max(0, bounds.width - ScreenshotMoreMenuLayout.separatorInset * 2), height: 1) }
    }

    func update(entries: [ScreenshotMenuItem], owner: ScreenshotActionMenuControl) {
        self.owner = owner
        rows.forEach { $0.removeFromSuperview() }; rows.removeAll(); separators.removeAll()
        preferredWidth = ScreenshotMoreMenuLayout.width(for: entries.filter { !$0.title.isEmpty }.map { L10n.string($0.title) })
        var y = ScreenshotMoreMenuLayout.rowInset
        for (index, entry) in entries.enumerated() {
            if entry.title.isEmpty {
                separators.append(y + ScreenshotMoreMenuLayout.separatorSpacing / 2)
                y += ScreenshotMoreMenuLayout.separatorSpacing
                continue
            }
            let row = ScreenshotMoreMenuRow(entry: entry, index: index, owner: owner)
            row.frame = NSRect(x: ScreenshotMoreMenuLayout.rowInset, y: y,
                               width: preferredWidth - ScreenshotMoreMenuLayout.rowInset * 2,
                               height: ScreenshotMoreMenuLayout.rowHeight)
            row.onHover = { [weak self] index in self?.select(index) }
            row.onChoose = { [weak owner] in owner?.choose(index: index) }
            addSubview(row); rows.append(row)
            y += ScreenshotMoreMenuLayout.rowHeight
        }
        if let selectedIndex, !rows.contains(where: { $0.index == selectedIndex && $0.isEnabled }) { self.selectedIndex = nil }
        select(selectedIndex)
        setAccessibilityRole(.menu)
        setAccessibilityLabel(L10n.string("More actions"))
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        for row in rows { row.frame.size.width = max(0, bounds.width - ScreenshotMoreMenuLayout.rowInset * 2) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        owner.menuBackground.setFill(); shape.fill()
        owner.menuBorder.setStroke(); shape.lineWidth = 1; shape.stroke()
        for separator in separatorFrames {
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: separator.minX, y: separator.midY))
            rule.line(to: NSPoint(x: separator.maxX, y: separator.midY))
            rule.lineWidth = 1; rule.stroke()
        }
    }
    func select(_ index: Int?) {
        selectedIndex = index
        for row in rows {
            row.selected = row.isEnabled && row.index == index
            row.setAccessibilitySelected(row.selected)
            row.needsDisplay = true
        }
        setAccessibilitySelectedChildren(rows.filter(\.selected))
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }
    func moveSelection(by step: Int) {
        let enabled = rows.filter(\.isEnabled).map(\.index)
        guard !enabled.isEmpty else { select(nil); return }
        let current = selectedIndex.flatMap { enabled.firstIndex(of: $0) } ?? (step > 0 ? -1 : 0)
        select(enabled[(current + step + enabled.count) % enabled.count])
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 48: owner?.dismissMoreMenu()
        case 125: moveSelection(by: 1)
        case 126: moveSelection(by: -1)
        case 115: select(rows.first(where: \.isEnabled)?.index)
        case 119: select(rows.last(where: \.isEnabled)?.index)
        case 36, 76, 49: if let selectedIndex { owner?.choose(index: selectedIndex) }
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class ScreenshotMoreMenuRow: NSButton {
    let index: Int
    private let entry: ScreenshotMenuItem
    private weak var owner: ScreenshotActionMenuControl?
    private var hoverTracking: NSTrackingArea?
    var selected = false
    var onHover: ((Int?) -> Void)?
    var onChoose: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    init(entry: ScreenshotMenuItem, index: Int, owner: ScreenshotActionMenuControl) {
        self.entry = entry; self.index = index; self.owner = owner
        super.init(frame: .zero)
        title = L10n.string(entry.title); isEnabled = entry.enabled
        isBordered = false; target = self; action = #selector(choose)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func choose() { if isEnabled { onChoose?() } }
    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: owner?.hoverCursor == .pointingHand ? .pointingHand : .arrow) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(isEnabled ? index : nil) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        if isEnabled && (selected || isHighlighted) {
            (isHighlighted ? owner.pressedFill : owner.hoverFill).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let ink = isEnabled ? owner.ink : owner.disabledInk
        entry.icon?.image(size: ScreenshotMoreMenuLayout.iconSize, color: ink).draw(in: ScreenshotMoreMenuLayout.iconRect(in: bounds))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [.font: ScreenshotMoreMenuLayout.font, .foregroundColor: ink, .paragraphStyle: paragraph])
        text.draw(in: ScreenshotMoreMenuLayout.textRect(in: bounds, height: text.size().height))
    }
}
