import CoreGraphics
import Foundation
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

    @Test func smoothingUsesSixtyPercentCornersAndStaysInsideTheBox() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 80)
        let path = ShapeKind.rectangle.path(in: rect, cornerRadius: 20, smoothing: true)
        let ordinary = ShapeKind.rectangle.path(in: rect, cornerRadius: 20)
        let bounds = path.boundingBoxOfPath
        #expect(abs(bounds.minX - rect.minX) < 0.000001 && abs(bounds.minY - rect.minY) < 0.000001)
        #expect(abs(bounds.maxX - rect.maxX) < 0.000001 && abs(bounds.maxY - rect.maxY) < 0.000001)
        // At 60%, the transition reaches 32 px along each edge instead of the circular corner's 20.
        #expect(!path.contains(CGPoint(x: 35, y: 20.01)))
        #expect(ordinary.contains(CGPoint(x: 35, y: 20.01)))
        #expect(path.contains(CGPoint(x: 43, y: 20.01)))
        #expect(path.contains(CGPoint(x: 60, y: 60)))
        #expect(!path.contains(CGPoint(x: 11, y: 21)))
        for x in stride(from: CGFloat(0.5), to: rect.width, by: 2) {
            for y in stride(from: CGFloat(0.5), to: rect.height, by: 2) {
                let inside = path.contains(CGPoint(x: rect.minX + x, y: rect.minY + y))
                #expect(inside == path.contains(CGPoint(x: rect.maxX - x, y: rect.minY + y)))
                #expect(inside == path.contains(CGPoint(x: rect.minX + x, y: rect.maxY - y)))
            }
        }
        #expect(ShapeKind.rectangle.path(in: rect, smoothing: true) == ShapeKind.rectangle.path(in: rect))
        #expect(ShapeKind.rectangle.path(in: rect, cornerRadius: 500, smoothing: true)
                == ShapeKind.rectangle.path(in: rect, cornerRadius: 500))
        #expect(ShapeKind.ellipse.path(in: rect, cornerRadius: 20, smoothing: true)
                == ShapeKind.ellipse.path(in: rect))
    }

    @Test func smoothingSurvivesSavingAndMatchesTheResizePreview() async throws {
        let session = makeSession()
        session.shapeCornerRadius = 10
        session.shapeSmoothing = true
        session.beginShape(at: CGPoint(x: 10, y: 10))
        #expect(session.shapeDraft?.smoothing == true)
        session.shapeSmoothing = false // the draft keeps the choice made at the start of the drag
        session.dragShape(to: CGPoint(x: 70, y: 60), square: false, fromCenter: false)
        session.finishShape()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Smoothing-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.last?.shape?.smoothing == true)
        let reopened = makeSession()
        reopened.installProject(loaded, from: url)
        reopened.beginTransform()
        var transform = try #require(reopened.transformEdit?.draft)
        transform.size = CGSize(width: 80, height: 60)
        let layer = try #require(reopened.activeLayer)
        let preview = try #require(reopened.shapeTransformPreview(for: layer, transform: transform))
        reopened.previewTransform(transform)
        reopened.commitTransform()
        let image = try #require(reopened.activeLayer?.liveShape?.image)
        let reference = try EditorSession.shapeImage(.rectangle, size: transform.size, color: session.foregroundColor,
                                                    cornerRadius: 10, smoothing: true)
        #expect(image.width == 80 && image.height == 60)
        #expect(image.dataProvider?.data == reference.dataProvider?.data)
        #expect(preview.dataProvider?.data == reference.dataProvider?.data)

        let oldStyle = LayerShapeStyle(kind: .rectangle, red: 1, green: 0, blue: 0, cornerRadius: 10)
        let decoded = try JSONDecoder().decode(LayerShapeStyle.self, from: JSONEncoder().encode(oldStyle))
        #expect(decoded.smoothing == nil, "older shapes keep their circular corners")
        var older = snapshot.manifest
        older.version = 13
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
        }
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
        #expect(session.shapeLineCap == .square, "new lines start square-capped")
        session.shapeLineCap = .round
        drag(session, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 20))
        #expect(session.activeLayer?.liveShape?.style.lineCap == nil, "a round cap saves as lines always have")
        session.shapeLineCap = .square
        drag(session, from: CGPoint(x: 10, y: 50), to: CGPoint(x: 50, y: 50))
        #expect(session.activeLayer?.liveShape?.style.lineCap == .square)
        let pixel = try await pixels(session)
        #expect(pixel(5, 15).alpha == 0 && pixel(5, 45).alpha == 255, "only the square cap fills the corner")
        #expect(pixel(54, 24).alpha == 0 && pixel(54, 54).alpha == 255)

        drag(session, from: CGPoint(x: 60, y: 10), to: CGPoint(x: 80, y: 30))
        let reach = 5 + (5 * CGFloat(2).squareRoot() - 5).rounded(.up)
        let size = try #require(session.activeLayer?.transform.size)
        #expect(abs(size.width - (20 + reach * 2)) < 0.001 && abs(size.height - (20 + reach * 2)) < 0.001)
    }

    @Test func lineStylesSurviveSavingAndNeedVersionFifteen() async throws {
        let session = makeSession()
        session.shapeKind = .line
        session.shapeLineStyle = .dotted
        session.shapeLineCap = .square
        drag(session, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 90, y: 20))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LineStyle-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.last?.shape?.lineStyle == .dotted)
        #expect(loaded.manifest.layers.last?.shape?.lineCap == .square)
        var older = snapshot.manifest
        older.version = 14
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
        }
    }

    /// A 1-pixel line stays one full-strength row or column with either cap, in its layer and in the finished image,
    /// as it's drawn while dragging, rather than two half-strength ones.
    @Test(arguments: [ShapeLineCap.square, .round]) func thinLinesStayOnThePixelGrid(cap: ShapeLineCap) async throws {
        let session = makeSession()
        session.shapeKind = .line
        session.shapeLineWidth = 1
        session.shapeLineCap = cap
        drag(session, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 20))
        let origin = try #require(session.activeLayer?.transform.origin)
        #expect(origin.x == origin.x.rounded() && origin.y == origin.y.rounded(), "the layer sits on whole pixels")
        drag(session, from: CGPoint(x: 70, y: 10), to: CGPoint(x: 70, y: 50))
        let pixel = try await pixels(session)
        #expect(pixel(30, 20).alpha == 255 && pixel(30, 19).alpha == 0 && pixel(30, 21).alpha == 0)
        #expect(pixel(70, 30).alpha == 255 && pixel(69, 30).alpha == 0 && pixel(71, 30).alpha == 0)
    }

    /// A 1-pixel dotted line's dots are whole pixels at full strength with square caps, and circles as strong as a
    /// pixel-wide circle gets with round ones, rather than quarter-strength smudges.
    @Test func onePixelDotsKeepTheirColor() throws {
        for cap in ShapeLineCap.allCases {
            let session = makeSession()
            session.shapeKind = .line
            session.shapeLineWidth = 1
            session.shapeLineStyle = .dotted
            session.shapeLineCap = cap
            drag(session, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 60, y: 20))
            let image = try #require(session.activeLayer?.asset?.image)
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            let row = (0..<image.width).map { Int(bytes[$0 * 4 + 3]) }
            let dots = stride(from: 0, to: row.count, by: 2).map { row[$0] }, gaps = stride(from: 1, to: row.count, by: 2).map { row[$0] }
            #expect(dots.allSatisfy { cap == .square ? $0 == 255 : $0 > 150 }, "\(cap)")
            #expect(gaps.allSatisfy { $0 == 0 }, "\(cap)")
        }
    }

    /// Scaling a line stretches it as it looked while being scaled, rather than redrawing it at its old width.
    @Test func aScaledLineStretchesInsteadOfKeepingItsWidth() async throws {
        let session = makeSession()
        session.shapeKind = .line
        session.shapeLineWidth = 4
        drag(session, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 90, y: 20))
        session.beginTransform()
        var transform = try #require(session.transformEdit?.draft)
        transform.size.height *= 3
        session.previewTransform(transform)
        session.commitTransform()
        let layer = try #require(session.activeLayer)
        #expect(layer.liveShape == nil, "plain pixels from then on")
        #expect(layer.transform.size.height == transform.size.height)
        let pixel = try await pixels(session)
        let column = (0..<80).filter { pixel(50, $0).alpha > 127 }
        #expect(column.count >= 10, "about three times the 4-pixel width")
    }
}
