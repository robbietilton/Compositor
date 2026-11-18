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

    @Test func aShapeDrawnWithAFolderSelectedGoesToTheTopOfTheFolder() throws {
        let session = makeSession()
        session.addBlankLayer()
        let layers = try #require(session.document?.layers.map(\.id))
        session.selectLayers(Set(layers), primary: layers.last)
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayer)
        #expect(folder.isGroup)
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        let document = try #require(session.document)
        let inside = document.layers.filter { $0.parentID == folder.id }.map(\.name)
        #expect(inside == ["Layer 1", "Layer 2", "Rectangle 1"])
    }

    @Test func theNextShapeIsTheForegroundColorOrTheFillJustPicked() throws {
        let session = makeSession()
        let red = session.foregroundColor, blue = PaletteColor(red: 0, green: 0, blue: 1)
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        let first = try #require(session.activeLayerID)
        // Swapping colors is for the next shape: the selected one keeps its fill.
        session.swapPaletteColors()
        #expect(session.activeLayer?.liveShape?.style.color == red)
        // The Fill swatch shows what the next shape will be.
        #expect(session.displayedShapeFill == .white)
        drag(session, from: CGPoint(x: 50, y: 10), to: CGPoint(x: 80, y: 30))
        #expect(session.activeLayer?.liveShape?.style.color == .white)
        // A fill picked in the Shape bar recolors the selected shape and carries on to the next one…
        session.openShapeFillPicker()
        session.colorPicker?.hsb = PickerHSB(blue)
        session.closeColorPicker(commit: true)
        #expect(session.activeLayer?.liveShape?.style.color == blue && session.foregroundColor == .white)
        drag(session, from: CGPoint(x: 10, y: 40), to: CGPoint(x: 40, y: 70))
        #expect(session.activeLayer?.liveShape?.style.color == blue)
        #expect(session.displayedShapeFill == blue)
        // …until the foreground changes again.
        session.swapPaletteColors()
        #expect(session.displayedShapeFill == red)
        drag(session, from: CGPoint(x: 50, y: 40), to: CGPoint(x: 80, y: 70))
        #expect(session.activeLayer?.liveShape?.style.color == red)
        #expect(session.document?.layers.first { $0.id == first }?.liveShape?.style.color == red)
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
        // The selected rectangle owns the radius control, so the next shape's radius is set with it out of the way.
        session.selectLayer(session.document?.layers.first?.id)
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
        session.selectLayer(session.document?.layers.first?.id)
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
        session.selectLayer(session.document?.layers.first?.id)
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

    /// The size shown beside the pointer and in the status bar while dragging: a shape's width and height at the corner
    /// being dragged, even from the center; a line's length at its end; a Marquee's width and height.
    @Test func whatsBeingDraggedOutShowsItsSize() {
        let session = makeSession()
        session.beginShape(at: CGPoint(x: 10, y: 10))
        session.dragShape(to: CGPoint(x: 40, y: 30), square: false, fromCenter: false)
        #expect(session.dragOutSize?.text == "30 × 20 px")
        #expect(session.dragOutSize?.corner == CGPoint(x: 40, y: 30))
        session.dragShape(to: CGPoint(x: 0, y: 0), square: false, fromCenter: true)
        #expect(session.dragOutSize?.text == "20 × 20 px")
        #expect(session.dragOutSize?.corner == CGPoint(x: 0, y: 0))
        session.cancelShape()
        session.shapeKind = .line
        session.beginShape(at: CGPoint(x: 10, y: 10))
        session.dragShape(to: CGPoint(x: 40, y: 50), square: false, fromCenter: false)
        #expect(session.dragOutSize?.text == "50 px")
        session.cancelShape()
        #expect(session.dragOutSize == nil)
        session.selectTool(.marquee)
        session.beginLasso(at: CGPoint(x: 60, y: 50), mode: .replace)
        session.dragMarquee(to: CGPoint(x: 20, y: 10), square: false, fromCenter: false)
        #expect(session.dragOutSize?.text == "40 × 40 px")
        #expect(session.dragOutSize?.corner == CGPoint(x: 20, y: 10))
    }

    /// No stroke draws the same pixels as a shape from before strokes existed. An inside stroke replaces the fill
    /// along the edge and leaves the middle, and the layer stays a shape.
    @Test func anInsideStrokeRecolorsTheEdgeAndKeepsTheShape() async throws {
        let session = makeSession()
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 40)) // 40 × 30
        let plain = try #require(session.activeLayer?.liveShape?.image)
        let reference = try EditorSession.shapeImage(.rectangle, size: CGSize(width: 40, height: 30), color: session.foregroundColor)
        #expect(plain.dataProvider?.data == reference.dataProvider?.data)
        #expect(session.activeLayer?.liveShape?.style.strokeWidth == nil)
        let foreground = session.foregroundColor
        session.shapeStrokeColor = .black
        let count = session.history.undoCount
        session.beginShapeStyleEdit()
        session.setDisplayedStrokeWidth(4)
        session.setDisplayedStrokeWidth(8)
        session.finishShapeStyleEdit()
        #expect(session.history.undoCount == count + 1)
        #expect(session.history.undoName == "Shape Style")
        #expect(session.foregroundColor == foreground)
        #expect(session.shapeStrokeWidth == 0, "the next shape's stroke is unchanged")
        let style = try #require(session.activeLayer?.liveShape?.style)
        #expect(style.strokeWidth == 8 && style.strokeColor == .black)
        let pixel = try await pixels(session)
        #expect(pixel(14, 25) == (0, 255), "inside the stroke")
        #expect(pixel(30, 25) == (255, 255), "the middle stays the fill")
        #expect(pixel(9, 25).alpha == 0, "the box does not grow")
        session.undo()
        #expect(session.activeLayer?.liveShape?.style.strokeWidth == nil)
        session.redo()
        #expect(session.activeLayer?.liveShape?.style.strokeWidth == 8)

        session.setDisplayedCornerRadius(10)
        #expect(session.activeLayer?.liveShape?.style.cornerRadius == 10)
        #expect(session.activeLayer?.liveShape?.style.strokeWidth == 8)
        session.undo()
        #expect(session.activeLayer?.liveShape?.style.cornerRadius == 0)
    }

    /// The rim of a stroked shape is the stroke alone: its anti-aliased edge pixels carry none of the fill.
    @Test func aStrokedEdgeHasNoFringeOfTheFill() throws {
        let image = try EditorSession.shapeImage(.ellipse, size: CGSize(width: 40, height: 40), color: PaletteColor(red: 1, green: 1, blue: 1),
                                                 strokeWidth: 4, strokeColor: .black)
        let context = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var rim = 0
        for y in 0..<40 {
            for x in 0..<40 {
                // Pixels on the outer edge only: the inner edge of the stroke rightly blends into the fill.
                guard hypot(CGFloat(x) + 0.5 - 20, CGFloat(y) + 0.5 - 20) > 19 else { continue }
                let index = (y * 40 + x) * 4
                guard bytes[index + 3] > 0, bytes[index + 3] < 255 else { continue }
                rim += 1
                #expect(bytes[index] == 0, "white fill showing in the black rim at \(x), \(y)")
            }
        }
        #expect(rim > 20, "the rim is anti-aliased")
        let full = Int(bytes[(20 * 40 + 20) * 4 + 3])
        #expect(full == 255)
    }

    @Test func anEllipseStrokeStaysInsideAndALineIgnoresTheStrokeWidth() async throws {
        let session = makeSession()
        session.shapeKind = .ellipse
        drag(session, from: CGPoint(x: 30, y: 20), to: CGPoint(x: 70, y: 60)) // 40 × 40
        session.shapeStrokeColor = PaletteColor(red: 0, green: 0, blue: 1)
        session.setDisplayedStrokeWidth(8)
        let pixel = try await pixels(session)
        #expect(pixel(50, 40) == (255, 255), "the middle is the fill")
        #expect(pixel(50, 24).red == 0 && pixel(50, 24).alpha == 255, "inside the rim")
        #expect(pixel(30, 20).alpha == 0, "the corner of the box stays clear")
        let ellipse = try #require(session.activeLayer?.id)

        session.shapeKind = .line
        session.shapeLineWidth = 4
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 10))
        let line = try #require(session.activeLayer)
        let lineID = line.id
        session.shapeLineWidth = 30
        #expect(line.liveShape?.style.lineWidth == 4, "the stored default does not redraw the selected line")
        session.setDisplayedLineWidth(30)
        #expect(session.activeLayer?.liveShape?.style.lineWidth == 30, "the Width control does")
        session.selectLayer(ellipse)
        session.shapeKind = .line
        session.setDisplayedLineStyle(.dashed)
        session.setDisplayedLineCap(.round)
        session.setDisplayedLineWidth(12)
        let unchanged = session.document?.layers.first { $0.id == lineID }?.liveShape?.style
        #expect(unchanged?.lineWidth == 30 && unchanged?.lineStyle == nil)
        #expect(session.shapeLineWidth == 12 && session.shapeLineStyle == .dashed && session.shapeLineCap == .round)
        #expect(session.activeLayer?.id != lineID)
    }

    /// The Shape tool opens on the kind of the selected live shape, instead of staying on Rectangle.
    @Test func theShapeToolAdoptsTheSelectedShape() throws {
        let session = makeSession()
        session.shapeKind = .line
        drag(session, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 20))
        session.shapeKind = .ellipse
        drag(session, from: CGPoint(x: 10, y: 40), to: CGPoint(x: 30, y: 60))
        let ellipse = try #require(session.activeLayer?.id)
        let line = try #require(session.document?.layers.first { $0.liveShape?.style.kind == .line }?.id)
        session.selectTool(.move)
        session.shapeKind = .rectangle
        session.selectLayer(line)
        session.selectTool(.shape)
        #expect(session.shapeKind == .line)
        session.selectTool(.move)
        session.shapeKind = .rectangle
        session.selectLayer(ellipse)
        session.selectTool(.shape)
        #expect(session.shapeKind == .ellipse)
        let blank = session.document?.layers.first { $0.liveShape == nil }?.id
        session.selectLayer(blank)
        #expect(session.shapeKind == .ellipse, "a layer that is not a shape leaves the mode alone")
    }

    /// Color and width on the Shape bar redraw the selected line, around the same two points.
    @Test func editingASelectedLineChangesItsColorAndWidth() async throws {
        let session = makeSession()
        session.shapeKind = .line
        session.shapeLineWidth = 4
        drag(session, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 90, y: 20))
        let foreground = session.foregroundColor
        session.openShapeFillPicker()
        let picker = try #require(session.colorPicker)
        picker.hsb = PickerHSB(PaletteColor(red: 0, green: 1, blue: 0))
        session.closeColorPicker(commit: true)
        #expect(session.activeLayer?.liveShape?.style.green == 1)
        #expect(session.foregroundColor == foreground)
        let count = session.history.undoCount
        session.beginShapeStyleEdit()
        session.setDisplayedLineWidth(10)
        session.setDisplayedLineWidth(12)
        session.finishShapeStyleEdit()
        #expect(session.history.undoCount == count + 1)
        let layer = try #require(session.activeLayer)
        #expect(layer.liveShape?.style.lineWidth == 12)
        #expect(abs(layer.transform.origin.y - 14) < 0.001, "the thicker stroke grows around the same row")
        #expect(abs((layer.transform.origin.y + layer.transform.size.height / 2) - 20) < 0.001)
        let pixel = try await pixels(session)
        #expect(pixel(50, 20) == (0, 255), "the line took the new color")
        #expect(pixel(50, 15).alpha == 255, "the stroke reaches further")
        #expect(pixel(50, 13).alpha == 0)
        session.undo()
        #expect(session.activeLayer?.liveShape?.style.lineWidth == 4)
        #expect(session.activeLayer?.liveShape?.style.green == 1)
    }

    /// Choosing Line and setting a width and color applies them to the line that is then drawn, even while another
    /// shape is selected. Afterwards the bar edits that line, without selecting it again.
    @Test func aNewLineUsesTheWidthAndColorChosenBeforeItIsDrawn() async throws {
        let session = makeSession()
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        let rectangle = try #require(session.activeLayer?.id)
        session.shapeKind = .line
        session.setDisplayedLineWidth(16)
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 1)
        #expect(session.shapeLineWidth == 16)
        #expect(session.document?.layers.first { $0.id == rectangle }?.liveShape?.style.strokeWidth == nil)
        drag(session, from: CGPoint(x: 10, y: 50), to: CGPoint(x: 70, y: 50))
        let line = try #require(session.activeLayer)
        #expect(line.id != rectangle)
        #expect(line.liveShape?.style.lineWidth == 16)
        #expect(line.liveShape?.style.blue == 1)
        #expect(session.editingLineLayer?.id == line.id)
        session.setDisplayedLineWidth(8)
        #expect(session.activeLayer?.liveShape?.style.lineWidth == 8)
        #expect(session.document?.layers.first { $0.id == rectangle }?.liveShape?.style.strokeWidth == nil)
    }

    /// The next rectangle takes the stroke the bar is showing on the selected shape.
    @Test func theNextShapeCopiesTheBar() async throws {
        let session = makeSession()
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        session.shapeStrokeColor = .black
        session.setDisplayedStrokeWidth(6)
        session.setDisplayedCornerRadius(4)
        drag(session, from: CGPoint(x: 50, y: 10), to: CGPoint(x: 80, y: 30))
        let style = try #require(session.activeLayer?.liveShape?.style)
        #expect(style.strokeWidth == 6 && style.cornerRadius == 4 && style.color == session.foregroundColor)

        // An unstroked rectangle shows 0 even when the next-shape default is wider, and the rectangle drawn from it
        // stays unstroked.
        let blank = session.document?.layers.first { $0.liveShape == nil }?.id
        session.selectLayer(blank)
        session.shapeStrokeWidth = 0
        drag(session, from: CGPoint(x: 5, y: 50), to: CGPoint(x: 25, y: 70))
        let plain = try #require(session.activeLayer?.id)
        session.selectLayer(blank)
        session.shapeStrokeWidth = 8
        session.selectLayer(plain)
        #expect(session.displayedStrokeWidth == 0)
        drag(session, from: CGPoint(x: 30, y: 50), to: CGPoint(x: 50, y: 70))
        #expect(session.activeLayer?.liveShape?.style.strokeWidth == nil)
        #expect(session.document?.layers.first { $0.id == plain }?.liveShape?.style.strokeWidth == nil)
    }

    @Test func fillRecolorsALiveShapeAndASelectionRasterizesIt() async throws {
        let session = makeSession()
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 40))
        session.shapeStrokeColor = .black
        session.setDisplayedStrokeWidth(6)
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 1)
        await session.fillSelection(with: .foreground)
        let style = try #require(session.activeLayer?.liveShape?.style)
        #expect(style.blue == 1 && style.red == 0)
        #expect(style.strokeWidth == 6 && style.strokeColor == .black)
        let image = try #require(session.activeLayer?.liveShape?.image)
        let reference = try EditorSession.shapeImage(style, size: CGSize(width: image.width, height: image.height))
        #expect(image.dataProvider?.data == reference.dataProvider?.data)
        session.undo()
        #expect(session.activeLayer?.liveShape?.style.red == 1)

        session.selectAll()
        await session.fillSelection(with: .background)
        #expect(session.activeLayer?.liveShape == nil)
    }

    @Test func theColorPickerPreviewsAndCancelRestoresTheFill() async throws {
        let session = makeSession()
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 40))
        let count = session.history.undoCount
        session.openShapeFillPicker()
        let picker = try #require(session.colorPicker)
        picker.hsb = PickerHSB(PaletteColor(red: 0, green: 1, blue: 0))
        session.previewShapeColor()
        let layer = try #require(session.activeLayer)
        let snapshot = try #require(session.projectSnapshot())
        let saved = try #require(snapshot.images[layer.id])
        let committed = try #require(layer.asset?.image)
        #expect(saved.image === committed, "a save keeps the fill that was committed, not the preview")
        #expect(snapshot.manifest.layers.last?.shape?.red == 1)
        let shown = try #require(session.displayedAsset(for: layer)?.image)
        let green = try EditorSession.shapeImage(.rectangle, size: CGSize(width: shown.width, height: shown.height),
                                                 color: PaletteColor(red: 0, green: 1, blue: 0))
        #expect(shown.dataProvider?.data == green.dataProvider?.data, "the canvas shows the color being chosen")
        #expect(session.foregroundColor.red == 1, "the foreground swatch stays")
        session.closeColorPicker(commit: false)
        #expect(session.history.undoCount == count)
        #expect(session.activeLayer?.liveShape?.style.red == 1)
        session.openShapeFillPicker()
        session.colorPicker?.hsb = PickerHSB(PaletteColor(red: 0, green: 1, blue: 0))
        session.closeColorPicker(commit: true)
        #expect(session.activeLayer?.liveShape?.style.green == 1)
        #expect(session.foregroundColor.red == 1)
        #expect(session.history.undoCount == count + 1)
        session.undo()
        #expect(session.activeLayer?.liveShape?.style.red == 1)
    }

    @Test func strokeSurvivesSavingAndNeedsVersionTwentyTwo() async throws {
        let session = makeSession()
        session.shapeStrokeWidth = 5
        session.shapeStrokeColor = PaletteColor(red: 0, green: 0, blue: 1)
        session.shapeCornerRadius = 6
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 40))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Stroke-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == ProjectManifest.current)
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let style = try #require(loaded.manifest.layers.last?.shape)
        #expect(style.strokeWidth == 5 && style.strokeBlue == 1 && style.cornerRadius == 6)
        let reopened = makeSession()
        reopened.installProject(loaded, from: url)
        reopened.beginTransform()
        var transform = try #require(reopened.transformEdit?.draft)
        transform.size = CGSize(width: 80, height: 50)
        let layer = try #require(reopened.activeLayer)
        let preview = try #require(reopened.shapeTransformPreview(for: layer, transform: transform))
        reopened.previewTransform(transform)
        reopened.commitTransform()
        let image = try #require(reopened.activeLayer?.liveShape?.image)
        #expect(reopened.activeLayer?.liveShape?.style.strokeWidth == 5)
        #expect(reopened.activeLayer?.liveShape?.style.cornerRadius == 6)
        let reference = try EditorSession.shapeImage(.rectangle, size: transform.size, color: session.foregroundColor,
                                                    cornerRadius: 6, strokeWidth: 5, strokeColor: PaletteColor(red: 0, green: 0, blue: 1))
        #expect(image.dataProvider?.data == reference.dataProvider?.data)
        #expect(preview.dataProvider?.data == reference.dataProvider?.data)

        var older = snapshot.manifest
        older.version = 21
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
        }
        let unstroked = LayerShapeStyle(kind: .rectangle, red: 1, green: 0, blue: 0, cornerRadius: 0)
        let decoded = try JSONDecoder().decode(LayerShapeStyle.self, from: JSONEncoder().encode(unstroked))
        #expect(decoded.strokeWidth == nil && decoded.strokeRed == nil)
    }
}
