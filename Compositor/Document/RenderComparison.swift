import Foundation
import CoreGraphics

extension EditorSession {
    func setFinishComparison(_ mode: FinishComparisonMode) {
        guard let edit = filterEdit, edit.kind == .renderFinish else { return }
        edit.comparisonMode = mode
        edit.showingOriginal = false
        if let fill = edit.comparisonFill { fitFinishComparison(fill: fill) }
        brushRevision += 1
    }

    func showFinishOriginal(_ show: Bool) {
        guard let edit = filterEdit, edit.kind == .renderFinish else { return }
        edit.showingOriginal = show
        brushRevision += 1
    }

    func fitFinishComparison(fill: Bool = false) {
        guard let edit = filterEdit, edit.kind == .renderFinish, let document else { return }
        let zoom = FinishComparisonGeometry.zoom(document: document.size, view: viewport.viewSize,
            backingScale: viewport.backingScale, sideBySide: edit.comparisonMode == .sideBySide, fill: fill)
        viewport.setZoom(zoom, anchoredAt: viewport.center, documentSize: document.size)
        viewport.pan = .zero
        edit.comparisonFill = fill
        brushRevision += 1
    }
}
