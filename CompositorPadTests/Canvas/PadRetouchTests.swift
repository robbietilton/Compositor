import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// Spot Healing and Clone Stamp on iPad: in the rail and on their keys, their bars, Clone Stamp's source, which a touch
/// sets and moves, and the brush cursor, as the Mac's.
@MainActor struct PadRetouchTests {
    /// A 400 × 300 canvas fitted to a view its size, with one red layer covering it and a green square in its middle.
    private func session(_ tool: NavigationTool = .cloneStamp) throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 180, y: 130, width: 40, height: 40))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        session.selectTool(tool)
        return session
    }

    /// The canvas point over document pixel (`x`, `y`).
    private func point(_ x: CGFloat, _ y: CGFloat, in session: EditorSession) -> CGPoint {
        session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: CGSize(width: 400, height: 300))
    }

    private func near(_ a: CGPoint?, _ b: CGPoint, within tolerance: CGFloat = 0.001) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// The active layer's pixel at (`x`, `y`), its red, green and blue.
    private func layerPixel(_ session: EditorSession, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        let context = try BrushRaster.copy(try #require(session.activeLayer?.asset?.image))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let i = y * context.bytesPerRow + x * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// J and S choose Spot Healing and Clone Stamp on a keyboard, as on the Mac, and both work by touch.
    @Test func theToolsAreInTheRailAndOnTheirKeys() throws {
        #expect(ToolRailView.touchTools.isSuperset(of: [.spotHealing, .cloneStamp]))
        let window = EditorWindowController()
        let tools = Dictionary((window.keyCommands ?? []).compactMap { command -> (String, NavigationTool)? in
            guard let input = command.input, command.modifierFlags.isEmpty, let raw = command.propertyList as? String,
                  let tool = NavigationTool(rawValue: raw) else { return nil }
            return (input, tool)
        }, uniquingKeysWith: { first, _ in first })
        #expect(tools["j"] == .spotHealing)
        #expect(tools["s"] == .cloneStamp)
        #expect(StatusBarView.hint(for: try session(.spotHealing), fingerPaints: true).hasPrefix("Drag over blemishes to heal"))
        let cloning = try session(.cloneStamp)
        #expect(StatusBarView.hint(for: cloning, fingerPaints: true).hasPrefix("Tap where to copy from"))
        cloning.setCloneSource(CGPoint(x: 10, y: 10))
        #expect(StatusBarView.hint(for: cloning, fingerPaints: true).hasPrefix("Drag to clone"))
    }

    /// The Spot Healing bar chooses how it heals, and the Clone Stamp bar whether strokes keep their alignment and what
    /// they copy from, and says how to set a source until there is one, as the Mac's bars do.
    @Test func theBarsSetHowTheToolsHealAndClone() throws {
        let session = try session(.spotHealing)
        let bar = ToolOptionsBar(frame: CGRect(x: 0, y: 0, width: 2400, height: ToolOptionsBar.height))
        bar.session = session
        bar.updatePropertiesIfNeeded()
        let modes = SpotHealingMode.allCases
        let types = try #require(views(UISegmentedControl.self, in: bar).first { $0.titleForSegment(at: 0) == modes[0].rawValue })
        #expect(types.numberOfSegments == modes.count && types.selectedSegmentIndex == 0)
        types.selectedSegmentIndex = 2
        types.sendActions(for: .valueChanged)
        #expect(session.spotHealingMode == modes[2])

        session.selectTool(.cloneStamp)
        bar.setNeedsUpdateProperties()
        bar.updatePropertiesIfNeeded()
        let aligned = try #require(views(UIButton.self, in: bar).first { $0.configuration?.title == "Aligned" })
        #expect(aligned.isSelected)
        aligned.isSelected = false
        aligned.sendActions(for: .primaryActionTriggered)
        #expect(!session.cloneSettings.aligned)
        let sample = try #require(views(UISegmentedControl.self, in: bar).first { $0.titleForSegment(at: 1) == "All Layers" })
        #expect(sample.selectedSegmentIndex == 0)
        sample.selectedSegmentIndex = 1
        sample.sendActions(for: .valueChanged)
        #expect(session.cloneSettings.sampleAllLayers)
        let hint = try #require(views(UILabel.self, in: bar).first { $0.text == "Tap where to copy from" })
        #expect(!hint.isHidden)
        session.setCloneSource(CGPoint(x: 10, y: 10))
        bar.setNeedsUpdateProperties()
        bar.updatePropertiesIfNeeded()
        #expect(hint.isHidden)
    }

    /// Before there's a source, a touch that would paint sets it where it lands, and moves it until it lifts; a finger
    /// that moves the canvas leaves it be. Other tools have no source to mark.
    @Test func theFirstTouchSetsTheSource() throws {
        let session = try session()
        session.zoom(to: 1)
        let input = PadCanvasInput(session: session)
        #expect(input.cloneSourceMark(brush: nil) == nil)
        #expect(!input.beginSourceDrag(at: point(200, 150, in: session), paints: false))
        #expect(session.cloneSource == nil)
        #expect(input.beginSourceDrag(at: point(200, 150, in: session)))
        #expect(input.isDraggingSource)
        input.moved(to: point(210, 140, in: session))
        input.ended(at: point(210, 140, in: session))
        #expect(near(session.cloneSource, CGPoint(x: 210, y: 140)) && !input.isDraggingSource)
        #expect(near(input.cloneSourceMark(brush: nil), CGPoint(x: 210, y: 140)))
        session.selectTool(.brush)
        #expect(input.cloneSourceMark(brush: nil) == nil)
    }

    /// With a source, a touch on its crosshair moves it, a finger too while fingers move the canvas, and an Option-tap
    /// sets it where it lands, as an Option-click does on the Mac. A touch anywhere else is left to paint.
    @Test func aTouchMovesTheSourceAndAnOptionTapSetsIt() throws {
        let session = try session()
        session.zoom(to: 1)
        session.setCloneSource(CGPoint(x: 200, y: 150))
        let input = PadCanvasInput(session: session)
        #expect(!input.beginSourceDrag(at: point(60, 60, in: session)))
        #expect(near(session.cloneSource, CGPoint(x: 200, y: 150)))
        // Within a fingertip of the crosshair, which keeps its place under the finger.
        #expect(input.beginSourceDrag(at: point(210, 160, in: session), paints: false))
        input.moved(to: point(310, 210, in: session))
        input.ended(at: point(310, 210, in: session))
        #expect(near(session.cloneSource, CGPoint(x: 300, y: 200)))
        #expect(near(input.cloneSourceMark(brush: nil), CGPoint(x: 300, y: 200)) && !input.isDragging)

        #expect(input.beginSourceDrag(at: point(40, 250, in: session), keys: .alternate))
        input.ended(at: point(40, 250, in: session), keys: .alternate)
        #expect(near(session.cloneSource, CGPoint(x: 40, y: 250)))
    }

    /// The crosshair stays on the source until a stroke, then keeps its offset from the brush as it paints. After the
    /// stroke it stays where the stroke left the source while strokes keep their alignment; without, it's back on the
    /// source.
    @Test func aStrokeCopiesFromTheSourceAndTheCrosshairFollows() throws {
        let session = try session()
        session.zoom(to: 1)
        session.brushSettings.diameter = 10
        session.brushSettings.hardness = 1
        session.brushSettings.opacity = 1
        let input = PadCanvasInput(session: session)
        #expect(input.beginSourceDrag(at: point(200, 150, in: session)))
        input.ended(at: point(200, 150, in: session))
        #expect(near(input.cloneSourceMark(brush: CGPoint(x: 60, y: 60)), CGPoint(x: 200, y: 150)))
        #expect(!input.beginSourceDrag(at: point(60, 60, in: session)))
        session.beginBrush(at: CGPoint(x: 60, y: 60))
        session.continueBrush(at: CGPoint(x: 70, y: 60))
        #expect(near(input.cloneSourceMark(brush: CGPoint(x: 70, y: 60)), CGPoint(x: 210, y: 150)))
        #expect(session.finishBrushImmediately())
        input.strokeEnded(at: CGPoint(x: 70, y: 60))
        #expect(near(input.cloneSourceMark(brush: nil), CGPoint(x: 210, y: 150)))
        // The green square's middle, copied over the red.
        let copied = try layerPixel(session, x: 65, y: 60)
        #expect(copied.g > 200 && copied.r < 40, "\(copied)")
        session.cloneSettings.aligned = false
        #expect(near(input.cloneSourceMark(brush: nil), CGPoint(x: 200, y: 150)))
    }

    /// The brush cursor, as the Mac's: the brush's circle where the brush is, around a crosshair. With Clone Stamp and a
    /// source, the crosshair marks the source instead, and the circle previews what a stroke would stamp, until Option
    /// is held to set another.
    @Test func theCursorIsTheMacs() throws {
        let session = try session()
        session.zoom(to: 1)
        session.brushSettings.diameter = 30
        let canvas = PadCanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        canvas.synchronizeBrushCursor()
        var cursor = try #require(canvas.overlayView.brushCursor)
        #expect(cursor.point == nil && cursor.sample == nil)

        let at = point(100, 100, in: session)
        canvas.hover(at: at)
        cursor = try #require(canvas.overlayView.brushCursor)
        #expect(cursor.point == at && cursor.diameter == 30 && cursor.crosshair && cursor.sample == nil && cursor.preview == nil)

        session.setCloneSource(CGPoint(x: 200, y: 150))
        canvas.synchronizeBrushCursor()
        cursor = try #require(canvas.overlayView.brushCursor)
        #expect(!cursor.crosshair && near(cursor.sample, point(200, 150, in: session)) && cursor.preview != nil && cursor.tip != nil)

        canvas.hover(at: at, keys: .alternate)
        cursor = try #require(canvas.overlayView.brushCursor)
        #expect(cursor.crosshair && cursor.preview == nil)

        session.selectTool(.spotHealing)
        canvas.hover(at: at)
        cursor = try #require(canvas.overlayView.brushCursor)
        #expect(cursor.crosshair && cursor.sample == nil && cursor.preview == nil)
        session.selectTool(.move)
        canvas.synchronizeBrushCursor()
        #expect(canvas.overlayView.brushCursor == nil)
    }
}
