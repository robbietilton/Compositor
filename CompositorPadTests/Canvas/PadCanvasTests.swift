import CoreGraphics
import CoreImage
import Metal
import Testing
import UIKit
@testable import Compositor

/// The iPad canvas against the editor's own composite, and painting on it.
@MainActor struct PadCanvasTests {
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

    /// GPUCanvasTests' document: masks, opacity, rotation, blend modes, a folder with a mask, a clipping stack, and
    /// Levels and Hue/Saturation layers — seen at 100%, one screen pixel to a document pixel.
    private func richSession() throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 600, height: 500), backingScale: 1, documentSize: nil)
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
        session.zoom(to: 1)
        return session
    }

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

    /// A solid red or black image 2400 pixels wide, wider than the canvas makes a layer's effects at.
    private func solid(red: CGFloat, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: 2400, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: height))
        return try #require(context.makeImage())
    }

    /// The document as it exports: the green at a point on it.
    private func exportedGreen(_ session: EditorSession) async throws -> (CGPoint) -> Double {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        return { point in Double(bytes[(Int(point.y) * image.width + Int(point.x)) * 4 + 1]) / 255 }
    }

    /// `richSession()`'s document with more of what a project can hold, drawn from or not, as GPUCanvasTests' opened
    /// project has: a layer masked by a hidden one, itself masked by another hidden one; a mask placed apart from its
    /// layer; a disabled mask, with a masked adjustment clipped to its layer; a hidden folder holding a masked layer; a
    /// photo clipped to an empty layer; an adjustment clipped to a hidden layer, outside a clipping stack; text; and a
    /// drop shadow. Saved as a package.
    private func savedProject() throws -> URL {
        let session = try richSession()
        func layer(_ image: CGImage, _ name: String, at origin: CGPoint) -> ImageLayer {
            ImageLayer(id: UUID(), asset: ImportedImage(image: image, thumbnail: image, name: name), name: name, isVisible: true,
                       transform: LayerTransform(origin: origin, size: CGSize(width: image.width, height: image.height)))
        }
        func mask(_ width: Int, _ height: Int) throws -> LayerMask {
            LayerMask(asset: try LayerMask.asset(from: gradientMask(width, height)))
        }
        var deep = layer(try pattern(150, 150, seed: 7, alpha: true), "Deep source", at: CGPoint(x: 420, y: 320))
        deep.isVisible = false
        var near = layer(try pattern(180, 140, seed: 8, alpha: true), "Near source", at: CGPoint(x: 400, y: 300))
        near.isVisible = false
        near.maskSourceID = deep.id
        near.mask = try mask(180, 140)
        var shown = layer(try pattern(200, 160, seed: 9), "Masked by hidden layers", at: CGPoint(x: 380, y: 290))
        shown.maskSourceID = near.id
        var apart = layer(try pattern(220, 180, seed: 10), "Mask placed apart", at: CGPoint(x: 20, y: 150))
        apart.mask = try mask(220, 180)
        var placement = apart.transform
        placement.origin.x += 40
        placement.rotation = 15
        apart.mask!.placement = placement
        apart.mask!.isLinked = false
        var disabled = layer(try pattern(160, 120, seed: 11), "Mask turned off", at: CGPoint(x: 200, y: 20))
        disabled.mask = try mask(160, 120)
        disabled.mask!.isEnabled = false
        var stacked = ImageLayer(name: "Levels clipped to a layer", blankSize: CGSize(width: 600, height: 500))
        stacked.adjustment = LayerAdjustment(kind: .levels)
        stacked.adjustment!.levels.ranges[0].gamma = 0.8
        stacked.mask = try mask(600, 500)
        stacked.maskSourceID = disabled.id
        var folder = ImageLayer(name: "Hidden folder", blankSize: CGSize(width: 600, height: 500))
        folder.isGroup = true
        folder.isVisible = false
        folder.mask = try mask(600, 500)
        var hidden = layer(try pattern(140, 140, seed: 12), "In a hidden folder", at: CGPoint(x: 100, y: 100))
        hidden.parentID = folder.id
        hidden.mask = try mask(140, 140)
        let empty = ImageLayer(name: "Empty", blankSize: CGSize(width: 600, height: 500))
        var clipped = layer(try pattern(160, 160, seed: 14), "Clipped to an empty layer", at: CGPoint(x: 300, y: 200))
        clipped.maskSourceID = empty.id
        var adjustment = ImageLayer(name: "Clipped Levels", blankSize: CGSize(width: 600, height: 500))
        adjustment.adjustment = LayerAdjustment(kind: .levels)
        adjustment.adjustment!.levels.ranges[0].gamma = 0.6
        adjustment.mask = try mask(600, 500)
        adjustment.maskSourceID = deep.id
        var shadowed = layer(try pattern(120, 100, seed: 13, alpha: true), "Shadowed", at: CGPoint(x: 460, y: 60))
        shadowed.effects = LayerEffects(shadow: ShadowEffect(distance: 8, blur: 6))
        session.document!.layers += [deep, near, shown, apart, disabled, stacked, hidden, folder, empty, clipped, adjustment, shadowed]
        session.selectLayer(shadowed.id)
        session.beginText(at: CGPoint(x: 60, y: 420), newLayer: true)
        session.textDraft?.style.content = "Opened"
        session.textDraft?.style.fontSize = 48
        #expect(session.finishText())
        let url = FileManager.default.temporaryDirectory.appending(path: "PadCanvasTests \(UUID().uuidString).comp")
        try ProjectStore.package(for: try #require(session.projectSnapshot())).write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    /// Where an opened project is seen: fit in windows of a few sizes, on screens of either scale, or zoomed in to
    /// crisp pixels.
    enum OpenedView: String, CaseIterable {
        case fitAtOneX, fitAtTwoX, fitSmall, crisp
        var points: CGSize {
            switch self {
            case .fitAtOneX: CGSize(width: 600, height: 500)
            case .fitAtTwoX: CGSize(width: 918, height: 800)
            case .fitSmall: CGSize(width: 300, height: 200)
            case .crisp: CGSize(width: 500, height: 400)
            }
        }
        var scale: Int { self == .fitAtOneX ? 1 : 2 }
        var pixels: CGSize { CGSize(width: points.width * CGFloat(scale), height: points.height * CGFloat(scale)) }
    }

    /// An editor seen as `view` is, with nothing in it yet.
    private func session(in view: OpenedView) -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: view.points, backingScale: CGFloat(view.scale), documentSize: nil)
        return session
    }

    /// Every image of the document: each layer's pixels and mask, folders' masks included.
    private func images(_ document: CanvasDocument) -> [(name: String, image: CGImage)] {
        document.layers.flatMap { layer in
            [layer.asset.map { (layer.name, $0.image) }, layer.mask.map { (layer.name + "'s mask", $0.asset.image) }].compactMap { $0 }
        }
    }

    /// The images a document just put in an editor says its first frame draws from are exactly the ones the iPad
    /// canvas's first frame uploads.
    @Test(arguments: OpenedView.allCases)
    func theIPadsFirstFrameDrawsFromExactlyItsSources(view: OpenedView) throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = session(in: view)
        session.installProject(try ProjectStore.readPackage(url), from: url)
        if view == .crisp { session.zoom(to: 3) }
        let document = try #require(session.document)
        let sources = Set(document.canvasSources.map { ObjectIdentifier($0.image) })
        _ = try frameBytes(session, size: view.pixels)
        let all = images(document)
        // All but the mask placed apart, the disabled one, the hidden folder's mask and layer, the photo clipped to an
        // empty layer, and the clipped adjustment's mask.
        #expect(all.count == 26 && sources.count == 19)
        for (name, image) in all {
            let levels = renderer.cachedLevels(of: image)
            #expect(levels.isEmpty != sources.contains(ObjectIdentifier(image)), "\(name): \(levels)")
            if sources.contains(ObjectIdentifier(image)) { #expect(levels.first == 0, "\(name): \(levels)") }
        }
    }

    /// A project opened with its textures made as it's read draws its first frame uploading nothing but the copy of a
    /// mask placed apart, exactly as one drawn on demand, and leaves the canvas holding what that one would.
    @Test(arguments: OpenedView.allCases)
    func anOpenedProjectsFirstFrameUploadsNothingAndLooksTheSame(view: OpenedView) async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let opened = session(in: view)
        let file = CompositorDocument(fileURL: url, session: opened)
        let made = try await file.openDocument { snapshot in
            await renderer.prepare(CanvasDocument(project: snapshot).canvasSources)
        }
        // From here on nothing is awaited, so no other frame comes between.
        #expect(made == 19)
        if view == .crisp { opened.zoom(to: 3) }
        let before = renderer.uploads
        let first = try frameBytes(opened, size: view.pixels)
        // The mask placed apart is drawn from a copy resampled into its layer's grid for the view, made as it's drawn.
        #expect(renderer.uploads == before + 1)
        let onDemand = session(in: view)
        onDemand.installProject(try ProjectStore.readPackage(url), from: url)
        if view == .crisp { onDemand.zoom(to: 3) }
        #expect(try frameBytes(onDemand, size: view.pixels) == first)
        renderer.endFrame()
        for (prepared, drawn) in zip(images(try #require(opened.document)), images(try #require(onDemand.document))) {
            #expect(renderer.cachedLevels(of: prepared.image) == renderer.cachedLevels(of: drawn.image), "\(prepared.name)")
        }
        await file.closeDocument()
    }

    /// What waits for the canvas's next frame to show runs as that frame is presented, once, on the main thread.
    @Test func whatWaitsForTheNextFrameToShowRunsAsItIsPresented() throws {
        let canvas = PadCanvasView(session: try richSession())
        canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        canvas.layoutIfNeeded()
        var runs = 0
        canvas.whenNextFrameShows {
            #expect(Thread.isMainThread)
            runs += 1
        }
        #expect(runs == 0)
        canvas.render()
        #expect(runs == 1)
        canvas.render()
        #expect(runs == 1)
    }

    /// A canvas that finds no drawable three frames running goes on without one, so nothing waits for its frame for good.
    @Test func whatWaitsForTheNextFrameToShowStillRunsWithoutADrawable() throws {
        let canvas = PadCanvasView(session: try richSession())
        canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        canvas.layoutIfNeeded()
        let surface = try #require(canvas.subviews.lazy.compactMap { $0 as? MetalCanvasView }.first)
        surface.metalLayer.device = nil
        var runs = 0
        canvas.whenNextFrameShows { runs += 1 }
        canvas.render()
        canvas.render()
        #expect(runs == 0)
        canvas.render()
        #expect(runs == 1)
        surface.metalLayer.device = GPUCanvasRenderer.shared?.device
        canvas.render()
        #expect(runs == 1)
    }

    @Test func matchesTheEditorsComposite() throws {
        let session = try richSession()
        let document = try #require(session.document)
        let placed = session.viewport.documentRect(document.size)
        #expect(abs(placed.minX) < 0.001 && abs(placed.minY) < 0.001 && placed.width == 600 && placed.height == 500)
        let gpu = try frameBytes(session, size: CGSize(width: 600, height: 500))
        // The editor's own composite on the CPU, as Copy Merged draws it.
        let reference = try BrushRaster.context(width: 600, height: 500, mask: false)
        session.drawLiveComposite(document, in: reference)
        let cpu = reference.data!.assumingMemoryBound(to: UInt8.self)
        var total = 0.0, over = 0, count = 0
        // Inside the document's edge line.
        for y in 2..<498 { for x in 2..<598 {
            let pixel = y * 600 + x
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
        #expect(mean < 1.5 && share < 0.01, "mean \(mean), over 12 levels \(share * 100)%")
    }

    @Test func paintsWithTheBrush() throws {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createNewProject(width: 400, height: 300)
        session.zoom(to: 1)
        session.selectTool(.brush)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.brushSettings.diameter = 40
        session.brushSettings.hardness = 1
        session.beginBrush(at: CGPoint(x: 100, y: 150))
        session.continueBrush(at: CGPoint(x: 300, y: 150))
        func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * 400 + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        // Mid-stroke, from the stroke's tiles.
        let live = try frameBytes(session, size: CGSize(width: 400, height: 300))
        let painting = pixel(live, 200, 150)
        #expect(painting.0 > 230 && painting.1 < 25 && painting.2 < 25, "mid-stroke \(painting)")
        #expect(session.finishBrushImmediately())
        // Committed, from the layer's pixels.
        let committed = try frameBytes(session, size: CGSize(width: 400, height: 300))
        let painted = pixel(committed, 200, 150)
        #expect(painted.0 > 230 && painted.1 < 25 && painted.2 < 25, "committed \(painted)")
        // Away from the stroke, the checkerboard shows through the empty layer.
        let empty = pixel(committed, 200, 40)
        #expect(empty.0 == empty.1 && empty.1 == empty.2 && (70...100).contains(empty.0), "empty \(empty)")
        #expect(session.canUndo)
        session.undo()
        let undone = pixel(try frameBytes(session, size: CGSize(width: 400, height: 300)), 200, 150)
        #expect(undone.0 == undone.1 && undone.1 == undone.2, "after undo \(undone)")
    }

    /// A shape being dragged out shows where its layer will go, just above the active layer: under the layers above it.
    @Test func drawsAShapeBeingDraggedOutAboveTheActiveLayer() throws {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createNewProject(width: 400, height: 300)
        session.zoom(to: 1)
        let below = try #require(session.activeLayerID)
        // A red layer above it, in the middle.
        let context = try BrushRaster.context(width: 100, height: 100, mask: false)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        let red = try #require(session.activeLayer?.transform)
        session.selectLayer(below)
        session.selectTool(.shape)
        session.shapeKind = .rectangle
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 1)
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.dragShape(to: CGPoint(x: 380, y: 280), square: false, fromCenter: false)

        let bytes = try frameBytes(session, size: CGSize(width: 400, height: 300))
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * 400 + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        let shape = pixel(40, 40)
        #expect(shape.0 < 25 && shape.1 < 25 && shape.2 > 230, "shape \(shape)")
        let covered = pixel(Int(red.origin.x) + 50, Int(red.origin.y) + 50)
        #expect(covered.0 > 230 && covered.1 < 25 && covered.2 < 25, "covered \(covered)")
    }

    enum PreviewedEdit: String, CaseIterable { case gaussianBlur, levels, hueSaturation }

    /// A layer with effects shows a filter's or an adjustment's preview on the canvas, with its effects redone around
    /// it, as on the Mac. The canvas used to draw the effects made from the layer's own pixels instead, so the preview
    /// never showed until OK. Until the preview's effects are made, the layer's own stand in where the layer is now,
    /// though it moved after they were made.
    @Test(arguments: PreviewedEdit.allCases)
    func previewShowsOnALayerWithEffects(edit: PreviewedEdit) async throws {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 240, height: 160), backingScale: 1, documentSize: nil)
        session.createDocument(width: 200, height: 120)
        // Red on the left half, blue on the right.
        let context = try BrushRaster.context(width: 120, height: 40, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 60, y: 0, width: 60, height: 40))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Halves"))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        // At the document's left edge for now: it moves 40 pixels right once its effects are made.
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 0, y: 20), size: CGSize(width: 120, height: 40))
        // A hard green drop shadow, 30 pixels straight down.
        session.document?.layers[index].effects = LayerEffects(shadow: ShadowEffect(distance: 30, blur: 0, green: 1, opacity: 1))
        session.zoom(to: 1)
        // The canvas as drawn, looked up at a point on the document.
        func drawn() throws -> (CGPoint) -> [Double] {
            let bytes = try frameBytes(session, size: CGSize(width: 240, height: 160))
            return { point in
                let at = session.viewport.viewPoint(from: point, documentSize: CGSize(width: 200, height: 120))
                let i = (Int(at.y) * 240 + Int(at.x)) * 4
                return (0..<3).map { Double(bytes[i + $0]) / 255 }
            }
        }
        // Where red meets blue, and the shadow below the layer, once it has moved.
        func colors() throws -> (edge: [Double], shadow: [Double]) {
            let color = try drawn()
            return (color(CGPoint(x: 99.5, y: 40)), color(CGPoint(x: 100.5, y: 80.5)))
        }
        // The effects are made on a worker: wait for them, as the canvas does.
        _ = try colors()
        for _ in 0..<100 where session.effectsPreviews.rendered(id) == nil { try await Task.sleep(for: .milliseconds(20)) }
        // Moved 40 pixels right, as Shift and the Right Arrow key nudge it with the Move tool.
        for _ in 0..<4 { session.nudgeLayer(dx: 10, dy: 0) }
        let before = try colors()
        #expect(before.edge[0] > 0.9 && before.edge[2] < 0.1, "the layer's own red \(before.edge)")
        #expect(before.shadow[1] > 0.8, "its shadow \(before.shadow)")
        // Blurred, darkened or turned another hue a little further at each step.
        func preview(_ step: Double) async {
            switch edit {
            case .gaussianBlur:
                if session.filterEdit == nil { session.beginFilter(.gaussianBlur) }
                session.updateFilter(FilterSettings(radius: 2 + step), preview: true)
                while let edit = session.filterEdit, edit.previewTask != nil { await edit.previewTask?.value }
            case .levels:
                if session.levels == nil { session.beginLevels() }
                var settings = LevelsSettings()
                settings.ranges[0].outputWhite = 120 + step * 8
                session.updateLevels(settings, preview: true)
                while let edit = session.levels, edit.previewTask != nil { await edit.previewTask?.value }
            case .hueSaturation:
                if session.hueSaturation == nil { session.beginHueSaturation() }
                session.updateHueSaturation(HueSaturationSettings(hue: 100 + step * 20), preview: true)
                while session.hueSaturationTask != nil { await session.hueSaturationTask?.value }
            }
        }
        await preview(1)
        #expect((session.filterEdit?.previewImage(for: id) ?? session.levels?.previewImage(for: id)
                 ?? session.hueSaturation?.previewImage(for: id)) != nil)
        // On the first frame, before the preview's effects are made, the layer's own stand in where the layer is now:
        // its blue end and the shadow under it past where it was, and no red left where its red end was.
        let color = try drawn()
        let end = color(CGPoint(x: 140, y: 40)), under = color(CGPoint(x: 140, y: 80.5)), was = color(CGPoint(x: 20, y: 40))
        #expect(end[2] > 0.8 && end[0] < 0.2, "\(edit.rawValue): the layer where it is now \(end)")
        #expect(under[1] > 0.8 && under[0] < 0.2, "\(edit.rawValue): its shadow under it \(under)")
        #expect(was[0] < 0.5, "\(edit.rawValue): no red where it was \(was)")
        // The red at the edge is no longer full, and the shadow stays on.
        var during = try colors()
        for _ in 0..<100 where !(during.edge[0] < 0.75 && during.shadow[1] > 0.8) {
            try await Task.sleep(for: .milliseconds(20))
            during = try colors()
        }
        #expect(during.edge[0] < 0.75, "\(edit.rawValue): the preview shows at the edge \(during.edge)")
        #expect(during.shadow[1] > 0.8, "\(edit.rawValue): with the shadow still under it \(during.shadow)")
        // As the setting changes, the effects around the last preview stand in until the new ones are made.
        for step in 2...4 {
            let shown = session.effectsPreviews.rendered(id)?.image
            await preview(Double(step))
            let changing = try colors()
            #expect(changing.shadow[1] > 0.8, "\(edit.rawValue) step \(step): the shadow doesn't blink off \(changing.shadow)")
            for _ in 0..<100 where session.effectsPreviews.rendered(id).map({ $0.image === shown }) ?? true {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        // Cancel puts the layer back with its effects straight away: those previews didn't push them out.
        switch edit {
        case .gaussianBlur: session.cancelFilter()
        case .levels: session.cancelLevels()
        case .hueSaturation: session.cancelHueSaturation()
        }
        let after = try colors()
        #expect(after.edge[0] > 0.9 && after.edge[2] < 0.1, "\(edit.rawValue): the layer's own red again \(after.edge)")
        #expect(after.shadow[1] > 0.8, "\(edit.rawValue): with its shadow \(after.shadow)")
    }

    enum PreviewedEffect: String, CaseIterable { case shadow, outerGlow }

    /// A filter previews a large layer from a smaller copy. The effects redone around that copy are made smaller with
    /// it, so a shadow stays where it is and a glow reaches no further while the editor is open, as on the Mac.
    @Test(arguments: PreviewedEffect.allCases)
    func previewOfALargeLayerKeepsItsEffectsInPlace(effect: PreviewedEffect) async throws {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 640, height: 80), backingScale: 1, documentSize: nil)
        session.createDocument(width: 2400, height: 240)
        // Over black, which a glow's soft edge reads against.
        for (image, name) in [(try solid(red: 0, height: 240), "Black"), (try solid(red: 1, height: 60), "Wide")] {
            session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        }
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 0, y: 20), size: CGSize(width: 2400, height: 60))
        switch effect {
        case .shadow:
            // A hard green drop shadow 100 pixels straight down: from 120 to 180.
            session.document?.layers[index].effects = LayerEffects(shadow: ShadowEffect(distance: 100, blur: 0, green: 1, opacity: 1))
        case .outerGlow:
            // A green glow fading out below the layer's bottom edge, at 80.
            session.document?.layers[index].effects = LayerEffects(outerGlow: OuterGlowEffect(size: 40, red: 0, green: 1, blue: 0, opacity: 1))
        }
        session.zoom(to: 0.25)
        // Just inside the shadow's top and just past its bottom, or 20 and 40 pixels below the layer, where the glow fades.
        let points: [CGFloat] = effect == .shadow ? [128, 188] : [100, 120]
        func green() throws -> [Double] {
            let bytes = try frameBytes(session, size: CGSize(width: 640, height: 80))
            return points.map { y in
                let at = session.viewport.viewPoint(from: CGPoint(x: 1200, y: y), documentSize: CGSize(width: 2400, height: 240))
                return Double(bytes[(Int(at.y) * 640 + Int(at.x)) * 4 + 1]) / 255
            }
        }
        // The same points in the exported image: in the shadow or past it, and as far into the glow.
        let exported = try await exportedGreen(session)
        let expected = points.map { exported(CGPoint(x: 1200, y: $0)) }
        func asExported(_ drawn: [Double]) -> Bool { zip(drawn, expected).allSatisfy { abs($0 - $1) < 0.05 } }
        _ = try green()
        for _ in 0..<100 where session.effectsPreviews.rendered(id) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let before = try green()
        #expect(asExported(before), "the \(effect.rawValue) before \(before), exported \(expected)")
        session.beginFilter(.gaussianBlur)
        session.updateFilter(FilterSettings(radius: 1), preview: true)
        while let edit = session.filterEdit, edit.previewTask != nil { await edit.previewTask?.value }
        let edit = try #require(session.filterEdit)
        #expect(edit.previewScale < 0.9, "previewed from a smaller copy: \(edit.previewScale)")
        let shown = session.effectsPreviews.rendered(id)?.image
        _ = try green()
        for _ in 0..<100 where session.effectsPreviews.rendered(id).map({ $0.image === shown }) ?? true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.effectsPreviews.rendered(id)?.image !== shown, "the effects redone around the preview")
        let during = try green()
        #expect(asExported(during), "the \(effect.rawValue) where it was \(during), exported \(expected)")
        session.cancelFilter()
    }

    enum LargeLayerEffect: String, CaseIterable { case outerGlow, innerGlow, innerShadow }

    /// The canvas makes a large layer's effects from a smaller copy of it, and makes the effects smaller with it, so a
    /// glow or an inner shadow reaches as far on the canvas as in the exported image, as on the Mac.
    @Test(arguments: LargeLayerEffect.allCases)
    func effectsOfALargeLayerReachAsFarAsWhenExported(effect: LargeLayerEffect) async throws {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 640, height: 100), backingScale: 1, documentSize: nil)
        session.createDocument(width: 2400, height: 400)
        // A red layer 2400 pixels wide, past the size the canvas makes effects at, over black.
        for (image, name) in [(try solid(red: 0, height: 400), "Black"), (try solid(red: 1, height: 200), "Wide")] {
            session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        }
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 0, y: 100), size: CGSize(width: 2400, height: 200))
        // In green, which neither the layer nor the black behind it has.
        switch effect {
        case .outerGlow:
            session.document?.layers[index].effects = LayerEffects(outerGlow: OuterGlowEffect(size: 40, red: 0, green: 1, blue: 0, opacity: 1))
        case .innerGlow:
            session.document?.layers[index].effects = LayerEffects(innerGlow: InnerGlowEffect(size: 40, red: 0, green: 1, blue: 0, opacity: 1))
        case .innerShadow:
            // 40 pixels down from the layer's top edge, softened.
            session.document?.layers[index].effects = LayerEffects(innerShadow: InnerShadowEffect(distance: 40, blur: 20, green: 1, opacity: 1))
        }
        session.zoom(to: 0.25)
        // The green the canvas draws at a point on the document, down the middle of the layer.
        func drawn() throws -> (CGFloat) -> Double {
            let bytes = try frameBytes(session, size: CGSize(width: 640, height: 100))
            return { y in
                let at = session.viewport.viewPoint(from: CGPoint(x: 1200, y: y), documentSize: CGSize(width: 2400, height: 400))
                return Double(bytes[(Int(at.y) * 640 + Int(at.x)) * 4 + 1]) / 255
            }
        }
        // The effects are made on a worker: wait for them, as the canvas does.
        _ = try drawn()
        for _ in 0..<100 where session.effectsPreviews.rendered(id) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let green = try drawn()
        let exported = try await exportedGreen(session)
        // Above and below the layer, where an outer glow fades out, and inside its top and bottom edges, where an inner
        // glow fades out and the inner shadow ends; away from the edges, where a pixel either way changes little.
        for y: CGFloat in [60, 75, 125, 155, 245, 260, 275, 325, 340] {
            let point = CGPoint(x: 1200, y: y)
            #expect(abs(green(y) - exported(point)) < 0.05, "\(effect.rawValue) at \(y): canvas \(green(y)), exported \(exported(point))")
        }
    }

    /// Text is drawn through UIKit on iPad: upright, like the Mac's — a T's bar is at its top.
    @Test func drawsTextUpright() throws {
        var style = LayerTextStyle()
        style.content = "T"
        style.fontSize = 96
        let image = try EditorSession.textImage(style)
        let context = try BrushRaster.copy(image)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        var rows: [Int] = []
        for y in 0..<image.height {
            var ink = 0
            for x in 0..<image.width where data[(y * image.width + x) * 4 + 3] > 128 { ink += 1 }
            rows.append(ink)
        }
        let inked = rows.enumerated().filter { $0.element > 0 }
        let top = try #require(inked.first), bottom = try #require(inked.last)
        #expect(top.element > bottom.element * 3, "top row \(top.element) px wide, bottom \(bottom.element)")
    }

    /// Once Apple Pencil has painted, a finger moves the canvas rather than painting or drawing, as in other iPad
    /// painting apps. It still moves layers, selects, crops, picks colors and zooms.
    @Test func aFingerStillMovesSelectsAndPicksColorsOnceApplePencilPaints() {
        for tool in [NavigationTool.brush, .blur, .spotHealing, .cloneStamp, .gradient, .shape] {
            #expect(PadCanvasView.touchMovesCanvas(tool: tool, pencil: false, fingerPaints: false), "\(tool)")
        }
        for tool in [NavigationTool.move, .marquee, .lasso, .wand, .crop] {
            #expect(!PadCanvasView.touchMovesCanvas(tool: tool, pencil: false, fingerPaints: false), "\(tool)")
        }
        #expect(!PadCanvasView.touchMovesCanvas(tool: .eyedropper, pencil: false, fingerPaints: false))
        #expect(!PadCanvasView.touchMovesCanvas(tool: .zoom, pencil: false, fingerPaints: false))
        #expect(!PadCanvasView.touchMovesCanvas(tool: .brush, pencil: true, fingerPaints: false))
        #expect(!PadCanvasView.touchMovesCanvas(tool: .brush, pencil: false, fingerPaints: true))
        #expect(PadCanvasView.touchMovesCanvas(tool: .hand, pencil: true, fingerPaints: true))
    }
}
