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
            NSHostingView(rootView: ToolRailStack(session: session, columns: .constant(columns))).fittingSize
        }
        #expect(size(1).width == 56)
        #expect(size(2).width == 92)
        #expect(size(2).height < size(1).height * 0.75)
    }

    /// The rail scrolls its contents in an AppKit scroll view, which has to give them the rail's whole width: at a
    /// fixed one-column width the second column was cut off.
    @Test func scrollingRailGivesItsContentsItsWidth() throws {
        for columns in [1, 2] {
            let width = ToolRailLayout.width(columns: columns)
            let host = NSHostingView(rootView: ToolRail(session: EditorSession(), columns: .constant(columns)).frame(height: 300))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            host.layoutSubtreeIfNeeded()
            func scrollView(in view: NSView) -> NSScrollView? {
                view as? NSScrollView ?? view.subviews.lazy.compactMap(scrollView).first
            }
            let scroll = try #require(scrollView(in: host))
            #expect(scroll.frame.width == width)
            #expect(scroll.documentView?.frame.width == width)
        }
    }
}
