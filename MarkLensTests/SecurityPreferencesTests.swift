import XCTest
import MarkdownPipeline
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
        XCTAssertTrue(defaults.bool(forKey: SecurityPreferences.rendersMermaidKey))
        XCTAssertTrue(defaults.bool(forKey: SecurityPreferences.loadsLocalImagesKey))
    }

    func testDocumentCanDisableMermaidAndLocalImages() {
        let document = MarkdownDocument(text: """
        ![Local](images/example.png)

        ```mermaid
        flowchart LR
            A --> B
        ```
        """)

        document.updateRenderingPreferences(RenderingPreferences(
            rendersRawHTML: false,
            loadsRemoteResources: false,
            rendersMermaid: false,
            loadsLocalImages: false
        ))

        XCTAssertFalse(document.renderedHTML.contains("data-marklens-local-image"))
        XCTAssertFalse(document.renderedHTML.contains("images/example.png"))
        XCTAssertFalse(document.renderedHTML.contains("<div class=\"mermaid-block\" data-mermaid-diagram>"))
        XCTAssertFalse(document.renderedHTML.contains("mermaid.initialize"))
        XCTAssertTrue(document.renderedHTML.contains("flowchart LR"))
        XCTAssertTrue(document.renderedResources.allSatisfy { $0.contentType != "application/javascript" })
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
