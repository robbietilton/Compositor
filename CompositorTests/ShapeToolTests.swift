import AppKit
import Testing
@testable import Compositor

@MainActor
struct ShapeToolTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80, emptyLayer: true)
        session.selectTool(.shape)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        return session
    }
    private func drag(_ session: EditorSession, from start: CGPoint, to end: CGPoint, square: Bool = false, fromCenter: Bool = false) {
        session.beginShape(at: start)
        session.dragShape(to: end, square: square, fromCenter: fromCenter)
        session.finishShape()
    }
    /// The flattened document as RGBA bytes, and a reader for one pixel's red and alpha.
    private func pixels(_ session: EditorSession) async throws -> (Int, Int) -> (red: Int, alpha: Int) {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        let width = image.width
        return { x, y in (Int(bytes[(y * width + x) * 4]), Int(bytes[(y * width + x) * 4 + 3])) }
    }

    @Test func rectangleFillsANewLayerWithTheForegroundColorAsOneUndoStep() async throws {
        let session = makeSession()
        session.selectAll()
        let count = session.history.undoCount
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        let document = try #require(session.document)
        #expect(document.layers.map(\.name) == ["Layer 1", "Rectangle 1"])
        #expect(session.activeLayer?.name == "Rectangle 1" && session.history.undoCount == count + 1)
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 10, y: 10)
                && session.activeLayer?.transform.size == CGSize(width: 30, height: 20))
        #expect(session.selection != nil) // unlike Paste, drawing a shape keeps the selection
        let pixel = try await pixels(session)
        #expect(pixel(25, 20) == (255, 255) && pixel(10, 10) == (255, 255) && pixel(39, 29) == (255, 255))
        #expect(pixel(9, 20).alpha == 0 && pixel(40, 20).alpha == 0 && pixel(25, 30).alpha == 0)

        drag(session, from: CGPoint(x: 60, y: 10), to: CGPoint(x: 70, y: 20))
        #expect(session.activeLayer?.name == "Rectangle 2")
        session.undo()
        session.undo()
        #expect(session.document?.layers.map(\.name) == ["Layer 1"])
    }

    @Test func ellipseLeavesItsCornersClearWithShiftCircleAndOptionFromCenter() async throws {
        let session = makeSession()
        session.toggleShapeKind()
        #expect(session.shapeKind == .ellipse)
        drag(session, from: CGPoint(x: 50, y: 40), to: CGPoint(x: 60, y: 45), square: true, fromCenter: true)
        #expect(session.activeLayer?.name == "Ellipse 1")
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 40, y: 30)
                && session.activeLayer?.transform.size == CGSize(width: 20, height: 20))
        let pixel = try await pixels(session)
        #expect(pixel(50, 40) == (255, 255) && pixel(41, 40).alpha > 0 && pixel(50, 31).alpha > 0)
        #expect(pixel(40, 30).alpha == 0 && pixel(59, 49).alpha == 0) // outside the circle, inside its box
    }

    @Test func aClickEscapeOrToolSwitchMakesNoLayer() {
        let session = makeSession()
        let count = session.history.undoCount
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.finishShape()
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.dragShape(to: CGPoint(x: 50, y: 50), square: false, fromCenter: false)
        #expect(session.shapeDraft?.rect == CGRect(x: 20, y: 20, width: 30, height: 30))
        session.cancelShape()
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.dragShape(to: CGPoint(x: 50, y: 50), square: false, fromCenter: false)
        session.selectTool(.brush)
        #expect(session.shapeDraft == nil && session.history.undoCount == count)
        #expect(session.document?.layers.count == 1)
    }

    /// A corner radius cuts the rectangle's corners; one larger than half the shorter side makes a pill.
    @Test func roundedRectanglesFollowTheRadiusAndClampToAPill() async throws {
        let session = makeSession()
        session.shapeCornerRadius = 8
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 40)) // 40 × 30
        session.shapeCornerRadius = 500
        drag(session, from: CGPoint(x: 55, y: 50), to: CGPoint(x: 95, y: 70)) // 40 × 20: radius 10
        let pixel = try await pixels(session)
        #expect(pixel(10, 10).alpha == 0, "the corner is cut away")
        #expect(pixel(11, 11).alpha == 0)
        #expect(pixel(13, 13).alpha == 255, "inside the rounded corner")
        #expect(pixel(30, 10).alpha == 255, "straight edges stay full")
        #expect(pixel(30, 25) == (255, 255))
        #expect(pixel(55, 50).alpha == 0, "the pill's corner is round")
        #expect(pixel(75, 60) == (255, 255))
        #expect(session.document?.layers.count == 3)

        session.toggleShapeKind()
        session.beginShape(at: CGPoint(x: 5, y: 5))
        #expect(session.shapeDraft?.cornerRadius == 0, "ellipses take no radius")
        session.cancelShape()
    }

    @Test func shiftUStepsThroughEveryShapeInTheMenuOrder() {
        let session = makeSession()
        var seen: [ShapeKind] = [session.shapeKind]
        for _ in 0..<5 { session.toggleShapeKind(); seen.append(session.shapeKind) }
        #expect(seen == [.rectangle, .ellipse, .star, .polygon, .line, .rectangle])
    }

    /// Both fill a 40 × 40 box point-up; the star's sides dip in between its points where the pentagon's run straight.
    @Test func starsAndPolygonsFillTheirBoxPointUp() async throws {
        let session = makeSession()
        session.shapeKind = .star
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))
        #expect(session.activeLayer?.name == "Star 1" && session.activeLayer?.liveShape?.style.points == 5)
        session.shapeKind = .polygon
        drag(session, from: CGPoint(x: 55, y: 10), to: CGPoint(x: 95, y: 50))
        #expect(session.activeLayer?.name == "Polygon 1" && session.activeLayer?.liveShape?.style.points == 5)
        let pixel = try await pixels(session)
        #expect(pixel(30, 30) == (255, 255) && pixel(75, 30) == (255, 255), "filled at the middle")
        #expect(pixel(30, 11).alpha > 0 && pixel(75, 11).alpha > 0, "the top point touches the top edge")
        #expect(pixel(12, 12).alpha == 0 && pixel(57, 12).alpha == 0, "the box's corners stay clear")
        #expect(pixel(40, 19).alpha == 0, "the star is cut in between its points")
        #expect(pixel(85, 19).alpha == 255, "the pentagon's side runs straight across")
        #expect(pixel(30, 47).alpha == 0, "the star's bottom dips in")
        #expect(pixel(75, 48).alpha == 255, "the pentagon sits on its flat base")
    }

    @Test func pointsAndSidesAreTakenWhenTheDragStarts() {
        let session = makeSession()
        session.shapeKind = .star
        session.shapeStarPoints = 8
        session.shapePolygonSides = 12
        session.beginShape(at: CGPoint(x: 10, y: 10))
        #expect(session.shapeDraft?.points == 8)
        session.shapeStarPoints = 3 // a change mid-drag doesn't reach the shape being drawn
        session.dragShape(to: CGPoint(x: 40, y: 40), square: false, fromCenter: false)
        session.finishShape()
        #expect(session.activeLayer?.liveShape?.style.points == 8)
        session.shapeKind = .polygon
        drag(session, from: CGPoint(x: 50, y: 10), to: CGPoint(x: 90, y: 40))
        #expect(session.activeLayer?.liveShape?.style.points == 12)
        session.shapeKind = .rectangle
        drag(session, from: CGPoint(x: 10, y: 50), to: CGPoint(x: 30, y: 70))
        #expect(session.activeLayer?.liveShape?.style.points == nil)
        session.shapeKind = .polygon
        session.shapePolygonSides = 3
        drag(session, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 90, y: 78))
        #expect(session.activeLayer?.liveShape?.style.points == 3, "polygons go down to a triangle")
    }

    /// Each inner corner sits on the line between the points either side of it, so the edges run straight across.
    @Test func starInnerCornersLineUpWithTheirNeighboringPoints() {
        for points in 5...20 {
            let step = 2 * CGFloat.pi / CGFloat(points)
            // The top point's neighbors, and the inner corner just clockwise of the top.
            let left = CGPoint(x: cos(-.pi / 2 - step), y: sin(-.pi / 2 - step))
            let right = CGPoint(x: cos(-.pi / 2 + step), y: sin(-.pi / 2 + step))
            let reach = ShapeKind.starIndent(points: points), angle = -CGFloat.pi / 2 + step / 2
            let inner = CGPoint(x: cos(angle) * reach, y: sin(angle) * reach)
            let cross = (right.x - left.x) * (inner.y - left.y) - (right.y - left.y) * (inner.x - left.x)
            #expect(abs(cross) < 1e-9, "\(points) points")
        }
        #expect(abs(ShapeKind.starIndent(points: 6) - 0.5 / cos(.pi / 6)) < 1e-9)
        #expect(ShapeKind.starIndent(points: 3) == ShapeKind.starIndent(points: 5))
        #expect(ShapeKind.starIndent(points: 4) == ShapeKind.starIndent(points: 5))
    }

    /// The inset stays even until it is chosen; a chosen one is kept with the star and cuts its points deeper.
    @Test func aChosenInsetIsKeptAndDeepensTheStar() async throws {
        let session = makeSession()
        session.shapeKind = .star
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))
        #expect(session.activeLayer?.liveShape?.style.inset == nil, "an untouched inset stays even")
        session.shapeStarInset = 0.9
        drag(session, from: CGPoint(x: 55, y: 10), to: CGPoint(x: 95, y: 50))
        #expect(session.activeLayer?.liveShape?.style.inset == 0.9)
        let pixel = try await pixels(session)
        // Just below the top point, off to one side: inside an even star, outside a deeply cut one.
        #expect(pixel(32, 26).alpha == 255 && pixel(77, 26).alpha == 0)
        #expect(pixel(30, 31) == (255, 255) && pixel(75, 31) == (255, 255), "both keep a filled middle")

        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.layers.last?.shape?.inset == 0.9)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var deep = snapshot.manifest
        deep.layers[deep.layers.count - 1].shape?.inset = 1.5
        do {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: deep, images: snapshot.images), to: root.appendingPathComponent("Deep.comp"))
            Issue.record("An inset past the center was saved")
        } catch {}
    }

    /// Stars and polygons keep their corner count through a save, and need format version 10.
    @Test func starsRoundTripAndNeedVersionTen() async throws {
        let session = makeSession()
        session.shapeKind = .star
        session.shapeStarPoints = 7
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Star.comp")
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == 10)
        let shape = try #require(loaded.manifest.layers.last?.shape)
        #expect(shape.kind == .star && shape.points == 7)

        var older = snapshot.manifest
        older.version = 9
        do {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: root.appendingPathComponent("Old.comp"))
            Issue.record("A star was saved as version 9")
        } catch {}
        var tooMany = snapshot.manifest
        tooMany.layers[tooMany.layers.count - 1].shape?.points = 21
        do {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: tooMany, images: snapshot.images), to: root.appendingPathComponent("Many.comp"))
            Issue.record("A 21-point star was saved")
        } catch {}
    }

    /// Dashes are measured in line widths, caps included: a width-4 dashed line is 12 pixels on, 8 off.
    @Test func dashedLinesBreakWhereThePatternSays() async throws {
        let session = makeSession()
        session.shapeKind = .line
        session.shapeLineWidth = 4
        drag(session, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 90, y: 20))
        #expect(session.activeLayer?.liveShape?.style.lineStyle == nil, "a solid line saves as lines always have")
        session.shapeLineStyle = .dashed
        drag(session, from: CGPoint(x: 10, y: 50), to: CGPoint(x: 90, y: 50))
        #expect(session.activeLayer?.liveShape?.style.lineStyle == .dashed)
        let pixel = try await pixels(session)
        #expect(pixel(24, 20).alpha == 255, "solid all the way")
        #expect(pixel(14, 50).alpha == 255 && pixel(24, 50).alpha == 0 && pixel(34, 50).alpha == 255)
    }

    /// A square cap fills the corners a round one leaves clear, and its layer grows to hold them at an angle.
    @Test func squareCapsReachTheirCorners() async throws {
        let session = makeSession()
        session.shapeKind = .line
        session.shapeLineWidth = 10
        drag(session, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 20))
        session.shapeLineCap = .square
        drag(session, from: CGPoint(x: 10, y: 50), to: CGPoint(x: 50, y: 50))
        #expect(session.activeLayer?.liveShape?.style.lineCap == .square)
        let pixel = try await pixels(session)
        #expect(pixel(5, 15).alpha == 0 && pixel(5, 45).alpha == 255, "only the square cap fills the corner")
        #expect(pixel(54, 24).alpha == 0 && pixel(54, 54).alpha == 255)

        drag(session, from: CGPoint(x: 60, y: 10), to: CGPoint(x: 80, y: 30))
        let reach = (5 * CGFloat(2).squareRoot()).rounded(.up)
        let size = try #require(session.activeLayer?.transform.size)
        #expect(abs(size.width - (20 + reach * 2)) < 0.001 && abs(size.height - (20 + reach * 2)) < 0.001)
    }

    @Test func lineStylesBelongToVersionTenLines() {
        var line = LayerShapeStyle(kind: .line, red: 0, green: 0, blue: 0, cornerRadius: 0, lineWidth: 4)
        #expect(line.isValid(version: 9))
        line.lineStyle = .dotted
        line.lineCap = .square
        #expect(line.isValid(version: 10) && !line.isValid(version: 9))
        var rectangle = LayerShapeStyle(kind: .rectangle, red: 0, green: 0, blue: 0, cornerRadius: 0)
        rectangle.lineCap = .square
        #expect(!rectangle.isValid(version: 10))
    }
}
