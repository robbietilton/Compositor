import CoreGraphics
import CoreImage

/// The shape being dragged out with the Shape tool, as the canvases draw it: just above the active layer, where its layer
/// will go, in the color it will be made in.
extension EditorSession {
    /// Draws the shape into `context`, `scale` of its pixels to a document pixel, with `center` taking a document point
    /// to it.
    func drawShapeDraft(scale: CGFloat, center: (CGPoint) -> CGPoint, in context: CGContext) {
        // A flat or upright line has a box with no height or width, which is not "empty" for this purpose.
        guard let draft = shapeDraft,
              draft.kind == .line ? (draft.rect.width > 0 || draft.rect.height > 0) : !draft.rect.isEmpty else { return }
        let middle = center(CGPoint(x: draft.rect.midX, y: draft.rect.midY))
        let rect = CGRect(x: middle.x - draft.rect.width * scale / 2, y: middle.y - draft.rect.height * scale / 2,
                          width: draft.rect.width * scale, height: draft.rect.height * scale)
        let color = CGColor(srgbRed: foregroundColor.red, green: foregroundColor.green, blue: foregroundColor.blue, alpha: 1)
        context.saveGState()
        context.setFillColor(color)
        if draft.kind == .line {
            guard let ends = shapeLineEnds else { context.restoreGState(); return }
            let thickness = max(1, CGFloat(shapeLineWidth) * scale)
            context.setStrokeColor(color)
            context.setLineWidth(thickness)
            context.setLineCap(.round)
            // Exactly the two points being dragged between, so the start never shifts.
            context.move(to: center(ends.start))
            context.addLine(to: center(ends.end))
            context.strokePath()
        } else {
            context.addPath(draft.kind.path(in: rect, cornerRadius: draft.cornerRadius * scale))
            context.fillPath()
        }
        context.restoreGState()
    }

    /// The shape drawn by `drawShapeDraft` into a bitmap just big enough for it, in the frame's pixels.
    func shapeDraftImage(placement: GPUPlacement) -> CIImage? {
        guard let draft = shapeDraft, let renderer = GPUCanvasRenderer.shared else { return nil }
        let reach = CGFloat(shapeLineWidth) * placement.scale + 4
        let box = draft.rect.applying(placement.mapping).insetBy(dx: -reach, dy: -reach).integral
        guard box.width >= 1, box.height >= 1, box.width * box.height <= DocumentLimits.maxSurfaceExtent,
              let context = try? BrushRaster.context(width: Int(box.width), height: Int(box.height), mask: false) else { return nil }
        context.translateBy(x: -box.minX, y: -box.minY)
        drawShapeDraft(scale: placement.scale, center: { $0.applying(placement.mapping) }, in: context)
        guard let image = context.makeImage(), let drawn = renderer.image(image, transient: true) else { return nil }
        return drawn.transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
    }
}
