import JavaScriptCore
import XCTest
@testable import MarkLens

#if os(macOS)
import AppKit
import WebKit

final class LinkHoverTests: XCTestCase {
    func testMarkdownAnnotationReflectsNavigationAndCommandClick() throws {
        let document = URL(fileURLWithPath: "/wiki/source.md")
        let url = URL(fileURLWithPath: "/wiki/Notes.md")
        let hover = LinkHover(url: url)
        XCTAssertEqual(hover.annotation(documentURL: nil, navigatesInPlace: true), "Navigate to /wiki/Notes.md")
        XCTAssertEqual(hover.annotation(documentURL: nil, navigatesInPlace: false), "Open /wiki/Notes.md")
        XCTAssertEqual(hover.annotation(documentURL: document, navigatesInPlace: true), "Navigate to Notes.md")
        XCTAssertEqual(hover.annotation(documentURL: document, navigatesInPlace: false), "Open Notes.md")
        let commandHover = LinkHover(url: url, commandKey: true)
        XCTAssertEqual(commandHover.annotation(documentURL: document, navigatesInPlace: true), "Open in New Tab: Notes.md")
        let nested = LinkHover(url: try XCTUnwrap(URL(string: "file:///wiki/pages/My%20Notes.md?q=1#heading")))
        XCTAssertEqual(nested.annotation(documentURL: document, navigatesInPlace: true), "Navigate to pages/My Notes.md?q=1#heading")
        let wiki = LinkHover(url: try XCTUnwrap(URL(string: "marklens-wikilink://open?target=Notes%23Heading")))
        XCTAssertEqual(wiki.annotation(documentURL: nil, navigatesInPlace: true), "Navigate to wiki page Notes#Heading")
        XCTAssertEqual(wiki.annotation(documentURL: nil, navigatesInPlace: false), "Open wiki page Notes#Heading")
    }

    func testOtherLocalAnnotationsMatchTheConfiguredAndCommandActions() throws {
        let document = URL(fileURLWithPath: "/wiki/pages/source.md")
        for (path, relativePath) in [
            ("/wiki/settings.json", "../settings.json"),
            ("/wiki/files/", "../files"),
            ("/wiki/pages/image.png", "image.png"),
            ("/wiki/shared/report.txt", "../shared/report.txt"),
            ("/wiki/pages/artifacts/report.json", "artifacts/report.json"),
            ("/wiki/pages/", "."),
            ("/wiki/pages-extra/settings.json", "../pages-extra/settings.json")
        ] {
            let url = URL(fileURLWithPath: path)
            for clickAction in LinkedFileAction.allCases {
                for commandAction in LinkedFileAction.allCases {
                    let preference = LinkedFileOpenPreference(clickAction: clickAction, commandClickAction: commandAction)
                    for commandKey in [false, true] {
                        let hover = LinkHover(url: url, commandKey: commandKey)
                        let action = commandKey ? commandAction : clickAction
                        let prefix = action.title + ": "
                        XCTAssertEqual(hover.annotation(documentURL: nil, navigatesInPlace: true, fileOpenPreference: preference), prefix + url.path)
                        XCTAssertEqual(hover.annotation(documentURL: document, navigatesInPlace: true, fileOpenPreference: preference), prefix + relativePath)
                    }
                }
            }
        }
        let encoded = LinkHover(url: try XCTUnwrap(URL(string: "file:///wiki/My%20Notes.json?download=1#section")))
        XCTAssertEqual(encoded.annotation(documentURL: document, navigatesInPlace: false), "Reveal in Finder: ../My Notes.json")
    }

    func testSameDocumentAnchorsAndSourceLinesDescribeNavigation() throws {
        let document = URL(fileURLWithPath: "/wiki/Notes.md")
        let heading = LinkHover(url: try XCTUnwrap(URL(string: "file:///wiki/Notes.md#heading")), commandKey: true)
        XCTAssertEqual(heading.annotation(documentURL: document, navigatesInPlace: false), "Navigate to Notes.md#heading")
        let line = LinkHover(url: try XCTUnwrap(URL(string: "file:///wiki/Notes.md#marklens-line=12")))
        XCTAssertEqual(line.annotation(documentURL: document, navigatesInPlace: false), "Navigate to Notes.md:12")
    }

    func testRemoteLinksDescribeBrowserAndInvalidSchemesHaveNoAnnotation() throws {
        let remote = LinkHover(url: try XCTUnwrap(URL(string: "https://example.com/notes.md?q=hello%20world#part")))
        XCTAssertEqual(
            remote.annotation(documentURL: nil, navigatesInPlace: true),
            "Open in browser: https://example.com/notes.md?q=hello%20world#part"
        )
        for raw in ["javascript:alert(1)", "file://server/share/file", "marklens-wikilink://open?target="] {
            let hover = LinkHover(url: try XCTUnwrap(URL(string: raw)))
            XCTAssertNil(hover.annotation(documentURL: nil, navigatesInPlace: true))
        }
    }

    func testHoverScriptHandlesNestedLinkContentAndDeduplicatesMouseMoves() throws {
        let context = try makeContext()
        context.evaluateScript("emit('mouseover', child); emit('mousemove', child); emit('mouseout', child, first);")
        XCTAssertEqual(try messages(in: context).count, 1)
        XCTAssertEqual(try messages(in: context).last?["href"] as? String, "file:///wiki/Notes.md")
        context.evaluateScript("emit('mousemove', second);")
        XCTAssertEqual(try messages(in: context).last?["href"] as? String, "file:///wiki/settings.json")
        context.evaluateScript("emit('mouseout', second, null);")
        XCTAssertTrue(try messages(in: context).last?["href"] is NSNull)
        XCTAssertNil(context.exception)
    }

    func testHoverScriptUpdatesModifiersScrollingAndWindowExit() throws {
        let context = try makeContext()
        context.evaluateScript("emit('mouseover', first); emit('keydown', first, null, true);")
        XCTAssertEqual(try messages(in: context).last?["commandKey"] as? Bool, true)
        context.evaluateScript("emit('keyup', first);")
        XCTAssertEqual(try messages(in: context).last?["commandKey"] as? Bool, false)
        XCTAssertEqual(try messages(in: context).last?["href"] as? String, "file:///wiki/Notes.md")
        context.evaluateScript("hitElement = second; handlers.scroll({});")
        XCTAssertEqual(try messages(in: context).last?["href"] as? String, "file:///wiki/settings.json")
        context.evaluateScript("windowHandlers.blur({});")
        XCTAssertTrue(try messages(in: context).last?["href"] is NSNull)
        let countAfterExit = try messages(in: context).count
        context.evaluateScript("hitElement = first; handlers.scroll({});")
        XCTAssertEqual(try messages(in: context).count, countAfterExit)
        XCTAssertNil(context.exception)
    }

    @MainActor
    func testNativeHoverUsesCurrentModifiersWhenScrollingWithStaleDOMFlags() async throws {
        let loaded = expectation(description: "The hover page loaded")
        let first = expectation(description: "First link uses held Command")
        let second = expectation(description: "Scroll to another link still uses held Command")
        let released = expectation(description: "A later link uses the released modifier")
        var heldFlags: NSEvent.ModifierFlags = .command
        let coordinator = MarkdownWebView(html: "", linkHoverChanged: { hover in
            guard let hover else { return }
            switch hover.url.lastPathComponent {
            case "first.json":
                XCTAssertTrue(hover.commandKey)
                first.fulfill()
            case "second.json":
                XCTAssertTrue(hover.commandKey)
                second.fulfill()
            case "third.json":
                XCTAssertFalse(hover.commandKey)
                released.fulfill()
            default: XCTFail("Unexpected hover destination")
            }
        }).makeCoordinator()
        coordinator.currentModifierFlags = { heldFlags }
        let configuration = MarkdownWebView.makeSecureConfiguration()
        configuration.userContentController.add(coordinator, name: "marklensLinkHover")
        configuration.userContentController.addUserScript(WKUserScript(
            source: MarkdownWebView.linkHoverScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let observer = HoverLoadObserver(loaded: loaded)
        webView.navigationDelegate = observer
        coordinator.webView = webView
        webView.loadHTMLString("""
            <a id="first" href="file:///wiki/first.json">First</a>
            <a id="second" href="file:///wiki/second.json">Second</a>
            <a id="third" href="file:///wiki/third.json">Third</a>
            """, baseURL: nil)
        defer {
            configuration.userContentController.removeAllScriptMessageHandlers()
            webView.stopLoading()
            withExtendedLifetime(observer) {}
        }
        await fulfillment(of: [loaded], timeout: 5)
        coordinator.isPageReady = true
        _ = try await webView.evaluateJavaScript("""
            document.getElementById('first').dispatchEvent(new MouseEvent('mouseover', {
                bubbles: true, clientX: 10, clientY: 10, metaKey: false
            }))
            """)
        await fulfillment(of: [first], timeout: 3)
        _ = try await webView.evaluateJavaScript("""
            document.elementFromPoint = () => document.getElementById('second');
            document.dispatchEvent(new Event('scroll'));
            """)
        await fulfillment(of: [second], timeout: 3)
        heldFlags = []
        _ = try await webView.evaluateJavaScript("""
            document.elementFromPoint = () => document.getElementById('third');
            document.dispatchEvent(new Event('scroll'));
            """)
        await fulfillment(of: [released], timeout: 3)
    }

    @MainActor
    func testClearingHoverDiscardsQueuedUpdatesFromPreviousDocument() async {
        let reported = expectation(description: "The cleared hover is delivered")
        var values: [LinkHover?] = []
        let coordinator = MarkdownWebView(html: "", linkHoverChanged: {
            values.append($0)
            reported.fulfill()
        }).makeCoordinator()
        coordinator.updateLinkHover(LinkHover(url: URL(fileURLWithPath: "/wiki/old.md")))
        coordinator.updateLinkHover(nil)
        await fulfillment(of: [reported], timeout: 2)
        XCTAssertEqual(values.count, 1)
        XCTAssertNil(values.first.flatMap { $0 })
    }

    private func messages(in context: JSContext) throws -> [[String: Any]] {
        try XCTUnwrap(context.objectForKeyedSubscript("messages")?.toArray() as? [[String: Any]])
    }

    private func makeContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            var messages = [];
            var handlers = {};
            var windowHandlers = {};
            class Element {
                constructor(href, parent = null) { this.href = href; this.parent = parent; }
                closest() { return this.href ? this : this.parent ? this.parent.closest() : null; }
            }
            var first = new Element('file:///wiki/Notes.md');
            var child = new Element(null, first);
            var second = new Element('file:///wiki/settings.json');
            var hitElement = null;
            var document = {
                addEventListener: (name, callback) => { handlers[name] = callback; },
                elementFromPoint: () => hitElement
            };
            var window = {
                webkit: { messageHandlers: { marklensLinkHover: { postMessage: value => messages.push(value) } } },
                addEventListener: (name, callback) => { windowHandlers[name] = callback; }
            };
            function emit(name, target, relatedTarget = null, metaKey = false) {
                handlers[name]({ target, relatedTarget, metaKey, clientX: 10, clientY: 20 });
            }
            """)
        context.evaluateScript(MarkdownWebView.linkHoverScript)
        XCTAssertNil(context.exception)
        return context
    }
}

@MainActor
private final class HoverLoadObserver: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation

    init(loaded: XCTestExpectation) { self.loaded = loaded }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }
}
#endif
