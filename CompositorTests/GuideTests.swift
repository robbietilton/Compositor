import AppKit
import Testing
@testable import Compositor

@MainActor
struct GuideTests {
    private func paintedSession(width: Int = 400, height: Int = 300, layerSize: CGSize = CGSize(width: 100, height: 60)) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        let context = try BrushRaster.context(width: Int(layerSize.width), height: Int(layerSize.height), mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: layerSize))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        return session
    }

    @Test func newGuidesUndoAndClear() {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        let vertical = CanvasGuide(id: UUID(), axis: .vertical, position: 40)
        let horizontal = CanvasGuide(id: UUID(), axis: .horizontal, position: 25)
        session.addGuide(vertical)
        session.addGuide(horizontal)
        #expect(session.document?.guides.count == 2)
        #expect(session.canClearGuides)
        session.undo()
        #expect(session.document?.guides == [vertical])
        session.clearGuides()
        #expect(session.document?.guides.isEmpty == true)
        session.undo()
        #expect(session.document?.guides == [vertical])
    }

    @Test func lockPreventsCreatingAndMoving() {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        session.locksGuides = true
        session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 10))
        #expect(session.document?.guides.isEmpty == true)
        session.locksGuides = false
        let guide = CanvasGuide(id: UUID(), axis: .vertical, position: 10)
        session.addGuide(guide)
        session.locksGuides = true
        session.beginGuideMove(guide)
        #expect(session.guideDrag == nil)
        session.clearGuides()
        #expect(session.document?.guides.isEmpty == true, "Clear Guides still works while locked")
    }

    @Test func projectRoundTripAndLegacyRejection() async throws {
        let session = EditorSession()
        session.createDocument(width: 80, height: 40)
        let vertical = CanvasGuide(id: UUID(), axis: .vertical, position: 16)
        let horizontal = CanvasGuide(id: UUID(), axis: .horizontal, position: 12)
        session.addGuide(vertical)
        session.addGuide(horizontal)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 9)
        #expect(snapshot.manifest.guides == [vertical, horizontal])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Guides-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.document?.guides == [vertical, horizontal])

        var legacy = snapshot.manifest
        legacy.version = 7
        try JSONEncoder().encode(legacy).write(to: url.appendingPathComponent("manifest.json"))
        do {
            _ = try await ProjectStore.shared.load(from: url)
            Issue.record("Version 7 with guides should be rejected")
        } catch ProjectError.invalid {}
    }

    @Test func canvasAndImageSizeMoveGuides() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 50)
        session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 20))
        session.addGuide(CanvasGuide(id: UUID(), axis: .horizontal, position: 10))
        let source = try #require(session.projectSnapshot())
        let expanded = try await CanvasResizer.shared.resize(source, to: CanvasSizeOptions(width: 140, height: 80, anchor: 8))
        // Anchor 8 is bottom-right: extra pixels on the left and top.
        #expect(expanded.manifest.guides?.first { $0.axis == .vertical }?.position == 60)
        #expect(expanded.manifest.guides?.first { $0.axis == .horizontal }?.position == 40)
        let scaled = try await ImageResizer.shared.resize(source, to: ImageSizeOptions(width: 200, height: 100, resolution: 72))
        #expect(scaled.manifest.guides?.first { $0.axis == .vertical }?.position == 40)
        #expect(scaled.manifest.guides?.first { $0.axis == .horizontal }?.position == 20)
    }

    @Test func flipCanvasMirrorsGuides() {
        let session = EditorSession()
        session.createDocument(width: 100, height: 40)
        session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 20))
        session.addGuide(CanvasGuide(id: UUID(), axis: .horizontal, position: 10))
        session.flipCanvas(horizontally: true)
        #expect(session.document?.guides.first { $0.axis == .vertical }?.position == 80)
        #expect(session.document?.guides.first { $0.axis == .horizontal }?.position == 10)
        session.flipCanvas(horizontally: false)
        #expect(session.document?.guides.first { $0.axis == .vertical }?.position == 80)
        #expect(session.document?.guides.first { $0.axis == .horizontal }?.position == 30)
    }

    @Test func snapTargetsFollowViewMenu() throws {
        let session = try paintedSession()
        // Default: canvas bounds and the centered 100×60 layer (150–250 × 120–180).
        let crop = session.cropSnapTargets()
        #expect(Set(crop.xs) == Set<CGFloat>([0, 400, 150, 250]))
        #expect(Set(crop.ys) == Set<CGFloat>([0, 300, 120, 180]))
        let move = session.transformSnapTargets(excluding: [])
        #expect(Set(move.xs).isSuperset(of: [0, 200, 400, 150, 200, 250]))
        session.snapEnabled = false
        #expect(session.cropSnapTargets().xs.isEmpty && session.cropSnapTargets().ys.isEmpty)
        session.snapEnabled = true
        session.snapToLayers = false
        #expect(Set(session.cropSnapTargets().xs) == Set<CGFloat>([0, 400]))
        session.snapToDocumentBounds = false
        #expect(session.cropSnapTargets().xs.isEmpty)
        session.snapToGuides = true
        session.showsGuides = true
        session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 33))
        #expect(session.cropSnapTargets().xs == [33])
        session.showsGuides = false
        #expect(session.cropSnapTargets().xs.isEmpty, "hidden extras do not snap")
        session.showsGuides = true
        session.showsGrid = true
        session.snapToGrid = true
        #expect(session.cropSnapTargets().xs.contains(64) && session.cropSnapTargets().xs.contains(8))
    }

    @Test func layoutGridLinesIncludeMajorsAndSubdivisions() {
        let lines = LayoutGrid.lines(along: 64)
        #expect(lines.first == 0 && lines.last == 64)
        #expect(lines.contains(8) && lines.contains(64))
        #expect(LayoutGrid.isMajor(0) && LayoutGrid.isMajor(64) && !LayoutGrid.isMajor(8))
    }

    @Test func moveToolDragsAGuideAndRulerDropDeletesIt() throws {
        let session = try paintedSession()
        let guide = CanvasGuide(id: UUID(), axis: .vertical, position: 40)
        session.addGuide(guide)
        session.showsRulers = true
        session.selectTool(.move)
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: try #require(session.document?.size))
        session.zoom(to: 1)
        view.synchronizeDisplay()
        let size = try #require(session.document?.size)
        func event(_ type: NSEvent.EventType, at pixel: CGPoint) throws -> NSEvent {
            let spot = session.viewport.viewPoint(from: pixel, documentSize: size)
            return try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: spot.x, y: view.bounds.height - spot.y),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 40, y: 20)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 70, y: 20)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 70, y: 20)))
        #expect(session.document?.guides.first?.position == 70)
        #expect(session.guideDrag == nil)
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 70, y: 20)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: -10, y: 20)))
        #expect(session.document?.guides.isEmpty == true, "dropping on the ruler deletes the guide")
    }

    @Test func rulerStepUsesNicePixelIntervals() {
        #expect(CanvasRulerNSView.majorStep(pointsPerPixel: 1) == 100)
        #expect(CanvasRulerNSView.majorStep(pointsPerPixel: 8) == 10)
        #expect(CanvasRulerNSView.label(0) as String == "0")
        #expect(CanvasRulerNSView.label(250) as String == "250")
    }
}
