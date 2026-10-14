import Foundation
import Testing
@testable import Compositor

/// The app hosts these tests, and an update out since this build would stop them with Sparkle's alert, so the app
/// doesn't check for updates while it does.
struct UpdateCheckTests {
    @Test func theTestHostKnowsItRunsTests() {
        #expect(CompositorApplicationDelegate.runsTests)
        // From launch, before XCTest has anything loaded.
        let environment = ProcessInfo.processInfo.environment
        #expect(environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil)
    }
}
