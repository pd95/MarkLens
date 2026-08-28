import MarkdownPipeline
import XCTest

final class CodeLanguageIntegrationTests: XCTestCase {
    func testShortUntypedProseIsNotMisidentifiedAsCode() throws {
        let document = try MarkdownPipeline.defaultHTML().renderHTML(
            from: .string("```\nno language here\n```")
        )

        XCTAssertTrue(document.html.contains("data-code-language=\"plaintext\""))
        XCTAssertTrue(document.html.contains("data-code-language-source=\"fallback\""))
        XCTAssertFalse(document.html.contains("data-code-language=\"pgsql\""))
    }

    func testExplicitSwiftFencePreservesItsLanguageMetadata() throws {
        let document = try MarkdownPipeline.defaultHTML().renderHTML(
            from: .string("```swift title=Example.swift\nlet value = 1\n```")
        )

        XCTAssertTrue(document.html.contains("data-code-language=\"swift\""))
        XCTAssertTrue(document.html.contains("data-code-language-source=\"explicit\""))
        XCTAssertFalse(document.html.contains("title=Example.swift"))
    }
}
