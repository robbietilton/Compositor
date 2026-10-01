import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// The tool options bar: what a tool's bar ends with stays at the end when the bar has room to spare, as on the Mac.
@MainActor struct PadToolOptionsTests {
    /// A 400 × 300 canvas with one layer on it.
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        return session
    }

    /// `session`'s bar, `width` points wide and laid out.
    private func bar(for session: EditorSession, width: CGFloat) -> ToolOptionsBar {
        let bar = ToolOptionsBar(frame: CGRect(x: 0, y: 0, width: width, height: ToolOptionsBar.height))
        bar.session = session
        bar.updatePropertiesIfNeeded()
        bar.layoutIfNeeded()
        return bar
    }

    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// How far `view` ends from the bar's right edge.
    private func gap(after view: UIView, in bar: ToolOptionsBar) -> CGFloat {
        bar.bounds.maxX - view.convert(view.bounds, to: bar).maxX
    }

    /// Painting on a mask, the Brush bar says so at its end.
    @Test func theBrushBarSaysMaskAtItsEnd() throws {
        let session = try session()
        session.addMask(revealing: true)
        session.isMaskSelected = true
        session.selectTool(.brush)
        let bar = bar(for: session, width: 2400)
        let mask = try #require(views(UILabel.self, in: bar).first { $0.text == "Mask" })
        #expect(abs(gap(after: mask, in: bar) - 18) < 1)
    }

    /// A transform waiting for them has Cancel and Apply at the Transform bar's end.
    @Test func applySitsAtTheTransformBarsEnd() throws {
        let session = try session()
        session.selectTool(.move)
        session.beginTransform()
        let bar = bar(for: session, width: 2400)
        let apply = try #require(views(UIButton.self, in: bar).first { $0.configuration?.title == "Apply" })
        #expect(abs(gap(after: apply, in: bar) - 18) < 1)
    }

    /// With a selection, Deselect sits at the selection tools' bar's end.
    @Test func deselectSitsAtTheSelectionBarsEnd() throws {
        let session = try session()
        session.selectTool(.marquee)
        session.selectAll()
        let bar = bar(for: session, width: 2400)
        let deselect = try #require(views(UIButton.self, in: bar).first { $0.configuration?.title == "Deselect" })
        #expect(abs(gap(after: deselect, in: bar) - 18) < 1)
    }

    /// A gradient waiting for them has Cancel and Apply at the Gradient bar's end.
    @Test func applySitsAtTheGradientBarsEnd() throws {
        let session = try session()
        session.selectTool(.gradient)
        session.beginGradient(at: CGPoint(x: 10, y: 10))
        session.moveGradient(end: CGPoint(x: 200, y: 10))
        let bar = bar(for: session, width: 2400)
        let apply = try #require(views(UIButton.self, in: bar).first { $0.configuration?.title == "Apply" })
        #expect(abs(gap(after: apply, in: bar) - 18) < 1)
    }

    /// The Crop bar has Cancel and Apply Crop at its end.
    @Test func applyCropSitsAtTheCropBarsEnd() throws {
        let session = try session()
        session.selectTool(.crop)
        let bar = bar(for: session, width: 1032)
        let apply = try #require(views(UIButton.self, in: bar).first { $0.configuration?.title == "Apply Crop" })
        #expect(abs(gap(after: apply, in: bar) - 18) < 1)
    }
}
