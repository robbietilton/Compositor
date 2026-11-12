import AppKit
import Testing
@testable import Compositor

@MainActor
struct BrushDynamicsTests {
    private let size = CGSize(width: 512, height: 128)
    private func make(_ options: RoundBrushDynamics, diameter: CGFloat = 32, hardness: CGFloat = 1, opacity: CGFloat = 1,
                      pressure: Bool = false, gpu: Bool = true, seed: UInt64 = 42) throws -> BrushStroke {
        var settings = BrushSettings(diameter: diameter, hardness: hardness, red: 1, opacity: opacity)
        settings.roundDynamics = options
        settings.pressureSize = pressure; settings.pressureOpacity = pressure
        return try BrushStroke(layer: ImageLayer(name: "Blank", blankSize: size), mask: false,
            settings: settings, canvas: size, useGPU: gpu, seed: seed)
    }
    private func trace(_ stroke: BrushStroke, steps: Int, flush: Bool = true, ramp: Bool = false) throws {
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            try stroke.append(CGPoint(x: 32 + 448 * t, y: 64),
                input: BrushInput(pressure: ramp ? 0.2 + 0.8 * t : 0.6, timestamp: Double(t), deviceID: 7))
        }
        if flush { try stroke.flush() }
    }
    private func raster(_ stroke: BrushStroke) throws -> CGContext {
        let context = try BrushRaster.context(width: 512, height: 128, mask: false)
        LayerRenderer.drawBrushPreview(stroke.layer.asset?.image, transform: stroke.paintTransform, center: stroke.paintTransform.center,
            scale: 1, opacity: 1, blendMode: .normal, mask: nil, patches: stroke.patches,
            pixelWidth: stroke.width, pixelHeight: stroke.height, paintingMask: false, in: context)
        return context
    }
    private func alpha(_ context: CGContext, _ x: Int, _ y: Int) -> Int {
        Int(context.data!.assumingMemoryBound(to: UInt8.self)[y * context.bytesPerRow + x * 4 + 3])
    }
    private func difference(_ a: CGContext, _ b: CGContext) -> Int {
        let x = a.data!.assumingMemoryBound(to: UInt8.self), y = b.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(a.bytesPerRow * a.height)).map { abs(Int(x[$0]) - Int(y[$0])) }.max() ?? 0
    }

    @Test func pressureCurveValidationAndLegacyDefaults() throws {
        let identity = PressureCurve()
        #expect(identity.isValid && identity.isIdentity && identity.value(0.37) == 0.37)
        let curve = PressureCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.2), .init(x: 1, y: 1)])
        #expect(curve.isValid && curve.value(0.25) > 0.05 && curve.value(0.25) < 0.1 && curve.value(.nan) == 1)
        for points: [PressureCurve.Point] in [[], [.init(x: 0, y: -0.1), .init(x: 1, y: 1)],
            [.init(x: 0, y: 0), .init(x: 0, y: 0.2), .init(x: 1, y: 1)],
            [.init(x: 0, y: 0), .init(x: 0.3, y: 1.1), .init(x: 1, y: 1)]] {
            #expect(!PressureCurve(points: points).isValid)
        }
        #expect(!RoundBrushDynamics().usesStamps)
        var options = RoundBrushDynamics(); options.angle = 1; options.scatter = 1
        #expect(!options.usesStamps, "Angle/scatter alone cannot change a circle")
        options.pressureCurve = curve
        let untouched = try make(RoundBrushDynamics()), buttonsOff = try make(options)
        try trace(untouched, steps: 8); try trace(buttonsOff, steps: 8)
        #expect(difference(try raster(untouched), try raster(buttonsOff)) == 0, "A curve with both pressure mappings off must not change the renderer or pixels")
        let brush = try make(options, pressure: true)
        try brush.append(CGPoint(x: 256, y: 64), pressure: 0.5); try brush.flush()
        let image = try raster(brush)
        #expect(alpha(image, 256, 64) <= 52 && alpha(image, 256, 64) >= 49)
        #expect(alpha(image, 262, 64) == 0, "The curve must affect actual tip size")
    }

    @Test func pressureCurvesEaseThroughPointsAndAllowBellResponse() throws {
        let curve = PressureCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.2), .init(x: 1, y: 1)])
        let epsilon: CGFloat = 0.0001
        let left = (curve.value(0.5) - curve.value(0.5 - epsilon)) / epsilon
        let right = (curve.value(0.5 + epsilon) - curve.value(0.5)) / epsilon
        #expect(abs(left - right) < 0.01, "The curve must have no angular corner at its control point")
        var straight = curve
        for index in straight.points.indices { straight.points[index].easing = 0 }
        #expect(abs(straight.value(0.25) - 0.1) < 0.000001)
        #expect(abs(straight.value(0.25) - curve.value(0.25)) > 0.01, "Per-point easing must change the evaluated curve")
        #expect(try JSONDecoder().decode(PressureCurve.self, from: JSONEncoder().encode(straight)) == straight)
        var endpointEase = PressureCurve()
        endpointEase.points[0].easing = 1
        #expect(!endpointEase.isIdentity && endpointEase.value(0.25) < 0.25, "Endpoint easing must also change the response")
        straight.points[1].easing = .nan
        #expect(!straight.isValid)
        let bell = PressureCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 1), .init(x: 1, y: 0)])
        #expect(bell.isValid && bell.value(0.5) == 1 && bell.value(1) == 0)
        for profile in PressureCurve.Profile.allCases {
            let recipe = profile.curve
            #expect(recipe.isValid)
            #expect(try JSONDecoder().decode(PressureCurve.self, from: JSONEncoder().encode(recipe)) == recipe)
            for point in recipe.points { #expect(abs(recipe.value(point.x) - point.y) < 0.000001) }
            for step in 0...1000 { #expect((0...1).contains(recipe.value(CGFloat(step) / 1000))) }
        }
        var options = RoundBrushDynamics(); options.pressureCurve = bell
        options.shape = ShapeBrushSettings(source: .custom, customTip: asymmetricBrushShapeTip())
        let mid = try make(options, pressure: true), high = try make(options, pressure: true)
        try mid.append(CGPoint(x: 256, y: 64), input: BrushInput(pressure: 0.5)); try mid.flush()
        try high.append(CGPoint(x: 256, y: 64), input: BrushInput(pressure: 1)); try high.flush()
        #expect(!mid.patches.isEmpty && high.patches.isEmpty, "Bell must affect actual custom-tip size/opacity")
        let mouse = try make(options, pressure: true)
        try mouse.append(CGPoint(x: 256, y: 64), input: BrushInput()); try mouse.flush()
        #expect(difference(try raster(mid), try raster(mouse)) == 0, "Missing pressure must retain full-strength mouse painting")
        for step in 0...1000 {
            let x = CGFloat(step) / 1000
            #expect((0...1).contains(bell.value(x)))
            #expect(abs(bell.value(x) - bell.value(1 - x)) < 0.00001)
        }
    }

    @Test func flowSpacingCountAndOpacityAreRealDabControls() throws {
        var options = RoundBrushDynamics(); options.flow = 0.1; options.spacing = 1
        let one = try make(options, opacity: 0.4)
        try one.append(CGPoint(x: 256, y: 64)); try one.flush()
        #expect(abs(alpha(try raster(one), 256, 64) - 10) <= 1)
        options.count = 4
        let four = try make(options, opacity: 0.4)
        try four.append(CGPoint(x: 256, y: 64)); try four.flush()
        #expect(abs(alpha(try raster(four), 256, 64) - 35) <= 1)
        options.flow = 1; options.count = 1; options.spacing = 2
        let spaced = try make(options); try trace(spaced, steps: 2)
        let gaps = try raster(spaced)
        #expect(alpha(gaps, 32, 64) == 255 && alpha(gaps, 64, 64) == 0 && alpha(gaps, 96, 64) == 255)
        options.flow = 0
        let empty = try make(options); try trace(empty, steps: 12)
        #expect(empty.patches.isEmpty)
        options.flow = 0.0001; options.spacing = 0.01
        let faint = try make(options); try trace(faint, steps: 2)
        #expect(alpha(try raster(faint), 256, 64) > 0, "Sub-byte flow must accumulate in floating point")
        options.flow = 0.2; options.count = 8
        let capped = try make(options, opacity: 0.4, pressure: true); try trace(capped, steps: 20)
        let cap = try raster(capped)
        #expect(alpha(cap, 256, 64) <= 62, "Pressure and stroke opacity must both cap accumulation")
    }

    @Test func ellipseAngleAndSeededScatterAreDeterministic() throws {
        var options = RoundBrushDynamics(); options.roundness = 0.25
        let horizontal = try make(options)
        try horizontal.append(CGPoint(x: 256, y: 64)); try horizontal.flush()
        let h = try raster(horizontal)
        #expect(alpha(h, 268, 64) > 240 && alpha(h, 256, 72) == 0)
        options.angle = .pi / 2
        let vertical = try make(options)
        try vertical.append(CGPoint(x: 256, y: 64)); try vertical.flush()
        let v = try raster(vertical)
        #expect(alpha(v, 256, 76) > 240 && alpha(v, 264, 64) == 0)
        options.flow = 0.2; options.count = 3; options.scatter = 1; options.spacing = 0.3
        let sparse = try make(options), dense = try make(options, gpu: false), different = try make(options, seed: 99)
        try trace(sparse, steps: 1); try trace(dense, steps: 128); try trace(different, steps: 1)
        let a = try raster(sparse), b = try raster(dense)
        let delta = difference(a, b)
        #expect(delta <= 1, "Sample density/backend choice changed coverage by \(delta); dab counts \(sparse.dabIndex)/\(dense.dabIndex)")
        if delta > 1 {
            let ai = try #require(a.makeImage()), bi = try #require(b.makeImage())
            Attachment.record(try #require(NSBitmapImageRep(cgImage: ai).representation(using: .png, properties: [:])), named: "sparse-dynamics.png")
            Attachment.record(try #require(NSBitmapImageRep(cgImage: bi).representation(using: .png, properties: [:])), named: "dense-dynamics.png")
        }
        #expect(difference(try raster(sparse), try raster(different)) > 10)
    }

    @Test func nonlinearPressureCurveIsStableAcrossEventRates() throws {
        var options = RoundBrushDynamics()
        options.pressureCurve.points.insert(.init(x: 0.4, y: 0.7), at: 1)
        options.flow = 0.4; options.spacing = 0.15; options.roundness = 0.6
        options.scatter = 0.7; options.count = 2; options.taperEnd = 0.15
        let sparse = try make(options, pressure: true), dense = try make(options, pressure: true, gpu: false)
        try trace(sparse, steps: 1, ramp: true); try trace(dense, steps: 128, ramp: true)
        let delta = difference(try raster(sparse), try raster(dense))
        #expect(delta <= 1, "Nonlinear pressure replay differs by \(delta)")
    }

    @Test func taperReplaysFinalDistanceAndFlushIsIdempotent() throws {
        var options = RoundBrushDynamics(); options.taperStart = 0.25; options.taperEnd = 0.25
        let live = try make(options), replay = try make(options)
        replay.defersTaperRendering = true
        try trace(live, steps: 64)
        try trace(replay, steps: 64, flush: false)
        #expect(replay.patches.isEmpty, "Recorded taper samples need no provisional rasterization")
        try replay.flush()
        #expect(difference(try raster(live), try raster(replay)) == 0)
        options.flow = 0.4; options.roundness = 0.7; options.scatter = 0.6; options.spacing = 0.12
        let sparse = try make(options), dense = try make(options, gpu: false)
        try trace(sparse, steps: 2, flush: false)
        let provisional = try raster(sparse)
        try sparse.flush(); try trace(dense, steps: 112)
        let final = try raster(sparse)
        #expect(difference(final, try raster(dense)) <= 1)
        #expect(difference(final, provisional) > 10)
        #expect(alpha(final, 35, 76) == 0 && alpha(final, 256, 64) > 230)
        try sparse.flush()
        #expect(difference(final, try raster(sparse)) == 0)
        let click = try make(options)
        try click.append(CGPoint(x: 256, y: 64)); try click.flush()
        #expect(alpha(try raster(click), 256, 64) > 0, "A zero-length click has no length to taper")
    }

    @Test func presetsRoundTripAndRejectInvalidDynamicsAtomically() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("brushes.json")
        let library = BrushLibrary(url: url)
        var preset = library.current
        preset.roundDynamics.spacing = 0.2; preset.roundDynamics.flow = 0.3
        preset.roundDynamics.taperEnd = 0.25; preset.roundDynamics.roundness = 0.4
        preset.roundDynamics.count = 3; preset.roundDynamics.scatter = 0.7
        preset.roundDynamics.strokePath = StrokePathSettings(spacingJitter: 0.4, lateralJitter: 0.3,
            linearJitter: 0.2, falloff: 0.1, speedSpacing: 0.5, lateralInput: .tilt)
        preset.roundDynamics.pressureCurve.points.insert(.init(x: 0.4, y: 0.6), at: 1)
        try library.save(preset)
        #expect(BrushLibrary(url: url).current == preset)
        var settings = BrushSettings(red: 0.7); settings.healing = true
        let applied = preset.applying(to: settings)
        #expect(applied.roundDynamics == preset.roundDynamics && applied.red == 0.7 && applied.healing)
        var captured = BrushPreset(name: "Captured"); captured.capture(applied)
        #expect(captured.roundDynamics == preset.roundDynamics)
        let before = try Data(contentsOf: url)
        var invalid = preset; invalid.roundDynamics.spacing = -0.01
        #expect(throws: (any Error).self) { try library.save(invalid) }
        #expect(try Data(contentsOf: url) == before)
        invalid = preset; invalid.roundDynamics.strokePath?.speedReference = .nan
        #expect(throws: (any Error).self) { try library.save(invalid) }
        #expect(try Data(contentsOf: url) == before)
        invalid = preset; invalid.roundDynamics.count = 17
        #expect(throws: (any Error).self) { try make(invalid.roundDynamics) }
        invalid = preset; invalid.roundDynamics.flow = .nan
        #expect(throws: (any Error).self) { try make(invalid.roundDynamics) }
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any])
        legacy.removeValue(forKey: "roundDynamics")
        let decoded = try JSONDecoder().decode(BrushPreset.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.roundDynamics == RoundBrushDynamics())
    }

    @Test func transformedTipsAndSelectedMasksPreservePixelsUndoAndReopen() async throws {
        let blank = try BrushRaster.context(width: 512, height: 128, mask: false)
        let image = try #require(blank.makeImage())
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Transformed"), origin: .zero)
        layer.transform = LayerTransform(origin: CGPoint(x: 128, y: -192), size: CGSize(width: 256, height: 512),
            rotation: 90, flipX: true, flipY: true)
        var settings = BrushSettings(diameter: 32, red: 1)
        settings.roundDynamics.roundness = 0.25
        let transformed = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: size)
        try transformed.append(CGPoint(x: 256, y: 64)); try transformed.flush()
        let tip = try raster(transformed)
        #expect(alpha(tip, 268, 64) > 230 && alpha(tip, 256, 76) == 0)

        let session = EditorSession(); session.createDocument(width: 512, height: 128)
        let white = try BrushRaster.context(width: 512, height: 128, mask: false)
        white.setFillColor(NSColor.white.cgColor); white.fill(CGRect(origin: .zero, size: size))
        let whiteImage = try #require(white.makeImage())
        session.insert(ImportedImage(image: whiteImage, thumbnail: whiteImage, name: "White"))
        session.addLayerMask(); session.isMaskSelected = true; session.selectTool(.brush)
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 200, y: 0, width: 100, height: 128), transform: nil)), name: "Fixture")
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 0)
        session.brushSettings.roundDynamics.flow = 0.4
        session.brushSettings.roundDynamics.spacing = 0.2
        session.brushSettings.roundDynamics.taperStart = 0.1
        let before = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 32, y: 64), seed: 42)
        session.continueBrush(at: CGPoint(x: 480, y: 64))
        #expect(session.finishBrushImmediately() && session.history.undoCount == before + 1)
        let painted = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let pixels = try BrushRaster.copy(painted)
        #expect(alpha(pixels, 150, 64) == 255 && alpha(pixels, 350, 64) == 255 && abs(alpha(pixels, 250, 64) - 20) <= 2)
        session.undo()
        let undone = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(alpha(try BrushRaster.copy(undone), 250, 64) == 255)
        session.redo()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = try await ImageExporter.shared.render(try await ProjectStore.shared.load(from: url)).image
        #expect(difference(pixels, try BrushRaster.copy(reopened)) == 0)

    }

    @Test func previewReplayMatchesCanvasAndSiblingToolsKeepDefaults() async throws {
        var preset = BrushPreset(name: "Dynamics", hardness: 0.4)
        preset.diameter = 30; preset.pressureSize = true
        preset.roundDynamics.flow = 0.3; preset.roundDynamics.spacing = 0.2
        preset.roundDynamics.roundness = 0.4; preset.roundDynamics.scatter = 0.8
        preset.roundDynamics.count = 2; preset.roundDynamics.taperEnd = 0.3
        preset.roundDynamics.strokePath = StrokePathSettings(spacingJitter: 0.3, lateralJitter: 0.15, linearJitter: 0.1, falloff: 0.4)
        preset.roundDynamics.shape = ShapeBrushSettings(source: .custom, customTip: asymmetricBrushShapeTip(), inputStyle: .barrel, filtering: .improved)
        preset.roundDynamics.rendering = BrushRenderingSettings(mode: .uniformBlending, wetEdges: 0.5, burntEdges: 0.4,
            edgeBlend: .colorBurn, strokeBlend: .overlay, alphaThreshold: 0.02, dualSource: .generated, secondary: .speckle, classicDualNormal: true)

        let preview = BrushDrawingView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        preview.preset = preset; preview.reset()
        let points = [CGPoint(x: 30, y: 90), CGPoint(x: 140, y: 100), CGPoint(x: 280, y: 140)]
        preview.beginStroke(at: points[0], pressure: 0.2)
        let seed = try #require(preview.session.brushStroke?.seed)
        preview.continueStroke(at: points[1], pressure: 0.6); preview.continueStroke(at: points[2], pressure: 1)
        preview.endStroke()
        preview.reset(clearing: false)
        let session = EditorSession(); session.createDocument(width: 320, height: 240); session.addBlankLayer(); session.selectTool(.brush)
        session.brushSettings = preset.applying(to: session.brushSettings)
        session.foregroundColor = preview.color
        session.beginBrush(at: points[0], pressure: 0.2, seed: seed)
        session.continueBrush(at: points[1], pressure: 0.6); session.continueBrush(at: points[2], pressure: 1)
        #expect(session.finishBrushImmediately())
        let a = try await ImageExporter.shared.render(try #require(preview.session.projectSnapshot())).image
        let b = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(NSBitmapImageRep(cgImage: a).representation(using: .png, properties: [:]) == NSBitmapImageRep(cgImage: b).representation(using: .png, properties: [:]))
        let revision = session.history.undoCount
        session.undo(); #expect(session.activeLayer?.asset == nil)
        session.redo(); #expect(session.history.undoCount == revision && session.activeLayer?.asset != nil)
        session.selectTool(.spotHealing)
        session.beginBrush(at: CGPoint(x: 150, y: 100))
        #expect(session.brushStroke?.settings.roundDynamics == RoundBrushDynamics() && session.brushStroke?.settings.shapeTip == nil)
        session.cancelBrush()
        Attachment.record(try #require(NSBitmapImageRep(cgImage: a).representation(using: .png, properties: [:])), named: "core-round-dynamics.png")
    }
    @Test func strokePathJitterIsDistanceBasedAndTailRollbackIsExact() throws {
        var options = RoundBrushDynamics(); options.spacing = 0.3
        options.strokePath = StrokePathSettings(spacingJitter: 1, lateralJitter: 1, linearJitter: 1)
        let sparse = try make(options), dense = try make(options, gpu: false)
        try trace(sparse, steps: 1); try trace(dense, steps: 128)
        #expect(sparse.dabIndex == dense.dabIndex)
        #expect(difference(try raster(sparse), try raster(dense)) <= 1)
        let different = try make(options, seed: 79); try trace(different, steps: 1)
        #expect(difference(try raster(sparse), try raster(different)) > 10)
        options.taperEnd = 0.15
        let live = try make(options), replay = try make(options)
        replay.defersTaperRendering = true
        let points = [CGPoint(x: 40, y: 30), CGPoint(x: 260, y: 30), CGPoint(x: 260, y: 95), CGPoint(x: 460, y: 95)]
        for stroke in [live, replay] {
            for (i, point) in points.enumerated() {
                try stroke.append(point, input: BrushInput(pressure: 0.6, timestamp: Double(i)))
                // Identical points and time-only updates cannot advance the random sequence.
                try stroke.append(point, input: BrushInput(pressure: 0.6, timestamp: Double(i) + 0.1))
            }
            try stroke.flush()
        }
        let final = try raster(live)
        #expect(difference(final, try raster(replay)) == 0)
        try live.flush()
        #expect(difference(final, try raster(live)) == 0)
    }

    @Test func strokePathInputsSpeedAndFalloffAffectActualPixels() throws {
        var path = StrokePathSettings(spacingJitter: 1, lateralJitter: 1, linearJitter: 1)
        let empty = BrushInput()
        for input in StrokePathSettings.Input.allCases { #expect(input.factor(empty, curve: PressureCurve()) == 1) }
        #expect(StrokePathSettings.Input.pressure.factor(BrushInput(pressure: 0.25), curve: PressureCurve()) == 0.25)
        #expect(StrokePathSettings.Input.tilt.factor(BrushInput(tilt: CGPoint(x: 0.3, y: 0.4)), curve: PressureCurve()) == 0.5)
        #expect(StrokePathSettings.Input.rotation.factor(BrushInput(rotation: -.pi / 2), curve: PressureCurve()) == 0)
        path.spacingInput = .pressure; path.lateralInput = .tilt; path.linearInput = .rotation
        var options = RoundBrushDynamics(); options.spacing = 0.3; options.strokePath = path
        let mapped = try make(options), fixed = try make(options)
        for step in 0...32 {
            let t = CGFloat(step) / 32, point = CGPoint(x: 32 + 448 * t, y: 64)
            try mapped.append(point, input: BrushInput(pressure: 0, tilt: .zero, rotation: -.pi / 2, timestamp: Double(t)))
            try fixed.append(point)
        }
        try mapped.flush(); try fixed.flush()
        #expect(difference(try raster(mapped), try raster(fixed)) > 20)
        let index = mapped.dabIndex
        try mapped.append(CGPoint(x: 480, y: 64), input: BrushInput(pressure: 0.8, tilt: CGPoint(x: 1, y: 0), rotation: 1, timestamp: 2))
        try mapped.flush()
        #expect(mapped.dabIndex == index + 1, "Stationary pressure/tilt/rotation changes must paint")
        options.strokePath = StrokePathSettings(speedSpacing: 1, speedReference: 448)
        let fast = try make(options), slow = try make(options), missing = try make(options), dense = try make(options)
        for (stroke, duration) in [(fast, 1.0), (slow, 100.0), (dense, 1.0)] {
            let steps = stroke === dense ? 128 : 1
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                try stroke.append(CGPoint(x: 32 + 448 * t, y: 64), input: BrushInput(timestamp: t * duration))
            }
            try stroke.flush()
        }
        try missing.append(CGPoint(x: 32, y: 64)); try missing.append(CGPoint(x: 480, y: 64)); try missing.flush()
        let missingIndex = missing.dabIndex
        try missing.append(CGPoint(x: 480, y: 64), input: BrushInput(tilt: CGPoint(x: 1, y: 0), rotation: 1, timestamp: 2))
        try missing.flush()
        #expect(missing.dabIndex == missingIndex, "Unmapped sensor noise cannot add paint")
        #expect(fast.dabIndex < slow.dabIndex && slow.dabIndex <= missing.dabIndex)
        #expect(difference(try raster(fast), try raster(dense)) <= 1)
        options.spacing = 0.2; options.strokePath = StrokePathSettings(falloff: 1)
        let faded = try make(options); try trace(faded, steps: 2)
        let image = try raster(faded)
        #expect(alpha(image, 32, 64) == 255 && alpha(image, 450, 64) < 120)
        #expect(options.path.opacity(at: 640, diameter: 32) == 0)
        #expect(StrokePathSettings().opacity(at: 100000, diameter: 32) == 1)
    }

    @Test func strokePathMetadataIsValidatedAndLegacySafe() throws {
        var options = RoundBrushDynamics()
        options.strokePath = StrokePathSettings(spacingJitter: 0.4, lateralJitter: 0.5, linearJitter: 0.6,
            falloff: 0.7, speedSpacing: 0.8, speedReference: 900, spacingInput: .pressure, lateralInput: .tilt, linearInput: .rotation)
        #expect(options.isValid && options.usesStamps)
        #expect(try JSONDecoder().decode(RoundBrushDynamics.self, from: JSONEncoder().encode(options)) == options)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        json.removeValue(forKey: "strokePath")
        let legacy = try JSONDecoder().decode(RoundBrushDynamics.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.path == StrokePathSettings() && !legacy.usesStamps)
        options.strokePath?.speedReference = 0; #expect(!options.isValid)
        options.strokePath = StrokePathSettings(spacingJitter: .nan); #expect(!options.isValid)
        options.strokePath = StrokePathSettings(spacingInput: .tilt); #expect(!options.isValid)
        options.strokePath = StrokePathSettings(linearJitter: 1.01); #expect(!options.isValid)
        options.strokePath = nil; options.spacing = 0; #expect(options.isValid)
    }

    @Test func strokePathTransformedSelectedMaskSurvivesUndoExportAndReopen() async throws {
        let session = EditorSession(); session.createDocument(width: 512, height: 128)
        let white = try BrushRaster.context(width: 512, height: 128, mask: false)
        white.setFillColor(NSColor.white.cgColor); white.fill(CGRect(origin: .zero, size: size))
        let image = try #require(white.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Path mask"))
        let index = try #require(session.document?.layers.firstIndex(where: { $0.id == session.activeLayerID }))
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 128, y: -192),
            size: CGSize(width: 256, height: 512), rotation: 90, flipX: true, flipY: true)
        session.addLayerMask(); session.isMaskSelected = true; session.selectTool(.brush)
        session.maskPaintWhite = false
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 200, y: 0, width: 100, height: 128), transform: nil)), name: "Path clip")
        session.brushSettings.diameter = 32
        session.brushSettings.roundDynamics.spacing = 0.2
        session.brushSettings.roundDynamics.strokePath = StrokePathSettings(spacingJitter: 0.2, lateralJitter: 0.5, linearJitter: 0.5, falloff: 0.2)
        session.brushSettings.roundDynamics.shape = ShapeBrushSettings(source: .custom, customTip: asymmetricBrushShapeTip(), flipX: true, filtering: .improved)
        session.beginBrush(at: CGPoint(x: 32, y: 64), seed: 42)
        session.continueBrush(at: CGPoint(x: 480, y: 64))
        #expect(session.finishBrushImmediately() && session.brushError == nil)
        let painted = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let pixels = try BrushRaster.copy(painted)
        #expect(alpha(pixels, 150, 64) == 255 && alpha(pixels, 350, 64) == 255)
        #expect((200..<300).contains { alpha(pixels, $0, 64) < 200 })
        session.undo()
        let undone = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(alpha(try BrushRaster.copy(undone), 250, 64) == 255)
        session.redo()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = try await ImageExporter.shared.render(try await ProjectStore.shared.load(from: url)).image
        #expect(difference(pixels, try BrushRaster.copy(reopened)) == 0)
        Attachment.record(try #require(NSBitmapImageRep(cgImage: painted).representation(using: .png, properties: [:])), named: "stroke-path-transformed-mask.png")
    }

    @Test func strokePathFourKTimingAndTileBudget() throws {
        var report = "4K Debug timing in Xcode; CPU discrete path versus unchanged automatic renderer. Same 2400 px path, 12 updates.\n"
        for diameter: CGFloat in [40, 800] {
            for mode in 0...2 {
                let discrete = mode != 0
                var settings = BrushSettings(diameter: diameter, hardness: 0.5, red: 1)
                if discrete {
                    settings.roundDynamics.spacing = mode == 1 ? 0.25 : nil
                    settings.roundDynamics.strokePath = StrokePathSettings(spacingJitter: mode == 1 ? 0.3 : 0, lateralJitter: 0.2, linearJitter: 0.2, falloff: 0.2, speedSpacing: mode == 1 ? 0.3 : 0)
                }
                let stroke = try BrushStroke(layer: ImageLayer(name: "4K", blankSize: CGSize(width: 4000, height: 4000)),
                    mask: false, settings: settings, canvas: CGSize(width: 4000, height: 4000), seed: 42)
                var updates: [Double] = []
                for step in 0...12 {
                    let start = CFAbsoluteTimeGetCurrent()
                    try stroke.append(CGPoint(x: 700 + step * 200, y: 2000), input: BrushInput(timestamp: Double(step) / 12))
                    updates.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                }
                let end = CFAbsoluteTimeGetCurrent(); try stroke.flush()
                let mouseUp = (CFAbsoluteTimeGetCurrent() - end) * 1000
                updates.sort()
                let tiles = stroke.patches.count
                #expect(tiles > 0 && tiles < 100, "A short band cannot allocate the entire 4K canvas")
                let bytes = tiles * 256 * 256 * (discrete ? 13 : 4)
                report += "diameter=\(diameter) mode=\(mode) updateMedian=\(updates[updates.count / 2])ms max=\(updates.last!)ms flush=\(mouseUp)ms tiles=\(tiles) coreTileBytesEstimate=\(bytes)\n"
            }
        }
        print(report)
        Attachment.record(Data(report.utf8), named: "stroke-path-4k-timing.txt")
    }

    @Test func strokePathReferenceExamples() throws {
        let atlas = try BrushRaster.context(width: 512, height: 384, mask: false)
        atlas.setFillColor(NSColor.white.cgColor); atlas.fill(CGRect(x: 0, y: 0, width: 512, height: 384))
        for mode in 0...2 {
            var options = RoundBrushDynamics()
            options.spacing = mode == 0 ? 1.5 : 0.08
            if mode == 1 { options.strokePath = StrokePathSettings(lateralJitter: 1, linearJitter: 1) }
            if mode == 2 { options.strokePath = StrokePathSettings(falloff: 1) }
            var settings = BrushSettings(diameter: mode == 2 ? 12 : 24, hardness: 0.5, red: 1)
            settings.roundDynamics = options
            let stroke = try BrushStroke(layer: ImageLayer(name: "Reference", blankSize: size), mask: false,
                settings: settings, canvas: size, seed: 42)
            try trace(stroke, steps: 16)
            atlas.draw(try #require(try raster(stroke).makeImage()), in: CGRect(x: 0, y: mode * 128, width: 512, height: 128))
        }
        let image = try #require(atlas.makeImage())
        Attachment.record(try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])), named: "stroke-path-spacing-scatter-falloff.png")
    }

    private func renderingStroke(_ rendering: BrushRenderingSettings, base: CGImage? = nil,
                                 options: RoundBrushDynamics? = nil, opacity: CGFloat = 1, gpu: Bool = true) throws -> BrushStroke {
        var settings = BrushSettings(diameter: 32, hardness: 0.4, red: 0.75, green: 0.3, blue: 0.12, opacity: opacity)
        settings.roundDynamics = options ?? RoundBrushDynamics()
        settings.roundDynamics.flow = options?.flow ?? 0.08
        settings.roundDynamics.spacing = options?.spacing ?? 0.35
        settings.roundDynamics.rendering = rendering
        let layer = base.map { ImageLayer(asset: ImportedImage(image: $0, thumbnail: $0, name: "Backdrop"), origin: .zero) }
            ?? ImageLayer(name: "Blank", blankSize: size)
        return try BrushStroke(layer: layer, mask: false, settings: settings, canvas: size, useGPU: gpu, seed: 42)
    }
    private func renderingPixel(_ context: CGContext, _ x: Int, _ y: Int) -> [Int] {
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self), i = y * context.bytesPerRow + x * 4
        return (0..<4).map { Int(bytes[i + $0]) }
    }
    private func renderingBackdrop() throws -> CGImage {
        let context = try BrushRaster.context(width: 512, height: 128, mask: false)
        context.setFillColor(NSColor(calibratedRed: 0.08, green: 0.65, blue: 0.3, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        context.setFillColor(NSColor(calibratedRed: 0.15, green: 0.3, blue: 0.85, alpha: 1).cgColor)
        context.fill(CGRect(x: 256, y: 0, width: 256, height: 128))
        return try #require(context.makeImage())
    }

    @Test func colorDynamicsValidationIdentityAndColorMath() throws {
        var options = RoundBrushDynamics(); options.colorDynamics = BrushColorDynamics()
        #expect(options.isValid && !options.usesStamps)
        let legacy = try make(RoundBrushDynamics()), identity = try make(options)
        try trace(legacy, steps: 8); try trace(identity, steps: 8)
        #expect(difference(try raster(legacy), try raster(identity)) == 0)
        let red = PaletteColor(red: 1, green: 0, blue: 0)
        let negative = BrushColorResponse(hue: -0.1).applying(to: red, secondaryColor: .white)
        #expect(negative.red == 1 && negative.blue > 0 && negative.green == 0)
        let gray = PaletteColor(red: 0.5, green: 0.5, blue: 0.5)
        #expect(BrushColorResponse(hue: 1).applying(to: gray, secondaryColor: .white) == gray)
        #expect(BrushColorResponse(lightness: 1).applying(to: red, secondaryColor: .black) == .white)
        #expect(BrushColorResponse(darkness: 1).applying(to: red, secondaryColor: .white) == .black)
        #expect(BrushColorResponse(secondary: 1).applying(to: red, secondaryColor: .black) == .black)
        let fields: [WritableKeyPath<BrushColorResponse, CGFloat>] = [\.hue, \.saturation, \.lightness, \.darkness, \.secondary]
        for field in fields {
            for invalid: CGFloat in [.nan, .infinity, 1.01] {
                var response = BrushColorResponse(); response[keyPath: field] = invalid
                options.colorDynamics?.pressure = response
                #expect(!options.isValid)
                #expect(throws: (any Error).self) { _ = try make(options) }
            }
        }
        options.colorDynamics = BrushColorDynamics(stamp: BrushColorResponse(hue: -0.1))
        #expect(!options.isValid)
        options.colorDynamics?.stamp.hue = 0.6
        options.colorDynamics?.secondaryColor.red = .nan
        #expect(!options.isValid)
    }

    @Test func colorDynamicsSensorsAndRandomScopesAreExplicit() throws {
        let base = SIMD3<Float>(0.8, 0.3, 0.15)
        var settings = BrushColorDynamics(secondaryColor: .black,
            pressure: BrushColorResponse(secondary: 1), tilt: BrushColorResponse(secondary: 1), rotation: BrushColorResponse(secondary: 1))
        func color(_ input: BrushInput, curve: PressureCurve = PressureCurve(), index: Int = 0, copy: Int = 0) -> SIMD3<Float> {
            settings.color(base, stroke: settings.stroke.randomized(seed: 42, index: 0, channel: 1300), input: input,
                curve: curve, seed: 42, index: index, copy: copy)
        }
        #expect(color(BrushInput()) == base)
        #expect(color(BrushInput(pressure: 0)) == base)
        #expect(color(BrushInput(pressure: 1)) == .zero)
        #expect(color(BrushInput(tilt: CGPoint(x: 1, y: 0))) == .zero)
        #expect(color(BrushInput(rotation: .pi / 2)) == .zero)
        let curve = PressureCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 1, y: 1)])
        #expect(color(BrushInput(pressure: 0.5), curve: curve) == base)
        settings = BrushColorDynamics(stroke: BrushColorResponse(hue: 1, secondary: 0.5))
        #expect(color(BrushInput(), index: 0, copy: 0) == color(BrushInput(), index: 100, copy: 15))
        settings = BrushColorDynamics(stamp: BrushColorResponse(hue: 1, secondary: 0.5))
        #expect(color(BrushInput(), copy: 0) != color(BrushInput(), copy: 1))
        #expect(color(BrushInput(), index: 0) != color(BrushInput(), index: 1))
        for group: WritableKeyPath<BrushColorDynamics, BrushColorResponse> in [\.tilt, \.rotation, \.pressure] {
            var options = RoundBrushDynamics(); options.spacing = 0.3
            var dynamics = BrushColorDynamics(); dynamics[keyPath: group].secondary = 1
            options.colorDynamics = dynamics
            let stroke = try make(options)
            try stroke.append(CGPoint(x: 256, y: 64), input: BrushInput())
            let input = group == \.pressure ? BrushInput(pressure: 1) : group == \.tilt ? BrushInput(tilt: CGPoint(x: 1, y: 0)) : BrushInput(rotation: .pi / 2)
            try stroke.append(CGPoint(x: 256, y: 64), input: input)
            try stroke.flush()
            #expect(stroke.dabIndex == 2, "Stationary color sensor changes must create a new dab")
        }
    }

    @Test func colorDynamicsEveryControlChangesNativePixels() throws {
        var options = RoundBrushDynamics(); options.flow = 0.5; options.spacing = 0.2
        let baseline = try renderingStroke(BrushRenderingSettings(), options: options, gpu: false)
        try baseline.append(CGPoint(x: 256, y: 64), input: BrushInput(pressure: 1, tilt: CGPoint(x: 1, y: 0), rotation: .pi / 2))
        try baseline.flush(); let original = try raster(baseline)
        let groups: [WritableKeyPath<BrushColorDynamics, BrushColorResponse>] = [\.stroke, \.stamp, \.pressure, \.tilt, \.rotation]
        let fields: [WritableKeyPath<BrushColorResponse, CGFloat>] = [\.hue, \.saturation, \.lightness, \.darkness, \.secondary]
        let atlas = try BrushRaster.context(width: 512, height: 128 * groups.count, mask: false)
        for (row, group) in groups.enumerated() {
            for field in fields {
                var dynamics = BrushColorDynamics(secondaryColor: PaletteColor(red: 0.1, green: 0.2, blue: 0.9))
                dynamics[keyPath: group][keyPath: field] = 0.8
                options.colorDynamics = dynamics
                let changed = try renderingStroke(BrushRenderingSettings(), options: options)
                #expect(!changed.usesMetalStampRenderer)
                try changed.append(CGPoint(x: 256, y: 64), input: BrushInput(pressure: 1, tilt: CGPoint(x: 1, y: 0), rotation: .pi / 2))
                try changed.flush()
                #expect(difference(original, try raster(changed)) > 0, "Color response had no output: \(group), \(field)")
            }
            var dynamics = BrushColorDynamics(secondaryColor: PaletteColor(red: 0.1, green: 0.2, blue: 0.9))
            dynamics[keyPath: group] = BrushColorResponse(hue: 0.6, saturation: 0.2, secondary: 0.5)
            options.colorDynamics = dynamics
            let stroke = try renderingStroke(BrushRenderingSettings(), options: options)
            for step in 0...32 {
                let t = CGFloat(step) / 32
                try stroke.append(CGPoint(x: 32 + 448 * t, y: 64), input: BrushInput(pressure: t, tilt: CGPoint(x: t, y: 0), rotation: -.pi / 2 + .pi * t))
            }
            try stroke.flush()
            BrushRaster.draw(try #require(try raster(stroke).makeImage()), in: CGRect(x: 0, y: row * 128, width: 512, height: 128), mask: false, context: atlas)
        }
        Attachment.record(try #require(NSBitmapImageRep(cgImage: atlas.makeImage()!).representation(using: .png, properties: [:])), named: "native-color-dynamics-groups.png")
    }

    @Test func colorDynamicsPreservesAlphaAndSeededTailReplay() throws {
        var options = RoundBrushDynamics(); options.flow = 0.2; options.spacing = 0.2; options.count = 3
        options.taperStart = 0.1; options.taperEnd = 0.2
        options.colorDynamics = BrushColorDynamics(stroke: BrushColorResponse(hue: 0.3), stamp: BrushColorResponse(hue: 0.7, secondary: 0.4), pressure: BrushColorResponse(darkness: 0.2))
        let sparse = try make(options), dense = try make(options, gpu: false), deferred = try make(options)
        deferred.defersTaperRendering = true
        try trace(sparse, steps: 1, ramp: true); try trace(dense, steps: 64, ramp: true); try trace(deferred, steps: 1, ramp: true)
        let result = try raster(sparse)
        #expect(difference(result, try raster(dense)) <= 1)
        #expect(difference(result, try raster(deferred)) <= 1)
        try sparse.flush(); #expect(difference(result, try raster(sparse)) == 0)
        let otherSeed = try make(options, seed: 99); try trace(otherSeed, steps: 1, ramp: true)
        #expect(difference(result, try raster(otherSeed)) > 0)
        options.colorDynamics = nil
        let plain = try make(options, gpu: false); try trace(plain, steps: 1, ramp: true)
        let plainPixels = try raster(plain)
        var alphaDifference = 0
        for y in 0..<128 { for x in 0..<512 { alphaDifference = max(alphaDifference, abs(alpha(result, x, y) - alpha(plainPixels, x, y))) } }
        #expect(alphaDifference <= 1, "Color variation must preserve coverage within byte quantization")
    }

    @Test func wetMixDefaultsPersistenceAndInvalidSettings() throws {
        let defaults = BrushWetMix()
        #expect(defaults.isValid && !defaults.isActive)
        var options = RoundBrushDynamics(); options.wetMix = defaults
        #expect(!options.usesStamps)
        let legacy = try make(RoundBrushDynamics()), neutral = try make(options)
        try trace(legacy, steps: 8); try trace(neutral, steps: 8)
        #expect(difference(try raster(legacy), try raster(neutral)) == 0)
        let fields: [WritableKeyPath<BrushWetMix, CGFloat>] = [\.dilution, \.charge, \.attack, \.pull, \.grade, \.blur, \.blurJitter, \.wetnessJitter]
        for field in fields {
            for value: CGFloat in [-0.01, 1.01, .infinity, .nan] {
                var wet = defaults; wet[keyPath: field] = value; options.wetMix = wet
                #expect(!options.isValid)
                #expect(throws: (any Error).self) { _ = try make(options) }
            }
        }
        options.wetMix = BrushWetMix(dilution: 0.3, charge: 0.5, attack: 0.7, pull: 0.6, grade: 0.4, blur: 0.5, blurJitter: 0.4, wetnessJitter: 0.2)
        #expect(try JSONDecoder().decode(RoundBrushDynamics.self, from: JSONEncoder().encode(options)) == options)
    }

    @Test func wetMixExhaustsReloadsAndPullRechargesWithoutCreatingPaintOnEmptyPixels() throws {
        var options = RoundBrushDynamics(); options.spacing = 0.1; options.flow = 1
        options.wetMix = BrushWetMix(charge: 0.2, grade: 1)
        let exhausted = try make(options), reloaded = try make(options)
        try trace(exhausted, steps: 8); try trace(reloaded, steps: 8)
        let result = try raster(exhausted)
        #expect(alpha(result, 32, 64) > 0 && alpha(result, 400, 64) == 0)
        #expect(difference(result, try raster(reloaded)) == 0)
        for wet in [BrushWetMix(dilution: 1), BrushWetMix(charge: 0), BrushWetMix(attack: 0), BrushWetMix(charge: 0, pull: 1)] {
            options.wetMix = wet
            let empty = try make(options); try trace(empty, steps: 8)
            let pixels = try raster(empty)
            #expect(alpha(pixels, 64, 64) == 0)
        }
        options.wetMix = BrushWetMix(charge: 0, pull: 1)
        let pulled = try renderingStroke(BrushRenderingSettings(), base: renderingBackdrop(), options: options)
        try trace(pulled, steps: 8)
        #expect(!pulled.patches.isEmpty)
    }

    @Test func wetMixGradeChangesImageTipContrast() throws {
        var options = RoundBrushDynamics(); options.flow = 0.4; options.spacing = 0.2
        options.shape = ShapeBrushSettings(source: .generated, generator: .softRound)
        let smooth = try make(options)
        options.wetMix = BrushWetMix(grade: 1)
        let graded = try make(options)
        try trace(smooth, steps: 8); try trace(graded, steps: 8)
        #expect(difference(try raster(smooth), try raster(graded)) > 0)
    }

    @Test func wetMixControlledNativeStrokeComparisons() throws {
        let cases = [BrushWetMix(), BrushWetMix(dilution: 0.7), BrushWetMix(charge: 0.2, grade: 1),
                     BrushWetMix(attack: 0.3), BrushWetMix(wetnessJitter: 1)]
        let atlas = try BrushRaster.context(width: 512, height: cases.count * 128, mask: false)
        atlas.setFillColor(NSColor.white.cgColor); atlas.fill(CGRect(x: 0, y: 0, width: 512, height: cases.count * 128))
        for (row, wet) in cases.enumerated() {
            var options = RoundBrushDynamics(); options.spacing = 0.2; options.flow = 0.3; options.wetMix = wet
            let stroke = try renderingStroke(BrushRenderingSettings(), options: options)
            try trace(stroke, steps: 16)
            let transform = LayerTransform(origin: CGPoint(x: 0, y: row * 128), size: size)
            LayerRenderer.draw(try #require(try raster(stroke).makeImage()), transform: transform, center: transform.center, in: atlas)
        }
        Attachment.record(try #require(NSBitmapImageRep(cgImage: atlas.makeImage()!).representation(using: .png, properties: [:])), named: "wet-mix-native-comparisons.png")
    }

    @Test func wetMixIsIgnoredByMasksAndErasing() throws {
        for mask in [false, true] {
            var settings = BrushSettings(diameter: 32, hardness: 0.4, red: 1, erasing: !mask)
            let image = try renderingBackdrop()
            let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Backdrop"), origin: .zero)
            let legacy = try BrushStroke(layer: layer, mask: mask, settings: settings, canvas: size, seed: 42)
            settings.roundDynamics.wetMix = BrushWetMix(dilution: 1, charge: 0, pull: 1, grade: 1)
            settings.roundDynamics.colorDynamics = BrushColorDynamics(stamp: BrushColorResponse(hue: 1, secondary: 1))
            let wet = try BrushStroke(layer: layer, mask: mask, settings: settings, canvas: size, seed: 42)
            #expect(wet.settings.roundDynamics.wetMix == nil && wet.settings.roundDynamics.colorDynamics == nil)
            try trace(legacy, steps: 8); try trace(wet, steps: 8)
            #expect(difference(try raster(legacy), try raster(wet)) == 0)
        }
    }

    @Test func wetMixControlsChangeDepositedPixels() throws {
        let backdrop = try renderingBackdrop()
        var options = RoundBrushDynamics(); options.spacing = 0.2; options.flow = 0.4
        let reference = BrushWetMix(dilution: 0.2, charge: 0.6, attack: 0.7, pull: 0.4, grade: 0.3, blur: 0.8, blurJitter: 0.2, wetnessJitter: 0.2)
        func draw(_ wet: BrushWetMix) throws -> CGContext {
            options.wetMix = wet
            let stroke = try renderingStroke(BrushRenderingSettings(), base: backdrop, options: options)
            try trace(stroke, steps: 16)
            return try raster(stroke)
        }
        let original = try draw(reference)
        for field: WritableKeyPath<BrushWetMix, CGFloat> in [\.dilution, \.charge, \.attack, \.pull, \.grade, \.blur, \.blurJitter, \.wetnessJitter] {
            var changed = reference; changed[keyPath: field] = field == \.blurJitter ? 1 : 0
            #expect(difference(original, try draw(changed)) > 0, "Wet control did not change pixels: \(field)")
        }
    }

    @Test func wetMixPickupJitterAndTaperReplayAreDeterministic() throws {
        var options = RoundBrushDynamics(); options.flow = 0.3; options.spacing = 0.2
        options.wetMix = BrushWetMix(dilution: 0.2, charge: 0.6, attack: 0.8, pull: 0.5, grade: 0.5, blur: 0.6, blurJitter: 0.7, wetnessJitter: 0.8)
        options.taperStart = 0.1; options.taperEnd = 0.2
        let backdrop = try renderingBackdrop()
        let sparse = try renderingStroke(BrushRenderingSettings(), base: backdrop, options: options)
        let dense = try renderingStroke(BrushRenderingSettings(), base: backdrop, options: options, gpu: false)
        let deferred = try renderingStroke(BrushRenderingSettings(), base: backdrop, options: options)
        deferred.defersTaperRendering = true
        try trace(sparse, steps: 1); try trace(dense, steps: 64); try trace(deferred, steps: 1)
        let result = try raster(sparse)
        #expect(difference(result, try raster(dense)) <= 1)
        #expect(difference(result, try raster(deferred)) <= 1)
        try sparse.flush(); #expect(difference(result, try raster(sparse)) == 0)
        Attachment.record(try #require(NSBitmapImageRep(cgImage: result.makeImage()!).representation(using: .png, properties: [:])), named: "wet-mix-pickup-taper.png")
    }

    @Test func renderingMetadataIsValidatedPersistedAndLegacySafe() throws {
        #expect(!RoundBrushDynamics().renderingSettings.isActive && !RoundBrushDynamics().usesStamps)
        var rendering = BrushRenderingSettings(mode: .intenseBlending, wetEdges: 0.4, burntEdges: 0.7, backruns: 0.55,
            edgeBlend: .colorBurn, strokeBlend: .screen, luminanceBlending: true, alphaThreshold: 0.3,
            dualSource: .generated, secondary: .bristles, secondaryScale: 1.2, classicDualNormal: true)
        var preset = BrushPreset(name: "Rendering"); preset.roundDynamics.rendering = rendering
        #expect(preset.isValid && preset.roundDynamics.usesStamps)
        #expect(try JSONDecoder().decode(BrushPreset.self, from: JSONEncoder().encode(preset)) == preset)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("brushes.json"), library = BrushLibrary(url: url)
        try library.save(preset); #expect(BrushLibrary(url: url).current == preset)
        let bytes = try Data(contentsOf: url)
        rendering.wetEdges = .nan; preset.roundDynamics.rendering = rendering
        #expect(throws: (any Error).self) { try library.save(preset) }
        #expect(try Data(contentsOf: url) == bytes)
        for invalid in [BrushRenderingSettings(wetEdges: -0.1), BrushRenderingSettings(backruns: 1.1), BrushRenderingSettings(alphaThreshold: 1.1),
                        BrushRenderingSettings(secondaryScale: .infinity)] { #expect(!invalid.isValid) }
        let oldRendering = Data("{\"mode\":\"Standard\",\"wetEdges\":0.2,\"burntEdges\":0.3}".utf8)
        #expect(try JSONDecoder().decode(BrushRenderingSettings.self, from: oldRendering).backruns == 0)
        let old = Data("{\"pressureCurve\":{\"points\":[{\"x\":0,\"y\":0},{\"x\":1,\"y\":1}]},\"flow\":1,\"taperStart\":0,\"taperEnd\":0,\"roundness\":1,\"angle\":0,\"count\":1,\"scatter\":0}".utf8)
        #expect(try JSONDecoder().decode(RoundBrushDynamics.self, from: old).renderingSettings == BrushRenderingSettings())
    }

    @Test func renderingModesHaveDistinctBuildupAndOpacityCaps() throws {
        var levels: [Int] = []
        let atlas = try BrushRaster.context(width: 512, height: 6 * 128, mask: false)
        atlas.setFillColor(NSColor.white.cgColor); atlas.fill(CGRect(x: 0, y: 0, width: 512, height: 6 * 128))
        for (row, mode) in BrushRenderingSettings.Mode.allCases.dropFirst().enumerated() {
            let rendering = BrushRenderingSettings(mode: mode)
            let once = try renderingStroke(rendering, opacity: 0.65)
            try trace(once, steps: 1)
            let single = alpha(try raster(once), 256, 64)
            try once.append(CGPoint(x: 32, y: 64)); try once.flush()
            let image = try raster(once), repeated = alpha(image, 256, 64)
            if mode == .lightGlaze { #expect(abs(repeated - single) <= 1) }
            else { #expect(repeated > single) }
            #expect(repeated <= 166 && repeated > 0)
            levels.append(repeated)
            let transform = LayerTransform(origin: CGPoint(x: 0, y: row * 128), size: size)
            LayerRenderer.draw(try #require(image.makeImage()), transform: transform, center: transform.center, in: atlas)
        }
        #expect(Set(levels).count == 6, "Mode buildup must be observable, not six labels for one renderer: \(levels)")
        Attachment.record(try #require(NSBitmapImageRep(cgImage: atlas.makeImage()!).representation(using: .png, properties: [:])), named: "rendering-six-modes.png")
    }

    @Test func renderingPickupAndTailReplayAreEventRateIndependent() throws {
        let backdrop = try renderingBackdrop()
        var options = RoundBrushDynamics(); options.flow = 0.25; options.spacing = 0.2
        options.taperStart = 0.1; options.taperEnd = 0.2
        let rendering = BrushRenderingSettings(mode: .intenseBlending, wetEdges: 0.6, burntEdges: 0.4, edgeBlend: .multiply)
        let sparse = try renderingStroke(rendering, base: backdrop, options: options)
        let dense = try renderingStroke(rendering, base: backdrop, options: options, gpu: false)
        let deferred = try renderingStroke(rendering, base: backdrop, options: options)
        deferred.defersTaperRendering = true
        try trace(sparse, steps: 1); try trace(dense, steps: 64); try trace(deferred, steps: 1)
        let result = try raster(sparse)
        #expect(difference(result, try raster(dense)) <= 1)
        #expect(difference(result, try raster(deferred)) <= 1)
        try sparse.flush(); #expect(difference(result, try raster(sparse)) == 0)
        options.taperStart = 0; options.taperEnd = 0
        let blending = try renderingStroke(BrushRenderingSettings(mode: .uniformBlending), base: backdrop, options: options)
        let paint = try renderingStroke(BrushRenderingSettings(), base: backdrop, options: options)
        try trace(blending, steps: 32); try trace(paint, steps: 32)
        #expect(difference(try raster(blending), try raster(paint)) > 15, "Blending must pick up existing color")
        Attachment.record(try #require(NSBitmapImageRep(cgImage: result.makeImage()!).representation(using: .png, properties: [:])), named: "rendering-pickup-taper.png")
    }

    @Test func renderingEdgesBlendModesLuminanceAndThresholdChangePixels() throws {
        func click(_ rendering: BrushRenderingSettings, options: RoundBrushDynamics? = nil, base: CGImage? = nil) throws -> CGContext {
            let stroke = try renderingStroke(rendering, base: base, options: options)
            try stroke.append(CGPoint(x: 240, y: 64)); try stroke.flush(); return try raster(stroke)
        }
        var options = RoundBrushDynamics(); options.flow = 0.4; options.shape = ShapeBrushSettings(filtering: .none)
        let original = try click(BrushRenderingSettings(), options: options)
        let wet = try click(BrushRenderingSettings(wetEdges: 1), options: options)
        #expect(difference(original, wet) > 1)
        let burned = try click(BrushRenderingSettings(burntEdges: 1), options: options)
        let bright = try click(BrushRenderingSettings(burntEdges: 1, edgeBlend: .screen), options: options)
        #expect(difference(original, burned) > 2 && difference(burned, bright) > 2)
        for x in 224...256 { #expect(abs(alpha(original, x, 64) - alpha(burned, x, 64)) <= 1) }
        let binary = try click(BrushRenderingSettings(alphaThreshold: 0.1), options: options)
        #expect(alpha(binary, 240, 64) == 255 && alpha(binary, 220, 64) == 0)
        #expect((0..<(512 * 128)).allSatisfy { let a = binary.data!.assumingMemoryBound(to: UInt8.self)[$0 * 4 + 3]; return a == 0 || a == 255 })
        let empty = try click(BrushRenderingSettings(alphaThreshold: 0.9), options: options)
        #expect(alpha(empty, 240, 64) == 0)
        let zero = try click(BrushRenderingSettings(alphaThreshold: 0), options: options)
        #expect(alpha(zero, 0, 0) == 0)
        options.flow = 1
        let base = try renderingBackdrop()
        let normal = try click(BrushRenderingSettings(), options: options, base: base)
        let multiply = try click(BrushRenderingSettings(strokeBlend: .multiply), options: options, base: base)
        let screen = try click(BrushRenderingSettings(strokeBlend: .screen), options: options, base: base)
        let luminance = try click(BrushRenderingSettings(luminanceBlending: true), options: options, base: base)
        #expect(difference(normal, multiply) > 20 && difference(multiply, screen) > 20)
        let pixel = renderingPixel(luminance, 240, 64)
        #expect(pixel[1] > pixel[0] * 2 && pixel[3] == 255, "Luminance mode must retain destination hue")
        let examples = [original, wet, burned, bright, binary, normal, multiply, screen, luminance]
        let atlas = try BrushRaster.context(width: 512, height: examples.count * 128, mask: false)
        atlas.setFillColor(NSColor.white.cgColor)
        atlas.fill(CGRect(x: 0, y: 0, width: 512, height: examples.count * 128))
        for (row, example) in examples.enumerated() {
            let transform = LayerTransform(origin: CGPoint(x: 0, y: row * 128), size: size)
            LayerRenderer.draw(try #require(example.makeImage()), transform: transform, center: transform.center, in: atlas)
        }
        Attachment.record(try #require(NSBitmapImageRep(cgImage: atlas.makeImage()!).representation(using: .png, properties: [:])), named: "rendering-edges-threshold-blends.png")
        for mode in LayerBlendMode.allCases {
            let result = try click(BrushRenderingSettings(burntEdges: 0.7, edgeBlend: mode, strokeBlend: mode), options: options, base: base)
            #expect(alpha(result, 240, 64) == 255)
            #expect(renderingPixel(result, 100, 10) == renderingPixel(normal, 100, 10), "Blend changed untouched pixels: \(mode)")
        }
    }

    @Test func burntEdgePoolingIsDeferredContinuousAndStableAcrossTiles() throws {
        var options = RoundBrushDynamics()
        options.spacing = 0.12
        options.flow = 0.38
        options.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
        options.rendering = BrushRenderingSettings(burntEdges: 1)
        let pooled = try make(options, diameter: 52, seed: 0xA77E)
        options.rendering = BrushRenderingSettings()
        let plain = try make(options, diameter: 52, seed: 0xA77E)
        for stroke in [pooled, plain] {
            for index in 0...32 {
                try stroke.append(CGPoint(x: 100 + index * 8, y: 64 + (index % 3 - 1) * 2))
            }
        }
        let livePooled = try raster(pooled), livePlain = try raster(plain)
        #expect(difference(livePooled, livePlain) == 0, "Pooling is deferred until the stroke is settled")
        try pooled.flush(); try plain.flush()
        let final = try raster(pooled), unpooled = try raster(plain)
        #expect(difference(final, unpooled) > 8, "Settled pooling adds a visible, continuous dark edge")
        let beforeRepeat = try raster(pooled)
        try pooled.flush()
        #expect(difference(beforeRepeat, try raster(pooled)) == 0, "Settled edge pooling must be deterministic and idempotent")
        Attachment.record(try #require(NSBitmapImageRep(cgImage: final.makeImage()!).representation(using: .png, properties: [:])),
            named: "rendering-burnt-edge-pooled.png")
    }

    @Test func renderingDualNormalOwnsBothSourcesAndKeepsMissingGates() throws {
        var preset = BrushPreset(name: "Dual")
        let tip = asymmetricBrushShapeTip()
        preset.source = BrushSource(archiveDigest: String(repeating: "a", count: 64), filename: "Dual.brush", definitions: [
            .init(path: "Brush.archive", shapeReference: "Tip.png", shapeResolution: .embedded(path: "Tip.png"), tip: tip),
            .init(path: "Sub01/Brush.archive", shapeReference: "Tip.png", shapeResolution: .embedded(path: "Sub01/Tip.png"), tip: GeneratedBrushTip.speckle.make())])
        preset.roundDynamics.shape = ShapeBrushSettings(source: .embedded)
        preset.roundDynamics.wetMix = BrushWetMix(pull: 0.5)
        preset.usesShapeApproximation = true
        #expect(!preset.isRenderable)
        preset.roundDynamics.rendering = BrushRenderingSettings(dualSource: .original, secondaryScale: 1.5)
        #expect(preset.isValid && preset.isRenderable)
        func click(_ preset: BrushPreset) throws -> CGContext {
            var settings = preset.applying(to: BrushSettings(red: 1))
            settings.diameter = 48
            let stroke = try BrushStroke(layer: ImageLayer(name: "Dual", blankSize: size), mask: false, settings: settings, canvas: size)
            try stroke.append(CGPoint(x: 256, y: 64)); try stroke.flush(); return try raster(stroke)
        }
        let modern = try click(preset)
        preset.roundDynamics.rendering?.classicDualNormal = true
        let classic = try click(preset)
        #expect(difference(modern, classic) > 100)
        for (name, image) in [("modern", modern), ("classic", classic)] {
            Attachment.record(try #require(NSBitmapImageRep(cgImage: image.makeImage()!).representation(using: .png, properties: [:])), named: "rendering-dual-\(name).png")
        }
        #expect(preset.source?.definitions[1].shapeResolution == .embedded(path: "Sub01/Tip.png"))
        preset.source?.definitions[1].tip = nil
        #expect(!preset.isValid && !preset.isRenderable)
        preset.roundDynamics.rendering?.dualSource = .generated
        #expect(preset.isValid && preset.isRenderable, "An explicit native secondary override is allowed")
        preset.source?.definitions[1].grainReference = "Missing grain.png"
        #expect(!preset.isRenderable)
    }

    @Test func renderingSelectedTransformedMaskUndoExportAndReopen() async throws {
        let session = EditorSession(); session.createDocument(width: 512, height: 128)
        let context = try BrushRaster.context(width: 512, height: 128, mask: false)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(origin: .zero, size: size))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "White"))
        let i = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[i].transform = LayerTransform(origin: CGPoint(x: 128, y: -192), size: CGSize(width: 256, height: 512), rotation: 90, flipX: true)
        session.addLayerMask(); session.isMaskSelected = true; session.selectTool(.brush); session.maskPaintWhite = false
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 200, y: 0, width: 100, height: 128), transform: nil)), name: "Clip")
        session.brushSettings.roundDynamics.flow = 0.3; session.brushSettings.roundDynamics.spacing = 0.2
        session.brushSettings.roundDynamics.taperEnd = 0.1
        session.brushSettings.roundDynamics.wetMix = BrushWetMix(dilution: 0.2, charge: 0.7, pull: 0.5, grade: 0.3, blur: 0.6)
        session.brushSettings.roundDynamics.colorDynamics = BrushColorDynamics(stamp: BrushColorResponse(hue: 0.3))
        session.brushSettings.roundDynamics.rendering = BrushRenderingSettings(mode: .intenseGlaze, wetEdges: 1, burntEdges: 0.7,
            strokeBlend: .screen, luminanceBlending: true, alphaThreshold: 0.1, dualSource: .generated, secondary: .bristles, classicDualNormal: true)
        session.beginBrush(at: CGPoint(x: 32, y: 64), seed: 42); session.continueBrush(at: CGPoint(x: 480, y: 64))
        #expect(session.finishBrushImmediately())
        let painted = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let pixels = try BrushRaster.copy(painted)
        #expect(alpha(pixels, 150, 64) == 255 && alpha(pixels, 350, 64) == 255)
        #expect((200..<300).contains { alpha(pixels, $0, 64) < 200 })
        session.undo(); let undone = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(alpha(try BrushRaster.copy(undone), 250, 64) == 255)
        session.redo()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = try await ImageExporter.shared.render(try await ProjectStore.shared.load(from: url)).image
        #expect(difference(pixels, try BrushRaster.copy(reopened)) == 0)
        session.undo(); session.isMaskSelected = false
        // Isolate color deposition/clipping from pickup of the white backdrop.
        session.brushSettings.roundDynamics.wetMix?.pull = 0
        session.brushSettings.red = 0.8; session.brushSettings.green = 0.2; session.brushSettings.blue = 0.1
        session.brushSettings.roundDynamics.rendering = BrushRenderingSettings(mode: .intenseGlaze, wetEdges: 0.6,
            burntEdges: 0.5, strokeBlend: .multiply)
        session.beginBrush(at: CGPoint(x: 32, y: 64), seed: 42); session.continueBrush(at: CGPoint(x: 480, y: 64))
        #expect(session.finishBrushImmediately())
        let colored = try BrushRaster.copy(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
        #expect(renderingPixel(colored, 150, 64) == renderingPixel(try BrushRaster.copy(undone), 150, 64))
        #expect(renderingPixel(colored, 350, 64) == renderingPixel(try BrushRaster.copy(undone), 350, 64))
        #expect(renderingPixel(colored, 250, 64)[1] < 250, "Transformed color painting must stay inside the selection")
    }

    @Test func renderingIsIndependentOfTilePartitionAndTransparentBackdrop() throws {
        var settings = BrushSettings(diameter: 32, hardness: 0.3, red: 0.7, green: 0.3, blue: 0.12, opacity: 0.8)
        settings.roundDynamics.spacing = 0.25; settings.roundDynamics.flow = 0.25
        settings.roundDynamics.shape = ShapeBrushSettings(source: .custom, customTip: asymmetricBrushShapeTip())
        settings.roundDynamics.grain = BrushGrain(scale: 23, depth: 0.7)
        settings.roundDynamics.colorDynamics = BrushColorDynamics(stamp: BrushColorResponse(hue: 0.5, secondary: 0.3))
        settings.roundDynamics.wetMix = BrushWetMix(dilution: 0.2, charge: 0.7, pull: 0.5, grade: 0.3, blur: 0.6)
        settings.roundDynamics.rendering = BrushRenderingSettings(mode: .intenseBlending, wetEdges: 0.8, burntEdges: 0.7,
            edgeBlend: .colorBurn, strokeBlend: .multiply, luminanceBlending: true, alphaThreshold: 0.05,
            dualSource: .generated, secondary: .speckle, secondaryScale: 1.25)
        var results: [CGContext] = []
        for offset: CGFloat in [0, -127] {
            var layer = ImageLayer(name: "Partition", blankSize: CGSize(width: 1024, height: 128))
            layer.transform.origin.x = offset
            let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: size, useGPU: offset == 0, seed: 42)
            try trace(stroke, steps: offset == 0 ? 1 : 64)
            results.append(try raster(stroke))
        }
        #expect(difference(results[0], results[1]) <= 1, "Tile boundaries changed rendering pixels")
        let transparent = try BrushRaster.context(width: 512, height: 128, mask: false)
        transparent.setFillColor(NSColor(calibratedRed: 0.1, green: 0.7, blue: 0.3, alpha: 0.4).cgColor)
        transparent.fill(CGRect(origin: .zero, size: size))
        let base = try #require(transparent.makeImage())
        let stroke = try renderingStroke(BrushRenderingSettings(luminanceBlending: true), base: base)
        try stroke.append(CGPoint(x: 240, y: 64)); try stroke.flush()
        let image = try raster(stroke)
        #expect(abs(alpha(image, 20, 10) - 102) <= 1, "Luminance composition must not increase untouched translucent alpha")
        #expect(alpha(image, 240, 64) > 102)
    }

    @Test func renderingFourKTimingAndTileBudget() throws {
        var report = "4K Debug Rendering: 2400 px path, 12 updates, 25% spacing. Native CPU advanced path.\n"
        for diameter: CGFloat in [40, 800] { for configuration in 0..<5 {
            let mode: BrushRenderingSettings.Mode = configuration == 0 ? .uniformGlaze : .intenseBlending
            var settings = BrushSettings(diameter: diameter, hardness: 0.4, red: 0.7, green: 0.3, blue: 0.1)
            settings.roundDynamics.spacing = 0.25; settings.roundDynamics.flow = 0.3
            settings.roundDynamics.rendering = BrushRenderingSettings(mode: mode, wetEdges: 0.5, burntEdges: 0.5, strokeBlend: .multiply)
            if configuration == 4 { settings.roundDynamics.colorDynamics = BrushColorDynamics(stroke: BrushColorResponse(hue: 0.5), stamp: BrushColorResponse(hue: 0.6, saturation: 0.3, secondary: 0.4)) }
            if configuration == 3 { settings.roundDynamics.wetMix = BrushWetMix(dilution: 0.2, charge: 0.7, pull: 0.5, grade: 0.3, blur: 0.6, blurJitter: 0.4, wetnessJitter: 0.3) }
            if configuration == 2 { settings.roundDynamics.grain = BrushGrain(scale: 23, depth: 0.8, filtering: .improved) }
            let stroke = try BrushStroke(layer: ImageLayer(name: "4K", blankSize: CGSize(width: 4000, height: 4000)), mask: false,
                settings: settings, canvas: CGSize(width: 4000, height: 4000))
            var times: [Double] = []
            for step in 0...12 {
                let start = CFAbsoluteTimeGetCurrent()
                try stroke.append(CGPoint(x: 700 + step * 200, y: 2000), input: BrushInput(timestamp: Double(step) / 12))
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            let start = CFAbsoluteTimeGetCurrent(); try stroke.flush(); let flush = (CFAbsoluteTimeGetCurrent() - start) * 1000
            times.sort(); #expect(!stroke.patches.isEmpty && stroke.patches.count < 120)
            report += "diameter=\(diameter) mode=\(mode.rawValue) grain=\(configuration == 2) wetMix=\(configuration == 3) colorDynamics=\(configuration == 4) median=\(times[times.count / 2])ms max=\(times.last!)ms flush=\(flush)ms tiles=\(stroke.patches.count)\n"
        } }
        Attachment.record(Data(report.utf8), named: "rendering-4k-timing.txt")
    }

    @Test func editorGapSettingsValidatePersistAndKeepLegacyDefaults() throws {
        var preset = BrushPreset(name: "Complete")
        preset.roundDynamics.properties = BrushProperties(minimumSize: 5, maximumSize: 100, minimumOpacity: 0.1, maximumOpacity: 0.7)
        preset.roundDynamics.stabilization = BrushStabilization(streamline: 0.2, pressure: 0.5, stabilization: 0.3, motion: 0.2, expression: 0.4)
        preset.roundDynamics.pressureTaper = BrushTaper(start: 0.2, end: 0.3, size: 0.6, opacity: 0.5, pressure: 0.2, tip: 0.8)
        preset.roundDynamics.touchTaper = BrushTaper(start: 0.1, end: 0.1)
        preset.roundDynamics.grain = BrushGrain()
        #expect(preset.isValid)
        #expect(try JSONDecoder().decode(BrushPreset.self, from: JSONEncoder().encode(preset)) == preset)
        preset.roundDynamics.properties?.minimumSize = 101; #expect(!preset.isValid)
        preset.roundDynamics.properties?.minimumSize = 5
        preset.roundDynamics.grain?.scale = .nan; #expect(!preset.isValid)
        #expect(!BrushTaper(tip: .infinity).isValid && !BrushStabilization(motion: -1).isValid)
        #expect(!RoundBrushDynamics().usesStamps && !RoundBrushDynamics().hasTaper)
    }

    @Test func grainChangesActualPixelsAndRetainsSeededReplay() throws {
        var options = RoundBrushDynamics(); options.spacing = 0.15; options.flow = 0.2
        let original = try make(options, hardness: 1); try trace(original, steps: 1)
        let plain = try raster(original)
        let atlas = try BrushRaster.context(width: 512, height: 256, mask: false)
        atlas.setFillColor(NSColor.white.cgColor); atlas.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
        var modes: [CGContext] = []
        for (row, mode) in [BrushGrain.Mode.moving, .texturized].enumerated() {
            options.grain = BrushGrain(mode: mode, scale: 18, depth: 1, movement: 0.3, depthJitter: 0.4, offsetJitter: 0.3)
            let sparse = try make(options), dense = try make(options, gpu: false)
            try trace(sparse, steps: 1); try trace(dense, steps: 64)
            let image = try raster(sparse); modes.append(image)
            #expect(difference(image, plain) > 10)
            #expect(difference(image, try raster(dense)) <= 1)
            let transform = LayerTransform(origin: CGPoint(x: 0, y: row * 128), size: size)
            LayerRenderer.draw(try #require(image.makeImage()), transform: transform, center: transform.center, in: atlas)
            for filtering in [ShapeBrushSettings.Filtering.classic, .improved] {
                options.grain?.filtering = filtering
                let cpu = try make(options, gpu: false), metal = try make(options)
                #expect(metal.usesMetalStampRenderer)
                try trace(cpu, steps: 32); try trace(metal, steps: 32)
                #expect(difference(try raster(cpu), try raster(metal)) <= 1,
                    "\(mode.rawValue) grain with \(filtering.rawValue) filtering must match CPU output")
            }
        }
        #expect(difference(modes[0], modes[1]) > 1, "Moving grain must differ from canvas-anchored grain")
        for (index, blend) in BrushGrain.Blend.allCases.enumerated() {
            options.grain?.blend = blend; options.grain?.brightness = 0.1; options.grain?.contrast = 0.2
            options.grain?.filtering = ShapeBrushSettings.Filtering.allCases[index % 3]
            let textured = try make(options); try trace(textured, steps: 1)
            #expect(difference(try raster(textured), plain) > 0)
        }
        options.grain?.depth = 0
        let disabled = try make(options); try trace(disabled, steps: 1)
        #expect(difference(try raster(disabled), plain) <= 1)
        Attachment.record(try #require(NSBitmapImageRep(cgImage: atlas.makeImage()!).representation(using: .png, properties: [:])), named: "editor-grain-modes.png")
        options.flow = 1; options.grain = BrushGrain(scale: 64, depth: 1)
        let repeated = try make(options)
        try trace(repeated, steps: 1)
        for _ in 0..<6 { try repeated.append(CGPoint(x: 32, y: 64)); try repeated.append(CGPoint(x: 480, y: 64)); try repeated.flush() }
        let saturated = try raster(repeated)
        #expect((10..<250).contains(alpha(saturated, 256, 64)), "Texturized grain must survive repeated full-flow overlap")

        var source = BrushPreset(name: "Missing Grain")
        source.source = BrushSource(archiveDigest: String(repeating: "a", count: 64), filename: "Grain.brush", definitions: [
            .init(path: "Brush.archive", shapeReference: BasicBrushShape.soft.rawValue, grainReference: "Missing.png", shapeResolution: .procedural(.soft, revision: BasicBrushShape.revision), grainResolution: .missing)])
        source.usesShapeApproximation = true
        #expect(!source.isRenderable)
        source.roundDynamics.grain = BrushGrain(); #expect(source.isRenderable)
        source.roundDynamics.grain?.source = .original; #expect(!source.isValid && !source.isRenderable)
    }

    @Test func gpuGlazeModesMatchCpuForGrainedStrokes() throws {
        for (index, mode) in [BrushRenderingSettings.Mode.lightGlaze, .uniformGlaze, .intenseGlaze, .heavyGlaze].enumerated() {
            var options = RoundBrushDynamics()
            options.spacing = 0.2
            options.flow = 0.7
            options.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
            options.grain = BrushGrain(mode: index.isMultiple(of: 2) ? .moving : .texturized,
                scale: 21, depth: 0.73, brightness: 0.08, contrast: 0.2, movement: 0.35,
                depthJitter: 0.17, offsetJitter: 0.13, rotation: 0.2, blend: BrushGrain.Blend.allCases[index])
            options.rendering = BrushRenderingSettings(mode: mode)
            let cpu = try make(options, diameter: 28, gpu: false, seed: 0xB71571E5)
            let metal = try make(options, diameter: 28, seed: 0xB71571E5)
            #expect(metal.usesMetalStampRenderer)
            try trace(cpu, steps: 24)
            try trace(metal, steps: 24)
            #expect(difference(try raster(cpu), try raster(metal)) <= 1,
                "\(mode.rawValue) grain output must match the CPU reference within one byte")
        }
    }

    @Test func gpuWatercolorEdgesMatchCPUThroughTileCrossingAndTailReplay() throws {
        var options = RoundBrushDynamics()
        options.spacing = 0.18
        options.flow = 0.62
        options.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
        options.grain = BrushGrain(mode: .texturized, scale: 23, depth: 0.81,
            brightness: 0.07, contrast: 0.16, blend: .multiply, filtering: .improved)
        options.rendering = BrushRenderingSettings(wetEdges: 0.72, burntEdges: 0.68, edgeBlend: .multiply)
        let cpu = try make(options, diameter: 48, gpu: false, seed: 0xB71571E5)
        let metal = try make(options, diameter: 48, seed: 0xB71571E5)
        #expect(metal.usesMetalStampRenderer)

        for (index, x) in [190, 222, 254, 286, 318, 350].enumerated() {
            let input = BrushInput(pressure: 0.38 + CGFloat(index) * 0.08,
                tilt: CGPoint(x: 0.2, y: 0.7), rotation: 0.15 * CGFloat(index), timestamp: Double(index) / 60)
            try cpu.append(CGPoint(x: x, y: 64), input: input)
            try metal.append(CGPoint(x: x, y: 64), input: input)
        }
        try cpu.flush(); try metal.flush()
        let reference = try raster(cpu)
        #expect(difference(reference, try raster(metal)) <= 1,
            "Wet tip shape and accumulated burnt edges must survive tile crossing and provisional-tail replacement")
        try cpu.flush(); try metal.flush()
        #expect(difference(reference, try raster(metal)) <= 1, "Repeated flush must not re-accumulate burnt edges")
    }

    @Test func orderedBrushInputBatchesMatchIndividualSamples() throws {
        var options = RoundBrushDynamics()
        options.spacing = 0.18
        options.flow = 0.64
        options.count = 2
        options.scatter = 0.08
        options.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
        options.grain = BrushGrain(mode: .texturized, scale: 23, depth: 0.71,
            brightness: 0.04, contrast: 0.12, blend: .multiply, filtering: .improved)
        options.rendering = BrushRenderingSettings(wetEdges: 0.35, burntEdges: 0.42, edgeBlend: .multiply)
        let samples = (0...48).map { index -> BrushStroke.InputSample in
            let t = CGFloat(index) / 48
            let previousT = CGFloat(max(0, index - 1)) / 48
            let repeatedPoint = index == 25
            let positionT = repeatedPoint ? previousT : t
            return BrushStroke.InputSample(point: CGPoint(x: 28 + 456 * positionT,
                y: 64 + sin(positionT * .pi * 2) * 16), input: BrushInput(
                    pressure: index == 25 ? 0.93 : 0.28 + 0.68 * t,
                    tilt: CGPoint(x: 0.25, y: 0.7), rotation: 0.11 * t,
                    timestamp: Double(index) / 60, deviceID: 17))
        }

        for useGPU in [false, true] {
            let individual = try make(options, diameter: 46, gpu: useGPU, seed: 0xB71571E5)
            let batched = try make(options, diameter: 46, gpu: useGPU, seed: 0xB71571E5)
            for sample in samples { try individual.append(sample.point, input: sample.input) }
            for start in stride(from: 0, to: samples.count, by: 8) {
                try batched.append(batch: Array(samples[start..<min(samples.count, start + 8)]))
            }
            try individual.flush(); try batched.flush()
            let expected = try raster(individual), actual = try raster(batched)
            #expect(difference(expected, actual) <= 1,
                "Batching may reduce publication frequency but must preserve ordered pressure, tilt, rotation, and tile-crossing pixels")
            #expect(batched.tilePublicationCount < individual.tilePublicationCount,
                "Each input batch should publish at most once")
        }
    }

    @Test func sessionFrameBatchPreservesInputFilteringAndPixels() throws {
        func session() -> EditorSession {
            let value = EditorSession()
            value.createDocument(width: 512, height: 128)
            value.addBlankLayer()
            value.selectTool(.brush)
            value.brushSettings.diameter = 42
            value.brushSettings.pressureSize = true
            value.brushSettings.smoothing = 0.14
            value.brushSettings.roundDynamics.spacing = 0.19
            value.brushSettings.roundDynamics.strokePath = StrokePathSettings(speedSpacing: 0.35)
            value.brushSettings.roundDynamics.stabilization = BrushStabilization(
                streamline: 0.2, pressure: 0.3, stabilization: 0.18, motion: 0.05, expression: 0.1)
            return value
        }
        let individual = session()
        let first = BrushInput(pressure: 0.2, tilt: CGPoint(x: 0.2, y: 0.7), rotation: 0.1,
                               timestamp: 0, deviceID: 17)
        individual.beginBrush(at: CGPoint(x: 32, y: 64), input: first, seed: 501)
        let samples = (1...48).map { index -> BrushStroke.InputSample in
            let t = CGFloat(index) / 48
            let stationary = index == 24
            let previousT = CGFloat(index - 1) / 48
            let positionT = stationary ? previousT : t
            return BrushStroke.InputSample(point: CGPoint(x: 32 + 448 * positionT,
                y: 64 + sin(positionT * .pi * 2) * 14), input: BrushInput(
                    pressure: index == 24 ? 0.95 : 0.2 + 0.75 * t,
                    tilt: CGPoint(x: 0.2 + 0.4 * t, y: 0.7), rotation: 0.1 + 0.3 * t,
                    timestamp: Double(index) / 60, deviceID: 17))
        }
        for sample in samples {
            individual.continueBrush(at: sample.point, input: sample.input)
        }
        let individualStroke = try #require(individual.brushStroke)
        #expect(individual.finishBrushImmediately(), "The reference stroke should commit")
        let expected = try raster(individualStroke)
        for samplesPerFrame in [1, 4, 12, 48] {
            let batched = session()
            batched.beginBrush(at: CGPoint(x: 32, y: 64), input: first, seed: 501)
            for (index, sample) in samples.enumerated() {
                batched.queueBrushInput(at: sample.point, input: sample.input)
                if (index + 1).isMultiple(of: samplesPerFrame) || index == samples.count - 1 {
                    try batched.flushQueuedBrushInputSamples()
                }
            }
            let batchedStroke = try #require(batched.brushStroke)
            #expect(batched.finishBrushImmediately(), "Mouse-up must commit after cadence (samplesPerFrame)")
            #expect(difference(expected, try raster(batchedStroke)) <= 1,
                "(samplesPerFrame) samples per frame changed output despite identical ordered input, speed spacing, pressure, smoothing, and stabilization")
        }
    }

    @Test func queuedSessionInputIsBoundedAndCancelDropsOnlyPendingTail() throws {
        let session = EditorSession()
        session.createDocument(width: 512, height: 128)
        session.addBlankLayer(); session.selectTool(.brush)
        session.brushSettings.diameter = 20
        session.beginBrush(at: CGPoint(x: 80, y: 64), input: BrushInput(pressure: 0.5, timestamp: 0, deviceID: 9), seed: 83)
        for index in 1...4097 {
            session.queueBrushInput(at: CGPoint(x: 80, y: 64),
                input: BrushInput(pressure: 0.5, timestamp: Double(index) / 60, deviceID: 9))
        }
        #expect(session.pendingBrushInputSamples.count == 1, "The 4096-sample frame buffer must flush before it can grow further")
        #expect(session.brushStroke?.lastInput?.timestamp == 4096.0 / 60,
                "The capacity flush must retain all older accepted input in order")
        session.cancelBrush()
        #expect(session.pendingBrushInputSamples.isEmpty && session.brushStroke == nil,
                "Cancellation must discard the unsubmitted tail and release the stroke")
    }

    @Test func queuedBrushSamplesBlockToolAndProjectTransitionsUntilMouseUp() throws {
        let session = EditorSession()
        session.createDocument(width: 256, height: 128)
        session.addBlankLayer(); session.selectTool(.brush)
        let projects = ProjectController(session: session)
        session.beginBrush(at: CGPoint(x: 24, y: 64), input: BrushInput(pressure: 0.5, timestamp: 0, deviceID: 4), seed: 94)
        for index in 1...8 {
            session.queueBrushInput(at: CGPoint(x: 24 + index * 12, y: 64),
                input: BrushInput(pressure: 0.5, timestamp: Double(index) / 60, deviceID: 4))
        }

        #expect(session.pendingBrushInputSamples.count == 8)
        #expect(!projects.canStart, "Project replacement and save entry points must remain gated during the active stroke")
        session.selectTool(.move)
        #expect(session.tool == .brush && session.pendingBrushInputSamples.count == 8,
            "A tool change must not strand or discard queued brush input")

        #expect(session.finishBrushImmediately())
        #expect(session.pendingBrushInputSamples.isEmpty && session.brushStroke == nil)
        #expect(session.activeLayer?.asset?.image != nil)
        #expect(projects.canStart, "Project operations become available after mouse-up commits the queued batch")
        session.selectTool(.move)
        #expect(session.tool == .move)
    }

    @Test func backrunsCreateSeededStaticBloomsOverGrainedWash() throws {
        var options = RoundBrushDynamics()
        options.spacing = 0.2
        options.flow = 0.55
        options.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
        options.grain = BrushGrain(mode: .texturized, scale: 31, depth: 0.72,
            brightness: 0.06, contrast: 0.18, blend: .multiply, filtering: .improved)
        let plain = try make(options, diameter: 64, seed: 0xA17E)
        options.rendering = BrushRenderingSettings(wetEdges: 0.32, burntEdges: 0.45, backruns: 0.82)
        let metal = try make(options, diameter: 64, seed: 0xA17E)
        let cpu = try make(options, diameter: 64, gpu: false, seed: 0xA17E)
        let otherSeed = try make(options, diameter: 64, seed: 0xB100)
        #expect(metal.usesMetalStampRenderer)
        for stroke in [plain, metal, cpu, otherSeed] {
            for index in 0...48 {
                let t = CGFloat(index) / 48
                let point = CGPoint(x: 32 + 448 * t, y: 54 + sin(t * .pi * 2) * 14)
                let input = BrushInput(pressure: 0.25 + 0.7 * t, timestamp: Double(t))
                try stroke.append(point, input: input)
            }
            try stroke.flush()
        }
        let wash = try raster(metal), reference = try raster(cpu)
        #expect(difference(wash, reference) <= 2, "Settled backrun output must remain within two channel levels across CPU and Metal stamp accumulation")
        #expect(difference(wash, try raster(plain)) > 8, "Backruns should alter the final grainy wash")
        #expect(difference(wash, try raster(otherSeed)) > 1, "Bloom placement must vary deterministically with the stroke seed")
        let final = try raster(metal)
        try metal.flush()
        #expect(difference(final, try raster(metal)) == 0, "Repeated finalization must not animate or accumulate backruns")
        let atlas = try BrushRaster.context(width: 512, height: 128, mask: false)
        atlas.setFillColor(NSColor.white.cgColor); atlas.fill(CGRect(x: 0, y: 0, width: 512, height: 128))
        LayerRenderer.draw(try #require(wash.makeImage()), transform: LayerTransform(origin: .zero, size: size),
            center: CGPoint(x: size.width / 2, y: size.height / 2), in: atlas)
        Attachment.record(try #require(NSBitmapImageRep(cgImage: atlas.makeImage()!).representation(using: .png, properties: [:])),
            named: "rendering-backrun-grain.png")
    }

    @Test func propertyBoundsAffectStrokeAndPressureWithoutSquaringOpacity() throws {
        var settings = BrushSettings(diameter: 100, hardness: 1, red: 1)
        settings.roundDynamics.properties = BrushProperties(minimumSize: 10, maximumSize: 20, minimumOpacity: 0.1, maximumOpacity: 0.5)
        let stroke = try BrushStroke(layer: ImageLayer(name: "Bounds", blankSize: size), mask: false, settings: settings, canvas: size)
        #expect(stroke.settings.diameter == 20 && stroke.settings.opacity == 0.5)
        try stroke.append(CGPoint(x: 256, y: 64)); try stroke.flush()
        let image = try raster(stroke)
        #expect(abs(alpha(image, 256, 64) - 128) <= 1 && alpha(image, 268, 64) == 0)
        settings.pressureSize = true; settings.pressureOpacity = true
        let response = settings.dynamics(0)
        #expect(response.scale == 0.1 && response.strength == 0.1)
    }

    @Test func independentPenAndTouchTapersReplaySizeAndOpacityTogether() throws {
        var options = RoundBrushDynamics(); options.spacing = 0.15; options.flow = 0.3
        options.pressureTaper = BrushTaper(start: 0.3, end: 0.3, size: 0, opacity: 1, tip: 0.8)
        options.touchTaper = BrushTaper(start: 0.2, end: 0.2, size: 1, opacity: 0, tip: 0.1)
        var outputs: [CGContext] = []
        for pen in [true, false] {
            let a = try make(options), b = try make(options, gpu: false)
            for (stroke, steps) in [(a, 1), (b, 64)] {
                for n in 0...steps {
                    let t = CGFloat(n) / CGFloat(steps)
                    try stroke.append(CGPoint(x: 32 + 448*t, y: 64), input: BrushInput(pressure: pen ? 0.6 : nil, timestamp: Double(t)))
                }
                try stroke.flush()
            }
            let image = try raster(a); outputs.append(image)
            #expect(difference(image, try raster(b)) <= 1)
            #expect(alpha(image, 32, 64) < 50 && alpha(image, 256, 64) > 80)
        }
        #expect(difference(outputs[0], outputs[1]) > 10)
        let taper = BrushTaper(start: 0.5, size: 1, tip: 1)
        #expect(taper.response(distance: 0.25, total: 1, input: nil).size < taper.response(distance: 0.25, total: 1, input: nil, classic: true).size)
    }

    @Test func relativeStrokeOrientationChangesBarrelDrivenShapePixels() throws {
        var options = imageOptions(); options.shape?.inputStyle = .barrel
        var outputs: [CGContext] = []
        for relative in [false, true] {
            options.shape?.relativeToStroke = relative
            let stroke = try make(options, diameter: 40)
            let input = BrushInput(pressure: 1, tilt: CGPoint(x: 0.5, y: 0), rotation: 0.2)
            try stroke.append(CGPoint(x: 240, y: 24), input: input)
            try stroke.append(CGPoint(x: 240, y: 104), input: input); try stroke.flush()
            outputs.append(try raster(stroke))
        }
        #expect(difference(outputs[0], outputs[1]) > 50)
    }

    @Test func smudgePullScalesSmudgeWithoutChangingLiquify() throws {
        let image = try renderingBackdrop()
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Smudge"), origin: .zero)
        var settings = BrushSettings(opacity: 0.8)
        settings.roundDynamics.properties = BrushProperties(smudgePull: 0)
        let smudge = try WarpStroke(layer: layer, image: image, transform: layer.transform, canvas: size, mode: .smudge, settings: settings, useGPU: false)
        let push = try WarpStroke(layer: layer, image: image, transform: layer.transform, canvas: size, mode: .liquify, settings: settings, useGPU: false)
        #expect(smudge.strength == 0 && push.strength == 0.8)
        smudge.append(CGPoint(x: 240, y: 64)); smudge.append(CGPoint(x: 280, y: 64))
        #expect(difference(try BrushRaster.copy(try #require(smudge.image)), try BrushRaster.copy(image)) == 0)
    }

    @Test func stabilizationFiltersPositionAndPressureOnTheSharedSessionPath() throws {
        let p = CGPoint(x: 30, y: 10), zero = CGPoint.zero
        #expect(BrushStabilization().point(p, previous: zero, rawPrevious: zero, zoom: 1) == p)
        let filter = BrushStabilization(streamline: 0.5, pressure: 1, stabilization: 0.5, motion: 0.2)
        let damped = filter.point(p, previous: zero, rawPrevious: zero, zoom: 1)
        #expect(damped.x < p.x && damped.x >= 0)
        let session = EditorSession(); session.createDocument(width: 512, height: 128)
        session.addBlankLayer(); session.selectTool(.brush)
        session.brushSettings.roundDynamics.stabilization = filter
        session.beginBrush(at: CGPoint(x: 32, y: 64), input: BrushInput(pressure: 0.2))
        session.continueBrush(at: CGPoint(x: 100, y: 64), input: BrushInput(pressure: 1))
        #expect(session.brushAnchor!.x < 100 && session.brushInput.pressure! < 1)
        #expect(session.finishBrushImmediately())
    }

    private func imageOptions() -> RoundBrushDynamics {
        var options = RoundBrushDynamics()
        options.spacing = 0.4
        options.shape = ShapeBrushSettings(source: .custom, customTip: asymmetricBrushShapeTip(), filtering: .none)
        return options
    }
    @Test func asymmetricImageRotationFlipsAndFilteringAreReal() throws {
        func click(_ options: RoundBrushDynamics, point: CGPoint = CGPoint(x: 256, y: 64), seed: UInt64 = 1) throws -> CGContext {
            let stroke = try make(options, seed: seed); try stroke.append(point); try stroke.flush(); return try raster(stroke)
        }
        var options = imageOptions()
        let base = try click(options)
        options.shape?.flipX = true
        let x = try click(options)
        options.shape?.flipX = false; options.shape?.flipY = true
        let y = try click(options)
        options.shape?.flipY = false; options.angle = .pi / 2
        let rotated = try click(options)
        for row in 44..<84 { for col in 236..<276 {
            #expect(alpha(base, col, row) == alpha(x, 511 - col, row))
            #expect(alpha(base, col, row) == alpha(y, col, 127 - row))
            #expect(alpha(base, col, row) == alpha(rotated, 319 - row, col - 192))
        } }
        #expect(difference(base, x) > 200 && difference(base, y) > 200 && difference(base, rotated) > 200)
        var copies = imageOptions(); copies.flow = 0.1; copies.count = 16
        #expect(abs(alpha(try click(copies), 244, 52) - 208) <= 1)
        copies.shape?.countJitter = 1
        #expect(abs(alpha(try click(copies), 244, 52) - 145) <= 1, "Seed 1 selects 8 of 16 copies; count jitter must affect coverage")
        var randomized = imageOptions(); randomized.shape?.randomized = true
        #expect(difference(try click(randomized, seed: 1), try click(randomized, seed: 2)) > 100)
        #expect(difference(try click(randomized, seed: 1), try click(randomized, seed: 1)) == 0)
        options.angle = 0.31; options.roundness = 0.63
        let nearest = try click(options, point: CGPoint(x: 256.3, y: 64.7))
        options.shape?.filtering = .classic
        let classic = try click(options, point: CGPoint(x: 256.3, y: 64.7))
        options.shape?.filtering = .improved
        let improved = try click(options, point: CGPoint(x: 256.3, y: 64.7))
        #expect(difference(nearest, classic) > 20 && difference(classic, improved) > 1)
        #expect((240..<273).contains { alpha(classic, $0, 60) > 0 && alpha(classic, $0, 60) < 255 })
        let atlas = try BrushRaster.context(width: 512, height: 256, mask: false)
        atlas.setFillColor(NSColor.white.cgColor); atlas.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
        atlas.interpolationQuality = .none
        for (i, context) in [base, x, y, rotated, nearest, classic, improved].enumerated() {
            let crop = try #require(context.makeImage()?.cropping(to: CGRect(x: 224, y: 32, width: 64, height: 64)))
            var transform = LayerTransform(origin: CGPoint(x: i % 4 * 128, y: i / 4 * 128), size: CGSize(width: 128, height: 128))
            transform.sampling = .nearest
            LayerRenderer.draw(crop, transform: transform, center: transform.center, in: atlas)
        }
        Attachment.record(try #require(NSBitmapImageRep(cgImage: atlas.makeImage()!).representation(using: .png, properties: [:])), named: "shape-flips-rotation-filtering.png")
    }
    @Test func shapeInputOrientationAndRoundnessRespectMissingHardware() throws {
        func click(_ options: RoundBrushDynamics, _ input: BrushInput) throws -> CGContext {
            let stroke = try make(options); try stroke.append(CGPoint(x: 256, y: 64), input: input); try stroke.flush(); return try raster(stroke)
        }
        var options = imageOptions()
        let base = try click(options, BrushInput())
        options.angle = .pi / 2
        let quarter = try click(options, BrushInput())
        options.angle = 0; options.shape?.inputStyle = .azimuth
        #expect(difference(try click(options, BrushInput(tilt: CGPoint(x: 0, y: 1))), quarter) == 0)
        #expect(difference(try click(options, BrushInput()), base) == 0)
        options.shape?.inputStyle = .barrel
        #expect(difference(try click(options, BrushInput(tilt: CGPoint(x: 0, y: 1))), quarter) == 0)
        #expect(difference(try click(options, BrushInput(tilt: CGPoint(x: 1, y: 0), rotation: .pi / 2)), quarter) == 0)
        options.shape?.relativeBarrel = true
        #expect(difference(try click(options, BrushInput(tilt: CGPoint(x: 1, y: 0), rotation: .pi / 2)), base) == 0)
        options.shape?.inputStyle = .touch; options.shape?.pressureRoundness = 1
        #expect(difference(try click(options, BrushInput()), base) == 0)
        #expect(difference(try click(options, BrushInput(pressure: 1)), base) > 200)
        options.shape?.pressureRoundness = 0; options.shape?.tiltRoundness = 1
        #expect(difference(try click(options, BrushInput(tilt: CGPoint(x: 1, y: 0))), base) > 200)
        options.shape?.tiltRoundness = 0; options.shape?.horizontalJitter = 1; options.shape?.horizontalInput = .pressure
        #expect(difference(try click(options, BrushInput(pressure: 0)), base) == 0)
        #expect(difference(try click(options, BrushInput(pressure: 1)), base) > 10)
        options.shape?.horizontalJitter = 0; options.shape?.rotationResponse = 1
        let follow = try make(options)
        options.shape?.rotationResponse = 0; let fixed = try make(options)
        options.shape?.rotationResponse = -1; let inverse = try make(options)
        for stroke in [follow, fixed, inverse] {
            try stroke.append(CGPoint(x: 256, y: 16)); try stroke.append(CGPoint(x: 256, y: 112)); try stroke.flush()
        }
        #expect(difference(try raster(follow), try raster(fixed)) > 100)
        #expect(difference(try raster(follow), try raster(inverse)) > 100)
    }
    @Test func imageShapeJitterAndFullInputTaperReplayAreDeterministic() throws {
        var options = imageOptions()
        options.count = 16; options.scatter = .pi; options.roundness = 0.7
        options.taperStart = 0.1; options.taperEnd = 0.1
        options.shape?.countJitter = 1; options.shape?.randomized = true
        options.shape?.horizontalJitter = 1; options.shape?.verticalJitter = 1
        options.shape?.inputStyle = .barrel; options.shape?.relativeBarrel = true; options.shape?.filtering = .classic
        let sparse = try make(options), dense = try make(options, gpu: false), replay = try make(options), other = try make(options, seed: 99)
        replay.defersTaperRendering = true
        for stroke in [sparse, dense, replay, other] {
            let steps = stroke === dense ? 96 : 1
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let point = CGPoint(x: 32 + 448 * t, y: 64)
                try stroke.append(point, input: BrushInput(pressure: 0.2 + 0.8 * t,
                    tilt: CGPoint(x: 0.2 + 0.6 * t, y: 0.1), rotation: -0.5 + 0.8 * t, timestamp: Double(t)))
            }
            try stroke.flush()
        }
        #expect(difference(try raster(sparse), try raster(dense)) <= 1)
        #expect(difference(try raster(sparse), try raster(replay)) == 0)
        #expect(difference(try raster(sparse), try raster(other)) > 10)
        let final = try raster(sparse); try sparse.flush(); #expect(difference(final, try raster(sparse)) == 0)
        Attachment.record(try #require(NSBitmapImageRep(cgImage: final.makeImage()!).representation(using: .png, properties: [:])), named: "shape-image-jitter-taper.png")
    }
    @Test func shapeMaskPersistenceBoundsAndOriginalBytes() throws {
        var unavailable = BrushPreset(name: "Unavailable")
        unavailable.roundDynamics.shape = ShapeBrushSettings(source: .embedded)
        #expect(!unavailable.isValid, "An embedded source needs its owning decoded mask")
        var empty = imageOptions()
        empty.shape?.customTip = BrushShapeTip(side: 1, luminance: Data([0]), alpha: Data([255]), name: "Black")
        let noPaint = try make(empty); try trace(noPaint, steps: 8)
        #expect(noPaint.patches.isEmpty, "An empty mask must not allocate or commit transparent paint")
        empty.shape?.mask = .inverted
        let inverted = try make(empty); try trace(inverted, steps: 8)
        #expect(!inverted.patches.isEmpty)
        let tip = asymmetricBrushShapeTip()
        #expect(tip.isValid && tip.mask(.alpha) == tip.alpha)
        #expect(tip.mask(.inverted).allSatisfy { $0 == 0 })
        var invalid = tip; invalid.side = 257; #expect(!invalid.isValid)
        invalid = tip; invalid.alpha.removeLast(); #expect(!invalid.isValid)
        #expect(throws: (any Error).self) { try BrushShapeTip.decode(Data([1, 2, 3]), name: "Invalid") }
        let image = try #require(tip.preview(.luminance))
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let decoded = try BrushShapeTip.decode(png, name: "L.png")
        #expect(decoded.side == 16 && decoded.luminance == tip.luminance)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("brushes.json"), library = BrushLibrary(url: url)
        var preset = BrushPreset(name: "Image")
        preset.roundDynamics = imageOptions()
        preset.roundDynamics.shape?.customTip?.originalDigest = try library.retainSource(png)
        try library.save(preset)
        let restored = BrushLibrary(url: url)
        #expect(restored.current == preset)
        #expect(try restored.retainedData(try #require(preset.roundDynamics.shape?.customTip?.originalDigest)) == png)
        let data = try Data(contentsOf: url)
        preset.roundDynamics.shape?.customTip?.side = 0
        #expect(throws: (any Error).self) { try library.save(preset) }
        #expect(try Data(contentsOf: url) == data)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(imageOptions())) as? [String: Any])
        legacy.removeValue(forKey: "shape")
        let restoredLegacy = try JSONDecoder().decode(RoundBrushDynamics.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!restoredLegacy.shapeSettings.isActive)
    }

    @Test func imageShapeTileSeamsMatchUnsplitCoverage() throws {
        var pixel = imageOptions(); pixel.angle = .pi / 4
        pixel.shape?.customTip = BrushShapeTip(side: 1, luminance: Data([255]), alpha: Data([255]), name: "Pixel")
        pixel.shape?.filtering = .classic
        let halo = try make(pixel); try halo.append(CGPoint(x: 256, y: 64)); try halo.flush()
        #expect(alpha(try raster(halo), 285, 64) > 10, "Rotated filter support must not be clipped to the unfiltered square")
        var options = imageOptions(); options.angle = 0.31; options.roundness = 0.63; options.flow = 0.3
        options.shape?.flipX = true; options.shape?.filtering = .classic
        let stroke = try make(options)
        try stroke.append(CGPoint(x: 256, y: 64)); try stroke.flush()
        let actual = try raster(stroke)
        var density = [Float](repeating: 0, count: 512 * 128), gray = [UInt8](repeating: 0, count: 512 * 128)
        let tip = asymmetricBrushShapeTip()
        let co = cos(options.angle), si = sin(options.angle), major: CGFloat = -16, minor = 16 * options.roundness
        tip.luminance.withUnsafeBytes { mask in
            density.withUnsafeMutableBufferPointer { values in
                brush_round_stamp(values.baseAddress, nil, 512, 0, 0, 512, 128,
                    Float((co * -255.5 + si * -63.5) / major), Float((-si * -255.5 + co * -63.5) / minor),
                    Float(co / major), Float(si / major), Float(-si / minor), Float(co / minor),
                    1, 0.3, 1, mask.bindMemory(to: UInt8.self).baseAddress, tip.side, 1)
            }
        }
        gray.withUnsafeMutableBufferPointer { bytes in
            density.withUnsafeBufferPointer { values in brush_density_bytes(bytes.baseAddress, 512, values.baseAddress, nil, 512, 128) }
        }
        var delta = 0
        for y in 0..<128 { for x in 0..<512 { delta = max(delta, abs(alpha(actual, x, y) - Int(gray[y * 512 + x]))) } }
        #expect(delta <= 1, "Tile partition changed the image stamp by \(delta)")
    }

    @Test func foundationalRoundTipsHaveDistinctBoundedRadialProfiles() throws {
        let styles: [GeneratedBrushTip] = [.ultraSoftRound, .softRound, .mediumRound, .mediumHardRound, .hardRound]
        let tips = styles.map { $0.make() }
        #expect(Set(tips.map(\.luminance)).count == 5)
        let center = 64 * 128 + 64, half = 64 * 128 + 96
        #expect(tips[0].luminance[center] > 100 && tips[0].luminance[center] < 128)
        for tip in tips.dropFirst() { #expect(tip.luminance[center] == 255) }
        for pair in zip(tips, tips.dropFirst()) { #expect(pair.0.luminance[half] <= pair.1.luminance[half]) }
        #expect(tips[0].luminance[half] < tips[1].luminance[half] && tips[1].luminance[half] < tips[2].luminance[half])
        #expect(tips[4].luminance[64 * 128 + 120] == 0 && tips[1].luminance[64 * 128 + 120] > 0)
        for basic in BasicBrushShape.allCases { #expect(styles.contains(basic.generatedTip)) }
        for style in styles {
            var options = RoundBrushDynamics(); options.flow = 0.25; options.spacing = 0.3
            options.shape = ShapeBrushSettings(source: .generated, generator: style)
            for diameter: CGFloat in [16, 64, 128] { for pressure: CGFloat in [0.25, 0.5, 1] {
                let stroke = try make(options, diameter: diameter, pressure: true)
                try stroke.append(CGPoint(x: 256, y: 64), input: BrushInput(pressure: pressure)); try stroke.flush()
                let image = try raster(stroke)
                #expect(alpha(image, 256, 64) > 0 && alpha(image, 256, 64) <= Int(pressure * 255) + 1)
                #expect(alpha(image, 256 + Int(ceil(diameter * pressure / 2)) + 3, 64) == 0)
            } }
        }

    }

    @Test func generatedTipsAreIndependentDeterministicRecipes() throws {
        #expect(BrushHeadCatalog.names.count == 286)
        #expect(BrushHeadCatalog.names.contains("Acrylic-Dab-2.png") && BrushHeadCatalog.names.contains("Bacteria.png"))
        #expect(!BrushHeadCatalog.names.contains("Custom/Acrylic-Dab-2.png") && !BrushHeadCatalog.names.contains("acrylic-dab-2.png"))
        var outputs: [CGContext] = []
        let atlas = try BrushRaster.context(width: 512, height: GeneratedBrushTip.allCases.count * 128, mask: false)
        atlas.setFillColor(NSColor.white.cgColor); atlas.fill(CGRect(x: 0, y: 0, width: 512, height: GeneratedBrushTip.allCases.count * 128))
        for (i, style) in GeneratedBrushTip.allCases.enumerated() {
            let tip = style.make()
            #expect(tip.isValid && tip.side == 128 && tip.originalDigest == nil && tip == style.make())
            #expect(tip.luminance.contains { $0 > 0 } && tip.luminance.contains(0))
            var options = RoundBrushDynamics(); options.spacing = 0.3; options.flow = 0.4
            options.shape = ShapeBrushSettings(source: .generated, generator: style)
            var preset = BrushPreset(name: "Generated"); preset.roundDynamics = options
            let data = try JSONEncoder().encode(preset)
            #expect(data.count < 4096, "Generated presets must persist recipes, not image pixels")
            #expect(try JSONDecoder().decode(BrushPreset.self, from: data) == preset)
            #expect(preset.applying(to: BrushSettings()).shapeTip == nil && options.shapeSettings.customTip == nil)
            let stroke = try make(options), replay = try make(options, gpu: false)
            try trace(stroke, steps: 1); try trace(replay, steps: 64)
            let pixels = try raster(stroke)
            #expect(difference(pixels, try raster(replay)) <= 1 && !stroke.patches.isEmpty)
            outputs.append(pixels)
            let image = try #require(pixels.makeImage())
            let transform = LayerTransform(origin: CGPoint(x: 0, y: i * 128), size: size)
            LayerRenderer.draw(image, transform: transform, center: transform.center, in: atlas)
        }
        #expect(difference(outputs[0], outputs[1]) > 30 && difference(outputs[1], outputs[2]) > 30)
        Attachment.record(try #require(NSBitmapImageRep(cgImage: atlas.makeImage()!).representation(using: .png, properties: [:])), named: "independent-generated-tips.png")
    }

    @Test func shapeFourKImageTimingAndTileBudget() throws {
        var report = "4K Debug image-tip timing in Xcode, 2400 px path, 12 updates, 25% spacing, seeded 2-count rotated asymmetric image.\n"
        for diameter: CGFloat in [40, 800] {
            for filtering in ShapeBrushSettings.Filtering.allCases {
                var settings = BrushSettings(diameter: diameter, red: 1)
                settings.roundDynamics = imageOptions()
                settings.roundDynamics.spacing = 0.25
                settings.roundDynamics.count = 2; settings.roundDynamics.scatter = 0.5
                settings.roundDynamics.shape?.filtering = filtering
                settings.roundDynamics.shape?.rotationResponse = 1
                let stroke = try BrushStroke(layer: ImageLayer(name: "4K image", blankSize: CGSize(width: 4000, height: 4000)),
                    mask: false, settings: settings, canvas: CGSize(width: 4000, height: 4000), seed: 42)
                var updates: [Double] = []
                for i in 0...12 {
                    let start = CFAbsoluteTimeGetCurrent()
                    try stroke.append(CGPoint(x: 700 + i * 200, y: 2000), input: BrushInput(timestamp: Double(i) / 12))
                    updates.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                }
                let end = CFAbsoluteTimeGetCurrent(); try stroke.flush()
                let flush = (CFAbsoluteTimeGetCurrent() - end) * 1000
                updates.sort()
                let tiles = stroke.patches.count
                #expect(tiles > 0 && tiles < 120)
                let result = try stroke.paintSnapshot()
                #expect(result.asset.raster?.hasMaterializedPixels == false)
                report += "diameter=\(diameter) filtering=\(filtering.rawValue) median=\(updates[updates.count / 2])ms max=\(updates.last!)ms flush=\(flush)ms tiles=\(tiles) coreTileBytesEstimate=\(tiles * 256 * 256 * 9)\n"
            }
        }
        print(report)
        Attachment.record(Data(report.utf8), named: "shape-4k-image-timing.txt")
    }

}


nonisolated func asymmetricBrushShapeTip() -> BrushShapeTip {
    let side = 16
    var data = Data(repeating: 0, count: side * side)
    for y in 0..<side { for x in 0..<side where (x < 4 && y < 15) || (y < 4 && x < 11) { data[y * side + x] = 255 } }
    return BrushShapeTip(side: side, luminance: data, alpha: data, name: "Asymmetric L")
}
