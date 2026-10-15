import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Testing
@testable import Compositor

@MainActor
struct ImageImportTests {
    func fixture(_ type: UTType, orientation: Int = 1, p3: Bool = false) throws -> URL {
        let colorSpace = CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 256, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(type.preferredFilenameExtension ?? "image")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    func animatedGIFFixture(delays: [Double] = [0.1, 0.1]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)]
        for (index, color) in colors.enumerated() {
            let context = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                                                 bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            let image = try #require(context.makeImage())
            let frameProperties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[index]] as CFDictionary]
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    func asymmetricGIFFixture() throws -> (gif: URL, pngs: [URL]) {
        let gif = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        let destination = try #require(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil))
        let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                      CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 1)]
        var pngs: [URL] = []
        for index in 0..<2 {
            let context = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for quadrant in 0..<4 {
                context.setFillColor(colors[index == 0 ? quadrant : 3 - quadrant])
                context.fill(CGRect(x: (quadrant % 2) * 16, y: (quadrant / 2) * 12, width: 16, height: 12))
            }
            context.clear(CGRect(x: 28, y: 20, width: 4, height: 4))
            let image = try #require(context.makeImage())
            let png = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            let still = try #require(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(still, image, nil)
            #expect(CGImageDestinationFinalize(still))
            pngs.append(png)
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: 0.1] as CFDictionary] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return (gif, pngs)
    }

    func rgba(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return (0..<4).map { bytes[offset + $0] }
    }

    func gray(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try #require(context.data).assumingMemoryBound(to: UInt8.self)[y * image.width + x]
    }

    @Test(arguments: [UTType.png, .jpeg, .tiff, .heic])
    func supportedFormats(type: UTType) async throws {
        let url = try fixture(type)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImageImporter.shared.decode(url)
        #expect(result.image.width == 64)
        #expect(result.image.height == 32)
        #expect(result.image.colorSpace?.name == CGColorSpace.sRGB)
        #expect(result.thumbnail.width <= 96)
        #expect(result.thumbnail.height <= 96)
    }

    // 64 × 32 WebP images: opaque red on the left, transparent on the right.
    @Test(arguments: [
        "UklGRiYAAABXRUJQVlA4TBkAAAAvP8AHEA8Q8x/zHwyxYDJ/6RB6I/ofVfANAA==", // Lossless
        "UklGRoYAAABXRUJQVlA4WAoAAAAQAAAAPwAAHwAAQUxQSBQAAAABDzD/ERFCLJjMXzqE3oj+RxV8A1ZQOCBMAAAA8AMAnQEqQAAgAD4xFolDIiEhFgQAIAMEsYBmu0A/AD8AADKMNAliwAD+96KX/9eiUqpf3sP/+Fmfwsz+Fmf/Cc2fv90UD4A2eDkAAA==" // Lossy
    ])
    func webPImportPreservesTransparency(encoded: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".webp")
        try #require(Data(base64Encoded: encoded)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(UTType.importableImages.contains(.webP))
        let result = try await ImageImporter.shared.decode(url)
        #expect(result.image.width == 64)
        #expect(result.image.height == 32)
        #expect(result.image.colorSpace?.name == CGColorSpace.sRGB)
        #expect(result.thumbnail.width <= 96)
        #expect(result.thumbnail.height <= 96)
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(result.image, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[0] >= 250)
        #expect(bytes[3] == 255)
        #expect(bytes[63 * 4 + 3] == 0)
        do {
            _ = try await ImageImporter.shared.decode(url, remainingPixels: 10)
            Issue.record("Over-budget WebP should fail")
        } catch ImageImportError.tooLarge { }
        let session = EditorSession()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.webP.identifier, visibility: .all) { completion in
            completion(Data(base64Encoded: encoded), nil)
            return nil
        }
        await ImageFileDrop.importProviders([provider], into: session, at: nil)
        #expect(session.document?.size == CGSize(width: 64, height: 32))
        #expect(session.document?.layers.count == 1)
        #expect(session.importError == nil)
    }

    @Test func orientationAndColorConversion() async throws {
        let url = try fixture(.tiff, orientation: 6, p3: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImageImporter.shared.decode(url)
        #expect(result.image.width == 32)
        #expect(result.image.height == 64)
        #expect(result.image.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func pngPreservesTransparency() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImageImporter.shared.decode(url)
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(result.image, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[3] == 255)
        #expect(bytes[0] >= 250)
        #expect(bytes[63 * 4 + 3] == 0)
    }

    @Test func limitsAndInvalidFiles() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await ImageImporter.shared.decode(url, remainingPixels: 10)
            Issue.record("Over-budget image should fail")
        } catch ImageImportError.tooLarge { }
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data("not an image".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        do {
            _ = try await ImageImporter.shared.decode(invalid)
            Issue.record("Invalid image should fail")
        } catch ImageImportError.unreadable { }
        let gif = try fixture(.gif)
        defer { try? FileManager.default.removeItem(at: gif) }
        let gifResult = try await ImageImporter.shared.decode(gif)
        #expect(gifResult.image.width == 64)
        #expect(gifResult.image.height == 32)
        #expect(UTType.importableImages.contains(.gif))
    }

    @Test func animatedGIFTimelineSelectsAndDisplaysFrames() async throws {
        let url = try animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let (imported, animation) = try await ImageImporter.shared.importGIF(url)
        let frames = animation.source.frames
        #expect(frames.map(\.index) == [0, 1])
        #expect(frames.allSatisfy { abs($0.duration - 0.1) < 0.005 })
        #expect(frames.allSatisfy { $0.thumbnail.width <= GIFTimelineLimits.thumbnailSide })
        #expect(try rgba(imported.image, x: 16, y: 12)[0] > 240)
        #expect(try rgba(frames[1].thumbnail, x: frames[1].thumbnail.width / 2, y: frames[1].thumbnail.height / 2)[2] > 240)

        let session = EditorSession()
        await session.importImages([url])
        #expect(session.document?.size == CGSize(width: 32, height: 24))
        #expect(session.gifTimelineFrames.map(\.index) == [0, 1])
        #expect(session.gifTimelineLayerID == session.activeLayerID)
        let importedLayerImage = try #require(session.activeLayer?.asset?.image)

        let undoCount = session.history.undoCount
        await session.selectGIFTimelineFrame(1)
        #expect(session.gifTimelineSelectedFrameIndex == 1)
        #expect(session.history.undoCount == undoCount)
        #expect(session.gifTimelineIsLoadingFrame == false)
        #expect(session.activeLayer?.asset?.image === importedLayerImage)
        let displayedImage = try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        #expect(displayedImage !== importedLayerImage)
        #expect(try rgba(displayedImage, x: 16, y: 12)[2] > 240)
        let snapshotImage = try #require(session.projectSnapshot()?.images[session.activeLayer!.id]?.image)
        #expect(try rgba(snapshotImage, x: 16, y: 12)[2] > 240)
    }

    @Test func gifTimelineKeepsFrameDelaysForPlayback() async throws {
        let url = try animatedGIFFixture(delays: [0.04, 0.16])
        defer { try? FileManager.default.removeItem(at: url) }

        let (_, animation) = try await ImageImporter.shared.importGIF(url)
        let frames = animation.source.frames
        #expect(frames.count == 2)
        #expect(abs(frames[0].duration - 0.04) < 0.005)
        #expect(abs(frames[1].duration - 0.16) < 0.005)
    }

    @Test func gifFramesKeepTheSameOrientationAsStillImages() async throws {
        let files = try asymmetricGIFFixture()
        defer { for file in [files.gif] + files.pngs { try? FileManager.default.removeItem(at: file) } }
        let session = EditorSession()
        await session.importImages([files.gif])
        for index in files.pngs.indices {
            let still = try await ImageImporter.shared.decode(files.pngs[index])
            await session.selectGIFTimelineFrame(index)
            let displayed = try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0) })
            let timeline = session.gifTimelineFrames[index].thumbnail
            let exported = try await ImageExporter.shared.render(#require(session.projectSnapshot()))
            // Four different quadrants and a transparent corner expose flips hidden by solid-color fixtures.
            for (x, y) in [(4, 3), (24, 3), (4, 18), (24, 18), (30, 22)] {
                let expected = try rgba(still.image, x: x, y: y)
                #expect(try rgba(displayed.image, x: x, y: y) == expected)
                #expect(try rgba(displayed.thumbnail, x: x, y: y) == expected)
                #expect(try rgba(timeline, x: x, y: y) == expected)
                #expect(try rgba(exported.image, x: x, y: y) == expected)
            }
        }
    }

    @Test func gifFrameMasksStayWithTheirFramesAndUndoSeparately() async throws {
        let url = try animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let session = EditorSession()
        await session.importImages([url])
        let layerID = try #require(session.activeLayerID)
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 16, height: 24), transform: nil),
                                               antialiased: false), name: "Select Left Side")
        session.toggleGIFFrameMaskTarget()

        var layer = try #require(session.document?.layers.first(where: { $0.id == layerID }))
        let firstMask = try #require(layer.gifFrameMasks[0]?.asset.image)
        #expect(layer.mask == nil)
        #expect(session.isMaskSelected)
        #expect(session.isGIFFrameMaskSelected)
        #expect(session.document?.selection == nil)
        #expect(try gray(firstMask, x: 8, y: 12) > 240)
        #expect(try gray(firstMask, x: 24, y: 12) < 15)
        #expect(session.canCopyPixels)
        let copiedMask = try #require(try session.renderSelectedPixels(from: layer, mask: true))
        let maskToDocument = BrushRaster.pixelToDocument(layer.transform, width: firstMask.width, height: firstMask.height)
        let leftInDocument = CGPoint(x: 8.5, y: 12.5).applying(maskToDocument)
        let rightInDocument = CGPoint(x: 24.5, y: 12.5).applying(maskToDocument)
        let copiedLeft = try rgba(copiedMask.image,
            x: Int((leftInDocument.x - copiedMask.region.minX).rounded(.down)),
            y: Int((leftInDocument.y - copiedMask.region.minY).rounded(.down)))
        let copiedRight = try rgba(copiedMask.image,
            x: Int((rightInDocument.x - copiedMask.region.minX).rounded(.down)),
            y: Int((rightInDocument.y - copiedMask.region.minY).rounded(.down)))
        #expect(copiedLeft[0] > 240, "Copied left pixel \(copiedLeft), region \(copiedMask.region), size \(copiedMask.image.width)×\(copiedMask.image.height)")
        #expect(copiedRight[0] < 15, "Copied right pixel \(copiedRight), region \(copiedMask.region), size \(copiedMask.image.width)×\(copiedMask.image.height)")

        session.tool = .brush
        session.brushSettings.diameter = 4
        session.maskPaintWhite = false
        session.beginBrush(at: CGPoint(x: 8, y: 12))
        #expect(session.brushStroke != nil)
        #expect(session.finishBrushImmediately())
        layer = try #require(session.document?.layers.first(where: { $0.id == layerID }))
        #expect(try gray(try #require(layer.gifFrameMasks[0]?.asset.image), x: 8, y: 12) < 15)
        session.undo()
        layer = try #require(session.document?.layers.first(where: { $0.id == layerID }))
        #expect(try gray(try #require(layer.gifFrameMasks[0]?.asset.image), x: 8, y: 12) > 240)

        await session.selectGIFTimelineFrame(1)
        #expect(!session.isGIFFrameMaskSelected)
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 16, y: 0, width: 16, height: 24), transform: nil),
                                               antialiased: false), name: "Select Right Side")
        session.toggleGIFFrameMaskTarget()

        layer = try #require(session.document?.layers.first(where: { $0.id == layerID }))
        #expect(Set(layer.gifFrameMasks.keys) == [0, 1])
        #expect(session.displayedLayer(for: layer).mask?.asset.image === layer.gifFrameMasks[1]?.asset.image)
        #expect(session.projectSnapshot()?.frameMasks[layerID]?[1]?.asset.image.width == 32)
        let maskedFrame = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
        #expect(try rgba(maskedFrame.image, x: 24, y: 12)[3] > 240)
        #expect(try rgba(maskedFrame.image, x: 8, y: 12)[3] < 15)
        let document = try #require(session.document)
        let liveContext = try BrushRaster.context(width: document.width, height: document.height, mask: false)
        session.drawLiveComposite(document, in: liveContext)
        let liveFrame = try #require(liveContext.makeImage())
        #expect(try rgba(liveFrame, x: 24, y: 12)[3] > 240)
        #expect(try rgba(liveFrame, x: 8, y: 12)[3] < 15)

        await session.selectGIFTimelineFrame(0)
        #expect(session.displayedLayer(for: try #require(session.activeLayer)).mask?.asset.image === firstMask)
        await session.selectGIFTimelineFrame(1)
        session.undo()
        layer = try #require(session.document?.layers.first(where: { $0.id == layerID }))
        #expect(Set(layer.gifFrameMasks.keys) == [0])
        #expect(session.document?.selection != nil)
    }

    @Test func gifFrameMaskWithoutSelectionUsesFramePixelGridAndCanBePainted() async throws {
        let url = try animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let session = EditorSession()
        await session.importImages([url])
        session.toggleGIFFrameMaskTarget()

        let layerID = try #require(session.activeLayerID)
        var layer = try #require(session.document?.layers.first(where: { $0.id == layerID }))
        let mask = try #require(layer.gifFrameMasks[0]?.asset.image)
        #expect(mask.width == 32)
        #expect(mask.height == 24)
        #expect(try gray(mask, x: 8, y: 12) > 240)

        session.tool = .brush
        session.brushSettings.diameter = 4
        session.maskPaintWhite = false
        session.beginBrush(at: CGPoint(x: 8, y: 12))
        #expect(session.finishBrushImmediately())
        layer = try #require(session.document?.layers.first(where: { $0.id == layerID }))
        #expect(try gray(try #require(layer.gifFrameMasks[0]?.asset.image), x: 8, y: 12) < 15)
    }

    @Test func gifFrameMaskLoadsItsHiddenAreaAsASelection() async throws {
        let url = try animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let session = EditorSession()
        await session.importImages([url])
        let layerID = try #require(session.activeLayerID)
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 16, height: 24), transform: nil),
                                               antialiased: false), name: "Select Left Side")
        session.toggleGIFFrameMaskTarget()
        session.loadMaskSelection(layerID: layerID)

        let selection = try #require(session.selection)
        let layer = try #require(session.activeLayer)
        let frameToDocument = BrushRaster.pixelToDocument(layer.transform, width: 32, height: 24)
        let hiddenPoint = CGPoint(x: 24, y: 12).applying(frameToDocument)
        let visiblePoint = CGPoint(x: 8, y: 12).applying(frameToDocument)
        #expect(selection.path.contains(hiddenPoint, using: .winding))
        #expect(!selection.path.contains(visiblePoint, using: .winding))
    }

    @Test func gifFrameMaskCanBeDisabledEnabledAndUndone() async throws {
        let url = try animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let session = EditorSession()
        await session.importImages([url])
        session.toggleGIFFrameMaskTarget()
        #expect(session.gifTimelineCanToggleFrameMask)
        #expect(session.gifTimelineSelectedFrameMaskIsEnabled)

        session.toggleGIFFrameMaskEnabled()
        #expect(!session.gifTimelineSelectedFrameMaskIsEnabled)
        #expect(session.displayedLayer(for: try #require(session.activeLayer)).mask == nil)
        session.undo()
        #expect(session.gifTimelineSelectedFrameMaskIsEnabled)
        #expect(session.displayedLayer(for: try #require(session.activeLayer)).mask != nil)
        session.redo()
        #expect(!session.gifTimelineSelectedFrameMaskIsEnabled)
    }

    @Test func gifTimelinesStayAssociatedWithTheirLayers() async throws {
        let firstGIF = try animatedGIFFixture()
        let secondGIF = try animatedGIFFixture()
        let stillImage = try fixture(.png)
        defer {
            try? FileManager.default.removeItem(at: firstGIF)
            try? FileManager.default.removeItem(at: secondGIF)
            try? FileManager.default.removeItem(at: stillImage)
        }

        let session = EditorSession()
        await session.importImages([firstGIF])
        let firstLayerID = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(1)
        #expect(session.gifTimelineSelectedFrameIndex == 1)

        await session.importImages([stillImage])
        let stillLayerID = try #require(session.activeLayerID)
        #expect(session.gifTimelineLayerID == nil)
        session.selectLayers([firstLayerID], primary: firstLayerID)
        #expect(session.gifTimelineLayerID == firstLayerID)
        #expect(session.gifTimelineSelectedFrameIndex == 1)

        await session.importImages([secondGIF])
        let secondLayerID = try #require(session.activeLayerID)
        #expect(secondLayerID != firstLayerID)
        #expect(session.gifTimelineLayerID == secondLayerID)
        #expect(session.gifTimelineSelectedFrameIndex == 0)
        session.toggleGIFPlayback(for: secondLayerID)
        #expect(session.gifTimelineIsPlaying)
        session.stopGIFPlayback(for: secondLayerID)
        #expect(!session.gifTimelineIsPlaying)
        await session.selectGIFTimelineFrame(1)
        #expect(session.gifTimelineSelectedFrameIndex == 1)

        session.selectLayers([firstLayerID], primary: firstLayerID)
        #expect(session.gifTimelineLayerID == firstLayerID)
        #expect(session.gifTimelineSelectedFrameIndex == 1)
        let displayedFirstFrame = try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        #expect(try rgba(displayedFirstFrame, x: 16, y: 12)[2] > 240)

        session.selectLayers([secondLayerID], primary: secondLayerID)
        #expect(session.gifTimelineLayerID == secondLayerID)
        #expect(session.gifTimelineSelectedFrameIndex == 1)
        #expect(session.document?.layers.contains(where: { $0.id == stillLayerID }) == true)
    }

    @Test func importPlacementAndPartialFailure() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url, url])
        #expect(session.document?.size == CGSize(width: 64, height: 32))
        #expect(session.document?.layers.count == 2)
        #expect(session.activeLayerID == session.document?.layers.last?.id)
        session.createDocument(width: 128, height: 128)
        await session.importImages([url, url.appendingPathExtension("missing")])
        #expect(session.document?.size == CGSize(width: 128, height: 128))
        #expect(session.document?.layers.count == 1)
        #expect(session.document?.layers.first?.origin == CGPoint(x: 32, y: 48))
        #expect(session.importError != nil)
        #expect(!session.isImporting)
    }

    @Test func dropPositionUsesDocumentCoordinates() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.createDocument(width: 1000, height: 800)
        session.viewport.resize(to: CGSize(width: 700, height: 500), backingScale: 2, documentSize: session.document?.size)
        session.zoom(to: 2.5)
        session.viewport.translate(by: CGSize(width: 70, height: -35))
        let location = session.viewport.viewPoint(from: CGPoint(x: 300, y: 250), documentSize: session.document!.size)
        let dropPoint = session.viewport.documentPoint(from: location, documentSize: session.document!.size)
        await session.importImages([url], at: dropPoint)
        #expect(session.document?.layers.first?.origin == CGPoint(x: 268, y: 234))
        #expect(session.document?.size == CGSize(width: 1000, height: 800))
    }

    @Test func queuedImportsAreNotLost() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        let first = Task { await session.importImages([url, url], at: CGPoint(x: 999, y: 999)) }
        let second = Task { await session.importImages([url]) }
        await first.value
        await second.value
        #expect(session.document?.layers.count == 3)
        #expect(session.document?.size == CGSize(width: 64, height: 32))
        #expect(session.document?.layers.first?.origin == .zero)
        #expect(!session.isImporting)
    }

    @Test func fileDropProvidersReachImporterInOrder() async throws {
        let first = try fixture(.png)
        let second = try fixture(.jpeg)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let session = EditorSession()
        let providers = [first, second].map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }
        await ImageFileDrop.importProviders(providers, into: session, at: nil)
        #expect(session.document?.layers.map(\.name) == [first, second].map { $0.deletingPathExtension().lastPathComponent })
        #expect(session.importError == nil)
    }

    /// A folder brings in the images directly inside it, in the Finder's name order: not its other files, its hidden
    /// ones, or what's in its subfolders. A project is a folder on disk too, but not one to import from.
    @Test func folderImportsTheImagesDirectlyInsideIt() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = folder.appendingPathComponent("More", isDirectory: true)
        let project = folder.appendingPathComponent("Project.comp", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try manager.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        try manager.moveItem(at: try fixture(.png), to: folder.appendingPathComponent("10 Ten.png"))
        try manager.moveItem(at: try fixture(.jpeg), to: folder.appendingPathComponent("2 Two.jpeg"))
        try manager.moveItem(at: try fixture(.png), to: folder.appendingPathComponent(".Hidden.png"))
        try manager.moveItem(at: try fixture(.png), to: nested.appendingPathComponent("Nested.png"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("Notes.txt"))
        #expect(ImageFolder.matches(folder))
        #expect(!ImageFolder.matches(project))
        let session = EditorSession()
        await session.importImages([folder])
        #expect(session.document?.layers.map(\.name) == ["2 Two", "10 Ten"])
        #expect(session.importError == nil)
    }

    @Test func folderWithoutImagesSaysSo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("notes".utf8).write(to: folder.appendingPathComponent("Notes.txt"))
        let session = EditorSession()
        await session.importImages([folder])
        #expect(session.document == nil)
        #expect(session.importError?.contains("has no images to import") == true)
    }

    /// HEIF files from cameras (Canon, Sony and Fuji save .hif or .heif) are typed public.heif, not public.heic: the
    /// import panel offers them and they come in like any HEIC.
    @Test(arguments: ["hif", "heif"])
    func cameraHEIFFilesImport(ext: String) async throws {
        let type = try #require(UTType(filenameExtension: ext))
        #expect(UTType.importableImages.contains { type.conforms(to: $0) }, "\(ext) is offered by the import panel")
        let heic = try fixture(.heic)
        let url = heic.deletingPathExtension().appendingPathExtension(ext)
        try FileManager.default.moveItem(at: heic, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        #expect(session.importError == nil, "\(session.importError ?? "")")
        #expect(session.document?.layers.count == 1 && session.document?.width == 64)
    }

    /// A 16-bit PNG of a gentle gray gradient, four 8-bit steps across 256 pixels, at `alpha`.
    private func gentleGradient16(alpha: Double = 1) throws -> URL {
        let width = 256, height = 64
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        for y in 0..<height {
            for x in 0..<width {
                let level = (100 + 4 * Double(x) / Double(width - 1)) / 255 * alpha
                let value = UInt16((level * 65535).rounded()), a = UInt16((alpha * 65535).rounded())
                let i = (y * width + x) * 4
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = a
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// A 16-bit gradient comes in dithered rather than rounded straight down: averaged down each column, it follows
    /// the real gradient, where plain rounding would leave flat bands up to half a step out.
    @Test func sixteenBitImagesAreDitheredNotBanded() async throws {
        let url = try gentleGradient16()
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try await ImageImporter.shared.decode(url).image
        #expect(image.width == 256 && image.height == 64)
        let read = try #require(CGContext(data: nil, width: 256, height: 64, bitsPerComponent: 8, bytesPerRow: 1024,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        read.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 64))
        let bytes = try #require(read.data).assumingMemoryBound(to: UInt8.self)
        var worst = 0.0
        for x in 0..<256 {
            let mean = (0..<64).reduce(0.0) { $0 + Double(bytes[($1 * 256 + x) * 4]) } / 64
            worst = max(worst, abs(mean - (100 + 4 * Double(x) / 255)))
        }
        #expect(worst < 0.25, "columns follow the 16-bit gradient: worst \(worst) of a step off")
        #expect((0..<(256 * 64)).allSatisfy { bytes[$0 * 4 + 3] == 255 })
    }

    /// Premultiplied: the dither never lifts a color past its own alpha.
    @Test func ditheredSixteenBitKeepsColorWithinAlpha() async throws {
        let url = try gentleGradient16(alpha: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try await ImageImporter.shared.decode(url).image
        let read = try #require(CGContext(data: nil, width: 256, height: 64, bitsPerComponent: 8, bytesPerRow: 1024,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        read.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 64))
        let bytes = try #require(read.data).assumingMemoryBound(to: UInt8.self)
        #expect((0..<(256 * 64)).allSatisfy { p in (0..<3).allSatisfy { bytes[p * 4 + $0] <= bytes[p * 4 + 3] } })
        #expect(abs(Int(bytes[3]) - 128) <= 1)
    }
}
