import AppKit
import Testing
import zlib
import ImageIO
@testable import Compositor

@MainActor
struct ProcreateBrushImportTests {
    private func keyed(name: String = "Example", shape: String = "Hard.png", grain: String? = nil, badReference: Int? = nil) throws -> Data {
        let uid: (Int) -> [String: Int] = { ["CF$UID": $0] }
        let root: [String: Any] = ["name": uid(badReference ?? 2), "bundledShapePath": uid(3),
                                   "bundledGrainPath": uid(grain == nil ? 0 : 5), "$class": uid(4), "unknownFutureSetting": [1, 2, 3]]
        return try PropertyListSerialization.data(fromPropertyList: ["$archiver": "NSKeyedArchiver", "$version": 100000,
            "$top": ["root": uid(1)], "$objects": ["$null", root, name, shape,
                ["$classname": "NeverInstantiateThisClass", "$classes": ["NeverInstantiateThisClass", "NSObject"]], grain ?? "$null"]], format: .xml, options: 0)
    }
    private func zip(_ entries: [(String, Data)], symlink: Bool = false) -> Data {
        var body = Data(), directory = Data()
        func little(_ number: Int, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) }) }
        for (name, data) in entries {
            let path = Data(name.utf8)
            let crc = Int(data.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) })
            let offset = body.count
            for (number, bytes) in [(0x04034b50,4),(20,2),(0x800,2),(0,2),(0,2),(0,2),(crc,4),(data.count,4),(data.count,4),(path.count,2),(0,2)] {
                body.append(little(number, bytes))
            }
            body.append(path); body.append(data)
            for (number, bytes) in [(0x02014b50,4),(0x314,2),(20,2),(0x800,2),(0,2),(0,2),(0,2),(crc,4),
                (data.count,4),(data.count,4),(path.count,2),(0,2),(0,2),(0,2),(0,2),(symlink ? 0o120777 << 16 : 0,4),(offset,4)] {
                directory.append(little(number, bytes))
            }
            directory.append(path)
        }
        let start = body.count
        body.append(directory)
        for (number, bytes) in [(0x06054b50,4),(0,2),(0,2),(entries.count,2),(entries.count,2),(directory.count,4),(start,4),(0,2)] {
            body.append(little(number, bytes))
        }
        return body
    }

    @Test func modernOrderingDualResetAndUnknownClassesAreDataOnly() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["brushes": ["B", "A"], "name": "My Set"], format: .binary, options: 0)
        let bytes = zip([("A/Brush.archive", try keyed(name: "First")), ("B/Brush.archive", try keyed(name: "Second")),
                         ("B/Sub01/Brush.archive", try keyed(name: "Secondary")), ("B/Reset/Brush.archive", try keyed(name: "Reset")),
                         ("brushset.plist", plist)])
        let result = try ProcreateBrushImporter.read(bytes, filename: "Set.brushset")
        #expect(result.brushes.map(\.name) == ["Second", "First"])
        #expect(result.brushes[0].source?.definitions.map(\.path) == ["B/Brush.archive", "B/Sub01/Brush.archive"])
        #expect(result.brushes[0].source?.collectionName == "My Set")
        #expect(result.diagnostics.contains { $0.contains("Shape not embedded: Hard.png") })
        #expect(result.diagnostics.contains { $0.contains("Dual brush") })
    }

    @Test func repeatedOpaqueDataDoesNotExpandThroughXML() throws {
        var archive = try #require(PropertyListSerialization.propertyList(from: keyed(), format: nil) as? [String: Any])
        var objects = try #require(archive["$objects"] as? [Any])
        var root = try #require(objects[1] as? [String: Any])
        root["unknownRepeatedData"] = Array(repeating: Data(repeating: 42, count: 16384), count: 100)
        objects[1] = root; archive["$objects"] = objects
        let bytes = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        #expect(bytes.count < 2 * 1024 * 1024)
        let result = try ProcreateBrushImporter.read(zip([("Brush.archive", bytes)]), filename: "Repeated.brush")
        #expect(result.brushes.first?.name == "Example")
    }

    @Test func libraryOrderUsesSignedOffsetsAndKeepsNestedIdentity() throws {
        let first = zip([("Brush.archive", try keyed(name: "A"))])
        let second = zip([("Brush.archive", try keyed(name: "B"))])
        let bytes = zip([("Set/A.brush", first), ("Set/B.brush", second),
            (".procreate_meta.test", Data("Set/0/0\n\0opaque".utf8)),
            ("Set/.procreate_meta.test", Data("A.brush/1/0\nB.brush/-1/0\n\0opaque".utf8))])
        let result = try ProcreateBrushImporter.read(bytes, filename: "Library.brushlibrary")
        #expect(result.brushes.map(\.name) == ["B", "A"])
        #expect(result.brushes.map { $0.source?.memberPath } == ["Set/B.brush", "Set/A.brush"])
        #expect(result.brushes[0].source?.definitions.first?.path == "Brush.archive")
        let fallback = try ProcreateBrushImporter.read(zip([("Z/B.brush", second), ("A/A.brush", first)]), filename: "Library.brushlibrary")
        #expect(fallback.brushes.map(\.name) == ["B", "A"])
    }

    @Test func rejectsUnsafeContainersAndObjectReferencesWithoutPublishing() throws {
        let valid = try keyed()
        for entries in [[("../Brush.archive", valid)], [("/Brush.archive", valid)],
                        [("Brush.archive", valid), ("brush.archive", valid)],
                        [("Brush.archive", try keyed(badReference: 999))],
                        [("Brush.archive", try keyed(badReference: 1))],
                        [("Brush.archive", try keyed(shape: "../outside.png"))],
                        [("Sub01/Brush.archive", valid)]] {
            #expect(throws: (any Error).self) { try ProcreateBrushImporter.read(zip(entries), filename: "Bad.brush") }
        }
        #expect(throws: (any Error).self) { try ProcreateBrushImporter.read(zip([("Brush.archive", valid)], symlink: true), filename: "Bad.brush") }
        var corrupt = zip([("Brush.archive", valid)])
        corrupt[30 + "Brush.archive".utf8.count] ^= 1
        #expect(throws: (any Error).self) { try ProcreateBrushImporter.read(corrupt, filename: "Bad.brush") }
        #expect(throws: (any Error).self) { try ProcreateBrushImporter.read(Data(corrupt.dropLast()), filename: "Bad.brush") }
        var oversized = zip([("Brush.archive", valid)])
        let central = oversized.count - 22 - 46 - "Brush.archive".utf8.count
        for index in 0..<4 { oversized[central + 24 + index] = 255 }
        #expect(throws: (any Error).self) { try ProcreateBrushImporter.read(oversized, filename: "Bad.brush") }
    }

    @Test func importIsAtomicDeduplicatedRetainedAndDoesNotSelectUnsupportedBrushes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("brushes.json")
        let library = BrushLibrary(url: file)
        try library.save(library.current)
        let selection = library.selectedID
        let bytes = zip([("Brush.archive", try keyed()), ("Reset/Brush.archive", try keyed(name: "Reset"))])
        let result = try ProcreateBrushImporter.read(bytes, filename: "Example.brush")
        #expect(try library.importBrushes(result, original: bytes) == 1)
        #expect(library.selectedID == selection)
        let stored = try #require(library.brushes.last?.source)
        #expect(try library.sourceData(for: stored) == bytes)
        #expect(try library.importBrushes(result, original: bytes) == 0)
        #expect(BrushLibrary(url: file).brushes == library.brushes)
        let before = try Data(contentsOf: file)
        #expect(throws: (any Error).self) { try library.importBrushes(result, original: Data([0])) }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func exactMappingsEmbeddedPrecedenceAndIndependentGrain() throws {
        let context = try BrushRaster.context(width: 4, height: 4, mask: false)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let grainedBytes = zip([("B/Brush.archive", try keyed(shape: BasicBrushShape.hard.rawValue, grain: "Texture.png")), ("B/Texture.png", png)])
        var grained = try #require(ProcreateBrushImporter.read(grainedBytes, filename: "Grain.brushset").brushes.first)
        #expect(grained.source?.definitions.first?.nativeGrainTip?.isValid == true && !grained.isRenderable)
        grained.usesShapeApproximation = true
        grained.roundDynamics.grain = BrushGrain(source: .original)
        #expect(grained.isValid && grained.isRenderable)
        grained.source?.definitions[0].grainResolution = .embedded(path: "Other/Texture.png")
        #expect(!grained.isValid && !grained.isRenderable, "Grain must belong to the selected component")

        for shape in BasicBrushShape.allCases {
            let bytes = zip([("Brush.archive", try keyed(shape: shape.rawValue))])
            let brush = try #require(ProcreateBrushImporter.read(bytes, filename: "Example.brush").brushes.first)
            #expect(brush.source?.definitions.first?.shapeResolution == .procedural(shape, revision: BasicBrushShape.revision))
            #expect(brush.source?.definitions.first?.shapeReference == shape.rawValue)
            #expect(brush.canApproximateRound && !brush.isRenderable, "Mapping identity never silently opts into rendering")
            let embedded = zip([("B/Brush.archive", try keyed(shape: shape.rawValue)), ("B/" + shape.rawValue, png)])
            let resolved = try #require(ProcreateBrushImporter.read(embedded, filename: "Example.brushset").brushes.first)
            #expect(resolved.source?.definitions.first?.shapeResolution == .embedded(path: "B/" + shape.rawValue))
            #expect(!resolved.canApproximateRound && resolved.canApproximateShape && !resolved.isRenderable)
            #expect(resolved.source?.definitions.first?.tip?.isValid == true)
            var mismatched = resolved
            mismatched.source?.definitions[0].shapeResolution = .embedded(path: "Other/" + shape.rawValue)
            mismatched.usesShapeApproximation = true
            #expect(!mismatched.canApproximateShape && !mismatched.isRenderable)
            var enabled = resolved; enabled.usesShapeApproximation = true
            #expect(enabled.isRenderable && enabled.applying(to: BrushSettings()).shapeTip != nil)
            let imageStroke = try BrushStroke(layer: ImageLayer(name: "Image", blankSize: CGSize(width: 64, height: 64)),
                mask: false, settings: enabled.applying(to: BrushSettings()), canvas: CGSize(width: 64, height: 64))
            try imageStroke.append(CGPoint(x: 32, y: 32)); try imageStroke.flush()
            #expect(!imageStroke.patches.isEmpty)
        }
        context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let black = try #require(context.makeImage())
        let blackPNG = try #require(NSBitmapImageRep(cgImage: black).representation(using: .png, properties: [:]))
        let bytes = zip([
            ("B/Brush.archive", try keyed(shape: "GL-Volcanic-Grain.png", grain: "Missing.png")),
            ("B/GL-Volcanic-Grain.png", png), ("B/Shape.png", blackPNG),
            ("B/Sub01/Brush.archive", try keyed(shape: "custom.asset")), ("B/Sub01/custom.asset", blackPNG)
        ])
        let brush = try #require(ProcreateBrushImporter.read(bytes, filename: "Example.brushset").brushes.first)
        #expect(brush.source?.definitions[0].shapeResolution == .embedded(path: "B/GL-Volcanic-Grain.png"))
        #expect(brush.source?.definitions[0].grainResolution == .missing)
        #expect(brush.source?.definitions[1].shapeResolution == .embedded(path: "B/Sub01/custom.asset"))
        #expect(!brush.canApproximateRound && !brush.canApproximateShape)
        #expect(brush.source?.definitions[0].tip?.isValid == true && brush.source?.definitions[1].tip?.isValid == true)
        #expect(brush.source?.definitions[0].tip?.luminance.allSatisfy { $0 == 255 } == true)
        #expect(brush.source?.definitions[1].tip?.luminance.allSatisfy { $0 == 0 } == true)
        for reference in ["Custom/Brush-Preset-Hard.png", "brush-preset-hard.png", "Unknown.png"] {
            let unresolved = zip([("B/Brush.archive", try keyed(shape: reference)), ("Other/" + reference, png)])
            let result = try #require(ProcreateBrushImporter.read(unresolved, filename: "Unknown.brushset").brushes.first)
            #expect(result.source?.definitions.first?.shapeResolution == .missing)
            #expect(!result.canApproximateRound)
        }
        let absent = zip([("Brush.archive", try keyed(shape: "$null"))])
        let noShape = try #require(ProcreateBrushImporter.read(absent, filename: "Absent.brush").brushes.first)
        #expect(noShape.source?.definitions.first?.shapeReference == nil)
        #expect(noShape.source?.definitions.first?.shapeResolution == .missing)
        let dual = zip([("Brush.archive", try keyed(shape: BasicBrushShape.hard.rawValue)),
                        ("Sub01/Brush.archive", try keyed(shape: BasicBrushShape.hard.rawValue))])
        let combined = try #require(ProcreateBrushImporter.read(dual, filename: "Dual.brush").brushes.first)
        #expect(!combined.canApproximateRound)
        let withGrain = zip([("Brush.archive", try keyed(shape: BasicBrushShape.hard.rawValue, grain: "Unknown.png"))])
        let blocked = try #require(ProcreateBrushImporter.read(withGrain, filename: "Grain.brush").brushes.first)
        #expect(blocked.source?.definitions.first?.shapeResolution == .procedural(.hard, revision: BasicBrushShape.revision))
        #expect(!blocked.canApproximateRound)
        #expect(throws: (any Error).self) {
            try ProcreateBrushImporter.read(zip([("Brush.archive", try keyed(shape: "invalid.asset")),
                ("invalid.asset", Data([1]))]), filename: "Bad.brush")
        }
        let corrupt = zip([("B/Brush.archive", try keyed(shape: "Broken.asset")), ("B/Broken.asset", Data([1, 2, 3]))])
        #expect(throws: (any Error).self) { try ProcreateBrushImporter.read(corrupt, filename: "Corrupt.brushset") }
        let multi = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(multi, "public.tiff" as CFString, 2, nil))
        CGImageDestinationAddImage(destination, image, nil); CGImageDestinationAddImage(destination, black, nil)
        #expect(CGImageDestinationFinalize(destination))
        let unsupported = zip([("B/Brush.archive", try keyed(shape: "Multipage.asset")), ("B/Multipage.asset", multi as Data)])
        let retained = try #require(ProcreateBrushImporter.read(unsupported, filename: "Unsupported.brushset").brushes.first)
        #expect(retained.source?.definitions.first?.shapeResolution == .embedded(path: "B/Multipage.asset"))
        #expect(retained.source?.definitions.first?.tip == nil && !retained.isRenderable)
        #expect(retained.source?.issues?.contains { $0.contains("Shape image unavailable") } == true)

    }

    @Test func cataloguedMissingTipsRequireExplicitIndependentSubstitution() throws {
        let original = zip([("Brush.archive", try keyed(shape: "Acrylic-Dab-2.png"))])
        var brush = try #require(ProcreateBrushImporter.read(original, filename: "Missing.brush").brushes.first)
        #expect(brush.source?.definitions.first?.shapeResolution == .cataloguedMissing && !brush.isRenderable)
        #expect(brush.source?.definitions.first?.tip == nil)
        brush.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles)
        brush.usesShapeApproximation = true
        #expect(brush.isRenderable && brush.canApproximateShape)
        #expect(brush.source?.definitions.first?.shapeReference == "Acrylic-Dab-2.png")
        #expect(brush.source?.definitions.first?.shapeResolution == .cataloguedMissing)
        let stroke = try BrushStroke(layer: ImageLayer(name: "Generated", blankSize: CGSize(width: 64, height: 64)),
            mask: false, settings: brush.applying(to: BrushSettings()), canvas: CGSize(width: 64, height: 64))
        try stroke.append(CGPoint(x: 32, y: 32)); try stroke.flush(); #expect(!stroke.patches.isEmpty)
        let image = try #require(asymmetricBrushShapeTip().preview(.luminance))
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let supplied = zip([("Brush.archive", try keyed(shape: "Acrylic-Dab-2.png")), ("Acrylic-Dab-2.png", png)])
        let embedded = try #require(ProcreateBrushImporter.read(supplied, filename: "Supplied.brush").brushes.first)
        #expect(embedded.source?.definitions.first?.shapeResolution == .embedded(path: "Acrylic-Dab-2.png"))
        #expect(embedded.roundDynamics.shapeSettings.source == .embedded, "Supplied images take precedence over the name catalog")
        let grain = zip([("Brush.archive", try keyed(shape: "Acrylic-Dab-2.png", grain: "Acrylic-Grit.jpg"))])
        var textured = try #require(ProcreateBrushImporter.read(grain, filename: "Grain.brush").brushes.first)
        textured.roundDynamics.shape = brush.roundDynamics.shape; textured.usesShapeApproximation = true
        #expect(textured.source?.definitions.first?.grainResolution == .cataloguedMissing)
        #expect(!textured.isRenderable, "A generated shape cannot silently discard missing grain")
    }

    @Test func derivedImageMasksHaveAnAggregateBudget() throws {
        let context = try BrushRaster.context(width: 256, height: 256, mask: false)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let definition = try keyed(shape: "Tip.png")
        let entries: [(String, Data)] = (0..<65).flatMap { [("B\($0)/Brush.archive", definition), ("B\($0)/Tip.png", png)] }
        #expect(throws: (any Error).self) { try ProcreateBrushImporter.read(zip(entries), filename: "TooManyMasks.brushset") }
    }

    @Test func explicitCalibrationSurvivesRemappingAndUsesNativeRoundOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("brushes.json")
        let library = BrushLibrary(url: url)
        let atlas = try BrushRaster.context(width: 320, height: 240 * 5, mask: false)
        atlas.setFillColor(NSColor.white.cgColor)
        atlas.fill(CGRect(x: 0, y: 0, width: 320, height: 240 * 5))
        for (index, shape) in BasicBrushShape.allCases.enumerated() {
            let bytes = zip([("Brush.archive", try keyed(shape: shape.rawValue))])
            let imported = try ProcreateBrushImporter.read(bytes, filename: "Example.brush")
            _ = try library.importBrushes(imported, original: bytes)
            var brush = try #require(library.brushes.last)
            #expect(throws: (any Error).self) { try EditorSession().activateBrushPreset(brush, library: library) }
            brush.usesRoundApproximation = true
            if shape == .hard {
                #expect(brush.roundDynamics.shapeSettings.source == .procedural, "The existing hard-round mapping keeps its fast renderer")
            } else {
                #expect(brush.roundDynamics.shapeSettings.generatedKind == shape.generatedTip)
                #expect(brush.roundDynamics.shapeSettings.source == .generated)
            }
            // Native five-profile approximations, not a claim of matching source rendering.
            brush.diameter = 60; brush.opacity = 0.7; brush.pressureSize = true
            try library.save(brush)
            var legacyMapping = brush
            legacyMapping.source?.definitions[0].shapeResolution = .procedural(shape, revision: 1)
            #expect(legacyMapping.canApproximateRound, "Revision-one overrides must remain usable")
            legacyMapping.hardness = 0.37; legacyMapping.roundDynamics.shape = nil; legacyMapping.roundDynamics.flow = 0.12
            let refreshedLegacy = try ProcreateBrushImporter.remap(legacyMapping, original: bytes)
            #expect(refreshedLegacy.hardness == 0.37 && refreshedLegacy.roundDynamics.flow == 0.12)
            #expect(refreshedLegacy.roundDynamics.shapeSettings.source == .procedural, "Refreshing metadata must not replace a user's old native tip")

            legacyMapping.source?.definitions[0].shapeResolution = .procedural(shape, revision: BasicBrushShape.revision + 1)
            #expect(!legacyMapping.canApproximateRound)
            let selected = library.selectedID
            var inspected = brush; inspected.usesRoundApproximation = false
            try library.save(inspected, select: false)
            #expect(library.selectedID == selected)
            try library.save(brush)
            var legacy = brush
            legacy.source?.definitions[0].shapeResolution = nil
            let remapped = try ProcreateBrushImporter.remap(legacy, original: bytes)
            #expect(remapped == brush, "Re-resolution must preserve explicit calibration and opt-in")
            #expect(try library.sourceData(for: brush.source!) == bytes)
            let restored = try #require(BrushLibrary(url: url).brushes.first { $0.id == brush.id })
            #expect(restored == brush && restored.isRenderable)
            let preview = BrushDrawingView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
            preview.preset = remapped; preview.reset()
            preview.beginStroke(at: CGPoint(x: 40, y: 120), pressure: 0.2)
            preview.continueStroke(at: CGPoint(x: 150, y: 100), pressure: 0.6)
            preview.continueStroke(at: CGPoint(x: 270, y: 140), pressure: 1)
            preview.endStroke()
            #expect(preview.session.activeLayer?.asset != nil, "The approximation must paint visible pixels")
            let actual = try await ImageExporter.shared.render(try #require(preview.session.projectSnapshot())).image
            var native = brush; native.source = nil; native.usesRoundApproximation = false
            preview.preset = native; preview.reset(clearing: false)
            let expected = try await ImageExporter.shared.render(try #require(preview.session.projectSnapshot())).image
            #expect(NSBitmapImageRep(cgImage: actual).representation(using: .png, properties: [:])
                == NSBitmapImageRep(cgImage: expected).representation(using: .png, properties: [:]))
            atlas.draw(actual, in: CGRect(x: 0, y: index * 240, width: 320, height: 240))
        }
        let image = try #require(atlas.makeImage())
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        Attachment.record(data, named: "native-round-profile-sweep.png")
    }

    @Test func suppliedProcreateExportsWhenAvailable() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("procreate")
        guard FileManager.default.fileExists(atPath: folder.path) else {
            print("Local Procreate acceptance skipped: user-supplied fixtures are not distributed."); return
        }
        let samples = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["brush", "brushset", "brushlibrary"].contains($0.pathExtension.lowercased()) || $0.lastPathComponent.lowercased().hasSuffix(".brushset.zip") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(samples.contains { $0.lastPathComponent == "Gggg.brush" })
        var definitions = 0, brushes = 0
        for sample in samples {
            let result = try ProcreateBrushImporter.read(Data(contentsOf: sample), filename: sample.lastPathComponent)
            #expect(!result.brushes.isEmpty)
            definitions += result.brushes.reduce(0) { $0 + ($1.source?.definitions.count ?? 0) }
            brushes += result.brushes.count
            if sample.lastPathComponent == "Design.brushset" {
                #expect(result.brushes.first?.name == "Peregrine")
                #expect(result.brushes.count == 10)
            }
            if sample.lastPathComponent == "Classic Library.brushlibrary" {
                #expect(result.brushes.first?.name == "Peppermint")
                let volcanic = try #require(result.brushes.first { $0.name == "Volcanic Ash" })
                #expect(volcanic.source?.definitions.first?.shapeReference == "GL-Volcanic-Grain.png")
                #expect(volcanic.source?.issues?.contains { $0.contains("Shape not embedded") } == false)
                #expect(volcanic.source?.definitions.first?.shapeResolution == .embedded(path: "GL-Volcanic-Grain.png"))
            }
            if sample.lastPathComponent == "Gggg.brush" {
                #expect(result.brushes.first?.source?.definitions.first?.shapeResolution == .procedural(.hard, revision: BasicBrushShape.revision))
                #expect(result.brushes.first?.canApproximateRound == true)
            }
            print("Procreate acceptance: \(sample.lastPathComponent), \(result.brushes.count) brushes")
        }
        print("Procreate acceptance total: \(samples.count) containers, \(brushes) brushes, \(definitions) definitions (Warptuner removed)")
    }
}
