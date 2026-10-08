import Foundation
import XCTest

final class BuildConfigurationTests: XCTestCase {
    func testHostedApplicationAndTestBundleHaveSeparateKnownIdentities() {
        // verify.sh uses a dedicated host so an already-running trial app
        // cannot receive the fixture's activation request. Direct Xcode tests
        // may still use the normal app identity; deliverable IDs are checked
        // strictly on both built products by verify.sh.
        let allowedHosts = ["com.lumax.tsx", "com.lumax.tsx.TestHost"]
        XCTAssertTrue(allowedHosts.contains(Bundle.main.bundleIdentifier ?? ""))
        XCTAssertEqual(Bundle(for: Self.self).bundleIdentifier, "com.lumax.tsx.Tests")
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, Bundle(for: Self.self).bundleIdentifier)
    }
}
