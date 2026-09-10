import WebKit
import XCTest
@testable import MarkLens

final class MarkdownWebViewSecurityTests: XCTestCase {
    func testUsesEphemeralStorageAndDisablesScriptWindows() {
        let configuration = MarkdownWebView.makeSecureConfiguration()

        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    @MainActor
    func testStaleContentLoadCannotConsumePendingScrollRestoration() throws {
        let parent = MarkdownWebView(
            html: "<p>Current</p>",
            scrollTarget: .top,
            scrollRequest: 1
        )
        let coordinator = parent.makeCoordinator()
        let webView = WKWebView(
            frame: .zero,
            configuration: MarkdownWebView.makeSecureConfiguration()
        )
        coordinator.webView = webView
        let staleNavigation = try XCTUnwrap(webView.loadHTMLString("<p>Stale</p>", baseURL: nil))
        coordinator.activeContentNavigation = webView.loadHTMLString(
            "<p>Current</p>",
            baseURL: nil
        )

        coordinator.webView(webView, didFinish: staleNavigation)

        XCTAssertFalse(coordinator.isPageReady)
        XCTAssertEqual(coordinator.latestScrollRequest, 0)
        webView.stopLoading()
    }

    @MainActor
    func testFinishedCachedLoadImmediatelyStartsQueuedContentLoad() throws {
        let currentParent = MarkdownWebView(html: "<p>Current</p>", contentIdentity: "current")
        let coordinator = currentParent.makeCoordinator()
        let webView = WKWebView(
            frame: .zero,
            configuration: MarkdownWebView.makeSecureConfiguration()
        )
        coordinator.webView = webView
        coordinator.latestContentVersion = MarkdownWebView.ContentVersion(
            identity: "cached",
            documentURL: nil,
            reloadRequest: 0
        )
        let cachedNavigation = try XCTUnwrap(
            webView.loadHTMLString("<p>Cached</p>", baseURL: nil)
        )
        coordinator.activeContentNavigation = cachedNavigation

        coordinator.webView(webView, didFinish: cachedNavigation)

        XCTAssertFalse(coordinator.isPageReady)
        XCTAssertEqual(coordinator.latestContentVersion?.identity, "current")
        XCTAssertFalse(coordinator.activeContentNavigation === cachedNavigation)
        webView.stopLoading()
    }

    @MainActor
    func testAppliedScrollRequestIsPendingAgainForNewContentVersion() {
        let parent = MarkdownWebView(
            html: "<p>Current</p>",
            contentIdentity: "current",
            scrollTarget: .top,
            scrollRequest: 4
        )
        let coordinator = parent.makeCoordinator()
        coordinator.latestScrollRequest = 4
        coordinator.latestScrollContentVersion = MarkdownWebView.ContentVersion(
            identity: "cached",
            documentURL: nil,
            reloadRequest: 0
        )

        XCTAssertTrue(coordinator.needsScrollRestoration)
    }
}
