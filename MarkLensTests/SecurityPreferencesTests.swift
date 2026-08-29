import XCTest
@testable import MarkLens

@MainActor
final class SecurityPreferencesTests: XCTestCase {
    func testRegistersSecureContentDefaults() throws {
        let suite = "SecurityPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        SecurityPreferences.registerDefaults(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: SecurityPreferences.rendersRawHTMLKey))
        XCTAssertFalse(defaults.bool(forKey: SecurityPreferences.loadsRemoteResourcesKey))
    }

    func testDocumentRerendersWhenContentPolicyChanges() {
        let document = MarkdownDocument(text: """
        <span class="note">Raw</span>
        ![Remote](https://example.com/image.png)
        """)

        XCTAssertTrue(document.renderedHTML.contains("&lt;span"))
        XCTAssertFalse(document.renderedHTML.contains("https://example.com/image.png"))

        document.updateRenderingPreferences(RenderingPreferences(
            rendersRawHTML: true,
            loadsRemoteResources: true
        ))

        XCTAssertTrue(document.renderedHTML.contains("<span class=\"note\">Raw</span>"))
        XCTAssertTrue(document.renderedHTML.contains("https://example.com/image.png"))
        XCTAssertEqual(document.renderRevision, 1)
    }
}
