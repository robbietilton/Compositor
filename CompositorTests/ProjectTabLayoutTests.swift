import Foundation
import Testing
@testable import Compositor

/// `projectTabOverflow` is pure geometry, so these exercise it directly with made-up ids and widths
/// rather than real `ProjectTab`s.
struct ProjectTabLayoutTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    /// Every tab 100 wide, a flat 80-wide pill — big enough that width numbers stay easy to check by hand.
    private func widths(_ ids: [UUID]) -> [UUID: CGFloat] { Dictionary(uniqueKeysWithValues: ids.map { ($0, 100) }) }
    private let pill: (Int) -> CGFloat = { _ in 80 }

    @Test func everythingFitsShowsAllTabsWithNoPill() {
        let order = [a, b, c]
        let result = projectTabOverflow(order: order, widths: widths(order), selectedID: c, availableWidth: 400, pillWidth: pill)
        #expect(result.hiddenIDs.isEmpty)
        #expect(result.pill == nil)
        #expect(result.visible.map(\.id) == order)
        #expect(result.visible.map(\.x) == [0, 106, 212])
        #expect(result.contentWidth == 312)
    }

    @Test func overflowHidesTheLeftmostTabsAndPillsThem() {
        let order = [a, b, c, d, e]
        // Only room for the pill plus the rightmost two tabs (292 wide); a third would need 398.
        let result = projectTabOverflow(order: order, widths: widths(order), selectedID: e, availableWidth: 300, pillWidth: pill)
        #expect(result.hiddenIDs == [a, b, c])
        #expect(result.visible.map(\.id) == [d, e])
        #expect(result.pill?.width == 80)
        #expect(result.visible.first?.x == 86) // pill (80) + spacing (6)
        #expect(result.contentWidth == 292)
    }

    @Test func selectedTabInTheHiddenSetIsPinnedRightOfThePill() {
        let order = [a, b, c, d, e]
        // Same overflow as above, but the selected tab (a) would otherwise be hidden.
        let result = projectTabOverflow(order: order, widths: widths(order), selectedID: a, availableWidth: 300, pillWidth: pill)
        // a takes the first visible slot; d — the tab that would have had it — is hidden instead. The
        // visible count is unchanged, and the overflow menu still lists hiddenIDs in their real order.
        #expect(result.visible.map(\.id) == [a, e])
        #expect(result.hiddenIDs == [b, c, d])
        #expect(result.pill?.width == 80)
    }

    @Test func overflowLabelIsSingularForOneTab() {
        #expect(projectTabOverflowLabel(for: 1) == String(localized: "1 more tab"))
        #expect(projectTabOverflowLabel(for: 2) == String(localized: "\(2) more tabs"))
        #expect(projectTabOverflowLabel(for: 11) == String(localized: "\(11) more tabs"))
    }

    @Test func unmeasuredWidthShowsEverythingRatherThanGuessing() {
        let order = [a, b, c, d, e]
        let result = projectTabOverflow(order: order, widths: widths(order), selectedID: a, availableWidth: 0, pillWidth: pill)
        #expect(result.hiddenIDs.isEmpty)
        #expect(result.pill == nil)
        #expect(result.visible.count == 5)
    }

    /// Picking a long-titled hidden tab still leaves a row that fits: the tabs after it make room.
    @Test func aWiderSelectedTabStillFits() {
        let order = (0..<8).map { _ in UUID() }
        var widths = Dictionary(uniqueKeysWithValues: order.map { ($0, CGFloat(80)) })
        widths[order[0]] = 190
        let layout = projectTabOverflow(order: order, widths: widths, selectedID: order[0], availableWidth: 500) { _ in 90 }
        let right = layout.visible.last.map { $0.x + $0.width } ?? 0
        #expect(right <= 500, "row ends at \(right)")
        #expect(layout.visible.first?.id == order[0])
    }
}
