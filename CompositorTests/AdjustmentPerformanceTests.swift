import AppKit
import CoreImage
import Testing
@testable import Compositor

/// How long the canvas takes to draw a frame with adjustment layers over a large picture. Run on its own, in a
/// Release build: `TEST_RUNNER_ADJUSTMENT_BENCHMARK=1`, the timings attached to the result.
@MainActor
struct AdjustmentPerformanceTests {
    /// A 4000 × 2600 picture with detail, color and a few bright lights.
    private func picture() throws -> CGImage {
        let width = 4000, height = 2600
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = [CGColor(srgbRed: 0.05, green: 0.08, blue: 0.16, alpha: 1), CGColor(srgbRed: 0.7, green: 0.45, blue: 0.3, alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        var seed: UInt64 = 1
        func random() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 11) / CGFloat(1 << 53) }
        for _ in 0..<600 {
            context.setFillColor(CGColor(srgbRed: random(), green: random(), blue: random(), alpha: 0.6))
            context.fillEllipse(in: CGRect(x: random() * CGFloat(width), y: random() * CGFloat(height), width: 20 + random() * 200, height: 20 + random() * 200))
        }
        for _ in 0..<12 {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fillEllipse(in: CGRect(x: random() * CGFloat(width), y: random() * CGFloat(height), width: 30, height: 30))
        }
        return try #require(context.makeImage())
    }

    private func adjustment(_ kind: AdjustmentKind, lens: LensEffect? = nil) -> LayerAdjustment {
        var adjustment = LayerAdjustment(kind: kind)
        switch kind {
        case .gaussianBlur: adjustment.gaussianRadius = 20
        case .bloomGlow: adjustment.filterLayer.bloomAmount = 60
        case .rgbSplit: adjustment.filterLayer.rgbSplitDistance = 20; adjustment.filterLayer.rgbSplitBlur = 60
        case .vignette: adjustment.filterLayer.vignette = VignetteLayerSettings()
        case .tonalContrast: adjustment.filterLayer.tonal = TonalLayerSettings()
        case .lensEffects:
            var settings = LensEffectSettings()
            settings.effect = lens ?? .anamorphicFlare
            adjustment.filterLayer.lens = settings
        default:
            var curves = CurvesSettings()
            curves.channels[0] = [CurvePoint(x: 0, y: 20), CurvePoint(x: 128, y: 150), CurvePoint(x: 255, y: 240)]
            adjustment.curves = curves
        }
        return adjustment
    }

    /// Milliseconds a frame takes, after one to warm up, the median of `frames`.
    private func frameTime(_ adjustments: [LayerAdjustment], frames: Int = 8, caching: Bool = false) throws -> Double {
        let session = EditorSession()
        session.createDocument(width: 4000, height: 2600)
        let image = try picture()
        session.insert(ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Picture"))
        for adjustment in adjustments {
            session.addAdjustment(adjustment.kind)
            session.adjustmentEditingID = nil
            if let id = session.activeLayerID { session.updateAdjustment(id, value: adjustment) }
        }
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        defer { _ = window }
        session.viewport.resize(to: canvas.bounds.size, backingScale: 2, documentSize: session.document?.size)
        session.viewport.fit(documentSize: session.document!.size)
        canvas.synchronizeDisplay()
        canvas.cachesAdjustments = caching
        let renderer = try #require(GPUCanvasRenderer.shared)
        let size = CGSize(width: 3200, height: 2000)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 3200, height: 2000, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderWrite, .shaderRead]
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        var times: [Double] = []
        for frame in 0...frames {
            let start = CFAbsoluteTimeGetCurrent()
            let image = try #require(canvas.gpuFrame(size: size))
            let command = try #require(renderer.queue.makeCommandBuffer())
            renderer.context.render(image, to: target, commandBuffer: command, bounds: CGRect(origin: .zero, size: size), colorSpace: renderer.space)
            command.commit()
            command.waitUntilCompleted()
            if frame > 0 { times.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
        }
        return times.sorted()[times.count / 2]
    }

    @Test func adjustmentLayerFrameTimes() throws {
        guard ProcessInfo.processInfo.environment["ADJUSTMENT_BENCHMARK"] == "1" else { return }
        var lines = [String(format: "No adjustments: %.1f ms", try frameTime([]))]
        let cases: [(String, [LayerAdjustment])] = [
            ("Curves", [adjustment(.curves)]),
            ("Gaussian Blur 20", [adjustment(.gaussianBlur)]),
            ("Bloom / Glow", [adjustment(.bloomGlow)]),
            ("RGB Split", [adjustment(.rgbSplit)]),
            ("Vignette", [adjustment(.vignette)]),
            ("Tonal Contrast", [adjustment(.tonalContrast)]),
            ("Lens: Anamorphic Flare", [adjustment(.lensEffects, lens: .anamorphicFlare)]),
            ("Lens: Starburst", [adjustment(.lensEffects, lens: .starburst)]),
            ("Lens: Mist", [adjustment(.lensEffects, lens: .mist)]),
            ("Lens: Prism", [adjustment(.lensEffects, lens: .prism)]),
            ("Lens: Bokeh", [adjustment(.lensEffects, lens: .bokeh)]),
            ("Stack: Curves, Tonal, Bloom, Vignette, Mist", [adjustment(.curves), adjustment(.tonalContrast), adjustment(.bloomGlow),
                                                             adjustment(.vignette), adjustment(.lensEffects, lens: .mist)]),
        ]
        for (name, adjustments) in cases {
            lines.append(String(format: "%@: %.1f ms worked out, %.1f ms kept", name, try frameTime(adjustments),
                                try frameTime(adjustments, caching: true)))
        }
        Attachment.record(lines.joined(separator: "\n"), named: "frame-times.txt")
    }
}
