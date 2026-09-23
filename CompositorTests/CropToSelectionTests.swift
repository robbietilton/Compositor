import AppKit
import Testing
@testable import Compositor

@MainActor
struct CropToSelectionTests {
    @Test func cropsBoundsPreservingLayerStateAndUndo() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80, emptyLayer: true)
        session.setPaletteColor(PaletteColor(red: 1, green: 0, blue: 0), background: false)
        await session.fillSelection(with: .foreground)
        session.document?.layers[0].opacity = 0.6
        session.document?.layers[0].effects = LayerEffects()
        session.document?.guides = [CanvasGuide(id: UUID(), axis: .vertical, position: 25)]
        session.applySelection(CGPath(rect: CGRect(x: 10, y: 20, width: 40, height: 30), transform: nil),
                               mode: .replace, name: "Select")
        let before = try #require(session.document)
        let count = session.history.undoCount
        session.cropToSelection()
        #expect(session.document?.size == CGSize(width: 40, height: 30))
        #expect(session.selection == nil)
        var expected = before.layers[0]
        expected.transform.origin = CGPoint(x: -10, y: -20)
        #expect(session.document?.layers[0] == expected)
        #expect(session.document?.guides[0].position == 15)
        #expect(session.history.undoCount == count + 1)
        let output = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(output.width == 40 && output.height == 30)
        session.undo()
        #expect(session.document == before)
        session.redo()
        #expect(session.document?.size == CGSize(width: 40, height: 30))
    }

    @Test func cropToolStartsFromOutwardRoundedSelectionBoundsAndCancels() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80)
        session.document?.selection = DocumentSelection(path: CGPath(ellipseIn:
            CGRect(x: 10.2, y: 20.4, width: 30.2, height: 20.1), transform: nil), feather: 4)
        let before = session.document
        session.selectTool(.crop)
        #expect(session.cropRect == CGRect(x: 10, y: 20, width: 31, height: 21))
        session.cancelCrop()
        #expect(session.document == before)
    }

    @Test func missingEmptyOrOutsideSelectionCannotCrop() {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80)
        for path in [CGMutablePath(), CGPath(rect: CGRect(x: 200, y: 200, width: 5, height: 5), transform: nil)] {
            session.document?.selection = DocumentSelection(path: path)
            let before = session.document
            #expect(!session.canCropToSelection)
            session.cropToSelection()
            #expect(session.document == before)
        }
        session.document?.selection = nil
        #expect(!session.canCropToSelection)
    }
    @Test func cropPreservesEditableLayersAndExplicitMaskPlacement() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80, emptyLayer: true)
        await session.fillSelection(with: .foreground)
        let image = try #require(session.activeLayer?.asset?.image)
        session.document?.layers[0].text = LayerText(style: LayerTextStyle(), image: image)
        session.document?.layers[0].effects = LayerEffects(stroke: StrokeEffect())
        session.addLayerMask()
        session.document?.layers[0].mask?.placement = LayerTransform(origin: CGPoint(x: 7, y: 9), size: CGSize(width: 60, height: 40))
        session.document?.layers[0].mask?.isLinked = false
        session.isMaskSelected = false
        var shape = try #require(session.activeLayer)
        shape.text = nil
        shape.shape = LayerShape(style: LayerShapeStyle(kind: .ellipse, red: 1, green: 0, blue: 0, cornerRadius: 0), image: image)
        // Give the second layer its own identity while preserving its editable content.
        let second = ImageLayer(id: UUID(), asset: shape.asset, name: "Shape", isVisible: true,
            transform: shape.transform, shape: shape.shape, effects: shape.effects)
        session.document?.layers.append(second)
        session.document?.selection = DocumentSelection(path: CGPath(rect:
            CGRect(x: 10, y: 20, width: 40, height: 30), transform: nil))
        let before = try #require(session.document)
        session.cropToSelection()
        #expect(session.document?.layers[0].liveText == before.layers[0].liveText)
        #expect(session.document?.layers[1].liveShape == before.layers[1].liveShape)
        #expect(session.document?.layers[0].effects == before.layers[0].effects)
        #expect(session.document?.layers[0].mask?.placement?.origin == CGPoint(x: -3, y: -11))
        #expect(session.document?.layers[0].mask?.isLinked == false)
        session.undo()
        #expect(session.document == before)
    }
}
