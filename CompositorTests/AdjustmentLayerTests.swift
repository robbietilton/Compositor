import AppKit
import Testing
@testable import Compositor

@MainActor struct AdjustmentLayerTests {
    func image(_ color: PaletteColor, alpha: [UInt8] = [255,255,255,255]) throws -> ImportedImage {
        let bytes = alpha.flatMap { a in [UInt8((color.red*CGFloat(a)).rounded()), UInt8((color.green*CGFloat(a)).rounded()), UInt8((color.blue*CGFloat(a)).rounded()), a] }
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return ImportedImage(image: image, thumbnail: image, name: "Fixture")
    }
    func pixels(_ image: CGImage) throws -> [UInt8] {
        let ctx = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0,y: 0,width: image.width,height: image.height), mask: false, context: ctx)
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width*image.height*4))
    }
    func rendered(_ session: EditorSession) async throws -> [UInt8] {
        try pixels(await ImageExporter.shared.render(#require(session.projectSnapshot())).image)
    }
    func add(_ kind: AdjustmentKind, to s: EditorSession) throws -> UUID {
        s.addAdjustment(kind); s.adjustmentEditingID = nil
        return try #require(s.activeLayerID)
    }
    @Test func globalAdjustmentAffectsBelowButNotAboveAndRemainsLive() async throws {
        let s = EditorSession(); s.createDocument(width: 2,height: 2)
        s.insert(try image(.white))
        let base = try #require(s.activeLayerID)
        let adjustment = try add(.levels, to: s)
        var settings = LayerAdjustment(kind: .levels); settings.levels.ranges[0].outputWhite = 0
        s.updateAdjustment(adjustment, value: settings)
        #expect(try await rendered(s) == [0,0,0,255,0,0,0,255,0,0,0,255,0,0,0,255])
        s.insert(try image(PaletteColor(red: 1,green: 0,blue: 0), alpha: [255,0,0,0]))
        #expect(Array(try await rendered(s).prefix(4)) == [255,0,0,255])
        s.document?.layers[0].asset = try image(PaletteColor(red: 0,green: 0,blue: 1))
        #expect(s.document?.layers[0].id == base)
        #expect(Array(try await rendered(s)[4..<8]) == [0,0,0,255])
        s.selectLayer(adjustment); s.toggleLayerVisibility(adjustment)
        #expect(Array(try await rendered(s)[4..<8]) == [0,0,255,255])
    }
    @Test func clippedCurveChangesOnlyItsBaseAndCopyMergedMatchesExport() async throws {
        let s = EditorSession(); s.createDocument(width: 2,height: 2)
        s.insert(try image(PaletteColor(red: 0,green: 0,blue: 1)))
        s.insert(try image(PaletteColor(red: 0,green: 1,blue: 0), alpha: [255,0,128,0]))
        let adjustment = try add(.curves, to: s)
        var settings = LayerAdjustment(kind: .curves)
        settings.curves.channels[0] = [CurvePoint(x: 0,y: 255),CurvePoint(x: 255,y: 0)]
        s.updateAdjustment(adjustment, value: settings)
        s.toggleClippingMask(adjustment)
        let result = try await rendered(s)
        #expect(Array(result[0..<4]) == [255,0,255,255])
        #expect(Array(result[4..<8]) == [0,0,255,255])
        #expect(try pixels(#require(s.renderMergedPixels()?.image)) == result)
        s.toggleClippingMask(adjustment)
        #expect(Array(try await rendered(s)[4..<8]) == [255,255,0,255])
    }
    @Test func hueOpacityAndMaskPreserveOriginalPixels() async throws {
        let s = EditorSession(); s.createDocument(width: 2,height: 2)
        s.insert(try image(PaletteColor(red: 1,green: 0,blue: 0)))
        let original = s.document?.layers[0].asset?.image
        let id = try add(.hsv, to: s)
        var value = LayerAdjustment(kind: .hsv); value.hue = 120
        s.updateAdjustment(id, value: value)
        let result = try await rendered(s)
        #expect(result[1] > 250 && result[0] < 5 && result[2] < 5)
        s.document?.layers[1].opacity = 0
        #expect(Array(try await rendered(s).prefix(4)) == [255,0,0,255])
        s.document?.layers[1].opacity = 1
        s.document?.layers[1].mask = LayerMask.solid(revealing: false)
        #expect(Array(try await rendered(s).prefix(4)) == [255,0,0,255])
        #expect(s.document?.layers[0].asset?.image === original)
    }
    @Test func adjustmentPersistsDuplicatesAndUndoRestoresSettings() async throws {
        let s = EditorSession(); s.createDocument(width: 2,height: 2)
        s.insert(try image(.white))
        let id = try add(.curves, to: s)
        var value = LayerAdjustment(kind: .curves); value.curves.channels[0].insert(CurvePoint(x: 128,y: 190), at: 1)
        s.beginEdit("Edit Curves"); s.updateAdjustment(id, value: value); s.endEdit()
        s.undo(); #expect(s.activeLayer?.adjustment?.curves == CurvesSettings())
        s.redo(); #expect(s.activeLayer?.adjustment == value)
        s.duplicateActiveLayer(); #expect(s.activeLayer?.adjustment == value)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Adjustment-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(#require(s.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.last?.adjustment == value)
        let restored = EditorSession(); restored.installProject(loaded, from: url)
        #expect(try await rendered(restored) == rendered(s))
    }
    @Test func curvesIdentityAndImageCommandPreserveAlpha() async throws {
        let asset = try image(PaletteColor(red: 0.4,green: 0.7,blue: 0.1), alpha: [255,128,32,0])
        #expect(try pixels(CurvesSettings().apply(asset.image)) == pixels(asset.image))
        let s = EditorSession(); s.createDocument(width: 2,height: 2); s.insert(asset)
        s.beginFilter(.curves)
        var settings = FilterSettings(); settings.curves.channels[0] = [CurvePoint(x: 0,y: 255),CurvePoint(x: 255,y: 255)]
        s.updateFilter(settings, preview: true); await s.commitFilter()
        let p = try pixels(#require(s.activeLayer?.asset?.image))
        #expect(p == [255,255,255,255,128,128,128,128,32,32,32,32,0,0,0,0])
        s.undo(); #expect(s.activeLayer?.asset?.image === asset.image)
    }
    @Test func adjustmentBlendAndSoftMaskPreserveCoverage() async throws {
        let s = EditorSession(); s.createDocument(width: 2, height: 2)
        s.insert(try image(PaletteColor(red: 1, green: 0, blue: 0), alpha: [255,128,32,0]))
        let id = try add(.hsv, to: s)
        var value = LayerAdjustment(kind: .hsv); value.hue = 120
        s.updateAdjustment(id, value: value)
        s.setLayerBlendMode(.multiply)
        #expect(try await rendered(s) == [0,0,0,255,0,0,0,128,0,0,0,32,0,0,0,0])
        s.setLayerBlendMode(.normal)
        let gray = try BrushRaster.context(width: 1, height: 1, mask: true)
        gray.data!.assumingMemoryBound(to: UInt8.self)[0] = 128
        s.document?.layers[1].mask = LayerMask(asset: try LayerMask.asset(from: #require(gray.makeImage())))
        let p = try await rendered(s)
        #expect(p[3] == 255 && p[7] == 128 && p[11] == 32 && p[15] == 0)
        #expect(abs(Int(p[0]) - 127) <= 2 && abs(Int(p[1]) - 128) <= 2)
    }
}

@MainActor struct AdjustmentEditorTests {
    /// Invert is the one adjustment with nothing to set: adding it applies straight away rather
    /// than opening an editor, and it inverts what is underneath without touching those pixels.
    @Test func invertAppliesWithoutAnEditor() throws {
        let fixtures = AdjustmentLayerTests()
        let session = EditorSession()
        session.createDocument(width: 2, height: 2)
        session.insert(try fixtures.image(.white))
        session.addAdjustment(.invert)
        #expect(session.adjustmentEditingID == nil, "nothing to edit, so no editor opens")
        let adjustment = try #require(session.activeLayer?.adjustment)
        #expect(adjustment.kind == .invert)
        #expect(!adjustment.kind.isEditable)

        let context = try BrushRaster.context(width: 2, height: 2, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let source = try #require(context.makeImage())
        let inverted = try adjustment.apply(source)
        let before = try pixel(of: source), after = try pixel(of: inverted)
        #expect(abs(Int(before.r) + Int(after.r) - 255) <= 1)
        #expect(abs(Int(before.g) + Int(after.g) - 255) <= 1)
        #expect(abs(Int(before.b) + Int(after.b) - 255) <= 1)
        #expect(after.a == before.a, "transparency is left alone")
    }

    private func pixel(of image: CGImage) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var px = [UInt8](repeating: 0, count: 4)
        try px.withUnsafeMutableBytes { buf in
            let ctx = try BrushRaster.context(width: 1, height: 1, mask: false)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: ctx)
            let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<4 { buf[i] = data[i] }
        }
        return (px[0], px[1], px[2], px[3])
    }

    // Invert has no settings and so no editor; it is covered on its own.
    @Test(arguments: AdjustmentKind.allCases.filter(\.isEditable))
    func sharedEditorsKeepPixelsDynamicAndSupportCancel(_ kind: AdjustmentKind) async throws {
        let fixtures = AdjustmentLayerTests()
        let session = EditorSession()
        session.createDocument(width: 2, height: 2)
        let asset = try fixtures.image(.white)
        session.insert(asset)
        let baseID = try #require(session.activeLayerID)
        session.addAdjustment(kind)
        let id = try #require(session.adjustmentEditingID)
        // As created: a Gradient Map takes the palette's colors and a Grain layer its own pattern.
        let created = try #require(session.activeLayer?.adjustment)
        await session.beginAdjustmentEditing(id)
        #expect(session.adjustmentOriginal?.kind == kind)
        #expect(!session.showsBusy)
        switch kind {
        case .invert: return   // filtered out above: no editor to share
        case .levels:
            let edit = try #require(session.levels)
            await edit.histogramTask?.value
            #expect(edit.histogramReady)
            #expect(edit.histogram[0][255] == 4)
            var settings = edit.settings
            settings.ranges[0].outputWhite = 0
            session.updateLevels(settings, preview: true)
            #expect(session.activeLayer?.adjustment?.levels == settings)
            session.updateLevels(settings, preview: false)
            #expect(session.activeLayer?.adjustment == LayerAdjustment(kind: kind))
            await session.commitLevels()
        case .curves:
            var settings = try #require(session.filterEdit).settings
            settings.curves.channels[0] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 255, y: 0)]
            session.updateFilter(settings, preview: true)
            #expect(session.activeLayer?.adjustment?.curves == settings.curves)
            await session.commitFilter()
        case .exposure, .gradientMap, .grain, .blackWhite, .colorBalance, .gaussianBlur, .motionBlur, .addNoise:
            #expect(session.filterEdit?.kind == kind.filterKind)
            var settings = try #require(session.filterEdit).settings
            switch kind {
            case .blackWhite: settings.blackWhite.reds = 100
            case .colorBalance: settings.colorBalance.midCyanRed = 50
            case .exposure: settings.exposure.exposure = 1
            case .gradientMap: settings.gradientMap.reversed = true
            case .gaussianBlur: settings.radius = 24
            case .motionBlur: settings.angle = 35; settings.distance = 48
            case .addNoise: settings.amount = 35; settings.gaussian = true; settings.monochromatic = true
            default: settings.grain.amount = 70
            }
            session.updateFilter(settings, preview: true)
            let live = try #require(session.activeLayer?.adjustment)
            #expect(live.exposure == settings.exposure && live.gradientMap == settings.gradientMap && live.grain == settings.grain)
            if kind == .gaussianBlur { #expect(live.gaussianRadius == 24) }
            if kind == .motionBlur { #expect(live.resolvedMotionAngle == 35 && live.resolvedMotionDistance == 48) }
            if kind == .addNoise {
                #expect(live.resolvedNoiseAmount == 35 && live.resolvedNoiseGaussian && live.resolvedNoiseMonochromatic)
            }
            await session.commitFilter()
        case .hsv:
            var settings = try #require(session.hueSaturation).settings
            settings.range = .reds
            settings.hue = 80
            settings.band = settings.band.centered(on: 25)
            settings.invertRange = true
            session.updateHueSaturation(settings, preview: true)
            #expect(session.activeLayer?.adjustment?.resolvedHSV == settings)
            await session.commitHueSaturation()
        }
        let saved = try #require(session.activeLayer?.adjustment)
        #expect(session.adjustmentEditingID == nil)
        #expect(session.document?.layers.first { $0.id == baseID }?.asset?.image === asset.image)
        #expect(session.activeLayer?.asset == nil)
        let encoded = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(LayerAdjustment.self, from: encoded) == saved)
        session.adjustmentEditingID = id
        await session.beginAdjustmentEditing(id)
        switch kind {
        case .invert: return   // filtered out above: nothing to reopen
        case .levels:
            #expect(session.levels?.settings == saved.levels)
            session.updateLevels(LevelsSettings(), preview: true)
            session.cancelLevels()
        case .curves, .exposure, .gradientMap, .grain, .blackWhite, .colorBalance, .gaussianBlur, .motionBlur, .addNoise:
            let reopened = try #require(session.filterEdit).settings
            #expect(reopened.curves == saved.curves && reopened.exposure == saved.exposure
                    && reopened.gradientMap == saved.gradientMap && reopened.grain == saved.grain
                    && reopened.blackWhite == saved.blackWhite && reopened.colorBalance == saved.colorBalance)
            #expect(reopened.radius == saved.gaussianRadius && reopened.angle == saved.resolvedMotionAngle
                    && reopened.distance == saved.resolvedMotionDistance)
            #expect(reopened.amount == saved.resolvedNoiseAmount && reopened.gaussian == saved.resolvedNoiseGaussian
                    && reopened.monochromatic == saved.resolvedNoiseMonochromatic)
            session.updateFilter(FilterSettings(), preview: true)
            session.cancelFilter()
        case .hsv:
            #expect(session.hueSaturation?.settings == saved.resolvedHSV)
            session.updateHueSaturation(HueSaturationSettings(), preview: true)
            session.cancelHueSaturation()
        }
        #expect(session.activeLayer?.adjustment == saved)
        #expect(session.adjustmentEditingID == nil)
        session.undo()
        #expect(session.activeLayer?.adjustment == created)
        session.redo()
        #expect(session.activeLayer?.adjustment == saved)
    }

    @Test func legacyHSVStillDecodesAndRenders() throws {
        let data = try JSONEncoder().encode(LayerAdjustment(kind: .hsv, hue: 120))
        let decoded = try JSONDecoder().decode(LayerAdjustment.self, from: data)
        #expect(decoded.hsvSettings == nil)
        #expect(decoded.resolvedHSV.hue == 120)
    }
}
