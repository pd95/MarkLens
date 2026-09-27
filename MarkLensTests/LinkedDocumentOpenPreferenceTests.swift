import XCTest
@testable import MarkLens

#if os(macOS)
final class LinkedDocumentOpenPreferenceTests: XCTestCase {
    func testStoredChoiceAndUnknownValue() {
        let suiteName = "LinkedDocumentOpenPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        LinkedDocumentOpenPreference.registerDefaults(in: defaults)
        XCTAssertEqual(LinkedDocumentOpenPreference.current(in: defaults), .followSystem)
        defaults.set(LinkedDocumentOpenPreference.newWindow.rawValue, forKey: LinkedDocumentOpenPreference.key)
        XCTAssertEqual(LinkedDocumentOpenPreference.current(in: defaults), .newWindow)
        defaults.set(LinkedDocumentOpenPreference.newTab.rawValue, forKey: LinkedDocumentOpenPreference.key)
        XCTAssertEqual(LinkedDocumentOpenPreference.current(in: defaults), .newTab)
        defaults.set("unknown", forKey: LinkedDocumentOpenPreference.key)
        XCTAssertEqual(LinkedDocumentOpenPreference.current(in: defaults), .followSystem)
    }
}
#endif
