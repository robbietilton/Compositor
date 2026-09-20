import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct PSDImportExportTests {
    /// Writes a flattened PSD with the system encoder (ImageIO), independently of the code under test:
    /// a 64×32 canvas whose left half is opaque red and whose right half is transparent.
    private func psdFixture(width: Int = 64, height: Int = 32) throws -> URL {
        let type = try #require(UTType("com.adobe.photoshop-image"))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("psd")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// A 6×6 document holding one 4×4 layer (placed at 1,1) built from a 2×2 image whose left column is red.
    private func snapshot() throws -> ProjectSnapshot {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 2))
        let image = try #require(context.makeImage())
        let id = UUID()
        let record = ProjectLayerRecord(id: id, name: "Red", isVisible: true,
            transform: LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 4, height: 4)),
            imageFile: "\(id).png")
        return ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 6, height: 6,
            activeLayerID: id, layers: [record]), images: [id: ImportedImage(image: image, thumbnail: image, name: "Red")])
    }

    @Test func importDecodesCompositeDimensionsPixelsAndAlpha() async throws {
        let url = try psdFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImageImporter.shared.decode(url)
        #expect(result.image.width == 64)
        #expect(result.image.height == 32)
        #expect(result.image.colorSpace?.name == CGColorSpace.sRGB)
        #expect(result.thumbnail.width <= 96 && result.thumbnail.height <= 96)
        // The PSD composite's left half is opaque red; its right half is transparent.
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(result.image, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[3] == 255)
        #expect(bytes[0] >= 250)
        #expect(bytes[63 * 4 + 3] == 0)
    }

    @Test func importRejectsOverBudgetPSD() async throws {
        let url = try psdFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await ImageImporter.shared.decode(url, remainingPixels: 10)
            Issue.record("Over-budget PSD should fail")
        } catch ImageImportError.tooLarge { }
    }

    @Test func exportedDataReadsBackWithDimensionsAndAlpha() async throws {
        let data = try await ImageExporter.shared.psdData(try snapshot())
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "com.adobe.photoshop-image")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 6 && image.height == 6)
        let bitmap = NSBitmapImageRep(cgImage: image)
        #expect(try #require(bitmap.colorAt(x: 1, y: 1)).redComponent > 0.99)
        #expect(try #require(bitmap.colorAt(x: 1, y: 1)).alphaComponent == 1)
        #expect(try #require(bitmap.colorAt(x: 4, y: 1)).alphaComponent == 0)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
    }

    @Test func exportPSDWritesReadableFileToDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PSD-\(UUID()).psd")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ImageExporter.shared.exportPSD(try snapshot(), to: url)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "com.adobe.photoshop-image")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 6 && image.height == 6)
    }

    /// Half-transparent pixels must keep their color: the PSD composite holds straight alpha, so a
    /// premultiplied writer would store red 128 for a 50% red pixel and every correct reader
    /// (Photoshop included) would show it darkened by its own alpha. Verified two independent ways:
    /// the bytes in the file's composite section, and the decoded image through the same
    /// CIImage → CIContext(RGBA8) pipeline `ImageImporter` imports with.
    @Test func exportedTranslucentColorsAreNotDarkenedByAlpha() async throws {
        let width = 8, height = 2
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Straight 255,0,0 at alpha 128 — i.e. premultiplied bytes 128,0,0,128.
        for i in 0..<(width * height) { bytes[i*4] = 128; bytes[i*4+1] = 0; bytes[i*4+2] = 0; bytes[i*4+3] = 128 }
        let image = try #require(context.makeImage())
        let id = UUID()
        let snapshot = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: width, height: height,
            activeLayerID: id, layers: [ProjectLayerRecord(id: id, name: "Red", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: width, height: height)), imageFile: "\(id).png")]),
            images: [id: ImportedImage(image: image, thumbnail: image, name: "Red")])
        let data = try await ImageExporter.shared.psdData(snapshot)

        // 1) File bytes: the composite's channels are straight alpha (R 255, not the premultiplied 128).
        let planes = try Self.compositePlanes(data, width: width, height: height)
        #expect(planes.count == 4)
        #expect(planes[0].allSatisfy { abs(Int($0) - 255) <= 1 })
        #expect(planes[1].allSatisfy { $0 == 0 })
        #expect(planes[2].allSatisfy { $0 == 0 })
        #expect(planes[3].allSatisfy { abs(Int($0) - 128) <= 1 })

        // 2) Decoded and rendered through the import pipeline: a half-transparent pure red.
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == width && decoded.height == height)
        let ci = CIImage(cgImage: decoded)
        let rendered = try #require(CIContext(options: [.cacheIntermediates: false])
            .createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        for (x, y) in [(0, 0), (width - 1, 0), (3, height - 1)] {
            let pixel = try #require(bitmap.colorAt(x: x, y: y))
            #expect(abs(pixel.redComponent - 0.5) < 0.02)
            #expect(pixel.greenComponent == 0 && pixel.blueComponent == 0)
            #expect(abs(pixel.alphaComponent - 0.5) < 0.02)
        }
    }

    /// An independent PSD composite reader (header + section lengths + PackBits decode), so the
    /// export test does not lean on the writer's own code paths.
    private static func compositePlanes(_ data: Data, width: Int, height: Int) throws -> [[UInt8]] {
        func be16(_ offset: Int) -> Int { Int(data[data.startIndex + offset]) << 8 | Int(data[data.startIndex + offset + 1]) }
        func be32(_ offset: Int) -> Int {
            Int(data[data.startIndex + offset]) << 24 | Int(data[data.startIndex + offset + 1]) << 16
                | Int(data[data.startIndex + offset + 2]) << 8 | Int(data[data.startIndex + offset + 3])
        }
        let bytes = [UInt8](data)
        var offset = 26
        for _ in 0..<3 { offset += 4 + be32(offset) }
        let channels = be16(12)
        guard be16(offset) == 1 else { throw ExportError.encode } // RLE, as written straight from pixels
        offset += 2
        var counts = [Int]()
        for _ in 0..<(channels * height) { counts.append(be16(offset)); offset += 2 }
        var planes = [[UInt8]]()
        planes.reserveCapacity(channels)
        for _ in 0..<channels {
            var plane = [UInt8]()
            plane.reserveCapacity(width * height)
            for _ in 0..<height {
                let count = counts.removeFirst()
                var row = [UInt8]()
                var index = offset
                let end = offset + count
                while index < end {
                    let control = Int8(bitPattern: bytes[index]); index += 1
                    if control >= 0 {
                        row.append(contentsOf: bytes[index..<(index + Int(control) + 1)]); index += Int(control) + 1
                    } else if control != -128 {
                        row.append(contentsOf: [UInt8](repeating: bytes[index], count: 1 - Int(control))); index += 1
                    }
                }
                plane.append(contentsOf: row)
                offset = end
            }
            planes.append(plane)
        }
        return planes
    }

    /// Wide gradient+noise rows over the paired-byte distribution that can overflow a PackBits
    /// literal packet (bytes repeat twice — long literal runs, no worthwhile repeats). The other
    /// fixtures are ≤8px wide on purpose; this one exists to cover the row codec at scale.
    /// Opaque pixels make straight and premultiplied storage identical, so the round trip must be
    /// byte-exact through the whole psdData → CGImageSource path.
    @Test func exportedWideNoisyRowsSurvivePackBitsExactly() async throws {
        let width = 2000, height = 6
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var expected = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            var state = UInt64(y) &+ 0x9E3779B97F4A7C15
            func noise() -> UInt8 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return UInt8(truncatingIfNeeded: state) }
            var pair = noise()
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8((x * 255) / (width - 1))              // gradient
                // One lone byte, then byte pairs: [a][b,b][c,c]… — the literal run grows by two from an
                // odd count, which is exactly what overflows a 128-byte literal packet (control byte 128).
                bytes[i + 1] = x == 0 ? noise() : pair
                if x % 2 == 0 { pair = noise() }
                bytes[i + 2] = UInt8((x * 37 + y * 91) % 256)
                bytes[i + 3] = 255
                for c in 0..<4 { expected[i + c] = bytes[i + c] }
            }
        }
        let image = try #require(context.makeImage())
        let id = UUID()
        let snapshot = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: width, height: height,
            activeLayerID: id, layers: [ProjectLayerRecord(id: id, name: "Noise", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: width, height: height)), imageFile: "\(id).png")]),
            images: [id: ImportedImage(image: image, thumbnail: image, name: "Noise")])
        let data = try await ImageExporter.shared.psdData(snapshot)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == width && decoded.height == height)
        let readBack = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        readBack.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
        let actual = [UInt8](Data(bytes: try #require(readBack.data), count: width * height * 4))
        #expect(actual == expected)
    }

    @Test func oversizedCanvasThrows() async throws {
        let huge = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 30_000, height: 30_000,
            activeLayerID: nil, layers: []), images: [:])
        await #expect(throws: ExportError.self) { try await ImageExporter.shared.psdData(huge) }
    }
}
