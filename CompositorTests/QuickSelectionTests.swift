import AppKit
import ImageIO
import Testing
@testable import Compositor

private enum SuppliedPortraitFixture {
    static let path = ProcessInfo.processInfo.environment["COMPOSITOR_QUICK_SELECTION_IMAGE"]
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/ChatGPT Image 24 сент. 2026 г., 12_04_51.png").path
    static var isAvailable: Bool { FileManager.default.fileExists(atPath: path) }
}
@MainActor
struct QuickSelectionTests {
    private func image(width: Int, height: Int, _ color: (Int, Int) -> [UInt8]) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = color(x, y)
                for channel in 0..<4 {
                    bytes[y * context.bytesPerRow + x * 4 + channel] = pixel[channel]
                }
            }
        }
        return try #require(context.makeImage())
    }

    @Test func quickSelectionDoesNotCrossSyntheticSoftEdge() throws {
        let image = try image(width: 200, height: 100) { x, _ in
            x < 120 ? [245, 190, 20, 255] : [255, 255, 255, 255]
        }
        let mask = try #require(QuickSelection.mask(
            in: image,
            points: [CGPoint(x: 80, y: 50)],
            settings: QuickSelectionSettings(diameter: 40)
        ))
        #expect(mask[50 * 200 + 80] > 0)
        #expect(mask[50 * 200 + 160] == 0)
    }

    @Test func quickSelectionSmallDiameterFollowsShading() throws {
        let image = try image(width: 240, height: 80) { x, _ in
            x < 180 ? [UInt8(180 + (x % 35)), 120, 20, 255] : [245, 245, 245, 255]
        }
        let mask = try #require(QuickSelection.mask(
            in: image,
            points: stride(from: 40, through: 160, by: 20).map { CGPoint(x: $0, y: 40) },
            settings: QuickSelectionSettings(diameter: 10)
        ))
        #expect(mask[40 * 240 + 140] > 0)
        #expect(mask[40 * 240 + 220] == 0)
    }

    @Test func quickSelectionCommitsOneHistoryEntryPerDrag() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100, emptyLayer: true)
        let before = session.history.undoCount
        session.beginQuickSelection(at: CGPoint(x: 20, y: 20), mode: .replace)
        session.extendQuickSelection(to: CGPoint(x: 40, y: 40))
        await session.finishQuickSelection()
        #expect(session.history.undoCount == before + 1)
    }

    private func makeSplitImage(width: Int, height: Int, splitX: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: splitX, height: height))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: splitX, y: 0, width: width - splitX, height: height))
        return try #require(context.makeImage())
    }

    private func makeBrushFootprintImage() throws -> CGImage {
        let context = try BrushRaster.context(width: 31, height: 31, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.1, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 31, height: 31))
        context.setFillColor(CGColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 15, height: 15))
        // This slightly different patch is inside the brush footprint but outside a tight
        // fixed-seed colour tolerance. A real brush-driven selector must seed it directly.
        context.setFillColor(CGColor(srgbRed: 0.46, green: 0.46, blue: 0.46, alpha: 1))
        context.fill(CGRect(x: 17, y: 13, width: 2, height: 2))
        return try #require(context.makeImage())
    }

    private func makeShadedContourImage() throws -> CGImage {
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.15, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        for x in 10..<30 {
            let red = 0.18 + CGFloat(x - 10) * 0.08
            context.setFillColor(CGColor(srgbRed: red, green: 0.35, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: x, y: 3, width: 1, height: 14))
        }
        context.setFillColor(CGColor(srgbRed: 0.01, green: 0.01, blue: 0.01, alpha: 1))
        context.fill(CGRect(x: 30, y: 3, width: 1, height: 14))
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 31, y: 3, width: 9, height: 14))
        return try #require(context.makeImage())
    }

    /// A small deterministic analogue of the supplied character illustration. The exact
    /// antialiasing is intentionally irrelevant; the test only checks the major semantic regions.
    private func makeCharacterLikeFixture() throws -> CGImage {
        let context = try BrushRaster.context(width: 128, height: 128, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.16, green: 0.48, blue: 0.84, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))

        context.setFillColor(CGColor(srgbRed: 0.88, green: 0.45, blue: 0.28, alpha: 1))
        context.fillEllipse(in: CGRect(x: 34, y: 28, width: 60, height: 72))
        // A shaded strip exercises adaptive growth inside one object.
        context.saveGState()
        context.addEllipse(in: CGRect(x: 34, y: 28, width: 60, height: 72))
        context.clip()
        context.setFillColor(CGColor(srgbRed: 0.96, green: 0.57, blue: 0.37, alpha: 1))
        context.fill(CGRect(x: 40, y: 55, width: 48, height: 24))
        context.restoreGState()

        context.setFillColor(CGColor(srgbRed: 0.10, green: 0.07, blue: 0.07, alpha: 1))
        context.fillEllipse(in: CGRect(x: 26, y: 12, width: 76, height: 58))
        context.fillEllipse(in: CGRect(x: 22, y: 60, width: 20, height: 56))
        context.fillEllipse(in: CGRect(x: 86, y: 60, width: 20, height: 56))

        context.setStrokeColor(CGColor(srgbRed: 0.01, green: 0.01, blue: 0.01, alpha: 1))
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(x: 34, y: 28, width: 60, height: 72))
        context.strokeEllipse(in: CGRect(x: 26, y: 12, width: 76, height: 58))
        return try #require(context.makeImage())
    }

    private func makeLargeCharacterLikeFixture() throws -> CGImage {
        let source = try makeCharacterLikeFixture()
        let context = try BrushRaster.context(width: 1254, height: 1254, mask: false)
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: 1254, height: 1254))
        return try #require(context.makeImage())
    }

    @Test func circularBrushDiameterSeedsFootprint() throws {
        let image = try makeBrushFootprintImage()
        let settings = QuickSelectionSettings(diameter: 9, tolerance: 8, edgeSensitivity: 4)
        let mask = try #require(QuickSelection.mask(in: image,
                                                    points: [CGPoint(x: 15, y: 14)],
                                                    settings: settings))
        #expect(mask[14 * 31 + 15] == 255)
        #expect(mask[13 * 31 + 17] == 255)
        #expect(mask[5 * 31 + 15] == 0)
    }

    @Test func adaptiveGrowthFollowsShadingButStopsAtContour() throws {
        let image = try makeShadedContourImage()
        let settings = QuickSelectionSettings(diameter: 5, tolerance: 24, edgeSensitivity: 8)
        let mask = try #require(QuickSelection.mask(in: image,
                                                    points: [CGPoint(x: 11, y: 10)],
                                                    settings: settings))
        #expect(mask[10 * 40 + 11] == 255)
        #expect(mask[10 * 40 + 28] == 255)
        #expect(mask[10 * 40 + 30] == 0)
        #expect(mask[10 * 40 + 33] == 0)
    }

    @Test func repeatedDabsReusePreviousMask() throws {
        let image = try makeSplitImage(width: 40, height: 20, splitX: 20)
        let settings = QuickSelectionSettings(diameter: 7, tolerance: 12, edgeSensitivity: 20)
        let first = try #require(QuickSelection.mask(in: image,
                                                     points: [CGPoint(x: 7, y: 10)],
                                                     settings: settings))
        let combined = try #require(QuickSelection.mask(in: image,
                                                         points: [CGPoint(x: 32, y: 10)],
                                                         settings: settings,
                                                         previousMask: first))
        let repeated = try #require(QuickSelection.mask(in: image,
                                                        points: [CGPoint(x: 32, y: 10)],
                                                        settings: settings,
                                                        previousMask: first))
        #expect(combined == repeated)
        #expect(combined[10 * 40 + 7] == 255)
        #expect(combined[10 * 40 + 32] == 255)
    }

    @Test func growsThePaintedRegionWithoutCrossingAColourEdge() throws {
        let image = try makeSplitImage(width: 40, height: 20, splitX: 20)
        let settings = QuickSelectionSettings(diameter: 9, tolerance: 8, edgeSensitivity: 32)
        let mask = try #require(QuickSelection.mask(in: image,
                                                    points: [CGPoint(x: 8, y: 10)],
                                                    settings: settings))
        #expect(mask[10 * 40 + 8] == 255)
        #expect(mask[10 * 40 + 18] == 255)
        #expect(mask[10 * 40 + 28] == 0)
    }

    @Test func repeatedDabsAreDeterministicAndOutOfBoundsPointsAreIgnored() throws {
        let image = try makeSplitImage(width: 40, height: 20, splitX: 20)
        let settings = QuickSelectionSettings(diameter: 7, tolerance: 12, edgeSensitivity: 20)
        let points = [CGPoint(x: -10, y: -10), CGPoint(x: 7, y: 10), CGPoint(x: 12, y: 10)]
        #expect(QuickSelection.mask(in: image, points: points, settings: settings)
                == QuickSelection.mask(in: image, points: points, settings: settings))
    }
    @Test func characterLikeFixtureKeepsSelectionInsideMajorContours() throws {
        let image = try makeCharacterLikeFixture()
        let settings = QuickSelectionSettings(diameter: 7, tolerance: 18, edgeSensitivity: 14)
        let face = try #require(QuickSelection.mask(in: image,
                                                    points: [CGPoint(x: 64, y: 78)],
                                                    settings: settings))

        #expect(face[78 * 128 + 64] == 255)
        #expect(face[8 * 128 + 8] == 0) // blue background
        #expect(face[30 * 128 + 64] == 0) // dark hair across the face contour
        #expect(face[78 * 128 + 16] == 0) // blue just outside the left contour

        let faceAndHair = try #require(QuickSelection.mask(in: image,
                                                            points: [CGPoint(x: 64, y: 30)],
                                                            settings: settings,
                                                            previousMask: face))
        #expect(faceAndHair[30 * 128 + 64] == 255)
        #expect(faceAndHair[8 * 128 + 8] == 0)
        #expect(faceAndHair[78 * 128 + 16] == 0)
    }

    @Test func oneStrokeGrowsAroundEachDifferentlyColouredBrushPoint() throws {
        let image = try makeSplitImage(width: 80, height: 40, splitX: 40)
        let settings = QuickSelectionSettings(diameter: 7, tolerance: 18, edgeSensitivity: 14)
        let mask = try #require(QuickSelection.mask(in: image,
                                                    points: [CGPoint(x: 10, y: 20), CGPoint(x: 55, y: 20)],
                                                    settings: settings))
        #expect(mask[20 * 80 + 5] == 255)
        #expect(mask[20 * 80 + 75] == 255, "The second colour must grow beyond its brush footprint")
    }

    @Test func largeImageQuickSelectionDoesNotCrawlOnTheMainPath() throws {
        let image = try makeLargeCharacterLikeFixture()
        let started = Date()
        let mask = try #require(QuickSelection.mask(in: image,
                                                    points: [CGPoint(x: 627, y: 760)],
                                                    settings: QuickSelectionSettings(diameter: 40, tolerance: 32, edgeSensitivity: 32)))
        let elapsed = Date().timeIntervalSince(started)
        let outline = try? MagicWand.displayOutline(of: mask, width: 1254, height: 1254)

        #expect(mask[760 * 1254 + 627] == 255)
        #expect(outline != nil)
        #expect(elapsed < 5.0, "Quick Selection took \(elapsed)s on a 1254×1254 image")
    }

    @Test func largeFaceSelectionContinuesPastBrushSearchDistanceWithoutSquareEdges() throws {
        let image = try makeLargeCharacterLikeFixture()
        let width = image.width
        let mask = try #require(QuickSelection.mask(in: image,
                                                    points: [CGPoint(x: 627, y: 760)],
                                                    settings: QuickSelectionSettings(diameter: 40, tolerance: 32, edgeSensitivity: 32)))
        #expect(mask[930 * width + 627] == 255, "The face continues past the former 160-pixel search boundary")
        #expect(mask[760 * width + 100] == 0, "The blue background stays unselected")
    }

    @Test func repeatedLargeBrushPointsRemainInteractive() throws {
        let image = try makeLargeCharacterLikeFixture()
        let prepared = try #require(QuickSelection.prepare(image))
        let points = (0..<20).map { CGPoint(x: 627 + $0, y: 760) }
        let began = Date()
        let mask = try #require(QuickSelection.mask(in: prepared, points: points,
                                                    settings: QuickSelectionSettings()))
        let elapsed = Date().timeIntervalSince(began)
        #expect(mask[760 * image.width + 627] == 255)
        #expect(elapsed < 0.5, "Twenty brush points took \(elapsed)s after pixel preparation")
    }

    @Test func preparingLargeImagePixelsIsFastEnoughForBrushPreview() throws {
        let image = try makeLargeCharacterLikeFixture()
        let began = Date()
        let rgba = try ForegroundMaskUtilities.rgbaBytes(from: image, width: image.width, height: image.height)
        let elapsed = Date().timeIntervalSince(began)
        #expect(rgba.count == image.width * image.height * 4)
        #expect(elapsed < 0.25, "Pixel preparation took \(elapsed)s")
    }

    @Test func preparedPixelsGiveIdenticalRepeatedBrushResults() throws {
        let image = try makeLargeCharacterLikeFixture()
        let prepared = try #require(QuickSelection.prepare(image))
        let points = [CGPoint(x: 627, y: 760)]
        let settings = QuickSelectionSettings()
        let first = try #require(QuickSelection.mask(in: image, points: points, settings: settings))
        let second = try #require(QuickSelection.mask(in: prepared, points: points, settings: settings))
        #expect(first == second)
    }

    @Test func incrementalBrushPreviewMatchesFinalWholeStroke() throws {
        let image = try makeSplitImage(width: 80, height: 40, splitX: 40)
        let prepared = try #require(QuickSelection.prepare(image))
        let settings = QuickSelectionSettings(diameter: 7, tolerance: 18, edgeSensitivity: 14)
        let first = CGPoint(x: 10, y: 20), second = CGPoint(x: 55, y: 20)
        let preview = try #require(QuickSelection.mask(in: prepared, points: [first], settings: settings))
        let incremental = try #require(QuickSelection.mask(in: prepared, points: [second],
                                                           settings: settings, previousMask: preview))
        let whole = try #require(QuickSelection.mask(in: prepared, points: [first, second], settings: settings))
        #expect(incremental == whole)
    }

    /// Optional acceptance check on the user's supplied portrait. Missing fixture is explicitly
    /// reported as skipped, never as a green test that returned early.
    @Test(.enabled(if: SuppliedPortraitFixture.isAvailable))
    func suppliedPortraitKeepsFaceHairBraidsAndBackgroundSeparate() throws {
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: SuppliedPortraitFixture.path) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try #require(image.width == 1254 && image.height == 1254)
        let prepared = try #require(QuickSelection.prepare(image))
        let settings = QuickSelectionSettings()
        let width = image.width
        func selected(_ mask: [UInt8], _ x: Int, _ y: Int) -> Bool { mask[y * width + x] != 0 }

        let face = try #require(QuickSelection.mask(in: prepared, points: [CGPoint(x: 627, y: 630)], settings: settings))
        #expect(selected(face, 627, 630) && selected(face, 627, 760))
        #expect(!selected(face, 627, 300) && !selected(face, 100, 630))

        let hair = try #require(QuickSelection.mask(in: prepared, points: [CGPoint(x: 627, y: 300)], settings: settings))
        #expect(selected(hair, 627, 300) && selected(hair, 627, 220))
        #expect(!selected(hair, 627, 630) && !selected(hair, 100, 630))

        let combined = try #require(QuickSelection.mask(in: prepared, points: [CGPoint(x: 627, y: 630)],
                                                       settings: settings, previousMask: hair))
        #expect(selected(combined, 627, 300) && selected(combined, 627, 630))
        #expect(!selected(combined, 100, 630))

        let singleStroke = try #require(QuickSelection.mask(in: prepared,
                                                            points: [CGPoint(x: 627, y: 630), CGPoint(x: 627, y: 300)],
                                                            settings: settings))
        #expect(selected(singleStroke, 627, 630) && selected(singleStroke, 627, 300))
        #expect(!selected(singleStroke, 100, 630))

        let leftBraid = try #require(QuickSelection.mask(in: prepared, points: [CGPoint(x: 400, y: 900)], settings: settings))
        #expect(selected(leftBraid, 400, 900) && selected(leftBraid, 400, 1050))
        #expect(!selected(leftBraid, 627, 630) && !selected(leftBraid, 300, 900) && !selected(leftBraid, 100, 630))

        let rightBraid = try #require(QuickSelection.mask(in: prepared, points: [CGPoint(x: 820, y: 900)], settings: settings))
        #expect(selected(rightBraid, 820, 900) && selected(rightBraid, 820, 1050))
        #expect(!selected(rightBraid, 627, 630) && !selected(rightBraid, 1000, 900) && !selected(rightBraid, 100, 630))
    }

    @Test func outliningLargeSelectionIsFastEnoughForBrushPreview() throws {
        let image = try makeLargeCharacterLikeFixture()
        let mask = try #require(QuickSelection.mask(in: image,
                                                    points: [CGPoint(x: 627, y: 760)],
                                                    settings: QuickSelectionSettings()))
        let began = Date()
        let outline = try MagicWand.displayOutline(of: mask, width: image.width, height: image.height)
        let elapsed = Date().timeIntervalSince(began)
        #expect(outline != nil)
        #expect(elapsed < 0.25, "Outline preparation took \(elapsed)s")
    }

}
