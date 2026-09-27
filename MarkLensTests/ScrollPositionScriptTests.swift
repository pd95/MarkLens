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

    func testReportsActualPositionWithActiveRestorationRequest() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "H2", text: "Destination", line: 40, top: 600)
        ])

        context.evaluateScript("""
        window.MarkLensScroll.restore({
            request: 17,
            line: 40,
            progress: 0.3,
            anchor: null,
            occurrence: null,
            previousAnchor: null,
            nextAnchor: null,
            offset: 20
        });
        """)
        let position = try lastReportedPosition(in: context)

        XCTAssertEqual((position["restorationRequest"] as? NSNumber)?.intValue, 17)
        XCTAssertEqual((position["line"] as? NSNumber)?.intValue, 40)
        let progress = try XCTUnwrap((position["progress"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(progress, 0.305, accuracy: 0.001)
    }

    func testTopPositionUsesDocumentOriginInsteadOfFirstSourceAnchor() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "DETAILS", text: "Frontmatter", line: 1, top: 17)
        ])

        context.evaluateScript("""
        scrollY = 300;
        window.MarkLensScroll.restore({
            request: 18,
            line: null,
            progress: 0,
            anchor: null,
            occurrence: null,
            previousAnchor: null,
            nextAnchor: null,
            offset: 0
        });
        """)

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("scrollY")?.toInt32(), 0)
    }

    func testLineRequestUsesExactMarkerInsideMultilineContent() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "P", text: "First line", line: 10, top: 100),
            anchor(tag: "SPAN", text: "", line: 11, top: 150),
            anchor(tag: "P", text: "Following block", line: 14, top: 300)
        ])

        context.evaluateScript("window.MarkLensScroll.restore({ request: 1, line: 11, progress: 0, anchor: null, offset: 0 });")

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("scrollY")?.toInt32(), 150)
    }

    func testLineLinkBrieflyHighlightsExactInlineTarget() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "P", text: "First line", line: 10, top: 100),
            anchor(tag: "SPAN", text: "", line: 11, top: 150),
            anchor(tag: "P", text: "Following block", line: 14, top: 300)
        ])

        context.evaluateScript("window.MarkLensScroll.restore({ request: 1, line: 11, progress: 0, anchor: null, offset: 0, highlight: true });")

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("scrollY")?.toInt32(), 110)
        XCTAssertEqual(context.evaluateScript("document.body.children.length")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("document.body.children[0].style.top")?.toString(), "150px")
        XCTAssertEqual(context.evaluateScript("document.body.children[0].style.height")?.toString(), "24px")

        context.evaluateScript("pendingTimeouts.find(timer => timer.delay === 2200).callback();")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("document.body.children.length")?.toInt32(), 0)
    }

    func testOrdinaryScrollRestorationDoesNotHighlight() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "H2", text: "Destination", line: 40, top: 600)
        ])

        context.evaluateScript("window.MarkLensScroll.restore({ request: 1, line: 40, progress: 0, anchor: null, offset: 0 });")

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("scrollY")?.toInt32(), 600)
        XCTAssertEqual(context.evaluateScript("document.body.children.length")?.toInt32(), 0)
    }

    func testBlankLineUsesFollowingRenderedElement() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "P", text: "Before blank", line: 10, top: 100),
            anchor(tag: "H2", text: "After blank", line: 14, top: 300)
        ])

        context.evaluateScript("window.MarkLensScroll.restore({ request: 1, line: 12, progress: 0, anchor: null, offset: 0 });")

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("scrollY")?.toInt32(), 300)
    }

    func testLinePastLastRenderedElementGoesToEnd() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "P", text: "Last", line: 10, top: 100)
        ])

        context.evaluateScript("window.MarkLensScroll.restore({ request: 1, line: 99, progress: 0, anchor: null, offset: 0 });")

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("scrollY")?.toInt32(), 1_900)
    }

    func testRenderedBlockWithoutIndividualLinesUsesItsRange() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "DIV", text: "Diagram", line: 10, top: 100,
                   endLine: 15, rangeFallback: true),
            anchor(tag: "P", text: "After", line: 20, top: 300)
        ])

        context.evaluateScript("window.MarkLensScroll.restore({ request: 1, line: 12, progress: 0, anchor: null, offset: 0 });")

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("scrollY")?.toInt32(), 100)
    }

    func testUserScrollCancelsRestorationBeforeLaterLayoutChanges() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "H2", text: "Destination", line: 40, top: 600)
        ])

        context.evaluateScript("""
        window.MarkLensScroll.restore({
            request: 17,
            line: 40,
            progress: 0.3,
            anchor: null,
            occurrence: null,
            previousAnchor: null,
            nextAnchor: null,
            offset: 20
        });
        scrollY = 640;
        eventListeners.scroll();
        latestResizeObserver.callback();
        window.MarkLensScroll.report();
        """)

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("scrollY")?.toInt32(), 640)
        let position = try lastReportedPosition(in: context)
        XCTAssertTrue(position["restorationRequest"] is NSNull)
    }

    func testProgrammaticRestorationScrollKeepsLayoutCorrectionActive() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "H2", text: "Destination", line: 40, top: 600)
        ])

        context.evaluateScript("""
        window.MarkLensScroll.restore({
            request: 17,
            line: 40,
            progress: 0.3,
            anchor: null,
            occurrence: null,
            previousAnchor: null,
            nextAnchor: null,
            offset: 20
        });
        eventListeners.scroll();
        mockAnchors[0].top = 650;
        latestResizeObserver.callback();
        """)

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("scrollY")?.toInt32(), 630)
        let position = try lastReportedPosition(in: context)
        XCTAssertEqual((position["restorationRequest"] as? NSNumber)?.intValue, 17)
    }

    func testUserScrollReportingIsBoundedAndIncludesFinalPosition() throws {
        let context = try makeContext(anchors: [
            anchor(tag: "H2", text: "Destination", line: 40, top: 600)
        ])

        context.evaluateScript("""
        while (pendingTimeouts.length > 0) pendingTimeouts.shift().callback();
        var reportsBeforeScroll = postedMessages.length;
        scrollY = 100;
        eventListeners.scroll();
        var reportsAfterLeadingEvent = postedMessages.length;
        scrollY = 200;
        eventListeners.scroll();
        scrollY = 300;
        eventListeners.scroll();
        var reportsBeforeInterval = postedMessages.length;
        pendingTimeouts.shift().callback();
        var reportsAfterInterval = postedMessages.length;
        var intervalPosition = postedMessages[postedMessages.length - 1].progress;
        scrollY = 400;
        eventListeners.scroll();
        pendingTimeouts.shift().callback();
        var reportsAfterFinal = postedMessages.length;
        var finalPosition = postedMessages[postedMessages.length - 1].progress;
        """)

        XCTAssertNil(context.exception)
        XCTAssertEqual(
            context.objectForKeyedSubscript("reportsAfterLeadingEvent")?.toInt32(),
            (context.objectForKeyedSubscript("reportsBeforeScroll")?.toInt32() ?? 0) + 1
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("reportsBeforeInterval")?.toInt32(),
            context.objectForKeyedSubscript("reportsAfterLeadingEvent")?.toInt32()
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("reportsAfterInterval")?.toInt32(),
            (context.objectForKeyedSubscript("reportsBeforeInterval")?.toInt32() ?? 0) + 1
        )
        let intervalPosition = try XCTUnwrap(
            context.objectForKeyedSubscript("intervalPosition")?.toDouble()
        )
        XCTAssertEqual(intervalPosition, 300.0 / 1_900.0, accuracy: 0.001)
        XCTAssertEqual(
            context.objectForKeyedSubscript("reportsAfterFinal")?.toInt32(),
            (context.objectForKeyedSubscript("reportsAfterInterval")?.toInt32() ?? 0) + 1
        )
        let finalPosition = try XCTUnwrap(
            context.objectForKeyedSubscript("finalPosition")?.toDouble()
        )
        XCTAssertEqual(finalPosition, 400.0 / 1_900.0, accuracy: 0.001)
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
        height: Int = 20,
        endLine: Int? = nil,
        rangeFallback: Bool = false
    ) -> [String: Any] {
        ["tag": tag, "text": text, "line": line, "top": top, "height": height,
         "endLine": endLine as Any? ?? NSNull(), "rangeFallback": rangeFallback]
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
            dataset: {
                marklensSourceLine: String(spec.line),
                marklensSourceEndLine: spec.endLine === null ? undefined : String(spec.endLine),
                marklensSourceRangeFallback: spec.rangeFallback ? '' : undefined
            },
            top: spec.top,
            parentElement: spec.tag === 'SPAN' ? {
                getBoundingClientRect() {
                    return { top: 100 - scrollY, bottom: 180 - scrollY, left: 10, width: 500, height: 80 };
                }
            } : null,
            getAttribute(name) { return name === 'aria-hidden' && spec.tag === 'SPAN' ? 'true' : null; },
            getBoundingClientRect() {
                return {
                    top: this.top - scrollY,
                    bottom: this.top - scrollY + spec.height,
                    left: 10,
                    width: spec.tag === 'SPAN' ? 0 : 500,
                    height: spec.height
                };
            }
        }));
        var overlayChildren = [];
        var document = {
            documentElement: { scrollHeight: 2_000 },
            body: { appendChild(element) { overlayChildren.push(element); }, get children() { return overlayChildren; } },
            createElement() {
                return {
                    style: {},
                    setAttribute() {},
                    remove() { overlayChildren = overlayChildren.filter(child => child !== this); }
                };
            },
            querySelectorAll() { return mockAnchors; }
        };
        function getComputedStyle() { return { lineHeight: '24px' }; }
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
        var latestResizeObserver = null;
        var pendingTimeouts = [];
        var ResizeObserver = class {
            constructor(callback) {
                this.callback = callback;
                latestResizeObserver = this;
            }
            observe() {}
        };
        function requestAnimationFrame(callback) { callback(); }
        var eventListeners = {};
        function addEventListener(name, callback) { eventListeners[name] = callback; }
        function setTimeout(callback, delay) {
            if (delay <= 100) callback();
            else pendingTimeouts.push({ callback, delay });
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
