import AppKit
import ImageIO
import ColorSync
import Testing
@testable import Compositor

@MainActor
struct ExportTests {
    private func snapshot(rotation: CGFloat = 0, flip: Bool = false) throws -> ProjectSnapshot {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 2))
        let image = try #require(context.makeImage())
        let id = UUID()
        let transform = LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 4, height: 4),
                                       rotation: rotation, flipX: flip, sampling: .nearest)
        let record = ProjectLayerRecord(id: id, name: "Red", isVisible: true, transform: transform,
                                        imageFile: "\(id).png")
        return ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 6, height: 6,
            activeLayerID: id, layers: [record]), images: [id: ImportedImage(image: image, thumbnail: image, name: "Red")])
    }

    @Test func pngPreservesDimensionsAlphaOrientationAndTransforms() async throws {
        for (rotation, flip, redX, redY, clearX, clearY) in [
            (CGFloat(0), false, 1, 1, 4, 1), (0, true, 4, 1, 1, 1), (90, false, 1, 1, 1, 4)
        ] {
            let data = try await ImageExporter.shared.pngData(snapshot(rotation: rotation, flip: flip))
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 6 && image.height == 6)
            #expect(image.colorSpace?.name == CGColorSpace.sRGB)
            let bitmap = NSBitmapImageRep(cgImage: image)
            #expect(try #require(bitmap.colorAt(x: redX, y: redY)).redComponent > 0.99)
            #expect(try #require(bitmap.colorAt(x: redX, y: redY)).alphaComponent == 1)
            #expect(try #require(bitmap.colorAt(x: clearX, y: clearY)).alphaComponent == 0)
            #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
        }
    }

    @Test func orderVisibilityClippingAndAtomicOverwrite() async throws {
        let original = try snapshot()
        let blueContext = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        blueContext.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        blueContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let blue = try #require(blueContext.makeImage()), id = UUID()
        var images = original.images
        images[id] = ImportedImage(image: blue, thumbnail: blue, name: "Blue")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        for visible in [true, false] {
            var manifest = original.manifest
            manifest.layers.append(ProjectLayerRecord(id: id, name: "Blue", isVisible: visible,
                transform: LayerTransform(origin: CGPoint(x: -2, y: -2), size: CGSize(width: 10, height: 10)),
                imageFile: "\(id).png"))
            try await ImageExporter.shared.exportPNG(ProjectSnapshot(manifest: manifest, images: images), to: url)
            let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
            let pixel = try #require(bitmap.colorAt(x: 1, y: 1))
            #expect(visible ? pixel.blueComponent > 0.99 : pixel.redComponent > 0.99)
            #expect(bitmap.pixelsWide == 6 && bitmap.pixelsHigh == 6)
        }
    }

    @Test func pdfIsOnePageAtThePrintedSizeWithLosslessPixels() async throws {
        let original = try snapshot()
        var manifest = original.manifest
        manifest.resolution = 150
        let data = try await ImageExporter.shared.pdfData(ProjectSnapshot(manifest: manifest, images: original.images))
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(document.numberOfPages == 1)
        let page = try #require(document.page(at: 1))
        // 6 pixels at 150 per inch is 0.04 in, or 2.88 points.
        let box = page.getBoxRect(.mediaBox)
        #expect(abs(box.width - 2.88) < 0.001 && abs(box.height - 2.88) < 0.001)
        // The pixels go in losslessly, never as JPEG.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("/FlateDecode") && !text.contains("/DCTDecode"))
        // Drawn back at one point per pixel, red stays red and the clear area stays clear.
        let context = try #require(CGContext(data: nil, width: 6, height: 6, bitsPerComponent: 8, bytesPerRow: 24,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.scaleBy(x: 6 / box.width, y: 6 / box.height)
        context.drawPDFPage(page)
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        #expect(try #require(bitmap.colorAt(x: 1, y: 1)).redComponent > 0.99)
        #expect(try #require(bitmap.colorAt(x: 1, y: 1)).alphaComponent == 1)
        #expect(try #require(bitmap.colorAt(x: 4, y: 1)).alphaComponent == 0)
    }

    @Test func blankCanvasAndOversizedCanvas() async throws {
        let blank = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 2, height: 2,
            activeLayerID: nil, layers: []), images: [:])
        let data = try await ImageExporter.shared.pngData(blank)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(try #require(bitmap.colorAt(x: 1, y: 1)).alphaComponent == 0)
        let huge = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 30_000, height: 30_000,
            activeLayerID: nil, layers: []), images: [:])
        await #expect(throws: ExportError.self) { try await ImageExporter.shared.pngData(huge) }
        await #expect(throws: ExportError.self) { try await ImageExporter.shared.pdfData(huge) }
    }
    private func printSettings(intent: CMYKIntent = .relative) throws -> PrintSettings {
        let data = try #require(CGColorSpace(name: CGColorSpace.genericCMYK)?.copyICCData()) as Data
        return PrintSettings(profile: try CMYKProfile(data: data), intent: intent)
    }

    private func gamutSettings() throws -> PrintSettings {
        let settings = try printSettings()
        let selected = try #require(settings.profile)
        // System CMYK profiles need not contain a gamut table. Supply a deterministic
        // Lab LUT for this test: neutral colors are inside, saturated colors outside.
        #expect(String(decoding: selected.data[20..<24], as: UTF8.self) == "Lab ")
        let original = try #require(ColorSyncProfileCreate(selected.data as CFData, nil)?.takeRetainedValue())
        let mutable = try #require(ColorSyncProfileCreateMutableCopy(original)?.takeRetainedValue())
        var tag = Data("mft1".utf8)
        tag.append(contentsOf: [0, 0, 0, 0, 3, 1, 3, 0])
        for i in 0..<9 {
            tag.append(contentsOf: i % 4 == 0 ? [0, 1, 0, 0] : [0, 0, 0, 0])
        }
        for _ in 0..<3 { tag.append(contentsOf: (0..<256).map { UInt8($0) }) }
        for _ in 0..<3 { for a in 0..<3 { for b in 0..<3 {
            tag.append(a == 1 && b == 1 ? 0 : 255)
        } } }
        tag.append(contentsOf: (0..<256).map { UInt8($0) })
        ColorSyncProfileSetTag(mutable, "gamt" as CFString, tag as CFData)
        let data = ColorSyncProfileCopyData(mutable, nil).takeRetainedValue() as Data
        let profile = try CMYKProfile(data: data)
        #expect(profile.supportsGamutWarning)
        return PrintSettings(profile: profile)
    }

    @Test(arguments: [CMYKIntent.relative, .perceptual])
    func cmykTIFFKeepsProfileResolutionAndInkChannels(intent: CMYKIntent) async throws {
        let raster = try await ImageExporter.shared.render(snapshot())
        let settings = try printSettings(intent: intent)
        let result = try await ImageExporter.shared.cmykTIFF(ExportRaster(image: raster.image, resolution: 300), settings: settings)
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 6 && image.height == 6)
        #expect(image.colorSpace?.model == .cmyk)
        #expect(image.colorSpace?.numberOfComponents == 4)
        #expect(image.alphaInfo == .none)
        #expect(image.colorSpace?.copyICCData() as Data? == settings.profile?.data)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties[kCGImagePropertyDPIWidth as String] as? Double == 300)
        #expect(properties[kCGImagePropertyDPIHeight as String] as? Double == 300)
        let bytes = try #require(image.dataProvider?.data) as Data
        // Opaque red has magenta and yellow ink; clear corners become white (no ink).
        let red = image.bytesPerRow + 4
        #expect(bytes[red + 1] > 128 && bytes[red + 2] > 128)
        #expect(bytes.prefix(4).allSatisfy { $0 < 3 })
        let conversion = try CMYKConversion(profile: #require(settings.profile), intent: intent)
        let proof = try conversion.proof(raster.image, background: settings.background)
        let expected = try #require(CGContext(data: nil, width: 6, height: 6, bitsPerComponent: 8,
            bytesPerRow: 24, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        expected.setRenderingIntent(.relativeColorimetric)
        expected.draw(image, in: CGRect(x: 0, y: 0, width: 6, height: 6))
        let a = try #require(proof.dataProvider?.data) as Data
        let b = try #require(expected.makeImage()?.dataProvider?.data) as Data
        for pixel in 0..<36 { for channel in 0..<3 {
            #expect(abs(Int(a[pixel * 4 + channel]) - Int(b[pixel * 4 + channel])) <= 3)
        } }
    }

    @Test func cmykBackgroundAndGamutWarningAreViewOnly() async throws {
        let raster = try await ImageExporter.shared.render(snapshot())
        var settings = try gamutSettings()
        settings.background = PaletteColor(red: 0, green: 0, blue: 1)
        let conversion = try CMYKConversion(profile: #require(settings.profile), intent: settings.intent)
        let image = try conversion.image(raster.image, background: settings.background)
        let bytes = try #require(image.dataProvider?.data) as Data
        #expect(bytes[0] > 128 && bytes[1] > 128)
        let proof = try conversion.proof(raster.image, background: .white)
        let warning = try conversion.proof(raster.image, background: .white, warning: true)
        let a = try #require(proof.dataProvider?.data) as Data
        let b = try #require(warning.dataProvider?.data) as Data
        let red = proof.bytesPerRow + 4
        #expect(a[red] != 128)
        #expect(b[red] == 128 && b[red + 1] == 128 && b[red + 2] == 128)
        #expect(b[0] >= 250 && b[1] >= 250 && b[2] >= 250)
        #expect(raster.image.alphaInfo == .premultipliedLast)
        #expect(try #require(NSBitmapImageRep(cgImage: raster.image).colorAt(x: 0, y: 0)).alphaComponent == 0)
    }

    @Test func cmykRejectsInvalidAndRGBProfilesAndMissingProfile() async throws {
        #expect(throws: CMYKError.self) { try CMYKProfile(data: Data("invalid".utf8)) }
        let rgb = try #require(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData()) as Data
        #expect(throws: CMYKError.self) { try CMYKProfile(data: rgb) }
        let raster = try await ImageExporter.shared.render(snapshot())
        await #expect(throws: CMYKError.self) { try await ImageExporter.shared.cmykTIFF(raster, settings: PrintSettings()) }
    }

    @Test(arguments: [0.75, 1.0, 4.0])
    func cmykCanvasProofTracksEditsWithoutChangingPixels(zoom: Double) throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64)
        let raster = try BrushRaster.context(width: 64, height: 64, mask: false)
        let bytes = try #require(raster.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<64 { for x in 0..<32 {
            let index = y * raster.bytesPerRow + x * 4
            bytes[index + (y < 32 ? 2 : 0)] = 255
            bytes[index + 3] = 255
        } }
        let image = try #require(raster.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Colors"))
        session.printSettings = try printSettings()
        let before = session.document
        session.showsPrintProof = true
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        session.viewport.resize(to: canvas.bounds.size, backingScale: 1, documentSize: session.document?.size)
        session.zoom(to: CGFloat(zoom))
        func drawn() throws -> NSBitmapImageRep {
            canvas.synchronizeDisplay()
            let context = try BrushRaster.context(width: 256, height: 256, mask: false)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            canvas.draw(canvas.bounds)
            return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        }
        let conversion = try CMYKConversion(profile: #require(session.printSettings.profile), intent: .relative)
        let expected = NSBitmapImageRep(cgImage: try conversion.proof(image, background: .white))
        let shown = try drawn()
        for point in [CGPoint(x: 12, y: 12), CGPoint(x: 12, y: 44), CGPoint(x: 44, y: 12)] {
            let view = session.viewport.viewPoint(from: point, documentSize: CGSize(width: 64, height: 64))
            let actual = try #require(shown.colorAt(x: Int(view.x), y: Int(view.y)))
            let reference = try #require(expected.colorAt(x: Int(point.x), y: Int(point.y)))
            #expect(abs(actual.redComponent - reference.redComponent) < 0.02)
            #expect(abs(actual.greenComponent - reference.greenComponent) < 0.02)
            #expect(abs(actual.blueComponent - reference.blueComponent) < 0.02)
        }
        #expect(session.document == before)
        session.document!.layers[0].isVisible = false
        let hidden = try drawn()
        let center = try #require(hidden.colorAt(x: 128, y: 128))
        #expect(center.redComponent > 0.98 && center.greenComponent > 0.98 && center.blueComponent > 0.98)
        session.document!.layers[0].isVisible = true
        session.showsPrintProof = false
        let original = try drawn()
        let point = session.viewport.viewPoint(from: CGPoint(x: 12, y: 44), documentSize: CGSize(width: 64, height: 64))
        #expect(try #require(original.colorAt(x: Int(point.x), y: Int(point.y))).redComponent > 0.99)
        #expect(session.document == before)
    }

    @Test func canceledCMYKExportDoesNotProduceOutput() async throws {
        let raster = try await ImageExporter.shared.render(snapshot())
        let settings = try printSettings()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ImageExporter.shared.cmykTIFF(raster, settings: settings)
        }
        do {
            _ = try await task.value
            Issue.record("Canceled CMYK export should fail")
        } catch is CancellationError { }
    }

    @Test func profileWithoutGamutDataStillExportsAndProofs() async throws {
        let settings = try gamutSettings()
        let selected = try #require(settings.profile)
        let original = try #require(ColorSyncProfileCreate(selected.data as CFData, nil)?.takeRetainedValue())
        let mutable = try #require(ColorSyncProfileCreateMutableCopy(original)?.takeRetainedValue())
        ColorSyncProfileRemoveTag(mutable, "gamt" as CFString)
        let data = ColorSyncProfileCopyData(mutable, nil).takeRetainedValue() as Data
        let profile = try CMYKProfile(data: data)
        #expect(!profile.supportsGamutWarning)
        let raster = try await ImageExporter.shared.render(snapshot())
        let conversion = try CMYKConversion(profile: profile, intent: .relative)
        #expect(try conversion.proof(raster.image, background: .white).width == 6)
        #expect(throws: CMYKError.self) { try conversion.proof(raster.image, background: .white, warning: true) }
        let exported = try await ImageExporter.shared.cmykTIFF(raster, settings: PrintSettings(profile: profile))
        #expect(!exported.data.isEmpty)
    }

}
