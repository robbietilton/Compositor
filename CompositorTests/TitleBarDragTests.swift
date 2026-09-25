import AppKit
import SwiftUI
import Testing
@testable import Compositor

/// The tab strip sits in the title bar. Empty space beside the tabs has to stay a window drag, on macOS 26
/// where a scroll view keeps the mouse-down across its whole frame.
@MainActor
@Suite(.serialized)
struct TitleBarDragTests {
    @Test func emptySpaceBesideOneTabIsOutsideTheScroller() async throws {
        let workspace = ProjectWorkspace()
        let (window, hosting) = try await host(workspace, width: 800)
        defer { window.orderOut(nil) }
        let scroll = try #require(scrollView(in: hosting))
        #expect(abs(hosting.bounds.width - 800) < 2, "host \(hosting.bounds)")
        #expect(scroll.frame.width < 220,
                "one tab still owns frame \(scroll.frame) bounds \(scroll.bounds) in host \(hosting.bounds)")
        let point = NSPoint(x: hosting.bounds.width - 40, y: hosting.bounds.midY)
        let scrollFrame = scroll.convert(scroll.bounds, to: hosting)
        #expect(scrollFrame.contains(point) == false, "empty title bar is still inside \(scrollFrame)")
        let hit = hosting.hitTest(point)
        #expect(hit is TitleBarDragView, "the empty title bar hit \(String(describing: hit.map { type(of: $0) }))")
        try sendClick(at: point, in: hosting, window: window)
        #expect(window.dragCount == 1)

        window.dragCount = 0
        try sendClick(at: NSPoint(x: 12, y: hosting.bounds.midY), in: hosting, window: window)
        #expect(window.dragCount == 0, "a tab click dragged the window")
    }

    @Test func overflowingTabsStayInsideTheSlotAndCanScroll() async throws {
        let workspace = ProjectWorkspace()
        for _ in 0..<12 { workspace.newCanvas() }
        let (window, hosting) = try await host(workspace, width: 280)
        defer { window.orderOut(nil) }
        let scroll = try #require(scrollView(in: hosting))
        #expect(abs(scroll.bounds.width - 280) < 2, "the strip grew to \(scroll.bounds.width)")
        let documentWidth = scroll.documentView?.frame.width ?? 0
        #expect(documentWidth > scroll.bounds.width + 1, "tabs \(documentWidth) never overflowed \(scroll.bounds.width)")
        #expect(scroll.horizontalScrollElasticity == .allowed)
    }

    private func host(_ workspace: ProjectWorkspace, width: CGFloat) async throws -> (DragRecordingWindow, NSView) {
        let hosting = NSHostingView(rootView: ProjectTabStrip(workspace: workspace)
            .frame(width: width, height: 34, alignment: .leading))
        hosting.sizingOptions = []
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 34)
        let window = DragRecordingWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func sendClick(at point: NSPoint, in view: NSView, window: NSWindow) throws {
        let location = view.convert(point, to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(down)
    }

    private final class DragRecordingWindow: NSWindow {
        var dragCount = 0
        override func performDrag(with event: NSEvent) { dragCount += 1 }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let scroll = scrollView(in: subview) { return scroll }
        }
        return nil
    }
}
