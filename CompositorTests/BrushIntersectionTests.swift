import AppKit
import Testing
@testable import Compositor

@MainActor
struct BrushIntersectionTests {
    private func stroke(diameter: CGFloat = 120, opacity: CGFloat = 1, useGPU: Bool = true) throws -> BrushStroke {
        let session = EditorSession()
        session.createDocument(width: 800, height: 800)
        session.addBlankLayer()
        return try BrushStroke(layer: #require(session.activeLayer), mask: false,
            settings: BrushSettings(diameter: diameter, hardness: 0, red: 1, green: 1, blue: 1, opacity: opacity, usesAirbrushFalloff: true),
            canvas: CGSize(width: 800, height: 800), useGPU: useGPU)
    }
    private func trace(_ stroke: BrushStroke, _ points: [CGPoint], step: CGFloat = 12) throws {
        try stroke.append(points[0])
        for (a, b) in zip(points, points.dropFirst()) {
            let count = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / step)))
            for index in 1...count {
                let t = CGFloat(index) / CGFloat(count)
                try stroke.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
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
