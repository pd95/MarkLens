//
//  MarkLensUITests.swift
//  MarkLensUITests
//
//  Created by Philipp on 17.05.2026.
//

import XCTest

final class MarkLensUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDocumentWindowPlacementSurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLensPlacementUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("placement.md")
        try "# Placement".write(to: documentURL, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.open(documentURL)
        defer { app.terminate() }

        let window = app.windows["placement.md"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let original = window.frame
        let resizeHandle = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -3, dy: -3))
        resizeHandle.press(
            forDuration: 0.2,
            thenDragTo: resizeHandle.withOffset(CGVector(dx: -80, dy: -60))
        )
        let resized = window.frame
        XCTAssertGreaterThan(abs(resized.width - original.width), 20)
        XCTAssertGreaterThan(abs(resized.height - original.height), 20)
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        titleBar.press(
            forDuration: 0.1,
            thenDragTo: titleBar.withOffset(CGVector(dx: 45, dy: 35))
        )
        let expected = window.frame
        XCTAssertGreaterThan(abs(expected.minX - resized.minX), 20)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.terminate()

        app.open(documentURL)
        let reopened = app.windows["placement.md"].firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        let actual = reopened.frame
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 12)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 12)
        XCTAssertEqual(actual.width, expected.width, accuracy: 12)
        XCTAssertEqual(actual.height, expected.height, accuracy: 12)
    }

    @MainActor
    func testLocalMarkdownLinkOffersNativeNewTabAction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLensTabUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let target = directory.appendingPathComponent("target.md")
        try "[Target](target.md)".write(to: source, atomically: true, encoding: .utf8)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-DefaultViewModeEnabled", "NO",
            "-LinkedDocumentOpenPreference", "newWindow"
        ]
        app.open(source)
        defer { app.terminate() }

        let window = app.windows["source.md"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let link = window.webViews.links["Target"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.rightClick()
        let newTab = app.menuItems["Open in New Tab"].firstMatch
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            abs(newTab.frame.midY - link.frame.midY),
            120,
            "The link context menu should appear beside the clicked link."
        )
        newTab.click()
        let targetWindow = app.windows["target.md"].firstMatch
        XCTAssertTrue(targetWindow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(targetWindow.isHittable, "The new document tab should be selected.")
    }

    @MainActor
    func testOpenInWindowKeepsDocumentSeparateAndReusesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLensWindowUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let target = directory.appendingPathComponent("target.md")
        try "[Target](target.md)".write(to: source, atomically: true, encoding: .utf8)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-DefaultViewModeEnabled", "NO",
            "-LinkedDocumentOpenPreference", "newWindow"
        ]
        app.open(source)
        defer { app.terminate() }

        let sourceWindow = app.windows["source.md"].firstMatch
        XCTAssertTrue(sourceWindow.waitForExistence(timeout: 5))
        let link = sourceWindow.webViews.links["Target"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.click()
        let targetWindow = app.windows["target.md"].firstMatch
        XCTAssertTrue(targetWindow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(sourceWindow.exists, "The source should remain a separate window.")
        XCTAssertTrue(targetWindow.isHittable)

        sourceWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        link.click()
        XCTAssertTrue(targetWindow.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.matching(identifier: "target.md").count, 1)
        XCTAssertTrue(targetWindow.isHittable)
    }

    @MainActor
    func testNormalLinkCanOpenInNewTabFromAppPreference() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLensPreferredTabUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let target = directory.appendingPathComponent("target.md")
        try "[Target](target.md)".write(to: source, atomically: true, encoding: .utf8)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-DefaultViewModeEnabled", "NO",
            "-LinkedDocumentOpenPreference", "newTab"
        ]
        app.open(source)
        defer { app.terminate() }

        let sourceWindow = app.windows["source.md"].firstMatch
        XCTAssertTrue(sourceWindow.waitForExistence(timeout: 5))
        let link = sourceWindow.webViews.links["Target"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.click()
        let targetWindow = app.windows["target.md"].firstMatch
        XCTAssertTrue(targetWindow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(targetWindow.isHittable)
    }

    @MainActor
    func testCommandClickOpensLocalMarkdownInSelectedTab() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLensCommandTabUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let target = directory.appendingPathComponent("target.md")
        try "[Target](target.md)".write(to: source, atomically: true, encoding: .utf8)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-DefaultViewModeEnabled", "YES"]
        app.open(source)
        defer { app.terminate() }

        let sourceWindow = app.windows["source.md"].firstMatch
        XCTAssertTrue(sourceWindow.waitForExistence(timeout: 5))
        let link = sourceWindow.webViews.links["Target"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCUIElement.perform(withKeyModifiers: .command) {
            link.click()
        }
        let targetWindow = app.windows["target.md"].firstMatch
        XCTAssertTrue(targetWindow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(targetWindow.isHittable)
    }

    @MainActor
    func testViewModeRequestsFolderAccessForInWindowLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLensViewModeUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let target = directory.appendingPathComponent("target.md")
        try "[Target](target.md)".write(to: source, atomically: true, encoding: .utf8)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-DefaultViewModeEnabled", "YES"]
        app.open(source)
        defer { app.terminate() }

        let window = app.windows["source.md"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let link = window.webViews.links["Target"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.click()
        let accessSheet = window.sheets.firstMatch
        XCTAssertTrue(accessSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(accessSheet.buttons["action-button-1"].exists)
    }

    @MainActor
    func testOpensSampleMarkLens() throws {
        let preview = XCUIApplication().openDocument(named: "sample", fileExtension: "md")
        defer { preview.terminate() }

        capture(preview.window, name: "sample-md-preview")
    }

    @MainActor
    func testExternalRefreshPreservesPreviewPosition() throws {
        let preview = XCUIApplication().openDocument(named: "sample", fileExtension: "md")
        defer { preview.terminate() }

        try preview.verifyExternalRefreshPreservesPreviewPosition()
    }

    @MainActor
    func testSourceDraftAutosavesAndCancelRestoresBaseline() throws {
        let preview = XCUIApplication().openDocument(named: "sample", fileExtension: "md")
        defer { preview.terminate() }

        try preview.verifySourceDraftAutosavesAndCancelRestoresBaseline()
    }

    @MainActor
    func testCreatesStarterDocument() throws {
        let preview = XCUIApplication().openDocument(named: "sample", fileExtension: "md")
        defer { preview.terminate() }

        preview.createStarterDocument()
    }

    @MainActor
    func testUpdatePopoverShowsMissedChangesAndDirectDownload() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MARKLENS_MOCK_UPDATE_VERSION"] = "99.0.0"
        let preview = app.openDocument(named: "sample", fileExtension: "md")
        defer { preview.terminate() }

        preview.verifyUpdatePopover()
        capture(app, name: "update-release-notes-popover")
        preview.remindAboutUpdateLater()
    }

    @MainActor
    func testUpdatePopoverCanSkipVersion() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MARKLENS_MOCK_UPDATE_VERSION"] = "99.0.0"
        let preview = app.openDocument(named: "sample", fileExtension: "md")
        defer { preview.terminate() }

        preview.verifyUpdatePopover()
        preview.skipAvailableUpdate()
    }

    @MainActor
    func testInstalledReleaseNotesOpenAutomatically() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MARKLENS_MOCK_INSTALLED_RELEASE_VERSION"] = "1.7.0"
        app.launchEnvironment["MARKLENS_MOCK_PREVIOUS_INSTALLED_VERSION"] = "1.5.0"
        app.launchEnvironment["MARKLENS_FORCE_WHATS_NEW"] = "1"
        let preview = app.openDocument(named: "sample", fileExtension: "md")
        defer { preview.terminate() }

        preview.verifyInstalledReleaseNotes(includesPreviousRelease: true)
        capture(app, name: "installed-release-notes-window")
        preview.verifyFullChangelogLinkExists()
        preview.openChangelogFromHelp()
        preview.verifyCompleteChangelogCanScrollToOldestChange()
    }

    @MainActor
    func testInstalledReleaseNotesOpenFromHelpMenu() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MARKLENS_MOCK_INSTALLED_RELEASE_VERSION"] = "1.7.0"
        app.launchEnvironment["MARKLENS_MOCK_PREVIOUS_INSTALLED_VERSION"] = "1.7.0"
        let preview = app.openDocument(
            named: "sample",
            fileExtension: "md",
            additionalLaunchArguments: [
                "-releaseNotes.currentRelease", "",
                "-releaseNotes.previousRelease", "",
            ]
        )
        defer { preview.terminate() }

        preview.openReleaseNotesFromHelp()
        preview.verifyCurrentReleaseNotes(version: "1.7.0")
        preview.openChangelogFromHelp()
        preview.verifyCompleteChangelog()
    }

    @MainActor
    func testInstalledReleaseNotesAppearOnlyOncePerVersion() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MARKLENS_MOCK_INSTALLED_RELEASE_VERSION"] = "97.0.0"
        app.launchEnvironment["MARKLENS_FORCE_WHATS_NEW"] = "1"
        let firstLaunch = app.openDocument(named: "sample", fileExtension: "md")

        XCTAssertTrue(
            firstLaunch.installedReleaseNotesWindow.waitForExistence(timeout: 5),
            "Expected release notes on the first launch of this version."
        )
        firstLaunch.terminate()

        app.launchEnvironment.removeValue(forKey: "MARKLENS_FORCE_WHATS_NEW")
        let secondLaunch = app.openDocument(named: "sample", fileExtension: "md")
        defer { secondLaunch.terminate() }

        XCTAssertFalse(
            secondLaunch.installedReleaseNotesWindow.waitForExistence(timeout: 2),
            "Expected acknowledged release notes to stay closed on the next launch."
        )
    }

    @MainActor
    func testDebugHelpShowsCurrentReleaseNotesAndChangelog() throws {
        let app = XCUIApplication()
        let preview = app.openDocument(named: "sample", fileExtension: "md")
        defer { preview.terminate() }

        XCTAssertFalse(
            preview.installedReleaseNotesWindow.exists,
            "Expected the development changelog to remain opt-in."
        )
        preview.openReleaseNotesFromHelp()
        preview.verifyCurrentReleaseNotes(version: "1.9.0")
        preview.openChangelogFromHelp()
        preview.verifyCompleteChangelog()
        capture(app, name: "debug-complete-changelog-window")
    }

    @MainActor
    func testFrontMatterCardSupportsDarkMode() throws {
        let app = XCUIApplication()
        let preview = app.openDocument(
            named: "frontmatter",
            fileExtension: "md",
            additionalLaunchArguments: ["-AppleInterfaceStyle", "Dark"]
        )
        defer { preview.terminate() }

        preview.verifyFrontMatterCard()
        capture(preview.window, name: "frontmatter-dark-mode")
    }

    @MainActor
    func testOpenFileRecorded() throws {
        let preview = XCUIApplication().openDocument(named: "search-sample", fileExtension: "md")
        defer { preview.terminate() }

        capture(preview.window, name: "search-sample-opened")

        preview.openFind()
        capture(preview.window, name: "search-sample-find-open")

        preview.search("MLX")
        capture(preview.window, name: "search-sample-search-mlx")

        preview.submitSearch()
        preview.submitSearch()
        preview.submitSearch()
        capture(preview.window, name: "search-sample-search-mlx-advanced")

        preview.search(" ")
        capture(preview.window, name: "search-sample-search-mlx-space")

        preview.previousSearchResult()
        capture(preview.window, name: "search-sample-search-previous")

        preview.nextSearchResult()
        capture(preview.window, name: "search-sample-search-next")

        preview.verifyCollapsedSelectionDoesNotReplaceSearch()
        preview.refocusFindUsingSelection(expectedText: "Think")
        preview.verifyKeyboardSearchNavigation()
        capture(preview.window, name: "search-sample-search-think")

        preview.closeFind()
        capture(preview.window, name: "search-sample-search-closed")
    }

    @MainActor
    func testCancelDismissesPrintDialog() throws {
        let preview = XCUIApplication().openDocument(named: "sample", fileExtension: "md")
        defer { preview.terminate() }

        preview.cancelPrint()
    }

    @MainActor
    func testExportCancellationAndRenderedFormats() throws {
        let preview = XCUIApplication().openDocument(named: "sample", fileExtension: "md")
        defer { preview.terminate() }

        preview.cancelExport()
        try preview.exportAndVerifyContent(format: .pdf)
        try preview.exportAndVerifyContent(format: .html)
    }
}

private extension XCUIApplication {
    @MainActor
    @discardableResult
    func openDocument(
        named baseName: String,
        fileExtension: String,
        additionalLaunchArguments: [String] = [],
        file: StaticString = #file,
        line: UInt = #line
    ) -> MarkLensAppHandle {
        guard let fixtureURL = Bundle(for: MarkLensUITests.self)
            .url(forResource: baseName, withExtension: fileExtension) else {
            XCTFail("Could not locate fixture \(baseName).\(fileExtension).", file: file, line: line)
            launch()
            return previewHandle(
                documentTitle: "\(baseName).\(fileExtension)",
                file: file,
                line: line
            )
        }

        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLensUITests-\(UUID().uuidString)", isDirectory: true)
        let temporaryDocumentURL = exportDirectory.appendingPathComponent(
            fixtureURL.lastPathComponent
        )
        do {
            try FileManager.default.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true
            )
            try Data(contentsOf: fixtureURL).write(to: temporaryDocumentURL, options: .atomic)
        } catch {
            XCTFail("Could not prepare the temporary test document: \(error)", file: file, line: line)
        }

        terminate()
        launchEnvironment["MARKLENS_UI_TEST_EXPORT_DIRECTORY"] = exportDirectory.path
        launchArguments = [
            "-ApplePersistenceIgnoreState",
            "YES",
            "-CustomCSSOverrides",
            "",
            "-LastRenderedDocumentExportFormat",
            "pdf",
        ] + additionalLaunchArguments
        open(temporaryDocumentURL)

        return previewHandle(
            documentTitle: "\(baseName).\(fileExtension)",
            exportDirectoryURL: exportDirectory,
            documentURL: temporaryDocumentURL,
            file: file,
            line: line
        )
    }

    @MainActor
    func previewHandle(
        documentTitle: String,
        exportDirectoryURL: URL? = nil,
        documentURL: URL? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) -> MarkLensAppHandle {
        let window = windows[documentTitle].firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 5),
            "Expected \(documentTitle) window to appear.",
            file: file,
            line: line
        )

        let contentView = window.descendants(matching: .any)["contentView"]
        XCTAssertTrue(
            contentView.waitForExistence(timeout: 5),
            "Expected markdown preview content view to appear.",
            file: file,
            line: line
        )

        let identifiedWebView = window.descendants(matching: .any)["previewWebView"]
        let webView = identifiedWebView.exists ? identifiedWebView : window.webViews.firstMatch
        if webView.waitForExistence(timeout: 5) == false {
            XCTFail("Expected rendered markdown web view to appear.", file: file, line: line)
        }

        return MarkLensAppHandle(
            app: self,
            window: window,
            contentView: contentView,
            exportDirectoryURL: exportDirectoryURL,
            documentURL: documentURL
        )
    }
}

@MainActor
private struct MarkLensAppHandle {
    enum ExportFormat {
        case pdf
        case html

        var pathExtension: String {
            switch self {
            case .pdf: "pdf"
            case .html: "html"
            }
        }
    }

    let app: XCUIApplication
    let window: XCUIElement
    let contentView: XCUIElement
    let exportDirectoryURL: URL?
    let documentURL: URL?

    var findField: XCUIElement {
        app.textFields["previewFindField"].firstMatch
    }

    var previewText: XCUIElement {
        app.staticTexts["Search Fixture"].firstMatch
    }

    var installedReleaseNotesWindow: XCUIElement {
        app.windows["installed-release-notes"].firstMatch
    }

    func verifyUpdatePopover() {
        let updateButton = app.buttons["updateAvailableButton"].firstMatch
        XCTAssertTrue(
            updateButton.waitForExistence(timeout: 5),
            "Expected the mocked update indicator to appear."
        )
        updateButton.click()

        XCTAssertTrue(
            app.staticTexts["What’s New"].firstMatch.waitForExistence(timeout: 5),
            "Expected the expanded release-notes popover."
        )
        let downloadButton = app.buttons["Download Update"].firstMatch
        XCTAssertTrue(
            downloadButton.waitForExistence(timeout: 5),
            "Expected a direct download action for the release ZIP."
        )
        XCTAssertTrue(downloadButton.isHittable, "Expected the download action to remain on-screen.")
        XCTAssertTrue(
            app.buttons["Remind Me Later"].firstMatch.waitForExistence(timeout: 5),
            "Expected the update reminder action."
        )
        XCTAssertTrue(
            app.buttons["Skip This Version"].firstMatch.waitForExistence(timeout: 5),
            "Expected the version skip action."
        )
        XCTAssertTrue(
            app.staticTexts["99.0.0"].firstMatch.waitForExistence(timeout: 5),
            "Expected the newest changelog section."
        )
        XCTAssertTrue(
            app.staticTexts["98.0.0"].firstMatch.waitForExistence(timeout: 5),
            "Expected an earlier missed changelog section."
        )
    }

    func remindAboutUpdateLater() {
        app.buttons["Remind Me Later"].firstMatch.click()
        XCTAssertTrue(
            app.buttons["updateAvailableButton"].firstMatch.waitForNonExistence(timeout: 5),
            "Expected Remind Me Later to remove the update badge."
        )
    }

    func skipAvailableUpdate() {
        app.buttons["Skip This Version"].firstMatch.click()
        XCTAssertTrue(
            app.buttons["updateAvailableButton"].firstMatch.waitForNonExistence(timeout: 5),
            "Expected Skip This Version to remove the update badge."
        )
    }

    func verifyInstalledReleaseNotes(includesPreviousRelease: Bool) {
        let notesWindow = installedReleaseNotesWindow
        XCTAssertTrue(
            notesWindow.waitForExistence(timeout: 5),
            "Expected the installed release-notes window."
        )
        XCTAssertEqual(
            notesWindow.title,
            "MarkLens Release Notes",
            "Expected the native release-notes window title."
        )
        XCTAssertTrue(
            notesWindow.staticTexts["1.7.0"].firstMatch.waitForExistence(timeout: 5),
            "Expected the current changelog section."
        )
        if includesPreviousRelease {
            XCTAssertTrue(
                notesWindow.staticTexts["1.6.0"].firstMatch.waitForExistence(timeout: 5),
                "Expected an intervening changelog section."
            )
        }
    }

    func openReleaseNotesFromHelp() {
        let helpMenu = app.menuBars.menuBarItems["Help"].firstMatch
        helpMenu.click()
        let menuItem = helpMenu.menus.menuItems["Release Notes"].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Expected the Release Notes Help command.")
        menuItem.click()
    }

    func openChangelogFromHelp() {
        let helpMenu = app.menuBars.menuBarItems["Help"].firstMatch
        helpMenu.click()
        let menuItem = helpMenu.menus.menuItems["Changelog"].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Expected the Changelog Help command.")
        menuItem.click()
    }

    func verifyFullChangelogLinkExists() {
        let button = installedReleaseNotesWindow.descendants(matching: .any)[
            "viewFullChangelogButton"
        ].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Expected a link to the full changelog.")
    }

    func verifyCurrentReleaseNotes(version: String) {
        let notesWindow = installedReleaseNotesWindow
        XCTAssertTrue(notesWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(notesWindow.staticTexts[version].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(notesWindow.staticTexts["1.8.1"].firstMatch.exists)
    }

    func verifyCompleteChangelog() {
        let notesWindow = installedReleaseNotesWindow
        XCTAssertTrue(
            notesWindow.waitForExistence(timeout: 5),
            "Expected the complete changelog window."
        )
        XCTAssertEqual(
            notesWindow.title,
            "MarkLens Release Notes",
            "Expected the native changelog window title."
        )
        XCTAssertTrue(
            notesWindow.staticTexts["1.8.1"].firstMatch
                .waitForExistence(timeout: 5),
            "Expected the current changelog section."
        )
        XCTAssertTrue(
            notesWindow.staticTexts["1.0.4"].firstMatch.waitForExistence(timeout: 5),
            "Expected the entire bundled changelog, including its oldest section."
        )
    }

    func verifyFrontMatterCard() {
        XCTAssertTrue(
            app.staticTexts["Document details"].firstMatch.waitForExistence(timeout: 5),
            "Expected the front-matter card summary."
        )
        XCTAssertTrue(
            app.staticTexts["Dark Mode Compatibility"].firstMatch.waitForExistence(timeout: 5),
            "Expected the front-matter title."
        )
    }

    func verifyCompleteChangelogCanScrollToOldestChange() {
        let notesWindow = installedReleaseNotesWindow
        let oldestChange = notesWindow.staticTexts[
            "Improved Quick Look preview rendering and shared app/extension resources."
        ].firstMatch
        XCTAssertTrue(
            oldestChange.waitForExistence(timeout: 10),
            "Expected the oldest bundled changelog entry to be rendered."
        )

        let notesWebView = notesWindow.webViews.firstMatch
        XCTAssertTrue(
            notesWebView.waitForExistence(timeout: 5),
            "Expected scrollable release-note content."
        )
        let notesScrollView = notesWindow.scrollViews.firstMatch
        XCTAssertTrue(
            notesScrollView.waitForExistence(timeout: 5),
            "Expected the release-note content to expose a scroll view."
        )
        let initialChangeFrame = oldestChange.frame
        for _ in 0..<60 where oldestChange.isHittable == false {
            notesScrollView.scroll(byDeltaX: 0, deltaY: -400)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            oldestChange.isHittable,
            "Expected scrolling to reveal the oldest bundled changelog entry. "
                + "Initial frame: \(initialChangeFrame); final frame: \(oldestChange.frame); "
                + "window: \(notesWindow.frame)."
        )
    }

    func openFind() {
        if findField.exists {
            return
        }

        contentView.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(findField.waitForExistence(timeout: 5), "Expected preview find field to appear.")
    }

    func createStarterDocument() {
        let originalWindowCount = app.windows.count
        let previews = app.webViews
        let originalPreviewCount = previews.count
        let fileMenu = app.menuBars.menuBarItems["File"]
        fileMenu.click()

        let newItem = fileMenu.menus.menuItems["New"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 2), "Expected the File → New command.")
        XCTAssertTrue(newItem.isEnabled, "Expected File → New to be enabled.")
        newItem.click()

        let deadline = Date().addingTimeInterval(5)
        while app.windows.count <= originalWindowCount, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(
            app.windows.count,
            originalWindowCount,
            "Expected File → New to create another document window."
        )

        let previewDeadline = Date().addingTimeInterval(5)
        while previews.count <= originalPreviewCount, Date() < previewDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(
            previews.count,
            originalPreviewCount,
            "Expected the new Markdown document to display its rendered preview."
        )

        app.typeKey("e", modifierFlags: .command)
        let sourceEditor = app.textViews["Markdown source editor"].firstMatch
        XCTAssertTrue(
            sourceEditor.waitForExistence(timeout: 5),
            "Expected the new document to expose its editable Markdown source."
        )
        XCTAssertTrue(
            (sourceEditor.value as? String)?.contains("# Welcome to MarkLens") == true,
            "Expected File → New to use the Markdown starter."
        )
        let focusMarker = "editor-focus-check"
        app.typeText(focusMarker)
        XCTAssertTrue(
            (sourceEditor.value as? String)?.contains(focusMarker) == true,
            "Expected source editing to begin with keyboard focus in the editor."
        )
        let literalMarkdown = "'literal-quotes' -- literal-dashes"
        app.typeText(literalMarkdown)
        XCTAssertTrue(
            (sourceEditor.value as? String)?.contains(literalMarkdown) == true,
            "Expected source editing to preserve literal Markdown punctuation."
        )
    }

    func verifyExternalRefreshPreservesPreviewPosition() throws {
        let documentURL = try XCTUnwrap(documentURL)
        let target = app.staticTexts["Fenced math"].firstMatch

        openFind()
        search("math")
        for _ in 0..<12 where target.isHittable == false {
            submitSearch()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(
            waitUntilHittable(target),
            "Expected preview search to reveal the middle document section."
        )
        let originalY = target.frame.minY

        let insertedSections = (1...20).map { index in
            "## External Update \(index)\n\nInserted content above the reading position."
        }.joined(separator: "\n\n")
        let originalText = try String(contentsOf: documentURL, encoding: .utf8)
        let updatedText = originalText.replacingOccurrences(
            of: "# Main markdown\n",
            with: "# Main markdown\n\n\(insertedSections)\n"
        )
        XCTAssertNotEqual(updatedText, originalText)
        try updatedText.write(to: documentURL, atomically: true, encoding: .utf8)

        let refreshedHeading = app.staticTexts["External Update 20"].firstMatch
        XCTAssertTrue(
            refreshedHeading.waitForExistence(timeout: 8),
            "Expected MarkLens to render the externally updated file."
        )
        XCTAssertTrue(
            waitUntilHittable(target),
            "Expected the section being read to remain visible after refresh."
        )
        XCTAssertEqual(
            target.frame.minY,
            originalY,
            accuracy: 80,
            "Expected external refresh to preserve the section's viewport position."
        )
        XCTAssertTrue(
            remainsStable(target, near: originalY),
            "Expected active Find reconstruction not to override the restored position."
        )
    }

    func verifySourceDraftAutosavesAndCancelRestoresBaseline() throws {
        let documentURL = try XCTUnwrap(documentURL)
        let originalText = try String(contentsOf: documentURL, encoding: .utf8)
        let draftText = "# Autosaved source draft\n\nLiteral Markdown content."

        contentView.typeKey("e", modifierFlags: .command)
        let sourceEditor = app.textViews["Markdown source editor"].firstMatch
        XCTAssertTrue(
            sourceEditor.waitForExistence(timeout: 5),
            "Expected the source editor to open."
        )
        sourceEditor.typeKey("a", modifierFlags: .command)
        sourceEditor.typeText(draftText)

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(
            waitForFile(documentURL, toEqual: draftText, timeout: 8),
            "Expected background autosave to persist the visible source draft."
        )

        app.activate()
        XCTAssertTrue(sourceEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(sourceEditor.value as? String, draftText)
        XCTAssertFalse(app.alerts["File Changed Externally"].exists)

        app.buttons["Cancel"].firstMatch.click()
        finder.activate()
        XCTAssertTrue(
            waitForFile(documentURL, toEqual: originalText, timeout: 8),
            "Expected Cancel to autosave the restored edit-session baseline."
        )
    }

    private func waitForFile(_ url: URL, toEqual expectedText: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? String(contentsOf: url, encoding: .utf8)) == expectedText {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.isHittable == false, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.isHittable
    }

    private func remainsStable(
        _ element: XCUIElement,
        near expectedY: CGFloat,
        accuracy: CGFloat = 80,
        duration: TimeInterval = 1
    ) -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard element.isHittable, abs(element.frame.minY - expectedY) <= accuracy else {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    func search(_ text: String) {
        findField.click()
        findField.typeText(text)
    }

    func submitSearch() {
        findField.typeText("\r")
    }

    func refocusFindUsingSelection(expectedText: String) {
        let selectedText = app.staticTexts["Think carefully about the final paragraph."].firstMatch
        XCTAssertTrue(selectedText.waitForExistence(timeout: 2), "Expected selectable rendered preview text.")
        selectedText
            .coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .doubleClick()

        contentView.typeKey("f", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(2)
        while findField.value as? String != expectedText, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(
            findField.value as? String,
            expectedText,
            "Expected Command-F to copy the web selection into the refocused find field."
        )
    }

    func verifyCollapsedSelectionDoesNotReplaceSearch() {
        let originalSearch = findField.value as? String
        let selectedText = app.staticTexts["Think carefully about the final paragraph."].firstMatch
        XCTAssertTrue(selectedText.waitForExistence(timeout: 2), "Expected selectable rendered preview text.")
        selectedText
            .coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .doubleClick()
        previewText.click()

        contentView.typeKey("f", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            XCTAssertEqual(
                findField.value as? String,
                originalSearch,
                "Expected Command-F to ignore a collapsed, stale web selection."
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func verifyKeyboardSearchNavigation() {
        let status = app.staticTexts["previewFindStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 2), "Expected search result status.")
        XCTAssertTrue(
            waitForSearchResults(in: status),
            "Expected matching search results, got label \(status.label), value \(String(describing: status.value))."
        )
        XCTAssertEqual(searchStatusText(status), "2 of 2", "Expected search to start at the selected text.")

        previewText.click()

        let initialStatus = searchStatusText(status)
        contentView.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForLabelChange(of: status, from: initialStatus), "Expected Return to select the next result.")

        let returnStatus = searchStatusText(status)
        contentView.typeKey("g", modifierFlags: .command)
        XCTAssertTrue(waitForLabelChange(of: status, from: returnStatus), "Expected Command-G to select the next result.")

        let nextStatus = searchStatusText(status)
        contentView.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForLabelChange(of: status, from: nextStatus), "Expected Shift-Command-G to select the previous result.")
    }

    private func waitForLabelChange(of element: XCUIElement, from originalLabel: String) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while searchStatusText(element) == originalLabel, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return searchStatusText(element) != originalLabel
    }

    private func waitForSearchResults(in element: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while searchStatusText(element).contains(" of ") == false, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return searchStatusText(element).contains(" of ")
    }

    private func searchStatusText(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    func previousSearchResult() {
        let button = app.buttons["previewFindPreviousButton"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 2), "Expected previous search button.")
        button.click()
    }

    func nextSearchResult() {
        let button = app.buttons["previewFindNextButton"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 2), "Expected next search button.")
        button.click()
    }

    func closeFind() {
        let button = app.buttons["previewFindDoneButton"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 2), "Expected done search button.")
        button.click()
        XCTAssertFalse(findField.exists, "Expected preview find field to close.")
    }

    func cancelPrint() {
        contentView.typeKey("p", modifierFlags: .command)

        let printSheet = window.sheets.firstMatch
        XCTAssertTrue(printSheet.waitForExistence(timeout: 5), "Expected the print dialog to appear.")

        let cancelButton = printSheet.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Expected the print dialog to appear.")
        cancelButton.click()
        XCTAssertTrue(
            printSheet.waitForNonExistence(timeout: 2),
            "Expected the print dialog to stay dismissed after cancellation."
        )
        XCTAssertFalse(
            window.sheets.firstMatch.waitForExistence(timeout: 1),
            "Expected the print dialog not to reappear after cancellation."
        )
    }

    func cancelExport() {
        let exportSheet = openExportSheet()
        let cancelButton = exportSheet.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 2), "Expected the Export cancel button.")
        cancelButton.click()
        XCTAssertTrue(
            exportSheet.waitForNonExistence(timeout: 2),
            "Expected the Export dialog to stay dismissed after cancellation."
        )
    }

    func exportAndVerifyContent(format: ExportFormat) throws {
        let exportDirectoryURL = try XCTUnwrap(exportDirectoryURL)
        let filesBeforeExport = try exportedFiles(in: exportDirectoryURL)

        let exportSheet = openExportSheet()
        let formatPopup = formatPopup(in: exportSheet)
        if format == .html {
            formatPopup.click()
            formatPopup.typeKey(.downArrow, modifierFlags: [])
            formatPopup.typeKey(.return, modifierFlags: [])
        }

        let exportButton = exportSheet.buttons["Export"].firstMatch
        XCTAssertTrue(exportButton.waitForExistence(timeout: 2), "Expected the Export button.")
        exportButton.click()

        // PDF generation may temporarily replace the save panel with another sheet.
        // The file itself is the reliable signal that the asynchronous export finished.
        let deadline = Date().addingTimeInterval(15)
        var exportURL: URL?
        while Date() < deadline {
            exportURL = try exportedFiles(in: exportDirectoryURL).subtracting(filesBeforeExport).first
            if exportURL != nil {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let unsafeDestinationAlert = app.alerts["Unsafe Test Export Destination"]
        XCTAssertFalse(
            unsafeDestinationAlert.waitForExistence(timeout: 1),
            "The app rejected the temporary export directory."
        )
        let completedExportURL = try XCTUnwrap(
            exportURL,
            "Expected the export in the UI test's temporary directory."
        )
        defer { try? FileManager.default.removeItem(at: completedExportURL) }
        XCTAssertEqual(completedExportURL.pathExtension, format.pathExtension)

        let data = try Data(contentsOf: completedExportURL)
        switch format {
        case .pdf:
            XCTAssertTrue(data.starts(with: Data("%PDF-".utf8)), "Expected a PDF file.")
            XCTAssertGreaterThan(data.count, 2_000, "Expected rendered PDF content, not empty pages.")
        case .html:
            let html = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(html.contains("<!DOCTYPE html>"), "Expected an HTML document.")
            XCTAssertTrue(html.contains("data-mermaid-diagram"), "Expected the Mermaid diagram markup.")
            XCTAssertTrue(html.contains("mermaid.initialize"), "Expected the Mermaid renderer.")
            XCTAssertFalse(html.contains("marklens-resource://"), "Expected app resources to be inlined.")
            XCTAssertFalse(
                html.contains("data:application/javascript"),
                "Expected executable JavaScript to be safely inlined."
            )
        }
    }

    private func exportedFiles(in directory: URL) throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))
    }

    private func openExportSheet() -> XCUIElement {
        contentView.typeKey("e", modifierFlags: [.command, .shift])

        let exportSheet = window.sheets.firstMatch
        XCTAssertTrue(exportSheet.waitForExistence(timeout: 5), "Expected the Export dialog to appear.")
        _ = formatPopup(in: exportSheet)
        return exportSheet
    }

    private func formatPopup(in exportSheet: XCUIElement) -> XCUIElement {
        let popups = exportSheet.popUpButtons
        XCTAssertGreaterThanOrEqual(
            popups.count,
            2,
            "Expected separate path and file-format selectors."
        )
        let popup = popups.element(boundBy: popups.count - 1)
        XCTAssertTrue(popup.waitForExistence(timeout: 2), "Expected the PDF and HTML format selector.")
        return popup
    }

    func terminate() {
        app.terminate()
        if let exportDirectoryURL {
            try? FileManager.default.removeItem(at: exportDirectoryURL)
        }
    }
}
