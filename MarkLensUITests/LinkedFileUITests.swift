import AppKit
import XCTest

final class LinkedFileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLocalFileMenusOfferRevealAndAppropriateOpenActions() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        try """
        [Markdown](notes.md)

        [Image](photo.png)

        [PDF](report.pdf)

        [Folder](files/)

        [[Notes]]
        """.write(to: source, atomically: true, encoding: .utf8)
        let app = open(source)
        defer { app.terminate() }
        let window = app.windows["source.md"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        window.click()
        for label in ["Markdown", "Image", "PDF", "Folder", "Notes"] {
            let link = window.webViews.links[label].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 5), label)
            link.rightClick()
            XCTAssertTrue(app.menuItems["Reveal in Finder"].firstMatch.waitForExistence(timeout: 3), label)
            XCTAssertTrue(app.menuItems["Copy Link Address"].firstMatch.exists)
            XCTAssertEqual(app.menuItems["Open in New Tab"].firstMatch.exists, ["Markdown", "Notes"].contains(label))
            XCTAssertTrue(app.menuItems["Quick Look"].firstMatch.exists)
            if label == "Image" { capture(app, name: "linked-image-context-menu") }
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    @MainActor
    func testPNGLinkPreviewsAndReturnsToMarkdownPosition() throws {
        try verifyFilePreview(fileExtension: "png")
    }

    @MainActor
    func testJPEGContextActionPreviewsWithoutOpeningATab() throws {
        try verifyFilePreview(fileExtension: "jpg")
    }

    @MainActor
    func testMarkdownContextActionPreviewsWithoutNavigating() throws {
        try verifyFilePreview(fileExtension: "md")
    }

    @MainActor
    func testJSONContextActionPreviewsWithoutNavigating() throws {
        try verifyFilePreview(fileExtension: "json")
    }

    @MainActor
    func testTextAndJSONClicksRevealAndSelectTargetsInFinder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDirectory = directory.appendingPathComponent("preview", isDirectory: true)
        let targetDirectory = directory.appendingPathComponent("Linked Targets \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("source.md")
        let targets = ["Settings File.json", "Notes.txt"].map { targetDirectory.appendingPathComponent($0) }
        for target in targets { try Data("Target".utf8).write(to: target) }
        let relativeJSON = "../" + targetDirectory.lastPathComponent + "/Settings File.json"
        let encodedJSON = try XCTUnwrap(relativeJSON.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
        try "# Reveal links\n\n[JSON](\(encodedJSON))\n\n[Text](\(targets[1].absoluteString))"
            .write(to: source, atomically: true, encoding: .utf8)
        let app = open(source)
        defer { app.terminate() }
        let window = app.windows["source.md"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        let finderWindow = finder.windows[targetDirectory.lastPathComponent].firstMatch
        defer {
            if finderWindow.exists {
                finderWindow.click()
                finder.typeKey("w", modifierFlags: .command)
            }
        }
        for (label, target) in zip(["JSON", "Text"], targets) {
            app.activate()
            let link = window.webViews.links[label].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            link.click()
            XCTAssertTrue(finderWindow.waitForExistence(timeout: 5), finder.debugDescription)
            let targetName = target.lastPathComponent
            let matchesTarget = NSPredicate(format: "label == %@ OR value == %@", targetName, targetName)
            XCTAssertTrue(finderWindow.descendants(matching: .any).matching(matchesTarget).firstMatch.waitForExistence(timeout: 5))
            let selectedTarget = finderWindow.descendants(matching: .any).matching(
                NSPredicate(format: "selected == YES AND (label == %@ OR value == %@)", targetName, targetName)
            ).firstMatch
            XCTAssertTrue(selectedTarget.waitForExistence(timeout: 5), "Finder must select \(targetName).\n\(finder.debugDescription)")
            XCTAssertEqual(app.windows.matching(identifier: "source.md").count, 1)
            XCTAssertFalse(window.sheets.firstMatch.exists, "Revealing a target must not request read access.")
        }
        capture(finderWindow, name: "clicked-link-revealed-in-finder")
    }

    @MainActor
    func testHoverDescribesTheClickActionAndClearsWhenLeavingLink() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        try "# Hover\n\n[Markdown](notes.md)\n\n[JSON](settings.json)\n\n[Sibling](../shared/settings.json)\n\n[Web](https://example.com/)"
            .write(to: source, atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-DefaultViewModeEnabled", "YES"]
        app.terminate()
        addTeardownBlock { @MainActor in app.terminate() }
        app.open(source)
        app.activate()
        defer { app.terminate() }
        let window = app.windows["source.md"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.click()
        let markdown = window.webViews.links["Markdown"].firstMatch
        XCTAssertTrue(markdown.waitForExistence(timeout: 5))
        markdown.hover()
        let status = window.staticTexts["linkDestinationStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(status.value as? String ?? status.label, "Navigate to notes.md")
        window.webViews.links["JSON"].firstMatch.hover()
        let reveals = NSPredicate(format: "value == %@ OR label == %@", "Reveal in Finder: settings.json", "Reveal in Finder: settings.json")
        expectation(for: reveals, evaluatedWith: status)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(status.value as? String ?? status.label, "Reveal in Finder: settings.json")
        window.webViews.links["Sibling"].firstMatch.hover()
        let relativeTarget = "Reveal in Finder: ../shared/settings.json"
        expectation(for: NSPredicate(format: "value == %@ OR label == %@", relativeTarget, relativeTarget), evaluatedWith: status)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(status.value as? String ?? status.label, relativeTarget)
        capture(app, name: "link-action-and-destination")
        window.webViews.staticTexts["Hover"].firstMatch.hover()
        XCTAssertTrue(status.waitForNonExistence(timeout: 3))
    }

    @MainActor
    private func verifyFilePreview(fileExtension: String) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let target = directory.appendingPathComponent("Linked Target.\(fileExtension)")
        if ["md", "json"].contains(fileExtension) {
            let contents = fileExtension == "md" ? "# Target Preview" : "{\"preview\": true}"
            try Data(contents.utf8).write(to: target)
        } else {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            for y in 0..<64 {
                for x in 0..<96 { bitmap.setColor(.systemRed, atX: x, y: y) }
            }
            let imageType: NSBitmapImageRep.FileType = fileExtension == "png" ? .png : .jpeg
            try XCTUnwrap(bitmap.representation(using: imageType, properties: [:])).write(to: target)
        }
        let paragraphsBefore = (1...80).map { "Paragraph \($0). Content before the reading position." }.joined(separator: "\n\n")
        let paragraphsAfter = (81...160).map { "Paragraph \($0). Content after the reading position." }.joined(separator: "\n\n")
        try """
            # Local Links

            \(paragraphsBefore)

            ## Reading position

            [View target](Linked%20Target.\(fileExtension))

            \(paragraphsAfter)
            """
            .write(to: source, atomically: true, encoding: .utf8)
        let app = open(source)
        defer { app.terminate() }
        let window = app.windows["source.md"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.click()
        let viewport = window.scrollViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        let topHeading = window.webViews.staticTexts["Local Links"].firstMatch
        XCTAssertTrue(topHeading.waitForExistence(timeout: 5))
        XCTAssertTrue(topHeading.isHittable)
        let initialTopY = topHeading.frame.minY
        let link = window.webViews.links["View target"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertFalse(link.isHittable, "The target must start below the viewport so this test requires scrolling.")
        for _ in 0..<24 where !link.isHittable {
            viewport.scroll(byDeltaX: 0, deltaY: -400)
        }
        XCTAssertTrue(link.isHittable)
        XCTAssertFalse(topHeading.isHittable)
        XCTAssertGreaterThan(
            initialTopY - topHeading.frame.minY, viewport.frame.height,
            "The source must be scrolled by more than a viewport before opening Quick Look."
        )
        let readingMarker = window.webViews.staticTexts["Reading position"].firstMatch
        XCTAssertTrue(readingMarker.isHittable)
        let readingMarkerY = readingMarker.frame.minY
        let originalY = link.frame.minY
        link.rightClick()
        let quickLook = app.menuItems["Quick Look"].firstMatch
        XCTAssertTrue(quickLook.waitForExistence(timeout: 3))
        quickLook.click()

        // On a sandboxed launch only source.md may be authorized. Select the
        // linked file itself if access is needed; no folder grant is involved.
        let allow = app.buttons["Allow Access"].firstMatch
        if allow.waitForExistence(timeout: 3) {
            app.typeKey("g", modifierFlags: [.command, .shift])
            app.typeKey("a", modifierFlags: .command)
            app.typeText(target.path)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(allow.waitForExistence(timeout: 3))
            allow.click()
        }

        let preview = app.windows["Quick Look"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15), app.debugDescription)
        if fileExtension == "md" {
            XCTAssertTrue(preview.webViews.staticTexts["Target Preview"].firstMatch.waitForExistence(timeout: 5))
        }
        XCTAssertEqual(app.windows.matching(identifier: "source.md").count, 1)
        capture(app, name: "linked-\(fileExtension)-quick-look")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        XCTAssertTrue(link.isHittable)
        XCTAssertEqual(link.frame.minY, originalY, accuracy: 12)
        XCTAssertTrue(readingMarker.isHittable)
        XCTAssertEqual(readingMarker.frame.minY, readingMarkerY, accuracy: 12)
        XCTAssertFalse(topHeading.isHittable)
        XCTAssertFalse(window.sheets.firstMatch.exists)
        if fileExtension == "json" {
            link.rightClick()
            let reopen = app.menuItems["Quick Look"].firstMatch
            XCTAssertTrue(reopen.waitForExistence(timeout: 3))
            reopen.click()
            XCTAssertTrue(preview.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["Allow Access"].firstMatch.exists, "The item grant must survive dismissing Quick Look.")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
            XCTAssertEqual(link.frame.minY, originalY, accuracy: 12)
        }
    }

    @MainActor
    private func open(_ source: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-DefaultViewModeEnabled", "NO"]
        app.terminate()
        addTeardownBlock { @MainActor in app.terminate() }
        app.open(source)
        app.activate()
        return app
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLensLinkedFileUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
