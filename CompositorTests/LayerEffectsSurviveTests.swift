import AppKit
import Testing
@testable import Compositor

/// A layer's effects, and a text or shape layer's live style, stay with it through the edits that rebuild the layer:
/// canvas and image size, crop, trim, Hue/Saturation, Levels, Invert and transforming a selection.
@MainActor
struct LayerEffectsSurviveTests {
    private let effects = LayerEffects(stroke: StrokeEffect(size: 4), shadow: ShadowEffect(distance: 20, blur: 10),
                                       outerGlow: OuterGlowEffect(size: 8))

    /// What a layer carries beyond its pixels.
    private struct Extras: Equatable {
        var effects: LayerEffects?
        var text: LayerTextStyle?
        var shape: LayerShapeStyle?
    }
    private func extras(_ session: EditorSession, _ ids: [UUID]) -> [Extras?] {
        ids.map { id in
            session.document?.layers.first { $0.id == id }
                .map { Extras(effects: $0.effects, text: $0.liveText?.style, shape: $0.liveShape?.style) }
        }
    }

    /// A transparent document with a text layer and a shape layer, both carrying `effects`.
    private func textAndShape() throws -> (session: EditorSession, ids: [UUID]) {
        let session = EditorSession()
        session.createDocument(width: 200, height: 120, emptyLayer: true)
        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 30, y: 60))
        var draft = try #require(session.textDraft)
        draft.style.content = "Text"
        #expect(session.applyText(draft))
        let text = try #require(session.activeLayerID)
        session.selectTool(.shape)
        session.beginShape(at: CGPoint(x: 120, y: 30))
        session.dragShape(to: CGPoint(x: 170, y: 80), square: false, fromCenter: false)
        session.finishShape()
        let shape = try #require(session.activeLayerID)
        try #require(shape != text)
        for id in [text, shape] {
            let index = try #require(session.document?.layers.firstIndex { $0.id == id })
            session.document?.layers[index].effects = effects
        }
        let before = extras(session, [text, shape])
        try #require(before[0]?.text != nil && before[1]?.shape != nil)
        return (session, [text, shape])
    }

    /// A gray square on a transparent document, its layer carrying `effects`.
    private func pixelLayer() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 48, height: 48)
        let context = try BrushRaster.context(width: 24, height: 24, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.7, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 3, y: 3, width: 18, height: 18))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Sample"))
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].effects = effects
        return session
    }

    @Test func canvasSizeKeepsEffectsTextAndShapes() async throws {
        let (session, ids) = try textAndShape()
        let before = extras(session, ids)
        let resized = try await CanvasResizer.shared.resize(try #require(session.projectSnapshot()),
            to: CanvasSizeOptions(width: 260, height: 160, anchor: 4))
        session.applyDocumentSize(resized, actionName: "Canvas Size")
        #expect(session.document?.width == 260)
        #expect(extras(session, ids) == before)
    }

    @Test func cropKeepsEffectsTextAndShapes() async throws {
        let (session, ids) = try textAndShape()
        let before = extras(session, ids)
        session.selectTool(.crop)
        session.cropRect = CGRect(x: 10, y: 10, width: 180, height: 100)
        await session.commitCrop()
        #expect(session.document?.width == 180)
        #expect(extras(session, ids) == before)
    }

    @Test func trimKeepsEffectsTextAndShapes() async throws {
        let (session, ids) = try textAndShape()
        let before = extras(session, ids)
        #expect(try await session.trim())
        #expect((session.document?.width ?? 200) < 200)
        #expect(extras(session, ids) == before)
    }

    @Test func resolutionOnlyImageSizeKeepsEffectsTextAndShapes() async throws {
        let (session, ids) = try textAndShape()
        let before = extras(session, ids)
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 200, height: 120, resolution: 300))
        session.applyImageSize(resized)
        #expect(session.document?.resolution == 300)
        #expect(extras(session, ids) == before)
    }

    /// The layer's pixels are resampled, so its effects are scaled with them, as Photoshop's Scale Styles does.
    @Test func imageSizeKeepsEffectsScaledWithTheImage() async throws {
        let session = try pixelLayer()
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 24, height: 24, resolution: 72))
        session.applyImageSize(resized)
        #expect(session.document?.width == 24)
        let kept = try #require(session.activeLayer?.effects)
        #expect(kept.stroke?.size == 2 && kept.outerGlow?.size == 4)
        #expect(kept.shadow?.distance == 10 && kept.shadow?.blur == 5 && kept.shadow?.angle == effects.shadow?.angle)
    }

    @Test func hueSaturationKeepsEffects() async throws {
        let session = try pixelLayer()
        var settings = HueSaturationSettings()
        settings.adjustments[.master] = RangeAdjustment(hue: 90)
        session.beginHueSaturation()
        session.updateHueSaturation(settings, preview: true)
        await session.hueSaturationTask?.value
        await session.commitHueSaturation()
        #expect(session.history.undoName == "Hue/Saturation")
        #expect(session.activeLayer?.effects == effects)
    }

    @Test func levelsKeepsEffects() async throws {
        let session = try pixelLayer()
        var settings = LevelsSettings()
        settings.current = LevelRange(black: 64, gamma: 1, white: 128)
        session.beginLevels()
        session.updateLevels(settings, preview: true)
        await session.commitLevels()
        #expect(session.history.undoName == "Levels")
        #expect(session.activeLayer?.effects == effects)
    }

    @Test func invertKeepsEffects() async throws {
        let session = try pixelLayer()
        await session.invertPixels()
        #expect(session.history.undoName == "Invert")
        #expect(session.activeLayer?.effects == effects)
    }

    @Test func transformingASelectionKeepsEffects() async throws {
        let session = try pixelLayer()
        let source = try #require(session.activeLayerID)
        session.applySelection(CGPath(rect: CGRect(x: 14, y: 14, width: 10, height: 10), transform: nil), mode: .replace, name: "Select")
        await session.beginSelectionTransform()
        var draft = try #require(session.transformEdit?.draft)
        draft.origin.x += 8
        session.previewTransform(draft)
        session.commitTransform()
        #expect(session.history.undoName == "Transform Selection")
        #expect(session.document?.layers.first { $0.id == source }?.effects == effects)
    }
}
