import Foundation
import CoreGraphics
import Testing
@testable import Compositor

/// Layer-level PSD import and export against the real 962 MB sample, plus a layered export
/// round-trip whose output is verified byte- and structure-wise by psd-tools outside Xcode.
@MainActor
struct PSDLayerIOTests {
    /// The real-world sample never ships with the repo; COMPOSITOR_PSD_SAMPLE points at a
    /// local copy (or a text file holding its path). Without it the test skips, not fails.
    private static let sampleURL: URL = {
        guard let raw = ProcessInfo.processInfo.environment["COMPOSITOR_PSD_SAMPLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return URL(fileURLWithPath: "/dev/null/compositor-psd-sample-missing")
        }
        if raw.hasSuffix(".psd") { return URL(fileURLWithPath: raw) }
        let inner = ((try? String(contentsOfFile: raw, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: inner.isEmpty ? raw : inner)
    }()

    /// Upstream CI has no sample fixture; the test must skip there rather than fail.
    nonisolated static let isReachableSample = {
        guard let raw = ProcessInfo.processInfo.environment["COMPOSITOR_PSD_SAMPLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        if raw.hasSuffix(".psd") { return FileManager.default.fileExists(atPath: raw) }
        guard let inner = try? String(contentsOfFile: raw, encoding: .utf8) else { return false }
        return FileManager.default.fileExists(atPath: inner.trimmingCharacters(in: .whitespacesAndNewlines))
    }()

    @Test(.enabled(if: Self.isReachableSample)) func realSampleSplitsIntoArtboardDocuments() async throws {
        let result = try await PSDImporter.shared.importDocuments(at: Self.sampleURL)
        #expect(result.documents.count == 11)
        let names = Set(result.documents.map(\.name))
        #expect(names.contains("画板 1"))
        #expect(names.contains("画板 11"))
        for document in result.documents {
            #expect(document.snapshot.manifest.width == 3840)
            #expect(document.snapshot.manifest.height == 2160)
            #expect(document.snapshot.manifest.layers.contains { $0.isGroup != true })
            // The importer must produce structures the project validators accept.
            try LayerHierarchy.validate(document.snapshot.manifest.layers)
            try LiveMaskGraph.validate(document.snapshot.manifest.layers)
            for layer in document.snapshot.manifest.layers {
                if layer.imageFile != nil { #expect(document.snapshot.images[layer.id] != nil) }
                if layer.maskFile != nil { #expect(document.snapshot.masks[layer.id] != nil) }
                #expect(!layer.name.isEmpty)
            }
        }
        // 59 pixel + 16 smart object + 2 text + 1 solid fill layers rasterize (the fill spans
        // the whole 256 MP canvas and is cropped per artboard); the lone hue/saturation
        // adjustment layer has empty channels and is skipped.
        #expect(result.summary.emptyLayersSkipped == 1)
        #expect(result.summary.oversizeLayersSkipped == 0)
        // 10 DARKER_COLOR layers downgrade to Darken.
        #expect(result.summary.darkerColorLayers == 10)
        let masks = result.documents.reduce(0) { count, document in
            count + document.snapshot.manifest.layers.filter { $0.maskFile != nil }.count
        }
        #expect(masks == 10) // 4 pixel + 6 smart object; the adjustment layer's mask is empty
        let layers = result.documents.reduce(0) { count, document in
            count + document.snapshot.manifest.layers.count
        }
        #expect(layers == 86) // 78 rasterized layers + 8 pass-through groups

        // The first artboard, re-exported through the layered writer for the external
        // psd-tools judge to compare against the original file's own layer pixels.
        if let artboard = result.documents.first {
            let data = try await ImageExporter.shared.psdData(artboard.snapshot)
            try data.write(to: URL(fileURLWithPath: "/tmp/compositor-psd-artboard1.psd"))
        }
    }

    @Test func packBitsRoundTripsMixedRows() throws {
        let row: [UInt8] = [0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 1, 2, 3, 99, 99, 0, 0, 0, 0, 255, 7, 7, 7, 7, 7, 42]
        let packed = PSDFormat.packBits(row[...])
        var unpacked = [UInt8](repeating: 0, count: row.count)
        try PSDFormat.unpackRow(packed[...], into: &unpacked, at: 0, width: row.count)
        #expect(unpacked == row)
        #expect(PSDFormat.packBits([]) .isEmpty)
    }

    /// A channel with mixed runs and literals, decoded through a window smaller than the
    /// record's rect, must yield exactly the crop of the full decode.
    @Test func windowedChannelDecodeMatchesFullDecode() throws {
        let width = 300, height = 40
        var plane = [UInt8](repeating: 0, count: width * height)
        var seed: UInt32 = 0x1234_5678
        for index in plane.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            plane[index] = UInt8(truncatingIfNeeded: seed >> 13)
        }
        for row in 0..<height { // inject long runs so both packet kinds appear
            for column in 0..<40 { plane[row * width + column] = 0xAB }
            plane[row * width + width - 1] = 0xCD
        }
        let channel = PSDFormat.rleChannel(plane[...], width: width, height: height)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("windowed-\(UUID().uuidString).psd")
        // A minimal valid PSD: header, three empty sections, then the channel body as the
        // composite's first plane stand-in is unnecessary — the reader only needs bytes.
        var file = PSDWriter()
        file.append(PSDFormat.signature)
        file.u16(1); file.append([UInt8](repeating: 0, count: 6)); file.u16(4)
        file.u32(UInt32(height)); file.u32(UInt32(width)); file.u16(8); file.u16(3)
        file.u32(0); file.u32(0); file.u32(0) // color mode, resources, layer sections
        file.append(channel)
        try file.bytes.withUnsafeBufferPointer { buffer in
            try Data(buffer: buffer).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let written = try Data(contentsOf: url)
        #expect(Array(written[38 ..< 38 + 2]) == [0, 1])
        #expect(Array(written[40...]) == Array(channel.dropFirst(2)))
        let source = PSDRect(top: 0, left: 0, bottom: height, right: width)
        func decode(_ visible: PSDRect) throws -> [UInt8] {
            var reader = try PSDFileReader(url: url)
            let info = PSDChannelInfo(id: 0, length: UInt32(channel.count), offset: 26 + 12)
            return try PSDImporter.decodeChannel(info, source: source, visible: visible, reader: &reader)
        }
        let full = try decode(source)
        #expect(full == plane)
        let window = PSDRect(top: 7, left: 93, bottom: 29, right: 211)
        let cropped = try decode(window)
        var expected = [UInt8]()
        for row in window.top..<window.bottom {
            expected.append(contentsOf: plane[row * width + window.left ..< row * width + window.right])
        }
        #expect(cropped == expected)
    }

    /// A PSD with a layer-count field of zero (flattened-only) falls back to importing the
    /// composite. That fallback used to re-enter importImages while its own drain was
    /// suspended, deadlocking with isImporting stuck true (review finding).
    @Test func flattenedPSDFallbackCompletesInsteadOfDeadlocking() async throws {
        var file = PSDWriter()
        file.append(PSDFormat.signature)
        file.u16(1); file.append([UInt8](repeating: 0, count: 6)); file.u16(4)
        file.u32(2); file.u32(4); file.u16(8); file.u16(3)
        file.u32(0); file.u32(0)
        // Layer & Mask: an empty Layer Info whose only content is a zero layer count.
        file.u32(8); file.u32(4); file.i16(0); file.append([0, 0])
        // Composite: raw RGBA planes, 4×2, opaque with one red pixel.
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: 8), count: 4)
        planes[0][0] = 255; planes[3] = [UInt8](repeating: 255, count: 8)
        file.u16(0) // compression: raw
        for plane in planes { file.append(plane) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flat-\(UUID().uuidString).psd")
        try Data(file.bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let session = EditorSession()
        Task { await session.importImages([url]) }
        // Poll rather than await the import: a deadlock would otherwise wedge this test too.
        // The window must outlast PSDImporter's shared actor serving a queued 962 MB import
        // (~60 s in-suite); in isolation the fallback finishes in milliseconds.
        var completed = false
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(500))
            if session.document != nil, !session.isImporting { completed = true; break }
        }
        #expect(completed)
        #expect(!session.isImporting)
        #expect(session.document?.width == 4)
        #expect(session.document?.height == 2)
        #expect(session.document?.layers.first?.asset?.image != nil)
    }

    @Test func layeredExportRoundTripsThroughTheWriter() async throws {
        // A small, precise document: a masked, clipped Multiply layer inside a folder over a
        // solid base, plus an empty adjustment-style layer with no pixels.
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        func image(_ width: Int, _ height: Int, fill: (CGFloat, CGFloat, CGFloat, CGFloat)) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setFillColor(CGColor(red: fill.0, green: fill.1, blue: fill.2, alpha: fill.3))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(context.makeImage())
        }
        func mask(_ width: Int, _ height: Int, reveal: Bool) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(gray: reveal ? 1 : 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(context.makeImage())
        }
        let baseID = UUID(), topID = UUID(), groupID = UUID(), emptyID = UUID()
        let base = try image(8, 8, fill: (0, 0, 1, 1))          // blue
        let top = try image(4, 4, fill: (1, 0, 0, 0.5))         // half-transparent red
        let topMask = try mask(4, 4, reveal: true)
        let layers = [
            ProjectLayerRecord(id: baseID, name: "底", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: 8, height: 8)),
                imageFile: "\(baseID).png"),
            ProjectLayerRecord(id: groupID, name: "组", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: 8, height: 8)), imageFile: nil, isGroup: true),
            ProjectLayerRecord(id: topID, name: "红·中文", isVisible: true,
                transform: LayerTransform(origin: CGPoint(x: 2, y: 2), size: CGSize(width: 4, height: 4)),
                imageFile: "\(topID).png", parentID: groupID, opacity: 0.5, blendMode: .multiply,
                maskFile: "\(topID).mask.png", maskSourceID: baseID),
            // On top, where its (correctly) chain-breaking absence can't disturb the clip below.
            ProjectLayerRecord(id: emptyID, name: "调整", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: 8, height: 8)), imageFile: nil),
        ]
        let snapshot = ProjectSnapshot(
            manifest: ProjectManifest(documentID: UUID(), width: 8, height: 8, activeLayerID: topID, layers: layers),
            images: [baseID: ImportedImage(image: base, thumbnail: base, name: "底"),
                     topID: ImportedImage(image: top, thumbnail: top, name: "红·中文")],
            masks: [topID: ImportedImage(image: topMask, thumbnail: topMask, name: "红·中文")])
        let data = try await ImageExporter.shared.psdData(snapshot)
        let url = URL(fileURLWithPath: "/tmp/compositor-psd-export-test.psd")
        try data.write(to: url)

        // What the app itself reads back must agree with what went in.
        let back = try await PSDImporter.shared.importDocuments(at: url)
        #expect(back.documents.count == 1)
        let document = try #require(back.documents.first)
        #expect(document.snapshot.manifest.width == 8)
        #expect(document.snapshot.manifest.height == 8)
        let imported = document.snapshot.manifest.layers
        #expect(imported.count == 3) // the pixel-less 调整 layer is skipped
        #expect(imported.first { $0.id != groupID && $0.isGroup != true && $0.blendMode == .multiply } != nil)
        let clipped = try #require(imported.first { $0.maskSourceID != nil })
        #expect(clipped.maskSourceID == imported.first { $0.name == "底" }?.id)
        #expect(imported.first { $0.name == "组" }?.isGroup == true)
        #expect(imported.first { $0.name == "调整" } == nil) // no pixels: skipped with a summary note
        #expect(back.summary.emptyLayersSkipped == 1)
        let masked = try #require(imported.first { $0.maskFile != nil })
        #expect(document.snapshot.masks[masked.id] != nil)
    }

    /// Assembles one layer record: rect (top, left, bottom, right), listed channels, blend
    /// fields and extra data (empty mask, empty blending ranges, pascal name, tagged blocks).
    /// Channel bodies follow separately, in record order.
    private static func layerRecord(rect: (Int, Int, Int, Int), channels: [(id: Int16, bytes: [UInt8])],
                                    name: String, blocks: [(String, [UInt8])] = [],
                                    mask: (Int, Int, Int, Int)? = nil) -> PSDWriter {
        var extra = PSDWriter()
        if let mask {
            extra.u32(20) // rect + background + flags + padding to the block size
            extra.i32(Int32(mask.0)); extra.i32(Int32(mask.1)); extra.i32(Int32(mask.2)); extra.i32(Int32(mask.3))
            extra.append(UInt8(0)); extra.append(UInt8(0)); extra.append([0, 0])
        }
        extra.u32(0); extra.u32(0)
        extra.append(UInt8(name.utf8.count)); extra.ascii(name)
        extra.pad(to: 4) // the pascal field pads from its length byte, and 8 bytes precede it
        for (key, data) in blocks {
            extra.ascii("8BIM"); extra.ascii(key)
            extra.u32(UInt32(data.count)); extra.append(data)
            if data.count % 2 == 1 { extra.append(UInt8(0)) }
        }
        var record = PSDWriter()
        record.i32(Int32(rect.0)); record.i32(Int32(rect.1)); record.i32(Int32(rect.2)); record.i32(Int32(rect.3))
        record.u16(UInt16(channels.count))
        for channel in channels { record.i16(channel.id); record.u32(UInt32(channel.bytes.count)) }
        record.ascii("8BIM"); record.ascii("norm")
        record.append(UInt8(255)); record.append(UInt8(0)); record.append(UInt8(0)); record.append(UInt8(0))
        record.u32(UInt32(extra.count)); record.append(extra.slice)
        return record
    }

    /// A raw-compression channel body for a 2×2 plane: compression 0 plus four fill bytes.
    private static func rawPlane(_ fill: UInt8) -> [UInt8] { [0, 0, fill, fill, fill, fill] }

    /// A no-artboard layer whose I32 rect spans ~4 billion pixels per side used to trap on
    /// width*height before the budget compared (review finding). It must be skipped as
    /// over-budget while its normal sibling imports.
    @Test func oversizeLayerRectIsSkippedNotCrash() async throws {
        let small = Self.layerRecord(rect: (0, 0, 2, 2),
                                channels: [(0, Self.rawPlane(255)), (1, Self.rawPlane(0)), (2, Self.rawPlane(0))], name: "A")
        let huge = Self.layerRecord(rect: (-2_000_000_000, -2_000_000_000, 2_000_000_000, 2_000_000_000),
                               channels: [(0, Self.rawPlane(1)), (1, Self.rawPlane(2)), (2, Self.rawPlane(3))], name: "B")
        var section = PSDWriter()
        section.i16(2)
        section.append(small.slice); section.append(huge.slice)
        for fill in [UInt8(255), 0, 0, 1, 2, 3] { section.append(Self.rawPlane(fill)) }
        section.pad(to: 4)
        var outer = PSDWriter()
        outer.u32(UInt32(section.count)); outer.append(section.slice); outer.u32(0)
        var file = PSDWriter()
        file.append(PSDFormat.signature)
        file.u16(1); file.append([UInt8](repeating: 0, count: 6)); file.u16(4)
        file.u32(2); file.u32(2); file.u16(8); file.u16(3)
        file.u32(0); file.u32(0)
        file.u32(UInt32(outer.count)); file.append(outer.slice)
        file.u16(0) // composite: raw RGBA planes
        for _ in 0..<3 { file.append([0, 0, 0, 0]) }
        file.append([255, 255, 255, 255])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("huge-\(UUID().uuidString).psd")
        try Data(file.bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await PSDImporter.shared.importDocuments(at: url)
        #expect(result.documents.count == 1)
        #expect(result.documents.first?.snapshot.manifest.layers.count == 1)
        #expect(result.summary.oversizeLayersSkipped == 1)
    }

    /// An artb descriptor whose `Top ` double is NaN used to trap in Int(Double) while
    /// rounding the artboard rect (review finding). The group must degrade to a plain folder.
    @Test func artboardWithNonFiniteSideIsIgnoredNotCrash() async throws {
        var artb = PSDWriter()
        artb.u32(16)                        // descriptor version
        artb.u32(0)                         // empty unicode string
        artb.u32(0); artb.ascii("null")     // class ID, short key
        artb.u32(1)                         // one item: artboardRect
        artb.u32(12); artb.ascii("artboardRect")
        artb.ascii("Objc")
        artb.u32(0)                         // object name string
        artb.u32(0); artb.ascii("Rctn")     // object class ID
        artb.u32(4)                         // Top, Left, Btom, Rght
        func side(_ key: String, _ bits: UInt64) {
            artb.u32(0); artb.ascii(key)
            artb.ascii("doub"); artb.u64(bits)
        }
        side("Top ", 0x7FF8_0000_0000_0000) // NaN
        side("Left", (0.0).bitPattern)
        side("Btom", (2160.0).bitPattern)
        side("Rght", (3840.0).bitPattern)
        let seal = Self.layerRecord(rect: (0, 0, 2, 2), channels: [], name: "s", blocks: [("lsct", [0, 0, 0, 3])])
        let pixel = Self.layerRecord(rect: (0, 0, 2, 2),
                                     channels: [(0, Self.rawPlane(255)), (1, Self.rawPlane(0)), (2, Self.rawPlane(0))],
                                     name: "p")
        let header = Self.layerRecord(rect: (0, 0, 2, 2), channels: [], name: "h",
                                      blocks: [("lsct", [0, 0, 0, 1]), ("artb", artb.bytes)])
        var section = PSDWriter()
        section.i16(3)
        section.append(seal.slice); section.append(pixel.slice); section.append(header.slice)
        for fill in [UInt8(255), 0, 0] { section.append(Self.rawPlane(fill)) }
        section.pad(to: 4)
        var outer = PSDWriter()
        outer.u32(UInt32(section.count)); outer.append(section.slice); outer.u32(0)
        var file = PSDWriter()
        file.append(PSDFormat.signature)
        file.u16(1); file.append([UInt8](repeating: 0, count: 6)); file.u16(4)
        file.u32(2); file.u32(2); file.u16(8); file.u16(3)
        file.u32(0); file.u32(0)
        file.u32(UInt32(outer.count)); file.append(outer.slice)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nan-\(UUID().uuidString).psd")
        try Data(file.bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await PSDImporter.shared.importDocuments(at: url)
        #expect(result.documents.count == 1) // no artboard split: the NaN rect yields no artboard
        let document = try #require(result.documents.first)
        #expect(document.snapshot.manifest.width == 2) // whole-canvas doc, not a 3840×2160 artboard
        #expect(document.snapshot.manifest.height == 2)
        #expect(document.snapshot.manifest.layers.contains { $0.isGroup != true })
    }

    /// PSD scanline tables count row bytes in u16s, so a layer past 30,000 pixels per side
    /// cannot round-trip; the writer used to truncate its rows silently (review finding).
    @Test func exportRejectsLayersPastThePSDSideLimit() async throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 8 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let id = UUID()
        let layers = [ProjectLayerRecord(id: id, name: "超大", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 40_000, height: 10)),
            imageFile: "\(id).png")]
        let snapshot = ProjectSnapshot(
            manifest: ProjectManifest(documentID: UUID(), width: 8, height: 8, activeLayerID: id, layers: layers),
            images: [id: ImportedImage(image: image, thumbnail: image, name: "超大")],
            masks: [:])
        await #expect(throws: ExportError.self) { try await ImageExporter.shared.psdData(snapshot) }
    }

    /// A Layer & Mask section whose Layer Info length is zero (no count field at all) used to
    /// report the file as damaged instead of falling back to the composite (review finding).
    @Test func zeroLengthLayerInfoFallsBackToComposite() async throws {
        var file = PSDWriter()
        file.append(PSDFormat.signature)
        file.u16(1); file.append([UInt8](repeating: 0, count: 6)); file.u16(4)
        file.u32(2); file.u32(4); file.u16(8); file.u16(3)
        file.u32(0); file.u32(0)
        file.u32(4); file.u32(0) // Layer & Mask present, Layer Info empty
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: 8), count: 4)
        planes[0][0] = 255; planes[3] = [UInt8](repeating: 255, count: 8)
        file.u16(0)
        for plane in planes { file.append(plane) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("li0-\(UUID().uuidString).psd")
        try Data(file.bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try PSDReader.read(url: url).records.isEmpty) // this layout used to throw .damaged
        let session = EditorSession()
        Task { await session.importImages([url]) }
        // Poll rather than await: the fallback must complete on its own drain.
        var completed = false
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(500))
            if session.document != nil, !session.isImporting { completed = true; break }
        }
        #expect(completed)
        #expect(session.document?.width == 4)
        #expect(session.document?.height == 2)
    }

    /// workspace.receive with a PSD used to deadlock: receive holds isManaging while
    /// importPSD spun on canSwitch, which itself requires !isManaging — forever, and
    /// isManaging stuck true also vetoes quit (review finding B1).
    @Test func workspaceReceivePSDCompletesInsteadOfDeadlocking() async throws {
        let record = Self.layerRecord(rect: (0, 0, 2, 2),
                                      channels: [(0, Self.rawPlane(255)), (1, Self.rawPlane(0)), (2, Self.rawPlane(0))], name: "A")
        var section = PSDWriter()
        section.i16(1); section.append(record.slice)
        for fill in [UInt8(255), 0, 0] { section.append(Self.rawPlane(fill)) }
        section.pad(to: 4)
        var outer = PSDWriter()
        outer.u32(UInt32(section.count)); outer.append(section.slice); outer.u32(0)
        var file = PSDWriter()
        file.append(PSDFormat.signature)
        file.u16(1); file.append([UInt8](repeating: 0, count: 6)); file.u16(4)
        file.u32(2); file.u32(2); file.u16(8); file.u16(3)
        file.u32(0); file.u32(0)
        file.u32(UInt32(outer.count)); file.append(outer.slice)
        file.u16(0)
        for _ in 0..<3 { file.append([0, 0, 0, 0]) }
        file.append([255, 255, 255, 255])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString).psd")
        try Data(file.bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let workspace = ProjectWorkspace()
        Task { await workspace.receive([url]) }
        // Poll rather than await: the bug is precisely that the call never returns. The
        // window must outlast PSDImporter's shared actor serving a queued 962 MB import.
        var completed = false
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(500))
            if !workspace.isManaging, workspace.tabs.contains(where: { $0.session.document != nil }) {
                completed = true; break
            }
        }
        let state = "isManaging=\(workspace.isManaging) tabs=\(workspace.tabs.count) "
            + "docs=\(workspace.tabs.filter { $0.session.document != nil }.count) "
            + "importing=\(workspace.tabs.map { $0.session.isImporting })"
        #expect(completed, "stalled: \(state)")
    }

    /// An 8×8 asset under a 16×16 transform: the record rect and its channel rows must agree,
    /// so the writer bakes the scale instead of writing 8px rows under a 16px rect (B3).
    @Test func scaledLayerExportsRectSizedChannels() async throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 8 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let id = UUID()
        let layers = [ProjectLayerRecord(id: id, name: "放大", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 16, height: 16)),
            imageFile: "\(id).png")]
        let snapshot = ProjectSnapshot(
            manifest: ProjectManifest(documentID: UUID(), width: 16, height: 16, activeLayerID: id, layers: layers),
            images: [id: ImportedImage(image: image, thumbnail: image, name: "放大")],
            masks: [:])
        let data = try await ImageExporter.shared.psdData(snapshot)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scaled-\(UUID().uuidString).psd")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let back = try await PSDImporter.shared.importDocuments(at: url)
        #expect(back.summary.damagedLayersSkipped == 0)
        let layer = try #require(back.documents.first?.snapshot.manifest.layers.first { $0.isGroup != true })
        #expect(layer.transform.size.width == 16)
        #expect(layer.transform.size.height == 16)
    }

    /// A no-artboard mask rect spanning the I32 range used to reach decodeChannel's plane
    /// allocation with no clamp: an Int overflow trap or an astronomic allocation (B4).
    @Test func hugeMaskRectIsSkippedNotCrash() async throws {
        let maskChannel: [UInt8] = [0, 0, 255] // raw, one byte; the guard must skip before reading
        let record = Self.layerRecord(rect: (0, 0, 2, 2),
                                      channels: [(0, Self.rawPlane(255)), (1, Self.rawPlane(0)),
                                                 (2, Self.rawPlane(0)), (-2, maskChannel)],
                                      name: "A",
                                      mask: (-2_000_000_000, -2_000_000_000, 2_000_000_000, 2_000_000_000))
        var section = PSDWriter()
        section.i16(1); section.append(record.slice)
        section.append(Self.rawPlane(255)); section.append(Self.rawPlane(0))
        section.append(Self.rawPlane(0)); section.append(maskChannel)
        section.pad(to: 4)
        var outer = PSDWriter()
        outer.u32(UInt32(section.count)); outer.append(section.slice); outer.u32(0)
        var file = PSDWriter()
        file.append(PSDFormat.signature)
        file.u16(1); file.append([UInt8](repeating: 0, count: 6)); file.u16(4)
        file.u32(2); file.u32(2); file.u16(8); file.u16(3)
        file.u32(0); file.u32(0)
        file.u32(UInt32(outer.count)); file.append(outer.slice)
        file.u16(0)
        for _ in 0..<3 { file.append([0, 0, 0, 0]) }
        file.append([255, 255, 255, 255])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hm-\(UUID().uuidString).psd")
        try Data(file.bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await PSDImporter.shared.importDocuments(at: url)
        #expect(result.documents.count == 1)
        #expect(result.documents.first?.snapshot.manifest.layers.count == 1)
        #expect(result.summary.masksSkipped == 1)
    }

    /// A mask starting above/left of its artboard decodes from the clamped origin; the
    /// placement used to claim the raw mask origin, shifting the mask by the overhang (B5).
    @Test func maskReachingPastTheArtboardPlacesAtItsClampedOrigin() async throws {
        func plane(_ width: Int, _ height: Int, _ fill: UInt8) -> [UInt8] {
            [0, 0] + [UInt8](repeating: fill, count: width * height) // raw compression
        }
        var artb = PSDWriter()
        artb.u32(16); artb.u32(0)
        artb.u32(0); artb.ascii("null")
        artb.u32(1); artb.u32(12); artb.ascii("artboardRect"); artb.ascii("Objc")
        artb.u32(0); artb.u32(0); artb.ascii("Rctn"); artb.u32(4)
        func side(_ key: String, _ value: Double) {
            artb.u32(0); artb.ascii(key); artb.ascii("doub"); artb.u64(value.bitPattern)
        }
        side("Top ", 50); side("Left", 100); side("Btom", 250); side("Rght", 300)
        let seal = Self.layerRecord(rect: (0, 0, 2, 2), channels: [], name: "s", blocks: [("lsct", [0, 0, 0, 3])])
        let pixel = Self.layerRecord(rect: (0, 0, 200, 150),
                                     channels: [(0, plane(200, 150, 255)), (1, plane(200, 150, 0)),
                                                (2, plane(200, 150, 0)), (-2, plane(200, 150, 255))],
                                     name: "p", mask: (0, 0, 150, 200))
        let header = Self.layerRecord(rect: (0, 0, 2, 2), channels: [], name: "h",
                                      blocks: [("lsct", [0, 0, 0, 1]), ("artb", artb.bytes)])
        var section = PSDWriter()
        section.i16(3)
        section.append(seal.slice); section.append(pixel.slice); section.append(header.slice)
        section.append(plane(200, 150, 255)); section.append(plane(200, 150, 0))
        section.append(plane(200, 150, 0)); section.append(plane(200, 150, 255))
        section.pad(to: 4)
        var outer = PSDWriter()
        outer.u32(UInt32(section.count)); outer.append(section.slice); outer.u32(0)
        var file = PSDWriter()
        file.append(PSDFormat.signature)
        file.u16(1); file.append([UInt8](repeating: 0, count: 6)); file.u16(4)
        file.u32(250); file.u32(300); file.u16(8); file.u16(3)
        file.u32(0); file.u32(0)
        file.u32(UInt32(outer.count)); file.append(outer.slice)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID().uuidString).psd")
        try Data(file.bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await PSDImporter.shared.importDocuments(at: url)
        #expect(result.documents.count == 1)
        let masked = try #require(result.documents.first?.snapshot.manifest.layers.first { $0.maskFile != nil })
        // Clamped mask window (50,100)-(150,200) inside the artboard (50,100)-(250,300):
        // origin (0,0) in artboard-local terms and a 100×100 plane. The bug placed it at
        // (-100,-50) with the pre-clamp extents.
        #expect(masked.maskPlacement?.origin == CGPoint(x: 0, y: 0))
        #expect(masked.maskPlacement?.size == CGSize(width: 100, height: 100))
    }

}
