import AppKit
import Testing
@testable import Compositor

/// Pixel mode: every pixel is either fully painted in the exact color or left alone, on the GPU and off it.
@MainActor
struct PixelBrushTests {
    private let size = CGSize(width: 200, height: 100)
    private func settings(diameter: CGFloat, erasing: Bool = false) -> BrushSettings {
        var settings = BrushSettings(diameter: diameter, hardness: 1, red: 0.2, green: 0.6, blue: 0.4)
        settings.pixelPerfect = true
        settings.erasing = erasing
        return settings
    }
    private func trace(_ stroke: BrushStroke, from a: CGPoint, to b: CGPoint) throws {
        try stroke.append(a)
        for index in 1...7 {
            let t = CGFloat(index) / 7
            try stroke.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        try stroke.flush()
    }
    private func raster(_ stroke: BrushStroke) throws -> CGContext {
        let context = try BrushRaster.context(width: Int(size.width), height: Int(size.height), mask: false)
        LayerRenderer.drawBrushPreview(stroke.layer.asset?.image, transform: stroke.paintTransform, center: stroke.paintTransform.center,
            scale: 1, opacity: 1, blendMode: .normal, mask: nil, patches: stroke.patches,
            pixelWidth: stroke.width, pixelHeight: stroke.height, paintingMask: false, sourceRect: stroke.sourceRect, in: context)
        return context
    }
    private func pixel(_ context: CGContext, _ x: Int, _ y: Int) -> [Int] {
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Int(bytes[y * context.bytesPerRow + x * 4 + $0]) }
    }

    @Test(arguments: [true, false])
    func paintsOnlyWholePixelsInTheExactColor(useGPU: Bool) throws {
        for diameter: CGFloat in [1, 3, 20] {
            let session = EditorSession()
            session.createDocument(width: Int(size.width), height: Int(size.height))
            session.addBlankLayer()
            let stroke = try BrushStroke(layer: #require(session.activeLayer), mask: false, settings: settings(diameter: diameter),
                                         canvas: size, useGPU: useGPU)
            try trace(stroke, from: CGPoint(x: 20.3, y: 30.7), to: CGPoint(x: 170.8, y: 62.2))
            let context = try raster(stroke)
            var painted = 0
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    let value = pixel(context, x, y)
                    #expect(value[3] == 0 || value == [51, 153, 102, 255], "diameter \(diameter) at \(x),\(y): \(value)")
                    if value[3] == 255 { painted += 1 }
                }
            }
            #expect(painted > 0)
        }
    }

    /// A click fills the square of pixels nearest the pointer, Size pixels across.
    @Test(arguments: [true, false])
    func clickFillsTheSquareUnderThePointer(useGPU: Bool) throws {
        let session = EditorSession()
        session.createDocument(width: Int(size.width), height: Int(size.height))
        session.addBlankLayer()
        let stroke = try BrushStroke(layer: #require(session.activeLayer), mask: false, settings: settings(diameter: 4),
                                     canvas: size, useGPU: useGPU)
        try stroke.append(CGPoint(x: 40.3, y: 40.8))
        try stroke.flush()
        let context = try raster(stroke)
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let inside = (38...41).contains(x) && (39...42).contains(y)
                #expect(pixel(context, x, y) == (inside ? [51, 153, 102, 255] : [0, 0, 0, 0]), "at \(x),\(y)")
            }
        }
    }

    /// The cursor's square is the one a click fills, in the layer's own pixels when it's scaled.
    @Test func squareFollowsTheLayersPixelGrid() {
        #expect(BrushStroke.pixelSquare(at: CGPoint(x: 40.3, y: 40.8), diameter: 4, pixelToDocument: .identity)
                == CGRect(x: 38, y: 39, width: 4, height: 4))
        #expect(BrushStroke.pixelSquare(at: CGPoint(x: 40.3, y: 40.8), diameter: 1, pixelToDocument: .identity)
                == CGRect(x: 40, y: 40, width: 1, height: 1))
        // Layer pixels two document pixels wide: Size 4 is two of them, and Size 1 still one.
        let doubled = CGAffineTransform(scaleX: 2, y: 2)
        #expect(BrushStroke.pixelSquare(at: CGPoint(x: 40.3, y: 40.8), diameter: 4, pixelToDocument: doubled)
                == CGRect(x: 19, y: 19, width: 2, height: 2))
        #expect(BrushStroke.pixelSquare(at: CGPoint(x: 40.3, y: 40.8), diameter: 1, pixelToDocument: doubled)
                == CGRect(x: 20, y: 20, width: 1, height: 1))
    }

    /// A one-pixel pencil draws an unbroken line: every column it crosses has a painted pixel.
    @Test(arguments: [true, false])
    func onePixelLineHasNoGaps(useGPU: Bool) throws {
        let session = EditorSession()
        session.createDocument(width: Int(size.width), height: Int(size.height))
        session.addBlankLayer()
        let stroke = try BrushStroke(layer: #require(session.activeLayer), mask: false, settings: settings(diameter: 1),
                                     canvas: size, useGPU: useGPU)
        try trace(stroke, from: CGPoint(x: 20.3, y: 30.7), to: CGPoint(x: 170.8, y: 62.2))
        let context = try raster(stroke)
        for x in 21...170 {
            #expect((0..<Int(size.height)).contains { pixel(context, x, $0)[3] == 255 }, "gap at column \(x)")
        }
    }

    /// Only the Brush has a pixel mode; the tools that share its tip paint as they always have.
    @Test func onlyTheBrushToolPaintsInPixelMode() async throws {
        let session = EditorSession()
        session.createDocument(width: Int(size.width), height: Int(size.height))
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings = settings(diameter: 5)
        session.beginBrush(at: CGPoint(x: 40, y: 40))
        #expect(session.brushStroke?.settings.pixelPerfect == true)
        await session.finishBrush()
        session.selectTool(.spotHealing)
        session.brushSettings.pixelPerfect = true
        session.beginBrush(at: CGPoint(x: 40, y: 40))
        #expect(session.brushStroke?.settings.pixelPerfect == false)
        session.cancelBrush()
    }

    @Test(arguments: [true, false])
    func erasingClearsWholePixels(useGPU: Bool) throws {
        let session = EditorSession()
        session.createDocument(width: Int(size.width), height: Int(size.height))
        let fill = try BrushRaster.context(width: Int(size.width), height: Int(size.height), mask: false)
        fill.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        fill.fill(CGRect(origin: .zero, size: size))
        let photo = try #require(fill.makeImage())
        session.insert(ImportedImage(image: photo, thumbnail: photo, name: "Photo"))
        let stroke = try BrushStroke(layer: #require(session.activeLayer), mask: false, settings: settings(diameter: 3, erasing: true),
                                     canvas: size, useGPU: useGPU)
        try trace(stroke, from: CGPoint(x: 20.3, y: 30.7), to: CGPoint(x: 170.8, y: 62.2))
        let context = try raster(stroke)
        var erased = 0
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let value = pixel(context, x, y)
                #expect(value == [0, 0, 0, 0] || value == [255, 0, 0, 255], "at \(x),\(y): \(value)")
                if value[3] == 0 { erased += 1 }
            }
        }
        #expect(erased > 0)
    }
}
