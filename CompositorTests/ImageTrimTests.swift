import Testing
import CoreGraphics
import AppKit
@testable import Compositor

@MainActor
struct ImageTrimTests {
    private func makeRGBAImage(width: Int, height: Int, painter: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) throws -> CGImage {
        let count = width * height * 4
        var pixels = [UInt8](repeating: 0, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let off = (y * width + x) * 4
                let c = painter(x, y)
                pixels[off + 0] = c.r
                pixels[off + 1] = c.g
                pixels[off + 2] = c.b
                pixels[off + 3] = c.a
            }
        }
        let data = Data(pixels)
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ))
    }

    @Test func calculateTrimRectTransparentPixels() throws {
        // 20x20 image:
        // Left transparent: 2 px (x < 2)
        // Right transparent: 3 px (x >= 17)
        // Top transparent: 4 px (y < 4)
        // Bottom transparent: 5 px (y >= 15)
        // Content: x: 2..<17 (width 15), y: 4..<15 (height 11)
        let image = try makeRGBAImage(width: 20, height: 20) { x, y in
            if x >= 2 && x < 17 && y >= 4 && y < 15 {
                return (r: 255, g: 0, b: 0, a: 255)
            } else {
                return (r: 0, g: 0, b: 0, a: 0)
            }
        }

        // All 4 edges
        let allOptions = TrimOptions(basedOn: .transparentPixels, top: true, bottom: true, left: true, right: true)
        let allRect = try #require(ImageTrim.calculateTrimRect(in: image, options: allOptions))
        #expect(allRect == CGRect(x: 2, y: 4, width: 15, height: 11))

        // Only top and bottom
        let tbOptions = TrimOptions(basedOn: .transparentPixels, top: true, bottom: true, left: false, right: false)
        let tbRect = try #require(ImageTrim.calculateTrimRect(in: image, options: tbOptions))
        #expect(tbRect == CGRect(x: 0, y: 4, width: 20, height: 11))

        // Only left and right
        let lrOptions = TrimOptions(basedOn: .transparentPixels, top: false, bottom: false, left: true, right: true)
        let lrRect = try #require(ImageTrim.calculateTrimRect(in: image, options: lrOptions))
        #expect(lrRect == CGRect(x: 2, y: 0, width: 15, height: 20))
    }

    @Test func calculateTrimRectTopLeftPixelColor() throws {
        // 16x16 image:
        // Top-left is blue (0, 0, 255, 255)
        // Border of 3px around is blue
        // Center x: 3..<13, y: 3..<13 is yellow (255, 255, 0, 255)
        let image = try makeRGBAImage(width: 16, height: 16) { x, y in
            if x >= 3 && x < 13 && y >= 3 && y < 13 {
                return (r: 255, g: 255, b: 0, a: 255) // Yellow content
            } else {
                return (r: 0, g: 0, b: 255, a: 255) // Blue border
            }
        }

        let options = TrimOptions(basedOn: .topLeftPixelColor, top: true, bottom: true, left: true, right: true)
        let rect = try #require(ImageTrim.calculateTrimRect(in: image, options: options))
        #expect(rect == CGRect(x: 3, y: 3, width: 10, height: 10))

        // Only trim top
        let topOnly = TrimOptions(basedOn: .topLeftPixelColor, top: true, bottom: false, left: false, right: false)
        let topRect = try #require(ImageTrim.calculateTrimRect(in: image, options: topOnly))
        #expect(topRect == CGRect(x: 0, y: 3, width: 16, height: 13))
    }

    @Test func calculateTrimRectBottomRightPixelColor() throws {
        // 16x16 image:
        // Bottom-right is magenta (255, 0, 255, 255)
        // Bottom 4 rows and right 4 cols are magenta
        // Rest is cyan (0, 255, 255, 255)
        let image = try makeRGBAImage(width: 16, height: 16) { x, y in
            if x >= 12 || y >= 12 {
                return (r: 255, g: 0, b: 255, a: 255) // Magenta border
            } else {
                return (r: 0, g: 255, b: 255, a: 255) // Cyan content
            }
        }

        let options = TrimOptions(basedOn: .bottomRightPixelColor, top: true, bottom: true, left: true, right: true)
        let rect = try #require(ImageTrim.calculateTrimRect(in: image, options: options))
        #expect(rect == CGRect(x: 0, y: 0, width: 12, height: 12))
    }

    @Test func uniformImageReturnsNil() throws {
        // Solid 8x8 image
        let solid = try makeRGBAImage(width: 8, height: 8) { _, _ in
            (r: 100, g: 150, b: 200, a: 255)
        }
        let solidRect = ImageTrim.calculateTrimRect(in: solid, options: TrimOptions(basedOn: .topLeftPixelColor))
        #expect(solidRect == nil)

        // Fully transparent 8x8 image
        let transparent = try makeRGBAImage(width: 8, height: 8) { _, _ in
            (r: 0, g: 0, b: 0, a: 0)
        }
        let transRect = ImageTrim.calculateTrimRect(in: transparent, options: TrimOptions(basedOn: .transparentPixels))
        #expect(transRect == nil)
    }

    @Test func trimImageDirectly() throws {
        let image = try makeRGBAImage(width: 10, height: 10) { x, y in
            if x >= 2 && x < 8 && y >= 2 && y < 8 {
                return (r: 255, g: 128, b: 0, a: 255)
            } else {
                return (r: 0, g: 0, b: 0, a: 0)
            }
        }
        let trimmed = try #require(ImageTrim.trimImage(image, options: TrimOptions(basedOn: .transparentPixels)))
        #expect(trimmed.width == 6)
        #expect(trimmed.height == 6)
    }

    @Test func sessionTrimIntegrationAndUndo() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)

        // Create a 40x40 opaque square
        let square = try makeRGBAImage(width: 40, height: 40) { _, _ in
            (r: 200, g: 50, b: 50, a: 255)
        }
        session.insert(ImportedImage(image: square, thumbnail: square, name: "Square"))

        // Position layer at (20, 30)
        session.beginEdit("Position")
        if let active = session.activeLayerID, let index = session.document?.layers.firstIndex(where: { $0.id == active }) {
            session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 20, y: 30), size: CGSize(width: 40, height: 40))
        }
        session.endEdit()

        #expect(session.document?.width == 100)
        #expect(session.document?.height == 100)

        // Trim transparent pixels
        let trimmed = try await session.trim(options: TrimOptions(basedOn: .transparentPixels))
        #expect(trimmed)

        // Document should now be resized to 40x40
        #expect(session.document?.width == 40)
        #expect(session.document?.height == 40)

        // Layer should now be at (0, 0)
        let activeLayer = try #require(session.activeLayer)
        #expect(abs(activeLayer.transform.origin.x) < 0.001)
        #expect(abs(activeLayer.transform.origin.y) < 0.001)

        // Test Undo
        session.undo()
        #expect(session.document?.width == 100)
        #expect(session.document?.height == 100)
        let undoneLayer = try #require(session.activeLayer)
        #expect(abs(undoneLayer.transform.origin.x - 20) < 0.001)
        #expect(abs(undoneLayer.transform.origin.y - 30) < 0.001)
    }
}
