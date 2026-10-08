// Compile-only feasibility probe. This file is deliberately excluded from the application.
// It does not request permissions, inspect other apps, capture a screen, or download models.
import AppKit
import ApplicationServices
import Carbon
import ScreenCaptureKit
import SwiftUI
import Translation
import Vision

@MainActor
private struct TranslationHostProbe: View {
    @State private var configuration: TranslationSession.Configuration? = .init(
        source: nil,
        target: Locale.Language(identifier: "zh-Hans")
    )

    var body: some View {
        Color.clear.translationTask(configuration) { session in
            do {
                _ = try await session.translate("Hello")
            } catch {
                // Runtime error presentation belongs to the approved implementation phase.
            }
        }
    }
}

private func selectedTextAPIProbe(pid: pid_t) -> AXError {
    let application = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(
        application, kAXFocusedUIElementAttribute as CFString, &value
    )
}

@MainActor
private func hotKeyAPIProbe() -> OSStatus {
    var reference: EventHotKeyRef?
    let identifier = EventHotKeyID(signature: 0x4C554D58, id: 1)
    let status = RegisterEventHotKey(
        UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), identifier,
        GetApplicationEventTarget(), 0, &reference
    )
    if let reference {
        UnregisterEventHotKey(reference)
    }
    return status
}

private func screenshotAPIProbe(
    filter: SCContentFilter, configuration: SCStreamConfiguration
) async throws -> CGImage {
    try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: configuration
    )
}

private func ocrAPIProbe(image: CGImage) async throws -> [RecognizedTextObservation] {
    var request = RecognizeTextRequest(.revision3)
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true
    request.usesLanguageCorrection = true
    return try await request.perform(on: image)
}

@MainActor
private func floatingPanelAPIProbe() -> NSPanel {
    NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
        backing: .buffered, defer: true
    )
}
