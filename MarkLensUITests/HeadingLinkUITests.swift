import XCTest

final class HeadingLinkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSameDocumentHeadingLinkJumpsWithoutReopening() throws {
        try verifyHeadingLink(inAnotherDocument: false)
    }

    @MainActor
    func testLinkedDocumentOpensAtHeading() throws {
        try verifyHeadingLink(inAnotherDocument: true)
    }

    @MainActor
    func testNewDocumentOpensAtHeading() throws {
        try verifyHeadingLink(inAnotherDocument: true, reuseTarget: false)
    }

    @MainActor
    func testCommandClickOpensNewTabAtHeading() throws {
        try verifyHeadingLink(inAnotherDocument: true, reuseTarget: false, commandClick: true)
    }

    @MainActor
    private func verifyHeadingLink(inAnotherDocument: Bool, reuseTarget: Bool = true, commandClick: Bool = false) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLensHeadingUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let target = inAnotherDocument ? directory.appendingPathComponent("target.md") : source
        let paragraphs = (1...70).map { "Paragraph \($0). Content before the destination." }.joined(separator: "\n\n")
        let after = (1...25).map { "Following paragraph \($0). Content after the destination." }.joined(separator: "\n\n")
        let destination = inAnotherDocument ? "target.md#ABC" : "#ABC"
        let targetContents = "# Document start\n\n\(paragraphs)\n\n## ABC\n\n\(after)"
        if inAnotherDocument {
            try targetContents.write(to: target, atomically: true, encoding: .utf8)
            try "# Source\n\n[Jump to ABC](\(destination))".write(to: source, atomically: true, encoding: .utf8)
        } else {
            try "[Jump to ABC](\(destination))\n\n\(targetContents)".write(to: source, atomically: true, encoding: .utf8)
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-DefaultViewModeEnabled", "NO",
            "-LinkedDocumentOpenPreference", "newWindow"
        ]
        app.terminate()
        defer { app.terminate() }
        // Opening the destination first authorizes that individual file and
        // also checks that a reused document scrolls to the requested heading.
        app.open(target)
        let targetWindow = app.windows[target.lastPathComponent].firstMatch
        XCTAssertTrue(targetWindow.waitForExistence(timeout: 5))
        let heading = targetWindow.webViews.staticTexts["ABC"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertFalse(heading.isHittable, "The destination must initially be below the viewport.")
        if !reuseTarget {
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(targetWindow.waitForNonExistence(timeout: 5))
        }
        if inAnotherDocument { app.open(source) }
        app.activate()
        let sourceWindow = app.windows[source.lastPathComponent].firstMatch
        XCTAssertTrue(sourceWindow.waitForExistence(timeout: 5))
        let link = sourceWindow.webViews.links["Jump to ABC"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        if commandClick {
            XCUIElement.perform(withKeyModifiers: .command) { link.click() }
        } else {
            link.click()
        }
        let viewport = targetWindow.scrollViews.firstMatch
        let jumped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            heading.isHittable && heading.frame.minY >= viewport.frame.minY
                && heading.frame.minY < viewport.frame.minY + viewport.frame.height / 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [jumped], timeout: 8), .completed,
                       "The linked heading must be near the top of the visible preview.")
        XCTAssertFalse(targetWindow.webViews.staticTexts["Document start"].firstMatch.isHittable)
        XCTAssertEqual(app.windows.matching(identifier: target.lastPathComponent).count, 1)
    }
}
