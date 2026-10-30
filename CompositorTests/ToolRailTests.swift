import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct ToolRailTests {
    private let tools = NavigationTool.allCases.filter { $0 != .idle }

    @Test func widthsForOneAndTwoColumns() {
        #expect(ToolRailLayout.width(columns: 1) == 56)
        #expect(ToolRailLayout.width(columns: 2) == 92)
        #expect(ToolRailLayout.width(columns: 7) == 92, "anything past two is two")
    }

    @Test func rowsKeepTheOrderAndFillLeftToRight() {
        let one = ToolRailLayout.rows(tools, columns: 1)
        #expect(one.count == tools.count && one.allSatisfy { $0.count == 1 })
        let two = ToolRailLayout.rows(tools, columns: 2)
        #expect(two.count == (tools.count + 1) / 2)
        #expect(two.flatMap { $0 } == tools, "same order, read row by row")
        #expect(two.dropLast().allSatisfy { $0.count == 2 })
        #expect(ToolRailLayout.rows([], columns: 2).isEmpty)
    }

    @Test func railIsAsWideAsItsColumnsAndShorterInTwo() {
        let session = EditorSession()
        func size(_ columns: Int) -> CGSize {
            // The rail's contents: the scroll view around them would take any height it's offered.
            NSHostingView(rootView: ToolRailStack(session: session, columns: columns)).fittingSize
        }
        #expect(size(1).width == 56)
        #expect(size(2).width == 92)
        #expect(size(2).height < size(1).height * 0.75)
    }

    /// One column while the window is tall enough for it; two, scrolling in an AppKit scroll view that has to give
    /// its contents the rail's whole width, when it isn't.
    @Test func railTakesTwoColumnsWhenOneDoesntFit() throws {
        let session = EditorSession()
        let tall = NSHostingView(rootView: ToolRailStack(session: session, columns: 1)).fittingSize.height
        func scrollView(in view: NSView) -> NSScrollView? {
            view as? NSScrollView ?? view.subviews.lazy.compactMap(scrollView).first
        }
        func rail(height: CGFloat) -> NSHostingView<some View> {
            let host = NSHostingView(rootView: ToolRail(session: session).frame(height: height))
            host.frame = CGRect(x: 0, y: 0, width: 200, height: height)
            host.layoutSubtreeIfNeeded()
            return host
        }
        let roomy = rail(height: tall + 20)
        #expect(roomy.fittingSize.width == 56)
        #expect(scrollView(in: roomy) == nil, "one column needs no scrolling")
        let short = rail(height: 300)
        #expect(short.fittingSize.width == 92)
        let scroll = try #require(scrollView(in: short))
        #expect(scroll.frame.width == 92)
        #expect(scroll.documentView?.frame.width == 92)
    }
}
