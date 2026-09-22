import Foundation

@main struct ComparisonChecks {
    static func main() {
        let view = CGSize(width: 1200, height: 800), document = CGSize(width: 1800, height: 1200)
        let panes = FinishComparisonGeometry.panes(in: CGRect(origin: .zero, size: view))
        assert(panes.count == 2 && panes[0].width == panes[1].width)
        assert(panes[1].minX - panes[0].maxX == 12)
        for paired in [false, true] {
            let available = paired ? panes[0].size : view
            let fit = FinishComparisonGeometry.zoom(document: document, view: view, backingScale: 2, sideBySide: paired, fill: false)
            assert(document.width * fit / 2 <= available.width && document.height * fit / 2 <= available.height)
            let fill = FinishComparisonGeometry.zoom(document: document, view: view, backingScale: 2, sideBySide: paired, fill: true)
            assert(document.width * fill / 2 >= available.width - 0.01 && document.height * fill / 2 >= available.height - 0.01)
        }
        let left = CGPoint(x: panes[0].midX + 50, y: 250), right = CGPoint(x: panes[1].midX + 50, y: 250)
        assert(FinishComparisonGeometry.centeredAnchor(left, view: view) == FinishComparisonGeometry.centeredAnchor(right, view: view))
        var viewport = CanvasViewport()
        viewport.resize(to: view, backingScale: 2, documentSize: document)
        let anchor = FinishComparisonGeometry.centeredAnchor(right, view: view)
        let before = viewport.documentPoint(from: anchor, documentSize: document)
        viewport.setZoom(1, anchoredAt: anchor, documentSize: document)
        let after = viewport.documentPoint(from: anchor, documentSize: document)
        assert(abs(before.x - after.x) < 0.001 && abs(before.y - after.y) < 0.001)
        assert(viewport.pointsPerPixel == 0.5) // 1:1 is physical display pixels on Retina, not points.
        print("Comparison: equal panes, Fit, Fill, synchronized anchoring and Retina 1:1 passed.")
    }
}
