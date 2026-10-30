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
