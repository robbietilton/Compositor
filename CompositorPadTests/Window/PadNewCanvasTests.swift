import Testing
import UIKit
@testable import Compositor

/// The New canvas card a window shows with no project, as the Mac's New Canvas sheet.
@MainActor struct PadNewCanvasTests {
    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// The button between the fields is named for what it does, with no hint, which would only say the name again: its
    /// help, which only an iPad app running on a Mac shows as a tooltip, is the name, as the Mac's.
    @Test func theSwapButtonIsNamedWithoutAHint() throws {
        let card = NewCanvasView()
        let swap = try #require(views(UIButton.self, in: card).first { $0.accessibilityLabel == "Swap width and height" })
        #expect(swap.accessibilityHint == nil)
    }
}
