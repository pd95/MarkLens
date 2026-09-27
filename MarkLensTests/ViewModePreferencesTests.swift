import XCTest
@testable import MarkLens

#if os(macOS)
final class ViewModePreferencesTests: XCTestCase {
    func testDefaultAndPerFileChoicesRemainIndependent() throws {
        let suiteName = "ViewModePreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        ViewModePreferences.registerDefaults(in: defaults)

        let first = URL(fileURLWithPath: "/tmp/view-mode/first.md")
        let second = URL(fileURLWithPath: "/tmp/view-mode/second.md")
        XCTAssertFalse(ViewModePreferences.isEnabled(for: first, in: defaults))

        defaults.set(true, forKey: ViewModePreferences.defaultKey)
        XCTAssertTrue(ViewModePreferences.isEnabled(for: first, in: defaults))
        ViewModePreferences.setEnabled(false, for: first, in: defaults)
        XCTAssertFalse(ViewModePreferences.isEnabled(for: first, in: defaults))
        XCTAssertTrue(ViewModePreferences.isEnabled(for: second, in: defaults))

        defaults.set(false, forKey: ViewModePreferences.defaultKey)
        ViewModePreferences.setEnabled(true, for: second, in: defaults)
        XCTAssertFalse(ViewModePreferences.isEnabled(for: first, in: defaults))
        XCTAssertTrue(ViewModePreferences.isEnabled(for: second, in: defaults))
        XCTAssertTrue(ViewModePreferences.isEnabled(
            for: URL(fileURLWithPath: "/tmp/view-mode/../view-mode/second.md"),
            in: defaults
        ))
    }
}
#endif
