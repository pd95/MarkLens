import XCTest
@testable import MarkLens

#if os(macOS)
import AppKit
import WebKit

final class LocalLinkDestinationTests: XCTestCase {
    func testResolvesRelativeImageAndRemovesQueryAndFragment() throws {
        let base = URL(fileURLWithPath: "/wiki/pages/source.md")
        let link = try XCTUnwrap(URL(string: "../images/My%20Photo.PNG?download=1#detail", relativeTo: base))
        XCTAssertEqual(
            LocalLinkDestination(url: link),
            .file(URL(fileURLWithPath: "/wiki/images/My Photo.PNG"))
        )
    }

    func testClassifiesMarkdownImagesAndOtherFiles() throws {
        for ext in ["md", "MARKDOWN", "mdown", "mkd", "mkdn"] {
            let url = URL(fileURLWithPath: "/wiki/file.\(ext)")
            XCTAssertEqual(LocalLinkDestination(url: url), .markdown(url))
        }
        for ext in ["jpg", "JPEG", "png", "gif", "webp"] {
            let url = URL(fileURLWithPath: "/wiki/file.\(ext)")
            XCTAssertEqual(LocalLinkDestination(url: url), .file(url))
        }
        for path in ["/wiki/report.pdf", "/wiki/folder/", "/wiki/image.svg", "/wiki/folder.png/"] {
            let url = URL(fileURLWithPath: path)
            XCTAssertEqual(LocalLinkDestination(url: url), .file(url.standardizedFileURL))
        }
        let lineURL = try XCTUnwrap(URL(string: "file:///wiki/notes.md#marklens-line=12"))
        XCTAssertEqual(LocalLinkDestination(url: lineURL), .markdown(URL(fileURLWithPath: "/wiki/notes.md")))
    }

    func testRejectsRemoteAndMalformedWikiDestinations() throws {
        for raw in ["https://example.com/photo.png", "file://server/share/photo.png", "javascript:alert(1)",
                    "marklens-wikilink://other?target=Notes", "marklens-wikilink://open?target="] {
            XCTAssertNil(LocalLinkDestination(url: try XCTUnwrap(URL(string: raw))))
        }
        XCTAssertEqual(
            LocalLinkDestination(url: try XCTUnwrap(URL(string: "marklens-wikilink://open?target=Notes%23Heading"))),
            .wiki("Notes#Heading")
        )
    }

    func testRevealPreservesSymlinkRatherThanSelectingItsTarget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target.png")
        try Data().write(to: target)
        let link = folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(LocalLinkDestination(url: link)?.fileURL, link)
    }

    @MainActor
    func testMenusOfferOnlyActionsSupportedByEachDestination() throws {
        let coordinator = MarkdownWebView(html: "").makeCoordinator()
        for (path, titles) in [
            ("notes.md", ["Open", "Open in New Tab", "Quick Look", "Reveal in Finder", "Copy Link Address"]),
            ("photo.png", ["Quick Look", "Reveal in Finder", "Copy Link Address"]),
            ("report.pdf", ["Quick Look", "Reveal in Finder", "Copy Link Address"]),
            ("folder/", ["Quick Look", "Reveal in Finder", "Copy Link Address"])
        ] {
            let menu = try XCTUnwrap(coordinator.makeLinkContextMenu(for: URL(fileURLWithPath: "/wiki/" + path)))
            XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), titles)
        }
    }

    @MainActor
    func testRevealAndPreviewDispatchTheCorrectNormalizedURL() throws {
        var previewed: URL?
        var revealed: URL?
        let coordinator = MarkdownWebView(html: "", previewFile: { previewed = $0 }).makeCoordinator()
        coordinator.revealFile = { revealed = $0 }
        let link = try XCTUnwrap(URL(string: "file:///wiki/photo.png?download=1#detail"))
        let menu = try XCTUnwrap(coordinator.makeLinkContextMenu(for: link))
        let reveal = try XCTUnwrap(menu.item(withTitle: "Reveal in Finder"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(reveal.action), to: reveal.target, from: reveal))
        XCTAssertEqual(revealed, URL(fileURLWithPath: "/wiki/photo.png"))
        XCTAssertNil(previewed)
        let preview = try XCTUnwrap(menu.item(withTitle: "Quick Look"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(preview.action), to: preview.target, from: preview))
        XCTAssertEqual(previewed, revealed)
        XCTAssertFalse(coordinator.revealNonMarkdownLink(URL(string: "https://example.com/photo.png")!))
    }

    @MainActor
    func testNonMarkdownClicksRevealFilesAndFoldersInsteadOfPreviewing() {
        var revealed: [URL] = []
        var previewed = false
        let coordinator = MarkdownWebView(html: "", previewFile: { _ in previewed = true }).makeCoordinator()
        coordinator.revealFile = { revealed.append($0) }
        for path in ["/wiki/settings.json", "/wiki/files/", "/wiki/photo.png", "/wiki/report.pdf"] {
            let url = URL(fileURLWithPath: path)
            XCTAssertTrue(coordinator.revealNonMarkdownLink(url))
            XCTAssertEqual(revealed.last, url.standardizedFileURL)
        }
        XCTAssertFalse(coordinator.revealNonMarkdownLink(URL(fileURLWithPath: "/wiki/notes.md")))
        XCTAssertFalse(previewed)
        XCTAssertEqual(revealed.count, 4)
    }

    @MainActor
    func testWebViewClicksRevealJSONFoldersAndImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let targets = ["settings.json", "files/", "photo.png"].map { directory.appendingPathComponent($0) }
        try Data("Source".utf8).write(to: source)
        try Data("{}".utf8).write(to: targets[0])
        try FileManager.default.createDirectory(at: targets[1], withIntermediateDirectories: true)
        try Data().write(to: targets[2])
        let loaded = expectation(description: "The Markdown preview loaded")
        let revealed = expectation(description: "All three links reveal in Finder")
        revealed.expectedFulfillmentCount = 3
        var destinations: [URL] = []
        let coordinator = MarkdownWebView(
            html: "",
            openDocument: { _, _, _ in XCTFail("A non-Markdown link must not open as Markdown.") },
            previewFile: { _ in XCTFail("Quick Look is an explicit context action.") }
        ).makeCoordinator()
        coordinator.revealFile = {
            destinations.append($0)
            revealed.fulfill()
        }
        let observer = LinkNavigationObserver(coordinator: coordinator, loaded: loaded)
        let webView = WKWebView(frame: .zero, configuration: MarkdownWebView.makeSecureConfiguration())
        webView.navigationDelegate = observer
        coordinator.webView = webView
        coordinator.authorizeInternalLoad()
        webView.loadHTMLString("""
            <a id="json" href="settings.json">JSON</a>
            <a id="folder" href="files/">Folder</a>
            <a id="image" href="photo.png">Image</a>
            """, baseURL: source)
        defer {
            webView.stopLoading()
            withExtendedLifetime(observer) {}
        }
        await fulfillment(of: [loaded], timeout: 5)
        for id in ["json", "folder", "image"] {
            _ = try await webView.evaluateJavaScript("document.getElementById('\(id)').click()")
        }
        await fulfillment(of: [revealed], timeout: 5)
        XCTAssertEqual(destinations.map(\.path), targets.map(\.path), observer.actions.description)
    }

    @MainActor
    func testWebViewClicksRevealFilesOutsidePreviewReadAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = directory.appendingPathComponent("preview", isDirectory: true)
        let targetDirectory = directory.appendingPathComponent("targets", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = sourceDirectory.appendingPathComponent("preview.html")
        let targets = ["Settings File.json", "Notes.txt", "100%.txt"].map { targetDirectory.appendingPathComponent($0) }
        for target in targets { try Data("Target".utf8).write(to: target) }
        let html = """
            <a id="json" href="../targets/Settings%20File.json"><span>JSON</span></a>
            <a id="text" href="\(targets[1].absoluteString)">Text</a>
            <a id="percent" href="../targets/100%.txt">Percent</a>
            """
        try html.write(to: source, atomically: true, encoding: .utf8)
        let loaded = expectation(description: "The preview loaded with access only to its own directory")
        let revealed = expectation(description: "All links reach Finder without WebKit reading their targets")
        revealed.expectedFulfillmentCount = targets.count
        var destinations: [URL] = []
        let coordinator = MarkdownWebView(html: "").makeCoordinator()
        coordinator.revealFile = {
            destinations.append($0)
            revealed.fulfill()
        }
        let observer = LinkNavigationObserver(coordinator: coordinator, loaded: loaded)
        let configuration = MarkdownWebView.makeSecureConfiguration()
        MarkdownWebView.installLocalFileClickHandling(in: configuration, coordinator: coordinator)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = observer
        coordinator.webView = webView
        coordinator.authorizeInternalLoad()
        webView.loadFileURL(source, allowingReadAccessTo: sourceDirectory)
        defer {
            configuration.userContentController.removeAllScriptMessageHandlers()
            webView.stopLoading()
            withExtendedLifetime(observer) {}
        }
        await fulfillment(of: [loaded], timeout: 5)
        for selector in ["#json span", "#text", "#percent"] {
            _ = try await webView.evaluateJavaScript("document.querySelector('\(selector)').click()")
        }
        await fulfillment(of: [revealed], timeout: 5)
        XCTAssertEqual(destinations.map(\.path), targets.map(\.path), observer.actions.description)
        XCTAssertEqual(observer.actions.count, 1, "File clicks must be handled before WebKit attempts navigation.")
    }

    @MainActor
    func testClickBridgePreservesMarkdownExternalAndContextClickBehavior() async throws {
        let loaded = expectation(description: "The preview loaded")
        let coordinator = MarkdownWebView(html: "").makeCoordinator()
        coordinator.revealFile = { _ in XCTFail("These actions must not reveal a file.") }
        let configuration = MarkdownWebView.makeSecureConfiguration()
        MarkdownWebView.installLocalFileClickHandling(in: configuration, coordinator: coordinator)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let observer = LinkNavigationObserver(coordinator: coordinator, loaded: loaded)
        webView.navigationDelegate = observer
        coordinator.webView = webView
        coordinator.authorizeInternalLoad()
        webView.loadHTMLString("<p>Preview</p>", baseURL: nil)
        defer {
            configuration.userContentController.removeAllScriptMessageHandlers()
            webView.stopLoading()
            withExtendedLifetime(observer) {}
        }
        await fulfillment(of: [loaded], timeout: 5)
        let intercepted = try await webView.evaluateJavaScript("""
            (() => {
                let intercepted;
                // Cancel the remaining default action after the production
                // capture listener so this test cannot open a browser or menu.
                document.addEventListener('click', event => {
                    intercepted = event.defaultPrevented;
                    event.preventDefault();
                });
                const cases = [
                    ['file:///wiki/Notes.md', {}],
                    ['file:///wiki/Notes.MARKDOWN?data=json#heading', { metaKey: true }],
                    ['file:///wiki/Notes.mdown', {}],
                    ['file:///wiki/Notes.mkd', {}],
                    ['file:///wiki/Notes.mkdn', {}],
                    ['marklens-wikilink://open?target=Notes', {}],
                    ['https://example.com/settings.json', {}],
                    ['file://server/share/settings.json', {}],
                    ['file:///wiki/settings.json', { ctrlKey: true }],
                    ['file:///wiki/settings.json', { button: 1 }],
                    ['file:///wiki/settings.json', { button: 2 }]
                ];
                return cases.map(([href, options]) => {
                    const link = document.createElement('a');
                    link.href = href;
                    document.body.appendChild(link);
                    link.dispatchEvent(new MouseEvent('click', {
                        bubbles: true, cancelable: true, ...options
                    }));
                    link.remove();
                    return intercepted;
                });
            })();
            """) as? [Bool]
        XCTAssertEqual(intercepted, Array(repeating: false, count: 11))
    }

    @MainActor
    func testMarkdownAndWikiQuickLookDoNotOpenDocuments() throws {
        var previewed: URL?
        var previewedWiki: String?
        var opened = false
        let coordinator = MarkdownWebView(
            html: "",
            openDocument: { _, _, _ in opened = true },
            openWikiLink: { _, _ in opened = true },
            previewFile: { previewed = $0 },
            previewWikiLink: { previewedWiki = $0 }
        ).makeCoordinator()
        let markdownURL = URL(fileURLWithPath: "/wiki/notes.md")
        let wikiURL = try XCTUnwrap(URL(string: "marklens-wikilink://open?target=Notes%23Heading"))
        for url in [markdownURL, wikiURL] {
            let menu = try XCTUnwrap(coordinator.makeLinkContextMenu(for: url))
            let item = try XCTUnwrap(menu.item(withTitle: "Quick Look"))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertEqual(previewed, markdownURL)
        XCTAssertEqual(previewedWiki, "Notes#Heading")
        XCTAssertFalse(opened)
    }

    @MainActor
    func testWikiRevealIsDispatchedSeparatelyFromOpening() throws {
        var revealed: String?
        var opened = false
        let coordinator = MarkdownWebView(
            html: "",
            openWikiLink: { _, _ in opened = true },
            revealWikiLink: { revealed = $0 }
        ).makeCoordinator()
        let url = try XCTUnwrap(URL(string: "marklens-wikilink://open?target=Notes%23Missing"))
        let menu = try XCTUnwrap(coordinator.makeLinkContextMenu(for: url))
        let item = try XCTUnwrap(menu.item(withTitle: "Reveal in Finder"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(revealed, "Notes#Missing")
        XCTAssertFalse(opened)
    }
}

@MainActor
private final class LinkNavigationObserver: NSObject, WKNavigationDelegate {
    let coordinator: MarkdownWebView.Coordinator
    let loaded: XCTestExpectation
    var actions: [String] = []

    init(coordinator: MarkdownWebView.Coordinator, loaded: XCTestExpectation) {
        self.coordinator = coordinator
        self.loaded = loaded
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        actions.append("\(navigationAction.navigationType.rawValue): \(navigationAction.request.url?.absoluteString ?? "nil")")
        coordinator.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
    }
}
#endif
