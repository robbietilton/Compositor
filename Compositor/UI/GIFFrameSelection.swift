import Foundation

/// Batch targets stay separate from the frame displayed on the canvas and are never saved.
nonisolated struct GIFFrameSelection: Equatable {
    private(set) var indices: Set<Int> = []

    mutating func select(_ index: Int, toggling: Bool, displayedIndex: Int) {
        guard toggling else { indices = [index]; return }
        if indices.isEmpty { indices = [displayedIndex] }
        if indices.contains(index) {
            if indices.count > 1 { indices.remove(index) }
        } else { indices.insert(index) }
    }

    mutating func include(_ targets: Set<Int>, displayedIndex: Int) {
        guard !targets.isEmpty else { return }
        if indices.isEmpty { indices = [displayedIndex] }
        indices.formUnion(targets)
    }

    mutating func reconcile(with available: Set<Int>, displayedIndex: Int) {
        indices.formIntersection(available)
        if indices.isEmpty, available.contains(displayedIndex) { indices = [displayedIndex] }
    }

    mutating func followDisplayedFrame(_ index: Int) {
        if indices.count <= 1 { indices = [index] }
    }
}
