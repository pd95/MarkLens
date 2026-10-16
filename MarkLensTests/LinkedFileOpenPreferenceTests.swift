import XCTest
@testable import MarkLens

final class LinkedFileOpenPreferenceTests: XCTestCase {
    func testStoredChoiceAndInvalidValueFallback() throws {
        let suiteName = "LinkedFileOpenPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        LinkedFileOpenPreference.registerDefaults(in: defaults)
        XCTAssertEqual(LinkedFileOpenPreference.current(in: defaults), .init())
        defaults.set("quickLook", forKey: LinkedFileOpenPreference.key)
        XCTAssertEqual(LinkedFileOpenPreference.current(in: defaults).clickAction, .quickLook)
        defaults.set("openInDefaultApp", forKey: LinkedFileOpenPreference.commandClickKey)
        XCTAssertEqual(LinkedFileOpenPreference.current(in: defaults).commandClickAction, .openInDefaultApp)
        defaults.set("unknown", forKey: LinkedFileOpenPreference.key)
        XCTAssertEqual(LinkedFileOpenPreference.current(in: defaults).clickAction, .revealInFinder)
        XCTAssertEqual(LinkedFileOpenPreference.current(in: defaults).commandClickAction, .openInDefaultApp)
        defaults.set("unknown", forKey: LinkedFileOpenPreference.commandClickKey)
        XCTAssertEqual(LinkedFileOpenPreference.current(in: defaults), .init())
    }
}
