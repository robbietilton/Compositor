import AppKit
import Metal
import Testing
@testable import Compositor

@MainActor
struct FilterTests {
    @Test func gaussianBlurSoftensAHardEdgeAndSpreadsPastTheLayerEdgeAsOneUndoStep() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        // Left half opaque white, right half transparent.
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Half"))
        session.beginFilter(.gaussianBlur)
        #expect(session.filterEdit != nil && !session.canEditLayers)
        session.updateFilter(FilterSettings(radius: 3), preview: true)
        let count = session.history.undoCount
        await session.commitFilter()
        #expect(session.filterEdit == nil && session.history.undoCount == count + 1)
        #expect(session.filterSettings.radius == 3)
        let result = try #require(session.activeLayer?.asset?.image)
        let pixels = try #require(CGContext(data: nil, width: result.width, height: result.height, bitsPerComponent: 8,
            bytesPerRow: result.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        pixels.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        // The blur is not clamped at the layer's edge: the layer is given room, the blur spreads into it and
        // whatever stays empty is cut away again (Filters.swift, `growForBlur` / `PixelFilter.trimmed`). The
        // 40 x 20 layer, opaque across its full height for its left half, comes out 36 x 36 at (-8, -8). This
        // used to read three fixed columns of a 40-wide result and assert that the border did not fade, from
        // when the blur smeared outwards and stopped at the edge; the test's name said so too.
        let origin = try #require(session.activeLayer?.transform.origin)
        #expect(origin.x < 0 && origin.y < 0, "the layer grew on every side: origin \(origin)")
        // The strongest evidence that the blur left the layer: it was 20 tall and opaque top to bottom, so it
        // could not have grown vertically unless the blur went past the edge and the layer was given room.
        #expect(result.height > 20, "the blur spread past the layer's edge: height \(result.height)")
        #expect(result.width < 40, "and the half that stayed empty was trimmed away: width \(result.width)")
        let middle = (0..<result.width).map { Int(bytes[(result.height / 2 * result.width + $0) * 4 + 3]) }
        // 250 rather than 255: the block's centre is 10 px from its edges, which at this radius leaves it a
        // fraction of a level below full opacity. What would break here is the inside fading, not rounding.
        #expect(try #require(middle.max()) >= 250, "the block's inside is untouched: \(middle.max() ?? -1)")
        #expect(middle.contains { $0 > 20 && $0 < 235 }, "the hard edge is now soft")
        #expect(try #require(middle.last) < 20, "and it fades out on the far side")
    }

    /// Dragging a blur bigger grows the layer to make room for it. The last preview stays on the canvas, in the place it
    /// was made for, until the preview from the grown layer replaces it — it used to be dropped, and the unblurred layer
    /// flashed up in between.
    @Test func growingABlurKeepsThePreviewUpUntilTheNextOne() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Half"))
        let layer = try #require(session.activeLayer)
        session.beginFilter(.gaussianBlur)
        session.updateFilter(FilterSettings(radius: 2), preview: true)
        await session.filterEdit?.previewTask?.value
        let edit = try #require(session.filterEdit)
        let first = try #require(edit.previewImage(for: layer.id))
        let firstPlace = session.displayedTransform(for: layer)
        session.updateFilter(FilterSettings(radius: 12), preview: true)
        #expect(edit.previewImage(for: layer.id) === first, "the last preview stays up while the bigger blur renders")
        #expect(session.displayedTransform(for: layer) == firstPlace, "where it was made for")
        while edit.previewTask != nil { await edit.previewTask?.value }
        let second = try #require(edit.previewImage(for: layer.id))
        #expect(second !== first)
        #expect(session.displayedTransform(for: layer).size.width > firstPlace.size.width, "the grown layer's preview, placed on it")
        session.cancelFilter()
    }

    enum PreviewedEdit: String, CaseIterable { case gaussianBlur, levels, hueSaturation }

    /// A layer with effects shows a filter's or an adjustment's preview on the canvas, with its effects redone around
    /// it. Both canvases used to draw the effects made from the layer's own pixels instead, so the preview never
    /// showed until OK. Until the preview's effects are made, the layer's own stand in where the layer is now, though
    /// it moved after they were made.
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
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 240, height: 160)
        let width = 240, height = 160
        // Where red meets blue, and the shadow below the layer, once it has moved.
        let edge = CGPoint(x: 99.5, y: 40), shadow = CGPoint(x: 100.5, y: 80.5)
        // The canvas as drawn, looked up at a point on the document.
        func drawn(gpu: Bool) throws -> (CGPoint) -> [Double] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            if gpu {
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
                texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            } else {
                let cpu = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                cpu.translateBy(x: 0, y: CGFloat(height)); cpu.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cpu, flipped: true)
                canvas.allowsGPU = false
                canvas.draw(canvas.bounds)
                NSGraphicsContext.restoreGraphicsState()
                bytes = Array(UnsafeBufferPointer(start: try #require(cpu.data).assumingMemoryBound(to: UInt8.self), count: bytes.count))
            }
            return { [bytes] point in
                let at = session.viewport.viewPoint(from: point, documentSize: CGSize(width: 200, height: 120))
                let i = (Int(at.y) * width + Int(at.x)) * 4
                return (0..<3).map { Double(bytes[i + $0]) / 255 }
            }
        }
        func colors(gpu: Bool) throws -> (edge: [Double], shadow: [Double]) {
            let color = try drawn(gpu: gpu)
            return (color(edge), color(shadow))
        }
        let canvases = GPUCanvasRenderer.shared == nil ? [false] : [false, true]
        // The effects are made on a worker: wait for them, as the canvas does.
        for gpu in canvases { _ = try colors(gpu: gpu) }
        for _ in 0..<100 where session.effectsPreviews.rendered(id) == nil { try await Task.sleep(for: .milliseconds(20)) }
        // Moved 40 pixels right, as Shift and the Right Arrow key nudge it with the Move tool.
        for _ in 0..<4 { session.nudgeLayer(dx: 10, dy: 0) }
        for gpu in canvases {
            let before = try colors(gpu: gpu)
            #expect(before.edge[0] > 0.9 && before.edge[2] < 0.1, "gpu \(gpu): the layer's own red \(before.edge)")
            #expect(before.shadow[1] > 0.8, "gpu \(gpu): its shadow \(before.shadow)")
        }
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
        for gpu in canvases {
            let color = try drawn(gpu: gpu)
            let end = color(CGPoint(x: 140, y: 40)), under = color(CGPoint(x: 140, y: 80.5)), was = color(CGPoint(x: 20, y: 40))
            #expect(end[2] > 0.8 && end[0] < 0.2, "\(edit.rawValue), gpu \(gpu): the layer where it is now \(end)")
            #expect(under[1] > 0.8 && under[0] < 0.2, "\(edit.rawValue), gpu \(gpu): its shadow under it \(under)")
            #expect(was[0] < 0.5, "\(edit.rawValue), gpu \(gpu): no red where it was \(was)")
        }
        // The red at the edge is no longer full, and the shadow stays on.
        for gpu in canvases {
            var during = try colors(gpu: gpu)
            for _ in 0..<100 where !(during.edge[0] < 0.75 && during.shadow[1] > 0.8) {
                try await Task.sleep(for: .milliseconds(20))
                during = try colors(gpu: gpu)
            }
            #expect(during.edge[0] < 0.75, "\(edit.rawValue), gpu \(gpu): the preview shows at the edge \(during.edge)")
            #expect(during.shadow[1] > 0.8, "\(edit.rawValue), gpu \(gpu): with the shadow still under it \(during.shadow)")
        }
        // As the setting changes, the effects around the last preview stand in until the new ones are made.
        for step in 2...4 {
            let shown = session.effectsPreviews.rendered(id)?.image
            await preview(Double(step))
            for gpu in canvases {
                let changing = try colors(gpu: gpu)
                #expect(changing.shadow[1] > 0.8, "\(edit.rawValue) step \(step), gpu \(gpu): the shadow doesn't blink off \(changing.shadow)")
            }
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
        for gpu in canvases {
            let after = try colors(gpu: gpu)
            #expect(after.edge[0] > 0.9 && after.edge[2] < 0.1, "\(edit.rawValue), gpu \(gpu): the layer's own red again \(after.edge)")
            #expect(after.shadow[1] > 0.8, "\(edit.rawValue), gpu \(gpu): with its shadow \(after.shadow)")
        }
    }

    /// A filter previews a large layer from a smaller copy. The effects redone around that copy are made smaller with
    /// it, so the shadow stays where it is while the panel is open.
    @Test func previewOfALargeLayerKeepsItsEffectsInPlace() async throws {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 640, height: 80), backingScale: 1, documentSize: nil)
        session.createDocument(width: 2400, height: 240)
        let context = try BrushRaster.context(width: 2400, height: 60, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 60))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Wide"))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 0, y: 20), size: CGSize(width: 2400, height: 60))
        // A hard green drop shadow 100 pixels straight down: from 120 to 180.
        session.document?.layers[index].effects = LayerEffects(shadow: ShadowEffect(distance: 100, blur: 0, green: 1, opacity: 1))
        session.zoom(to: 0.25)
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 80)
        canvas.allowsGPU = false
        // Just inside the shadow's top, and just past its bottom.
        func shadow() throws -> (top: Double, past: Double) {
            let cpu = try #require(CGContext(data: nil, width: 640, height: 80, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            cpu.translateBy(x: 0, y: 80); cpu.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cpu, flipped: true)
            canvas.draw(canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let bytes = try #require(cpu.data).assumingMemoryBound(to: UInt8.self)
            func green(_ y: CGFloat) -> Double {
                let at = session.viewport.viewPoint(from: CGPoint(x: 1200, y: y), documentSize: CGSize(width: 2400, height: 240))
                return Double(bytes[(Int(at.y) * 640 + Int(at.x)) * 4 + 1]) / 255
            }
            return (green(128), green(188))
        }
        _ = try shadow()
        for _ in 0..<100 where session.effectsPreviews.rendered(id) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let before = try shadow()
        #expect(before.top > 0.8 && before.past < 0.5, "the shadow before \(before)")
        session.beginFilter(.gaussianBlur)
        session.updateFilter(FilterSettings(radius: 1), preview: true)
        while let edit = session.filterEdit, edit.previewTask != nil { await edit.previewTask?.value }
        let edit = try #require(session.filterEdit)
        #expect(edit.previewScale < 0.9, "previewed from a smaller copy: \(edit.previewScale)")
        let shown = session.effectsPreviews.rendered(id)?.image
        _ = try shadow()
        for _ in 0..<100 where session.effectsPreviews.rendered(id).map({ $0.image === shown }) ?? true {
            try await Task.sleep(for: .milliseconds(20))
        }
        let during = try shadow()
        #expect(during.top > 0.8 && during.past < 0.5, "the shadow where it was \(during)")
        session.cancelFilter()
    }

    @Test func motionBlurStreaksAlongItsAngleCounterclockwiseFromHorizontal() throws {
        // One opaque white dot in the middle of a transparent image.
        let context = try BrushRaster.context(width: 41, height: 41, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 1, height: 1))
        let dot = try #require(context.makeImage())
        func streak(angle: Double) throws -> (Int, Int) -> Int {
            let settings = FilterSettings(angle: angle, distance: 16)
            let image = try PixelFilter.run(FilterJob(kind: .motionBlur, image: dot, settings: settings, scale: 1,
                                                      selection: nil, mapping: .identity))
            let read = try #require(CGContext(data: nil, width: 41, height: 41, bitsPerComponent: 8, bytesPerRow: 164,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 41, height: 41))
            let bytes = Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 41 * 41 * 4))
            return { x, y in Int(bytes[(y * 41 + x) * 4 + 3]) } // rows top-down
        }
        let horizontal = try streak(angle: 0)
        #expect(horizontal(24, 20) > 0 && horizontal(16, 20) > 0 && horizontal(20, 24) == 0)
        let vertical = try streak(angle: 90)
        #expect(vertical(20, 24) > 0 && vertical(20, 16) > 0 && vertical(24, 20) == 0)
        // 45° runs up-right and down-left on screen, never up-left.
        let diagonal = try streak(angle: 45)
        #expect(diagonal(23, 17) > 0 && diagonal(17, 23) > 0 && diagonal(17, 17) == 0)
    }

    @Test func addNoiseChangesColorButNeverAlphaAndMonochromaticKeepsGrays() throws {
        // Left half opaque mid gray, right half transparent.
        let context = try BrushRaster.context(width: 32, height: 8, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        let gray = try #require(context.makeImage())
        func pixels(_ settings: FilterSettings) throws -> [UInt8] {
            let image = try PixelFilter.run(FilterJob(kind: .addNoise, image: gray, settings: settings, scale: 1,
                                                      selection: nil, mapping: .identity, seed: 7))
            let read = try #require(CGContext(data: nil, width: 32, height: 8, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 8))
            return Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 32 * 8 * 4))
        }
        let offsets = Array(stride(from: 0, to: 32 * 8 * 4, by: 4))
        let opaque = offsets.filter { $0 / 4 % 32 < 16 }, clear = offsets.filter { $0 / 4 % 32 >= 16 }
        let color = try pixels(FilterSettings(amount: 10))
        #expect(try pixels(FilterSettings(amount: 10)) == color) // the same seed gives the same grain
        #expect(opaque.allSatisfy { color[$0 + 3] == 255 && (112...144).contains(Int(color[$0])) })
        #expect(Set(opaque.map { color[$0] }).count > 5)
        #expect(opaque.contains { color[$0] != color[$0 + 1] }) // color noise differs per channel
        #expect(clear.allSatisfy { color[$0] == 0 && color[$0 + 3] == 0 })
        let mono = try pixels(FilterSettings(amount: 10, gaussian: true, monochromatic: true))
        #expect(opaque.allSatisfy { mono[$0] == mono[$0 + 1] && mono[$0 + 1] == mono[$0 + 2] && mono[$0 + 3] == 255 })
    }

    @Test func removeDistortionBendsAboutTheCenterAndOnlyPincushionCorrectionOpensTheCorners() throws {
        // An opaque image with a distinct color in each quadrant.
        let context = try BrushRaster.context(width: 40, height: 30, mask: false)
        for (index, rect) in [CGRect(x: 0, y: 0, width: 20, height: 15), CGRect(x: 20, y: 0, width: 20, height: 15),
                              CGRect(x: 0, y: 15, width: 20, height: 15), CGRect(x: 20, y: 15, width: 20, height: 15)].enumerated() {
            context.setFillColor(CGColor(srgbRed: CGFloat(index) / 3, green: 0.5, blue: 1 - CGFloat(index) / 3, alpha: 1))
            context.fill(rect)
        }
        let source = try #require(context.makeImage())
        func pixels(_ distortion: Double) throws -> [UInt8] {
            let image = try PixelFilter.run(FilterJob(kind: .lensCorrection, image: source, settings: FilterSettings(distortion: distortion),
                                                      scale: 1, selection: nil, mapping: .identity))
            let read = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 160,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 30))
            return Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 40 * 30 * 4))
        }
        func alpha(_ bytes: [UInt8], _ x: Int, _ y: Int) -> UInt8 { bytes[(y * 40 + x) * 4 + 3] }
        let original = try pixels(0)
        #expect(original.count == 40 * 30 * 4 && (0..<(40 * 30)).allSatisfy { original[$0 * 4 + 3] == 255 })
        // Straightening barrel distortion stretches the edges outward: nothing opens up.
        let barrel = try pixels(100)
        #expect(alpha(barrel, 0, 0) == 255 && alpha(barrel, 39, 29) == 255)
        // Straightening pincushion pulls the edges in: the corners turn transparent, the middle stays put.
        let pincushion = try pixels(-100)
        #expect(alpha(pincushion, 0, 0) == 0 && alpha(pincushion, 39, 29) == 0)
        #expect(Array(pincushion[((15 * 40 + 20) * 4)..<((15 * 40 + 20) * 4 + 4)]) == Array(original[((15 * 40 + 20) * 4)..<((15 * 40 + 20) * 4 + 4)]))
    }
}
