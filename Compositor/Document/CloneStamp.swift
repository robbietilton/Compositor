import AppKit

/// Clone Stamp's options-bar settings.
nonisolated struct CloneSettings: Equatable, Sendable {
    /// The source moves with the brush and keeps its offset between strokes; off, every stroke
    /// starts again at the source point.
    var aligned = true
    /// Copy from every visible layer as shown rather than the active layer alone.
    var sampleAllLayers = false
}

extension EditorSession {
    /// Option-click: where Clone Stamp copies from. A new source starts a new alignment.
    func setCloneSource(_ point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        cloneSource = point
        cloneOffset = nil
    }

    /// The whole-pixel offset a stroke starting at `point` would copy with: aligned strokes keep
    /// the first stroke's; otherwise it runs from the brush to the source. Nil without a source.
    /// Shared by the stroke and the hover preview, so the preview is exactly what a click stamps.
    func cloneStrokeOffset(at point: CGPoint) -> CGSize? {
        guard let cloneSource else { return nil }
        return (cloneSettings.aligned ? cloneOffset : nil)
            ?? CGSize(width: (cloneSource.x - point.x).rounded(), height: (cloneSource.y - point.y).rounded())
    }

    /// Where the source sits for a brush at `point` (document pixels), for the canvas's
    /// crosshair: the source itself until a stroke fixes the offset.
    func cloneSamplePoint(for point: CGPoint) -> CGPoint? {
        guard let cloneSource else { return nil }
        guard let cloneOffset, cloneSettings.aligned || brushStroke != nil else { return cloneSource }
        return CGPoint(x: point.x + cloneOffset.width, y: point.y + cloneOffset.height)
    }

    /// What `stroke` copies from, taken when it starts, placed `offset` document pixels from where it paints: the
    /// layer's own pixels, at their own resolution; or, sampling all layers, the canvas as it shows them.
    func cloneSample(_ document: CanvasDocument, for stroke: BrushStroke, offset: CGSize) -> (image: CGImage, placed: CGRect, inGrid: Bool)? {
        guard cloneSettings.sampleAllLayers else {
            guard let image = stroke.layer.asset?.image else { return nil }
            return (image, stroke.gridRect(stroke.sourceRect, copyingFrom: offset), true)
        }
        guard let context = try? BrushRaster.context(width: document.width, height: document.height, mask: false) else { return nil }
        drawLiveComposite(document, in: context)
        guard let image = context.makeImage() else { return nil }
        return (image, CGRect(x: -offset.width, y: -offset.height, width: CGFloat(image.width), height: CGFloat(image.height)), false)
    }
}
