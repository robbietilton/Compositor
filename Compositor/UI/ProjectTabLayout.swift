import Foundation

/// Horizontal gap between adjacent tab pills, and between the overflow pill and the first tab after it.
let projectTabSpacing: CGFloat = 6

/// A pill's slot in the strip: `id` identifies the tab it belongs to (or is absent for the overflow pill).
struct ProjectTabSlot: Identifiable, Equatable {
    let id: UUID
    let x: CGFloat
    let width: CGFloat
}

/// The overflow pill's own slot — no tab id, since it isn't one.
struct ProjectTabPillSlot: Equatable {
    let x: CGFloat
    let width: CGFloat
}

/// What the strip should draw right now: the tabs that fit, the ones that don't (for the overflow menu, in
/// their real order), and the overflow pill's own slot.
struct ProjectTabOverflow: Equatable {
    let visible: [ProjectTabSlot]
    let hiddenIDs: [UUID]
    let pill: ProjectTabPillSlot?
    var contentWidth: CGFloat { visible.last.map { $0.x + $0.width } ?? pill.map { $0.x + $0.width } ?? 0 }
}

/// "N more tabs", singular for one.
func projectTabOverflowLabel(for hiddenCount: Int) -> String {
    hiddenCount == 1 ? String(localized: "1 more tab") : String(localized: "\(hiddenCount) more tabs")
}

/// Lays out the strip left to right: everything shows when it all fits. Otherwise tabs are dropped from the
/// front of `order` — oldest overflow first — until the rest fit alongside an overflow pill at x = 0. The
/// selected tab is never dropped: if it would be, it takes the first visible slot (right after the pill) and
/// whichever tab was there instead is hidden in its place, so the visible count never changes.
func projectTabOverflow(order: [UUID], widths: [UUID: CGFloat], selectedID: UUID,
                        availableWidth: CGFloat, pillWidth: (Int) -> CGFloat) -> ProjectTabOverflow {
    guard !order.isEmpty else { return ProjectTabOverflow(visible: [], hiddenIDs: [], pill: nil) }
    func span(_ ids: some Collection<UUID>) -> CGFloat {
        guard !ids.isEmpty else { return 0 }
        return ids.reduce(0) { $0 + (widths[$1] ?? 0) } + projectTabSpacing * CGFloat(ids.count - 1)
    }
    func place(_ ids: [UUID], startX: CGFloat) -> [ProjectTabSlot] {
        var x = startX
        return ids.map { id in
            let width = widths[id] ?? 0
            defer { x += width + projectTabSpacing }
            return ProjectTabSlot(id: id, x: x, width: width)
        }
    }
    // Not yet measured, or everything already fits: no pill needed.
    if availableWidth <= 0 || span(order) <= availableWidth {
        return ProjectTabOverflow(visible: place(order, startX: 0), hiddenIDs: [], pill: nil)
    }
    var shown = order.count
    while shown > 1 {
        let hidden = order.count - shown
        let width = pillWidth(hidden) + projectTabSpacing + span(order.suffix(shown))
        if width <= availableWidth { break }
        shown -= 1
    }
    var visibleIDs = Array(order.suffix(shown))
    var hiddenIDs = Array(order.prefix(order.count - shown))
    if let bumped = visibleIDs.first, hiddenIDs.contains(selectedID) {
        hiddenIDs.removeAll { $0 == selectedID }
        hiddenIDs.append(bumped)
        visibleIDs[0] = selectedID
        // The selected tab can be wider than the one it replaced (a longer title, set in semibold): hide the
        // tabs after it until the row fits again.
        while visibleIDs.count > 1, pillWidth(hiddenIDs.count) + projectTabSpacing + span(visibleIDs) > availableWidth {
            hiddenIDs.append(visibleIDs.remove(at: 1))
        }
    }
    let pillW = pillWidth(hiddenIDs.count)
    let pill = ProjectTabPillSlot(x: 0, width: pillW)
    return ProjectTabOverflow(visible: place(visibleIDs, startX: pillW + projectTabSpacing), hiddenIDs: hiddenIDs, pill: pill)
}
