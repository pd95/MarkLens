import WebKit
import XCTest
@testable import MarkLens

final class MarkdownWebViewSecurityTests: XCTestCase {
    func testUsesEphemeralStorageAndDisablesScriptWindows() {
        let configuration = MarkdownWebView.makeSecureConfiguration()

        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }
}
