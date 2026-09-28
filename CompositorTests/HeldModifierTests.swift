import AppKit
import SwiftUI
import Testing
@testable import Compositor

/// Holding Command shows, in the Move tool's options bar, that it turns Auto Select the other way while held.
@MainActor
struct HeldModifierTests {
    @Test func heldCommandShowsAutoSelectFlippedInTheBar() throws {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        session.selectTool(.move)
        session.transformAutoSelect = false
        let host = NSHostingView(rootView: TransformInspector(session: session))
        host.frame = CGRect(x: 0, y: 0, width: 1400, height: 42)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { HeldModifiers.shared.update([]) }
        func settle() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        func buttons(_ view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
        settle()
        // Auto Select is the bar's first checkbox.
        let autoSelect = try #require(buttons(host).first)
        #expect(autoSelect.state == .off)
        HeldModifiers.shared.update(.command)
        settle()
        #expect(autoSelect.state == .on)
        #expect(!session.transformAutoSelect, "only shown flipped; the setting itself is unchanged")
        HeldModifiers.shared.update([])
        settle()
        #expect(autoSelect.state == .off)
    }
}
