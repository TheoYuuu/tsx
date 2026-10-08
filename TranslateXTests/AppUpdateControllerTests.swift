import XCTest
@testable import TranslateX

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testTestHostsAndPreviewBundlesCannotStartUpdaterOrChangePreferences() {
        for identifier in [nil, "com.lumax.tsx.TestHost", "preview", "com.lumax.tsx"] {
            let updates = AppUpdateController(bundleIdentifier: identifier, isTesting: true)
            updates.start()
            updates.setAutomaticChecks(true)
            updates.setAutomaticDownloads(true)
            updates.checkForUpdates()
            XCTAssertFalse(updates.isAvailable)
            XCTAssertFalse(updates.started)
            XCTAssertFalse(updates.canCheckForUpdates)
            XCTAssertFalse(updates.automaticallyChecksForUpdates)
            XCTAssertFalse(updates.automaticallyDownloadsUpdates)
        }
        XCTAssertFalse(AppUpdateController(bundleIdentifier: "preview", isTesting: false).isAvailable)
    }

    func testConstructingControllerDoesNotStartNetworkOrEnableAutomaticUpdates() {
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false)
        XCTAssertTrue(updates.isAvailable)
        XCTAssertFalse(updates.started)
        XCTAssertFalse(updates.canCheckForUpdates)
        XCTAssertFalse(updates.automaticallyChecksForUpdates)
        XCTAssertFalse(updates.automaticallyDownloadsUpdates)
    }

    func testPackagedUpdatePolicyRequiresSignaturesAndDoesNotOptUsersIntoNetworkChecks() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://lumaxspace.com/updates/tsx/appcast.xml")
        let publicKey = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
    }
}
