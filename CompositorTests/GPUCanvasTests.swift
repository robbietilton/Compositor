import AppKit
import CoreImage
import Metal
import Testing
@testable import Compositor

/// The GPU canvas against the Core Graphics canvas, frame for frame.
@MainActor struct GPUCanvasTests {
    private func pattern(_ w: Int, _ h: Int, seed: Int, alpha: Bool = false) throws -> CGImage {
        let context = try BrushRaster.context(width: w, height: h, mask: false)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let a = alpha ? UInt8(min(255, (x + y) * 255 / max(1, w + h - 2) + 40)) : 255
            func c(_ v: Int) -> UInt8 { UInt8(Int(v & 255) * Int(a) / 255) }
            data[i] = c(x * 255 / w + seed * 40); data[i + 1] = c(y * 255 / h + seed * 25)
            data[i + 2] = c((x / 16 + y / 16) % 2 == 0 ? 200 : 60); data[i + 3] = a
        } }
        return context.makeImage()!
    }
    private func gradientMask(_ w: Int, _ h: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: w, height: h, mask: true)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w { data[y * context.bytesPerRow + x] = UInt8(x * 255 / max(1, w - 1)) } }
        return context.makeImage()!
    }

    /// A document using most of what the GPU canvas draws: masks, opacity, rotation, blend modes, a folder with a
    /// mask, a clipping stack, and Levels and Hue/Saturation layers.
    private func session(zoom: CGFloat) throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 500, height: 400), backingScale: 2, documentSize: nil)
        session.createDocument(width: 600, height: 500)
        func insert(_ image: CGImage, _ name: String) -> Int {
            session.insert(ImportedImage(image: image, thumbnail: image, name: name))
            return session.document!.layers.firstIndex { $0.id == session.activeLayerID }!
        }
        _ = insert(try pattern(600, 500, seed: 0), "Background")
        let multiply = insert(try pattern(300, 260, seed: 1), "Multiply")
        session.document!.layers[multiply].blendMode = .multiply
        session.document!.layers[multiply].transform.origin = CGPoint(x: 40, y: 30)
        let rotated = insert(try pattern(240, 200, seed: 2, alpha: true), "Rotated")
        session.document!.layers[rotated].transform.rotation = 20
        session.document!.layers[rotated].opacity = 0.7
        let masked = insert(try pattern(320, 240, seed: 3), "Masked")
        session.document!.layers[masked].transform.origin = CGPoint(x: 250, y: 220)
        session.document!.layers[masked].mask = LayerMask(asset: try LayerMask.asset(from: gradientMask(320, 240)))
        let base = insert(try pattern(200, 200, seed: 4, alpha: true), "Base")
        session.document!.layers[base].transform.origin = CGPoint(x: 350, y: 40)
        let clipped = insert(try pattern(260, 120, seed: 5), "Clipped")
        session.document!.layers[clipped].transform.origin = CGPoint(x: 330, y: 100)
        session.document!.layers[clipped].maskSourceID = session.document!.layers[base].id
        session.document!.layers[clipped].blendMode = .screen
        let dodge = insert(try pattern(200, 160, seed: 6, alpha: true), "Dodge")
        session.document!.layers[dodge].blendMode = .colorDodge
        session.document!.layers[dodge].transform.origin = CGPoint(x: 60, y: 300)
        // A folder holding the dodge layer, with a mask of its own.
        let size = CGSize(width: 600, height: 500)
        var folder = ImageLayer(name: "Folder", blankSize: size)
        folder.isGroup = true
        folder.mask = LayerMask(asset: try LayerMask.asset(from: gradientMask(600, 500)))
        session.document!.layers[dodge].parentID = folder.id
        session.document!.layers.insert(folder, at: dodge + 1)
        var levels = ImageLayer(name: "Levels", blankSize: size)
        levels.adjustment = LayerAdjustment(kind: .levels)
        levels.adjustment!.levels.ranges[0].gamma = 1.4
        levels.adjustment!.levels.ranges[0].black = 20
        session.document!.layers.append(levels)
        var hsv = ImageLayer(name: "Hue/Saturation", blankSize: size)
        hsv.adjustment = LayerAdjustment(kind: .hsv)
        hsv.adjustment!.hsvSettings = HueSaturationSettings(hue: 30, saturation: 40)
        hsv.opacity = 0.8
        hsv.mask = LayerMask(asset: try LayerMask.asset(from: gradientMask(600, 500)))
        session.document!.layers.append(hsv)
        session.selectLayer(nil)
        session.zoom(to: zoom)
        return session
    }

    private struct Difference { let mean: Double; let over: Double }

    /// Both canvases drawn for `session`; the share of pixels more than 12 levels apart, and the mean difference.
    private func compare(_ session: EditorSession, name: String, width points: Int = 500, height pointsHigh: Int = 400,
                         backingScale: Int = 2, inWindow: Bool = false) throws -> Difference {
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: points, height: pointsHigh)
        // Text being typed draws only with its editor, which lives in a window.
        var window: NSWindow?
        if inWindow {
            window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window?.contentView = canvas
            session.viewport.resize(to: canvas.bounds.size, backingScale: CGFloat(backingScale), documentSize: session.document?.size)
            canvas.synchronizeDisplay()
        }
        defer { _ = window }
        let width = points * backingScale, height = pointsHigh * backingScale
        let cpu = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        cpu.translateBy(x: 0, y: CGFloat(height)); cpu.scaleBy(x: CGFloat(backingScale), y: -CGFloat(backingScale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cpu, flipped: true)
        canvas.allowsGPU = false
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()

        let renderer = try #require(GPUCanvasRenderer.shared)
        let frame = try #require(canvas.gpuFrame(size: CGSize(width: width, height: height)))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let buffer = try #require(renderer.queue.makeCommandBuffer())
        renderer.context.render(frame, to: texture, commandBuffer: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                colorSpace: renderer.space)
        buffer.commit(); buffer.waitUntilCompleted()
        var gpu = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&gpu, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        let reference = cpu.data!.assumingMemoryBound(to: UInt8.self)
        var total = 0.0, over = 0
        for pixel in 0..<(width * height) {
            var largest = 0
            for channel in 0..<3 {
                let difference = abs(Int(reference[pixel * 4 + channel]) - Int(gpu[pixel * 4 + channel]))
                largest = max(largest, difference)
                total += Double(difference)
            }
            if largest > 12 { over += 1 }
        }
        // Side by side for looking at: Core Graphics on the left, the GPU on the right.
        let pair = try BrushRaster.context(width: width * 2, height: height, mask: false)
        let gpuData = Data(gpu)
        let gpuImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: gpuData as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        BrushRaster.draw(cpu.makeImage()!, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: pair)
        BrushRaster.draw(gpuImage, in: CGRect(x: width, y: 0, width: width, height: height), mask: false, context: pair)
        if let png = NSBitmapImageRep(cgImage: pair.makeImage()!).representation(using: .png, properties: [:]) {
            Attachment.record(png, named: "\(name).png")
        }
        return Difference(mean: total / Double(width * height * 3), over: Double(over) / Double(width * height))
    }

    @Test(arguments: [1.0, 2.0 / 3.0, 1.0 / 3.0, 2.0])
    func matchesCoreGraphicsCanvas(zoom: CGFloat) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let difference = try compare(try session(zoom: zoom), name: "zoom-\(Int(zoom * 100))")
        // Shrinking, the two sample a hard edge a little differently; the test pattern is all hard edges.
        #expect(difference.mean < 1.5 && difference.over < (zoom < 1 ? 0.03 : 0.01),
                "zoom \(zoom): mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// Selected pixels being dragged: the GPU draws them from the lifted pixels, the Core Graphics canvas from the
    /// rebuilt tiles.
    @Test(arguments: [false, true])
    func matchesWhileMovingPixels(duplicate: Bool) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 500, height: 400), backingScale: 2, documentSize: nil)
        session.createDocument(width: 600, height: 500)
        let image = try pattern(600, 500, seed: 2)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        session.applySelection(CGPath(ellipseIn: CGRect(x: 120, y: 100, width: 220, height: 160), transform: nil), mode: .replace, name: "Select")
        #expect(session.beginPixelMove(duplicate: duplicate))
        session.movePixels(by: CGSize(width: 90, height: 60))
        session.zoom(to: 1)
        let difference = try compare(session, name: duplicate ? "duplicating" : "moving")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// A photo on the canvas, with a mask on it when `masked`, ready to paint.
    private func paintable(masked: Bool = false) throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 500, height: 400), backingScale: 2, documentSize: nil)
        session.createDocument(width: 600, height: 500)
        let image = try pattern(420, 360, seed: 2)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        let index = session.document!.layers.firstIndex { $0.id == session.activeLayerID }!
        session.document!.layers[index].transform.origin = CGPoint(x: 90, y: 70)
        if masked { session.document!.layers[index].mask = LayerMask(asset: try LayerMask.asset(from: gradientMask(420, 360))) }
        session.brushSettings.diameter = 60
        session.foregroundColor = PaletteColor(red: 0.9, green: 0.2, blue: 0.1)
        return session
    }

    private func stroke(_ session: EditorSession) {
        session.beginBrush(at: CGPoint(x: 60, y: 100))
        for x in stride(from: 70.0, through: 540, by: 10) { session.continueBrush(at: CGPoint(x: x, y: 100 + x / 3)) }
    }

    /// A brush stroke in progress, on a layer's pixels (with and without a mask on it) and on its mask.
    @Test(arguments: [(false, false), (true, false), (true, true)])
    func matchesWhilePainting(masked: Bool, paintingMask: Bool) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable(masked: masked)
        session.tool = .brush
        session.isMaskSelected = paintingMask
        session.maskPaintWhite = false
        stroke(session)
        #expect(session.brushStroke != nil)
        session.zoom(to: 1)
        let difference = try compare(session, name: "painting-\(masked)-\(paintingMask)")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// A gradient being dragged, linear and radial, the radial one inside a selection.
    @Test(arguments: [GradientShape.linear, .radial])
    func matchesWhileDraggingAGradient(shape: GradientShape) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable()
        session.tool = .gradient
        session.gradientSettings.shape = shape
        if shape == .radial {
            session.applySelection(CGPath(ellipseIn: CGRect(x: 100, y: 80, width: 300, height: 260), transform: nil), mode: .replace, name: "Select")
        }
        session.beginGradient(at: CGPoint(x: 150, y: 120))
        session.moveGradient(end: CGPoint(x: 420, y: 330))
        #expect(session.gradientEdit?.hasLine == true)
        session.zoom(to: 1)
        let difference = try compare(session, name: "gradient-\(shape)")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// A Smudge stroke in progress.
    @Test func matchesWhileSmudging() throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable(masked: true)
        session.tool = .blur
        session.blurMode = .smudge
        stroke(session)
        #expect(session.warpStroke != nil)
        session.zoom(to: 1)
        let difference = try compare(session, name: "smudge")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// A new mask is a single white pixel stretched over its layer: it shows the layer whole, not faded.
    @Test(arguments: [0.0, 25.0])
    func aNewMaskRevealsTheWholeLayer(rotation: CGFloat) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable()
        let index = session.document!.layers.firstIndex { $0.id == session.activeLayerID }!
        session.document!.layers[index].transform.rotation = rotation
        session.document!.layers[index].transform.size = CGSize(width: 380, height: 300)
        session.addLayerMask()
        #expect(session.document!.layers[index].mask?.asset.image.width == 1)
        session.zoom(to: 0.8)
        let difference = try compare(session, name: "new-mask-\(Int(rotation))")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// Each adjustment over a photo, with a mask on it and at 80% opacity, on a canvas where the document fills the view
    /// one to one — so noise and grain land on the same pixels on both canvases.
    @Test(arguments: [AdjustmentKind.curves, .blackWhite, .colorBalance, .exposure, .gradientMap, .invert,
                      .gaussianBlur, .motionBlur, .addNoise, .grain])
    func matchesEveryAdjustment(kind: AdjustmentKind) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 600, height: 500), backingScale: 1, documentSize: nil)
        session.createDocument(width: 600, height: 500)
        let image = try pattern(600, 500, seed: 3)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        let small = try pattern(260, 200, seed: 5, alpha: true)
        session.insert(ImportedImage(image: small, thumbnail: small, name: "Top"))
        var adjustment = LayerAdjustment(kind: kind)
        switch kind {
        case .curves: adjustment.curves.channels[0] = [CurvePoint(x: 0, y: 20), CurvePoint(x: 120, y: 170), CurvePoint(x: 255, y: 235)]
        case .colorBalance: adjustment.colorBalance.midCyanRed = 40; adjustment.colorBalance.shadowYellowBlue = -30
        case .exposure: adjustment.exposure.exposure = 0.8; adjustment.exposure.gamma = 1.2
        case .gradientMap:
            adjustment.gradientMap.shadows = AdjustmentColor(red: 0.1, green: 0.0, blue: 0.4)
            adjustment.gradientMap.highlights = AdjustmentColor(red: 1, green: 0.8, blue: 0.3)
        case .gaussianBlur: adjustment.gaussianRadius = 6
        case .motionBlur: adjustment.resolvedMotionDistance = 30; adjustment.resolvedMotionAngle = 30
        case .addNoise: adjustment.resolvedNoiseAmount = 25; adjustment.resolvedNoiseSeed = 7
        case .grain: adjustment.grain.amount = 60; adjustment.grain.size = 3; adjustment.grain.seed = 11
        default: break
        }
        var layer = ImageLayer(name: "Adjustment", blankSize: CGSize(width: 600, height: 500))
        layer.adjustment = adjustment
        layer.opacity = 0.8
        layer.mask = LayerMask(asset: try LayerMask.asset(from: gradientMask(600, 500)))
        session.document!.layers.append(layer)
        session.selectLayer(nil)
        session.zoom(to: 1)
        let difference = try compare(session, name: "adjustment-\(kind.rawValue)", width: 600, height: 500, backingScale: 1)
        #expect(difference.mean < 1.5 && difference.over < 0.01, "\(kind.rawValue): mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// Noise and Grain belong to the document on both canvases, wherever it sits in the view and however it's zoomed.
    @Test(arguments: [AdjustmentKind.addNoise, .grain])
    func patternsStayWithTheDocument(kind: AdjustmentKind) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 500, height: 400), backingScale: 2, documentSize: nil)
        session.createDocument(width: 600, height: 500)
        let image = try pattern(600, 500, seed: 3)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        var adjustment = LayerAdjustment(kind: kind)
        adjustment.resolvedNoiseAmount = 25
        adjustment.grain.amount = 60
        adjustment.grain.size = 3
        var layer = ImageLayer(name: "Adjustment", blankSize: CGSize(width: 600, height: 500))
        layer.adjustment = adjustment
        session.document!.layers.append(layer)
        session.selectLayer(nil)
        session.zoom(to: 0.8)
        let difference = try compare(session, name: "pattern-\(kind.rawValue)")
        // Shrinking, the two sample the pattern's hard edges a little differently (see matchesCoreGraphicsCanvas).
        #expect(difference.mean < 1.5 && difference.over < 0.03, "\(kind.rawValue): mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// Adjustments in a blend mode, over the canvas and inside a clipping stack.
    @Test(arguments: [LayerBlendMode.multiply, .color, .overlay, .linearDodge])
    func matchesAdjustmentsInABlendMode(mode: LayerBlendMode) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable()
        let base = session.document!.layers.firstIndex { $0.id == session.activeLayerID }!
        var curves = ImageLayer(name: "Curves", blankSize: CGSize(width: 600, height: 500))
        curves.adjustment = LayerAdjustment(kind: .curves)
        curves.adjustment!.curves.channels[0] = [CurvePoint(x: 0, y: 40), CurvePoint(x: 128, y: 200), CurvePoint(x: 255, y: 230)]
        curves.blendMode = mode
        curves.opacity = 0.85
        session.document!.layers.append(curves)
        // The same, clipped to the photo.
        var clipped = ImageLayer(name: "Hue", blankSize: CGSize(width: 600, height: 500))
        clipped.adjustment = LayerAdjustment(kind: .hsv, hsvSettings: HueSaturationSettings(hue: 60, saturation: 30))
        clipped.blendMode = mode
        clipped.maskSourceID = session.document!.layers[base].id
        session.document!.layers.insert(clipped, at: base + 1)
        session.selectLayer(nil)
        session.zoom(to: 1)
        let difference = try compare(session, name: "adjustment-mode-\(mode.rawValue)")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "\(mode.rawValue): mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// A layer masked by the coverage of a layer that isn't directly under it.
    @Test func matchesALiveMaskOutsideAClippingStack() throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable()
        let shape = try pattern(260, 220, seed: 6, alpha: true)
        session.insert(ImportedImage(image: shape, thumbnail: shape, name: "Shape"))
        let source = session.document!.layers.firstIndex { $0.id == session.activeLayerID }!
        session.document!.layers[source].transform.rotation = 15
        let between = try pattern(200, 200, seed: 7)
        session.insert(ImportedImage(image: between, thumbnail: between, name: "Between"))
        let top = try pattern(500, 400, seed: 8)
        session.insert(ImportedImage(image: top, thumbnail: top, name: "Masked"))
        let masked = session.document!.layers.firstIndex { $0.id == session.activeLayerID }!
        session.document!.layers[masked].maskSourceID = session.document!.layers[source].id
        session.selectLayer(nil)
        session.zoom(to: 1)
        let difference = try compare(session, name: "live-mask")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// Option-click on a mask: the mask by itself, drawn alike on both canvases — as it is, and while a stroke paints it.
    @Test func matchesAMaskShownAlone() throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try session(zoom: 1)
        let masked = try #require(session.document?.layers.first { $0.name == "Masked" }?.id)
        session.toggleMaskAlone(masked)
        #expect(session.maskAloneLayer?.id == masked)
        var difference = try compare(session, name: "mask-alone")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 40, hardness: 1, red: 0, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 320, y: 300))
        session.continueBrush(at: CGPoint(x: 480, y: 330))
        difference = try compare(session, name: "mask-alone-painting")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
        session.finishBrushImmediately()
    }

    /// A distortion being dragged, on a masked layer: in perspective (convex), and folded over (warped on the CPU).
    @Test(arguments: [false, true])
    func matchesWhileDistorting(folded: Bool) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable(masked: true)
        session.selectTool(.move)
        session.beginTransform(persistent: false)
        session.beginDistort()
        let shape = [CGPoint(x: 120, y: 60), CGPoint(x: 470, y: 110), CGPoint(x: 430, y: 420), CGPoint(x: 70, y: 380)]
        session.previewCorners(folded ? [shape[0], shape[2], shape[1], shape[3]] : shape)
        #expect(session.transformEdit?.corners != nil)
        session.zoom(to: 1)
        let difference = try compare(session, name: "distort-\(folded)")
        // A warp resamples every pixel, and the CPU canvas warps at most 2048 pixels across: edges land a little
        // differently, so this allows more of them than the placements above.
        #expect(difference.mean < 2 && difference.over < 0.05, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// New text being typed, and text being edited with a stroke and shadow redone around it as it's typed.
    @Test(arguments: [false, true])
    func matchesWhileTyping(existing: Bool) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable()
        if existing {
            session.beginText(at: CGPoint(x: 150, y: 200), newLayer: true)
            session.textDraft?.style.content = "Before"
            session.textDraft?.style.fontSize = 64
            #expect(session.finishText())
            let index = session.document!.layers.firstIndex { $0.id == session.activeLayerID }!
            session.document!.layers[index].effects = LayerEffects(stroke: StrokeEffect(size: 3, red: 1, green: 1, blue: 1),
                                                                  shadow: ShadowEffect(distance: 8, blur: 6))
            session.beginText(at: CGPoint(x: 170, y: 180))
            #expect(session.textDraft?.layerID != nil)
        } else {
            session.beginText(at: CGPoint(x: 150, y: 200), newLayer: true)
        }
        session.textDraft?.style.content = "Typing"
        session.textDraft?.style.fontSize = 64
        session.zoom(to: 1)
        let difference = try compare(session, name: "typing-\(existing)", inWindow: true)
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// A shape being dragged out, which draws above the active layer.
    @Test func matchesWhileDrawingAShape() throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable()
        session.selectTool(.shape)
        session.beginShape(at: CGPoint(x: 120, y: 90))
        session.dragShape(to: CGPoint(x: 380, y: 300), square: false, fromCenter: false)
        #expect(session.shapeDraft != nil)
        session.zoom(to: 1)
        let difference = try compare(session, name: "shape")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    enum EffectsCase: String, CaseIterable {
        case paintingWithEffects, gradientWithEffects, gradientOnAMask, movingOnAMaskedLayer, movingWithEffects, paintingAPlacedMask
    }

    /// Editing layers the Core Graphics canvas used to draw for: effects redone as they're edited, masks placed apart.
    @Test(arguments: EffectsCase.allCases)
    func matchesWhileEditingLayersWithEffectsAndMasks(edit: EffectsCase) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let masked = edit == .gradientOnAMask || edit == .movingOnAMaskedLayer || edit == .paintingAPlacedMask
        let session = try paintable(masked: masked)
        let index = session.document!.layers.firstIndex { $0.id == session.activeLayerID }!
        if [.paintingWithEffects, .gradientWithEffects, .movingWithEffects].contains(edit) {
            session.document!.layers[index].effects = LayerEffects(stroke: StrokeEffect(size: 5, red: 1, green: 1, blue: 1),
                                                                  shadow: ShadowEffect(distance: 12, blur: 8))
        }
        if edit == .paintingAPlacedMask {
            var placed = session.document!.layers[index].transform
            placed.origin.x += 60
            placed.rotation = 10
            session.document!.layers[index].mask?.placement = placed
            session.document!.layers[index].mask?.isLinked = false
        }
        switch edit {
        case .paintingWithEffects, .paintingAPlacedMask:
            session.tool = .brush
            session.isMaskSelected = edit == .paintingAPlacedMask
            stroke(session)
            #expect(session.brushStroke != nil)
        case .gradientWithEffects, .gradientOnAMask:
            session.tool = .gradient
            session.isMaskSelected = edit == .gradientOnAMask
            session.beginGradient(at: CGPoint(x: 150, y: 120))
            session.moveGradient(end: CGPoint(x: 420, y: 330))
            #expect(session.gradientEdit?.hasLine == true)
        case .movingOnAMaskedLayer, .movingWithEffects:
            session.applySelection(CGPath(ellipseIn: CGRect(x: 140, y: 120, width: 200, height: 150), transform: nil), mode: .replace, name: "Select")
            #expect(session.beginPixelMove())
            session.movePixels(by: CGSize(width: 70, height: 50))
        }
        session.zoom(to: 1)
        let difference = try compare(session, name: "editing-\(edit.rawValue)")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "\(edit.rawValue): mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// A clipping stack whose base is in a mode Core Graphics can't draw: Copy Merged, export and both canvases blend
    /// the stack in that mode (they used to draw it Normal everywhere but the GPU canvas).
    @Test(arguments: [LayerBlendMode.linearDodge, .colorDodge, .multiply])
    func clippingStacksBlendInTheirBasesMode(mode: LayerBlendMode) async throws {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 500, height: 400), backingScale: 2, documentSize: nil)
        session.createDocument(width: 100, height: 100)
        func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ size: Int = 100) throws -> CGImage {
            let context = try BrushRaster.context(width: size, height: size, mask: false)
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            return context.makeImage()!
        }
        for (image, name) in [(try solid(0.4, 0.2, 0.1), "Base"), (try solid(0.3, 0.3, 0.3), "Blended"), (try solid(0.2, 0.05, 0, 50), "Clipped")] {
            session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        }
        let layers = session.document!.layers
        session.document!.layers[layers.count - 2].blendMode = mode
        session.document!.layers[layers.count - 1].maskSourceID = layers[layers.count - 2].id
        session.document!.layers[layers.count - 1].transform.origin = .zero
        session.selectLayer(nil)
        session.selectAll()
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
            let copy = try BrushRaster.copy(image)
            let data = try #require(copy.data).assumingMemoryBound(to: UInt8.self)
            return (0..<3).map { Int(data[y * copy.bytesPerRow + x * 4 + $0]) }
        }
        let merged = try #require(try session.renderMergedPixels()).image
        let exported = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        // Where the clipped layer covers the stack, and where only the stack's base does.
        for (x, y) in [(20, 20), (80, 80)] {
            #expect(try pixel(merged, x, y) == pixel(exported, x, y), "\(mode.rawValue) at \(x),\(y): Copy Merged matches export")
        }
        if mode == .linearDodge {
            let covered = try pixel(exported, 20, 20), bare = try pixel(exported, 80, 80)
            #expect(zip(covered, [153, 64, 26]).allSatisfy { abs($0 - $1) <= 1 }, "base plus the clipped layer: \(covered)")
            #expect(zip(bare, [179, 128, 102]).allSatisfy { abs($0 - $1) <= 1 }, "base plus the stack's own base: \(bare)")
        }
        guard GPUCanvasRenderer.shared != nil else { return }
        session.deselect()
        session.zoom(to: 2)
        let difference = try compare(session, name: "stack-\(mode.rawValue)")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "\(mode.rawValue): mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// Soft Light as Photoshop computes it, within a few levels, in export and Copy Merged as on the canvas. Core
    /// Graphics's own formula came out up to 25 levels lighter with a light blend color.
    @Test func softLightMatchesPhotoshop() async throws {
        let session = EditorSession()
        session.createDocument(width: 10, height: 10)
        for (value, name) in [(CGFloat(0.5), "Base"), (0.9, "Soft")] {
            let context = try BrushRaster.context(width: 10, height: 10, mask: false)
            context.setFillColor(CGColor(srgbRed: value, green: value, blue: value, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
            let image = try #require(context.makeImage())
            session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        }
        session.document!.layers[session.document!.layers.count - 1].blendMode = .softLight
        session.selectLayer(nil)
        session.selectAll()
        func red(_ image: CGImage) throws -> Int {
            let copy = try BrushRaster.copy(image)
            return Int(try #require(copy.data).assumingMemoryBound(to: UInt8.self)[copy.bytesPerRow * 5 + 20])
        }
        // Photoshop: 2·0.5·(1 − 0.9) + √0.5·(2·0.9 − 1) = 0.666, 170 of 255.
        let exported = try red(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
        let merged = try red(try #require(try session.renderMergedPixels()).image)
        #expect(abs(exported - 170) <= 2 && abs(merged - 170) <= 2, "export \(exported), Copy Merged \(merged)")
    }

    /// A soft-edged painted layer, smaller than the canvas, in a blend mode: its partly transparent pixels blend the same
    /// on the GPU canvas as on the Core Graphics canvas and in Copy Merged.
    @Test(arguments: [LayerBlendMode.softLight, .overlay, .multiply, .colorDodge])
    func softEdgedLayersBlendTheSame(mode: LayerBlendMode) async throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 500, height: 400), backingScale: 2, documentSize: nil)
        session.createDocument(width: 600, height: 500)
        let photo = try pattern(600, 500, seed: 4)
        session.insert(ImportedImage(image: photo, thumbnail: photo, name: "Photo"))
        // Red, soft-edged: fully opaque in the middle, fading to nothing.
        let soft = try BrushRaster.context(width: 280, height: 180, mask: false)
        let colors = [CGColor(srgbRed: 1, green: 0.05, blue: 0, alpha: 1), CGColor(srgbRed: 1, green: 0.05, blue: 0, alpha: 0)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0.3, 1])!
        soft.drawRadialGradient(gradient, startCenter: CGPoint(x: 140, y: 90), startRadius: 0, endCenter: CGPoint(x: 140, y: 90), endRadius: 110, options: [])
        let paint = try #require(soft.makeImage())
        session.insert(ImportedImage(image: paint, thumbnail: paint, name: "Paint"))
        let index = session.document!.layers.count - 1
        session.document!.layers[index].transform.origin = CGPoint(x: 160, y: 140)
        session.document!.layers[index].blendMode = mode
        session.selectLayer(nil)
        session.zoom(to: 1)
        let difference = try compare(session, name: "soft-\(mode.rawValue)")
        #expect(difference.mean < 1.5 && difference.over < 0.005, "\(mode.rawValue): mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// Zoomed out, a layer is drawn from a reduced copy made from the full size; the full size goes once the frame is
    /// done, as nothing draws from it, while the reductions stay for the next frame.
    @Test func zoomedOutKeepsOnlyTheReductions() throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let image = try pattern(1200, 900, seed: 1)
        #expect(renderer.image(image, level: 2) != nil)
        #expect(renderer.cachedLevels(of: image) == [0, 1, 2])
        renderer.endFrame()
        #expect(renderer.cachedLevels(of: image) == [1, 2], "the full size is let go: \(renderer.cachedLevels(of: image))")
        // Drawn at full size, it stays.
        #expect(renderer.image(image, level: 0) != nil)
        renderer.endFrame()
        #expect(renderer.cachedLevels(of: image) == [0, 1, 2])
    }
}
