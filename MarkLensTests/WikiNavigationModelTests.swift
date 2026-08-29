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

    private func waitForLoad(_ model: WikiNavigationModel) async {
        for _ in 0..<100 where model.isLoading {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.isLoading)
    }
}
