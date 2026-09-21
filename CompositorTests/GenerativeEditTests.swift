import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// Stands in for the image service: answers with a flat color, remembers what it was asked, and can be
/// made to wait so a test can change things while a request is under way.
private final class FakeProvider: GenerativeImageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<Data, GenerativeError>]
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var holds: Bool
    private(set) var requests: [GenerativeRequest] = []

    init(_ answers: [Result<Data, GenerativeError>], holds: Bool = false) {
        self.answers = answers
        self.holds = holds
    }
    func generate(_ request: GenerativeRequest, key: String) async throws -> Data {
        if lock.withLock({ holds }) { await withCheckedContinuation { c in lock.withLock { waiting.append(c) } } }
        let answer = lock.withLock { () -> Result<Data, GenerativeError> in
            requests.append(request)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        return try answer.get()
    }
    func verify(key: String) async throws {}
    var isWaiting: Bool { lock.withLock { !waiting.isEmpty } }
    func release() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in holds = false; defer { waiting = [] }; return waiting }
        held.forEach { $0.resume() }
    }
}

/// Serialized: one test shows real panels and runs a display pass.
@MainActor @Suite(.serialized)
struct GenerativeEditTests {
    private let blue = PaletteColor(red: 0, green: 0, blue: 1)
    private let red = PaletteColor(red: 1, green: 0, blue: 0)

    private func flat(_ color: CGColor, width: Int = 64, height: Int = 64) throws -> Data {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try GenerativeRaster.encode(try #require(context.makeImage()), as: .png)
    }
    private var green: CGColor { CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) }

    /// A 100 × 80 canvas with one blue layer, and settings that hold a key and touch nothing real.
    private func makeSession(_ provider: FakeProvider, key: String? = "key", disclosed: Bool = true) async throws -> EditorSession {
        let session = EditorSession()
        let settings = GenerativeSettings(secrets: MemorySecretStore(), provider: provider, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        if let key { try settings.setKey(key) }
        settings.hasAcceptedDisclosure = disclosed
        session.generativeSettings = settings
        session.createDocument(width: 100, height: 80, emptyLayer: true)
        session.setPaletteColor(blue, background: true)
        await session.fillSelection(with: .background)
        return session
    }
    private func select(_ session: EditorSession, _ rect: CGRect) {
        session.applySelection(CGPath(rect: rect, transform: nil), mode: .replace, name: "Select")
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow + x * 4
        return (0..<4).map { Int(bytes[$0]) }
    }
    private func render(_ session: EditorSession) async throws -> CGImage {
        try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
    }
    private func finish(_ session: EditorSession) async { await session.generativeEdit?.task?.value }

    @Test func itNeedsASelectionAndHoldsTheDocumentStillWhileOpen() async throws {
        let session = try await makeSession(FakeProvider([.success(try flat(green))]))
        #expect(!session.canBeginGenerative(.fill) && !session.canBeginGenerative(.expand))
        session.beginGenerative(.fill)
        #expect(session.generativeEdit == nil)
        select(session, CGRect(x: 40, y: 30, width: 20, height: 20))
        #expect(session.canBeginGenerative(.fill) && session.canUndo && session.canStartProjectOperation)
        session.beginGenerative(.fill)
        let edit = try #require(session.generativeEdit)
        #expect(edit.mode == .fill && edit.mask.rect.contains(CGRect(x: 40, y: 30, width: 20, height: 20)))
        #expect(!session.canEditLayers && !session.canUndo && !session.canStartProjectOperation && !session.canAdjustColors && !session.canBeginGenerative(.fill))
        session.selectTool(.brush)
        #expect(session.tool != .brush)
        // A save or a tab switch waiting behind the panel goes ahead once it closes.
        let waited = Task { await session.waitForFileRequest(); return true }
        await Task.yield()
        session.cancelGenerative()
        #expect(await waited.value && session.generativeEdit == nil && session.canEditLayers && session.canUndo)
        #expect(session.selection != nil) // Cancelling leaves the selection as it was.
    }

    @Test func nothingIsSentWithoutAKeyOrBeforeTheUserKnowsWhatIsSent() async throws {
        let provider = FakeProvider([.success(try flat(green))])
        let session = try await makeSession(provider, key: nil, disclosed: false)
        select(session, CGRect(x: 40, y: 30, width: 20, height: 20))
        session.beginGenerative(.fill)
        session.generate()
        let edit = try #require(session.generativeEdit)
        #expect(edit.needsKey && edit.error != nil && !edit.isGenerating)
        try session.generativeSettings.setKey("key")
        session.generate()
        #expect(edit.needsDisclosure && !edit.needsKey && !edit.isGenerating && provider.requests.isEmpty)
        session.acceptGenerativeDisclosure()
        #expect(edit.isGenerating && session.generativeSettings.hasAcceptedDisclosure)
        await finish(session)
        #expect(provider.requests.count == 1 && edit.variations.count == 1 && !edit.isGenerating)
    }

    @Test func theModelSeesThePictureFromTheNewLayersPlaceInTheStack() async throws {
        let provider = FakeProvider([.success(try flat(green))])
        let session = try await makeSession(provider)
        let bottom = try #require(session.activeLayerID)
        // A red layer above the active blue one: it will draw over the new layer, so it is not part of what is sent.
        let context = try BrushRaster.context(width: 100, height: 80, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let cover = try #require(context.makeImage())
        session.insert(ImportedImage(image: cover, thumbnail: cover, name: "Cover"))
        session.selectLayer(bottom)
        select(session, CGRect(x: 40, y: 30, width: 20, height: 20))
        session.beginGenerative(.fill)
        let edit = try #require(session.generativeEdit)
        edit.prompt = "a lamp"
        session.generate()
        await finish(session)
        let request = try #require(provider.requests.first)
        let sent = try await ImageImporter.shared.decode(request.image.data, name: "Sent")
        let sample = try pixel(sent.image, x: sent.image.width / 2, y: sent.image.height / 2)
        #expect(sample[0] < 20 && sample[2] > 235) // Blue, not the red above it.
        #expect(request.prompt.contains("a lamp") && request.hint != nil && request.model == .flash)
        #expect(GenerativeAspectRatio.standard.contains(request.ratio))
        // The preview puts the result directly above the active layer, below the cover.
        let current = try #require(session.document)
        let shown = try #require(edit.previewDocument(from: current))
        #expect(shown.layers.count == 3 && shown.layers[1].id == edit.selectedID && shown.layers[1].name == "a lamp")
        #expect(session.document?.layers.count == 2) // Nothing is in the document yet.
    }

    @Test func keepingAddsOneMaskedLayerAsOneUndoStepAndTouchesNothingOutsideTheSelection() async throws {
        let session = try await makeSession(FakeProvider([.success(try flat(green))]))
        let source = try #require(session.activeLayerID)
        select(session, CGRect(x: 40, y: 30, width: 20, height: 20))
        session.beginGenerative(.fill)
        let revision = session.brushRevision
        session.generate()
        await finish(session)
        #expect(session.brushRevision > revision)
        let steps = session.history.undoCount
        session.keepGenerative()
        #expect(session.generativeEdit == nil && session.history.undoCount == steps + 1 && session.history.undoName == "Generative Fill")
        let layers = try #require(session.document?.layers)
        #expect(layers.count == 2 && layers[0].id == source && session.activeLayerID == layers[1].id && session.selection == nil)
        let mask = try #require(layers[1].mask)
        #expect(LayerMask.isValid(mask.asset.image) && layers[1].size == CGSize(width: mask.asset.image.width, height: mask.asset.image.height))
        let image = try await render(session)
        #expect(try pixel(image, x: 50, y: 40) == [0, 255, 0, 255])   // Generated, inside the selection.
        #expect(try pixel(image, x: 10, y: 10) == [0, 0, 255, 255])   // Untouched outside it.
        #expect(try pixel(image, x: 80, y: 40) == [0, 0, 255, 255])
        #expect(try pixel(image, x: 50, y: 70) == [0, 0, 255, 255])
        session.undo()
        #expect(session.document?.layers.map(\.id) == [source] && session.selection != nil)
        #expect(try pixel(try await render(session), x: 50, y: 40) == [0, 0, 255, 255])
    }

    @Test func variationsArriveTogetherAndOneFailureDoesNotLoseTheRest() async throws {
        let provider = FakeProvider([.success(try flat(green)), .failure(.refused("")), .success(try flat(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)))])
        let session = try await makeSession(provider)
        select(session, CGRect(x: 40, y: 30, width: 20, height: 20))
        session.beginGenerative(.fill)
        let edit = try #require(session.generativeEdit)
        edit.count = 3
        session.generate()
        await finish(session)
        #expect(provider.requests.count == 3 && edit.variations.count == 2 && edit.selectedID == edit.variations[0].id)
        #expect(edit.error?.hasPrefix("1 of 3 did not finish.") == true)
        let revision = session.brushRevision
        session.selectVariation(edit.variations[1].id)
        #expect(edit.selectedID == edit.variations[1].id && session.brushRevision == revision + 1)
        // Generating again adds to what is there and shows the newest.
        edit.count = 1
        session.generate()
        await finish(session)
        #expect(edit.variations.count == 3 && edit.selectedID == edit.variations[2].id)
    }

    @Test func aFailureIsShownInThePanelAndLeavesTheDocumentAlone() async throws {
        let session = try await makeSession(FakeProvider([.failure(.invalidKey)]))
        select(session, CGRect(x: 40, y: 30, width: 20, height: 20))
        session.beginGenerative(.fill)
        session.generate()
        await finish(session)
        let edit = try #require(session.generativeEdit)
        #expect(edit.error == GenerativeError.invalidKey.localizedDescription && edit.variations.isEmpty && !edit.isGenerating)
        let steps = session.history.undoCount
        session.keepGenerative() // Nothing to keep.
        #expect(session.generativeEdit === edit && session.history.undoCount == steps)
    }

    @Test func resultsThatArriveAfterCancellingAreDropped() async throws {
        let provider = FakeProvider([.success(try flat(green))], holds: true)
        let session = try await makeSession(provider)
        select(session, CGRect(x: 40, y: 30, width: 20, height: 20))
        session.beginGenerative(.fill)
        session.generate()
        let edit = try #require(session.generativeEdit)
        let task = try #require(edit.task)
        while !provider.isWaiting { await Task.yield() }
        session.cancelGenerative()
        provider.release()
        await task.value
        #expect(session.generativeEdit == nil && edit.variations.isEmpty && session.document?.layers.count == 1)
    }

    @Test func removeStartsAtOnceAndAsksForTheAreaToBeCleared() async throws {
        let provider = FakeProvider([.success(try flat(green))])
        let session = try await makeSession(provider)
        select(session, CGRect(x: 40, y: 30, width: 20, height: 20))
        session.beginGenerative(.remove)
        #expect(session.generativeEdit?.isGenerating == true)
        await finish(session)
        #expect(provider.requests.first?.prompt.contains("remove what is in the marked area") == true)
        session.keepGenerative()
        #expect(session.history.undoName == "Remove" && session.document?.layers.last?.name == "Remove")
    }

    @Test func expandGrowsTheCanvasAndFillsTheNewAreaAsOneUndoStep() async throws {
        let provider = FakeProvider([.success(try flat(green))])
        let session = try await makeSession(provider)
        let source = try #require(session.activeLayerID)
        session.document?.guides = [CanvasGuide(id: UUID(), axis: .vertical, position: 30)]
        session.selectTool(.crop)
        #expect(!session.canBeginGenerative(.expand)) // The frame is still the canvas.
        session.cropRect = CGRect(x: -20, y: 0, width: 120, height: 80)
        #expect(session.canBeginGenerative(.expand))
        session.beginGenerative(.expand)
        let edit = try #require(session.generativeEdit)
        #expect(edit.bounds == CGRect(x: -20, y: 0, width: 120, height: 80) && edit.mask.rect.minX == -20 && edit.mask.rect.maxX < 40)
        session.generate()
        await finish(session)
        // The picture sent has an empty strip, so it travels as PNG.
        #expect(provider.requests.first?.image.mimeType == "image/png" && provider.requests.first?.prompt.contains("blank area") == true)
        let steps = session.history.undoCount
        session.keepGenerative()
        let document = try #require(session.document)
        #expect(document.width == 120 && document.height == 80 && session.cropRect == nil && session.generativeEdit == nil)
        #expect(session.history.undoCount == steps + 1 && session.history.undoName == "Generative Expand")
        #expect(document.layers.count == 2 && document.layers[0].id == source && document.layers[0].origin == CGPoint(x: 20, y: 0))
        #expect(document.layers[1].origin == .zero && document.guides.first?.position == 50)
        let image = try await render(session)
        #expect(try pixel(image, x: 5, y: 40) == [0, 255, 0, 255])    // The new strip.
        #expect(try pixel(image, x: 70, y: 40) == [0, 0, 255, 255])   // The old picture, moved right and untouched.
        session.undo()
        #expect(session.document?.width == 100 && session.document?.layers.map(\.id) == [source] && session.document?.layers[0].origin == .zero)
    }

    /// The panel is sized once, when it opens: results, an error and the settings sheet must all fit and lay out
    /// inside it without AppKit's constraint pass objecting (see FloatingPanelTests).
    @Test func thePanelAndTheSettingsSheetSurviveALayoutPassWithResultsAndErrors() async throws {
        let session = try await makeSession(FakeProvider([.success(try flat(green)), .failure(.quota)]))
        select(session, CGRect(x: 40, y: 30, width: 20, height: 20))
        session.beginGenerative(.fill)
        let edit = try #require(session.generativeEdit)
        let panel = FloatingPanelController(name: "testGenerativePanel")
        panel.onClose = { session.cancelGenerative() }
        panel.show(title: "Generative Fill", content: GenerativeFillSheet(session: session))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let window = try #require(NSApp.windows.first { $0.identifier == panel.identifier })
        let size = window.frame.size
        #expect(panel.isVisible && size.width > 300 && size.height > 300)
        edit.count = 2
        session.generate()
        await finish(session)
        #expect(edit.variations.count == 1 && edit.error != nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        #expect(window.frame.size == size, "was \(size), now \(window.frame.size)") // Nothing that arrives later changes the panel's size.
        window.performClose(nil)
        #expect(session.generativeEdit == nil && !panel.isVisible)
        let settings = FloatingPanelController(name: "testGenerativeSettingsPanel")
        settings.show(title: "Settings", content: GenerativeSettingsSheet(settings: session.generativeSettings))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        #expect(settings.isVisible)
        settings.close()
    }

    /// Draws the real canvas view and reads a color back at a document position.
    private func shown(_ session: EditorSession, _ view: CanvasView, at point: CGPoint) throws -> [Int] {
        let size = try #require(session.document?.size)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let spot = session.viewport.viewPoint(from: point, documentSize: size)
        let color = try #require(rep.colorAt(x: Int(spot.x * scale), y: Int(spot.y * scale))?.usingColorSpace(.sRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    // The view draws through the display's color profile, so colors come back near, not at, their sRGB values.
    private func isBlue(_ c: [Int]) -> Bool { c[2] > 200 && c[0] < 60 && c[1] < 100 }
    private func isGreen(_ c: [Int]) -> Bool { c[1] > 200 && c[2] < 140 }

    @Test func theCanvasShowsAResultBeforeItIsKeptAndDropsItOnCancel() async throws {
        let session = try await makeSession(FakeProvider([.success(try flat(green))]))
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: CGSize(width: 100, height: 80))
        select(session, CGRect(x: 40, y: 30, width: 20, height: 20))
        session.beginGenerative(.fill)
        #expect(isBlue(try shown(session, view, at: CGPoint(x: 50, y: 40))))
        session.generate()
        await finish(session)
        #expect(session.document?.layers.count == 1) // Shown, not stored.
        #expect(isGreen(try shown(session, view, at: CGPoint(x: 50, y: 40))))
        #expect(isBlue(try shown(session, view, at: CGPoint(x: 10, y: 10))))
        session.cancelGenerative()
        #expect(isBlue(try shown(session, view, at: CGPoint(x: 50, y: 40))))
    }

    @Test func anExpandResultShowsOutsideTheOldCanvas() async throws {
        let session = try await makeSession(FakeProvider([.success(try flat(green))]))
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: CGSize(width: 100, height: 80))
        session.selectTool(.crop)
        session.cropRect = CGRect(x: -20, y: 0, width: 120, height: 80)
        session.beginGenerative(.expand)
        session.generate()
        await finish(session)
        #expect(isGreen(try shown(session, view, at: CGPoint(x: -10, y: 40))))
        #expect(isBlue(try shown(session, view, at: CGPoint(x: 75, y: 40)))) // Clear of the Crop tool's thirds lines.
    }

    @Test func recanvasingMovesThingsExactlyAsCropDoes() async throws {
        let session = try await makeSession(FakeProvider([.success(try flat(green))]))
        session.document?.guides = [CanvasGuide(id: UUID(), axis: .horizontal, position: 10)]
        let document = try #require(session.document)
        let rect = CGRect(x: -15, y: 5, width: 140, height: 60)
        let mine = try #require(document.recanvased(to: rect))
        let snapshot = try #require(session.projectSnapshot())
        let theirs = try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(width: 140, height: 60, contentOffset: CGPoint(x: 15, y: -5)))
        #expect(mine.width == theirs.manifest.width && mine.height == theirs.manifest.height && mine.id == theirs.manifest.documentID)
        #expect(mine.layers.map(\.transform) == theirs.manifest.layers.map(\.transform))
        #expect(mine.guides == theirs.manifest.guides)
        #expect(document.recanvased(to: CGRect(x: 0, y: 0, width: 40_000, height: 10)) == nil)
    }
}
