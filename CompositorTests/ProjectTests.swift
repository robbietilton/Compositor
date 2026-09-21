import AppKit
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
