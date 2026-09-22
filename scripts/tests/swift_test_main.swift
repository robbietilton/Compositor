import AppKit
import Testing

/// A small CLT host for the same Swift Testing cases used by the Xcode test target.
/// This does not start Compositor, its updater, or its document controller.
@main struct CompositorTestRunner {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard let optionsPath = ProcessInfo.processInfo.environment["COMPOSITOR_SWIFT_TEST_OPTIONS"] else {
            fatalError("Run this executable through scripts/test-swift.py")
        }
        let options = try JSONDecoder().decode(Testing.__CommandLineArguments_v0.self,
            from: Data(contentsOf: URL(fileURLWithPath: optionsPath)))
        let result: CInt = await Testing.__swiftPMEntryPoint(passing: options)
        exit(result)
    }
}
