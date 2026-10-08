import AppKit
import Observation
import SwiftUI

/// A window-wide material must remain translucent when another window is key.
/// Keep its backdrop and content stable so switching never reparents the editor.
@MainActor
final class WindowSurface<Content: View & SendableMetatype>: NSView {
    let hostingView: NSHostingView<LumaxThemeHost<Content>>
    let contentContainer = MaterialContentView()
    private let preferences: AppPreferences
    private let materialView: NSView
    private var accessibilityObserver: (any NSObjectProtocol)?
    private(set) var isGlassActive = false
    private let reduceTransparency: @MainActor () -> Bool

    init(preferences: AppPreferences, content: Content,
         reduceTransparency: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }) {
        self.preferences = preferences
        self.reduceTransparency = reduceTransparency
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            materialView = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            materialView = blur
        }
        hostingView = NSHostingView(rootView: LumaxThemeHost(preferences: preferences) { content })
        super.init(frame: .zero)
        wantsLayer = true
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        contentContainer.addSubview(hostingView)
        addSubview(materialView)
        if #available(macOS 26, *), let glass = materialView as? NSGlassEffectView {
            // The content belongs to the glass: AppKit uses it for native
            // compositing and legibility. Keep this owner for every material.
            glass.contentView = contentContainer
        } else {
            addSubview(contentContainer)
        }
        refreshMaterial()
        trackMaterial()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMaterial() }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func trackMaterial() {
        withObservationTracking { _ = preferences.material } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshMaterial()
                self?.trackMaterial()
            }
        }
    }

    func refreshMaterial() {
        isGlassActive = preferences.material == .glass && !reduceTransparency()
        let radius: CGFloat = isGlassActive ? 24 : 19
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        if #available(macOS 26, *), let glass = materialView as? NSGlassEffectView {
            glass.cornerRadius = radius
            // Cover the effect for opaque modes instead of hiding/reparenting
            // its live editor. Native focus adaptation must not swap materials.
        } else {
            materialView.isHidden = !isGlassActive
        }
        updateSurfaceColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceColor()
    }

    private func updateSurfaceColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            contentContainer.configure(glass: isGlassActive, dark: dark)
            layer?.backgroundColor = isGlassActive ? NSColor.clear.cgColor : contentContainer.layer?.backgroundColor
        }
        window?.invalidateShadow()
    }

    override func layout() {
        super.layout()
        materialView.frame = bounds
        contentContainer.frame = bounds
        hostingView.frame = contentContainer.bounds
    }

    isolated deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
}

/// A neutral lighting wash over the native glass. It contains no desktop
/// image, screenshot sampling, or fixed colored wallpaper. Light mode is opaque.
@MainActor
final class MaterialContentView: NSView {
    private let wash = CAGradientLayer()
    private let edge = CAGradientLayer()
    private let edgeMask = CAShapeLayer()
    private(set) var isGlass = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        wash.startPoint = CGPoint(x: 0, y: 1)
        wash.endPoint = CGPoint(x: 1, y: 0)
        wash.locations = [0, 0.48, 1]
        edge.startPoint = CGPoint(x: 0, y: 1)
        edge.endPoint = CGPoint(x: 1, y: 0)
        edgeMask.fillColor = nil
        edgeMask.lineWidth = 1
        edgeMask.strokeColor = NSColor.white.cgColor
        edge.mask = edgeMask
        layer?.addSublayer(wash)
        layer?.addSublayer(edge)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func configure(glass: Bool, dark: Bool) {
        isGlass = glass
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = glass ? NSColor.clear.cgColor : (dark ? NSColor(white: 0.11, alpha: 1) : NSColor.white).cgColor
        let tint = dark ? NSColor(white: 0.08, alpha: 1) : NSColor.white
        // Dark appearance uses light labels and needs a dark surface, even over a
        // bright desktop. Keep that contrast without replacing the real backdrop.
        // Glass already supplies blur and highlights. A heavy second wash made
        // it look solid, especially when the system softens an inactive window.
        wash.colors = (dark ? [0.64, 0.54, 0.60] : [0.50, 0.36, 0.46]).map { tint.withAlphaComponent($0).cgColor }
        edge.colors = (dark ? [0.40, 0.10, 0.22] : [0.95, 0.38, 0.65]).map { NSColor.white.withAlphaComponent($0).cgColor }
        wash.isHidden = !glass
        edge.isHidden = !glass
        layer?.cornerRadius = glass ? 24 : 19
        layer?.masksToBounds = true
        updateGeometry()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry()
        CATransaction.commit()
    }

    private func updateGeometry() {
        wash.frame = bounds
        edge.frame = bounds
        edgeMask.frame = bounds
        edgeMask.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 23.5, cornerHeight: 23.5, transform: nil)
    }
}

@MainActor
enum LumaxWindowChrome {
    static func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
    }
}
