import JavaScriptCore
import XCTest
@testable import MarkLens

final class ScrollPositionScriptTests: XCTestCase {
    func testAnchorIdentityRemainsStableWhenRenderedContentMutates() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "DIV", text: "flowchart LR A --> B", line: 20, top: 0)
        ])
        let initialPosition = try lastReportedPosition(in: context)

        context.evaluateScript("mockAnchors[0].textContent = 'rendered SVG labels';")
        context.evaluateScript("window.MarkLensScroll.report();")
        let mutatedPosition = try lastReportedPosition(in: context)

        XCTAssertEqual(mutatedPosition["anchor"] as? String, initialPosition["anchor"] as? String)

        let reloadedContext = try makeContext(anchors: [
            anchor(tag: "DIV", text: "flowchart LR A --> B", line: 55, top: 0)
        ])
        let resolved = try resolve(mutatedPosition, in: reloadedContext)
        XCTAssertEqual((resolved["line"] as? NSNumber)?.intValue, 55)
    }

    func testDuplicateAnchorUsesOccurrenceAndNeighborContextAfterInsertion() throws {
        let original = try makeContext(anchors: [
            anchor(tag: "P", text: "First context", line: 9),
            anchor(tag: "H2", text: "Repeated heading", line: 10),
            anchor(tag: "P", text: "After first", line: 11),
            anchor(tag: "P", text: "Second context", line: 99),
            anchor(tag: "H2", text: "Repeated heading", line: 100, top: 0),
            anchor(tag: "P", text: "After second", line: 101)
        ])
        let position = try lastReportedPosition(in: original)

        var updatedAnchors = [
            anchor(tag: "P", text: "First context", line: 9),
            anchor(tag: "H2", text: "Repeated heading", line: 10),
            anchor(tag: "P", text: "After first", line: 11)
        ]
        updatedAnchors.append(contentsOf: (12...98).map { line in
            anchor(tag: "P", text: "Inserted block \(line)", line: line)
        })
        updatedAnchors.append(contentsOf: [
            anchor(tag: "P", text: "Second context", line: 199),
            anchor(tag: "H2", text: "Repeated heading", line: 200),
            anchor(tag: "P", text: "After second", line: 201)
        ])

        let reloaded = try makeContext(anchors: updatedAnchors)
        let resolved = try resolve(position, in: reloaded)
        XCTAssertEqual((resolved["line"] as? NSNumber)?.intValue, 200)
        XCTAssertEqual((resolved["occurrence"] as? NSNumber)?.intValue, 1)
    }

    func testAnchorCrossingViewportTopWinsOverCloserAnchorBelow() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "DIV", text: "Frontmatter", line: 1, top: -50, height: 100),
            anchor(tag: "H1", text: "Body", line: 20, top: 10)
        ])

        let position = try lastReportedPosition(in: context)
        XCTAssertEqual((position["line"] as? NSNumber)?.intValue, 1)
    }

    func testSelectionStartLineUsesNearestSourceAncestor() throws {
        let context = try makeContext(anchors: [])
        context.evaluateScript("""
        var selectedSource = {
            nodeType: 1,
            dataset: { marklensSourceLine: '7' },
            parentElement: null
        };
        var selectedText = { nodeType: 3, parentElement: selectedSource };
        window.getSelection = () => ({
            rangeCount: 1,
            isCollapsed: false,
            getRangeAt() { return { startContainer: selectedText }; }
        });
        """)

        let value = context.evaluateScript("window.MarkLensScroll.selectionStartLine();")
        XCTAssertNil(context.exception)
        XCTAssertEqual(value?.toInt32(), 7)
    }

    func testSelectionStartLineReturnsNullWithoutSelection() throws {
        let context = try makeContext(anchors: [])
        context.evaluateScript("window.getSelection = () => ({ rangeCount: 0, isCollapsed: true });")
        let value = context.evaluateScript("window.MarkLensScroll.selectionStartLine();")
        XCTAssertNil(context.exception)
        XCTAssertTrue(value?.isNull == true)
    }

    func testSelectionStartLineCountsNewlinesWithinMappedElement() throws {
        let context = try makeContext(anchors: [])
        context.evaluateScript("""
        var selectedSource = {
            nodeType: 1,
            dataset: { marklensSourceLine: '7', marklensSourceEndLine: '10' },
            parentElement: null
        };
        var selectedText = { nodeType: 3, parentElement: selectedSource };
        document.createRange = () => ({
            setStart() {},
            setEnd() {},
            toString() { return 'first\\nsecond\\n'; }
        });
        window.getSelection = () => ({
            rangeCount: 1,
            isCollapsed: false,
            getRangeAt() { return { startContainer: selectedText, startOffset: 4 }; }
        });
        """)

        let value = context.evaluateScript("window.MarkLensScroll.selectionStartLine();")
        XCTAssertNil(context.exception)
        XCTAssertEqual(value?.toInt32(), 9)
    }

    func testSelectionStartLineUsesSeparateTextStartForFencedCode() throws {
        let context = try makeContext(anchors: [])
        context.evaluateScript("""
        var selectedSource = {
            nodeType: 1,
            dataset: {
                marklensSourceLine: '20',
                marklensSelectionLine: '21',
                marklensSourceEndLine: '24'
            },
            parentElement: null
        };
        var selectedText = { nodeType: 3, parentElement: selectedSource };
        document.createRange = () => ({
            setStart() {},
            setEnd() {},
            toString() { return 'first line\\n'; }
        });
        window.getSelection = () => ({
            rangeCount: 1,
            isCollapsed: false,
            getRangeAt() { return { startContainer: selectedText, startOffset: 3 }; }
        });
        """)

        let value = context.evaluateScript("window.MarkLensScroll.selectionStartLine();")
        XCTAssertNil(context.exception)
        XCTAssertEqual(value?.toInt32(), 22)
    }

    func testSelectionStartLineCountsRenderedHardBreaks() throws {
        let context = try makeContext(anchors: [])
        context.evaluateScript("""
        var selectedSource = {
            nodeType: 1,
            dataset: { marklensSourceLine: '30', marklensSourceEndLine: '31' },
            parentElement: null
        };
        var selectedText = { nodeType: 3, parentElement: selectedSource };
        document.createRange = () => ({
            setStart() {},
            setEnd() {},
            toString() { return 'before break'; },
            cloneContents() {
                return { querySelectorAll(selector) { return selector === 'br' ? [1] : []; } };
            }
        });
        window.getSelection = () => ({
            rangeCount: 1,
            isCollapsed: false,
            getRangeAt() { return { startContainer: selectedText, startOffset: 2 }; }
        });
        """)

        let value = context.evaluateScript("window.MarkLensScroll.selectionStartLine();")
        XCTAssertNil(context.exception)
        XCTAssertEqual(value?.toInt32(), 31)
    }

    private func anchor(
        tag: String,
        text: String,
        line: Int,
        top: Int = 1_000,
        height: Int = 20
    ) -> [String: Any] {
        ["tag": tag, "text": text, "line": line, "top": top, "height": height]
    }

    private func makeContext(anchors: [[String: Any]]) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        let data = try JSONSerialization.data(withJSONObject: anchors)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        context.evaluateScript("""
        var anchorSpecs = \(json);
        var postedMessages = [];
        var scrollY = 0;
        var innerHeight = 100;
        var mockAnchors = anchorSpecs.map(spec => ({
            tagName: spec.tag,
            textContent: spec.text,
            dataset: { marklensSourceLine: String(spec.line) },
            top: spec.top,
            parentElement: null,
            getBoundingClientRect() {
                return { top: this.top, bottom: this.top + spec.height };
            }
        }));
        var document = {
            documentElement: { scrollHeight: 2_000 },
            querySelectorAll() { return mockAnchors; }
        };
        var window = globalThis;
        window.webkit = {
            messageHandlers: {
                marklensScrollPosition: {
                    postMessage(message) { postedMessages.push(message); }
                }
            }
        };
        var IntersectionObserver = class {
            constructor(callback) { this.callback = callback; }
            observe(target) { this.callback([{ target, isIntersecting: true }]); }
        };
        var ResizeObserver = class {
            constructor(callback) { this.callback = callback; }
            observe() {}
        };
        function requestAnimationFrame(callback) { callback(); }
        function addEventListener() {}
        function setTimeout(callback, delay) {
            if (delay <= 100) callback();
            return 1;
        }
        function clearTimeout() {}
        function scrollTo(_x, y) { scrollY = y; }
        """)
        context.evaluateScript(MarkdownWebView.scrollPositionScript)
        XCTAssertNil(context.exception)
        return context
    }

    private func lastReportedPosition(in context: JSContext) throws -> [String: Any] {
        let messages = try XCTUnwrap(
            context.objectForKeyedSubscript("postedMessages")?.toArray() as? [[String: Any]]
        )
        return try XCTUnwrap(messages.last)
    }

    private func resolve(
        _ position: [String: Any],
        in context: JSContext
    ) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: position)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let value = context.evaluateScript("window.MarkLensScroll.resolve(\(json));")
        XCTAssertNil(context.exception)
        return try XCTUnwrap(value?.toDictionary() as? [String: Any])
    }
}
