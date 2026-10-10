import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class TranslationServiceIconTests: XCTestCase {
    func testSavedLegacyServicesKeepTheirProviderMark() {
        for kind in TranslationServiceKind.allCases {
            let configuration = TranslationServiceConfiguration(kind: kind)
            XCTAssertEqual(configuration.serviceIcon, TranslationServiceIcon.defaultIcon(for: kind))
        }
    }

    func testCustomIconOverridesPresetWithoutChangingTheConnection() {
        var configuration = TranslationServiceConfiguration(kind: .openAICompatible)
        configuration.presetID = TranslationServicePreset.kimi.rawValue
        configuration.endpoint = "https://constructed.example/v1"
        let original = configuration
        XCTAssertEqual(configuration.serviceIcon, .kimi)
        configuration.iconID = TranslationServiceIcon.cloud.rawValue
        XCTAssertEqual(configuration.serviceIcon, .cloud)
        XCTAssertEqual(configuration.kind, original.kind)
        XCTAssertEqual(configuration.endpoint, original.endpoint)
        XCTAssertEqual(configuration.presetID, original.presetID)
        configuration.iconID = "unknown-future-icon"
        XCTAssertEqual(configuration.serviceIcon, .kimi)
        configuration.iconID = nil
        XCTAssertEqual(configuration.serviceIcon, .kimi)
    }

    func testEveryPresetUsesAvailableArtworkAndEveryIconLoadsAtMenuSize() throws {
        for preset in TranslationServicePreset.allCases {
            XCTAssertNotNil(TranslationServiceIcon(rawValue: preset.defaultIconID), "Missing icon for \(preset.rawValue)")
        }
        for icon in TranslationServiceIcon.allCases {
            let image = try XCTUnwrap(icon.menuImage(), "Missing image for \(icon.id)")
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
            XCTAssertEqual(image.isTemplate, icon.usesTemplate)
        }
    }

    func testCustomMenuIconsPreserveSavedServiceIdentity() throws {
        var configuration = TranslationServiceConfiguration(kind: .openAICompatible)
        configuration.name = "Constructed gateway"
        configuration.iconID = TranslationServiceIcon.server.rawValue
        let control = TranslationServiceMenuControl()
        var chosen: UUID?
        control.configure(title: configuration.name, selectedID: configuration.id, services: [configuration],
                          select: { chosen = $0 }, manage: {})
        let menu = try XCTUnwrap(control.menu)
        let item = try XCTUnwrap(menu.items.first { $0.representedObject as? UUID == configuration.id })
        XCTAssertEqual(item.title, configuration.name)
        XCTAssertEqual(item.image?.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(item.image?.isTemplate, true)
        menu.performActionForItem(at: menu.index(of: item))
        XCTAssertEqual(chosen, configuration.id)
    }
}
