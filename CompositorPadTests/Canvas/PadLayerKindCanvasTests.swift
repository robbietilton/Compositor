import CoreGraphics
import CoreImage
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// Four solid frames, red, blue, green and yellow, 32 × 24, each with its own delay, as the Mac's GIF tests make them.
enum PadGIFFixture {
    static func url() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gif")
        let colors: [CGColor] = [.init(srgbRed: 1, green: 0, blue: 0, alpha: 1), .init(srgbRed: 0, green: 0, blue: 1, alpha: 1),
                                 .init(srgbRed: 0, green: 1, blue: 0, alpha: 1), .init(srgbRed: 1, green: 1, blue: 0, alpha: 1)]
        let delays: [TimeInterval] = [0.04, 0.16, 0.08, 0.24]
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, colors.count, nil))
        for (index, color) in colors.enumerated() {
            let context = try BrushRaster.context(width: 32, height: 24, mask: false)
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[index]]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

/// The layer kinds the Mac added after 1.5.3, on the iPad canvas: an animated GIF layer, and the filters that are
/// adjustment layers too.
@MainActor struct PadLayerKindCanvasTests {
    /// The iPad canvas's frame, `size` pixels, as RGBA bytes, top row first.
    private func frameBytes(_ session: EditorSession, size: CGSize) throws -> [UInt8] {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let frame = try #require(PadCanvasCompositor(session: session).frame(session.document!, renderer: renderer, size: size))
        let width = Int(size.width), height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let buffer = try #require(renderer.queue.makeCommandBuffer())
        renderer.context.render(frame, to: texture, commandBuffer: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: renderer.space)
        buffer.commit(); buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    /// An editor seen one to one on a document of `width` × `height`.
    private func session(width: Int, height: Int) -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: width, height: height), backingScale: 1, documentSize: nil)
        session.createDocument(width: width, height: height)
        session.zoom(to: 1)
        return session
    }

    /// A GIF layer shows the frame its timeline is on, and that frame's own pixels once it's edited, as the Mac's canvas
    /// does: not the first frame, which is what the layer's asset holds.
    @Test func aGIFLayerShowsTheFrameItsTimelineIsOn() async throws {
        let gif = try PadGIFFixture.url()
        defer { try? FileManager.default.removeItem(at: gif) }
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 32, height: 24), backingScale: 1, documentSize: nil)
        await session.importImages([gif])
        session.zoom(to: 1)
        let layer = try #require(session.activeLayer)
        try #require(layer.gifAnimation != nil)
        #expect(layer.depthLabel == "GIF")
        func middle() throws -> [Int] {
            let bytes = try frameBytes(session, size: CGSize(width: 32, height: 24))
            return (0..<3).map { Int(bytes[(12 * 32 + 16) * 4 + $0]) }
        }
        let red = try middle()
        #expect(red[0] > 200 && red[1] < 60 && red[2] < 60, "the first frame: \(red)")
        await session.selectGIFTimelineFrame(1)
        let blue = try middle()
        #expect(blue[2] > 200 && blue[0] < 60 && blue[1] < 80, "the second frame: \(blue)")
        await session.invertPixels()
        #expect(session.activeLayer?.gifAnimation?.framePixels.keys.sorted() == [1])
        let inverted = try middle()
        #expect(inverted[0] > 200 && inverted[1] > 170 && inverted[2] < 60, "the second frame inverted: \(inverted)")
    }

    /// An RGB Split layer with nothing under it splits nothing, and the layers over it still show, where its kernel,
    /// given nothing, made the whole canvas go blank.
    @Test func anRGBSplitLayerOverNothingLeavesTheRestShowing() throws {
        let session = session(width: 40, height: 30)
        session.addAdjustment(.rgbSplit)
        session.adjustmentEditingID = nil
        let context = try BrushRaster.context(width: 20, height: 10, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Green"))
        let bytes = try frameBytes(session, size: CGSize(width: 40, height: 30))
        let middle = (0..<3).map { Int(bytes[(15 * 40 + 20) * 4 + $0]) }
        #expect(middle[1] > 230 && middle[0] < 25 && middle[2] < 25, "the layer over it: \(middle)")
    }

    /// RGB Split's center, while its panel is open on Radial, is marked over the canvas with a ringed crosshair, as on
    /// the Mac: both draw the overlay the same way.
    @Test func rgbSplitsCenterIsMarkedOverTheCanvas() throws {
        let session = session(width: 100, height: 80)
        let context = try BrushRaster.context(width: 100, height: 80, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Green"))
        session.beginFilter(.rgbSplit)
        defer { session.cancelFilter() }
        var settings = try #require(session.filterEdit?.settings)
        settings.rgbSplitRadial = true
        settings.rgbSplitCenter = CGPoint(x: 30, y: 40)
        session.updateFilter(settings, preview: false)
        let overlay = CanvasOverlay(session: session)
        let center = try #require(overlay.rgbSplitCenter)
        #expect(abs(center.x - 30) < 0.5 && abs(center.y - 40) < 0.5, "\(center)")
        var pixels = [UInt8](repeating: 0, count: 100 * 80 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let drawing = CGContext(data: buffer.baseAddress, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 400,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Drawn y down, as the canvases draw it.
            drawing.translateBy(x: 0, y: 80)
            drawing.scaleBy(x: 1, y: -1)
            overlay.draw(in: drawing, bounds: CGRect(x: 0, y: 0, width: 100, height: 80), deviceScale: 1)
        }
        func alpha(_ x: Int, _ y: Int) -> Int { Int(pixels[(y * 100 + x) * 4 + 3]) }
        // The crosshair's arm to the right of the center, and nothing at the center itself.
        #expect(alpha(38, 40) > 150, "the arm: \(alpha(38, 40))")
        #expect(alpha(30, 40) == 0, "the middle: \(alpha(30, 40))")
    }

    /// Each filter that's an adjustment layer too shows on the iPad canvas as it exports, over a picture that covers
    /// only part of the canvas: Vignette frames the canvas and Lens Effects measures itself by it, as on the Mac, not by
    /// the layers drawn. The ones worked out in floats on the GPU and in 8 bits for the export come within a few
    /// levels; Lens Effects, which the Mac shows exactly once the canvas settles, the iPad shows from its quick working,
    /// close to it.
    @Test(arguments: [AdjustmentKind.vignette, .tonalContrast, .sharpen, .bloomGlow, .progressiveBlur, .rgbSplit, .lensEffects])
    func aFilterLayerShowsAsItExports(kind: AdjustmentKind) throws {
        let session = session(width: 120, height: 80)
        // A picture on the left two thirds: a ramp, with a few bright spots for the lens to catch.
        let context = try BrushRaster.context(width: 80, height: 80, mask: false)
        for x in 0..<80 {
            context.setFillColor(CGColor(srgbRed: CGFloat(x) / 100, green: 0.35, blue: 1 - CGFloat(x) / 100, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 80))
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        for spot in [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 50)] { context.fill(CGRect(x: spot.x, y: spot.y, width: 3, height: 3)) }
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Picture"), centeredAt: CGPoint(x: 40, y: 40))
        session.addAdjustment(kind)
        session.adjustmentEditingID = nil
        var adjustment = try #require(session.activeLayer?.adjustment)
        switch kind {
        case .vignette:
            adjustment.filterLayer.vignette = VignetteLayerSettings()
            adjustment.filterLayer.vignette?.amount = 80
        case .tonalContrast:
            adjustment.filterLayer.tonal = TonalLayerSettings()
            adjustment.filterLayer.tonal?.amount = 100
            adjustment.filterLayer.tonal?.radius = 6
        case .sharpen:
            adjustment.filterLayer.sharpen = SharpenLayerSettings()
            adjustment.filterLayer.sharpen?.amount = 200
            adjustment.filterLayer.sharpen?.radius = 2
        case .lensEffects:
            adjustment.filterLayer.lens = LensEffectSettings()
            adjustment.filterLayer.lens?.effect = .prism
            adjustment.filterLayer.lens?.prismFringe = 70
        default:
            break
        }
        session.updateAdjustment(try #require(session.activeLayerID), value: adjustment)

        let gpu = try frameBytes(session, size: CGSize(width: 120, height: 80))
        let reference = try BrushRaster.context(width: 120, height: 80, mask: false)
        session.drawLiveComposite(try #require(session.document), in: reference)
        let cpu = try #require(reference.data).assumingMemoryBound(to: UInt8.self)
        var total = 0.0, over = 0, count = 0
        // Over the picture, inside its edge. Progressive Blur's export carries the edge pixels on past the canvas's
        // sides, where the canvas, the Mac's as the iPad's, blurs in what's beyond; they're compared away from them by
        // the blur's reach, under the line's sharp end and its blurred one alike.
        let (columns, rows) = kind == .progressiveBlur ? (25..<56, 2..<58) : (2..<78, 2..<78)
        for y in rows { for x in columns {
            let pixel = y * 120 + x
            var largest = 0
            for channel in 0..<3 {
                let difference = abs(Int(cpu[pixel * 4 + channel]) - Int(gpu[pixel * 4 + channel]))
                largest = max(largest, difference)
                total += Double(difference)
            }
            if largest > 12 { over += 1 }
            count += 1
        } }
        let mean = total / Double(count * 3), share = Double(over) / Double(count)
        // RGB Split's dispersion is its own Metal kernel on the canvas, and Lens Effects is the quick working there.
        let (meanLimit, shareLimit) = kind == .lensEffects ? (4.0, 0.1) : kind == .rgbSplit ? (1.5, 0.02) : (1.5, 0.01)
        #expect(mean < meanLimit && share < shareLimit, "\(kind): mean \(mean), over 12 levels \(share * 100)%")
    }
}
