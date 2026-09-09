import XCTest
@testable import MarkLens

final class MarkdownDocumentTests: XCTestCase {
    func testStarterDocumentIntroducesMarkdownAndRendersReferences() {
        let document = MarkdownDocument(text: MarkdownDocument.starterText)

        XCTAssertTrue(document.text.contains("# Welcome to MarkLens"))
        XCTAssertTrue(document.text.contains("https://commonmark.org/help/"))
        XCTAssertTrue(document.text.contains("https://github.github.com/gfm/"))
        XCTAssertTrue(document.renderedHTML.contains("<h1"))
        XCTAssertTrue(document.renderedHTML.contains("<pre"))
        XCTAssertTrue(document.renderedHTML.contains("https://commonmark.org/help/"))
    }

    func testStarterDocumentsAreIndependentAndSnapshotAsUTF8Markdown() throws {
        let first = MarkdownDocument(text: MarkdownDocument.starterText)
        let second = MarkdownDocument(text: MarkdownDocument.starterText)

        first.updateText("# Changed")
        XCTAssertEqual(first.renderRevision, 1)
        first.updateText("# Changed")
        XCTAssertEqual(first.renderRevision, 1)
        XCTAssertEqual(second.text, MarkdownDocument.starterText)

        let snapshot = try second.snapshot(contentType: .appMarkdown)
        XCTAssertEqual(Data(snapshot.utf8), Data(MarkdownDocument.starterText.utf8))
        XCTAssertTrue(MarkdownDocument.writableContentTypes.contains(.appMarkdown))
    }

    func testPublishesWhetherHTMLWasFiltered() {
        let document = MarkdownDocument(text: "<script>alert('unsafe')</script>")

        XCTAssertGreaterThan(document.filteredHTMLFragmentCount, 0)

        document.updateText("# Safe Markdown")
        XCTAssertEqual(document.filteredHTMLFragmentCount, 0)
    }

    func testSnapshotIncludesInProgressSourceDraftWithoutRenderingIt() throws {
        let document = MarkdownDocument(text: "# Before")
        let originalHTML = document.renderedHTML

        document.beginSourceEditing()
        document.updateSourceDraft("# Draft")

        XCTAssertEqual(document.text, "# Draft")
        XCTAssertEqual(try document.snapshot(contentType: .appMarkdown), "# Draft")
        XCTAssertEqual(document.renderedHTML, originalHTML)
        XCTAssertEqual(document.renderRevision, 0)
    }

    func testCommittingSourceEditingRendersTheDraft() {
        let document = MarkdownDocument(text: "# Before")

        document.beginSourceEditing()
        document.updateSourceDraft("# After")
        document.commitSourceEditing()

        XCTAssertEqual(document.text, "# After")
        XCTAssertTrue(document.renderedHTML.contains("After"))
        XCTAssertEqual(document.renderRevision, 1)
    }

    func testCancellingSourceEditingRestoresAutosavableBaseline() throws {
        let document = MarkdownDocument(text: "# Before")

        document.beginSourceEditing()
        document.updateSourceDraft("# Autosaved draft")
        XCTAssertEqual(try document.snapshot(contentType: .appMarkdown), "# Autosaved draft")
        document.cancelSourceEditing()

        XCTAssertEqual(document.text, "# Before")
        XCTAssertEqual(try document.snapshot(contentType: .appMarkdown), "# Before")
        XCTAssertTrue(document.renderedHTML.contains("Before"))
    }
}
