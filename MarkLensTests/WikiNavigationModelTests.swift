import XCTest
@testable import MarkLens

@MainActor
final class WikiNavigationModelTests: XCTestCase {
    func testBackForwardRootRestorationAndBranching() async throws {
        let model = makeModel()
        let root = URL(fileURLWithPath: "/wiki")
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        let branch = root.appendingPathComponent("branch.md")

        model.navigate(to: first, wikiRoot: root)
        await waitForLoad(model)
        model.navigate(to: second, wikiRoot: root)
        await waitForLoad(model)

        XCTAssertEqual(model.currentPage?.url, second)
        model.goBack()
        XCTAssertEqual(model.currentPage?.url, first)
        model.goBack()
        XCTAssertNil(model.currentPage)
        XCTAssertTrue(model.canGoForward)

        model.goForward()
        XCTAssertEqual(model.currentPage?.url, first)
        model.navigate(to: branch, wikiRoot: root)
        await waitForLoad(model)

        XCTAssertEqual(model.currentPage?.url, branch)
        XCTAssertFalse(model.canGoForward)
    }

    func testBackAndForwardRestoreScrollPositionForEachHistoryVisit() async {
        let model = makeModel()
        let root = URL(fileURLWithPath: "/wiki")
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        let rootPosition = Self.scrollPosition(line: 8, progress: 0.1)
        let firstPosition = Self.scrollPosition(line: 40, progress: 0.4)
        let secondPosition = Self.scrollPosition(line: 90, progress: 0.9)
        let revisitedRootPosition = Self.scrollPosition(line: 16, progress: 0.2)
        let revisitedFirstPosition = Self.scrollPosition(line: 55, progress: 0.55)

        model.navigate(
            to: first,
            wikiRoot: root,
            leavingScrollPosition: rootPosition
        )
        await waitForLoad(model)
        model.navigate(
            to: second,
            wikiRoot: root,
            leavingScrollPosition: firstPosition
        )
        await waitForLoad(model)

        let backToFirst = model.goBack(leavingScrollPosition: secondPosition)
        XCTAssertEqual(backToFirst?.location, .page(first))
        XCTAssertEqual(backToFirst?.scrollPosition, firstPosition)

        let backToRoot = model.goBack(leavingScrollPosition: revisitedFirstPosition)
        XCTAssertEqual(backToRoot?.location, .root)
        XCTAssertEqual(backToRoot?.scrollPosition, rootPosition)

        let forwardToFirst = model.goForward(
            leavingScrollPosition: revisitedRootPosition
        )
        XCTAssertEqual(forwardToFirst?.location, .page(first))
        XCTAssertEqual(forwardToFirst?.scrollPosition, revisitedFirstPosition)

        let forwardToSecond = model.goForward(
            leavingScrollPosition: revisitedFirstPosition
        )
        XCTAssertEqual(forwardToSecond?.location, .page(second))
        XCTAssertEqual(forwardToSecond?.scrollPosition, secondPosition)

        _ = model.goBack(leavingScrollPosition: secondPosition)
        let backToRevisitedRoot = model.goBack(
            leavingScrollPosition: revisitedFirstPosition
        )
        XCTAssertEqual(backToRevisitedRoot?.location, .root)
        XCTAssertEqual(backToRevisitedRoot?.scrollPosition, revisitedRootPosition)
    }

    func testFailureAndStaleCompletionDoNotMutateHistory() async throws {
        let root = URL(fileURLWithPath: "/wiki")
        let slow = root.appendingPathComponent("slow.md")
        let fast = root.appendingPathComponent("fast.md")
        let model = WikiNavigationModel { url, root, _ in
            if url.lastPathComponent == "missing.md" {
                return .failure("Missing")
            }
            if url == slow {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return .success(Self.page(url: url, root: root))
        }

        model.navigate(to: root.appendingPathComponent("missing.md"), wikiRoot: root)
        await waitForLoad(model)
        XCTAssertNil(model.currentPage)
        XCTAssertEqual(model.historyEntryCount, 0)

        model.navigate(to: slow, wikiRoot: root)
        model.navigate(to: fast, wikiRoot: root)
        await waitForLoad(model)
        try? await Task.sleep(for: .milliseconds(75))

        XCTAssertEqual(model.currentPage?.url, fast)
        XCTAssertEqual(model.historyEntryCount, 1)
    }

    func testHistoryAndSnapshotCacheAreBounded() async {
        let model = makeModel(pageSize: 2_000_000)
        let root = URL(fileURLWithPath: "/wiki")

        for index in 0..<30 {
            model.navigate(
                to: root.appendingPathComponent("page-\(index).md"),
                wikiRoot: root
            )
            await waitForLoad(model)
        }

        XCTAssertLessThanOrEqual(model.historyEntryCount, 20)
        XCTAssertLessThanOrEqual(model.cachedPageCount, 21)
        XCTAssertLessThanOrEqual(model.cachedPageByteCount, 32 * 1_024 * 1_024)

        while model.canGoBack {
            model.goBack()
        }
        XCTAssertEqual(model.current, .root)
        XCTAssertNil(model.currentPage)
    }

    func testOversizedCurrentPageDoesNotEvictRoot() async {
        let model = makeModel(pageSize: 40 * 1_024 * 1_024)
        let root = URL(fileURLWithPath: "/wiki")

        model.navigate(to: root.appendingPathComponent("huge.md"), wikiRoot: root)
        await waitForLoad(model)

        XCTAssertTrue(model.canGoBack)
        model.goBack()
        XCTAssertEqual(model.current, .root)
        XCTAssertNil(model.currentPage)
    }

    func testReloadCurrentAppliesPreferencesAndInvalidatesHistory() async {
        let root = URL(fileURLWithPath: "/wiki")
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        let model = WikiNavigationModel { url, root, preferences in
            var page = Self.page(url: url, root: root)
            page = WikiPage(
                url: page.url,
                html: preferences.loadsRemoteResources ? "remote-on" : "remote-off",
                resources: page.resources,
                containsWikiLinks: page.containsWikiLinks,
                displayPath: page.displayPath,
                estimatedByteCount: page.estimatedByteCount
            )
            return .success(page)
        }

        model.navigate(to: first, wikiRoot: root)
        await waitForLoad(model)
        model.navigate(to: second, wikiRoot: root)
        await waitForLoad(model)
        model.reloadCurrent(renderingPreferences: RenderingPreferences(
            rendersRawHTML: false,
            loadsRemoteResources: true
        ))
        await waitForLoad(model)

        XCTAssertEqual(model.currentPage?.url, second)
        XCTAssertEqual(model.currentPage?.html, "remote-on")
        XCTAssertEqual(model.historyEntryCount, 1)
        XCTAssertTrue(model.canGoBack)
        XCTAssertFalse(model.canGoForward)
    }

    func testReloadKeepsAdjustmentReasonFromDisplayedPageUntilReplacementSucceeds() async {
        let root = URL(fileURLWithPath: "/wiki")
        let pageURL = root.appendingPathComponent("page.md")
        let model = WikiNavigationModel { url, root, preferences in
            if preferences.rendersRawHTML {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let reason: HTMLContentAdjustmentReason = preferences.rendersRawHTML
                ? .unsafeContentBlocked
                : .renderingDisabled
            return .success(WikiPage(
                url: url,
                html: "rendered",
                resources: [],
                containsWikiLinks: false,
                filteredHTMLFragmentCount: 1,
                htmlContentAdjustmentReason: reason,
                displayPath: url.path.replacingOccurrences(of: root.path + "/", with: ""),
                estimatedByteCount: 8
            ))
        }

        model.navigate(to: pageURL, wikiRoot: root)
        await waitForLoad(model)
        XCTAssertEqual(model.currentPage?.htmlContentAdjustmentReason, .renderingDisabled)

        model.reloadCurrent(renderingPreferences: RenderingPreferences(
            rendersRawHTML: true,
            loadsRemoteResources: false
        ))
        XCTAssertEqual(model.currentPage?.htmlContentAdjustmentReason, .renderingDisabled)
        await waitForLoad(model)
        XCTAssertEqual(model.currentPage?.htmlContentAdjustmentReason, .unsafeContentBlocked)
    }

    func testRefreshCurrentUpdatesPageWithoutInvalidatingHistory() async {
        let root = URL(fileURLWithPath: "/wiki")
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        let third = root.appendingPathComponent("third.md")
        let revision = LockedValue("initial")
        let model = WikiNavigationModel { url, root, _ in
            var page = Self.page(url: url, root: root)
            page = WikiPage(
                url: page.url,
                html: "\(url.lastPathComponent)-\(revision.get())",
                resources: page.resources,
                containsWikiLinks: page.containsWikiLinks,
                displayPath: page.displayPath,
                estimatedByteCount: page.estimatedByteCount
            )
            return .success(page)
        }

        model.navigate(to: first, wikiRoot: root)
        await waitForLoad(model)
        model.navigate(to: second, wikiRoot: root)
        await waitForLoad(model)
        model.navigate(to: third, wikiRoot: root)
        await waitForLoad(model)
        model.goBack()
        let historyCount = model.historyEntryCount
        revision.set("updated")

        model.refreshCurrent(renderingPreferences: .secureDefaults)
        await waitForLoad(model)

        XCTAssertEqual(model.currentPage?.url, second)
        XCTAssertEqual(model.currentPage?.html, "second.md-updated")
        XCTAssertEqual(model.historyEntryCount, historyCount)
        XCTAssertTrue(model.canGoBack)
        XCTAssertTrue(model.canGoForward)
    }

    func testFileRefreshReusesCachedPageUntilSourceChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-cache-\(UUID().uuidString)", isDirectory: true)
        let pageURL = root.appendingPathComponent("page.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Initial".write(to: pageURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = WikiNavigationModel()
        model.navigate(to: pageURL, wikiRoot: root)
        await waitForLoad(model)
        let initialID = model.currentPage?.id
        var contentChanged: Bool?

        model.refreshCurrent(renderingPreferences: .secureDefaults) { _, changed in
            contentChanged = changed
        }
        XCTAssertFalse(model.isForegroundLoading)
        await waitForLoad(model)

        XCTAssertEqual(model.currentPage?.id, initialID)
        XCTAssertEqual(contentChanged, false)

        try "# Updated".write(to: pageURL, atomically: true, encoding: .utf8)
        model.refreshCurrent(renderingPreferences: .secureDefaults) { _, changed in
            contentChanged = changed
        }
        await waitForLoad(model)

        XCTAssertNotEqual(model.currentPage?.id, initialID)
        XCTAssertEqual(contentChanged, true)
        XCTAssertTrue(model.currentPage?.html.contains("Updated") == true)
    }

    func testSlowRefreshRestoresLatestUserScrollPosition() async {
        let root = URL(fileURLWithPath: "/wiki")
        let pageURL = root.appendingPathComponent("page.md")
        let refreshStarted = LockedValue(false)
        let shouldDelay = LockedValue(false)
        let model = WikiNavigationModel { url, root, _ in
            if shouldDelay.get() {
                refreshStarted.set(true)
                Thread.sleep(forTimeInterval: 0.05)
            }
            return .success(Self.page(url: url, root: root))
        }

        model.navigate(to: pageURL, wikiRoot: root)
        await waitForLoad(model)

        let positionAtStart = Self.scrollPosition(line: 12, progress: 0.2)
        let positionAfterUserScroll = Self.scrollPosition(line: 44, progress: 0.7)
        let restoration = WikiRefreshScrollRestoration.live
        let currentPosition = LockedValue(positionAtStart)
        let restoredPosition = LockedValue<DocumentScrollPosition?>(nil)
        shouldDelay.set(true)

        model.refreshCurrent(renderingPreferences: .secureDefaults) { _, changed in
            guard changed else { return }
            restoredPosition.set(restoration.resolvedPosition(
                currentPosition: currentPosition.get(),
                confirmedRequest: 0
            ))
        }
        await waitUntil { refreshStarted.get() }
        currentPosition.set(positionAfterUserScroll)
        await waitForLoad(model)

        XCTAssertEqual(restoredPosition.get(), positionAfterUserScroll)
    }

    func testHistoryRefreshKeepsRequestedPositionUntilWebViewConfirmsIt() async {
        let root = URL(fileURLWithPath: "/wiki")
        let pageURL = root.appendingPathComponent("page.md")
        let refreshStarted = LockedValue(false)
        let shouldDelay = LockedValue(false)
        let model = WikiNavigationModel { url, root, _ in
            if shouldDelay.get() {
                refreshStarted.set(true)
                Thread.sleep(forTimeInterval: 0.05)
            }
            return .success(Self.page(url: url, root: root))
        }

        model.navigate(to: pageURL, wikiRoot: root)
        await waitForLoad(model)

        let historyPosition = Self.scrollPosition(line: 18, progress: 0.25)
        let leavingPagePosition = Self.scrollPosition(line: 80, progress: 0.9)
        let restoration = WikiRefreshScrollRestoration.requested(
            position: historyPosition,
            request: 7
        )
        let restoredPosition = LockedValue<DocumentScrollPosition?>(nil)
        shouldDelay.set(true)

        model.refreshCurrent(renderingPreferences: .secureDefaults) { _, changed in
            guard changed else { return }
            restoredPosition.set(restoration.resolvedPosition(
                currentPosition: leavingPagePosition,
                confirmedRequest: 6
            ))
        }
        await waitUntil { refreshStarted.get() }
        await waitForLoad(model)

        XCTAssertEqual(restoredPosition.get(), historyPosition)
    }

    func testRefreshFailureKeepsCurrentPageAndSuccessfulRetryClearsError() async {
        let root = URL(fileURLWithPath: "/wiki")
        let pageURL = root.appendingPathComponent("page.md")
        let state = LockedValue(RefreshState(
            failureDescription: nil,
            revision: "initial"
        ))
        let model = WikiNavigationModel { url, root, _ in
            let state = state.get()
            if let failureDescription = state.failureDescription {
                return .failure(failureDescription)
            }
            var page = Self.page(url: url, root: root)
            page = WikiPage(
                url: page.url,
                html: state.revision,
                resources: page.resources,
                containsWikiLinks: page.containsWikiLinks,
                displayPath: page.displayPath,
                estimatedByteCount: page.estimatedByteCount
            )
            return .success(page)
        }

        model.navigate(to: pageURL, wikiRoot: root)
        await waitForLoad(model)
        let originalPage = try? XCTUnwrap(model.currentPage)
        state.set(RefreshState(
            failureDescription: "Temporarily unavailable",
            revision: "initial"
        ))

        model.refreshCurrent(renderingPreferences: .secureDefaults)
        await waitForLoad(model)

        XCTAssertEqual(model.currentPage, originalPage)
        XCTAssertEqual(model.errorDescription, "Temporarily unavailable")

        state.set(RefreshState(
            failureDescription: nil,
            revision: "recovered"
        ))
        model.refreshCurrent(renderingPreferences: .secureDefaults)
        await waitForLoad(model)

        XCTAssertEqual(model.currentPage?.html, "recovered")
        XCTAssertNil(model.errorDescription)
    }

    func testStaleRefreshDoesNotReplaceNewNavigation() async {
        let root = URL(fileURLWithPath: "/wiki")
        let slow = root.appendingPathComponent("slow.md")
        let fast = root.appendingPathComponent("fast.md")
        let model = WikiNavigationModel { url, root, _ in
            if url == slow {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return .success(Self.page(url: url, root: root))
        }

        model.navigate(to: slow, wikiRoot: root)
        await waitForLoad(model)
        model.refreshCurrent(renderingPreferences: .secureDefaults)
        model.navigate(to: fast, wikiRoot: root)
        await waitForLoad(model)
        try? await Task.sleep(for: .milliseconds(75))

        XCTAssertEqual(model.currentPage?.url, fast)
    }

    func testRefreshDoesNotCancelNewerNavigation() async {
        let root = URL(fileURLWithPath: "/wiki")
        let first = root.appendingPathComponent("first.md")
        let slowDestination = root.appendingPathComponent("slow-destination.md")
        let model = WikiNavigationModel { url, root, _ in
            if url == slowDestination {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return .success(Self.page(url: url, root: root))
        }

        model.navigate(to: first, wikiRoot: root)
        await waitForLoad(model)

        model.navigate(to: slowDestination, wikiRoot: root)
        model.refreshCurrent(renderingPreferences: .secureDefaults)
        await waitForLoad(model)

        XCTAssertEqual(model.currentPage?.url, slowDestination)
        XCTAssertEqual(model.historyEntryCount, 2)
        XCTAssertTrue(model.canGoBack)
        XCTAssertNil(model.errorDescription)
    }

    func testRefreshQueuedDuringRefreshLoadsNewestRevision() async {
        let root = URL(fileURLWithPath: "/wiki")
        let pageURL = root.appendingPathComponent("page.md")
        let revision = LockedValue("initial")
        let firstRefreshStarted = LockedValue(false)
        let model = WikiNavigationModel { url, root, _ in
            let loadedRevision = revision.get()
            if loadedRevision == "first" {
                firstRefreshStarted.set(true)
                Thread.sleep(forTimeInterval: 0.05)
            }
            var page = Self.page(url: url, root: root)
            page = WikiPage(
                url: page.url,
                html: loadedRevision,
                resources: page.resources,
                containsWikiLinks: page.containsWikiLinks,
                displayPath: page.displayPath,
                estimatedByteCount: page.estimatedByteCount
            )
            return .success(page)
        }

        model.navigate(to: pageURL, wikiRoot: root)
        await waitForLoad(model)

        revision.set("first")
        model.refreshCurrent(renderingPreferences: .secureDefaults)
        await waitUntil { firstRefreshStarted.get() }
        revision.set("second")
        model.refreshCurrent(renderingPreferences: .secureDefaults)
        await waitForLoad(model)

        XCTAssertEqual(model.currentPage?.html, "second")
        XCTAssertEqual(model.historyEntryCount, 1)
        XCTAssertNil(model.errorDescription)
    }

    func testLeavingFailedPageClearsRefreshError() async {
        let root = URL(fileURLWithPath: "/wiki")
        let pageURL = root.appendingPathComponent("page.md")
        let shouldFail = LockedValue(false)
        let model = WikiNavigationModel { url, root, _ in
            if shouldFail.get() {
                return .failure("Missing page")
            }
            return .success(Self.page(url: url, root: root))
        }

        model.navigate(to: pageURL, wikiRoot: root)
        await waitForLoad(model)
        shouldFail.set(true)
        model.refreshCurrent(renderingPreferences: .secureDefaults)
        await waitForLoad(model)
        XCTAssertEqual(model.errorDescription, "Missing page")

        model.goBack()

        XCTAssertNil(model.currentPage)
        XCTAssertNil(model.errorDescription)
    }

    private func makeModel(pageSize: Int = 128) -> WikiNavigationModel {
        WikiNavigationModel { url, root, _ in
            .success(Self.page(url: url, root: root, pageSize: pageSize))
        }
    }

    nonisolated private static func page(url: URL, root: URL, pageSize: Int = 128) -> WikiPage {
        WikiPage(
            url: url,
            html: String(repeating: "x", count: pageSize),
            resources: [],
            containsWikiLinks: true,
            displayPath: url.path.replacingOccurrences(of: root.path + "/", with: ""),
            estimatedByteCount: pageSize
        )
    }

    private static func scrollPosition(
        line: Int,
        progress: Double
    ) -> DocumentScrollPosition {
        DocumentScrollPosition(
            sourceLine: line,
            progress: progress,
            anchorIdentity: "section-\(line)",
            anchorOccurrence: 0,
            viewportOffset: 24
        )
    }

    private func waitForLoad(_ model: WikiNavigationModel) async {
        for _ in 0..<100 where model.isLoading {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.isLoading)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where condition() == false {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition())
    }
}

private struct RefreshState: Sendable {
    let failureDescription: String?
    let revision: String
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}
