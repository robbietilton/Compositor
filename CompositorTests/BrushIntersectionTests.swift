import AppKit
import Testing
@testable import Compositor

@MainActor
struct BrushIntersectionTests {
    private func stroke(diameter: CGFloat = 120, opacity: CGFloat = 1, useGPU: Bool = true,
                        settings override: BrushSettings? = nil, seed: UInt64 = 0) throws -> BrushStroke {
        let session = EditorSession()
        session.createDocument(width: 800, height: 800)
        session.addBlankLayer()
        return try BrushStroke(layer: #require(session.activeLayer), mask: false,
            settings: override ?? BrushSettings(diameter: diameter, hardness: 0, red: 1, green: 1, blue: 1, opacity: opacity),
            canvas: CGSize(width: 800, height: 800), useGPU: useGPU, seed: seed)
    }
    private func trace(_ stroke: BrushStroke, _ points: [CGPoint], step: CGFloat = 12,
                       pressure: ((CGPoint) -> CGFloat)? = nil) throws {
        func append(_ point: CGPoint) throws {
            try stroke.append(point, input: BrushInput(pressure: pressure?(point) ?? 1))
        }
        try append(points[0])
        for (a, b) in zip(points, points.dropFirst()) {
            let count = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / step)))
            for index in 1...count {
                let t = CGFloat(index) / CGFloat(count)
                try append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        try stroke.flush()
    }
    private func raster(_ stroke: BrushStroke) throws -> CGContext {
        let context = try BrushRaster.context(width: 800, height: 800, mask: false)
        LayerRenderer.drawBrushPreview(nil, transform: stroke.paintTransform, center: stroke.paintTransform.center,
            scale: 1, opacity: 1, blendMode: .normal, mask: nil, patches: stroke.patches,
            pixelWidth: stroke.width, pixelHeight: stroke.height, paintingMask: false, in: context)
        return context
    }
    private func alpha(_ context: CGContext, _ x: Int, _ y: Int) -> Int {
        Int(context.data!.assumingMemoryBound(to: UInt8.self)[y * context.bytesPerRow + x * 4 + 3])
    }
    private func maximumPatchDifference(_ lhs: BrushStroke, _ rhs: BrushStroke) throws -> Int {
        let order: (BrushPatch, BrushPatch) -> Bool = {
            $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY
        }
        let left = lhs.patches.sorted(by: order), right = rhs.patches.sorted(by: order)
        guard left.map(\.rect) == right.map(\.rect) else { return Int.max }
        var maximum = 0
        for (a, b) in zip(left, right) {
            let ac = try BrushRaster.copy(a.image), bc = try BrushRaster.copy(b.image)
            guard ac.width == bc.width, ac.height == bc.height, ac.bytesPerRow == bc.bytesPerRow else { return Int.max }
            let bytes = ac.bytesPerRow * ac.height
            let ap = ac.data!.assumingMemoryBound(to: UInt8.self), bp = bc.data!.assumingMemoryBound(to: UInt8.self)
            for index in 0..<bytes { maximum = max(maximum, abs(Int(ap[index]) - Int(bp[index]))) }
        }
        return maximum
    }

    @Test func CPUFallbackRendersWithoutContinuousGPU() throws {
        let fallback = try stroke(diameter: 40, useGPU: false)
        #expect(!fallback.usesContinuousGPU)
        try trace(fallback, [CGPoint(x: 100, y: 400), CGPoint(x: 700, y: 400)])
        let output = try raster(fallback)
        #expect(alpha(output, 400, 400) == 255)
        #expect(alpha(output, 400, 350) == 0)
    }

    @Test func legacyDefaultStrokeDoesNotOptIntoMetalStamps() throws {
        let legacyGPURequested = try stroke(useGPU: true, settings: BrushSettings())
        #expect(!legacyGPURequested.usesMetalStampRenderer)
    }

    @Test func discreteMetalStampsMatchCPUForGeneratedAndCustomMasks() throws {
        let custom = BrushShapeTip(side: 32,
            luminance: Data((0..<32 * 32).map { index in
                let x = index % 32, y = index / 32
                return UInt8((x > 4 && x < 28 && y > 7 && y < 25 && (x + y) % 4 != 0) ? 220 : 0)
            }), alpha: Data(repeating: 255, count: 32 * 32), name: "test custom")
        for source in [ShapeBrushSettings(source: .procedural, filtering: .improved),
                       ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved),
                       ShapeBrushSettings(source: .custom, customTip: custom, mask: .luminance, filtering: .classic),
                       ShapeBrushSettings(source: .embedded, mask: .luminance, filtering: .classic),
                       ShapeBrushSettings(source: .embedded, mask: .luminance, filtering: .none)] {
            var settings = BrushSettings(diameter: 96, hardness: 1, red: 1, green: 0.2, blue: 0.05, opacity: 0.55)
            if source.source == .procedural { settings.hardness = 0.65 }
            if source.source == .embedded { settings.shapeTip = custom }
            settings.roundDynamics.shape = source
            settings.roundDynamics.spacing = 0.35
            settings.roundDynamics.count = 3
            settings.roundDynamics.scatter = 0.2
            settings.roundDynamics.angle = 0.17
            settings.roundDynamics.roundness = 0.72
            var shape = settings.roundDynamics.shapeSettings
            shape.flipX = true
            shape.horizontalJitter = 0.18
            shape.verticalJitter = 0.12
            settings.roundDynamics.shape = shape
            var path = settings.roundDynamics.path
            path.falloff = 0.3
            settings.roundDynamics.strokePath = path
            settings.roundDynamics.flow = 0.44
            settings.pressureOpacity = true
            settings.roundDynamics.taperEnd = 0.2
            for seed: UInt64 in [0, 0xB71571E5] {
                let cpu = try stroke(useGPU: false, settings: settings, seed: seed)
                let metal = try stroke(useGPU: true, settings: settings, seed: seed)
                let pressure: (CGPoint) -> CGFloat = { 0.35 + 0.65 * $0.x / 800 }
                try trace(cpu, [CGPoint(x: 80, y: 400), CGPoint(x: 720, y: 400)], step: 17, pressure: pressure)
                try trace(metal, [CGPoint(x: 80, y: 400), CGPoint(x: 720, y: 400)], step: 17, pressure: pressure)
                let cpuImage = try raster(cpu), metalImage = try raster(metal)
                let bytes = cpuImage.bytesPerRow * cpuImage.height
                let cpuPixels = cpuImage.data!.assumingMemoryBound(to: UInt8.self)
                let metalPixels = metalImage.data!.assumingMemoryBound(to: UInt8.self)
                let maximumChannelDifference = (0..<bytes).map { abs(Int(cpuPixels[$0]) - Int(metalPixels[$0])) }.max() ?? 0
                #expect(maximumChannelDifference <= 1, "\(source.source) maximum channel difference: \(maximumChannelDifference)")
                #expect(metal.usesMetalStampRenderer == (source.filtering != .none))
            }
        }
    }

    @Test func discreteMetalStampsMatchCPUForSparseAndDenseInput() throws {
        var settings = BrushSettings(diameter: 64, hardness: 1, red: 0.2, green: 0.8, blue: 0.35, opacity: 0.72)
        settings.roundDynamics.spacing = 0.18
        settings.roundDynamics.flow = 0.61
        settings.roundDynamics.count = 3
        settings.roundDynamics.scatter = 0.16
        settings.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
        let points = [CGPoint(x: 70, y: 397), CGPoint(x: 730, y: 403)]
        for step: CGFloat in [1000, 7] {
            let cpu = try stroke(useGPU: false, settings: settings, seed: 0x51A2)
            let metal = try stroke(useGPU: true, settings: settings, seed: 0x51A2)
            try trace(cpu, points, step: step)
            try trace(metal, points, step: step)
            #expect(metal.usesMetalStampRenderer)
            #expect(try maximumPatchDifference(cpu, metal) <= 1, "step \(step) CPU/Metal tile mismatch")
        }
    }

    @Test func discreteMetalStampRespectsTransformedSelectionMaskHistoryAndReopen() async throws {
        let session = EditorSession()
        session.createDocument(width: 800, height: 800)
        let background = try BrushRaster.context(width: 800, height: 800, mask: false)
        background.setFillColor(NSColor.white.cgColor)
        background.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
        let image = try #require(background.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Mask parity target"))
        let layerID = try #require(session.activeLayerID)
        let layerIndex = try #require(session.document?.layers.firstIndex { $0.id == layerID })
        session.document?.layers[layerIndex].transform = LayerTransform(origin: CGPoint(x: 64, y: 88),
            size: CGSize(width: 640, height: 590), rotation: 13, flipX: true)
        session.addLayerMask()
        session.maskPaintWhite = false
        session.setSelection(DocumentSelection(path: CGPath(ellipseIn: CGRect(x: 245, y: 190, width: 315, height: 420), transform: nil)),
            name: "Transformed selection parity")
        let layer = try #require(session.activeLayer)
        var settings = BrushSettings(diameter: 88, hardness: 1, red: 0, green: 0, blue: 0, opacity: 0.7)
        settings.roundDynamics.spacing = 0.6
        settings.roundDynamics.flow = 0.5
        settings.roundDynamics.count = 2
        settings.roundDynamics.scatter = 0.18
        settings.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
        func makeStroke(useGPU: Bool) throws -> BrushStroke {
            let stroke = try BrushStroke(layer: layer, mask: true, settings: settings,
                canvas: CGSize(width: 800, height: 800), useGPU: useGPU, seed: 0x6A77)
            stroke.selectionClip = try session.selection?.clip(canvas: CGSize(width: 800, height: 800))
            return stroke
        }
        let cpu = try makeStroke(useGPU: false), metal = try makeStroke(useGPU: true)
        #expect(metal.usesMetalStampRenderer)
        let points = [CGPoint(x: 100, y: 400), CGPoint(x: 700, y: 400)]
        try trace(cpu, points, step: 19)
        try trace(metal, points, step: 19)
        #expect(try maximumPatchDifference(cpu, metal) <= 1, "transformed mask tiles differ")

        func exportBytes() async throws -> Data {
            let snapshot = try #require(session.projectSnapshot())
            let rendered = try await ImageExporter.shared.render(snapshot).image
            let context = try BrushRaster.copy(rendered)
            return Data(bytes: context.data!, count: context.bytesPerRow * context.height)
        }
        let before = try await exportBytes()
        try session.commitPaintSnapshot(metal)
        let painted = try await exportBytes()
        #expect(before != painted)
        session.undo()
        #expect(try await exportBytes() == before)
        session.redo()
        #expect(try await exportBytes() == painted)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = try await ImageExporter.shared.render(try await ProjectStore.shared.load(from: url)).image
        let reopenedContext = try BrushRaster.copy(reopened)
        let reopenedBytes = Data(bytes: reopenedContext.data!, count: reopenedContext.bytesPerRow * reopenedContext.height)
        #expect(reopenedBytes == painted)
    }

    @Test func selfCrossingsBlendInsteadOfTakingTheStrongestEdge() throws {
        for useGPU in [true, false] {
            let vertical = try stroke(useGPU: useGPU), horizontal = try stroke(useGPU: useGPU), crossing = try stroke(useGPU: useGPU)
            try trace(vertical, [CGPoint(x: 400, y: 100), CGPoint(x: 400, y: 700)])
            try trace(horizontal, [CGPoint(x: 700, y: 400), CGPoint(x: 100, y: 400)])
            try trace(crossing, [CGPoint(x: 400, y: 100), CGPoint(x: 400, y: 700), CGPoint(x: 700, y: 700),
                                 CGPoint(x: 700, y: 400), CGPoint(x: 100, y: 400)])
            let v = try raster(vertical), h = try raster(horizontal), c = try raster(crossing)
            for offset in [45, 48, 51] {
                let a = alpha(v, 400 + offset, 400 + offset), b = alpha(h, 400 + offset, 400 + offset)
                let actual = alpha(c, 400 + offset, 400 + offset)
                let expected = 255 - (255 - a) * (255 - b) / 255
                #expect(actual > max(a, b) + 10)
                #expect(abs(actual - expected) <= 3)
            }
        }
    }

    @Test func accumulationDependsOnDistanceNotEventCount() throws {
        for diameter: CGFloat in [12, 120, 520] {
            let sparse = try stroke(diameter: diameter), dense = try stroke(diameter: diameter)
            let points = [CGPoint(x: 60, y: 400), CGPoint(x: 740, y: 400)]
            try trace(sparse, points, step: 1000)
            try trace(dense, points, step: 5)
            let a = try raster(sparse), b = try raster(dense)
            for y in 400..<min(800, 400 + Int(diameter / 2)) {
                #expect(abs(alpha(a, 400, y) - alpha(b, 400, y)) <= 2,
                        "diameter \(diameter), row \(y)")
            }
        }
    }

    @Test func softCrossingsRespectStrokeOpacityAndFlushIsIdempotent() throws {
        let paint = try stroke(opacity: 0.4)
        let path = [CGPoint(x: 400, y: 100), CGPoint(x: 400, y: 700), CGPoint(x: 700, y: 700),
                    CGPoint(x: 700, y: 400), CGPoint(x: 100, y: 400)]
        try trace(paint, path)
        let first = try raster(paint)
        #expect(alpha(first, 400, 400) == 102)
        let bytes = first.data!.assumingMemoryBound(to: UInt8.self)
        #expect(stride(from: 3, to: first.bytesPerRow * first.height, by: 4).allSatisfy { bytes[$0] <= 102 })
        try paint.flush()
        let second = try raster(paint)
        #expect(memcmp(first.data!, second.data!, first.bytesPerRow * first.height) == 0)
    }

    @Test func exportCrossingExample() async throws {
        guard ProcessInfo.processInfo.environment["BRUSH_BENCHMARK"] == "1" else { return }
        let session = EditorSession()
        session.createDocument(width: 4000, height: 4000)
        let black = try BrushRaster.context(width: 4000, height: 4000, mask: false)
        black.setFillColor(gray: 0, alpha: 1)
        black.fill(CGRect(x: 0, y: 0, width: 4000, height: 4000))
        let image = try #require(black.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Crossing"))
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 520, hardness: 0, red: 1, green: 1, blue: 1)
        let path = [CGPoint(x: 1600, y: 700), CGPoint(x: 1750, y: 3300), CGPoint(x: 2900, y: 2400),
                    CGPoint(x: 3150, y: 1800), CGPoint(x: 1600, y: 1700), CGPoint(x: 450, y: 2000)]
        session.beginBrush(at: path[0])
        for (a, b) in zip(path, path.dropFirst()) {
            for i in 1...60 {
                let t = CGFloat(i) / 60
                session.continueBrush(at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        #expect(session.finishBrushImmediately())
        try await ImageExporter.shared.exportPNG(try #require(session.projectSnapshot()),
            to: URL(fileURLWithPath: "/tmp/compositor-brush-crossing.png"))
    }
}
