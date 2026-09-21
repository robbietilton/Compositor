import AppKit
import SwiftUI

struct EditorCanvas: NSViewRepresentable {
    let session: EditorSession
    func makeNSView(context: Context) -> CanvasView { CanvasView(session: session) }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.consumeFocusRequest(session.canvasFocusRequest)
        _ = session.showsTransformControls // observed here so ⌘H redraws the transform box at once
        _ = session.showsGrid
        _ = session.showsGuides
        _ = session.guideDrag
        _ = session.document?.guides
        view.synchronizeDisplay()
        view.window?.isDocumentEdited = session.isModified
    }
}

final class CanvasView: NSView {
    var inlineTextEditor: InlineTextEditor?
    var textBoxAnchor: CGPoint?
    var textBoxRect: CGRect?
    private var lastFocusRequest = 0
    func consumeFocusRequest(_ request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.attachedSheet == nil else { return }
            if self.session.textDraft == nil { window.makeFirstResponder(self) }
        }
    }
    private let sampleRing = SampleRingOverlay()
    private var samplingOriginal = PaletteColor.black
    let session: EditorSession
    private var spaceHeld = false
    private var panPhysicalKey: UInt16?
    private var brushPointer: CGPoint?
    /// The layer being drawn into a surface for SeparableBlend, which draws it plainly and blends it afterwards.
    private var normalBlendLayerID: UUID?
    private func blendMode(of layer: ImageLayer) -> LayerBlendMode {
        layer.id == normalBlendLayerID ? .normal : session.displayedBlendMode(for: layer)
    }
    private let brushCursor = BrushCursorOverlay()
    private var lastDragPoint: CGPoint?
    /// Where Shift was last pressed in the stroke in progress (or where the stroke started, if it was held then):
    /// the line the stroke is kept on while Shift stays down.
    private var brushAxisAnchor: CGPoint?
    /// The axis that line runs along, chosen by which way the stroke first moves once Shift is down.
    private var brushAxisHorizontal: Bool?
    /// Where the stroke last went, so pressing Shift mid-stroke locks from there rather than from its start.
    private var brushLastPixel: CGPoint?
    private var transformDrag: TransformDrag? {
        didSet { if transformDrag == nil { releaseDragCursor() } }
    }
    private var dragCursor: NSCursor?
    private weak var cursorLockWindow: NSWindow?
    private var cropDrag: CropDrag? {
        didSet { if cropDrag == nil { releaseDragCursor() } }
    }
    private var guideDragging = false {
        didSet { if !guideDragging { releaseDragCursor() } }
    }
    private let transformOverlay: TransformOverlay
    private var displayedState: DisplayState?
    private var displayedTool: NavigationTool?
    private var displayedPicking = false
    private var displayedTargeting = false
    private var optionHeld = false
    private var palettePicking: Bool { session.tool == .eyedropper || (optionHeld && (session.tool == .brush || session.tool == .spotHealing || session.tool == .gradient) && session.brushStroke == nil && gradientDrag == nil) }
    private var picking: Bool { palettePicking || session.colorPicker != nil || session.hueSampleMode != nil || session.levels?.sampleMode != nil }
    /// View point where a targeted-adjustment drag began.
    private var hueTargetStart: CGPoint?
    private var samplingColor = false
    private enum GradientHandle { case start, end }
    private var gradientDrag: GradientHandle?
    private var antsTimer: Timer?
    private var modifierMonitor: Any?
    private var keyMonitor: Any?
    /// Document point where a selection-outline drag began.
    private var selectionDragStart: CGPoint?
    /// Document point where a Cmd-drag of the selected pixels began.
    private var pixelDragStart: CGPoint?
    private var duplicatesTransformOnDrag = false
    /// Snapping for the crop drag in progress, built when it starts (the zoom can't change mid-drag).
    private var cropSnap: CropSnap?
    /// How close, in screen points, a crop edge comes to a layer or canvas edge before it snaps.
    static let cropSnapDistance: CGFloat = 8
    /// Whether Shift squares the Marquee draft. False while a Shift held at the press (which chose Add)
    /// is still down; letting it go arms it, so pressing Shift again squares the shape.
    private var marqueeConstrainArmed = true
    /// The Marquee draft's latest drag point, so a Shift change can reshape it without a mouse move.
    private var marqueeDragPixel: CGPoint?
    /// While a Marquee is dragged against or past the canvas edge, pans the view toward the pointer.
    private var marqueeAutoscroll: Timer?
    private var marqueeAutoscrollPoint: CGPoint?
    /// Arrow with scissors: Cmd-dragging here cuts and moves the selected pixels.
    /// An invisible cursor, for tools that draw their own pointer on the canvas.
    static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    static let movePixelsCursor: NSCursor = {
        let base = NSCursor.arrow
        let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Move pixels")!
        let white = symbol.withSymbolConfiguration(.init(paletteColors: [.white]))!
        let black = symbol.withSymbolConfiguration(.init(paletteColors: [.black]))!
        let image = NSImage(size: NSSize(width: 36, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            let glyph = CGRect(x: base.hotSpot.x + 9, y: base.hotSpot.y + 12, width: 11, height: 11)
            for step in 0..<12 {
                let angle = CGFloat(step) * .pi / 6
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.2, dy: sin(angle) * 1.2), from: .zero,
                           operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            black.draw(in: glyph, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        return NSCursor(image: image, hotSpot: base.hotSpot)
    }()
    /// The pointer arrow as a vector path, tip at the origin (y down), about the system arrow's size.
    private static let arrowPath: NSBezierPath = {
        let arrow = NSBezierPath()
        for (index, point) in [(0, 0), (0, 16.5), (3.9, 12.8), (6.6, 19), (9.2, 17.9), (6.6, 11.8), (11.8, 11.8)].enumerated() {
            let point = NSPoint(x: point.0, y: point.1)
            if index == 0 { arrow.move(to: point) } else { arrow.line(to: point) }
        }
        arrow.close()
        arrow.lineJoinStyle = .round
        arrow.lineWidth = 2.2 // stroked under the fill, so about 1 pt of outline shows
        return arrow
    }()
    /// Shapes drawn back to front, outlined like the system cursors (each path's line width sets the
    /// outline, stroked under its fill), with a soft shadow. Coordinates are y-down.
    private static func outlinedCursor(size: NSSize, hotSpot: NSPoint,
                                       _ shapes: [(path: NSBezierPath, fill: NSColor, outline: NSColor)]) -> NSCursor {
        let image = NSImage(size: size, flipped: true) { _ in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            for shape in shapes {
                NSGraphicsContext.saveGraphicsState()
                shadow.set()
                shape.outline.setStroke()
                shape.path.stroke()
                NSGraphicsContext.restoreGraphicsState()
                shape.fill.setFill()
                shape.path.fill()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: hotSpot)
    }
    /// Arrows drawn back to front, each offset down-right from the hot spot.
    private static func arrowCursor(_ arrows: [(offset: CGFloat, fill: NSColor, outline: NSColor)]) -> NSCursor {
        let tip = NSPoint(x: 4, y: 3)
        return outlinedCursor(size: NSSize(width: 28, height: 32), hotSpot: tip, arrows.map { arrow in
            let path = arrowPath.copy() as! NSBezierPath
            path.transform(using: AffineTransform(translationByX: tip.x + arrow.offset, byY: tip.y + arrow.offset))
            return (path, arrow.fill, arrow.outline)
        })
    }
    /// Photoshop's duplicate pointer: a black arrow over a white one offset behind it. Shown where a
    /// drag copies — Option-dragging a layer, Cmd-Option-dragging selected pixels.
    static let duplicateCursor = arrowCursor([(offset: 5, fill: .white, outline: .black), (offset: 0, fill: .black, outline: .white)])
    /// A white arrow over a transform handle that distorts when dragged (Cmd held, or already distorted).
    static let distortCursor = arrowCursor([(offset: 0, fill: .white, outline: .black)])
    /// Photoshop's Move pointer: the arrow with a small four-way arrow at its lower right. Shown wherever
    /// a press would drag a layer, away from the transform handles.
    static let moveCursor: NSCursor = {
        let base = NSCursor.arrow
        // Heads kept narrow and well apart, so the four arrows stay distinct at badge size.
        let badge = fourArrowPath(center: NSPoint(x: base.hotSpot.x + 14.5, y: base.hotSpot.y + 17.5),
                                  reach: 6.5, shaft: 0.75, head: 2, headLength: 2.5)
        badge.lineWidth = 1.6 // stroked under the fill, so about 0.8 pt of white outline shows
        let image = NSImage(size: NSSize(width: 36, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            NSColor.white.setStroke()
            badge.stroke()
            NSColor.black.setFill()
            badge.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: base.hotSpot)
    }()

    /// Four arrows around `center` (y-down): each reaches `reach` from the center along a shaft of
    /// half-width `shaft`, ending in a head `head` wide on each side and `headLength` long.
    private static func fourArrowPath(center: NSPoint, reach: CGFloat, shaft: CGFloat, head: CGFloat, headLength: CGFloat) -> NSBezierPath {
        // The top arrow, from the shaft on its left round the tip to the shaft on its right; turned a
        // quarter at a time ((x, y) → (−y, x)) it traces the other three arrows clockwise.
        let arm: [(CGFloat, CGFloat)] = [(-shaft, -reach + headLength), (-head, -reach + headLength), (0, -reach),
                                         (head, -reach + headLength), (shaft, -reach + headLength), (shaft, -shaft)]
        let path = NSBezierPath()
        for turn in 0..<4 {
            for var point in arm {
                for _ in 0..<turn { point = (-point.1, point.0) }
                let location = NSPoint(x: center.x + point.0, y: center.y + point.1)
                if path.isEmpty { path.move(to: location) } else { path.line(to: location) }
            }
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }
    /// Arrow with a small dashed box: dragging here moves the selection outline.
    static let moveSelectionCursor = selectionBadged(.arrow, boxAt: CGPoint(x: 9.5, y: 13.5))
    /// Pointing hand with a dashed box: Cmd-click a mask thumbnail to load it as a selection.
    static let loadSelectionCursor = selectionBadged(.pointingHand, boxAt: CGPoint(x: 11.5, y: 14.5))

    /// Adds a small dashed selection box to a system cursor, offset from its hot spot.
    static func selectionBadged(_ base: NSCursor, boxAt offset: CGPoint) -> NSCursor {
        let image = NSImage(size: NSSize(width: 36, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            let box = NSBezierPath(rect: NSRect(x: base.hotSpot.x + offset.x, y: base.hotSpot.y + offset.y, width: 8, height: 6))
            NSColor.white.setStroke()
            box.lineWidth = 2.5
            box.stroke()
            NSColor.black.setStroke()
            box.lineWidth = 1
            box.setLineDash([2, 1.5], count: 2, phase: 0)
            box.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: base.hotSpot)
    }
    /// Which selection tool a crosshair names: the tool rail's icon, small, beneath and right of the crosshair.
    enum SelectionIcon: CaseIterable { case freehandLasso, polygonalLasso, rectangleMarquee, ellipseMarquee, objectSelection }

    /// Crosshair with the tool's icon, and a "+" (add) or "−" (subtract) beside the icon, as Photoshop shows.
    static let selectionCursors: [SelectionIcon: [SelectionMode: NSCursor]] = Dictionary(uniqueKeysWithValues:
        SelectionIcon.allCases.map { icon in
            (icon, Dictionary(uniqueKeysWithValues: SelectionMode.allCases.map { ($0, selectionCursor(icon, mode: $0)) }))
        })

    private static func selectionCursor(_ icon: SelectionIcon, mode: SelectionMode) -> NSCursor {
        let base = NSCursor.crosshair
        let hotSpot = base.hotSpot
        let image = NSImage(size: NSSize(width: 44, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            let box = NSRect(x: hotSpot.x + 7, y: hotSpot.y + 7, width: 12, height: 12)
            drawSelectionIcon(icon, in: box)
            if mode != .replace {
                let center = CGPoint(x: box.maxX + 5, y: box.midY)
                let badge = NSBezierPath()
                // Same white-outlined black stroke and round ends as the system crosshair.
                badge.move(to: CGPoint(x: center.x - 3, y: center.y))
                badge.line(to: CGPoint(x: center.x + 3, y: center.y))
                if mode == .add {
                    badge.move(to: CGPoint(x: center.x, y: center.y - 3))
                    badge.line(to: CGPoint(x: center.x, y: center.y + 3))
                }
                badge.lineCapStyle = .round
                NSColor.white.setStroke()
                badge.lineWidth = 3.2
                badge.stroke()
                NSColor.black.setStroke()
                badge.lineWidth = 1.2
                badge.stroke()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: hotSpot)
    }

    /// The tool rail's icon at cursor size: black with a thin white outline, so it reads on any image.
    private static func drawSelectionIcon(_ icon: SelectionIcon, in box: NSRect) {
        if icon == .polygonalLasso {
            // The rail's own drawing (see PolygonalLassoToolIcon), on its 18-unit grid.
            let unit = box.width / 18
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * unit, y: box.minY + y * unit) }
            let path = NSBezierPath()
            for (corners, closed) in [([point(1.2, 7.0), point(4.0, 2.4), point(11.8, 1.8), point(16.8, 5.2), point(15.6, 10.4), point(7.0, 11.6)], true),
                                      ([point(8.9, 10.9), point(13.3, 10.5), point(11.6, 14.5)], true),
                                      ([point(11.6, 14.5), point(12.9, 17.3)], false)] {
                path.move(to: corners[0])
                for corner in corners.dropFirst() { path.line(to: corner) }
                if closed { path.close() }
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke()
            path.lineWidth = 1.4 * unit + 2
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.4 * unit
            path.stroke()
            return
        }
        if icon == .objectSelection {
            let unit = box.width / 18
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * unit, y: box.minY + y * unit) }
            let corners = NSBezierPath()
            for part in [[point(2, 6), point(2, 2), point(6, 2)], [point(12, 2), point(16, 2), point(16, 6)],
                         [point(16, 12), point(16, 16), point(12, 16)], [point(6, 16), point(2, 16), point(2, 12)]] {
                corners.move(to: part[0]); corners.line(to: part[1]); corners.line(to: part[2])
            }
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            NSColor.white.setStroke()
            corners.lineWidth = 1.6 * unit + 2
            corners.stroke()
            NSColor.black.setStroke()
            corners.lineWidth = 1.6 * unit
            corners.stroke()
            let cursor = NSBezierPath()
            for (index, p) in [point(7, 5), point(7, 14), point(9.6, 11.7), point(11.3, 15.3),
                               point(13.2, 14.4), point(11.5, 10.9), point(14.5, 10.9)].enumerated() {
                index == 0 ? cursor.move(to: p) : cursor.line(to: p)
            }
            cursor.close()
            cursor.lineJoinStyle = .round
            NSColor.white.setStroke()
            cursor.lineWidth = 2
            cursor.stroke()
            NSColor.black.setFill()
            cursor.fill()
            return
        }
        let name = icon == .freehandLasso ? "lasso" : icon == .ellipseMarquee ? "circle.dashed" : "rectangle.dashed"
        let size = NSImage.SymbolConfiguration(pointSize: box.height, weight: .semibold)
        guard let white = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(size.applying(.init(paletteColors: [.white]))),
              let black = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(size.applying(.init(paletteColors: [.black]))) else { return }
        // The symbol keeps its own shape, fitted in the box.
        let scale = min(box.width / black.size.width, box.height / black.size.height)
        let rect = NSRect(x: box.midX - black.size.width * scale / 2, y: box.midY - black.size.height * scale / 2,
                          width: black.size.width * scale, height: black.size.height * scale)
        for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0), (-0.7, -0.7), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7)] {
            white.draw(in: rect.offsetBy(dx: dx, dy: dy), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        black.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    /// A wand whose sparkle is the hot spot, with the same "+" / "−" badges as the other selection tools.
    static let wandCursors: [SelectionMode: NSCursor] = Dictionary(uniqueKeysWithValues: SelectionMode.allCases.map { mode in
        let hotSpot = NSPoint(x: 7, y: 7)
        let image = NSImage(size: NSSize(width: 34, height: 34), flipped: true) { _ in
            let stick = NSBezierPath()
            stick.move(to: CGPoint(x: hotSpot.x + 6, y: hotSpot.y + 6))
            stick.line(to: CGPoint(x: hotSpot.x + 20, y: hotSpot.y + 20))
            let marks = NSBezierPath()
            for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] {
                marks.move(to: CGPoint(x: hotSpot.x + dx * 2.5, y: hotSpot.y + dy * 2.5))
                marks.line(to: CGPoint(x: hotSpot.x + dx * 6, y: hotSpot.y + dy * 6))
            }
            if mode != .replace {
                let center = CGPoint(x: hotSpot.x + 17, y: hotSpot.y + 5)
                marks.move(to: CGPoint(x: center.x - 3, y: center.y))
                marks.line(to: CGPoint(x: center.x + 3, y: center.y))
                if mode == .add {
                    marks.move(to: CGPoint(x: center.x, y: center.y - 3))
                    marks.line(to: CGPoint(x: center.x, y: center.y + 3))
                }
            }
            for path in [stick, marks] { path.lineCapStyle = .round }
            // White outlines first, so neither shape's outline covers the other's black line.
            NSColor.white.setStroke()
            stick.lineWidth = 5
            stick.stroke()
            marks.lineWidth = 3.2
            marks.stroke()
            NSColor.black.setStroke()
            stick.lineWidth = 2.4
            stick.stroke()
            marks.lineWidth = 1.2
            marks.stroke()
            return true
        }
        return (mode, NSCursor(image: image, hotSpot: hotSpot))
    })
    private var displayedCropRect: CGRect?
    private var displayedTransformGeometry: TransformOverlayGeometry?
    private var hoverTrackingArea: NSTrackingArea?
    private static let rotationCursor: NSCursor = {
        let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Rotate")!
        let white = symbol.withSymbolConfiguration(.init(paletteColors: [.white]))!
        let black = symbol.withSymbolConfiguration(.init(paletteColors: [.black]))!
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let glyph = CGRect(x: 2, y: 2, width: 20, height: 20)
            // Expand the white silhouette, then draw the black symbol on top.
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.25, dy: sin(angle) * 1.25))
            }
            black.draw(in: glyph)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
    private static let eyedropperCursor: NSCursor = {
        let symbol = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "Sample color")!
        let white = symbol.withSymbolConfiguration(.init(paletteColors: [.white]))!
        let black = symbol.withSymbolConfiguration(.init(paletteColors: [.black]))!
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let glyph = CGRect(x: 2, y: 2, width: 20, height: 20)
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.25, dy: sin(angle) * 1.25))
            }
            black.draw(in: glyph)
            return true
        }
        // The dropper tip sits at the glyph's bottom-left.
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 21))
    }()

    /// The Zoom tool's cursors: a magnifier with a plus, or a minus while Option is held.
    private static func zoomCursor(out: Bool) -> NSCursor {
        let symbol = NSImage(systemSymbolName: out ? "minus.magnifyingglass" : "plus.magnifyingglass",
                             accessibilityDescription: out ? "Zoom out" : "Zoom in")!
        let white = symbol.withSymbolConfiguration(.init(paletteColors: [.white]))!
        let black = symbol.withSymbolConfiguration(.init(paletteColors: [.black]))!
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let glyph = CGRect(x: 2, y: 2, width: 20, height: 20)
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.25, dy: sin(angle) * 1.25))
            }
            // The lens filled white, so the cursor reads on any image. Measured from the symbol: its lens sits at
            // 41% across and 40% down the glyph, with an inside radius of about 27% of it.
            let center = CGPoint(x: glyph.minX + glyph.width * 0.41, y: glyph.maxY - glyph.height * 0.40)
            let radius = glyph.width * 0.29
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            black.draw(in: glyph)
            return true
        }
        // The lens's center, toward the top-left of the glyph.
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }
    private static let zoomInCursor = zoomCursor(out: false)
    private static let zoomOutCursor = zoomCursor(out: true)
    /// A Zoom tool press: dragging left or right zooms smoothly about where it began; a press that doesn't move
    /// zooms a step on release instead.
    private var zoomDrag: (start: CGPoint, zoom: CGFloat, moved: Bool)?

    private struct DisplayState: Equatable {
        struct Layer: Equatable {
            let id: UUID
            let transform: LayerTransform
            let imageID: ObjectIdentifier?
            let maskID: ObjectIdentifier?
            let maskSourceID: UUID?
            /// Moving a layer into or out of a masked folder changes how it is clipped.
            let parentID: UUID?
            let visible: Bool
            let opacity: Double
            let blendMode: LayerBlendMode
            let adjustment: LayerAdjustment?
            let effects: LayerEffects?
            /// Where the mask shows when placed apart from the layer.
            let maskPlacement: LayerTransform?
        }
        let brushRevision: Int
        let pixelGrid: Bool
        let documentID: UUID?
        let size: CGSize?
        let renderBounds: CGRect?
        let viewport: CanvasViewport
        let layers: [Layer]
        /// Folders have no pixels, so their masks are tracked apart from `layers`.
        struct FolderMask: Equatable {
            let id: UUID
            let maskID: ObjectIdentifier?
            let transform: LayerTransform
        }
        let folderMasks: [FolderMask]
    }

    @discardableResult
    func synchronizeDisplay() -> Bool {
        // The stroke is over: what its surface holds stands in until the layer's own effects have been rebuilt from
        // the pixels it left, so nothing blinks at the end of a stroke.
        if session.brushStroke == nil, let surface = strokeSurface {
            if let built = surface.image, let placement = surface.placement {
                session.effectsPreviews.seed(surface.layerID, image: built, placement: placement)
            }
            strokeSurface = nil
        }
        synchronizeInlineText()
        if session.tool != .type, textBoxRect != nil { textBoxAnchor = nil; textBoxRect = nil; needsDisplay = true }
        // Image identity detects raster replacement without comparing pixel data.
        let document = session.document
        // Folders hold no pixels and so aren't listed below; their opacity reaches the canvas
        // through the layers inside them, which is what has to be watched for a change.
        let opacities = document?.effectiveOpacities ?? [:]
        let state = DisplayState(brushRevision: session.brushRevision, pixelGrid: session.showsPixelGrid, documentID: document?.id, size: document?.size, renderBounds: renderBounds, viewport: session.viewport,
            layers: (document.map { $0.layers.contains(where: { $0.maskSourceID != nil }) ? $0.layers : $0.renderLayers } ?? []).filter { $0.asset != nil || $0.adjustment != nil }.map {
                DisplayState.Layer(id: $0.id, transform: session.displayedTransform(for: $0),
                                   imageID: $0.asset.map { ObjectIdentifier($0.image) }, maskID: $0.mask?.enabledImage.map { ObjectIdentifier($0) }, maskSourceID: $0.maskSourceID, parentID: $0.parentID, visible: document?.effectiveVisibleIDs.contains($0.id) == true, opacity: opacities[$0.id] ?? $0.opacity, blendMode: session.displayedBlendMode(for: $0), adjustment: $0.adjustment, effects: $0.effects,
                                   maskPlacement: session.displayedMaskPlacement(for: $0))
            },
            folderMasks: (document?.layers ?? []).filter { $0.isGroup && $0.mask != nil }.map {
                DisplayState.FolderMask(id: $0.id, maskID: $0.mask?.enabledImage.map { ObjectIdentifier($0) },
                                        transform: session.displayedTransform(for: $0))
            })
        var changed = false
        if displayedState != state {
            if let previous = displayedState, previous.documentID == state.documentID,
               previous.size == state.size, previous.viewport == state.viewport,
               previous.renderBounds == state.renderBounds, previous.layers == state.layers,
               previous.folderMasks == state.folderMasks,
               let stroke = session.brushStroke, let document,
               let dirty = stroke.dirtyDocumentRect {
                let origin = session.viewport.viewPoint(from: dirty.origin, documentSize: document.size)
                let scale = session.viewport.pointsPerPixel
                setNeedsDisplay(CGRect(origin: origin, size: CGSize(width: dirty.width * scale, height: dirty.height * scale)).insetBy(dx: -2, dy: -2))
            } else { needsDisplay = true }
            displayedState = state
            changed = true
        }
        if displayedTool != session.tool {
            displayedTool = session.tool
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        if displayedPicking != picking || displayedTargeting != session.hueTargeting {
            displayedPicking = picking
            displayedTargeting = session.hueTargeting
            samplingColor = false
            sampleRing.isHidden = true
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
            if picking, let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                Self.eyedropperCursor.set()
            }
        }
        if displayedCropRect != transformOverlay.cropViewRect {
            displayedCropRect = transformOverlay.cropViewRect
            window?.invalidateCursorRects(for: self)
        }
        if displayedTransformGeometry != transformOverlay.geometry {
            displayedTransformGeometry = transformOverlay.geometry
            window?.invalidateCursorRects(for: self)
        }
        updateBrushCursor()
        updateAntsTimer()
        // Observe selection only for the lightweight handles overlay.
        _ = session.activeLayerID
        _ = session.cropRect
        transformOverlay.needsDisplay = true
        redrawRulers()
        return changed
    }

    private func redrawRulers() {
        func find(_ view: NSView) {
            if view is CanvasRulerNSView { view.needsDisplay = true }
            view.subviews.forEach(find)
        }
        window?.contentView.map(find)
    }

    init(session: EditorSession) {
        self.session = session
        transformOverlay = TransformOverlay(session: session)
        super.init(frame: .zero)
        session.refreshCanvasPreview = { [weak self] in
            self?.synchronizeDisplay()
            self?.displayIfNeeded()
        }
        addSubview(transformOverlay)
        addSubview(brushCursor)
        addSubview(sampleRing)
        // Each overlay draws into its own layer. Without one, redrawing a transparent overlay (every crop
        // or transform drag, marching-ants tick, or cursor move) makes AppKit redraw the canvas beneath —
        // the whole checkerboard and layer composite. All three get layers so they keep their stacking order.
        for overlay in [transformOverlay, brushCursor, sampleRing] as [NSView] { overlay.wantsLayer = true }
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Canvas")
        setAccessibilityIdentifier("editorCanvas")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        transformOverlay.frame = bounds
        brushCursor.frame = bounds
        syncGeometry()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncGeometry()
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor); self.modifierMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard window != nil else { return }
        optionHeld = NSEvent.modifierFlags.contains(.option)
        // A tab mounts a new canvas. Restore keyboard focus after SwiftUI finishes
        // installing it, without taking focus from a newly presented dialog.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session.document != nil, let window = self.window,
                  window.attachedSheet == nil, !self.session.showsNewDocument,
                  !self.session.showsImporter, self.session.colorPicker == nil else { return }
            window.makeFirstResponder(self)
        }
        // Modifier changes reach only the first responder; watch them app-wide so the
        // lasso badge updates even while another control has keyboard focus.
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            self.optionHeld = event.modifierFlags.contains(.option)
            // A Marquee drag reshapes as Shift goes down or up, without waiting for the mouse to move.
            if let pixel = self.marqueeDragPixel, let kind = self.session.lassoDraft?.kind, kind == .rectangle || kind == .ellipse {
                self.dragMarqueeDraft(to: pixel, flags: event.modifierFlags)
            }
            // So does a crop drag as Option (symmetry) or Control (no snapping) changes.
            if let drag = self.cropDrag, self.session.tool == .crop, let document = self.session.document, let window = self.window {
                self.dragCrop(drag, to: self.convert(window.mouseLocationOutsideOfEventStream, from: nil),
                              flags: event.modifierFlags, documentSize: document.size)
            }
            self.synchronizeDisplay()
            self.updateBrushCursor()
            // Only while the pointer is over the canvas: rebuilding its cursor rects with the pointer somewhere
            // else (the Layers panel, holding Option for a clipping mask) takes that view's cursor away.
            if let window = self.window, self.visibleRect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                self.window?.invalidateCursorRects(for: self)
            }
            self.session.updateHeldSelectionKeys(shift: event.modifierFlags.contains(.shift),
                                                 option: event.modifierFlags.contains(.option))
            if self.session.tool.isSelectionTool { self.refreshLassoCursor(event.modifierFlags) }
            if self.session.tool == .move, let window = self.window {
                let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.visibleRect.contains(point) { self.updateTransformCursor(at: point, flags: event.modifierFlags) }
            }
            return event
        }
        // Window-wide keys that work wherever focus sits — the canvas, the Layers panel, a header
        // control, the tool rail — except while typing in a text field.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let originalEvent = event
            guard let event = ShortcutSettings.shared.canvasEvent(event) else { return originalEvent }
            guard let self, let window = self.window, event.window === window, !(window.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers else { return originalEvent }
            // Shift-+ / Shift-− step the active layer's blend mode, in every tool.
            if event.modifierFlags.contains(.shift), key == "+" || key == "_" || event.keyCode == 24 || event.keyCode == 27 {
                self.session.cycleBlendMode(forward: key == "+" || event.keyCode == 24)
                return nil
            }
            // Brush size ([ ]) and hardness (Shift-[ ]); with focus on the canvas its own keyDown handles them.
            guard (self.session.tool.isBrushTool), self.session.levels == nil, window.firstResponder !== self,
                  ["[", "]", "{", "}"].contains(key) else { return originalEvent }
            if key == "[" || key == "]" { self.session.changeBrushSize(increase: key == "]") }
            else { self.session.changeBrushHardness(increase: key == "}") }
            return nil
        }
    }

    private var lassoCursor: NSCursor { lassoCursor(flags: NSEvent.modifierFlags) }

    /// In New mode over the selection, the move cursor; otherwise the badged crosshair. Over the
    /// selection, Cmd shows the scissors (cut and move its pixels) and Cmd-Option the copy cursor.
    /// `location` is the pointer in view coordinates, when an event supplies it.
    private func lassoCursor(flags: NSEvent.ModifierFlags, at location: CGPoint? = nil) -> NSCursor {
        let mode = session.lassoCursorMode(shift: flags.contains(.shift), option: flags.contains(.option))
        if selectionDragStart != nil { return Self.moveSelectionCursor }
        if pixelDragStart != nil { return pixelDragCursor(duplicate: session.pixelMove?.duplicate == true) }
        if flags.contains(.command) || mode == .replace, let document = session.document,
           let point = location ?? window.map({ convert($0.mouseLocationOutsideOfEventStream, from: nil) }),
           session.canMoveSelection(at: session.viewport.documentPoint(from: point, documentSize: document.size)) {
            return flags.contains(.command) ? pixelDragCursor(duplicate: flags.contains(.option)) : Self.moveSelectionCursor
        }
        if session.tool == .wand, session.wandMode == .wand { return Self.wandCursors[mode] ?? .crosshair }
        let icon: SelectionIcon = session.tool == .wand ? .objectSelection : session.tool == .marquee
            ? (session.marqueeKind == .ellipse ? .ellipseMarquee : .rectangleMarquee)
            : (session.lassoKind == .polygonal ? .polygonalLasso : .freehandLasso)
        return Self.selectionCursors[icon]?[mode] ?? .crosshair
    }

    /// Cmd-dragging the selection cuts and moves its pixels (scissors); with Option it copies them.
    private func pixelDragCursor(duplicate: Bool) -> NSCursor { duplicate ? Self.duplicateCursor : Self.movePixelsCursor }

    /// Re-applies the lasso cursor now if the pointer is over the canvas.
    private func refreshLassoCursor(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        window?.invalidateCursorRects(for: self)
        guard session.tool.isSelectionTool, !spaceHeld, !picking, let window,
              bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        lassoCursor(flags: flags).set()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); syncGeometry() }

    private func syncGeometry() {
        // Defer observable mutations until after SwiftUI's layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let scale = self.convertToBacking(CGSize(width: 1, height: 1)).width
            guard self.session.viewport.viewSize != self.bounds.size ||
                    self.session.viewport.backingScale != scale else { return }
            self.session.viewport.resize(to: self.bounds.size, backingScale: scale,
                                         documentSize: self.session.document?.size)
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        defer { drawTextBoxDraft() }
        NSColor(white: 0.105, alpha: 1).setFill()
        dirtyRect.fill()
        guard let stored = session.document,
              let context = NSGraphicsContext.current?.cgContext else { return }
        // A generated result shows as the layer it would become, so folders, clipping and the layers above it
        // treat it exactly as they will once it is kept.
        let document = session.generativeEdit?.previewDocument(from: stored) ?? stored
        let pixels = renderBounds ?? CGRect(origin: .zero, size: document.size)
        let rect = CGRect(origin: session.viewport.viewPoint(from: pixels.origin, documentSize: document.size),
                          size: CGSize(width: pixels.width * session.viewport.pointsPerPixel,
                                       height: pixels.height * session.viewport.pointsPerPixel))
        guard rect.intersects(bounds), rect.intersects(dirtyRect) else { return }
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 14,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setFillColor(NSColor(white: 0.26, alpha: 1).cgColor)
        context.fill(rect)
        context.restoreGState()
        context.saveGState()
        context.clip(to: rect.intersection(dirtyRect))
        context.setFillColor(NSColor(white: 0.30, alpha: 1).cgColor)
        context.fill(rect)
        // Work scales with the visible viewport, not document dimensions.
        let tile: CGFloat = 10
        let visible = rect.intersection(bounds).intersection(dirtyRect)
        if !visible.isNull, !visible.isEmpty {
            let minX = Int(floor((visible.minX - rect.minX) / tile))
            let maxX = Int(ceil((visible.maxX - rect.minX) / tile))
            let minY = Int(floor((visible.minY - rect.minY) / tile))
            let maxY = Int(ceil((visible.maxY - rect.minY) / tile))
            context.setFillColor(NSColor(white: 0.35, alpha: 1).cgColor)
            for row in minY..<maxY {
                for column in minX..<maxX where (row + column).isMultiple(of: 2) {
                    context.fill(CGRect(x: rect.minX + CGFloat(column) * tile,
                                        y: rect.minY + CGFloat(row) * tile, width: tile, height: tile))
                }
            }
        }
        if session.viewport.zoom >= Self.crispZoom, !visible.isNull, !visible.isEmpty {
            drawDocumentPixels(covering: visible, clippedTo: pixels, document: document, in: context)
        } else {
            // Draw native-resolution assets into the same document/view mapping as navigation.
            // The AppKit view is flipped; flip each image locally so its top stays at the top.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawLayers(document, scale: session.viewport.pointsPerPixel,
                       center: { self.session.viewport.viewPoint(from: $0, documentSize: document.size) }, in: context)
            context.endTransparencyLayer()
        }
        if session.showsPixelGrid, session.viewport.zoom >= Self.pixelGridZoom, !visible.isNull, !visible.isEmpty {
            drawPixelGrid(in: visible, document: document, context: context)
        }
        context.restoreGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
        context.setLineWidth(1 / session.viewport.backingScale)
        context.stroke(rect)
    }

    /// From 200% (2 screen pixels per document pixel) the canvas shows hard-edged
    /// document pixels, as Photoshop does; the pixel grid appears from 800%.
    static let crispZoom: CGFloat = 2
    static let pixelGridZoom: CGFloat = 8

    /// A copy of a layer image sized for how large it lands in `context` (`drawnWidth` in the context's units),
    /// from the shared cache of sharp halvings. Core Graphics resamples the whole source on every draw — a
    /// 4000 px layer costs ~24 ms per frame even when only a small patch is dirty — and blurs big reductions.
    private func displayImage(_ image: CGImage, width drawnWidth: CGFloat, in context: CGContext) -> CGImage {
        DownsampleCache.shared.image(image, drawnAt: drawnWidth * LayerRenderer.deviceScale(of: context) / CGFloat(max(1, image.width)))
    }

    private func drawLayers(_ document: CanvasDocument, scale: CGFloat, center: @escaping (CGPoint) -> CGPoint, in context: CGContext, onSurface: Bool = false) {
        session.effectsPreviews.prepare(layers: document.layers)
        // Color Burn and Color Dodge are blended by hand against the pixels under them, which needs a surface to
        // read back (see SeparableBlend).
        if !onSurface, document.layers.contains(where: { $0.adjustment != nil
            || SeparableBlend.isCoreGraphicsWrong(session.displayedBlendMode(for: $0)) }) {
            AdjustmentSurface.draw(in: context) { self.drawLayers(document, scale: scale, center: center, in: $0, onSurface: true) }
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        func drawOwn(_ id: UUID, _ context: CGContext) {
            guard let layer = byID[id], layer.id != session.textDraft?.layerID else { return }
            // A folder the layer sits in dims it along with everything else inside (see LayerOpacity).
            let opacity = layer.effectiveOpacity(in: byID)
            let mode = session.displayedBlendMode(for: layer)
            if SeparableBlend.isCoreGraphicsWrong(mode), normalBlendLayerID != id {
                normalBlendLayerID = id
                defer { normalBlendLayerID = nil }
                if SeparableBlend.draw(mode, in: context, body: { drawOwn(id, $0) }) { return }
            }
            let stroke = session.brushStroke?.layer.id == layer.id ? session.brushStroke
                : session.gradientEdit?.raster.layer.id == layer.id ? session.gradientEdit?.raster
                : session.pixelMove?.raster.layer.id == layer.id ? session.pixelMove?.raster : nil
            guard layer.asset != nil || stroke != nil else { return }
            // Smudge or Liquify in progress: the layer as the stroke has reshaped it so far, across the canvas.
            if let warp = session.warpStroke, warp.layer.id == layer.id, let image = warp.image {
                let canvas = LayerTransform(origin: .zero, size: document.size)
                let mask = layer.mask?.clipImage(placement: layer.maskTransform, over: canvas, width: warp.width, height: warp.height, limit: 2048)
                LayerRenderer.draw(image, transform: canvas, center: center(canvas.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), mask: mask, in: context)
                return
            }
            // A pending distortion shows the layer warped into its new shape — with its effects warped along with
            // it, so they stay on while the corners move.
            if stroke == nil, layer.effects?.visible.isEmpty == false,
               let effects = session.effectsPreviews.preview(for: layer, mask: layer.mask?.enabledImage,
                    transform: layer.transform, maskPlacement: session.displayedMaskPlacement(for: layer),
                    completion: { [weak self] in self?.needsDisplay = true }),
               let warped = session.distortedEffects(for: layer, effects: effects.image, inset: effects.inset) {
                LayerRenderer.draw(warped.image, transform: warped.transform, center: center(warped.transform.center),
                    scale: scale, opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                return
            }
            if stroke == nil, let distorted = session.distortPreview(for: layer) {
                LayerRenderer.draw(distorted.image, transform: distorted.transform, center: center(distorted.transform.center),
                    scale: scale, opacity: opacity, blendMode: blendMode(of: layer),
                    mask: distorted.mask, in: context)
                return
            }
            // A mask stroke paints the mask's grid; the layer itself stays put.
            let transform = (stroke?.isMask == true ? nil : stroke?.paintTransform) ?? session.displayedTransform(for: layer)
            // A mask placed apart from its layer is resampled into the grid the layer draws in (at most 2048 pixels
            // across while something moves, else about the size it's drawn).
            let mask: CGImage? = {
                guard let owned = layer.mask else { return nil }
                if let distorted = session.maskDistortPreview(for: layer) { return distorted }
                guard let placement = session.displayedMaskPlacement(for: layer) else { return owned.enabledImage }
                let owner = stroke?.layer ?? layer
                let base = stroke == nil ? transform : owner.transform
                let drawn = max(base.size.width, base.size.height) * scale * LayerRenderer.deviceScale(of: context)
                let steady = pow(2, ceil(log2(max(64, drawn))))
                return owned.clipImage(placement: placement, over: base,
                    width: owner.asset?.image.width ?? Int(base.size.width.rounded()),
                    height: owner.asset?.image.height ?? Int(base.size.height.rounded()),
                    limit: session.transformEdit != nil ? min(2048, steady) : steady)
            }()
            // A stroke or drop shadow is drawn around the layer's pixels, on a canvas grown to hold it.
            if stroke == nil, layer.asset != nil,
               let effects = session.effectsPreviews.preview(for: layer, mask: mask, transform: transform,
                    maskPlacement: session.displayedMaskPlacement(for: layer), completion: { [weak self] in
                        self?.needsDisplay = true
                    }) {
                // A seeded preview carries the place it belongs; everything else is the layer's box plus its margin.
                let grown = effects.placement ?? LayerEffectsRenderer.placed(transform, image: effects.image, inset: effects.inset)
                LayerRenderer.draw(effects.image, transform: grown, center: center(grown.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                return
            }
            if stroke == nil, let shaped = session.shapeTransformPreview(for: layer, transform: transform) {
                LayerRenderer.draw(shaped, transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), mask: mask, in: context)
            } else if let stroke, !stroke.isMask {
                // The effects follow the paint: a surface kept at full resolution, redone only where the brush has
                // just been (see LayerEffectsSurface). It already holds the wet pixels with the effects over them —
                // a color overlay and an inner shadow go over the layer, so drawing the paint again on top of it
                // would cover them — so nothing more is drawn for this layer.
                if let surface = strokeSurface(layer: layer, stroke: stroke, mask: mask), let built = surface.image {
                    let grown = LayerEffectsRenderer.placed(transform, image: built, inset: surface.margin)
                    surface.placement = grown
                    LayerRenderer.draw(built, transform: grown, center: center(grown.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                    return
                }
                if let effects = session.effectsPreviews.rendered(layer.id) {
                    let grown = effects.placement
                        ?? LayerEffectsRenderer.placed(layer.transform, image: effects.image, inset: effects.inset)
                    LayerRenderer.draw(effects.image, transform: grown, center: center(grown.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                }
                // Painting pixels previews exactly as the finished layer will look, with the layer's own
                // sampling, so nothing shifts when a stroke starts or ends (see TiledLayerRenderer).
                let previous = stroke.layer.asset
                TiledLayerRenderer.drawStroke(width: stroke.width, height: stroke.height, sourceRect: stroke.sourceRect,
                    patches: stroke.patches, image: previous?.raster == nil ? previous?.image : nil, raster: previous?.raster,
                    transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer),
                    mask: mask, in: context)
            } else if let stroke, let placement = stroke.layer.mask?.placement {
                // A mask on its own placement is painted in its own grid: the layer draws through the mask as the
                // stroke leaves it, resampled into the layer's grid.
                let preview = stroke.placedMaskPreview(placement: placement)
                if let raster = stroke.layer.asset?.raster {
                    TiledLayerRenderer.drawRaster(raster, transform: transform, center: center(transform.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: preview, in: context)
                } else if let image = stroke.layer.asset?.image {
                    LayerRenderer.draw(image, transform: transform, center: center(transform.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: preview, in: context)
                }
            } else if let stroke {
                // Painting the mask shows the layer through the mask as it will be once committed, the same way.
                let previous = stroke.layer.asset
                TiledLayerRenderer.drawMaskStroke(width: stroke.width, height: stroke.height, sourceRect: stroke.sourceRect,
                    patches: stroke.patches, oldMask: stroke.layer.mask?.asset,
                    image: previous?.raster == nil ? previous?.image : nil, raster: previous?.raster,
                    transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), in: context)
            } else if let asset = layer.asset, let raster = asset.raster, session.hueSaturation?.previewImage(for: layer.id) == nil && session.levels?.previewImage(for: layer.id) == nil && session.filterEdit?.previewImage(for: layer.id) == nil {
                TiledLayerRenderer.drawRaster(raster, transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer),
                    mask: mask, in: context)
            } else if let image = session.filterEdit?.previewImage(for: layer.id) ?? session.levels?.previewImage(for: layer.id) ?? session.hueSaturation?.previewImage(for: layer.id) ?? layer.asset?.image {
                // LayerRenderer picks a sharp reduction for the image and its mask itself.
                LayerRenderer.draw(image, transform: transform,
                    center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer),
                    mask: mask, in: context)
            }
        }
        // The shape being dragged out previews where its layer will go — above the active layer — rather than over
        // everything, so the layers above it cover it as they will once it is made.
        func drawOwnWithDraft(_ id: UUID, _ context: CGContext) {
            drawOwn(id, context)
            guard id == session.activeLayerID else { return }
            drawShapeDraft(scale: scale, center: center, in: context)
        }
        let live = LiveMaskRenderer(bounds: context.boundingBoxOfClipPath, source: { byID[$0]?.maskSourceID }, drawOwn: drawOwnWithDraft)
        live.adjustment = { byID[$0]?.adjustment }
        live.adjustmentOpacity = { byID[$0]?.effectiveOpacity(in: byID) ?? 1 }
        let area = context.boundingBoxOfClipPath
        live.adjustmentClip = { [weak self] id, ctx in
            guard let self, let layer = byID[id], layer.mask?.isEnabled == true else { return }
            // Mid-stroke the mask exists only as the edit's tiles, so the adjustment is clipped by those, the same
            // way a folder's mask is — otherwise the stroke would only appear once it was committed.
            if let edit = self.liveMaskEdit(for: id),
               let clip = self.liveFolderMaskClip(edit, area: area, scale: scale, center: center, in: ctx) {
                clip(ctx)
                return
            }
            if let image = layer.mask?.enabledImage {
                FolderMaskClip(image: image, transform: layer.transform).apply(scale: scale, center: center(layer.transform.center), in: ctx)
            }
        }
        live.prepareStacks(document.renderLayers.map(\.id), parent: { byID[$0]?.parentID }, blend: { byID[$0].map { session.displayedBlendMode(for: $0) } ?? .normal })
        FolderMaskClip.draw(document.renderLayers.map(\.id), parent: { byID[$0]?.parentID }, clip: { id in
            guard let folder = byID[id], let mask = folder.mask, mask.isEnabled else { return nil }
            if let edit = liveMaskEdit(for: folder.id),
               let clip = liveFolderMaskClip(edit, area: area, scale: scale, center: center, in: context) {
                return clip
            }
            let transform = session.displayedTransform(for: folder)
            let clip = FolderMaskClip(image: displayImage(mask.asset.image, width: transform.size.width * scale, in: context), transform: transform)
            let origin = center(transform.center)
            return { clip.apply(scale: scale, center: origin, in: $0) }
        }, in: context) { live.drawComposite($0, in: context) }
    }

    /// The shape being dragged out with the Shape tool, drawn in the color it will be made in.
    private func drawShapeDraft(scale: CGFloat, center: (CGPoint) -> CGPoint, in context: CGContext) {
        // A flat or upright line has a box with no height or width, which is not "empty" for this purpose.
        guard let draft = session.shapeDraft,
              draft.kind == .line ? (draft.rect.width > 0 || draft.rect.height > 0) : !draft.rect.isEmpty else { return }
        let middle = center(CGPoint(x: draft.rect.midX, y: draft.rect.midY))
        let rect = CGRect(x: middle.x - draft.rect.width * scale / 2, y: middle.y - draft.rect.height * scale / 2,
                          width: draft.rect.width * scale, height: draft.rect.height * scale)
        context.saveGState()
        context.setFillColor(session.foregroundColor.nsColor.cgColor)
        if draft.kind == .line {
            guard let ends = session.shapeLineEnds else { context.restoreGState(); return }
            let thickness = max(1, CGFloat(session.shapeLineWidth) * scale)
            context.setStrokeColor(session.foregroundColor.nsColor.cgColor)
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

    /// The effects surface for the layer being painted, made when the stroke starts and updated as it goes.
    private var strokeSurface: LayerEffectsSurface?
    private func strokeSurface(layer: ImageLayer, stroke: BrushStroke, mask: CGImage?) -> LayerEffectsSurface? {
        guard let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid else { return nil }
        let grid = CGSize(width: stroke.width, height: stroke.height)
        if strokeSurface?.matches(layerID: layer.id, effects: effects, grid: grid, sourceRect: stroke.sourceRect) != true {
            strokeSurface = LayerEffectsSurface(layerID: layer.id, effects: effects, grid: grid, sourceRect: stroke.sourceRect)
        }
        guard let surface = strokeSurface else { return nil }
        surface.update(base: stroke.layer.asset?.image, patches: stroke.patches, mask: mask)
        return surface
    }

    /// The raster edit painting this folder's mask, if one is in progress.
    private func liveMaskEdit(for id: UUID) -> BrushStroke? {
        [session.brushStroke, session.gradientEdit?.raster].compactMap { $0 }.first { $0.layer.id == id && $0.isMask }
    }

    /// While a folder's mask is being painted it exists only as the edit's tiles, so the clip
    /// for the layers inside is rendered from those tiles — just for the area being redrawn,
    /// at the context's device resolution — the same way a layer's own mask is previewed.
    private func liveFolderMaskClip(_ edit: BrushStroke, area: CGRect, scale: CGFloat,
                                    center: (CGPoint) -> CGPoint, in context: CGContext) -> ((CGContext) -> Void)? {
        let rect = area.integral
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        let device = context.convertToDeviceSpace(rect)
        let width = Int(abs(device.width).rounded(.up)), height = Int(abs(device.height).rounded(.up))
        guard width >= 1, height >= 1, width * height <= 64_000_000,
              let coverage = try? BrushRaster.context(width: width, height: height, mask: true) else { return nil }
        // Outside the folder's mask bounds is hidden, as it is for a committed mask.
        coverage.setFillColor(gray: 0, alpha: 1)
        coverage.fill(CGRect(x: 0, y: 0, width: width, height: height))
        coverage.scaleBy(x: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height)
        coverage.translateBy(x: -rect.minX, y: -rect.minY)
        var transform = edit.paintTransform
        transform.sampling = .nearest
        let base = edit.layer.mask?.asset
        LayerRenderer.drawBrushPreview(base.map { $0.raster == nil ? displayImage($0.image, width: transform.size.width * scale, in: coverage) : $0.image },
            transform: transform, center: center(transform.center), scale: scale, opacity: 1, blendMode: .normal, mask: nil,
            patches: edit.patches, pixelWidth: edit.width, pixelHeight: edit.height, paintingMask: false,
            sourceRect: edit.sourceRect, raster: base?.raster,
            rasterBase: base?.raster.flatMap { raster in raster.base.map { displayImage($0, width: transform.size.width * scale * raster.baseRect.width / CGFloat(max(1, raster.width)), in: coverage) } }, in: coverage)
        guard let image = coverage.makeImage() else { return nil }
        return { target in
            // CGImage rows run top-down; image clipping runs bottom-up in this flipped space.
            target.translateBy(x: 0, y: rect.minY * 2 + rect.height)
            target.scaleBy(x: 1, y: -1)
            target.clip(to: rect, mask: image)
            target.scaleBy(x: 1, y: -1)
            target.translateBy(x: 0, y: -(rect.minY * 2 + rect.height))
        }
    }

    /// Composites just the visible document pixels at 1:1 (the same rendering as export),
    /// then enlarges them without smoothing so each document pixel is a crisp square,
    /// even for scaled or rotated layers. Cost is proportional to what is on screen.
    private func drawDocumentPixels(covering view: CGRect, clippedTo pixels: CGRect, document: CanvasDocument, in context: CGContext) {
        let viewport = session.viewport
        let topLeft = viewport.documentPoint(from: view.origin, documentSize: document.size)
        let bottomRight = viewport.documentPoint(from: CGPoint(x: view.maxX, y: view.maxY), documentSize: document.size)
        let region = CGRect(x: floor(topLeft.x), y: floor(topLeft.y),
                            width: ceil(bottomRight.x) - floor(topLeft.x), height: ceil(bottomRight.y) - floor(topLeft.y))
            .intersection(pixels.integral)
        guard !region.isNull, region.width >= 1, region.height >= 1,
              let raster = try? BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false) else { return }
        drawLayers(document, scale: 1, center: { CGPoint(x: $0.x - region.minX, y: $0.y - region.minY) }, in: raster)
        guard let image = raster.makeImage() else { return }
        let origin = viewport.viewPoint(from: region.origin, documentSize: document.size)
        let target = CGRect(origin: origin, size: CGSize(width: region.width * viewport.pointsPerPixel,
                                                         height: region.height * viewport.pointsPerPixel))
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
    }

    /// One-screen-pixel lines on document pixel boundaries, over the image only.
    private func drawPixelGrid(in view: CGRect, document: CanvasDocument, context: CGContext) {
        let viewport = session.viewport
        let canvas = CGRect(origin: viewport.viewPoint(from: .zero, documentSize: document.size),
                            size: CGSize(width: document.size.width * viewport.pointsPerPixel,
                                         height: document.size.height * viewport.pointsPerPixel))
        let area = view.intersection(canvas)
        guard !area.isNull, !area.isEmpty else { return }
        let first = viewport.documentPoint(from: area.origin, documentSize: document.size)
        let last = viewport.documentPoint(from: CGPoint(x: area.maxX, y: area.maxY), documentSize: document.size)
        let hairline = 1 / viewport.backingScale
        let path = CGMutablePath()
        for column in stride(from: Int(ceil(first.x)), through: Int(floor(last.x)), by: 1) {
            let x = viewport.viewPoint(from: CGPoint(x: CGFloat(column), y: 0), documentSize: document.size).x
            path.addRect(CGRect(x: x - hairline / 2, y: area.minY, width: hairline, height: area.height))
        }
        for row in stride(from: Int(ceil(first.y)), through: Int(floor(last.y)), by: 1) {
            let y = viewport.viewPoint(from: CGPoint(x: 0, y: CGFloat(row)), documentSize: document.size).y
            path.addRect(CGRect(x: area.minX, y: y - hairline / 2, width: area.width, height: hairline))
        }
        context.saveGState()
        context.addPath(path)
        context.setFillColor(NSColor(white: 0.55, alpha: 0.45).cgColor)
        context.fillPath()
        context.restoreGState()
    }

    override func resetCursorRects() {
        if let dragCursor { addCursorRect(bounds, cursor: dragCursor); return }
        if picking { addCursorRect(bounds, cursor: Self.eyedropperCursor); return }
        if session.hueTargeting { addCursorRect(bounds, cursor: .resizeLeftRight); return }
        if session.tool.isSelectionTool, !spaceHeld { addCursorRect(bounds, cursor: lassoCursor); return }
        // Clone Stamp with a source: the brush circle, its preview and the source crosshair stand in
        // for the cursor. Holding Option to pick a new source brings the crosshair back.
        if session.tool == .cloneStamp, session.cloneSource != nil, !optionHeld, !spaceHeld {
            addCursorRect(bounds, cursor: Self.hiddenCursor)
            return
        }
        let cursor: NSCursor = spaceHeld || session.tool == .hand ? .openHand
            // The Move tool's cursor depends on the pointer (handles, Option to duplicate), so match it here.
            : session.tool == .move ? window.map { transformCursor(at: convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? .arrow
            : session.tool == .type ? .iBeam
            : session.tool == .idle ? .arrow
            : session.tool == .zoom ? (optionHeld ? Self.zoomOutCursor : Self.zoomInCursor)
            : .crosshair
        addCursorRect(bounds, cursor: cursor)
        guard session.tool == .crop, !spaceHeld else { return }
        let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        for region in transformOverlay.cropResizeRegions.reversed() {
            let rect = region.rect.intersection(bounds)
            if !rect.isEmpty && !rect.isNull {
                addCursorRect(rect, cursor: .frameResize(position: positions[region.index], directions: [.inward, .outward]))
            }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = nil
        // Every tool hears the mouse leave, so its cursor never follows it out of the canvas;
        // only tools whose cursor depends on where the pointer is also track movement.
        // The picker panel stays key, so sampling must track while this window is not.
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, picking ? .activeAlways : .activeInKeyWindow, .inVisibleRect]
        if picking || session.tool == .move || session.tool.isBrushTool || session.tool.isSelectionTool {
            options.formUnion([.mouseMoved, .cursorUpdate])
        }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }
    private func updateBrushCursor() {
        let shows = session.tool.isBrushTool && !spaceHeld && !picking
        let diameter = session.brushStroke?.settings.diameter ?? session.brushSettings.diameter
        // Clone Stamp also marks where it is copying from and, between strokes, previews inside
        // the circle what a click would stamp there.
        var sample: CGPoint?
        var preview: CGImage?
        if shows, session.tool == .cloneStamp, let pointer = brushPointer, let document = session.document {
            let point = session.viewport.documentPoint(from: pointer, documentSize: document.size)
            if let source = session.cloneSamplePoint(for: point) {
                sample = session.viewport.viewPoint(from: source, documentSize: document.size)
            }
            if session.brushStroke == nil, !optionHeld, let offset = session.cloneStrokeOffset(at: point) {
                preview = clonePreview(center: CGPoint(x: point.x + offset.width, y: point.y + offset.height),
                                       diameter: diameter, document: document)
            }
        }
        brushCursor.update(point: shows ? brushPointer : nil, diameter: max(1, diameter * session.viewport.pointsPerPixel),
                           sample: sample, preview: preview, previewOpacity: session.brushSettings.opacity,
                           tip: preview == nil ? nil : cloneTip(diameter: diameter, hardness: session.brushSettings.hardness),
                           hardness: brushTipDrag?.hardnessShown == true ? session.brushSettings.hardness : nil)
    }

    private var cloneTipCache: (diameter: CGFloat, hardness: CGFloat, image: CGImage?)?

    /// One click's coverage at the current brush size and hardness, painted by the brush engine
    /// itself, so the preview softens exactly as a click would. Rebuilt only when they change.
    private func cloneTip(diameter: CGFloat, hardness: CGFloat) -> CGImage? {
        if let cache = cloneTipCache, cache.diameter == diameter, cache.hardness == hardness { return cache.image }
        var image: CGImage?
        let side = max(1, Int(diameter.rounded(.up)))
        let size = CGSize(width: side, height: side)
        let settings = BrushSettings(diameter: diameter, hardness: hardness, red: 1, green: 1, blue: 1)
        if let stroke = try? BrushStroke(layer: ImageLayer(name: "Tip", blankSize: size), mask: false, settings: settings, canvas: size),
           (try? stroke.append(CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2))) != nil,
           (try? stroke.flush()) != nil,
           let painted = try? stroke.paintSnapshot(),
           let context = try? BrushRaster.context(width: side, height: side, mask: false) {
            BrushRaster.draw(painted.asset.image, in: painted.bounds, mask: false, context: context)
            image = context.makeImage()
        }
        cloneTipCache = (diameter, hardness, image)
        return image
    }

    private struct ClonePreviewKey: Equatable {
        let center: CGPoint
        let diameter: CGFloat
        let scale: CGFloat
        let revision: Int
        let undoCount: Int
        let allLayers: Bool
        let layerID: UUID?
    }
    private var clonePreviewCache: (key: ClonePreviewKey, image: CGImage?)?

    /// What a Clone Stamp click would copy into the brush circle: the source around `center`
    /// (document pixels), rendered for just that area at screen resolution and reused until the
    /// pointer, zoom, brush, or document changes.
    private func clonePreview(center: CGPoint, diameter: CGFloat, document: CanvasDocument) -> CGImage? {
        let scale = session.viewport.pointsPerPixel * session.viewport.backingScale
        let key = ClonePreviewKey(center: center, diameter: diameter, scale: scale, revision: session.brushRevision,
                                  undoCount: session.history.undoCount, allLayers: session.cloneSettings.sampleAllLayers,
                                  layerID: session.activeLayerID)
        if let cache = clonePreviewCache, cache.key == key { return cache.image }
        let side = min(1024, max(1, Int((diameter * scale).rounded(.up))))
        var image: CGImage?
        if diameter > 0, let context = try? BrushRaster.context(width: side, height: side, mask: false) {
            let perPixel = CGFloat(side) / diameter
            context.scaleBy(x: perPixel, y: perPixel)
            context.translateBy(x: diameter / 2 - center.x, y: diameter / 2 - center.y)
            context.interpolationQuality = .medium
            if session.cloneSettings.sampleAllLayers {
                session.drawLiveComposite(document, in: context)
            } else if let layer = session.activeLayer, let source = layer.asset?.image {
                let transform = session.displayedTransform(for: layer)
                LayerRenderer.draw(source, transform: transform, center: transform.center, in: context)
            }
            image = context.makeImage()
        }
        clonePreviewCache = (key, image)
        return image
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        brushPointer = nil
        updateBrushCursor()
        // Tools set their cursor directly while over the canvas, so put the arrow back on the
        // way out. A drag keeps its cursor until mouse-up.
        if NSEvent.pressedMouseButtons == 0 { NSCursor.arrow.set() }
    }
    override func mouseMoved(with event: NSEvent) {
        optionHeld = event.modifierFlags.contains(.option)
        if picking { Self.eyedropperCursor.set(); return }
        if session.tool.isSelectionTool {
            // Keys may have changed while the app was in the background.
            session.updateHeldSelectionKeys(shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option))
            lassoCursor(flags: event.modifierFlags, at: convert(event.locationInWindow, from: nil)).set()
            if session.lassoDraft?.kind == .polygonal, let document = session.document {
                session.moveLassoCursor(to: session.viewport.documentPoint(from: convert(event.locationInWindow, from: nil), documentSize: document.size))
                synchronizeDisplay()
            }
            return
        }
        brushPointer = convert(event.locationInWindow, from: nil)
        updateBrushCursor()
        if session.tool == .move { updateTransformCursor(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags) }
        else { super.mouseMoved(with: event) }
    }
    override func cursorUpdate(with event: NSEvent) {
        if picking { Self.eyedropperCursor.set() }
        else if session.tool.isSelectionTool, !spaceHeld { lassoCursor.set() }
        // Cursor-update events carry no modifier flags (AppKit sends one after every key change), so read
        // the keys as they are now; the event's flags would undo Option's duplicate cursor straight away.
        else if session.tool == .move { updateTransformCursor(at: convert(event.locationInWindow, from: nil), flags: NSEvent.modifierFlags) }
        else { super.cursorUpdate(with: event) }
    }
    private func updateTransformCursor(at point: CGPoint, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        transformCursor(at: point, flags: flags).set()
    }

    /// The Move tool's cursor at a view point. Option over anything a drag would move shows the
    /// copy cursor, since Option-dragging duplicates the layer. Guides sit under handles, over a layer drag.
    private func transformCursor(at point: CGPoint, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> NSCursor {
        if let dragCursor { return dragCursor }
        guard !spaceHeld else { return .openHand }
        guard !session.isProjectBusy, !session.isImporting else { return .arrow }
        let duplicate = flags.contains(.option)
        if let geometry = transformOverlay.geometry, let hit = geometry.hit(point) {
            switch hit {
            case .resize(let index):
                // Distorting (Cmd held, or already distorted) moves corners freely: the white arrow says so.
                let distorting = session.transformEdit?.corners != nil || flags.contains(.command)
                return distorting ? Self.distortCursor : geometry.resizeCursor(for: index)
            case .rotate: return Self.rotationCursor
            case .move: return duplicate ? Self.duplicateCursor : Self.moveCursor
            case .distort: return Self.distortCursor
            }
        }
        if let guide = session.hitGuide(at: point) {
            return guide.axis == .vertical ? .resizeLeftRight : .resizeUpDown
        }
        guard pressMovesLayer(at: point, flags: flags) else { return .arrow }
        return duplicate ? Self.duplicateCursor : Self.moveCursor
    }

    /// Whether a press that misses the transform handles would drag a layer (see `transformPressLayer`).
    private func pressMovesLayer(at point: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
        guard let document = session.document else { return false }
        return transformPressLayer(at: session.viewport.documentPoint(from: point, documentSize: document.size), flags: flags) != nil
    }

    /// The layer a press that misses the transform handles drags, and whether it was picked from under
    /// the pointer. Cmd picks the layer under the pointer; otherwise the active layer, unless auto-select
    /// finds another layer under a press outside it. A press on empty canvas still drags the active
    /// layer: it need not land inside the layer's bounds.
    private func transformPressLayer(at pixel: CGPoint, flags: NSEvent.ModifierFlags) -> (id: UUID, picked: Bool)? {
        guard session.canEditLayers || session.transformEdit != nil, let document = session.document else { return nil }
        let underPointer = document.renderLayers.reversed().first { $0.asset != nil && $0.transform.contains(pixel) }?.id
        let active = session.activeLayer.flatMap { layer in
            layer.asset != nil && !layer.isGroup && document.effectiveVisibleIDs.contains(layer.id) ? layer : nil
        }
        let picks = session.transformEdit == nil
        if flags.contains(.command), picks, let underPointer { return (underPointer, true) }
        // Several layers selected, or a folder: a press inside their box drags them all, and so does one outside it
        // unless auto-select finds a layer there.
        if session.transformsAsGroup, let id = session.activeLayerID {
            let box = session.transformEdit?.draft ?? session.groupTransformBox
            if box?.contains(pixel) == true || !(picks && session.transformAutoSelect) || underPointer == nil { return (id, false) }
        }
        if let active, session.editedTransform(for: active).contains(pixel) { return (active.id, false) }
        if picks, session.transformAutoSelect || flags.contains(.command), let underPointer { return (underPointer, true) }
        return active.map { ($0.id, false) }
    }
    /// Right-drag with a brush tool: left and right resize the brush from its size at the press, or with Shift
    /// change its hardness. The brush circle stays where the press was.
    private var brushTipDrag: (start: CGPoint, diameter: CGFloat, hardness: CGFloat, hardnessShown: Bool)?
    override func rightMouseDown(with event: NSEvent) {
        guard session.tool.isBrushTool, session.brushStroke == nil, session.warpStroke == nil, !spaceHeld else {
            super.rightMouseDown(with: event); return
        }
        let point = convert(event.locationInWindow, from: nil)
        brushTipDrag = (point, session.brushSettings.diameter, session.brushSettings.hardness, event.modifierFlags.contains(.shift))
        brushPointer = point
        updateBrushCursor()
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard let drag = brushTipDrag else { super.rightMouseDragged(with: event); return }
        brushTipDrag?.hardnessShown = event.modifierFlags.contains(.shift)
        let dx = convert(event.locationInWindow, from: nil).x - drag.start.x
        if event.modifierFlags.contains(.shift) {
            // The full range across 200 points.
            session.brushSettings.hardness = min(1, max(0, drag.hardness + dx / 200))
            session.brushSettings.diameter = drag.diameter
        } else {
            // The circle's edge follows the pointer: each point moved widens the radius by a point on screen.
            let perPixel = max(0.0001, session.viewport.pointsPerPixel)
            session.brushSettings.diameter = min(2000, max(1, (drag.diameter + 2 * dx / perPixel).rounded()))
            session.brushSettings.hardness = drag.hardness
        }
        brushPointer = drag.start
        updateBrushCursor()
    }
    override func rightMouseUp(with event: NSEvent) {
        guard brushTipDrag != nil else { super.rightMouseUp(with: event); return }
        brushTipDrag = nil
        brushPointer = convert(event.locationInWindow, from: nil)
        updateBrushCursor()
    }
    override func mouseDown(with event: NSEvent) {
        session.effectSelection = nil
        optionHeld = event.modifierFlags.contains(.option)
        window?.makeFirstResponder(self)
        guard session.document != nil, !session.isProjectBusy, !session.isImporting else { return }
        let point = convert(event.locationInWindow, from: nil)
        if session.levels?.sampleMode != nil, !spaceHeld, let document = session.document {
            session.sampleLevels(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("levelsPanel"))
            return
        }
        if session.levels != nil, !spaceHeld, session.tool != .hand, session.tool != .zoom { return }
        // An open generative panel holds the document, and for Expand the crop frame, as they were sampled.
        if session.generativeEdit != nil, !spaceHeld, session.tool != .hand, session.tool != .zoom {
            FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("generativePanel"))
            return
        }
        if picking, !spaceHeld {
            if session.colorPicker != nil || (palettePicking && session.hueSampleMode == nil) {
                samplingOriginal = session.colorPicker?.color ?? session.foregroundColor
                samplingColor = true
                sampleColor(at: point)
            } else if let document = session.document {
                session.sampleHueRange(at: session.viewport.documentPoint(from: point, documentSize: document.size))
                FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("adjustmentPanel"))
            }
            return
        }
        if session.hueTargeting, !spaceHeld, let document = session.document {
            if session.beginHueTargeting(at: session.viewport.documentPoint(from: point, documentSize: document.size)) {
                hueTargetStart = point
                NSCursor.resizeLeftRight.set()
            }
            return
        }
        if spaceHeld || session.tool == .hand {
            lastDragPoint = point
            NSCursor.closedHand.set()
        } else if session.tool.isBrushTool, let document = session.document {
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            // Option-click with Clone Stamp sets where it copies from (with the other brushes it samples a color).
            if session.tool == .cloneStamp, event.modifierFlags.contains(.option) {
                session.setCloneSource(pixel)
                updateBrushCursor()
                window?.invalidateCursorRects(for: self)
                return
            }
            brushPointer = point
            // Shift paints a straight line on from where the last stroke ended, as in Photoshop.
            if event.modifierFlags.contains(.shift), let from = session.shiftLineStart() {
                session.beginBrush(at: from)
                session.continueBrush(at: pixel)
            } else {
                session.beginBrush(at: pixel)
            }
            brushAxisAnchor = event.modifierFlags.contains(.shift) ? pixel : nil
            brushAxisHorizontal = nil
            brushLastPixel = pixel
            synchronizeDisplay()
        } else if session.tool.isSelectionTool {
            lassoMouseDown(at: point, event: event)
            refreshLassoCursor()
        } else if session.tool == .gradient {
            beginGradientDrag(at: point)
        } else if session.tool == .type {
            beginTextGesture(at: point, event: event)
        } else if session.tool == .shape, let document = session.document {
            session.beginShape(at: session.viewport.documentPoint(from: point, documentSize: document.size))
        } else if session.tool == .crop {
            beginCropDrag(at: point)
        } else if session.tool == .move {
            if beginGuideDrag(at: point) { return }
            beginTransformDrag(at: point, modifiers: event.modifierFlags)
        } else if session.tool == .zoom {
            zoomDrag = (point, session.viewport.zoom, false)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if textBoxAnchor != nil { dragTextGesture(to: point); return }
        if var drag = zoomDrag {
            let dx = point.x - drag.start.x
            if abs(dx) >= 3 { drag.moved = true; zoomDrag = drag }
            // Right zooms in, left out: doubling for every 100 points dragged.
            if drag.moved { session.zoom(to: drag.zoom * pow(2, dx / 100), anchor: drag.start) }
            return
        }
        if samplingColor { sampleColor(at: point); return }
        if let start = hueTargetStart {
            session.dragHueTargeting(byViewDelta: point.x - start.x,
                                     adjustsHue: event.modifierFlags.contains(.command))
            NSCursor.resizeLeftRight.set()
            return
        }
        if let start = pixelDragStart, let document = session.document {
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            session.movePixels(by: CGSize(width: pixel.x - start.x, height: pixel.y - start.y))
            pixelDragCursor(duplicate: session.pixelMove?.duplicate == true).set()
            synchronizeDisplay()
            return
        }
        if selectionDragStart != nil {
            dragSelection(to: point, flags: event.modifierFlags)
            updateMarqueeAutoscroll(at: point)
            Self.moveSelectionCursor.set()
            synchronizeDisplay()
            return
        }
        if session.tool.isSelectionTool, lastDragPoint == nil, let draft = session.lassoDraft, let document = session.document {
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            switch draft.kind {
            case .freehand: session.extendLasso(to: pixel)
            case .polygonal: session.moveLassoCursor(to: pixel)
            case .rectangle, .ellipse:
                dragMarqueeDraft(to: pixel, flags: event.modifierFlags)
                updateMarqueeAutoscroll(at: point)
            }
            synchronizeDisplay()
            return
        }
        if session.shapeDraft != nil, lastDragPoint == nil, let document = session.document {
            // Unlike the Marquee, Option has no other job here, so it draws from the center as in Photoshop.
            session.dragShape(to: session.viewport.documentPoint(from: point, documentSize: document.size),
                              square: event.modifierFlags.contains(.shift), fromCenter: event.modifierFlags.contains(.option))
            synchronizeDisplay()
            return
        }
        if let handle = gradientDrag, let edit = session.gradientEdit, let document = session.document {
            var pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            if event.modifierFlags.contains(.shift) {
                pixel = Self.snapped(pixel, around: handle == .start ? edit.end : edit.start)
            }
            session.moveGradient(start: handle == .start ? pixel : nil, end: handle == .end ? pixel : nil)
            synchronizeDisplay()
            return
        }
        brushPointer = point
        updateBrushCursor()
        if session.brushStroke != nil || session.warpStroke != nil, !session.isProjectBusy, let document = session.document {
            var pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            // Shift keeps the stroke straight, horizontal or vertical, from wherever it was pressed; letting go carries
            // on freehand. The axis is settled by the first few pixels of movement, so it doesn't flip mid-line.
            if event.modifierFlags.contains(.shift) {
                let anchor = brushAxisAnchor ?? brushLastPixel ?? pixel
                if brushAxisAnchor == nil { brushAxisAnchor = anchor; brushAxisHorizontal = nil }
                if brushAxisHorizontal == nil, hypot(pixel.x - anchor.x, pixel.y - anchor.y) >= 3 {
                    brushAxisHorizontal = abs(pixel.x - anchor.x) >= abs(pixel.y - anchor.y)
                }
                if let horizontal = brushAxisHorizontal {
                    pixel = horizontal ? CGPoint(x: pixel.x, y: anchor.y) : CGPoint(x: anchor.x, y: pixel.y)
                } else {
                    pixel = anchor
                }
            } else {
                brushAxisAnchor = nil
                brushAxisHorizontal = nil
            }
            brushLastPixel = pixel
            session.continueBrush(at: pixel)
            synchronizeDisplay()
            return
        }
        if guideDragging, let drag = session.guideDrag, let document = session.document {
            dragCursor?.set()
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            session.moveGuideDrag(to: Double(drag.axis == .vertical ? pixel.x : pixel.y))
            synchronizeDisplay()
            dragCursor?.set()
            return
        }
        if let drag = cropDrag, session.tool == .crop, !session.isProjectBusy, let document = session.document {
            dragCursor?.set()
            dragCrop(drag, to: point, flags: event.modifierFlags, documentSize: document.size)
            synchronizeDisplay()
            dragCursor?.set()
            return
        }
        if let drag = transformDrag, let document = session.document {
            dragCursor?.set()
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            if duplicatesTransformOnDrag {
                duplicatesTransformOnDrag = false
                session.beginDuplicateTransform()
            }
            if let corners = drag.corners(to: pixel, shift: event.modifierFlags.contains(.shift)) {
                session.previewCorners(corners)
                needsDisplay = true
            } else {
                // Dragging, scaling and rotating land on whole pixels and whole degrees; typed values stay exact.
                var draft = drag.updated(to: pixel, lockRatio: session.locksTransformRatio,
                                         shift: event.modifierFlags.contains(.shift),
                                         option: event.modifierFlags.contains(.option)).rounded()
                // Moving snaps to the canvas and the other layers; resizing and rotating are left alone, and
                // Control drags freely.
                if case .move = drag.mode, !event.modifierFlags.contains(.control) {
                    let moving = session.transformEdit?.group.map { Set($0.originals.keys) }
                        ?? Set([session.transformEdit?.layerID].compactMap { $0 })
                    draft = session.snappedMove(draft, moving: moving,
                                                tolerance: TransformSnap.distance / max(session.viewport.pointsPerPixel, 0.0001))
                }
                session.previewTransform(draft)
            }
            synchronizeDisplay()
            dragCursor?.set()
            return
        }
        guard let last = lastDragPoint else { return }
        session.viewport.translate(by: CGSize(width: point.x - last.x, height: point.y - last.y))
        lastDragPoint = point
        redrawRulers()
    }
    override func mouseUp(with event: NSEvent) {
        if textBoxAnchor != nil { finishTextGesture(); return }
        stopMarqueeAutoscroll()
        if let drag = zoomDrag {
            zoomDrag = nil
            if !drag.moved {
                session.zoom(to: session.viewport.zoom * (event.modifierFlags.contains(.option) ? 0.5 : 2), anchor: drag.start)
            }
            return
        }
        session.snapGuides = ([], [])
        if guideDragging {
            session.finishGuideDrag(delete: isOverRuler(convert(event.locationInWindow, from: nil)))
            guideDragging = false
        }
        if samplingColor {
            samplingColor = false
            sampleRing.isHidden = true
            if session.colorPicker != nil { ColorPickerPanelController.refocus() }
            return
        }
        if session.brushStroke != nil || session.warpStroke != nil, !session.isProjectBusy {
            if let document = session.document {
                session.continueBrush(at: session.viewport.documentPoint(from: convert(event.locationInWindow, from: nil), documentSize: document.size))
            }
            session.finishBrushImmediately()
            synchronizeDisplay()
        }
        if gradientDrag != nil {
            gradientDrag = nil
            session.endGradientDrag()
        }
        if session.shapeDraft != nil {
            session.finishShape()
            synchronizeDisplay()
        }
        if hueTargetStart != nil {
            hueTargetStart = nil
            session.endHueTargeting()
        }
        if pixelDragStart != nil {
            pixelDragStart = nil
            Task { await session.finishPixelMove(); synchronizeDisplay(); refreshLassoCursor() }
        }
        if let start = selectionDragStart {
            selectionDragStart = nil
            let moved = session.selectionMoveOrigin != session.selection
            session.endSelectionMove()
            if !moved, session.tool == .wand, session.wandMode == .object {
                Task { await session.selectObject(at: start, mode: .replace); synchronizeDisplay(); refreshLassoCursor() }
            } else if !moved, session.tool == .wand {
                // The wand's click inside the selection selects afresh from that pixel.
                Task { await session.magicWand(at: start, mode: .replace); synchronizeDisplay(); refreshLassoCursor() }
            } else if !moved {
                // A click without a drag deselects, as anywhere else with the lasso.
                session.deselect()
            }
            synchronizeDisplay()
            refreshLassoCursor()
        }
        if session.tool.isSelectionTool, let kind = session.lassoDraft?.kind, kind != .polygonal {
            session.finishLasso()
            synchronizeDisplay()
            refreshLassoCursor()
        }
        cropDrag = nil
        if transformDrag != nil {
            duplicatesTransformOnDrag = false
            transformDrag = nil
            if session.transformEdit?.persistent == false { session.commitTransform() }
        }
        lastDragPoint = nil
        // Leaving mid-drag keeps the drag's cursor, so a drag released outside the canvas (over
        // the Layers panel, say) must put the arrow back itself.
        if !visibleRect.contains(convert(event.locationInWindow, from: nil)) { NSCursor.arrow.set() }
        window?.invalidateCursorRects(for: self)
    }
    override func scrollWheel(with event: NSEvent) {
        guard transformDrag == nil, cropDrag == nil, !guideDragging, session.brushStroke == nil, session.warpStroke == nil else { return }
        guard session.document != nil else { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            session.zoom(to: session.viewport.zoom * exp(-event.scrollingDeltaY * 0.015),
                         anchor: convert(event.locationInWindow, from: nil))
        } else {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            session.viewport.translate(by: CGSize(width: event.scrollingDeltaX * multiplier,
                                                  height: event.scrollingDeltaY * multiplier))
            redrawRulers()
        }
    }
    override func magnify(with event: NSEvent) {
        guard transformDrag == nil, cropDrag == nil, !guideDragging, session.brushStroke == nil, session.warpStroke == nil else { return }
        session.zoom(to: session.viewport.zoom * (1 + event.magnification),
                     anchor: convert(event.locationInWindow, from: nil))
    }
    override func keyDown(with event: NSEvent) {
        let physicalKey = event.keyCode
        guard let event = ShortcutSettings.shared.canvasEvent(event) else { return }
        if event.keyCode == 53, textBoxAnchor != nil { textBoxAnchor = nil; textBoxRect = nil; needsDisplay = true; return }
        if event.keyCode == 53, session.textDraft != nil { session.cancelText(); return }
        // A drag session swallows the flagsChanged that says Option was let go, which left the canvas thinking it
        // was still held — and with it the Eyedropper standing in for the Brush. Every key press re-reads it.
        optionHeld = event.modifierFlags.contains(.option)
        if [51, 117].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift {
            if session.canContentAwareFill { session.beginFilter(.contentAwareFill) }
            return
        }
        if let edit = session.levels {
            if event.keyCode == 53 { session.cancelLevels(); return }
            if [36, 76].contains(event.keyCode) { Task { await session.commitLevels() }; return }
            if event.charactersIgnoringModifiers?.lowercased() == "p", event.modifierFlags.contains(.option) {
                session.updateLevels(edit.settings, preview: !edit.preview); return
            }
            if event.keyCode != 49 { super.keyDown(with: event); return }
        }
        if session.generativeEdit != nil {
            if event.keyCode == 53 { session.cancelGenerative(); return }
            if [36, 76].contains(event.keyCode) { session.keepGenerative(); return }
            if event.keyCode != 49 { super.keyDown(with: event); return } // Space still pans.
        }
        if session.brushStroke != nil || session.warpStroke != nil {
            if event.keyCode == 53 && !session.isProjectBusy { session.cancelBrush(); synchronizeDisplay() }
            return
        }
        if session.lassoDraft != nil, [53, 36, 76, 51, 117].contains(event.keyCode) {
            if event.keyCode == 53 { session.cancelLasso() }
            else if [36, 76].contains(event.keyCode) { session.finishLasso() }
            else { session.removeLastLassoPoint() }
            synchronizeDisplay()
            refreshLassoCursor()
        } else if session.shapeDraft != nil, event.keyCode == 53 {
            session.cancelShape()
            synchronizeDisplay()
        } else if session.gradientEdit != nil, event.keyCode == 53 {
            gradientDrag = nil
            session.cancelGradient()
        } else if session.gradientEdit != nil, [36, 76].contains(event.keyCode) {
            gradientDrag = nil
            Task { await session.commitGradient() }
        } else if session.tool == .crop, event.keyCode == 53 {
            cropDrag = nil
            session.cancelCrop()
        } else if session.tool == .crop, [36, 76].contains(event.keyCode) {
            cropDrag = nil
            Task { await session.commitCrop() }
        } else if event.keyCode == 53, session.guideDrag != nil {
            session.cancelGuideDrag()
            guideDragging = false
        } else if event.keyCode == 53, session.transformEdit != nil {
            transformDrag = nil
            session.cancelTransform()
        } else if [36, 76].contains(event.keyCode), session.transformEdit != nil {
            transformDrag = nil
            session.commitTransform()
        } else if session.selection?.isEmpty == false, session.lassoDraft == nil, [123, 124, 125, 126].contains(event.keyCode),
                  event.modifierFlags.contains(.command), event.modifierFlags.intersection([.control, .option]).isEmpty {
            // Cmd-arrow moves the selected pixels in any tool; Shift for 10 px.
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            Task { await session.nudgePixels(dx: dx, dy: dy); synchronizeDisplay() }
        } else if session.tool.isSelectionTool, session.lassoDraft == nil, session.selection?.isEmpty == false,
                  [123, 124, 125, 126].contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            session.nudgeSelection(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                   dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
        } else if session.tool == .move, [123, 124, 125, 126].contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            session.nudgeLayer(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                               dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
        } else if (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            session.deleteKeyPressed()
        } else if event.keyCode == 48, session.textDraft == nil, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            // Tab switches the current tool's mode (Rectangle/Ellipse, Paint/Erase, and so on).
            session.cycleToolMode()
            refreshLassoCursor()
            updateBrushCursor()
        } else if event.keyCode == 49 {
            panPhysicalKey = physicalKey
            spaceHeld = true
            updateBrushCursor()
            window?.invalidateCursorRects(for: self)
        } else if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "x": session.swapPaletteColors()
            case "d": session.resetPaletteColors()
            case "b": session.selectTool(.brush); session.brushMode = .paint
            case "e": session.selectTool(.brush); session.brushMode = .erase
            case "j": session.selectTool(.spotHealing)
            case "s": session.selectTool(.cloneStamp)
            case "t": session.selectTool(.type)
            case "g": session.selectTool(.gradient)
            case "u":
                if event.modifierFlags.contains(.shift), session.tool == .shape { session.toggleShapeKind() }
                else { session.selectTool(.shape) }
            case "i": session.selectTool(.eyedropper)
            // M chooses the Marquee in whichever shape it was last set to; the shape is switched in the tool
            // bar. Ignoring a repeat keeps holding the key from doing anything odd.
            case "m": if !event.isARepeat { session.pressMarqueeKey(); refreshLassoCursor() }
            case "w": if !event.isARepeat { session.pressWandKey(); refreshLassoCursor() }
            // L chooses the Lasso the same way; Freehand/Polygonal is switched in the tool bar.
            case "l": if !event.isARepeat { session.pressLassoKey(); refreshLassoCursor() }
            case let key? where Int(key) != nil && session.usesOpacityKeys:
                session.typeOpacityDigit(Int(key) ?? 0)
            case "[" where session.tool.isBrushTool: session.changeBrushSize(increase: false)
            case "]" where session.tool.isBrushTool: session.changeBrushSize(increase: true)
            // Shift turns [ and ] into { and }.
            case "{" where session.tool.isBrushTool: session.changeBrushHardness(increase: false)
            case "}" where session.tool.isBrushTool: session.changeBrushHardness(increase: true)
            case "a": session.selectTool(.idle)
            case "r": session.selectTool(.blur)
            case "c": session.selectTool(.crop)
            case "v": session.selectTool(.move)
            case "h": session.selectTool(.hand)
            case "z": session.selectTool(.zoom)
            default: super.keyDown(with: event)
            }
        } else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == panPhysicalKey || (panPhysicalKey == nil && event.keyCode == 49) {
            panPhysicalKey = nil
            spaceHeld = false
            updateBrushCursor()
            window?.invalidateCursorRects(for: self)
        } else { super.keyUp(with: event) }
    }
    override func resignFirstResponder() -> Bool {
        if !session.isProjectBusy { session.cancelBrush() }
        brushPointer = nil
        updateBrushCursor()
        cropDrag = nil
        gradientDrag = nil
        session.cancelShape()
        if let kind = session.lassoDraft?.kind, kind != .polygonal { session.cancelLasso() }
        if selectionDragStart != nil { selectionDragStart = nil; session.endSelectionMove() }
        if pixelDragStart != nil { pixelDragStart = nil; session.cancelPixelMove() }
        if let drag = transformDrag {
            duplicatesTransformOnDrag = false
            session.previewTransform(drag.original)
            if session.transformEdit?.persistent == false { session.cancelTransform() }
            transformDrag = nil
        }
        spaceHeld = false
        lastDragPoint = nil
        return super.resignFirstResponder()
    }

    /// How far, in points per frame, the view pans toward a pointer at `point`: nothing well inside the canvas,
    /// speeding up from the last few points before the edge to however far past it the pointer has gone.
    private func marqueeAutoscrollDelta(at point: CGPoint) -> CGSize {
        let rect = visibleRect, margin: CGFloat = 12
        func speed(_ past: CGFloat) -> CGFloat { past <= 0 ? 0 : min(40, 2 + past * 0.4) }
        let left = speed(rect.minX + margin - point.x), right = speed(point.x - (rect.maxX - margin))
        let top = speed(rect.minY + margin - point.y), bottom = speed(point.y - (rect.maxY - margin))
        // Pointer past the right edge: the document slides left to bring what's beyond into view.
        return CGSize(width: left - right, height: top - bottom)
    }
    private func updateMarqueeAutoscroll(at point: CGPoint) {
        marqueeAutoscrollPoint = point
        guard marqueeAutoscrollDelta(at: point) != .zero else { stopMarqueeAutoscroll(); return }
        guard marqueeAutoscroll == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepMarqueeAutoscroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        marqueeAutoscroll = timer
    }
    private func stepMarqueeAutoscroll() {
        let marquee = session.lassoDraft.map { $0.kind == .rectangle || $0.kind == .ellipse } == true
        guard let point = marqueeAutoscrollPoint, let document = session.document,
              marquee || selectionDragStart != nil else { stopMarqueeAutoscroll(); return }
        let delta = marqueeAutoscrollDelta(at: point)
        guard delta != .zero else { stopMarqueeAutoscroll(); return }
        session.viewport.translate(by: delta)
        // The pointer hasn't moved, but the document has under it: the box's corner, or the moved selection, follows.
        if selectionDragStart != nil { dragSelection(to: point, flags: NSEvent.modifierFlags) }
        else { dragMarqueeDraft(to: session.viewport.documentPoint(from: point, documentSize: document.size), flags: NSEvent.modifierFlags) }
        synchronizeDisplay()
    }
    /// Moves a dragged selection so the pixel grabbed sits under `point`. Shift keeps the move on one axis:
    /// whichever way the drag has gone further.
    private func dragSelection(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let start = selectionDragStart, let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        var offset = CGSize(width: pixel.x - start.x, height: pixel.y - start.y)
        if flags.contains(.shift) {
            if abs(offset.width) >= abs(offset.height) { offset.height = 0 } else { offset.width = 0 }
        }
        session.moveSelection(by: offset)
    }
    private func stopMarqueeAutoscroll() {
        marqueeAutoscroll?.invalidate()
        marqueeAutoscroll = nil
        marqueeAutoscrollPoint = nil
    }

    /// Reshapes the Marquee draft. Option subtracts (chosen at the press), so it never draws from the
    /// center. Shift squares the box — except a Shift already held when the drag began, which chose Add,
    /// until it has been let go and pressed again, as in Photoshop.
    private func dragMarqueeDraft(to pixel: CGPoint, flags: NSEvent.ModifierFlags) {
        if !flags.contains(.shift) { marqueeConstrainArmed = true }
        marqueeDragPixel = pixel
        session.dragMarquee(to: pixel, square: marqueeConstrainArmed && flags.contains(.shift), fromCenter: false)
    }

    /// Freehand starts an outline to drag. Polygonal adds a corner per click and closes on
    /// a click near the first corner or a double-click. Modifiers at the first click pick
    /// the mode: Shift adds, Option subtracts.
    private func lassoMouseDown(at point: CGPoint, event: NSEvent) {
        guard let document = session.document else { return }
        // A Shift held at the press means Add; for the Marquee it squares only once pressed afresh.
        marqueeConstrainArmed = !event.modifierFlags.contains(.shift)
        marqueeDragPixel = nil
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        guard let draft = session.lassoDraft, draft.kind == .polygonal else {
            // Cmd-drag inside the selection cuts and moves its pixels (Photoshop's temporary Move tool).
            if event.modifierFlags.contains(.command), session.canMoveSelection(at: pixel) {
                if session.beginPixelMove(duplicate: event.modifierFlags.contains(.option)) {
                    pixelDragStart = pixel
                    pixelDragCursor(duplicate: event.modifierFlags.contains(.option)).set()
                } else { NSSound.beep() }
                return
            }
            let mode = session.selectionMode(shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option))
            // In New mode, dragging inside the selection moves its outline instead of drawing.
            if mode == .replace, session.canMoveSelection(at: pixel), session.beginSelectionMove() {
                selectionDragStart = pixel
                Self.moveSelectionCursor.set()
                return
            }
            if session.tool == .wand, session.wandMode == .object {
                Task { await session.selectObject(at: pixel, mode: mode); synchronizeDisplay(); refreshLassoCursor() }
                return
            }
            if session.tool == .wand {
                Task { await session.magicWand(at: pixel, mode: mode); synchronizeDisplay(); refreshLassoCursor() }
                return
            }
            session.beginLasso(at: pixel, mode: mode)
            synchronizeDisplay()
            return
        }
        let first = session.viewport.viewPoint(from: draft.points[0], documentSize: document.size)
        if event.clickCount >= 2 || (draft.points.count >= 3 && hypot(point.x - first.x, point.y - first.y) <= 8) {
            session.finishLasso()
        } else {
            session.extendLasso(to: pixel)
        }
        synchronizeDisplay()
    }

    /// Marching ants animate only while a visible selection exists.
    private func updateAntsTimer() {
        let active = session.selection?.isEmpty == false && window != nil
        if active, antsTimer == nil {
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.transformOverlay.antsPhase = (self.transformOverlay.antsPhase + 1).truncatingRemainder(dividingBy: 8)
                self.transformOverlay.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            antsTimer = timer
        } else if !active, let timer = antsTimer {
            timer.invalidate()
            antsTimer = nil
        }
    }

    /// Grabs an existing endpoint, or starts a new line at the pointer.
    private func beginGradientDrag(at point: CGPoint) {
        guard let document = session.document else { return }
        if let geometry = transformOverlay.gradientLine {
            if hypot(point.x - geometry.end.x, point.y - geometry.end.y) <= 10 { gradientDrag = .end; return }
            if hypot(point.x - geometry.start.x, point.y - geometry.start.y) <= 10 { gradientDrag = .start; return }
        }
        session.beginGradient(at: session.viewport.documentPoint(from: point, documentSize: document.size))
        gradientDrag = session.gradientEdit == nil ? nil : .end
        synchronizeDisplay()
    }

    /// Shift constrains the line to 45° steps, as in Photoshop.
    private static func snapped(_ point: CGPoint, around anchor: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
    }

    private func sampleColor(at point: CGPoint) {
        guard let document = session.document else { return }
        Self.eyedropperCursor.set()
        let documentPoint = session.viewport.documentPoint(from: point, documentSize: document.size)
        if session.colorPicker != nil { session.sampleIntoColorPicker(at: documentPoint) }
        else if session.canEditPalette, let color = session.sampleCompositeColor(at: documentPoint) {
            session.foregroundColor = color
        }
        sampleRing.frame = CGRect(x: point.x - 58, y: point.y - 58, width: 116, height: 116)
        sampleRing.original = samplingOriginal
        sampleRing.sampled = session.colorPicker?.color ?? session.foregroundColor
        sampleRing.isHidden = !session.showsSampleRing
        sampleRing.needsDisplay = true
    }

    private var renderBounds: CGRect? {
        guard let document = session.document else { return nil }
        let original = CGRect(origin: .zero, size: document.size)
        let shown = session.tool == .crop ? original.union(session.cropRect ?? original) : original
        return session.generativeEdit.map { shown.union($0.bounds) } ?? shown
    }

    private func beginCropDrag(at point: CGPoint) {
        guard let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        let rect = session.visibleCropRect ?? CGRect(origin: pixel, size: .zero)
        let mode: CropDrag.Mode
        if let region = transformOverlay.cropResizeRegions.first(where: { $0.rect.contains(point) }) {
            mode = .resize(region.index)
        } else if session.cropRect?.contains(pixel) == true,
                  rect != CGRect(origin: .zero, size: document.size) { mode = .move }
        else { mode = .create; session.cropRect = nil }
        cropDrag = CropDrag(start: pixel, original: rect, mode: mode)
        let targets = session.cropSnapTargets()
        cropSnap = CropSnap(xs: targets.xs, ys: targets.ys, tolerance: Self.cropSnapDistance / max(session.viewport.pointsPerPixel, 0.0001))
        dragCursor = .current
        cursorLockWindow = window
        cursorLockWindow?.disableCursorRects()
        dragCursor?.set()
    }

    /// Reshapes the crop frame for the pointer at `point` (view coordinates): Option keeps the frame's center
    /// fixed, and edges snap to nearby layer and canvas edges unless Control is held.
    private func dragCrop(_ drag: CropDrag, to point: CGPoint, flags: NSEvent.ModifierFlags, documentSize: CGSize) {
        let pixel = session.viewport.documentPoint(from: point, documentSize: documentSize)
        let symmetric = flags.contains(.option)
        var next = drag.updated(to: pixel, ratio: session.cropRatio, symmetric: symmetric)
        if let cropSnap, session.snappingEnabled, !flags.contains(.control) {
            next = cropSnap.apply(next, drag: drag, point: pixel, ratio: session.cropRatio, symmetric: symmetric)
        }
        if CropGeometry.valid(next) { session.cropRect = next }
    }

    private func beginGuideDrag(at point: CGPoint) -> Bool {
        guard session.canEditGuides, let guide = session.hitGuide(at: point) else { return false }
        session.beginGuideMove(guide)
        guideDragging = true
        dragCursor = guide.axis == .vertical ? .resizeLeftRight : .resizeUpDown
        cursorLockWindow = window
        cursorLockWindow?.disableCursorRects()
        dragCursor?.set()
        return true
    }

    /// Released on the top or left ruler strip, which sits just outside the canvas.
    func isOverRuler(_ point: CGPoint) -> Bool {
        session.showsRulers && (point.x < 0 || point.y < 0)
    }

    func documentPosition(axis: CanvasGuide.Axis, at point: CGPoint) -> Double? {
        guard let document = session.document else { return nil }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        return Double(axis == .vertical ? pixel.x : pixel.y)
    }

    private func beginTransformDrag(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard session.canEditLayers || session.transformEdit != nil, let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        var mode = transformOverlay.geometry?.hit(point)
        if mode == nil, let target = transformPressLayer(at: pixel, flags: modifiers) {
            // Cmd-Shift-click adds the layer under the pointer to the selection (and takes it out again); Cmd-click
            // on its own selects just that one.
            if target.picked, modifiers.contains(.command), modifiers.contains(.shift) {
                session.extendSelection(with: target.id)
            } else if target.picked {
                session.selectLayer(target.id)
            }
            mode = .move
        }
        guard var mode else { return }
        if case .move = mode { duplicatesTransformOnDrag = modifiers.contains(.option) }
        else { duplicatesTransformOnDrag = false }
        if session.transformEdit == nil { session.beginTransform(persistent: false) }
        // Cmd-dragging a handle distorts, as in Photoshop; once distorted, handles keep distorting.
        if case .resize(let index) = mode, modifiers.contains(.command) || session.transformEdit?.corners != nil {
            session.beginDistort()
            if session.transformEdit?.corners != nil { mode = .distort(index) }
        }
        guard let transform = session.transformEdit?.draft else { return }
        transformDrag = TransformDrag(original: transform, start: pixel, mode: mode, originalCorners: session.transformEdit?.corners)
        switch mode {
        case .resize(let index): dragCursor = transformOverlay.geometry?.resizeCursor(for: index) ?? .arrow
        case .rotate: dragCursor = Self.rotationCursor
        case .move: dragCursor = duplicatesTransformOnDrag ? Self.duplicateCursor : Self.moveCursor
        case .distort: dragCursor = Self.distortCursor
        }
        cursorLockWindow = window
        cursorLockWindow?.disableCursorRects()
        dragCursor?.set()
    }

    private func releaseDragCursor() {
        guard transformDrag == nil, cropDrag == nil, !guideDragging, dragCursor != nil else { return }
        dragCursor = nil
        cursorLockWindow?.enableCursorRects()
        cursorLockWindow?.invalidateCursorRects(for: self)
        cursorLockWindow = nil
        if let window, session.tool == .move {
            updateTransformCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }
}
