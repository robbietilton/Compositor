import Foundation
import CoreGraphics
import Testing
@testable import Compositor

/// Round-trip against the real 962 MB Photoshop sample: import splits it into one document
/// per artboard; 画板 4 is then re-exported through the layered writer and must read back
/// with this app's own parser, structure intact. The test is disabled (skipped, hence green)
/// when the sample or its pointer file is absent, so CI without the fixture stays green.
@MainActor
struct PSDRealFileRoundTripTests {
    /// Where the artboard-4 round-trip lands for the external psd-tools judge to inspect.
    private static let exportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("compositor-psd-roundtrip-artboard4.psd")

    /// The 962 MB real-world sample never ships with the repo. Point the
    /// COMPOSITOR_PSD_SAMPLE environment variable at a local copy — or at a text file that
    /// holds its path — to run these tests; without it they skip, so CI stays green.
    /// Discovery lives outside the MainActor-isolated suite so the `.enabled` trait
    /// (evaluated off the main actor) can use it.
    private nonisolated enum Sample {
        static func url() -> URL? {
            guard let raw = ProcessInfo.processInfo.environment["COMPOSITOR_PSD_SAMPLE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            if raw.hasSuffix(".psd"), FileManager.default.fileExists(atPath: raw) {
                return URL(fileURLWithPath: raw)
            }
            guard let inner = try? String(contentsOfFile: raw, encoding: .utf8) else { return nil }
            let path = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        static var isAvailable: Bool { url() != nil }
    }

    @Test(.enabled(if: Sample.isAvailable))
    func realSampleImportsByArtboardAndArtboard4RoundTrips() async throws {
        let sample = try #require(Sample.url(), "the enabled trait checked this a moment ago")

        // 1. Import: 11 artboards, one document each; the counts below are the file's own
        //    facts as psd-tools 1.19.0 reads them: 98 layer records = 59 pixel + 16 smart
        //    object + 2 text + 1 solid fill + 1 hue/saturation + 8 pass-through groups +
        //    11 artboard frames. Artboard frames define documents, not layers; the lone
        //    hue/saturation layer has empty channels and is skipped by design → 86 imported.
        let result = try await PSDImporter.shared.importDocuments(at: sample)
        #expect(result.summary.artboards == 11)
        #expect(result.documents.count == 11)
        let names = Set(result.documents.map(\.name))
        #expect(names == Set((1...11).map { "画板 \($0)" }))
        #expect(names.contains("画板 4"))
        for document in result.documents {
            #expect(document.snapshot.manifest.width == 3840)
            #expect(document.snapshot.manifest.height == 2160)
            try LayerHierarchy.validate(document.snapshot.manifest.layers)
            try LiveMaskGraph.validate(document.snapshot.manifest.layers)
        }
        let layers = result.documents.reduce(0) { $0 + $1.snapshot.manifest.layers.count }
        #expect(layers == 86) // 98 records − 11 artboard frames − 1 empty-channel layer
        let masked = result.documents.reduce(0) {
            $0 + $1.snapshot.manifest.layers.filter { $0.maskFile != nil }.count
        }
        #expect(masked == 10) // the 11th mask belongs to the skipped hue/saturation layer
        #expect(result.summary.emptyLayersSkipped == 1)
        #expect(result.summary.oversizeLayersSkipped == 0)

        // 2. 画板 4's subtree: six rasterized layers, no folders, bottom-up as Photoshop
        //    stores them (psd-tools reads the same order). 图层 2 is hidden, 图层 5 is
        //    masked, icon_bg_new blends DARKER_COLOR which downgrades to Darken.
        let artboard4 = try #require(result.documents.first { $0.name == "画板 4" })
        let subtree = artboard4.snapshot.manifest.layers
        #expect(subtree.map(\.name) == ["图层 2", "图层 3", "图层 5", "图层 4", "封面16：9v02", "icon_bg_new"])
        #expect(subtree.allSatisfy { $0.isGroup != true })
        func layer(_ name: String) -> ProjectLayerRecord { subtree.first { $0.name == name } ?? subtree[0] }
        #expect(layer("图层 2").isVisible == false)
        for name in ["图层 3", "图层 5", "图层 4", "封面16：9v02", "icon_bg_new"] {
            #expect(layer(name).isVisible, "\(name) should be visible")
        }
        let maskedLayer = layer("图层 5")
        #expect(maskedLayer.maskFile != nil)
        #expect(artboard4.snapshot.masks[maskedLayer.id] != nil)
        #expect(layer("icon_bg_new").blendMode == .darken) // DARKER_COLOR, downgraded with a note
        #expect(layer("icon_bg_new").opacity ?? 1 == 1)
        // Rects as they sit on the canvas (the artboard sits at the origin).
        let partial = layer("图层 4").transform
        #expect(partial.origin == CGPoint(x: 3106, y: 0) && partial.size == CGSize(width: 734, height: 393))
        let cover = layer("封面16：9v02").transform
        #expect(cover.origin == CGPoint(x: 147, y: 997) && cover.size == CGSize(width: 1933, height: 1023))
        let icon = layer("icon_bg_new").transform
        #expect(icon.origin == CGPoint(x: 3706, y: 19) && icon.size == CGSize(width: 98, height: 107))

        // 3. Export 画板 4 as a layered PSD (the artifact this run leaves behind).
        let data = try await ImageExporter.shared.psdData(artboard4.snapshot)
        #expect(data.count > 0)
        try FileManager.default.createDirectory(at: Self.exportURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: Self.exportURL, options: .atomic)

        // 4. The app's own parser must read the export back with the structure intact.
        let back = try await PSDImporter.shared.importDocuments(at: Self.exportURL)
        #expect(back.documents.count == 1)
        #expect(back.summary.emptyLayersSkipped == 0)
        #expect(back.summary.droppedClipping == 0)
        #expect(back.summary.darkerColorLayers == 0) // Darken now exports/imports as plain `dark`
        let reimported = try #require(back.documents.first).snapshot.manifest.layers
        #expect(reimported.map(\.name) == subtree.map(\.name))
        #expect(reimported.count == 6)
        func reimport(_ name: String) -> ProjectLayerRecord { reimported.first { $0.name == name } ?? reimported[0] }
        for original in subtree {
            let again = reimport(original.name)
            #expect(again.isVisible == original.isVisible)
            #expect((again.blendMode ?? .normal) == (original.blendMode ?? .normal))
            #expect(abs((again.opacity ?? 1) - (original.opacity ?? 1)) < 0.001)
            #expect(again.isGroup != true)
            #expect(again.maskSourceID == nil && original.maskSourceID == nil)
            #expect(again.transform.origin == original.transform.origin)
            #expect(again.transform.size == original.transform.size)
            #expect((again.maskFile != nil) == (original.maskFile != nil))
        }
        let remasked = reimport("图层 5")
        #expect(remasked.maskFile != nil)

        // 5. Pixel parity between the two imports at the same sample points: PackBits is
        //    lossless, so only premultiply/unpremultiply rounding may show (a couple of units).
        let first = try #require(back.documents.first)
        for name in ["封面16：9v02", "图层 5"] {
            let sourceImage = try #require(artboard4.snapshot.images[layer(name).id]).image
            let againImage = try #require(first.snapshot.images[reimport(name).id]).image
            #expect(againImage.width == sourceImage.width && againImage.height == sourceImage.height)
            let x = sourceImage.width / 2, y = sourceImage.height / 2
            let before = try rgba(sourceImage, x, y), after = try rgba(againImage, x, y)
            for channel in 0..<4 {
                #expect(abs(before[channel] - after[channel]) <= 4, "\(name) channel \(channel)")
            }
        }
    }

    // MARK: helpers

    private func rgba(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }
}
