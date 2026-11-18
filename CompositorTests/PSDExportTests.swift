import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct PSDExportTests {
    private func solid(_ width: Int, _ height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// Left half black, right half white, on a layer's grid.
    private func halfMask(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try #require(context.makeImage())
    }

    /// Background, then a folder holding a masked Multiply layer and a layer clipped to it, then a hidden layer and a
    /// Levels adjustment on top.
    private func document() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 120, height: 80)
        session.insert(ImportedImage(image: try solid(120, 80, red: 0.2, green: 0.4, blue: 0.9), thumbnail: try solid(1, 1, red: 0, green: 0, blue: 0), name: "Sky"))
        session.insert(ImportedImage(image: try solid(40, 30, red: 1, green: 0, blue: 0), thumbnail: try solid(1, 1, red: 0, green: 0, blue: 0), name: "Red"))
        session.insert(ImportedImage(image: try solid(40, 30, red: 0, green: 1, blue: 0), thumbnail: try solid(1, 1, red: 0, green: 0, blue: 0), name: "Green"))
        session.insert(ImportedImage(image: try solid(10, 10, red: 1, green: 1, blue: 0), thumbnail: try solid(1, 1, red: 0, green: 0, blue: 0), name: "Hidden"))
        var layers = try #require(session.document?.layers)
        func index(_ name: String) throws -> Int { try #require(layers.firstIndex { $0.name == name }) }
        layers[try index("Sky")].transform = LayerTransform(origin: .zero, size: CGSize(width: 120, height: 80))
        let red = try index("Red")
        layers[red].transform = LayerTransform(origin: CGPoint(x: 10, y: 20), size: CGSize(width: 40, height: 30))
        layers[red].opacity = 0.5
        layers[red].blendMode = .multiply
        layers[red].mask = LayerMask(asset: try LayerMask.asset(from: halfMask(40, 30)))
        let green = try index("Green")
        layers[green].transform = LayerTransform(origin: CGPoint(x: 30, y: 30), size: CGSize(width: 40, height: 30))
        layers[green].maskSourceID = layers[red].id
        let hidden = try index("Hidden")
        layers[hidden].transform = LayerTransform(origin: CGPoint(x: 100, y: 5), size: CGSize(width: 10, height: 10))
        layers[hidden].isVisible = false
        var levels = ImageLayer(name: "Levels", blankSize: CGSize(width: 120, height: 80))
        levels.adjustment = LayerAdjustment(kind: .levels)
        layers.append(levels)
        session.document?.layers = layers
        session.selectLayers([layers[red].id, layers[green].id], primary: layers[green].id)
        session.groupSelectedLayers()
        return session
    }

    @Test func layersFoldersMasksAndClippingComeBackFromTheFile() async throws {
        let session = try document()
        let snapshot = try #require(session.projectSnapshot())
        let written = try await ImageExporter.shared.psdData(snapshot)
        let parsed = try PSDReader.read(written.data)
        #expect(parsed.width == 120 && parsed.height == 80)
        // Bottom to top; the adjustment layer is left out.
        #expect(parsed.layers.map(\.name) == ["Sky", "Red", "Green", "Folder 1", "Hidden"])
        let byName = Dictionary(uniqueKeysWithValues: parsed.layers.map { ($0.name, $0) })
        let folder = try #require(byName["Folder 1"])
        #expect(folder.isGroup && byName["Red"]?.parentID == folder.id && byName["Green"]?.parentID == folder.id)
        let red = try #require(byName["Red"])
        #expect(red.bounds == CGRect(x: 10, y: 20, width: 40, height: 30))
        #expect(abs(red.opacity - 0.5) < 0.01 && red.blendKey == "mul ")
        #expect(red.mask != nil && red.maskDefault == 255)
        #expect(byName["Green"]?.clipping == true && red.clipping == false)
        #expect(byName["Hidden"]?.isVisible == false && byName["Sky"]?.isVisible == true)
        // Pixels come back as they were.
        let green = try #require(byName["Green"]?.image)
        let pixel = try BrushRaster.context(width: 1, height: 1, mask: false)
        BrushRaster.draw(green, in: CGRect(x: 0, y: 0, width: 40, height: 30), mask: false, context: pixel)
        let bytes = try #require(pixel.data?.assumingMemoryBound(to: UInt8.self))
        #expect(bytes[0] == 0 && bytes[1] == 255 && bytes[2] == 0 && bytes[3] == 255)
        // The importer makes the same document again: the clipping, the folder and the mask.
        let imported = try PSDDocumentBuilder.makeImport(parsed)
        let importedRed = try #require(imported.layers.first { $0.name == "Red" })
        #expect(imported.layers.first { $0.name == "Green" }?.maskSourceID == importedRed.id)
        #expect(importedRed.mask != nil)
        #expect(imported.conversions.isEmpty, "\(imported.conversions.map(\.message))")
        #expect(PSDWriter.summary(PSDWriter.notes(for: snapshot)) == "Adjustment layers left out: “Levels”")
    }

    @Test func otherAppsSeeTheFlattenedPicture() async throws {
        let snapshot = try #require(try document().projectSnapshot())
        let written = try await ImageExporter.shared.psdData(snapshot)
        let source = try #require(CGImageSourceCreateWithData(written.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 120 && image.height == 80)
        // The flattened picture, as Export As draws it, matches what macOS reads from the file.
        let ours = try PSDWriter.planes(of: written.preview, sixteenBit: false)
        let theirs = try PSDWriter.planes(of: image, sixteenBit: false)
        var largest = 0
        for channel in 0..<3 {
            for (a, b) in zip(ours[channel], theirs[channel]) { largest = max(largest, abs(Int(a) - Int(b))) }
        }
        #expect(largest <= 2, "largest difference \(largest)")
    }

    @Test func aSixteenBitDocumentGoesOutAtSixteenBits() async throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 32)
        // A smooth ramp, finer than 8 bits can hold.
        let context = try DeepLayer.context(width: 64, height: 32)
        let pixels = try #require(context.data?.assumingMemoryBound(to: UInt16.self))
        for y in 0..<32 { for x in 0..<64 {
            let p = y * context.bytesPerRow / 2 + x * 4
            pixels[p] = UInt16(x * 1000).littleEndian; pixels[p + 1] = UInt16(20000).littleEndian
            pixels[p + 2] = UInt16(40000).littleEndian; pixels[p + 3] = UInt16(65535).littleEndian
        } }
        let deep = try #require(context.makeImage())
        var asset = ImportedImage(image: try DeepLayer.dithered(deep), thumbnail: try solid(1, 1, red: 0, green: 0, blue: 0), name: "Ramp")
        asset.deep = deep
        session.insert(asset)
        let index = try #require(session.document?.layers.firstIndex { $0.name == "Ramp" })
        session.document?.layers[index].transform = LayerTransform(origin: .zero, size: CGSize(width: 64, height: 32))
        let written = try await ImageExporter.shared.psdData(try #require(session.projectSnapshot()))
        // 16 bits a channel in the header, and macOS reads it.
        #expect(written.data[22] == 0 && written.data[23] == 16)
        let source = try #require(CGImageSourceCreateWithData(written.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64 && image.bitsPerComponent == 16)
        let planes = try PSDWriter.planes(of: image, sixteenBit: true)
        // Red at x = 3 is 3000 of 65535, which 8 bits would round to 2827 or 3084.
        let red = planes[0].withUnsafeBytes { Int(UInt16(bigEndian: $0.load(fromByteOffset: 3 * 2, as: UInt16.self))) }
        #expect(abs(red - 3000) < 40, "\(red)")
    }

    @Test func packBitsRoundTrips() {
        let rows: [[UInt8]] = [[], [7], [1, 1, 1, 1, 2, 3, 3, 4], Array(repeating: 9, count: 300), (0..<300).map { UInt8($0 % 251) }]
        for row in rows {
            let packed = row.withUnsafeBufferPointer { PackBits.pack($0) }
            var out: [UInt8] = []
            var index = packed.startIndex
            while index < packed.endIndex {
                let header = Int(Int8(bitPattern: packed[index])); index += 1
                if header >= 0 {
                    out.append(contentsOf: packed[index..<(index + header + 1)]); index += header + 1
                } else {
                    out.append(contentsOf: Array(repeating: packed[index], count: 1 - header)); index += 1
                }
            }
            #expect(out == row)
        }
    }
}
