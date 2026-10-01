import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// What the on-canvas text editor works out on every platform: where it shows the text, how a handle resizes its box,
/// what typing does to the text's colors, and the text as the canvas draws it.
@MainActor struct TextEditingTests {
    private func draft(_ style: LayerTextStyle = LayerTextStyle(), transform: LayerTransform? = nil) -> TextDraft {
        TextDraft(documentID: UUID(), layerID: nil, origin: CGPoint(x: 40, y: 30), transform: transform, style: style)
    }

    /// Point text on a layer grows as it's typed at the layer's own scale, its top-left corner staying put, rotated or
    /// not; without a transform, the editor stands at the draft's origin.
    @Test func pointTextGrowsAtTheLayersScale() {
        let shown = LayerTransform(origin: CGPoint(x: 100, y: 100), size: CGSize(width: 200, height: 100), rotation: 30)
        let grown = draft(transform: shown).shownTransform(logicalSize: CGSize(width: 150, height: 60), layerWidth: 100)
        #expect(grown.size == CGSize(width: 300, height: 120))
        #expect(abs(grown.point(.zero).x - shown.point(.zero).x) < 0.0001 && abs(grown.point(.zero).y - shown.point(.zero).y) < 0.0001)

        let fresh = draft().shownTransform(logicalSize: CGSize(width: 150, height: 60), layerWidth: nil)
        #expect(fresh.origin == CGPoint(x: 40, y: 30) && fresh.size == CGSize(width: 150, height: 60))
    }

    /// A handle turns point text into a box of the size it shows at, which then resizes from the edge dragged, the
    /// opposite edge staying put, and no smaller than a box can be.
    @Test func aHandleResizesTheBox() throws {
        let shown = LayerTransform(origin: CGPoint(x: 100, y: 100), size: CGSize(width: 400, height: 200), rotation: 0)
        let boxed = draft().boxed(logicalSize: CGSize(width: 200, height: 100), shown: shown)
        #expect(boxed.style.boxSize == CGSize(width: 200, height: 100) && boxed.transform == shown && boxed.origin == shown.origin)
        #expect(boxed.boxed(logicalSize: CGSize(width: 50, height: 50), shown: shown).style.boxSize == CGSize(width: 200, height: 100))

        // The right edge, 50 document pixels out, at twice the box's own scale.
        let wider = try #require(boxed.resized(handle: 3, from: shown, start: CGPoint(x: 500, y: 200), to: CGPoint(x: 550, y: 200)))
        #expect(wider.style.boxSize == CGSize(width: 225, height: 100))
        #expect(wider.transform?.size == CGSize(width: 450, height: 200) && wider.transform?.origin == shown.origin)

        let narrowest = try #require(boxed.resized(handle: 3, from: shown, start: CGPoint(x: 500, y: 200), to: CGPoint(x: -500, y: 200)))
        #expect(narrowest.style.boxSize?.width == 16)
    }

    /// Typing into colored text keeps each letter's color: the runs move with the change.
    @Test func typingKeepsTheLettersColors() throws {
        let session = EditorSession()
        var style = LayerTextStyle()
        style.content = "Hello"
        style.setColor(PaletteColor(red: 1, green: 0, blue: 0), in: NSRange(location: 0, length: 5))
        session.textDraft = draft(style)

        let pending = session.textStyle(replacing: NSRange(location: 0, length: 0), with: "Oh, ", after: nil)
        let changed = try #require(session.textDraft(changedTo: "Oh, Hello", selection: NSRange(location: 4, length: 0), pending: pending))
        #expect(changed.style.content == "Oh, Hello" && changed.style.isValid)
        #expect(changed.style.color(at: 4) == PaletteColor(red: 1, green: 0, blue: 0))
        #expect(changed.selection == NSRange(location: 4, length: 0))

        // Without the runs moved for it, a change can't keep them.
        let unexplained = try #require(session.textDraft(changedTo: "Hi", selection: NSRange(location: 2, length: 0), pending: nil))
        #expect(unexplained.style.colorRuns == nil)
    }

    /// The text as the canvas draws it: rendered once for each style, where the editor shows it, and nothing without a
    /// draft or an editor.
    @Test func theTextIsRenderedOncePerStyle() throws {
        let session = EditorSession()
        let rendering = TextDraftRendering(session: session)
        let shown = LayerTransform(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 300, height: 120), rotation: 0)
        #expect(rendering.text(shownAt: shown) == nil)
        var style = LayerTextStyle()
        style.content = "Type"
        session.textDraft = draft(style)
        #expect(rendering.text(shownAt: nil) == nil)
        let first = try #require(rendering.text(shownAt: shown))
        let second = try #require(rendering.text(shownAt: shown))
        #expect(first.image === second.image && first.transform == shown)
        session.textDraft?.style.content = "Typed"
        #expect(try #require(rendering.text(shownAt: shown)).image !== first.image)
    }
}
