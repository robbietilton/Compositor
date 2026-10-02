import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Compositor

/// A package read back holds its layers as the editor made them, and saving it again writes the same bytes.
@MainActor struct ProjectRoundTripTests {
    /// Every premultiplied value under every alpha, in three color patterns: what the editor can hold in a layer.
    private func everyPremultipliedPixel() throws -> CGImage {
        let width = 256, height = 256 * 3
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let alpha = y % 256, pattern = y / 256, value = min(x, alpha), i = y * context.bytesPerRow + x * 4
            pixels[i] = UInt8(value)
            pixels[i + 1] = UInt8(pattern == 0 ? value : alpha - value)
            pixels[i + 2] = UInt8(pattern == 2 ? value / 2 : (value * 7) % (alpha + 1))
            pixels[i + 3] = UInt8(alpha)
        } }
        return context.makeImage()!
    }

    /// A photo cut out with a soft edge, as Object or the wand leaves one.
    private func cutOut(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = [CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 0.4)]
        context.drawLinearGradient(CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!,
                                   start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.clear(CGRect(x: 0, y: 0, width: width / 4, height: height))
        return context.makeImage()!
    }

    /// Revealing or hiding at its edges, with every gray value in a patch inside: past its edges, a mask placed apart
    /// from its layer reveals or hides as its thumbnail says.
    private func edgedMask(_ width: Int, _ height: Int, revealing: Bool) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let inside = (width / 4..<width * 3 / 4).contains(x) && (height / 4..<height * 3 / 4).contains(y)
            data[y * context.bytesPerRow + x] = inside ? UInt8((x - width / 4) * 255 / max(1, width / 2 - 1)) : revealing ? 255 : 0
        } }
        return context.makeImage()!
    }

    /// A project of seven files: five layers, two of them masked, one revealing at its edges and one hiding there and
    /// placed apart; a blend mode and some opacity.
    private func project() throws -> ProjectSnapshot {
        let session = EditorSession()
        session.createDocument(width: 600, height: 800)
        for image in [try everyPremultipliedPixel(), try cutOut(500, 400), try cutOut(300, 700), try cutOut(200, 150), try cutOut(450, 250)] {
            session.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        }
        session.document!.layers[1].mask = LayerMask(asset: try LayerMask.asset(from: edgedMask(500, 400, revealing: true)))
        let last = session.document!.layers.count - 1
        session.document!.layers[last].blendMode = .multiply
        session.document!.layers[last].opacity = 0.6
        var placement = session.document!.layers[last].transform
        placement.origin.x += 120
        placement.origin.y += 60
        var mask = LayerMask(asset: try LayerMask.asset(from: edgedMask(450, 250, revealing: false)))
        mask.placement = placement
        mask.isLinked = false
        session.document!.layers[last].mask = mask
        return try #require(session.projectSnapshot())
    }

    private func saved(_ snapshot: ProjectSnapshot) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "round-trip-\(UUID().uuidString).comp")
        try ProjectStore.package(for: snapshot).write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    /// The package's files by name, the manifest's and every layer's and mask's.
    private func files(_ snapshot: ProjectSnapshot) throws -> [String: Data] {
        let package = try ProjectStore.package(for: snapshot)
        var files: [String: Data] = [:]
        files["manifest.json"] = package.fileWrappers?["manifest.json"]?.regularFileContents
        for (name, file) in package.fileWrappers?["images"]?.fileWrappers ?? [:] { files[name] = file.regularFileContents }
        return files
    }

    /// The image's pixels as the editor composites them: premultiplied sRGB, row by row.
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.copy(image)
        return (0..<image.height).flatMap { y in
            Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow, count: image.width * 4))
        }
    }

    /// Saving a project that was read back writes every file byte for byte as before, and the layers hold the very
    /// pixels the editor saved, at every alpha.
    @Test func savingAReadProjectAgainWritesTheSameBytes() throws {
        let original = try project()
        let url = try saved(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try ProjectStore.readPackage(url)
        let before = try files(original), after = try files(read)
        #expect(before.count == 8 && Set(before.keys) == Set(after.keys))
        for (name, data) in before { #expect(after[name] == data, "\(name) changed") }
        for (id, asset) in original.images { #expect(try pixels(read.images[id]!.image) == pixels(asset.image)) }
        // Past its edges, a mask placed apart reveals or hides as its thumbnail says: one of each here.
        #expect(Set(original.masks.values.map { LayerMask.background(of: $0.thumbnail) }) == [0, 1])
        for (id, mask) in original.masks {
            #expect(LayerMask.background(of: try #require(read.masks[id]).thumbnail) == LayerMask.background(of: mask.thumbnail))
        }

        // And once more, from what was read.
        let again = try saved(read)
        defer { try? FileManager.default.removeItem(at: again) }
        #expect(try files(ProjectStore.readPackage(again)) == before)
    }

    /// A package with a mask that isn't 8-bit gray is refused, even as the last of seven files, read after the first four.
    @Test func aColorMaskIsRefused() throws {
        let original = try project()
        let url = try saved(original)
        defer { try? FileManager.default.removeItem(at: url) }
        // The last layer's mask, the seventh file read, swapped for a color image of its size.
        let layer = try #require(original.manifest.layers.last)
        let maskFile = url.appending(path: "images").appending(path: try #require(layer.maskFile))
        let destination = try #require(CGImageDestinationCreateWithURL(maskFile as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try cutOut(450, 250), nil)
        #expect(CGImageDestinationFinalize(destination))
        let error = #expect(throws: ProjectError.self) { try ProjectStore.readPackage(url) }
        guard case .invalid = error else { Issue.record("refused as \(String(describing: error))"); return }
    }

    /// A project read back renders exactly as it did in the editor that saved it, a mask placed apart included.
    @Test func aReadProjectRendersAsSaved() async throws {
        let original = try project()
        let url = try saved(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try ProjectStore.readPackage(url)
        let before = try await ImageExporter.shared.render(original), after = try await ImageExporter.shared.render(read)
        #expect(try pixels(after.image) == pixels(before.image))
    }
}
