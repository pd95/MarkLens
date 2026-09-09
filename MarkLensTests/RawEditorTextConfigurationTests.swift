#if os(macOS)
import AppKit
import XCTest
@testable import MarkLens

@MainActor
final class RawEditorTextConfigurationTests: XCTestCase {
    func testDisablesAutomaticTextTransformations() {
        let textView = NSTextView()

        RawEditorTextConfiguration.apply(to: textView)

        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(textView.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(textView.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isGrammarCheckingEnabled)
    }
}
#endif
