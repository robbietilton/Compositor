import AppKit
import CoreImage
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct ProjectTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorProjectTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Saving writes `ProjectManifest.current` and `load` rejects anything outside
    /// `ProjectManifest.supported`, so the two have to agree or the app cannot reopen its own
    /// documents. This checks that directly, without touching the disk.
    @Test func theCurrentFormatVersionIsOneTheReaderAccepts() {
        #expect(ProjectManifest.supported.contains(ProjectManifest.current))
    }

    @Test func projectRoundTripSurvivesSourceRemovalAndPackageMove() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        let session = EditorSession()
        await session.importImages([source])
        try FileManager.default.removeItem(at: source)
        session.beginTransform()
        var transform = try #require(session.transformEdit?.draft)
        transform.origin = CGPoint(x: -27.5, y: 88.25)
        transform.size = CGSize(width: 123, height: 47)
        transform.rotation = 38
        transform.flipX = true
        transform.flipY = true
        transform.sampling = .nearest
        session.previewTransform(transform)
        session.commitTransform()
        let imageID = try #require(session.activeLayerID)
        session.renameLayer(imageID, to: "Paint & sky 🌤")
        session.toggleLayerVisibility(imageID)
        session.addBlankLayer()
        let before = try #require(session.projectSnapshot())
        let original = root.appendingPathComponent("Original.comp")
        let moved = root.appendingPathComponent("Moved.comp")
        try await ProjectStore.shared.save(before, to: original)
        try FileManager.default.moveItem(at: original, to: moved)
        let loaded = try await ProjectStore.shared.load(from: moved)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: moved)
        // Reloading creates new CGImage identities; compare persisted metadata here,
        // and decoded source pixels below, instead of in-memory snapshot identity.
        #expect(reopened.document?.id == session.document?.id)
        #expect(reopened.document?.size == session.document?.size)
        #expect(reopened.document?.resolution == session.document?.resolution)
        #expect(reopened.document?.layers.map(\.id) == session.document?.layers.map(\.id))
        #expect(reopened.document?.layers.map(\.name) == session.document?.layers.map(\.name))
        #expect(reopened.document?.layers.map(\.isVisible) == session.document?.layers.map(\.isVisible))
        #expect(reopened.document?.layers.map(\.transform) == session.document?.layers.map(\.transform))
        #expect(reopened.activeLayerID == session.activeLayerID)
        #expect(reopened.document?.layers.last?.asset == nil)
        #expect(!reopened.isModified)
        #expect(!reopened.canUndo)
        let image = try #require(loaded.images[imageID]?.image)
        #expect(image.width == 64 && image.height == 32)
        let bitmap = NSBitmapImageRep(cgImage: image)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).redComponent > 0.95)
        #expect(try #require(bitmap.colorAt(x: 63, y: 0)).alphaComponent == 0)
        reopened.renameLayer(imageID, to: "Edited")
        #expect(reopened.isModified)
        reopened.undo()
        #expect(!reopened.isModified)
    }

    @Test func rawSourceAndDevelopSettingsSurviveProjectRoundTrip() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let id = try #require(session.activeLayerID)
        let bytes = Data((0..<257).map { UInt8($0 & 0xff) })
        let settings = RawDevelopSettings(exposure: 1.25, temperature: 6_400, tint: -18,
                                          boost: 0.72, asShotTemperature: 5_250, asShotTint: 4)
        var asset = try #require(session.activeLayer?.asset)
        asset.rawBacking = RawBacking(data: bytes, name: "DSCF0123.RAF",
                                      typeIdentifier: "com.fujifilm.raw-image", settings: settings)
        session.document?.layers[0].asset = asset

        let snapshot = try #require(session.projectSnapshot())
        let record = try #require(snapshot.manifest.layers.first)
        #expect(snapshot.manifest.version == 12)
        #expect(record.rawFile == "\(id.uuidString).raw")
        #expect(record.rawName == "DSCF0123.RAF")
        #expect(record.rawSettings == settings)

        let url = root.appendingPathComponent("Raw.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        #expect(try Data(contentsOf: url.appendingPathComponent("raw/\(id.uuidString).raw")) == bytes)
        let loaded = try await ProjectStore.shared.load(from: url)
        let backing = try #require(loaded.images[id]?.rawBacking)
        #expect(backing.data == bytes)
        #expect(backing.name == "DSCF0123.RAF")
        #expect(backing.typeIdentifier == "com.fujifilm.raw-image")
        #expect(backing.settings == settings)
    }

    @Test func legacyAndInvalidRawMetadataAreRejected() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        await session.importImages([try ImageImportTests().fixture(.png)])
        let snapshot = try #require(session.projectSnapshot())
        var legacy = snapshot.manifest
        legacy.version = 11
        legacy.layers[0].rawFile = "\(legacy.layers[0].id.uuidString).raw"
        legacy.layers[0].rawName = "source.raf"
        legacy.layers[0].rawSettings = RawDevelopSettings()
        do {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: legacy, images: snapshot.images),
                                                to: root.appendingPathComponent("Legacy.comp"))
            Issue.record("Version 11 accepted RAW metadata")
        } catch {}

        var invalid = snapshot.manifest
        invalid.layers[0].rawFile = "\(invalid.layers[0].id.uuidString).raw"
        invalid.layers[0].rawName = "source.raf"
        invalid.layers[0].rawSettings = RawDevelopSettings(exposure: 100)
        do {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: invalid, images: snapshot.images),
                                                to: root.appendingPathComponent("Invalid.comp"))
            Issue.record("Out-of-range RAW settings were accepted")
        } catch {}
    }

    @Test func expandedRawSettingsDecodeOldVersion12ValuesAndAdjustTones() throws {
        let old = Data(#"{"exposure":0.5,"temperature":5400,"tint":3,"boost":0.8,"asShotTemperature":5200,"asShotTint":1}"#.utf8)
        let decoded = try JSONDecoder().decode(RawDevelopSettings.self, from: old)
        #expect(decoded.highlights == 0 && decoded.shadows == 0 && decoded.whites == 0 && decoded.blacks == 0)
        #expect(decoded.curves.channels == CurvesSettings().channels)

        let extent = CGRect(x: 0, y: 0, width: 1, height: 1)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        func red(_ level: CGFloat, _ settings: RawDevelopSettings) throws -> CGFloat {
            let input = CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: extent)
            let adjusted = try #require(RawImporter.toneAdjusted(input, settings: settings))
            let image = try #require(context.createCGImage(adjusted, from: extent, format: .RGBA8,
                                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
            return try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)).redComponent
        }
        let dark = try red(0.05, RawDevelopSettings())
        let lifted = try red(0.05, RawDevelopSettings(shadows: 100, blacks: 100))
        #expect(lifted > dark)
        let bright = try red(0.9, RawDevelopSettings())
        let recovered = try red(0.9, RawDevelopSettings(highlights: -100, whites: -100))
        #expect(recovered < bright)

        var curve = CurvesSettings()
        curve.channels[0] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 128, y: 210), CurvePoint(x: 255, y: 255)]
        #expect(try red(0.25, RawDevelopSettings(curves: curve)) > red(0.25, RawDevelopSettings()))
    }

    @Test func rawDevelopHistogramIncludesRGBAndLuminance() throws {
        let context = try BrushRaster.context(width: 2, height: 1, mask: false)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let image = try #require(context.makeImage())
        let result = try #require(RawDevelopHistogram.make(image))
        #expect(result.red[255] == 2)
        #expect(result.green[0] == 1 && result.green[255] == 1)
        #expect(result.blue[0] == 1 && result.blue[255] == 1)
        #expect(result.luminance[54] == 1, "Rec. 709 red is approximately code value 54")
        #expect(result.luminance[255] == 1)
    }

    /// Folders took an opacity of their own in 1.1.6, but project validation still demanded that
    /// every folder be fully opaque, so a document with a dimmed folder could not be saved at all.
    @Test func aDimmedFolderSavesAndReopens() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        await session.importImages([try ImageImportTests().fixture(.png)])
        let child = try #require(session.activeLayerID)
        session.selectLayers([child], primary: child)
        session.addGroup()
        let folder = try #require(session.activeLayerID)
        session.selectLayers([folder], primary: folder)
        session.setLayerOpacity(0.5)
        #expect(session.document?.layers.first { $0.id == folder }?.opacity == 0.5)

        let url = root.appendingPathComponent("Dimmed.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let saved = try #require(loaded.manifest.layers.first { $0.isGroup == true })
        #expect(saved.opacity == 0.5)
    }

    @Test func overwriteReplacesPackageAndDropsRemovedAssets() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let destination = root.appendingPathComponent("Overwrite.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: destination)
        session.deleteActiveLayer()
        session.addBlankLayer()
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: destination)
        let loaded = try await ProjectStore.shared.load(from: destination)
        #expect(loaded.images.isEmpty)
        #expect(loaded.manifest.layers.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("images").path).isEmpty)
    }

    @Test func failedSavePreservesPreviouslySavedPackage() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 80)
        session.addBlankLayer()
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Safe.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let original = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        var invalid = snapshot.manifest
        invalid.version = 99
        do {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: invalid, images: [:]), to: url)
            Issue.record("Unsupported version was saved")
        } catch {}
        #expect(try Data(contentsOf: url.appendingPathComponent("manifest.json")) == original)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.count == 1)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocker)
        do {
            try await ProjectStore.shared.save(snapshot, to: blocker.appendingPathComponent("CannotSave.comp"))
            Issue.record("Writing through a regular file unexpectedly succeeded")
        } catch {}
        #expect(try Data(contentsOf: url.appendingPathComponent("manifest.json")) == original)
    }

    @Test func unsupportedCorruptAndUnsafeMetadataAreRejected() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 80)
        session.addBlankLayer()
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Invalid.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let metadata = url.appendingPathComponent("manifest.json")
        var future = snapshot.manifest
        future.version = 42
        try JSONEncoder().encode(future).write(to: metadata)
        do {
            _ = try await ProjectStore.shared.load(from: url)
            Issue.record("Future version opened")
        } catch ProjectError.version(let version) { #expect(version == 42) }
        let record = try #require(snapshot.manifest.layers.first)
        var unsafe = snapshot.manifest
        unsafe.layers = [ProjectLayerRecord(id: record.id, name: record.name, isVisible: true,
            transform: record.transform, imageFile: "../../outside.png")]
        try JSONEncoder().encode(unsafe).write(to: metadata)
        do { _ = try await ProjectStore.shared.load(from: url); Issue.record("Path traversal accepted") }
        catch {}
        try Data("not json".utf8).write(to: metadata)
        do { _ = try await ProjectStore.shared.load(from: url); Issue.record("Corrupt metadata accepted") }
        catch {}
        #expect(session.document?.layers.count == 1)
    }

    @Test func missingEmbeddedImageIsRejected() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Missing.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let filename = try #require(snapshot.manifest.layers.first?.imageFile)
        try FileManager.default.removeItem(at: url.appendingPathComponent("images").appendingPathComponent(filename))
        do { _ = try await ProjectStore.shared.load(from: url); Issue.record("Missing image accepted") }
        catch {}
    }

    @Test func projectOperationsBlockEditsAndQueueImageImports() async throws {
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.addBlankLayer()
        let before = session.document
        session.isProjectBusy = true
        session.deleteActiveLayer()
        session.createDocument(width: 400, height: 400)
        session.undo()
        #expect(session.document == before)
        let pending = Task { await session.importImages([source]) }
        await Task.yield()
        #expect(!session.isImporting)
        session.isProjectBusy = false
        await pending.value
        #expect(session.document?.layers.count == 2)
        session.clearProject()
        #expect(session.document == nil && session.projectURL == nil)
        #expect(!session.isModified && !session.canUndo)
    }

    @Test func projectRoundTripPreservesAllLayerEffects() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let id = try #require(session.activeLayerID)

        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 8, red: 0.1, green: 0.8, blue: 0.2, opacity: 0.9, inside: false)
        effects.shadow = ShadowEffect(angle: 45, distance: 15, blur: 10, red: 0.2, green: 0.2, blue: 0.3, opacity: 0.75)
        effects.colorOverlay = ColorOverlayEffect(red: 0.9, green: 0.1, blue: 0.4, opacity: 0.65)
        effects.innerShadow = InnerShadowEffect(angle: 135, distance: 6, blur: 4, red: 0.05, green: 0.05, blue: 0.05, opacity: 0.5)
        session.setEffects(effects, on: id)

        #expect(session.activeLayer?.effects == effects)

        let snapshot = try #require(session.projectSnapshot())
        let record = try #require(snapshot.manifest.layers.first { $0.id == id })
        #expect(record.effects == effects)

        let fileURL = root.appendingPathComponent("EffectsProject.comp")
        try await ProjectStore.shared.save(snapshot, to: fileURL)

        let loaded = try await ProjectStore.shared.load(from: fileURL)
        let loadedRecord = try #require(loaded.manifest.layers.first { $0.id == id })
        #expect(loadedRecord.effects == effects)

        let reopened = EditorSession()
        reopened.installProject(loaded, from: fileURL)

        let restored = try #require(reopened.document?.layers.first { $0.id == id })
        #expect(restored.effects == effects)

        // Verify individual effect parameters survive round trip
        let stroke = try #require(restored.effects?.stroke)
        #expect(stroke.size == 8)
        #expect(!stroke.inside)
        #expect(stroke.opacity == 0.9)
        #expect(abs(stroke.red - 0.1) < 0.001 && abs(stroke.green - 0.8) < 0.001)

        let shadow = try #require(restored.effects?.shadow)
        #expect(shadow.angle == 45)
        #expect(shadow.distance == 15)
        #expect(shadow.blur == 10)
        #expect(shadow.opacity == 0.75)

        let colorOverlay = try #require(restored.effects?.colorOverlay)
        #expect(colorOverlay.opacity == 0.65)
        #expect(abs(colorOverlay.red - 0.9) < 0.001 && abs(colorOverlay.blue - 0.4) < 0.001)

        let innerShadow = try #require(restored.effects?.innerShadow)
        #expect(innerShadow.angle == 135)
        #expect(innerShadow.distance == 6)
        #expect(innerShadow.blur == 4)
        #expect(innerShadow.opacity == 0.5)
    }

    @Test func layerEffectsAreRenderedInExport() async throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
            bytesPerRow: 80, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let redImage = try #require(context.makeImage())

        let session = EditorSession()
        session.createDocument(width: 60, height: 60)
        session.insert(ImportedImage(image: redImage, thumbnail: redImage, name: "Square"))

        let id = try #require(session.activeLayerID)
        session.document?.layers[0].transform = LayerTransform(origin: CGPoint(x: 20, y: 20), size: CGSize(width: 20, height: 20))

        // Before adding effects, area outside the layer is transparent
        let unstyledSnapshot = try #require(session.projectSnapshot())
        let unstyledRaster = try await ImageExporter.shared.render(unstyledSnapshot)
        let unstyledBitmap = NSBitmapImageRep(cgImage: unstyledRaster.image)
        #expect(try #require(unstyledBitmap.colorAt(x: 15, y: 30)).alphaComponent == 0)
        #expect(try #require(unstyledBitmap.colorAt(x: 30, y: 30)).redComponent > 0.9)

        // Apply outside green stroke of width 6px
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 6, red: 0, green: 1, blue: 0, opacity: 1, inside: false)
        session.setEffects(effects, on: id)

        let styledSnapshot = try #require(session.projectSnapshot())
        #expect(styledSnapshot.manifest.layers.first?.effects != nil)

        let styledRaster = try await ImageExporter.shared.render(styledSnapshot)
        let styledBitmap = NSBitmapImageRep(cgImage: styledRaster.image)

        // Pixel at (15, 30) is 5px to the left of the layer (x=20..40), inside the 6px stroke
        let strokePixel = try #require(styledBitmap.colorAt(x: 15, y: 30))
        #expect(strokePixel.greenComponent > 0.9)
        #expect(strokePixel.alphaComponent > 0.9)

        // The layer itself at (30, 30) remains red
        let centerPixel = try #require(styledBitmap.colorAt(x: 30, y: 30))
        #expect(centerPixel.redComponent > 0.9)
    }
}
