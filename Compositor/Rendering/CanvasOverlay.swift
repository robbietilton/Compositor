#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreGraphics
import Foundation

struct TransformOverlayGeometry: Equatable {
    let handles: [CGPoint]
    let rotationHandle: CGPoint
    /// A distortion has no single rotation, so its rotation handle is hidden.
    let showsRotation: Bool

    init(transform: LayerTransform, viewport: CanvasViewport, documentSize: CGSize) {
        handles = LayerTransform.handles.map { viewport.viewPoint(from: transform.point($0), documentSize: documentSize) }
        rotationHandle = CGPoint(x: handles[1].x + sin(transform.radians) * 28,
                                 y: handles[1].y - cos(transform.radians) * 28)
        showsRotation = true
    }

    /// Handles for a distortion: its four corners (document pixels) and the midpoints of its edges.
    init(corners: [CGPoint], viewport: CanvasViewport, documentSize: CGSize) {
        let view = corners.map { viewport.viewPoint(from: $0, documentSize: documentSize) }
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        handles = [view[0], middle(view[0], view[1]), view[1], middle(view[1], view[2]),
                   view[2], middle(view[2], view[3]), view[3], middle(view[3], view[0])]
        rotationHandle = handles[1]
        showsRotation = false
    }

    func hit(_ point: CGPoint) -> TransformDrag.Mode? {
        func near(_ other: CGPoint) -> Bool { hypot(point.x - other.x, point.y - other.y) <= 10 }
        if showsRotation, near(rotationHandle) { return .rotate }
        if let index = handles.firstIndex(where: near) { return .resize(index) }
        for (start, end, handle) in [(0, 2, 1), (2, 4, 3), (4, 6, 5), (6, 0, 7)] {
            let a = handles[start], b = handles[end]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { continue }
            let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
            if (0...1).contains(t), hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) <= 10 {
                return .resize(handle)
            }
        }
        return nil
    }
}

/// What's drawn over the canvas, the same on the Mac and iPad: the layout grid and guides; the crop frame, a
/// gradient's or Progressive Blur's line or the transform box; the selection's marching ants and an outline being drawn; and the lines a
/// move snaps to. A view showing it draws it into its own context; it never draws image pixels, so selecting a layer
/// doesn't redraw them.
@MainActor final class CanvasOverlay {
    let session: EditorSession
    /// Asks the view to draw again, when a simplified selection outline is ready.
    var needsDisplay: () -> Void = {}
    var antsPhase: CGFloat = 0

    init(session: EditorSession) {
        self.session = session
    }

    var geometry: TransformOverlayGeometry? {
        guard session.tool == .move, session.showsTransformControls || session.transformEdit?.persistent == true,
              let document = session.document else { return nil }
        // Several layers selected, or a folder: one box around them all.
        if session.transformEdit?.group != nil || (session.transformEdit == nil && session.transformsAsGroup) {
            if let corners = session.transformEdit?.corners {
                return TransformOverlayGeometry(corners: corners, viewport: session.viewport, documentSize: document.size)
            }
            guard let box = session.transformEdit?.draft ?? session.groupTransformBox else { return nil }
            return TransformOverlayGeometry(transform: box, viewport: session.viewport, documentSize: document.size)
        }
        guard let layer = session.activeLayer, layer.asset != nil, !layer.isGroup, document.effectiveVisibleIDs.contains(layer.id) else { return nil }
        if let edit = session.transformEdit, edit.layerID == layer.id, let corners = edit.corners {
            return TransformOverlayGeometry(corners: corners, viewport: session.viewport, documentSize: document.size)
        }
        return TransformOverlayGeometry(transform: session.editedTransform(for: layer),
                                        viewport: session.viewport, documentSize: document.size)
    }

    /// Pending gradient endpoints in view coordinates.
    var gradientLine: (start: CGPoint, end: CGPoint)? {
        guard let edit = session.gradientEdit, edit.hasLine, let document = session.document else { return nil }
        return (session.viewport.viewPoint(from: edit.start, documentSize: document.size),
                session.viewport.viewPoint(from: edit.end, documentSize: document.size))
    }

    /// Progressive Blur's line in view coordinates while its panel is open, and whether it's radial.
    var progressiveLine: (start: CGPoint, end: CGPoint, radial: Bool)? {
        guard let edit = session.filterEdit, edit.kind == .progressiveBlur, let start = edit.settings.progressiveStart,
              let end = edit.settings.progressiveEnd, let document = session.document else { return nil }
        return (session.viewport.viewPoint(from: start, documentSize: document.size),
                session.viewport.viewPoint(from: end, documentSize: document.size), edit.settings.progressiveRadial)
    }

    /// RGB Split's center in view coordinates while its panel is open on Radial.
    var rgbSplitCenter: CGPoint? {
        guard let edit = session.filterEdit, edit.kind == .rgbSplit, edit.settings.rgbSplitRadial,
              let center = edit.settings.rgbSplitCenter, let document = session.document else { return nil }
        return session.viewport.viewPoint(from: center, documentSize: document.size)
    }

    /// Volumetric Light's light in view coordinates while its panel is open.
    var volumetricLight: CGPoint? {
        guard let edit = session.filterEdit, edit.kind == .volumetricLight,
              let center = edit.settings.volumetric.center, let document = session.document else { return nil }
        return session.viewport.viewPoint(from: center, documentSize: document.size)
    }

    // MARK: Marching ants level of detail
    //
    // A Magic Wand outline on detailed artwork can have hundreds of thousands of edges, one per pixel step. Stroked in
    // full every tick, zoomed out they pile into a few screen pixels and one redraw can take seconds, which froze the
    // app. Below 1:1 a complex outline is drawn from one traced at screen resolution instead: built in the background,
    // cached per power-of-two zoom step, so it never has more edges than the screen has pixels to show.

    /// Outlines at or under this many path elements are always drawn in full; marquees and lassos stay exact.
    private static let fullDetailLimit = 20_000
    private var antsSource: CGPath?
    private var antsSourceIsComplex = false
    /// The screen-resolution outline in document coordinates, and the zoom step it was traced for.
    private var antsLevel: (path: CGPath, step: CGFloat)?
    private var antsPendingStep: CGFloat?
    private var antsTask: Task<Void, Never>?

    /// What the ants stroke: the selection itself, or when zoomed out on a complex one, its screen-resolution outline.
    /// Nil while the first simplified outline is still being traced. `deviceScale` is device pixels to a point.
    private func antsOutline(for path: CGPath, deviceScale: CGFloat) -> CGPath? {
        if antsSource !== path {
            antsSource = path
            antsTask?.cancel()
            antsTask = nil
            antsLevel = nil
            antsPendingStep = nil
            var elements = 0
            path.applyWithBlock { _ in elements += 1 }
            antsSourceIsComplex = elements > Self.fullDetailLimit
        }
        let scale = session.viewport.pointsPerPixel * deviceScale
        guard antsSourceIsComplex, scale < 1, let document = session.document else { return path }
        // Screen pixels per document pixel, rounded up to a power of two so zooming doesn't retrace on every frame.
        let step = min(1, pow(2, ceil(log2(max(scale, 1 / 4096)))))
        if antsLevel?.step != step, antsPendingStep != step {
            antsPendingStep = step
            antsTask?.cancel()
            let canvas = CGRect(origin: .zero, size: document.size)
            antsTask = Task { [weak self] in
                let traced = await Task.detached(priority: .userInitiated) { Self.traceOutline(path, canvas: canvas, step: step) }.value
                guard let self, !Task.isCancelled, self.antsSource === path, self.antsPendingStep == step else { return }
                self.antsPendingStep = nil
                if let traced { self.antsLevel = (traced, step) }
                self.needsDisplay()
            }
        }
        // Until the new step is traced, the last one stands in: a little coarse or fine for a moment, never slow.
        return antsLevel?.path
    }

    /// `path` filled into a mask fine enough to fill quickly, averaged down to `step` screen pixels per document pixel,
    /// and traced along those pixels' edges. Any coverage counts, so thin parts stay outlined rather than vanishing.
    private nonisolated static func traceOutline(_ path: CGPath, canvas: CGRect, step: CGFloat) -> CGPath? {
        let region = path.boundingBoxOfPath.intersection(canvas).integral
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        // Filling costs about as much as the edges each output pixel has to sort through, so the mask is filled at no
        // less than half resolution and at most about 40 megapixels.
        let fill = min(1, max(step, (40_000_000 / (region.width * region.height)).squareRoot()))
        func mask(_ width: Int, _ height: Int) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        let fillWidth = max(1, Int((region.width * fill).rounded(.up))), fillHeight = max(1, Int((region.height * fill).rounded(.up)))
        guard let filled = mask(fillWidth, fillHeight) else { return nil }
        // Top-left origin, so a mask row is a document row, as the tracer expects.
        filled.translateBy(x: 0, y: CGFloat(fillHeight))
        filled.scaleBy(x: fill, y: -fill)
        filled.translateBy(x: -region.minX, y: -region.minY)
        filled.addPath(path)
        filled.setFillColor(gray: 1, alpha: 1)
        filled.fillPath(using: .winding)
        guard let image = filled.makeImage() else { return nil }
        let width = max(1, Int((region.width * step).rounded(.up))), height = max(1, Int((region.height * step).rounded(.up)))
        guard let small = mask(width, height) else { return nil }
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = small.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let line = bytes + row * small.bytesPerRow
            for column in 0..<width where line[column] > 0 { pixels[row * width + column] = 255 }
        }
        guard let traced = try? MagicWand.outline(of: pixels, width: width, height: height) else { return nil }
        var toDocument = CGAffineTransform(translationX: region.minX, y: region.minY).scaledBy(x: 1 / step, y: 1 / step)
        return traced.copy(using: &toDocument)
    }

    // MARK: Drawing

    /// Draws the overlay into `context`, which draws y down over a view of `bounds`, with `deviceScale` device pixels
    /// to a point.
    func draw(in context: CGContext, bounds: CGRect, deviceScale: CGFloat) {
        drawLayoutGrid(in: context)
        drawGuides(in: context, bounds: bounds)
        if let line = progressiveLine { drawProgressiveLine(line, in: context) }
        if let center = rgbSplitCenter ?? volumetricLight { drawRGBSplitCenter(center, in: context) }
        else if session.tool == .crop { drawCrop(in: context, bounds: bounds) }
        else if let line = gradientLine { drawGradientLine(line, in: context) }
        else { drawTransformHandles(in: context) }
        drawSelection(in: context, deviceScale: deviceScale)
        drawLassoDraft(in: context)
        drawSnapGuides(in: context)
    }

    /// Non-printing layout grid over the document: majors in the chosen style, dotted subdivisions, both in the
    /// chosen color.
    private func drawLayoutGrid(in context: CGContext) {
        guard session.showsGrid, let document = session.document, let transform = documentToView else { return }
        let grid = session.layoutGrid
        let appearance = session.gridAppearance
        let color = PlatformColor(srgbRed: appearance.color.red, green: appearance.color.green, blue: appearance.color.blue, alpha: 1)
        let size = document.size
        let scale = session.viewport.pointsPerPixel
        let hairline = 1 / max(session.viewport.backingScale, 1)
        let subdivisionGap = grid.step * scale
        context.saveGState()
        context.concatenate(transform)
        context.setLineWidth(hairline / max(scale, 0.0001))
        context.setStrokeColor(color.withAlphaComponent(appearance.subdivisionAlpha).cgColor)
        if subdivisionGap >= 4 {
            context.setLineDash(phase: 0, lengths: [1 / max(scale, 0.0001), 2 / max(scale, 0.0001)])
            let path = CGMutablePath()
            for x in grid.lines(along: size.width) where !grid.isMajor(x) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in grid.lines(along: size.height) where !grid.isMajor(y) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.addPath(path)
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: appearance.style.dashes.map { $0 / max(scale, 0.0001) })
        context.setStrokeColor(color.withAlphaComponent(appearance.majorAlpha).cgColor)
        let majors = CGMutablePath()
        for x in grid.lines(along: size.width) where grid.isMajor(x) {
            majors.move(to: CGPoint(x: x, y: 0))
            majors.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in grid.lines(along: size.height) where grid.isMajor(y) {
            majors.move(to: CGPoint(x: 0, y: y))
            majors.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.addPath(majors)
        context.strokePath()
        context.restoreGState()
    }

    /// User guides span the whole view, including the pasteboard.
    private func drawGuides(in context: CGContext, bounds: CGRect) {
        guard session.showsGuides, let document = session.document else { return }
        let guides = session.displayedGuides
        guard !guides.isEmpty else { return }
        context.saveGState()
        context.setStrokeColor(EditorSession.guideColor)
        context.setLineWidth(1 / max(session.viewport.backingScale, 1))
        for guide in guides {
            if guide.axis == .vertical {
                let x = session.viewport.viewPoint(from: CGPoint(x: guide.position, y: 0), documentSize: document.size).x
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: bounds.height))
            } else {
                let y = session.viewport.viewPoint(from: CGPoint(x: 0, y: guide.position), documentSize: document.size).y
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: bounds.width, y: y))
            }
        }
        context.strokePath()
        context.restoreGState()
    }

    /// While a move is snapped, a line along what it lined up with, across the whole canvas.
    private func drawSnapGuides(in context: CGContext) {
        let guides = session.snapGuides
        guard !guides.xs.isEmpty || !guides.ys.isEmpty, let document = session.document,
              let transform = documentToView else { return }
        context.saveGState()
        context.setStrokeColor(Platform.accentColor.cgColor)
        context.setLineWidth(1)
        for x in guides.xs {
            context.move(to: CGPoint(x: x, y: 0).applying(transform))
            context.addLine(to: CGPoint(x: x, y: document.size.height).applying(transform))
        }
        for y in guides.ys {
            context.move(to: CGPoint(x: 0, y: y).applying(transform))
            context.addLine(to: CGPoint(x: document.size.width, y: y).applying(transform))
        }
        context.strokePath()
        context.restoreGState()
    }

    private var documentToView: CGAffineTransform? {
        guard let document = session.document else { return nil }
        let origin = session.viewport.documentRect(document.size).origin
        let scale = session.viewport.pointsPerPixel
        return CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)
    }

    /// Marching ants: a white line under an animated black dash.
    private func drawSelection(in context: CGContext, deviceScale: CGFloat) {
        guard let selection = session.displayedSelection, !selection.isEmpty, var transform = documentToView,
              let outline = antsOutline(for: selection.path, deviceScale: deviceScale),
              let path = outline.copy(using: &transform) else { return }
        context.saveGState()
        context.setLineWidth(1)
        context.addPath(path)
        context.setStrokeColor(PlatformColor.white.cgColor)
        context.strokePath()
        context.addPath(path)
        context.setLineDash(phase: antsPhase, lengths: [4, 4])
        context.setStrokeColor(PlatformColor.black.cgColor)
        context.strokePath()
        context.restoreGState()
    }

    private func drawLassoDraft(in context: CGContext) {
        guard let draft = session.lassoDraft, let transform = documentToView else { return }
        var points = draft.points.map { $0.applying(transform) }
        if draft.kind == .polygonal, let cursor = draft.cursor { points.append(cursor.applying(transform)) }
        guard let first = points.first else { return }
        context.saveGState()
        let path = CGMutablePath()
        if draft.kind == .ellipse, points.count == 4 {
            let xs = points.map(\.x), ys = points.map(\.y)
            path.addEllipse(in: CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
        } else {
            path.addLines(between: points)
            if draft.kind == .rectangle { path.closeSubpath() }
        }
        context.addPath(path)
        context.setStrokeColor(PlatformColor.black.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(2)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(PlatformColor.white.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        if draft.kind == .polygonal {
            // The first corner: click it to close the outline.
            let handle = CGRect(x: first.x - 4, y: first.y - 4, width: 8, height: 8)
            context.setFillColor(PlatformColor.white.cgColor)
            context.fill(handle)
            context.setStrokeColor(PlatformColor.black.cgColor)
            context.stroke(handle)
        }
        context.restoreGState()
    }

    private func drawTransformHandles(in context: CGContext) {
        guard let geometry else { return }
        let path = CGMutablePath()
        path.move(to: geometry.handles[0])
        for index in [2, 4, 6] { path.addLine(to: geometry.handles[index]) }
        path.closeSubpath()
        if geometry.showsRotation {
            path.move(to: geometry.handles[1])
            path.addLine(to: geometry.rotationHandle)
        }
        // Just the accent line: a dark line behind it read as a grey halo around the box.
        context.addPath(path)
        context.setStrokeColor(Platform.accentColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.setFillColor(PlatformColor.white.cgColor)
        context.setStrokeColor(Platform.accentColor.cgColor)
        for point in geometry.handles {
            let rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            context.fill(rect)
            context.stroke(rect)
        }
        guard geometry.showsRotation else { return }
        let point = geometry.rotationHandle
        let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        context.fillEllipse(in: rect)
        context.strokeEllipse(in: rect)
    }

    var cropViewRect: CGRect? {
        guard let rect = session.visibleCropRect, let document = session.document else { return nil }
        return CGRect(origin: session.viewport.viewPoint(from: rect.origin, documentSize: document.size),
                      size: CGSize(width: rect.width * session.viewport.pointsPerPixel,
                                   height: rect.height * session.viewport.pointsPerPixel))
    }
    var cropHandles: [CGPoint] {
        guard let rect = cropViewRect else { return [] }
        return LayerTransform.handles.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
    }
    var cropResizeRegions: [(index: Int, rect: CGRect)] {
        guard let rect = cropViewRect else { return [] }
        let handles = cropHandles
        let radius: CGFloat = 10
        var regions = [0, 2, 4, 6].map { index in
            (index: index, rect: CGRect(x: handles[index].x - radius, y: handles[index].y - radius,
                                        width: radius * 2, height: radius * 2))
        }
        // Entire edges are draggable, not just the small midpoint squares.
        for index in [1, 5] {
            regions.append((index, CGRect(x: rect.minX + radius, y: handles[index].y - radius,
                width: max(0, rect.width - radius * 2), height: radius * 2)))
        }
        for index in [3, 7] {
            regions.append((index, CGRect(x: handles[index].x - radius, y: rect.minY + radius,
                width: radius * 2, height: max(0, rect.height - radius * 2))))
        }
        return regions
    }
    /// A crosshair in a ring, where RGB Split spreads out from, or where Volumetric Light's light is.
    private func drawRGBSplitCenter(_ center: CGPoint, in context: CGContext) {
        context.saveGState()
        for (width, color) in [(3.0, PlatformColor.black.withAlphaComponent(0.7)), (1.0, PlatformColor.white)] {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.strokeEllipse(in: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
            context.move(to: CGPoint(x: center.x - 12, y: center.y)); context.addLine(to: CGPoint(x: center.x - 4, y: center.y))
            context.move(to: CGPoint(x: center.x + 4, y: center.y)); context.addLine(to: CGPoint(x: center.x + 12, y: center.y))
            context.move(to: CGPoint(x: center.x, y: center.y - 12)); context.addLine(to: CGPoint(x: center.x, y: center.y - 4))
            context.move(to: CGPoint(x: center.x, y: center.y + 4)); context.addLine(to: CGPoint(x: center.x, y: center.y + 12))
            context.strokePath()
        }
        context.restoreGState()
    }
    /// Progressive Blur's line: a solid handle where it's sharp, a hollow one where it's fully blurred, and for a radial
    /// one the circle it reaches full blur at.
    private func drawProgressiveLine(_ line: (start: CGPoint, end: CGPoint, radial: Bool), in context: CGContext) {
        context.saveGState()
        if line.radial {
            let radius = hypot(line.end.x - line.start.x, line.end.y - line.start.y)
            let rim = CGRect(x: line.start.x - radius, y: line.start.y - radius, width: radius * 2, height: radius * 2)
            context.setLineDash(phase: 0, lengths: [4, 4])
            context.setStrokeColor(PlatformColor.black.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: rim)
            context.setStrokeColor(PlatformColor.white.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: rim)
            context.setLineDash(phase: 0, lengths: [])
        }
        for (width, color) in [(3.0, PlatformColor.black.withAlphaComponent(0.7)), (1.0, PlatformColor.white)] {
            context.move(to: line.start)
            context.addLine(to: line.end)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.strokePath()
        }
        context.setStrokeColor(PlatformColor.black.cgColor)
        context.setLineWidth(1)
        // Sharp: a solid handle.
        let sharp = CGRect(x: line.start.x - 6, y: line.start.y - 6, width: 12, height: 12)
        context.setFillColor(PlatformColor.white.cgColor)
        context.fillEllipse(in: sharp)
        context.strokeEllipse(in: sharp)
        // Blurred: a ring, soft gray inside.
        let blurred = CGRect(x: line.end.x - 6, y: line.end.y - 6, width: 12, height: 12)
        context.setFillColor(PlatformColor(white: 0.6, alpha: 0.9).cgColor)
        context.fillEllipse(in: blurred)
        context.setStrokeColor(PlatformColor.white.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: blurred.insetBy(dx: 1, dy: 1))
        context.setStrokeColor(PlatformColor.black.cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: blurred)
        context.restoreGState()
    }
    private func drawGradientLine(_ line: (start: CGPoint, end: CGPoint), in context: CGContext) {
        context.saveGState()
        if session.gradientSettings.shape == .radial {
            // Faint rim where the radial gradient reaches its end color.
            let radius = hypot(line.end.x - line.start.x, line.end.y - line.start.y)
            let rim = CGRect(x: line.start.x - radius, y: line.start.y - radius, width: radius * 2, height: radius * 2)
            context.setLineDash(phase: 0, lengths: [4, 4])
            context.setStrokeColor(PlatformColor.black.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: rim)
            context.setStrokeColor(PlatformColor.white.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: rim)
            context.setLineDash(phase: 0, lengths: [])
        }
        context.move(to: line.start)
        context.addLine(to: line.end)
        context.setStrokeColor(PlatformColor.black.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(3)
        context.strokePath()
        context.move(to: line.start)
        context.addLine(to: line.end)
        context.setStrokeColor(PlatformColor.white.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.setStrokeColor(PlatformColor.black.cgColor)
        context.setLineWidth(1)
        for (point, color) in [(line.start, session.gradientColors(mask: false).first), (line.end, session.gradientColors(mask: false).last)] {
            let rect = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
            context.setFillColor(PlatformColor.white.cgColor)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
            // Checkerboard shows through transparent ends.
            let inner = rect.insetBy(dx: 2.5, dy: 2.5)
            context.setFillColor(PlatformColor(white: 0.75, alpha: 1).cgColor)
            context.fillEllipse(in: inner)
            if let color { context.setFillColor(color); context.fillEllipse(in: inner) }
        }
        context.restoreGState()
    }

    private func drawCrop(in context: CGContext, bounds: CGRect) {
        guard let rect = cropViewRect else { return }
        context.saveGState()
        context.addRect(bounds)
        context.addRect(rect)
        context.setFillColor(PlatformColor.black.withAlphaComponent(0.6).cgColor)
        context.drawPath(using: .eoFill)
        context.setStrokeColor(PlatformColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(rect)
        context.setStrokeColor(PlatformColor.white.withAlphaComponent(0.4).cgColor)
        for index in 1...2 {
            let fraction = CGFloat(index) / 3
            context.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            context.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        context.strokePath()
        context.setFillColor(PlatformColor.white.cgColor)
        context.setStrokeColor(PlatformColor.black.cgColor)
        for point in cropHandles {
            let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.fill(handle)
            context.stroke(handle)
        }
        context.restoreGState()
    }
}
