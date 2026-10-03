import UIKit

/// What a touch does with the tools, all but the Hand, and with Clone Stamp's source, as the Mac's canvas does with the
/// mouse, apart from UIKit's touches: a press, drag and lift at points in the canvas's coordinates, with the keys a
/// hardware keyboard holds. The iPad canvas feeds it touches; tests feed it points.
@MainActor final class PadCanvasInput {
    let session: EditorSession
    /// Asks for the overlay to be drawn again though nothing it observes changed, as the lines a drag snaps to.
    var overlayChanged: () -> Void = {}
    /// Work a press started and left running, such as the Magic Wand's: tests wait for it.
    private(set) var pending: Task<Void, Never>?
    /// Text on the canvas opened for editing by a touch at this point, in the canvas's coordinates, where the canvas puts
    /// the caret.
    var textOpened: (CGPoint) -> Void = { _ in }
    /// The box being dragged out for new text, in document pixels, for the overlay to draw.
    private(set) var textBox: CGRect?
    /// The Eyedropper's ring while a touch samples: the color under the touch at `point`, in the canvas's coordinates,
    /// and the foreground color it replaced; nil once the touch lifts.
    var sampleChanged: ((point: CGPoint, color: PaletteColor, original: PaletteColor)?) -> Void = { _ in }

    /// How far a finger may land from a handle, or from a polygonal lasso's first corner to close it.
    static let reach: CGFloat = 22
    /// How close, in points, a crop edge comes to a layer or canvas edge before it snaps, as on the Mac.
    static let cropSnapDistance: CGFloat = 8

    private lazy var overlay = CanvasOverlay(session: session)
    private enum Drag {
        /// A brush stroke, which last reached `last`, in document pixels.
        case paint(last: CGPoint)
        /// The Eyedropper taking colors, and the foreground color it replaced.
        case sample(original: PaletteColor)
        /// The Zoom tool, as on the Mac: a tap zooms in, a drag right or left zooms smoothly in or out.
        case zoom(start: CGPoint, zoom: CGFloat, moved: Bool)
        /// The Move tool: a handle or the layer, and whether its first step drags a copy (Option).
        case transform(TransformDrag, duplicates: Bool)
        /// A marquee or lasso outline being drawn.
        case outline
        /// The next corner of a polygonal lasso, placed where the touch lifts.
        case corner
        /// The selection's outline, dragged from `start`.
        case selection(start: CGPoint)
        /// The selected pixels, cut or copied (Command, Option) and dragged from `start`.
        case pixels(start: CGPoint)
        /// The crop frame drawn, moved or resized, snapping to `snap`; `before` is the frame it had.
        case crop(CropDrag, snap: CropSnap, before: CGRect?)
        /// An end of the gradient's line: the line as it was, or nil when the drag made the gradient.
        case gradient(GradientEnd, before: (start: CGPoint, end: CGPoint)?)
        /// A shape being dragged out.
        case shape
        /// A box for new text, dragged out from `anchor`.
        case textBox(anchor: CGPoint)
        /// Clone Stamp's source, `grab` from the touch, and the source and alignment it had.
        case cloneSource(grab: CGSize, before: (source: CGPoint?, offset: CGSize?))
    }
    enum GradientEnd { case start, end }
    private var drag: Drag?
    /// Whether Shift squares a marquee: a Shift already held at the press chose Add instead, until it's let go.
    private var squareArmed = false
    /// Where the last Clone Stamp stroke ended, in document pixels.
    private var cloneStrokeEnd: CGPoint?

    init(session: EditorSession) {
        self.session = session
    }

    /// Whether this handles touches with `tool`.
    static func handles(_ tool: NavigationTool) -> Bool {
        tool == .move || tool == .crop || tool == .gradient || tool == .shape || tool == .type || tool.isSelectionTool
            || tool.isBrushTool || tool == .eyedropper || tool == .zoom
    }

    var isDragging: Bool { drag != nil }
    /// Whether a touch is drawing a brush stroke.
    var isPainting: Bool {
        if case .paint = drag { return true }
        return false
    }

    private func pixel(_ point: CGPoint) -> CGPoint? {
        session.document.map { session.viewport.documentPoint(from: point, documentSize: $0.size) }
    }

    /// A touch coming down at `point`, the `tapCount`th in quick succession. False when it starts nothing to follow, as
    /// a tap with the Magic Wand.
    @discardableResult
    func began(at point: CGPoint, keys: UIKeyModifierFlags = [], tapCount: Int = 1) -> Bool {
        guard let pixel = pixel(point) else { return false }
        if session.tool.isBrushTool {
            session.beginBrush(at: pixel)
            drag = .paint(last: pixel)
            return true
        }
        if session.tool == .eyedropper {
            let original = session.foregroundColor
            drag = .sample(original: original)
            sample(at: point, pixel: pixel, original: original)
            return true
        }
        if session.tool == .zoom {
            drag = .zoom(start: point, zoom: session.viewport.zoom, moved: false)
            return true
        }
        // A double tap on text with the Move tool opens it, as a double click does on the Mac.
        if session.tool == .move, tapCount >= 2, session.canEditLayers, let layer = liveText(at: pixel) {
            session.commitTransform()
            openText(layer, at: point)
            return false
        }
        if session.tool == .type {
            // Text being typed is kept first, as on the Mac. Then a touch on text opens it; anywhere else a drag draws a
            // box for new text, and a tap starts a line of it.
            guard session.finishText() else { return false }
            if let layer = liveText(at: pixel) {
                openText(layer, at: point)
                return false
            }
            textBox = CGRect(origin: pixel, size: .zero)
            drag = .textBox(anchor: pixel)
            return true
        }
        if session.tool == .move {
            // A handle of the transform box, or else the layer under the touch when Auto Select is on, as the Mac's
            // Move tool picks it. Command flips Auto Select, Command-Shift adds the layer to the selection, Command on
            // a handle distorts and Option drags a copy.
            let handle = overlay.geometry?.hit(touch: point, reach: Self.reach)
            guard let transform = session.beginTransformDrag(at: pixel, handle: handle, command: keys.contains(.command),
                                                             shift: keys.contains(.shift)) else { return false }
            if case .move = transform.mode { drag = .transform(transform, duplicates: keys.contains(.alternate)) }
            else { drag = .transform(transform, duplicates: false) }
            return true
        }
        if session.tool == .crop {
            beginCrop(at: point, pixel: pixel)
            return true
        }
        if session.tool == .gradient { return beginGradient(at: point, pixel: pixel) }
        if session.tool == .shape {
            session.beginShape(at: snappedCorner(pixel, keys: keys))
            guard session.shapeDraft != nil else { return false }
            drag = .shape
            return true
        }
        guard session.tool.isSelectionTool else { return false }
        squareArmed = !keys.contains(.shift)
        // A polygonal lasso already begun: the next corner follows the finger and goes down where it lifts.
        if session.lassoDraft?.kind == .polygonal {
            session.moveLassoCursor(to: pixel)
            drag = .corner
            return true
        }
        // Command inside the selection cuts and moves its pixels, and Option with it copies them, as on the Mac.
        if keys.contains(.command), session.canMoveSelection(at: pixel) {
            guard session.beginPixelMove(duplicate: keys.contains(.alternate)) else { Platform.beep(); return false }
            drag = .pixels(start: pixel)
            return true
        }
        let mode = session.selectionMode(shift: keys.contains(.shift), option: keys.contains(.alternate))
        // In New mode a drag inside the selection moves its outline rather than drawing another.
        if mode == .replace, session.canMoveSelection(at: pixel), session.beginSelectionMove() {
            drag = .selection(start: pixel)
            return true
        }
        if session.tool == .wand {
            select(at: pixel, mode: mode)
            return false
        }
        session.beginLasso(at: session.tool == .marquee ? snappedCorner(pixel, keys: keys) : pixel, mode: mode)
        drag = .outline
        return true
    }

    func moved(to point: CGPoint, keys: UIKeyModifierFlags = []) {
        guard let drag, let pixel = pixel(point) else { return }
        switch drag {
        case .paint:
            session.continueBrush(at: pixel)
            self.drag = .paint(last: pixel)
        case .sample(let original):
            sample(at: point, pixel: pixel, original: original)
        case .zoom(let start, let zoom, var moved):
            let dx = point.x - start.x
            if abs(dx) >= 3 { moved = true }
            // Doubling for every 100 points dragged, as on the Mac.
            if moved { session.zoom(to: zoom * pow(2, dx / 100), anchor: start) }
            self.drag = .zoom(start: start, zoom: zoom, moved: moved)
        case .transform(let transform, let duplicates):
            if duplicates {
                self.drag = .transform(transform, duplicates: false)
                session.beginDuplicateTransform()
            }
            session.dragTransform(transform, to: pixel, shift: keys.contains(.shift), option: keys.contains(.alternate),
                                  control: keys.contains(.control))
            overlayChanged()
        case .outline:
            switch session.lassoDraft?.kind {
            case .freehand: session.extendLasso(to: pixel)
            case .polygonal: session.moveLassoCursor(to: pixel)
            case .rectangle, .ellipse:
                if !keys.contains(.shift) { squareArmed = true }
                session.dragMarquee(to: snappedCorner(pixel, keys: keys), square: squareArmed && keys.contains(.shift), fromCenter: false)
                overlayChanged()
            case nil: break
            }
        case .corner:
            session.moveLassoCursor(to: pixel)
        case .selection(let start):
            var offset = CGSize(width: pixel.x - start.x, height: pixel.y - start.y)
            var horizontal = true, vertical = true
            // Shift keeps the move on one axis, whichever the drag has gone further along.
            if keys.contains(.shift) {
                if abs(offset.width) >= abs(offset.height) { offset.height = 0; vertical = false }
                else { offset.width = 0; horizontal = false }
            }
            // It snaps to View > Snap To targets as a drawn Marquee does, unless Control is held.
            if keys.contains(.control) { session.snapGuides = ([], []) }
            else {
                offset = session.snappedSelectionOffset(offset, tolerance: TransformSnap.distance / max(session.viewport.pointsPerPixel, 0.0001),
                                                        horizontal: horizontal, vertical: vertical)
            }
            session.moveSelection(by: offset)
            overlayChanged()
        case .pixels(let start):
            var offset = CGSize(width: pixel.x - start.x, height: pixel.y - start.y)
            if keys.contains(.shift) {
                if abs(offset.width) >= abs(offset.height) { offset.height = 0 } else { offset.width = 0 }
            }
            session.movePixels(by: offset)
        case .crop(let crop, let snap, _):
            guard !session.isProjectBusy else { return }
            // Option keeps the frame's center where it is, and Control drags without snapping, as on the Mac.
            let symmetric = keys.contains(.alternate)
            var next = crop.updated(to: pixel, ratio: session.cropRatio, symmetric: symmetric)
            if session.snappingEnabled, !keys.contains(.control) {
                next = snap.apply(next, drag: crop, point: pixel, ratio: session.cropRatio, symmetric: symmetric)
            }
            if CropGeometry.valid(next) { session.cropRect = next }
        case .gradient(let end, _):
            guard let edit = session.gradientEdit else { return }
            // Shift turns the line to 45° steps about its other end.
            let pixel = keys.contains(.shift) ? GradientEdit.constrained(pixel, around: end == .start ? edit.end : edit.start) : pixel
            session.moveGradient(start: end == .start ? pixel : nil, end: end == .end ? pixel : nil)
            overlayChanged()
        case .shape:
            // Shift squares the shape, or turns a line to 45° steps; Option grows it from its center.
            session.dragShape(to: snappedCorner(pixel, keys: keys), square: keys.contains(.shift), fromCenter: keys.contains(.alternate))
            overlayChanged()
        case .textBox(let anchor):
            textBox = DragBox.rect(from: anchor, to: pixel, square: false, fromCenter: false)
            overlayChanged()
        case .cloneSource(let grab, _):
            session.setCloneSource(CGPoint(x: pixel.x + grab.width, y: pixel.y + grab.height))
        }
    }

    /// The touch lifting at `point`, after `tapCount` taps in quick succession.
    func ended(at point: CGPoint, keys: UIKeyModifierFlags = [], tapCount: Int = 1) {
        defer { finish() }
        guard let drag else { return }
        switch drag {
        case .paint:
            let pixel = pixel(point)
            if let pixel { session.continueBrush(at: pixel) }
            session.finishBrushImmediately()
            strokeEnded(at: pixel)
        case .sample:
            sampleChanged(nil)
        case .zoom(let start, _, let moved):
            if !moved { session.zoom(to: session.viewport.zoom * 2, anchor: start) }
        case .transform:
            // As the Mac's does: a drag applies itself when it's let go, unless it's part of an edit waiting for Apply.
            if session.transformEdit?.persistent == false { session.commitTransform() }
        case .outline:
            if session.lassoDraft?.kind != .polygonal { session.finishLasso() }
        case .corner:
            guard let draft = session.lassoDraft, let document = session.document, let pixel = pixel(point) else { break }
            // A double tap, or a tap back on the first corner once there are three, closes the outline.
            let first = session.viewport.viewPoint(from: draft.points[0], documentSize: document.size)
            if tapCount >= 2 || (draft.points.count >= 3 && hypot(point.x - first.x, point.y - first.y) <= Self.reach) {
                session.finishLasso()
            } else {
                session.extendLasso(to: pixel)
                session.moveLassoCursor(to: nil)
            }
        case .selection(let start):
            let moved = session.selectionMoveOrigin != session.selection
            session.endSelectionMove()
            // A tap inside the selection: the Magic tools select afresh from there, and the others deselect.
            if !moved, session.tool == .wand { select(at: start, mode: .replace) }
            else if !moved { session.deselect() }
        case .pixels:
            pending = Task { [session] in await session.finishPixelMove() }
        case .crop:
            // The frame stays for Apply Crop, or Return.
            break
        case .gradient:
            // The line stays, its ends to drag, until Apply or Return.
            session.endGradientDrag()
        case .shape:
            session.finishShape()
        case .textBox:
            guard let rect = textBox else { break }
            textBox = nil
            if rect.width < 4 && rect.height < 4 { session.beginText(at: rect.origin, newLayer: true) }
            else { session.beginText(in: rect) }
        case .cloneSource:
            // The source stays where the touch left it.
            break
        }
    }

    /// Lets go of a crop, gradient or transform drag, or a box for new text, without taking it back, as a key that
    /// settles the edit does on the Mac: the touch still down moves nothing more.
    func endDrag() {
        switch drag {
        case .crop, .gradient, .transform, .textBox:
            textBox = nil
            finish()
        default: break
        }
    }

    /// The touch taken away, as by a second finger coming down to zoom: what it was doing is undone.
    func cancelled() {
        defer { finish() }
        guard let drag else { return }
        switch drag {
        case .paint(let last):
            session.cancelBrush()
            strokeEnded(at: last)
        case .sample:
            sampleChanged(nil)
        case .zoom:
            break
        case .transform(let transform, _):
            session.previewTransform(transform.original)
            if let corners = transform.originalCorners { session.previewCorners(corners) }
            if session.transformEdit?.persistent == false { session.cancelTransform() }
        case .outline:
            if session.lassoDraft?.kind != .polygonal { session.cancelLasso() }
        case .corner:
            session.moveLassoCursor(to: nil)
        case .selection:
            session.endSelectionMove()
        case .pixels:
            session.cancelPixelMove()
        case .crop(_, _, let before):
            session.cropRect = before
        case .gradient(_, let before):
            if let before { session.moveGradient(start: before.start, end: before.end) } else { session.cancelGradient() }
        case .shape:
            session.cancelShape()
        case .textBox:
            textBox = nil
        case .cloneSource(_, let before):
            session.cloneSource = before.source
            session.cloneOffset = before.offset
        }
    }

    private func finish() {
        drag = nil
        session.snapGuides = ([], [])
        overlayChanged()
    }

    /// A press with the Crop tool, as the Mac's: on a handle or an edge of the frame it resizes the frame, inside a frame
    /// smaller than the canvas it moves it, and anywhere else it draws a new one.
    private func beginCrop(at point: CGPoint, pixel: CGPoint) {
        guard let document = session.document else { return }
        let before = session.cropRect
        let rect = session.visibleCropRect ?? CGRect(origin: pixel, size: .zero)
        let mode: CropDrag.Mode
        if let handle = cropHandle(at: point) { mode = .resize(handle) }
        else if session.cropRect?.contains(pixel) == true, rect != CGRect(origin: .zero, size: document.size) { mode = .move }
        else { mode = .create; session.cropRect = nil }
        let targets = session.cropSnapTargets()
        let snap = CropSnap(xs: targets.xs, ys: targets.ys, tolerance: Self.cropSnapDistance / max(session.viewport.pointsPerPixel, 0.0001))
        drag = .crop(CropDrag(start: pixel, original: rect, mode: mode), snap: snap, before: before)
    }

    /// Where Clone Stamp's crosshair marks its source, in document pixels, as the Mac's does, with the brush at `brush`
    /// while it touches or hovers over the canvas: at the source, or once a stroke has fixed the offset to it, that far
    /// from the brush. With nothing over the canvas, an aligned source stays where the last stroke left it. Nil with
    /// other tools, or before a source is set.
    func cloneSourceMark(brush: CGPoint?) -> CGPoint? {
        guard session.tool == .cloneStamp, session.document != nil, let source = session.cloneSource else { return nil }
        if let brush, let sample = session.cloneSamplePoint(for: brush) { return sample }
        if session.cloneSettings.aligned, let offset = session.cloneOffset, let end = cloneStrokeEnd {
            return CGPoint(x: end.x + offset.width, y: end.y + offset.height)
        }
        return source
    }

    /// Whether a touch is setting Clone Stamp's source.
    var isDraggingSource: Bool {
        if case .cloneSource = drag { return true }
        return false
    }

    /// A touch coming down at `point` with Clone Stamp that sets its source rather than painting: with Option held, as an
    /// Option-click sets it on the Mac; on the source's crosshair, which a finger moves, as in Pixelmator Pro for iPad;
    /// or, before there's a source to copy from, wherever a touch that `paints` comes down. The source follows the
    /// touch until it lifts. False for a touch that paints, or one that moves the canvas.
    func beginSourceDrag(at point: CGPoint, keys: UIKeyModifierFlags = [], paints: Bool = true) -> Bool {
        guard session.tool == .cloneStamp, let document = session.document, let pixel = pixel(point) else { return false }
        var grab = CGSize.zero
        if let mark = cloneSourceMark(brush: nil), !keys.contains(.alternate) {
            let shown = session.viewport.viewPoint(from: mark, documentSize: document.size)
            guard hypot(point.x - shown.x, point.y - shown.y) <= Self.reach else { return false }
            grab = CGSize(width: mark.x - pixel.x, height: mark.y - pixel.y)
        } else if !keys.contains(.alternate), !paints {
            return false
        }
        drag = .cloneSource(grab: grab, before: (session.cloneSource, session.cloneOffset))
        session.setCloneSource(CGPoint(x: pixel.x + grab.width, y: pixel.y + grab.height))
        return true
    }

    /// The stroke ending at `pixel`, where Clone Stamp's crosshair then keeps an aligned source.
    func strokeEnded(at pixel: CGPoint?) {
        if session.tool == .cloneStamp, let pixel { cloneStrokeEnd = pixel }
    }

    /// The topmost text on the canvas at `pixel`, as the Mac finds text to open.
    private func liveText(at pixel: CGPoint) -> ImageLayer? {
        guard let document = session.document else { return nil }
        let visible = document.effectiveVisibleIDs
        return document.layers.reversed().first { visible.contains($0.id) && $0.liveText != nil && $0.transform.contains(pixel) }
    }

    /// Opens `layer`'s text for editing, the caret where the touch came down.
    private func openText(_ layer: ImageLayer, at point: CGPoint) {
        session.selectLayer(layer.id)
        session.editActiveText()
        if session.textDraft?.layerID == layer.id { textOpened(point) }
    }

    /// A press with the Gradient tool, as the Mac's: on an end of the line it moves that end; anywhere else it starts the
    /// line again, or a new gradient. A finger finds an end further off than the Mac's pointer does.
    private func beginGradient(at point: CGPoint, pixel: CGPoint) -> Bool {
        let before = session.gradientEdit.map { (start: $0.start, end: $0.end) }
        if let line = overlay.gradientLine {
            let ends: [(end: GradientEnd, distance: CGFloat)] = [(.end, hypot(point.x - line.end.x, point.y - line.end.y)),
                                                                  (.start, hypot(point.x - line.start.x, point.y - line.start.y))]
            if let nearest = ends.filter({ $0.distance <= Self.reach }).min(by: { $0.distance < $1.distance }) {
                drag = .gradient(nearest.end, before: before)
                return true
            }
        }
        session.beginGradient(at: pixel)
        guard session.gradientEdit != nil else { return false }
        drag = .gradient(.end, before: before)
        return true
    }

    /// The crop frame's handle under a finger, found further off than the Mac's pointer finds it: the nearest corner
    /// within reach, else the nearest edge within reach anywhere along its length; less far around a small frame.
    private func cropHandle(at point: CGPoint) -> Int? {
        guard let rect = overlay.cropViewRect else { return nil }
        let handles = overlay.cropHandles
        let reach = min(Self.reach, max(10, min(rect.width, rect.height) / 3))
        func nearest(_ candidates: [(index: Int, distance: CGFloat)]) -> Int? {
            candidates.filter { $0.distance <= reach }.min { $0.distance < $1.distance }?.index
        }
        if let corner = nearest([0, 2, 4, 6].map { (index: $0, distance: hypot(point.x - handles[$0].x, point.y - handles[$0].y)) }) {
            return corner
        }
        var edges: [(index: Int, distance: CGFloat)] = []
        if (rect.minX...rect.maxX).contains(point.x) { edges += [1, 5].map { (index: $0, distance: abs(point.y - handles[$0].y)) } }
        if (rect.minY...rect.maxY).contains(point.y) { edges += [3, 7].map { (index: $0, distance: abs(point.x - handles[$0].x)) } }
        return nearest(edges)
    }

    /// The Eyedropper at `point`, over `pixel`: the color there, as the canvas shows it, becomes the foreground color.
    private func sample(at point: CGPoint, pixel: CGPoint, original: PaletteColor) {
        guard session.canEditPalette, let color = session.sampleCompositeColor(at: pixel) else { return }
        session.foregroundColor = color
        sampleChanged((point, color, original))
    }

    /// The Magic tool at `pixel`: the object there, or the pixels of similar color.
    private func select(at pixel: CGPoint, mode: SelectionMode) {
        let session = session
        pending = Task {
            if session.wandMode == .object { await session.selectObject(at: pixel, mode: mode) }
            else { await session.magicWand(at: pixel, mode: mode) }
        }
    }

    /// A marquee corner at `pixel`, snapped to View > Snap To targets unless Control is held.
    private func snappedCorner(_ pixel: CGPoint, keys: UIKeyModifierFlags) -> CGPoint {
        guard !keys.contains(.control) else { session.snapGuides = ([], []); return pixel }
        return session.snappedPoint(pixel, tolerance: TransformSnap.distance / max(session.viewport.pointsPerPixel, 0.0001))
    }
}
