import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct BrushTests {
    private func makeSession(width: Int = 600, height: Int = 80) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 20, hardness: 1, red: 1, green: 0, blue: 0)
        return session
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        // Convert to a fixed byte order instead of relying on native bitmap storage.
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }
    private func render(_ session: EditorSession) async throws -> CGImage {
        try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
    }
    private func preview(_ stroke: BrushStroke, canvas: CGSize) throws -> CGImage {
        let context = try BrushRaster.context(width: Int(canvas.width), height: Int(canvas.height), mask: false)
        LayerRenderer.drawBrushPreview(stroke.layer.asset?.image, transform: stroke.paintTransform, center: stroke.paintTransform.center,
            scale: 1, opacity: stroke.layer.opacity, blendMode: stroke.layer.blendMode, mask: stroke.layer.mask?.enabledImage,
            patches: stroke.patches, pixelWidth: stroke.width, pixelHeight: stroke.height, paintingMask: stroke.isMask, sourceRect: stroke.sourceRect, in: context)
        return try #require(context.makeImage())
    }
    /// The brush's size and hardness keys work wherever focus sits in the editor window — the
    /// Layers panel, a header control, nothing at all — but never while typing in a text field.
    @Test func bracketKeysReachTheBrushWhereverFocusIsExceptTextFields() throws {
        let session = makeSession()
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        let host = NSHostingView(rootView: LayersPanel(session: session))
        host.frame = CGRect(x: 400, y: 0, width: 252, height: 600)
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 22))
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 652, height: 600))
        for view in [canvas, host, field] { content.addSubview(view) }
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        // Layout alone builds the table; spinning the run loop here stalls timing tests running alongside.
        host.layoutSubtreeIfNeeded()
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(table(in: host))
        // Through NSApplication, as a real key press arrives: menus, monitors, then the focused view.
        func press(_ key: String) {
            let shifted = key == "{" || key == "}"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shifted ? .shift : [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "[" || key == "{" ? 33 : 30)!
            NSApp.sendEvent(event)
        }
        for responder in [list, nil] as [NSResponder?] {
            #expect(window.makeFirstResponder(responder))
            session.brushSettings.diameter = 20
            session.brushSettings.hardness = 0.5
            press("]")
            #expect(session.brushSettings.diameter > 20)
            press("[")
            press("[")
            #expect(session.brushSettings.diameter < 20)
            press("}")
            #expect(session.brushSettings.hardness == 0.75)
            press("{")
            press("{")
            #expect(session.brushSettings.hardness == 0.25)
        }
        // Typing in a text field keeps its brackets.
        #expect(window.makeFirstResponder(field))
        let diameter = session.brushSettings.diameter
        press("]")
        #expect(session.brushSettings.diameter == diameter)
        // Other tools leave the brush alone.
        #expect(window.makeFirstResponder(list))
        session.selectTool(.move)
        press("]")
        #expect(session.brushSettings.diameter == diameter)
    }
    @Test func layerTableHandlesPhysicalBrushBracketsWithoutCanvasMonitor() throws {
        let session = makeSession()
        let host = NSHostingView(rootView: LayersPanel(session: session))
        host.frame = CGRect(x: 0, y: 0, width: 252, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(table(in: host))
        #expect(window.makeFirstResponder(list))
        func press(_ keyCode: CGKeyCode, shift: Bool) throws {
            let source = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
            source.flags = shift ? .maskShift : []
            list.keyDown(with: try #require(NSEvent(cgEvent: source)))
        }
        session.brushSettings.diameter = 20
        session.brushSettings.hardness = 0.5
        try press(30, shift: false)
        #expect(session.brushSettings.diameter > 20)
        try press(30, shift: true)
        #expect(session.brushSettings.hardness == 0.75)
    }
    /// Shift-[ and Shift-] reach the canvas as real key events (characters { and }) and step hardness.
    @Test func shiftBracketsStepHardnessFromTheCanvas() throws {
        #expect(BrushSettings().hardness == 1)
        let session = makeSession()
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        #expect(window.makeFirstResponder(view))
        func press(_ key: CGKeyCode, shift: Bool) throws {
            let source = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
            source.flags = shift ? .maskShift : []
            view.keyDown(with: try #require(NSEvent(cgEvent: source)))
        }
        session.brushSettings.hardness = 0.5
        try press(30, shift: true) // Shift-]
        #expect(session.brushSettings.hardness == 0.75)
        try press(33, shift: true) // Shift-[
        try press(33, shift: true)
        #expect(session.brushSettings.hardness == 0.25)
        let diameter = session.brushSettings.diameter
        try press(30, shift: false) // ] alone still sizes the brush
        #expect(session.brushSettings.diameter > diameter && session.brushSettings.hardness == 0.25)
    }
    @Test func continuousStrokeCrossesTilesAndCommitsOneUndo() async throws {
        let session = makeSession()
        let count = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 20, y: 40))
        session.continueBrush(at: CGPoint(x: 580, y: 40))
        let stroke = try #require(session.brushStroke)
        #expect(stroke.patches.count == 3)
        #expect(session.activeLayer?.asset == nil && session.history.undoCount == count)
        let live = try preview(stroke, canvas: session.document!.size)
        for x in [20, 255, 256, 511, 512, 579] { #expect(try pixel(live, x: x, y: 40) == [255, 0, 0, 255]) }
        await session.finishBrush()
        #expect(session.brushError == nil && session.brushStroke == nil)
        #expect(session.history.undoCount == count + 1)
        let result = try await render(session)
        for x in [20, 255, 256, 511, 512, 579] { #expect(try pixel(result, x: x, y: 40) == [255, 0, 0, 255]) }
        #expect(try pixel(result, x: 300, y: 0)[3] == 0)
        session.undo()
        #expect(session.activeLayer?.asset == nil)
        session.redo()
        #expect(session.activeLayer?.asset != nil)
    }
    @Test func softBrushProducesPartialAlphaAndCancelPreservesDocument() async throws {
        let session = makeSession(width: 80, height: 80)
        session.brushSettings.diameter = 40
        session.brushSettings.hardness = 0
        let before = session.document
        session.beginBrush(at: CGPoint(x: 40, y: 40))
        let live = try preview(try #require(session.brushStroke), canvas: session.document!.size)
        #expect(try pixel(live, x: 40, y: 40)[3] > 230)
        // 0% hardness feathers along a Gaussian across the whole radius: about half
        // strength at half radius, faint near the rim, nothing beyond it.
        let half = try pixel(live, x: 50, y: 40)[3]
        #expect(half > 95 && half < 140)
        #expect(try pixel(live, x: 57, y: 40)[3] < 40)
        #expect(try pixel(live, x: 64, y: 40)[3] == 0)
        session.cancelBrush()
        #expect(session.document == before)
        session.beginBrush(at: CGPoint(x: -100, y: -100))
        await session.finishBrush()
        #expect(session.document == before)
    }
    @Test func softMaskPaintingPreviewMatchesCommitAndPersists() async throws {
        let session = makeSession(width: 80, height: 80)
        session.brushSettings.diameter = 200
        session.beginBrush(at: CGPoint(x: 40, y: 40))
        await session.finishBrush()
        let source = try #require(session.activeLayer?.asset?.image)
        session.addLayerMask()
        session.brushSettings.diameter = 40
        session.brushSettings.hardness = 0
        session.beginBrush(at: CGPoint(x: 40, y: 40))
        let live = try preview(try #require(session.brushStroke), canvas: session.document!.size)
        await session.finishBrush()
        let result = try await render(session)
        for x in [10, 40, 54, 70] {
            let expected = try pixel(live, x: x, y: 40)[3]
            #expect(abs(try pixel(result, x: x, y: 40)[3] - expected) <= 1)
        }
        #expect(try pixel(result, x: 40, y: 40)[3] < 25)
        #expect(session.activeLayer?.asset?.image === source)
        #expect(session.activeLayer?.mask?.asset.image.width == 80)
        session.maskPaintWhite = true
        session.brushSettings.hardness = 1
        session.beginBrush(at: CGPoint(x: 40, y: 40))
        await session.finishBrush()
        #expect(try pixel(try await render(session), x: 40, y: 40)[3] == 255)
        session.undo()
        #expect(session.isMaskSelected)
        #expect(try pixel(try await render(session), x: 40, y: 40)[3] < 25)
        session.redo()
        #expect(session.isMaskSelected)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Brush-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = try await ImageExporter.shared.render(loaded)
        #expect(try pixel(reopened.image, x: 40, y: 40)[3] == 255)
    }
    @Test func brushStaysCircularOnNonuniformRotatedFlippedLayer() async throws {
        let session = makeSession(width: 100, height: 100)
        // Establish raster dimensions independently of transformed display dimensions.
        let sourceContext = try BrushRaster.context(width: 100, height: 100, mask: false)
        sourceContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        sourceContext.fill(CGRect(x: 2, y: 2, width: 6, height: 6))
        let sourceImage = try #require(sourceContext.makeImage())
        let sourceLayer = try #require(session.activeLayer)
        session.document?.layers[0] = ImageLayer(id: sourceLayer.id,
            asset: ImportedImage(image: sourceImage, thumbnail: sourceImage, name: "Fixture"),
            name: sourceLayer.name, isVisible: true, transform: sourceLayer.transform)
        session.document?.layers[0].transform = LayerTransform(origin: CGPoint(x: 25, y: -50),
            size: CGSize(width: 50, height: 200), rotation: 90, flipX: true, flipY: true, sampling: .nearest)
        session.brushSettings = BrushSettings(diameter: 16, hardness: 1, red: 0, green: 1, blue: 0)
        session.beginBrush(at: CGPoint(x: 50, y: 50))
        let live = try preview(try #require(session.brushStroke), canvas: session.document!.size)
        await session.finishBrush()
        let result = try await render(session)
        for (x, y) in [(50, 50), (54, 50), (50, 54)] {
            #expect(try pixel(result, x: x, y: y)[1] > 240)
            #expect(try pixel(live, x: x, y: y)[1] > 240)
        }
        for (x, y) in [(61, 50), (50, 61)] { #expect(try pixel(result, x: x, y: y)[3] == 0) }
    }
    @Test func maskedImagePaintingUsesCoverageAndOpacityOnlyOnce() async throws {
        let session = makeSession(width: 520, height: 40)
        session.addLayerMask()
        session.document?.layers[0].mask = LayerMask(asset: try gray(128))
        session.isMaskSelected = false
        session.setLayerOpacity(0.5)
        session.beginBrush(at: CGPoint(x: 240, y: 20))
        session.continueBrush(at: CGPoint(x: 280, y: 20))
        let live = try preview(try #require(session.brushStroke), canvas: session.document!.size)
        await session.finishBrush()
        let result = try await render(session)
        for x in [250, 255, 256, 260] {
            #expect(abs(try pixel(live, x: x, y: 20)[3] - 64) <= 1)
            #expect(abs(try pixel(result, x: x, y: 20)[3] - 64) <= 1)
        }
    }
    @Test func importedImageLayerExpandsAcrossCanvasWithoutMovingImageOrMask() async throws {
        for rotation: CGFloat in [0, 37, 90] {
            let session = makeSession(width: 600, height: 200)
            let context = try BrushRaster.context(width: 40, height: 20, mask: false)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            let image = try #require(context.makeImage())
            session.insert(ImportedImage(image: image, thumbnail: image, name: "Imported"))
            let index = try #require(session.document?.layers.indices.last)
            session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 240, y: 80),
                size: CGSize(width: 80, height: 40), rotation: rotation, flipX: true, sampling: .nearest)
            session.document?.layers[index].mask = LayerMask(asset: try gray(128))
            let original = session.document
            session.brushSettings = BrushSettings(diameter: 16, hardness: 1, red: 0, green: 1, blue: 0)
            session.beginBrush(at: CGPoint(x: 12, y: 12))
            session.continueBrush(at: CGPoint(x: 580, y: 12))
            let live = try preview(try #require(session.brushStroke), canvas: session.document!.size)
            #expect(try pixel(live, x: 12, y: 12)[1] > 240)
            #expect(try pixel(live, x: 580, y: 12)[1] > 240)
            await session.finishBrush()
            #expect(session.brushError == nil)
            let result = try await render(session)
            #expect(try pixel(result, x: 12, y: 12)[1] > 240)
            #expect(try pixel(result, x: 580, y: 12)[1] > 240)
            let center = try pixel(result, x: 280, y: 100)
            #expect(abs(center[0] - 128) <= 1 && abs(center[3] - 128) <= 1)
            #expect(session.activeLayer?.transform.rotation == rotation && session.activeLayer?.transform.flipX == true)
            session.undo()
            #expect(session.document == original)
            session.redo()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ExpandedBrush-\(UUID()).comp")
            defer { try? FileManager.default.removeItem(at: url) }
            try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
            let loaded = try await ProjectStore.shared.load(from: url)
            let reopened = try await ImageExporter.shared.render(loaded)
            #expect(try pixel(reopened.image, x: 12, y: 12)[1] > 240)
        }
    }
    @Test func paintedBoundsTrimTilePaddingAndKeepSoftEdges() async throws {
        for hardness: CGFloat in [0, 1] {
            let session = makeSession(width: 600, height: 200)
            session.brushSettings.hardness = hardness
            session.beginBrush(at: CGPoint(x: 300, y: 100))
            let live = try preview(try #require(session.brushStroke), canvas: session.document!.size)
            await session.finishBrush()
            let layer = try #require(session.activeLayer)
            let image = try #require(layer.asset?.image)
            #expect(image.width <= 20 && image.height <= 20)
            #expect(layer.transform.origin.x >= 290 && layer.transform.origin.y >= 90)
            let top = try (0..<image.width).map { try pixel(image, x: $0, y: 0)[3] }
            let bottom = try (0..<image.width).map { try pixel(image, x: $0, y: image.height - 1)[3] }
            let left = try (0..<image.height).map { try pixel(image, x: 0, y: $0)[3] }
            let right = try (0..<image.height).map { try pixel(image, x: image.width - 1, y: $0)[3] }
            #expect([top, bottom, left, right].allSatisfy { $0.contains { $0 > 0 } })
            let result = try await render(session)
            for x in 288...312 { #expect(try pixel(result, x: x, y: 100) == pixel(live, x: x, y: 100)) }
            session.undo()
            #expect(session.activeLayer?.asset == nil)
            session.redo()
            #expect(session.activeLayer?.transform == layer.transform)
        }
    }
    private func gray(_ value: UInt8) throws -> ImportedImage {
        let provider = try #require(CGDataProvider(data: Data([value]) as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try LayerMask.asset(from: image)
    }
    @Test func opacityCapsTheWholeStrokeEvenWhereItOverlapsItself() async throws {
        let session = makeSession(width: 200, height: 80)
        session.brushSettings.opacity = 0.5
        // Back and forth over the same pixels many times.
        session.beginBrush(at: CGPoint(x: 20, y: 40))
        for x in [180, 20, 180, 20, 100] { session.continueBrush(at: CGPoint(x: CGFloat(x), y: 40)) }
        let live = try preview(try #require(session.brushStroke), canvas: session.document!.size)
        let preview = try pixel(live, x: 100, y: 40)
        #expect(abs(preview[3] - 128) <= 1 && abs(preview[0] - 128) <= 1 && preview[1] == 0)
        await session.finishBrush()
        let result = try await render(session)
        #expect(try pixel(result, x: 100, y: 40) == preview)
        #expect(try pixel(result, x: 100, y: 0)[3] == 0)
    }
    @Test func softStrokeBuildsCoverageWhileKeepingItsFeatheredRim() throws {
        let session = makeSession(width: 200, height: 80)
        session.brushSettings.diameter = 40
        session.brushSettings.hardness = 0
        session.beginBrush(at: CGPoint(x: 100, y: 40))
        let single = try pixel(try preview(try #require(session.brushStroke), canvas: session.document!.size), x: 100, y: 50)[3]
        session.cancelBrush()
        session.beginBrush(at: CGPoint(x: 20, y: 40))
        session.continueBrush(at: CGPoint(x: 180, y: 40))
        let stroke = try pixel(try preview(try #require(session.brushStroke), canvas: session.document!.size), x: 100, y: 50)[3]
        #expect(stroke > single + 60)
        #expect(stroke <= 255)
        session.cancelBrush()
    }
    /// Dabs are spaced apart to keep wide brushes fast, which is only safe while the stroke
    /// still reads as solid: too far apart and it visibly beads along its length.
    @Test func spacedDabsLeaveNoVisibleRippleAlongTheStroke() throws {
        for hardness in [0.0, 0.5, 1.0] {
            let session = makeSession(width: 900, height: 300)
            session.brushSettings.diameter = 120
            session.brushSettings.hardness = hardness
            session.beginBrush(at: CGPoint(x: 100, y: 150))
            session.continueBrush(at: CGPoint(x: 800, y: 150))
            let image = try preview(try #require(session.brushStroke), canvas: session.document!.size)
            // Along the middle of the stroke, and again nearer its edge.
            for offset in [0, 30, 50] {
                let run = try (300...600).map { try pixel(image, x: $0, y: 150 + offset)[3] }
                let ripple = (run.max() ?? 0) - (run.min() ?? 0)
                #expect(ripple <= 16, "hardness \(hardness) offset \(offset) rippled by \(ripple)")
            }
            session.cancelBrush()
        }
    }
    @Test func sparseMouseSamplesFollowACurveInsteadOfStraightChords() async throws {
        let session = makeSession(width: 300, height: 300)
        session.brushSettings.diameter = 4
        let center = CGPoint(x: 150, y: 150), radius: CGFloat = 100
        func onCircle(_ degrees: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(degrees * .pi / 180) * radius, y: center.y + sin(degrees * .pi / 180) * radius)
        }
        session.beginBrush(at: onCircle(0))
        for degrees in stride(from: 30, through: 180, by: 30) { session.continueBrush(at: onCircle(CGFloat(degrees))) }
        await session.finishBrush()
        let result = try await render(session)
        // A straight chord between 30° and 60° passes 3.4 px inside the arc, farther than
        // this 2 px brush reaches; the curve passes through the arc itself.
        for degrees: CGFloat in [45, 75, 105, 135] {
            let point = onCircle(degrees)
            #expect(try pixel(result, x: Int(point.x), y: Int(point.y))[3] > 0, "arc at \(degrees)°")
        }
    }
    @Test func liveStrokeReachesNewestSampleAndTailIsReplacedExactly() async throws {
        let session = makeSession(width: 300, height: 120)
        session.brushSettings.diameter = 8
        session.beginBrush(at: CGPoint(x: 20, y: 60))
        session.continueBrush(at: CGPoint(x: 150, y: 20))
        session.continueBrush(at: CGPoint(x: 280, y: 60))
        let stroke = try #require(session.brushStroke)
        // No lag: the provisional tail already reaches the cursor.
        #expect(try pixel(try preview(stroke, canvas: session.document!.size), x: 278, y: 60)[3] == 255)
        await session.finishBrush()
        // The committed stroke is the smooth curve; the straight tail left nothing behind.
        let result = try await render(session)
        let chordMidpoint = try pixel(result, x: 215, y: 40)[3]
        #expect(chordMidpoint == 0)
        #expect(try pixel(result, x: 278, y: 60)[3] == 255)
    }
    @Test func opacityAppliesToMaskPainting() async throws {
        let session = makeSession(width: 80, height: 80)
        session.brushSettings.diameter = 200
        session.beginBrush(at: CGPoint(x: 40, y: 40))
        session.continueBrush(at: CGPoint(x: 41, y: 40))
        await session.finishBrush() // Opaque red layer over the whole canvas.
        session.addLayerMask(revealing: true)
        session.selectLayerTarget(try #require(session.activeLayerID), mask: true)
        session.brushSettings.diameter = 20
        session.brushSettings.opacity = 0.5
        session.maskPaintWhite = false
        session.beginBrush(at: CGPoint(x: 40, y: 40))
        session.continueBrush(at: CGPoint(x: 42, y: 40))
        await session.finishBrush()
        let result = try await render(session)
        #expect(abs(try pixel(result, x: 40, y: 40)[3] - 128) <= 1)
        #expect(try pixel(result, x: 5, y: 5)[3] == 255)
    }
    @Test func shiftBracketsStepHardnessByQuarters() {
        let session = makeSession()
        session.brushSettings.hardness = 0.8
        session.changeBrushHardness(increase: true)
        #expect(session.brushSettings.hardness == 1)
        session.changeBrushHardness(increase: true)
        #expect(session.brushSettings.hardness == 1)
        session.brushSettings.hardness = 0.8
        session.changeBrushHardness(increase: false)
        #expect(session.brushSettings.hardness == 0.75)
        for _ in 0..<5 { session.changeBrushHardness(increase: false) }
        #expect(session.brushSettings.hardness == 0)
        session.changeBrushHardness(increase: true)
        #expect(session.brushSettings.hardness == 0.25)
    }
    @Test func numberKeysSetBrushAndGradientOpacity() {
        let session = makeSession()
        session.typeOpacityDigit(5, at: 10)
        #expect(session.brushSettings.opacity == 0.5)
        session.typeOpacityDigit(0, at: 20)
        #expect(session.brushSettings.opacity == 1)
        session.typeOpacityDigit(4, at: 30)
        session.typeOpacityDigit(5, at: 30.3)
        #expect(session.brushSettings.opacity == 0.45)
        session.typeOpacityDigit(0, at: 40)
        session.typeOpacityDigit(5, at: 40.2)
        #expect(session.brushSettings.opacity == 0.05)
        session.selectTool(.gradient)
        session.typeOpacityDigit(1, at: 50)
        #expect(session.gradientSettings.opacity == 0.1 && session.brushSettings.opacity == 0.05)
        session.selectTool(.move)
        session.typeOpacityDigit(3, at: 60)
        #expect(session.gradientSettings.opacity == 0.1)
    }
    @Test func largeBlankCanvasOnlyAllocatesTouchedTilesUntilCommit() throws {
        let session = makeSession(width: 10_000, height: 10_000)
        session.beginBrush(at: CGPoint(x: 100, y: 100))
        let patches = try #require(session.brushStroke).patches
        #expect(patches.count == 1)
        #expect(patches.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height } <= 256 * 256 * 4)
        #expect(session.activeLayer?.asset == nil)
        session.cancelBrush()
    }
    @Test func foldersHiddenLayersAndDisabledMasksRejectPainting() throws {
        let session = makeSession()
        session.addGroup()
        session.beginBrush(at: CGPoint(x: 10, y: 10))
        #expect(session.brushStroke == nil)
        session.selectLayer(session.document?.layers.first?.id)
        session.toggleLayerVisibility(try #require(session.activeLayerID))
        #expect(!session.canPaint)
        session.toggleLayerVisibility(try #require(session.activeLayerID))
        session.addLayerMask()
        session.toggleLayerMask()
        #expect(!session.canPaint)
    }
}
