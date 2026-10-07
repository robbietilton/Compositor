import Foundation
import Testing
@testable import Compositor

/// iPadOS bringing a window back as it was left, with its tabs.
@MainActor struct PadRestorationTests {
    /// A window's tabs are kept in an activity named for the app's bundle identifier, as the Info.plist's list of the
    /// types iPadOS may hand back is, so the two can't drift apart and a build of your own under another has its own.
    @Test func theWindowsActivityIsNamedForTheApp() throws {
        let identifier = try #require(Bundle.main.bundleIdentifier)
        #expect(EditorWindowController.restorationActivityType == identifier + ".window")
        let types = try #require(Bundle.main.infoDictionary?["NSUserActivityTypes"] as? [String])
        #expect(types.contains(EditorWindowController.restorationActivityType))
    }
}
