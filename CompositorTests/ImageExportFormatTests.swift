import AppKit
import ImageIO
import UniformTypeIdentifiers

import Testing
@testable import Compositor

@MainActor
struct ImageExportFormatTests {
    @Test func supportedFormatsRoundTripPixelsAndMetadata() async throws {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        let raster = ExportRaster(image: try #require(context.makeImage()), resolution: 144)
        #expect(ExportFormat.available.contains(.png))
        #expect(ExportFormat.available.contains(.jpeg))
        #expect(ExportFormat.available.contains(.tiff))
        for format in ExportFormat.available {
            let result = try await ImageExporter.shared.encode(raster, options: ExportOptions(format: format))
            let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == format.type.identifier)
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 64 && image.height == 64)
            #expect(image.colorSpace?.name == CGColorSpace.sRGB)
            #expect(result.preview.width == 64 && result.preview.height == 64)
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let dpi = try #require(properties[kCGImagePropertyDPIWidth as String] as? Double)
            #expect(abs(dpi - 144) < 0.1)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let clear = try #require(bitmap.colorAt(x: 48, y: 32))
            let red = try #require(bitmap.colorAt(x: 16, y: 32))
            if format.supportsTransparency {
                #expect(clear.alphaComponent < 0.02)
                #expect(abs(red.alphaComponent - 0.5) < 0.03)
                #expect(red.redComponent > 0.95)
            } else {
                #expect(clear.alphaComponent == 1)
                #expect(clear.redComponent > 0.98 && clear.greenComponent > 0.98)
            }
            if format == .tiff {
                let tiff = try #require(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
                #expect(tiff[kCGImagePropertyTIFFCompression as String] as? Int == 5)
            }
        }
    }

    @Test func bitDepthCompressionAndTransparencyOptionsRoundTrip() async throws {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        let raster = ExportRaster(image: try #require(context.makeImage()))
        for format in ExportFormat.available {
            for depth in format.bitDepths {
                for alpha in [true, false] {
                    let compressions: [TIFFCompression] = format == .tiff ? TIFFCompression.allCases : [.lzw]
                    for compression in compressions {
                        let options = ExportOptions(format: format,
                            compression: JPEGOptions(red: 0, green: 0, blue: 1),
                            bitDepth: depth, preserveTransparency: alpha, tiffCompression: compression)
                        let result = try await ImageExporter.shared.encode(raster, options: options)
                        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
                        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                        #expect(properties[kCGImagePropertyDepth as String] as? Int == depth)
                        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                        // NSBitmapImageRep's pixel accessor does not read packed 10-bit RGB correctly.
                        let decoded = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                            bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        decoded.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
                        let bitmap = NSBitmapImageRep(cgImage: try #require(decoded.makeImage()))
                        let clear = try #require(bitmap.colorAt(x: 48, y: 32))
                        let red = try #require(bitmap.colorAt(x: 16, y: 32))
                        if options.includesAlpha {
                            #expect(clear.alphaComponent < 0.02)
                            #expect(abs(red.alphaComponent - 0.5) < 0.03)
                        } else {
                            #expect(clear.alphaComponent == 1)
                            #expect(clear.blueComponent > 0.95 && clear.redComponent < 0.05)
                        }
                        if format == .tiff {
                            let tiff = try #require(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
                            #expect(tiff[kCGImagePropertyTIFFCompression as String] as? Int == compression.rawValue)
                        }
                    }
                }
            }
        }
    }

    @Test func previewKeepsFullResolutionForPixelInspection() async throws {
        let snapshot = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 1200,
            height: 24, activeLayerID: nil, layers: []), images: [:])
        let raster = try await ImageExporter.shared.render(snapshot)
        let result = try await ImageExporter.shared.encode(raster, options: ExportOptions())
        #expect(result.preview.width == 1200)
        #expect(result.preview.height == 24)
    }

    @Test func incompatibleBitDepthFallsBackToEight() {
        #expect(ExportOptions(format: .jpeg, bitDepth: 16).effectiveBitDepth == 8)
        #expect(ExportOptions(format: .avif, bitDepth: 16).effectiveBitDepth == 8)
        #expect(ExportOptions(format: .png, bitDepth: 10).effectiveBitDepth == 8)
    }

    @Test func unifiedJPEGUsesSelectedBackground() async throws {
        let snapshot = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 32,
            height: 32, activeLayerID: nil, layers: []), images: [:])
        let raster = try await ImageExporter.shared.render(snapshot)
        let result = try await ImageExporter.shared.encode(raster,
            options: ExportOptions(format: .jpeg, compression: JPEGOptions(quality: 1, red: 0, green: 0, blue: 1)))
        let bitmap = try #require(NSBitmapImageRep(data: result.data))
        let pixel = try #require(bitmap.colorAt(x: 16, y: 16))
        #expect(pixel.blueComponent > 0.97 && pixel.redComponent < 0.03)
        #expect(pixel.alphaComponent == 1)
    }

    @Test func cancelledEncodingDoesNotProduceAResult() async throws {
        let snapshot = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 2,
            height: 2, activeLayerID: nil, layers: []), images: [:])
        let raster = try await ImageExporter.shared.render(snapshot)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ImageExporter.shared.encode(raster, options: ExportOptions())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
