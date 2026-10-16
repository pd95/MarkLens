import XCTest
@testable import MarkLens

#if os(macOS)
final class WikiLinkActionTests: XCTestCase {
    func testRevealIgnoresMissingHeadingButOpenStillValidatesIt() throws {
        let root = try makeWiki()
        defer { try? FileManager.default.removeItem(at: root) }
        for action in [WikiLinkAction.revealInFinder, .quickLook] {
            let destination = try ResolvedWikiLink.resolve("Notes#Missing", in: root, action: action)
            XCTAssertEqual(destination.matches, [root.appendingPathComponent("Notes.md")])
            XCTAssertNil(destination.heading)
            XCTAssertNil(destination.line)
        }
        XCTAssertThrowsError(try ResolvedWikiLink.resolve("Notes#Missing", in: root, action: .open(inNewTab: false)))
        let opened = try ResolvedWikiLink.resolve("Notes#Heading", in: root, action: .open(inNewTab: true))
        XCTAssertEqual(opened.line, 1)
    }

    func testAmbiguousRevealKeepsAllMatchesForTheChooser() throws {
        let root = try makeWiki()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# Other".write(to: nested.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8)
        let result = try ResolvedWikiLink.resolve("Notes#Missing", in: root, action: .revealInFinder)
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertNil(result.heading)
        XCTAssertThrowsError(try ResolvedWikiLink.resolve("Absent", in: root, action: .revealInFinder))
        XCTAssertThrowsError(try ResolvedWikiLink.resolve("Notes", in: root, action: .revealInFinder, shouldCancel: { true }))
    }

    private func makeWiki() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Heading".write(to: root.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8)
        return root
    }
}
#endif
