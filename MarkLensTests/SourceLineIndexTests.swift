import XCTest
@testable import MarkLens

final class SourceLineIndexTests: XCTestCase {
    func testMapsLinesToUTF16Offsets() {
        let index = SourceLineIndex(text: "alpha\n😀 beta\nomega")

        XCTAssertEqual(index.characterOffset(forLine: 1), 0)
        XCTAssertEqual(index.characterOffset(forLine: 2), 6)
        XCTAssertEqual(index.characterOffset(forLine: 3), 14)
        XCTAssertEqual(index.characterOffset(forLine: 100), 14)
    }

    func testMapsUTF16OffsetsToLines() {
        let index = SourceLineIndex(text: "alpha\n😀 beta\nomega")

        XCTAssertEqual(index.lineNumber(at: 0), 1)
        XCTAssertEqual(index.lineNumber(at: 5), 1)
        XCTAssertEqual(index.lineNumber(at: 6), 2)
        XCTAssertEqual(index.lineNumber(at: 13), 2)
        XCTAssertEqual(index.lineNumber(at: 14), 3)
        XCTAssertEqual(index.lineNumber(at: 10_000), 3)
    }

    func testTrailingNewlineCreatesAnEmptyFinalLine() {
        let index = SourceLineIndex(text: "one\n")

        XCTAssertEqual(index.characterOffset(forLine: 2), 4)
        XCTAssertEqual(index.lineNumber(at: 4), 2)
    }

    func testEmptyInputStaysOnItsSingleLogicalLine() {
        let index = SourceLineIndex(text: "")

        XCTAssertEqual(index.characterOffset(forLine: 1), 0)
        XCTAssertEqual(index.characterOffset(forLine: 100), 0)
        XCTAssertEqual(index.lineNumber(at: 100), 1)
        XCTAssertEqual(index.progress(at: 100), 0)
    }

    func testCRLFUsesUTF16OffsetsAndCountsOneLogicalLineBreak() {
        let index = SourceLineIndex(text: "one\r\ntwo")

        XCTAssertEqual(index.characterOffset(forLine: 2), 5)
        XCTAssertEqual(index.lineNumber(at: 4), 1)
        XCTAssertEqual(index.lineNumber(at: 5), 2)
    }

    func testMapsProgressWithoutMeasuringLaidOutContent() {
        let index = SourceLineIndex(text: "0123456789")

        XCTAssertEqual(index.characterOffset(forProgress: 0.5), 5)
        XCTAssertEqual(index.progress(at: 5), 0.5)
        XCTAssertEqual(index.characterOffset(forProgress: -1), 0)
        XCTAssertEqual(index.characterOffset(forProgress: .nan), 0)
        XCTAssertEqual(index.progress(at: 100), 1)
    }
}
