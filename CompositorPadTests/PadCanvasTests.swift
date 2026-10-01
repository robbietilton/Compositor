import CoreGraphics
import CoreImage
import Metal
import Testing
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
