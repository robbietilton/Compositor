import Foundation
import CoreGraphics

nonisolated enum CropGeometry {
    static func snapped(_ rect: CGRect) -> CGRect {
        let rect = rect.standardized
        let x = rect.minX.rounded(), y = rect.minY.rounded()
        return CGRect(x: x, y: y, width: max(1, rect.maxX.rounded() - x), height: max(1, rect.maxY.rounded() - y))
    }
    static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && (1...30_000).contains(rect.width) && (1...30_000).contains(rect.height)
            && abs(rect.minX) <= 1_000_000 && abs(rect.minY) <= 1_000_000
    }
    /// A frame dragged from `start` to `end` — or, `symmetric` (Option), grown out from `start` as its center.
    static func create(from start: CGPoint, to end: CGPoint, ratio: CGFloat?, symmetric: Bool = false) -> CGRect {
        var dx = end.x - start.x, dy = end.y - start.y
        if let ratio {
            if abs(dx) > abs(dy) * ratio { dy = (dy < 0 ? -1 : 1) * abs(dx) / ratio }
            else { dx = (dx < 0 ? -1 : 1) * abs(dy) * ratio }
        }
        if symmetric {
            return snapped(CGRect(x: start.x - abs(dx), y: start.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2))
        }
        return snapped(CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy)))
    }
}

struct CropDrag {
    enum Mode { case create, move, resize(Int) }
    let start: CGPoint
    let original: CGRect
    let mode: Mode
    /// `symmetric` (Option held) keeps the frame's center fixed: the opposite edges move with the dragged ones.
    func updated(to point: CGPoint, ratio: CGFloat?, symmetric: Bool = false) -> CGRect {
        switch mode {
        case .create: return CropGeometry.create(from: start, to: point, ratio: ratio, symmetric: symmetric)
        case .move: return CropGeometry.snapped(original.offsetBy(dx: point.x - start.x, dy: point.y - start.y))
        case .resize(let index):
            let transform = LayerTransform(origin: original.origin, size: original.size)
            let drag = TransformDrag(original: transform, start: start, mode: .resize(index))
            let next = drag.updated(to: point, lockRatio: ratio != nil, shift: false, option: symmetric)
            return CropGeometry.snapped(CGRect(origin: next.origin, size: next.size))
        }
    }
}

/// Crop edges snap to nearby layer and canvas edges while dragging.
nonisolated struct CropSnap {
    /// Document x and y positions to snap to.
    let xs: [CGFloat]
    let ys: [CGFloat]
    /// How close, in document pixels, an edge must come to snap.
    let tolerance: CGFloat

    private func nearest(_ value: CGFloat, in targets: [CGFloat]) -> CGFloat? {
        var best: CGFloat?
        for target in targets where abs(target - value) <= tolerance {
            if let current = best, abs(current - value) <= abs(target - value) { continue }
            best = target
        }
        return best
    }

    /// Moving the frame snaps its closest edges and keeps its size; creating or resizing snaps only the
    /// edges on the side being dragged — mirrored about the center when `symmetric`. With a fixed ratio only
    /// moves snap, so the ratio stays exact.
    func apply(_ rect: CGRect, drag: CropDrag, point: CGPoint, ratio: CGFloat?, symmetric: Bool = false) -> CGRect {
        guard tolerance > 0 else { return rect }
        let horizontal: Bool, vertical: Bool
        switch drag.mode {
        case .move:
            func shift(_ edges: [CGFloat], _ targets: [CGFloat]) -> CGFloat {
                edges.compactMap { edge in nearest(edge, in: targets).map { $0 - edge } }.min { abs($0) < abs($1) } ?? 0
            }
            return rect.offsetBy(dx: shift([rect.minX, rect.maxX], xs), dy: shift([rect.minY, rect.maxY], ys))
        case .create:
            guard ratio == nil else { return rect }
            horizontal = true; vertical = true
        case .resize(let index):
            guard ratio == nil else { return rect }
            let handle = LayerTransform.handles[index]
            horizontal = handle.x != 0.5; vertical = handle.y != 0.5
        }
        var result = rect
        // The dragged edge is the one on the pointer's side.
        if horizontal {
            if abs(point.x - result.minX) <= abs(point.x - result.maxX) {
                if let x = nearest(result.minX, in: xs), x < result.maxX { result = CGRect(x: x, y: result.minY, width: result.maxX - x, height: result.height) }
            } else if let x = nearest(result.maxX, in: xs), x > result.minX { result.size.width = x - result.minX }
        }
        if vertical {
            if abs(point.y - result.minY) <= abs(point.y - result.maxY) {
                if let y = nearest(result.minY, in: ys), y < result.maxY { result = CGRect(x: result.minX, y: y, width: result.width, height: result.maxY - y) }
            } else if let y = nearest(result.maxY, in: ys), y > result.minY { result.size.height = y - result.minY }
        }
        if symmetric {
            // The snapped (dragged) edge sets the half size; the opposite edge mirrors it about the center.
            var center = CGPoint(x: drag.original.midX, y: drag.original.midY)
            if case .create = drag.mode { center = drag.start }
            if horizontal {
                let half = point.x >= center.x ? result.maxX - center.x : center.x - result.minX
                if half >= 0.5 { result.origin.x = center.x - half; result.size.width = half * 2 }
            }
            if vertical {
                let half = point.y >= center.y ? result.maxY - center.y : center.y - result.minY
                if half >= 0.5 { result.origin.y = center.y - half; result.size.height = half * 2 }
            }
        }
        return result
    }
}

extension EditorSession {
    /// What a moving layer snaps to: the canvas edges and center, and every other visible layer's upright bounds
    /// and center. The layers being moved are left out, or they would snap to where they already are.
    func transformSnapTargets(excluding moving: Set<UUID>) -> (xs: [CGFloat], ys: [CGFloat]) {
        guard let document else { return ([], []) }
        var xs: [CGFloat] = [0, document.size.width / 2, document.size.width]
        var ys: [CGFloat] = [0, document.size.height / 2, document.size.height]
        for layer in document.renderLayers where layer.asset != nil && !moving.contains(layer.id) {
            let corners = DistortWarp.corners(of: displayedTransform(for: layer))
            let cornerXs = corners.map(\.x), cornerYs = corners.map(\.y)
            guard let minX = cornerXs.min(), let maxX = cornerXs.max(),
                  let minY = cornerYs.min(), let maxY = cornerYs.max() else { continue }
            xs += [minX.rounded(), ((minX + maxX) / 2).rounded(), maxX.rounded()]
            ys += [minY.rounded(), ((minY + maxY) / 2).rounded(), maxY.rounded()]
        }
        return (xs, ys)
    }

    /// `draft` nudged so the layer it places lines up with a nearby edge or center; `moving` is what is being
    /// dragged, and `tolerance` is in document pixels.
    func snappedMove(_ draft: LayerTransform, moving: Set<UUID>, tolerance: CGFloat) -> LayerTransform {
        let corners = DistortWarp.corners(of: draft)
        let cornerXs = corners.map(\.x), cornerYs = corners.map(\.y)
        guard let minX = cornerXs.min(), let maxX = cornerXs.max(),
              let minY = cornerYs.min(), let maxY = cornerYs.max() else { return draft }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let targets = transformSnapTargets(excluding: moving)
        let snap = TransformSnap.offset(for: box, xs: targets.xs, ys: targets.ys, tolerance: tolerance)
        snapGuides = (snap.x.map { [$0] } ?? [], snap.y.map { [$0] } ?? [])
        guard snap.offset != .zero else { return draft }
        var snapped = draft
        snapped.origin.x += snap.offset.width
        snapped.origin.y += snap.offset.height
        return snapped
    }

    /// What crop edges snap to: the canvas edges and every visible layer's bounds (a rotated layer's
    /// upright bounding box), in whole document pixels.
    func cropSnapTargets() -> (xs: [CGFloat], ys: [CGFloat]) {
        guard let document else { return ([], []) }
        var xs: [CGFloat] = [0, document.size.width], ys: [CGFloat] = [0, document.size.height]
        for layer in document.renderLayers where layer.asset != nil {
            let corners = DistortWarp.corners(of: displayedTransform(for: layer))
            let cornerXs = corners.map(\.x), cornerYs = corners.map(\.y)
            guard let minX = cornerXs.min(), let maxX = cornerXs.max(), let minY = cornerYs.min(), let maxY = cornerYs.max() else { continue }
            xs += [minX.rounded(), maxX.rounded()]
            ys += [minY.rounded(), maxY.rounded()]
        }
        return (xs, ys)
    }

    /// Keep the tool frame visible without creating an uncommitted edit.
    var visibleCropRect: CGRect? {
        guard tool == .crop, let document else { return nil }
        return cropRect ?? CGRect(origin: .zero, size: document.size)
    }
    var cropRatio: CGFloat? {
        switch cropRatioChoice {
        case "Original": return document.map { CGFloat($0.width) / CGFloat($0.height) }
        case "1:1": return 1
        case "4:3": return 4 / 3
        case "16:9": return 16 / 9
        default: return nil
        }
    }
    func cancelCrop() { cropRect = nil }
    func changeCropRatio() {
        guard let rect = visibleCropRect, let ratio = cropRatio else { return }
        let height = rect.width / ratio
        let next = CropGeometry.snapped(CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
        if CropGeometry.valid(next) { cropRect = next }
    }
    func commitCrop() async {
        guard canStartProjectOperation, let rect = cropRect, CropGeometry.valid(rect),
              let snapshot = projectSnapshot() else { return }
        isProjectBusy = true
        defer { isProjectBusy = false }
        do {
            let result = try await CanvasResizer.shared.resize(snapshot,
                to: CanvasSizeOptions(width: Int(rect.width), height: Int(rect.height),
                    contentOffset: CGPoint(x: -rect.minX, y: -rect.minY)))
            cropRect = nil
            applyDocumentSize(result, actionName: L10n.string("Crop"))
        } catch { cropError = error.localizedDescription }
    }
}
