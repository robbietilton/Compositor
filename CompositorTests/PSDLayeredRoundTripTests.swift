import Foundation
import CoreGraphics
import Testing
@testable import Compositor

/// Layered PSD export → import round-trips over a synthesized tree (folders, a nested folder,
/// a raster mask, several blend modes, Chinese and English names, semi-transparency), plus
/// the malformed-file rejections the importer promises: a clear damaged/truncation error, a
/// clear signature error, a clear PSB error, and the no-artboard over-budget canvas refusal.
/// Fixture building follows PSDImportExportTests (phase 1) in style.
@MainActor
struct PSDLayeredRoundTripTests {
    private static let width = 24, height = 18

    // MARK: fixtures

    private func colorImage(_ width: Int, _ height: Int,
                            _ fill: (CGFloat, CGFloat, CGFloat, CGFloat)) throws -> CGImage {
        // The color is built in the context's own space: CGColor(red:...) can carry another
        // space's primaries, and the fill's color match into sRGB shifts pure blue to (4,51,255).
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(try #require(CGColor(colorSpace: space, components: [fill.0, fill.1, fill.2, fill.3])))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// A grayscale mask whose left half reveals (white) and right half hides (black).
    private func halfRevealMask(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try #require(context.makeImage())
    }

    /// The synthesized tree, bottom-up as the manifest stores it:
    ///
    /// - Background 底 — plain opaque base, full canvas (English + Chinese name)
    /// - Red 红 — clipped to the base (`maskSourceID`), Difference, 65% opacity
    /// - 组 Outer — folder
    ///   - Blue 蓝 — Screen, 85% opacity, raster mask (left half reveals)
    ///   - 内 Inner — nested folder
    ///     - Green 绿 — Multiply, 50% opacity, pixels carry a baked 50% alpha
    /// - Tint 叠加 — hidden on top
    ///
    /// Red sits directly above its clipping base on purpose: PSD clipping resolves to the
    /// nearest non-clipped layer below, and a folder between the two would end the chain.
    private func synthesizedSnapshot() throws -> ProjectSnapshot {
        let backgroundID = UUID(), redID = UUID(), outerID = UUID(), blueID = UUID()
        let innerID = UUID(), greenID = UUID(), tintID = UUID()
        let background = try colorImage(Self.width, Self.height, (0, 0, 1, 1))
        let red = try colorImage(8, 6, (1, 0, 0, 1))
        let blue = try colorImage(10, 10, (0, 0, 1, 1))
        let green = try colorImage(6, 6, (0, 1, 0, 0.5))
        let tint = try colorImage(4, 4, (1, 0, 1, 1))
        let blueMask = try halfRevealMask(10, 10)
        let layers = [
            ProjectLayerRecord(id: backgroundID, name: "Background 底", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: Self.width, height: Self.height)),
                imageFile: "\(backgroundID.uuidString).png"),
            ProjectLayerRecord(id: redID, name: "Red 红", isVisible: true,
                transform: LayerTransform(origin: CGPoint(x: 5, y: 9), size: CGSize(width: 8, height: 6)),
                imageFile: "\(redID.uuidString).png", opacity: 0.65, blendMode: .difference,
                maskSourceID: backgroundID),
            ProjectLayerRecord(id: outerID, name: "组 Outer", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: Self.width, height: Self.height)),
                imageFile: nil, isGroup: true),
            ProjectLayerRecord(id: blueID, name: "Blue 蓝", isVisible: true,
                transform: LayerTransform(origin: CGPoint(x: 2, y: 2), size: CGSize(width: 10, height: 10)),
                imageFile: "\(blueID.uuidString).png", parentID: outerID, opacity: 0.85, blendMode: .screen,
                maskFile: "\(blueID.uuidString).mask.png"),
            ProjectLayerRecord(id: innerID, name: "内 Inner", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: Self.width, height: Self.height)),
                imageFile: nil, parentID: outerID, isGroup: true),
            ProjectLayerRecord(id: greenID, name: "Green 绿", isVisible: true,
                transform: LayerTransform(origin: CGPoint(x: 12, y: 3), size: CGSize(width: 6, height: 6)),
                imageFile: "\(greenID.uuidString).png", parentID: innerID, opacity: 0.5, blendMode: .multiply),
            ProjectLayerRecord(id: tintID, name: "Tint 叠加", isVisible: false,
                transform: LayerTransform(origin: CGPoint(x: 0, y: 14), size: CGSize(width: 4, height: 4)),
                imageFile: "\(tintID.uuidString).png"),
        ]
        func imported(_ image: CGImage, _ name: String) -> ImportedImage {
            ImportedImage(image: image, thumbnail: image, name: name)
        }
        return ProjectSnapshot(
            manifest: ProjectManifest(documentID: UUID(), width: Self.width, height: Self.height,
                                      activeLayerID: tintID, layers: layers),
            images: [backgroundID: imported(background, "Background 底"), redID: imported(red, "Red 红"),
                     blueID: imported(blue, "Blue 蓝"), greenID: imported(green, "Green 绿"),
                     tintID: imported(tint, "Tint 叠加")],
            masks: [blueID: imported(blueMask, "Blue 蓝")])
    }

    // MARK: pixel probes

    private func rgba(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }

    private func gray(_ image: CGImage, _ x: Int, _ y: Int) throws -> Int {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Int(bytes[y * image.width + x])
    }

    // MARK: the round-trip

    @Test func layeredTreeSurvivesExportAndReimport() async throws {
        let snapshot = try synthesizedSnapshot()
        let data = try await ImageExporter.shared.psdData(snapshot)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PSDLayered-\(UUID().uuidString).psd")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let back = try await PSDImporter.shared.importDocuments(at: url)
        #expect(back.summary.emptyLayersSkipped == 0)
        #expect(back.summary.droppedClipping == 0)
        #expect(back.summary.darkerColorLayers == 0)
        #expect(back.summary.unknownBlendLayers == 0)
        #expect(back.summary.artboards == 0)
        #expect(back.documents.count == 1)
        let document = try #require(back.documents.first)
        let imported = document.snapshot.manifest.layers

        // Structure the project validators accept, and nothing silently lost on the way in.
        try LayerHierarchy.validate(imported)
        try LiveMaskGraph.validate(imported)

        // Order: the flat list is bottom-up, a folder before its subtree — exactly the input order.
        let names = imported.map(\.name)
        #expect(names == ["Background 底", "Red 红", "组 Outer", "Blue 蓝", "内 Inner", "Green 绿", "Tint 叠加"])
        #expect(document.snapshot.manifest.width == Self.width)
        #expect(document.snapshot.manifest.height == Self.height)

        func layer(_ name: String) -> ProjectLayerRecord {
            imported.first { $0.name == name } ?? imported[0]
        }
        let background = layer("Background 底"), red = layer("Red 红"), outer = layer("组 Outer")
        let blue = layer("Blue 蓝"), inner = layer("内 Inner"), green = layer("Green 绿"), tint = layer("Tint 叠加")

        // Group relationships: folder rows and nesting survive with new IDs, re-parented correctly.
        #expect(outer.isGroup == true && inner.isGroup == true)
        #expect(background.isGroup != true && red.isGroup != true && blue.isGroup != true)
        #expect(green.isGroup != true && tint.isGroup != true)
        #expect(outer.parentID == nil && background.parentID == nil && red.parentID == nil && tint.parentID == nil)
        #expect(blue.parentID == outer.id)
        #expect(inner.parentID == outer.id)   // the nested folder stays inside the outer one
        #expect(green.parentID == inner.id)

        // Blend modes round-trip through their PSD keys.
        #expect(background.blendMode == nil || background.blendMode == .normal)
        #expect(red.blendMode == .difference)
        #expect(blue.blendMode == .screen)
        #expect(green.blendMode == .multiply)
        #expect(tint.blendMode == nil || tint.blendMode == .normal)

        // Opacity, quantized to 1/255 by the format, and visibility.
        func opacity(_ record: ProjectLayerRecord) -> Double { record.opacity ?? 1 }
        #expect(abs(opacity(background) - 1) < 0.001)
        #expect(abs(opacity(red) - 0.65) <= 1.0 / 255)
        #expect(abs(opacity(blue) - 0.85) <= 1.0 / 255)
        #expect(abs(opacity(green) - 0.5) <= 1.0 / 255)
        #expect(abs(opacity(outer) - 1) < 0.001)  // folders are fully opaque here
        #expect(background.isVisible && red.isVisible && outer.isVisible && blue.isVisible)
        #expect(inner.isVisible && green.isVisible)
        #expect(tint.isVisible == false)

        // Clipping: Red still hangs off the background layer.
        #expect(red.maskSourceID == background.id)
        #expect(blue.maskSourceID == nil)

        // The raster mask survives, white revealing and black hiding, in its own grid.
        #expect(blue.maskFile != nil)
        let mask = try #require(document.snapshot.masks[blue.id])
        #expect(mask.image.width == 10 && mask.image.height == 10)
        #expect(try gray(mask.image, 2, 5) == 255)
        #expect(try gray(mask.image, 7, 5) == 0)

        // Sampled pixels: opaque colors unchanged, the baked 50%-alpha green still straight
        // (premultiplied sampling shows color × alpha, not a darkened discard of alpha).
        let backgroundPixels = try rgba(try #require(document.snapshot.images[background.id]).image, 12, 9)
        #expect(backgroundPixels == [0, 0, 255, 255])
        let redPixels = try rgba(try #require(document.snapshot.images[red.id]).image, 4, 3)
        #expect(redPixels[0] >= 253 && redPixels[1] == 0 && redPixels[2] == 0 && redPixels[3] == 255)
        let greenPixels = try rgba(try #require(document.snapshot.images[green.id]).image, 3, 3)
        #expect(greenPixels[0] == 0 && abs(greenPixels[1] - 128) <= 2 && greenPixels[2] == 0)
        #expect(abs(greenPixels[3] - 128) <= 2)
        let tintPixels = try rgba(try #require(document.snapshot.images[tint.id]).image, 1, 2)
        #expect(tintPixels == [255, 0, 255, 255])
    }

    // MARK: malformed files

    /// Exports a one-layer document and cuts it mid-layer-record (header + resources are 66
    /// bytes, the record starts at 76), so parsing itself runs off the end; the message must
    /// say the file is damaged rather than surfacing a raw decode crash or a misleading
    /// fallback. (A cut inside the channel data instead skips the damaged layer and ends in
    /// `nothingImported`, which the flattened fallback then reports — a different, also
    /// designed path.)
    @Test func truncatedFileReportsDamage() async throws {
        let id = UUID()
        let image = try colorImage(8, 8, (1, 1, 0, 1))
        let snapshot = ProjectSnapshot(
            manifest: ProjectManifest(documentID: UUID(), width: 8, height: 8, activeLayerID: id, layers: [
                ProjectLayerRecord(id: id, name: "Solo", isVisible: true,
                    transform: LayerTransform(origin: .zero, size: CGSize(width: 8, height: 8)),
                    imageFile: "\(id.uuidString).png")]),
            images: [id: ImportedImage(image: image, thumbnail: image, name: "Solo")])
        let full = try await ImageExporter.shared.psdData(snapshot)
        #expect(full.count > 200)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PSDTruncated-\(UUID().uuidString).psd")
        try full.prefix(100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await assertImportFailure(at: url) { error, issue in
            guard case .damaged = error else { return issue("expected damaged, got \(error)") }
            let message = error.errorDescription ?? ""
            #expect(message.contains("damaged"), "message should say damaged: \(message)")
        }
    }

    @Test func badSignatureIsRejectedAsUnreadable() async throws {
        var file = PSDWriter()
        file.append(Array("XXXX".utf8))
        file.u16(1)
        file.append([UInt8](repeating: 0, count: 6))
        file.u16(4); file.u32(4); file.u32(4); file.u16(8); file.u16(3)
        file.append([UInt8](repeating: 0, count: 64))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PSDBadSignature-\(UUID().uuidString).psd")
        try Data(file.bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await assertImportFailure(at: url) { error, issue in
            guard case .unreadable = error else { return issue("expected unreadable, got \(error)") }
            #expect(error.errorDescription?.contains("could not be read") == true)
        }
    }

    @Test func psbHeaderIsRejectedWithAGuideToResave() async throws {
        var file = PSDWriter()
        file.append(PSDFormat.signature)
        file.u16(2) // version 2 = PSB (large document format)
        file.append([UInt8](repeating: 0, count: 6))
        file.u16(4); file.u32(4); file.u32(4); file.u16(8); file.u16(3)
        file.append([UInt8](repeating: 0, count: 64))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PSBHeader-\(UUID().uuidString).psd")
        try Data(file.bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await assertImportFailure(at: url) { error, issue in
            guard case .psb = error else { return issue("expected psb, got \(error)") }
            #expect(error.errorDescription?.contains("PSB") == true)
        }
    }

    /// A layer-bearing PSD without artboards whose canvas passes the 100-megapixel budget is
    /// refused with the split-by-artboards advice, not imported cropped or truncated.
    @Test func oversizeCanvasWithoutArtboardsIsRejected() async throws {
        var layerInfo = PSDWriter()
        layerInfo.i16(1) // one layer record (empty channels — enough to be a real layer file)
        layerInfo.i32(0); layerInfo.i32(0); layerInfo.i32(1); layerInfo.i32(1)
        layerInfo.u16(4)
        for id in [Int16(-1), 0, 1, 2] { layerInfo.i16(id); layerInfo.u32(2) }
        layerInfo.append(PSDFormat.blockSignature)
        layerInfo.ascii("norm")
        layerInfo.append(255); layerInfo.append(0); layerInfo.append(8); layerInfo.append(0)
        var extra = PSDWriter()
        extra.u32(0)                                     // no mask block
        extra.u32(0)                                     // no blending ranges
        extra.append(1); extra.append(UInt8(ascii: "A")) // pascal name, padded to 4
        extra.append([0, 0])
        layerInfo.u32(UInt32(extra.count)); layerInfo.append(extra.slice)
        for _ in 0..<4 { layerInfo.append([0, 0]) }      // four length-2 channel bodies
        var section = PSDWriter()
        section.u32(UInt32(layerInfo.count)); section.append(layerInfo.slice)
        section.u32(0); section.u32(0)                   // global mask info, global tagged blocks
        var file = PSDWriter()
        file.append(PSDFormat.signature)
        file.u16(1); file.append([UInt8](repeating: 0, count: 6)); file.u16(3)
        file.u32(6_000)   // height
        file.u32(20_000)  // width → 120 megapixels, past the budget
        file.u16(8); file.u16(3)
        file.u32(0)       // color mode data
        file.u32(0)       // image resources
        file.u32(UInt32(section.count)); file.append(section.slice)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PSDOversize-\(UUID().uuidString).psd")
        try Data(file.bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await assertImportFailure(at: url) { error, issue in
            guard case let .canvasTooLarge(width, height) = error else {
                return issue("expected canvasTooLarge, got \(error)")
            }
            #expect(width == 20_000 && height == 6_000)
            let message = error.errorDescription ?? ""
            #expect(message.contains("100-megapixel"))
            #expect(message.contains("artboards"))
        }
    }

private func assertImportFailure(
        at url: URL, _ verify: (PSDImportError, (String) -> Void) -> Void) async {
        let caught: PSDImportError?
        do {
            _ = try await PSDImporter.shared.importDocuments(at: url)
            caught = nil
        } catch let error as PSDImportError { caught = error }
        catch { caught = nil; Issue.record("unexpected error type: \(error)") }
        guard let error = caught else {
            Issue.record("importing \(url.lastPathComponent) should have failed")
            return
        }
        verify(error) { Issue.record(Comment(rawValue: $0)) }
    }
}
