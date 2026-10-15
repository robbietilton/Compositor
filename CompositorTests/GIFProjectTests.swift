import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct GIFProjectTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorGIFProjectTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func coverage(left: UInt8, right: UInt8) throws -> LayerMask {
        let bytes = (0..<(32 * 24)).map { $0 % 32 < 16 ? left : right }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: 32, height: 24, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return LayerMask(asset: try LayerMask.asset(from: image))
    }

    private func metadata(_ source: ProjectManifest, gifChanges: [String: Any], version: Int? = nil) throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        var layers = try #require(json["layers"] as? [[String: Any]])
        var gif = try #require(layers[0]["gif"] as? [String: Any])
        for (key, value) in gifChanges {
            if value is NSNull { gif.removeValue(forKey: key) }
            else { gif[key] = value }
        }
        layers[0]["gif"] = gif
        json["layers"] = layers
        if let version { json["version"] = version }
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func manifest(_ source: ProjectManifest, gifChanges: [String: Any], version: Int? = nil) throws -> ProjectManifest {
        try JSONDecoder().decode(ProjectManifest.self, from: metadata(source, gifChanges: gifChanges, version: version))
    }

    @Test func animatedLayersRoundTripAfterSourceRemovalPackageMoveAndResave() async throws {
        let root = try temporaryFolder()
        let firstURL = try ImageImportTests().animatedGIFFixture(delays: [0.04, 0.16])
        let secondURL = try ImageImportTests().animatedGIFFixture(delays: [0.08, 0.24])
        let stillURL = try ImageImportTests().fixture(.png)
        defer {
            try? FileManager.default.removeItem(at: root)
            for url in [firstURL, secondURL, stillURL] { try? FileManager.default.removeItem(at: url) }
        }
        let firstBytes = try Data(contentsOf: firstURL)
        let secondBytes = try Data(contentsOf: secondURL)
        let session = EditorSession()
        await session.importImages([firstURL])
        let firstID = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(1)
        await session.importImages([secondURL])
        let secondID = try #require(session.activeLayerID)
        await session.importImages([stillURL])
        let stillID = try #require(session.activeLayerID)
        session.selectLayer(firstID)
        session.toggleGIFPlayback(for: firstID)
        #expect(session.gifTimelineIsPlaying)
        for url in [firstURL, secondURL, stillURL] { try FileManager.default.removeItem(at: url) }

        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == ProjectManifest.current)
        #expect(Set(snapshot.animations.keys) == [firstID, secondID])
        let original = root.appendingPathComponent("Original.comp")
        let moved = root.appendingPathComponent("Moved.comp")
        try await ProjectStore.shared.save(snapshot, to: original)
        try FileManager.default.moveItem(at: original, to: moved)
        let loaded = try await ProjectStore.shared.load(from: moved)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: moved)
        #expect(reopened.document?.layers.map(\.id) == session.document?.layers.map(\.id))
        #expect(reopened.activeLayerID == firstID)
        #expect(reopened.gifTimelineSelectedFrameIndex == 1)
        #expect(!reopened.gifTimelineIsPlaying && !reopened.isMaskSelected)
        #expect(!reopened.isModified && !reopened.canUndo)
        #expect(loaded.animations[firstID]?.source.data == firstBytes)
        #expect(loaded.animations[secondID]?.source.data == secondBytes)
        #expect(reopened.gifTimelineFrames.map(\.index) == [0, 1])
        #expect(abs(reopened.gifTimelineFrames[0].duration - 0.04) < 0.005)
        #expect(abs(reopened.gifTimelineFrames[1].duration - 0.16) < 0.005)
        var image = try #require(reopened.activeLayer.flatMap { reopened.displayedAsset(for: $0)?.image })
        #expect(try ImageImportTests().rgba(image, x: 16, y: 12)[2] > 240)

        // Saving to the same package must not invalidate the decoded source retained for later frame switches.
        try await ProjectStore.shared.save(try #require(reopened.projectSnapshot()), to: moved)
        await reopened.selectGIFTimelineFrame(0)
        image = try #require(reopened.activeLayer.flatMap { reopened.displayedAsset(for: $0)?.image })
        #expect(try ImageImportTests().rgba(image, x: 16, y: 12)[0] > 240)
        reopened.selectLayer(secondID)
        #expect(reopened.gifTimelineSelectedFrameIndex == 0)
        #expect(abs(reopened.gifTimelineFrames[0].duration - 0.08) < 0.005)
        #expect(abs(reopened.gifTimelineFrames[1].duration - 0.24) < 0.005)
        await reopened.selectGIFTimelineFrame(1)
        image = try #require(reopened.activeLayer.flatMap { reopened.displayedAsset(for: $0)?.image })
        #expect(try ImageImportTests().rgba(image, x: 16, y: 12)[2] > 240)
        reopened.selectLayer(stillID)
        #expect(reopened.gifTimelineFrames.isEmpty)
        #expect(reopened.activeLayer?.gifAnimation == nil)
    }

    @Test func sharedAndFrameMasksRemainSeparateAndStillExportUsesBoth() async throws {
        let root = try temporaryFolder()
        let source = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let id = try #require(session.activeLayerID)
        let placement = LayerTransform(origin: CGPoint(x: 3, y: -2), size: CGSize(width: 32, height: 24))
        var disabled = try coverage(left: 0, right: 255)
        disabled.isEnabled = false
        disabled.isLinked = false
        disabled.placement = placement
        session.document?.layers[0].mask = try coverage(left: 128, right: 128)
        session.document?.layers[0].gifFrameMasks = [0: disabled, 1: try coverage(left: 255, right: 0)]
        await session.selectGIFTimelineFrame(1)
        let snapshot = try #require(session.projectSnapshot())
        #expect(try ImageImportTests().gray(try #require(snapshot.masks[id]?.image), x: 24, y: 12) == 128)
        let url = root.appendingPathComponent("Masks.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        let layer = try #require(reopened.activeLayer)
        #expect(Set(layer.gifFrameMasks.keys) == [0, 1])
        #expect(layer.gifFrameMasks[0]?.isEnabled == false)
        #expect(layer.gifFrameMasks[0]?.isLinked == false)
        #expect(layer.gifFrameMasks[0]?.placement == placement)
        #expect(try ImageImportTests().gray(try #require(layer.mask?.asset.image), x: 24, y: 12) == 128)
        #expect(try ImageImportTests().gray(try #require(layer.gifFrameMasks[0]?.asset.image), x: 8, y: 12) == 0)
        #expect(try ImageImportTests().gray(try #require(layer.gifFrameMasks[1]?.asset.image), x: 8, y: 12) == 255)
        var exported = try await ImageExporter.shared.render(try #require(reopened.projectSnapshot()))
        #expect(abs(Int(try ImageImportTests().rgba(exported.image, x: 8, y: 12)[3]) - 128) <= 1)
        #expect(try ImageImportTests().rgba(exported.image, x: 24, y: 12)[3] == 0)
        await reopened.selectGIFTimelineFrame(0)
        exported = try await ImageExporter.shared.render(try #require(reopened.projectSnapshot()))
        #expect(abs(Int(try ImageImportTests().rgba(exported.image, x: 8, y: 12)[3]) - 128) <= 1)
        #expect(abs(Int(try ImageImportTests().rgba(exported.image, x: 24, y: 12)[3]) - 128) <= 1)
    }

    @Test func capturedFrameMasksStayImmutableWhileLaterEditsCanUndo() async throws {
        let root = try temporaryFolder()
        let source = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        session.toggleGIFFrameMaskTarget()
        let id = try #require(session.activeLayerID)
        let captured = try #require(session.projectSnapshot())
        session.tool = .brush
        session.brushSettings.diameter = 4
        session.maskPaintWhite = false
        session.beginBrush(at: CGPoint(x: 8, y: 12))
        #expect(session.finishBrushImmediately())
        let edited = try #require(session.activeLayer?.gifFrameMasks[0]?.asset.image)
        #expect(try ImageImportTests().gray(edited, x: 8, y: 12) < 15)
        #expect(try ImageImportTests().gray(try #require(captured.frameMasks[id]?[0]?.asset.image), x: 8, y: 12) > 240)
        await session.selectGIFTimelineFrame(1)
        let url = root.appendingPathComponent("Captured.comp")
        try await ProjectStore.shared.save(captured, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.animations[id]?.selectedFrameIndex == 0)
        #expect(session.gifTimelineSelectedFrameIndex == 1)
        #expect(try ImageImportTests().gray(try #require(loaded.frameMasks[id]?[0]?.asset.image), x: 8, y: 12) > 240)
        session.undo()
        #expect(try ImageImportTests().gray(try #require(session.activeLayer?.gifFrameMasks[0]?.asset.image), x: 8, y: 12) > 240)
        session.redo()
        #expect(session.activeLayer?.gifFrameMasks[0]?.asset.image === edited)
    }

    @Test func invalidGIFMetadataCannotReplaceAnExistingProject() async throws {
        let root = try temporaryFolder()
        let source = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        session.toggleGIFFrameMaskTarget()
        let snapshot = try #require(session.projectSnapshot())
        let id = try #require(session.activeLayerID)
        let url = root.appendingPathComponent("Safe.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let metadata = url.appendingPathComponent("manifest.json")
        let originalMetadata = try Data(contentsOf: metadata)
        let gifFile = url.appendingPathComponent("images").appendingPathComponent("\(id.uuidString).gif")
        let originalSource = try Data(contentsOf: gifFile)
        let validMask: [String: Any] = ["index": 0, "maskFile": "\(id.uuidString).frame-0.mask.png"]
        let changes: [[String: Any]] = [
            ["sourceFile": "../outside.gif"],
            ["selectedFrameIndex": -1],
            ["selectedFrameIndex": 2],
            ["frameMasks": [["index": 2, "maskFile": "\(id.uuidString).frame-2.mask.png"]]],
            ["frameMasks": [["index": 0, "maskFile": "../outside.mask.png"]]],
            ["frameMasks": [validMask, validMask]],
            ["geometry": ["width": 32, "height": 24, "a": 0, "b": 0, "c": 0, "d": 0, "tx": 0, "ty": 0]]
        ]
        for change in changes {
            let invalid = try manifest(snapshot.manifest, gifChanges: change)
            await #expect(throws: ProjectError.self) {
                try await ProjectStore.shared.save(ProjectSnapshot(manifest: invalid, images: snapshot.images,
                    masks: snapshot.masks, animations: snapshot.animations, frameMasks: snapshot.frameMasks), to: url)
            }
            #expect(try Data(contentsOf: metadata) == originalMetadata)
            #expect(try Data(contentsOf: gifFile) == originalSource)
        }
        let old = try manifest(snapshot.manifest, gifChanges: [:], version: 11)
        await #expect(throws: ProjectError.self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: old, images: snapshot.images,
                masks: snapshot.masks, animations: snapshot.animations, frameMasks: snapshot.frameMasks), to: url)
        }
        #expect(try Data(contentsOf: metadata) == originalMetadata)
        #expect(try await ProjectStore.shared.load(from: url).animations.count == 1)
    }

    @Test func damagedOrMissingEmbeddedGIFAndFrameMaskAreRejected() async throws {
        let root = try temporaryFolder()
        let source = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        session.toggleGIFFrameMaskTarget()
        let snapshot = try #require(session.projectSnapshot())
        let id = try #require(session.activeLayerID)
        let url = root.appendingPathComponent("Damaged.comp")
        let file = url.appendingPathComponent("images").appendingPathComponent("\(id.uuidString).gif")
        try await ProjectStore.shared.save(snapshot, to: url)
        try Data("not a GIF".utf8).write(to: file)
        await #expect(throws: Error.self) { try await ProjectStore.shared.load(from: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        try FileManager.default.removeItem(at: file)
        await #expect(throws: Error.self) { try await ProjectStore.shared.load(from: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        try FileManager.default.removeItem(at: url.appendingPathComponent("images")
            .appendingPathComponent("\(id.uuidString).frame-0.mask.png"))
        await #expect(throws: Error.self) { try await ProjectStore.shared.load(from: url) }
    }

    @Test func singleFrameGIFAndOmittedMaskDefaultsReopen() async throws {
        let root = try temporaryFolder()
        let source = try ImageImportTests().fixture(.gif)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        session.toggleGIFFrameMaskTarget()
        let snapshot = try #require(session.projectSnapshot())
        let id = try #require(session.activeLayerID)
        let url = root.appendingPathComponent("Single.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let defaults = try metadata(snapshot.manifest, gifChanges: ["frameMasks": [
            ["index": 0, "maskFile": "\(id.uuidString).frame-0.mask.png"]
        ]])
        try defaults.write(to: url.appendingPathComponent("manifest.json"))
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.gifTimelineFrames.count == 1)
        #expect(reopened.gifTimelineSelectedFrameIndex == 0)
        #expect(reopened.activeLayer?.gifFrameMasks[0]?.isEnabled == true)
        #expect(reopened.activeLayer?.gifFrameMasks[0]?.isLinked == true)
        #expect(reopened.activeLayer?.gifFrameMasks[0]?.placement == nil)
        let image = try #require(reopened.activeLayer.flatMap { reopened.displayedAsset(for: $0)?.image })
        #expect(image.width == 64 && image.height == 32)
        #expect(try ImageImportTests().rgba(image, x: 0, y: 0)[0] > 240)
        #expect(try ImageImportTests().rgba(image, x: 63, y: 0)[3] == 0)
        reopened.toggleGIFPlayback(for: id)
        #expect(!reopened.gifTimelineIsPlaying)
        let noMasks = try metadata(snapshot.manifest, gifChanges: ["frameMasks": NSNull()])
        try noMasks.write(to: url.appendingPathComponent("manifest.json"))
        let unmasked = try await ProjectStore.shared.load(from: url)
        #expect(unmasked.frameMasks[id]?.isEmpty != false)
    }

    @Test func duplicatedGIFSurvivesCropUndoAndSaveWithItsFrameMasks() async throws {
        let root = try temporaryFolder()
        let source = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let originalID = try #require(session.activeLayerID)
        session.document?.layers[0].gifFrameMasks[1] = try coverage(left: 255, right: 0)
        await session.selectGIFTimelineFrame(1)
        session.duplicateActiveLayer()
        let copyID = try #require(session.activeLayerID)
        #expect(copyID != originalID)
        #expect(session.gifTimelineSelectedFrameIndex == 1)
        #expect(session.activeLayer?.gifAnimation?.source === session.document?.layers[0].gifAnimation?.source)
        #expect(session.activeLayer?.gifFrameMasks[1]?.asset.image === session.document?.layers[0].gifFrameMasks[1]?.asset.image)
        let beforeCrop = try #require(session.document)
        session.selectTool(.crop)
        session.cropRect = CGRect(x: 4, y: 2, width: 24, height: 20)
        await session.commitCrop()
        #expect(session.document?.size == CGSize(width: 24, height: 20))
        #expect(session.document?.layers.allSatisfy { $0.origin == CGPoint(x: -4, y: -2) } == true)
        #expect(session.gifTimelineSelectedFrameIndex == 1)
        session.undo()
        #expect(session.document == beforeCrop)
        session.redo()
        let url = root.appendingPathComponent("Copies.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        #expect(Set(loaded.animations.keys) == [originalID, copyID])
        #expect(reopened.gifTimelineSelectedFrameIndex == 1)
        #expect(reopened.activeLayer?.gifFrameMasks[1] != nil)
        await reopened.selectGIFTimelineFrame(0)
        #expect(reopened.activeLayer?.gifFrameMasks[0] == nil)
        reopened.selectLayer(originalID)
        #expect(reopened.gifTimelineSelectedFrameIndex == 1)
        #expect(reopened.activeLayer?.gifFrameMasks[1] != nil)
    }

    @Test func rotatedNonuniformImageResizeKeepsEveryFrameAfterReopenAndRepeatedResize() async throws {
        let root = try temporaryFolder()
        let source = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let id = try #require(session.activeLayerID)
        session.document?.layers[0].transform.rotation = 90
        session.document?.layers[0].gifFrameMasks[0] = try coverage(left: 255, right: 0)
        await session.selectGIFTimelineFrame(1)
        let before = try #require(session.projectSnapshot())
        let resized = try await ImageResizer.shared.resize(before,
            to: ImageSizeOptions(width: 64, height: 72, resolution: 72, sampling: .nearest))
        session.applyImageSize(resized)
        #expect(session.activeLayer?.gifAnimation?.source === before.animations[id]?.source)
        #expect(session.activeLayer?.gifAnimation?.geometry != nil)
        #expect(session.gifTimelineSelectedFrameIndex == 1)
        #expect(session.activeLayer?.transform.rotation == 0)
        let resizedImage = try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        // The existing rasterizer rounds transformed bounds outward; floating-point corners can add one edge pixel.
        #expect(abs(resizedImage.width - 48) <= 1 && abs(resizedImage.height - 96) <= 1)
        let url = root.appendingPathComponent("Resized.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.activeLayer?.gifAnimation?.geometry == session.activeLayer?.gifAnimation?.geometry)
        #expect(reopened.gifTimelineSelectedFrameIndex == 1)
        await reopened.selectGIFTimelineFrame(0)
        let first = try #require(reopened.activeLayer.flatMap { reopened.displayedAsset(for: $0)?.image })
        #expect(first.width == resizedImage.width && first.height == resizedImage.height)
        #expect(try ImageImportTests().rgba(first, x: first.width / 2, y: first.height / 2)[0] > 240)
        let frameMask = try #require(reopened.activeLayer?.gifFrameMasks[0]?.asset.image)
        #expect(frameMask.width == resizedImage.width && frameMask.height == resizedImage.height)
        // A clockwise quarter-turn carries the original white left half to the top half.
        #expect(try ImageImportTests().gray(frameMask, x: frameMask.width / 2, y: frameMask.height / 4) > 240)
        #expect(try ImageImportTests().gray(frameMask, x: frameMask.width / 2, y: frameMask.height * 3 / 4) < 15)
        let repeated = try await ImageResizer.shared.resize(try #require(reopened.projectSnapshot()),
            to: ImageSizeOptions(width: 32, height: 36, resolution: 72, sampling: .nearest))
        let repeatedImage = try #require(repeated.images[id]?.image)
        reopened.applyImageSize(repeated)
        await reopened.selectGIFTimelineFrame(1)
        let second = try #require(reopened.activeLayer.flatMap { reopened.displayedAsset(for: $0)?.image })
        #expect(second.width == repeatedImage.width && second.height == repeatedImage.height)
        #expect(try ImageImportTests().rgba(second, x: second.width / 2, y: second.height / 2)[2] > 240)
        #expect(reopened.activeLayer?.gifAnimation?.source.data == before.animations[id]?.source.data)
    }

    @Test func deletingGIFRetainsSourceForUndoThenReleasesItWithHistory() async throws {
        let sourceURL = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let session = EditorSession()
        await session.importImages([sourceURL])
        let id = try #require(session.activeLayerID)
        weak var source = session.activeLayer?.gifAnimation?.source
        await session.selectGIFTimelineFrame(1)
        session.deleteActiveLayer()
        #expect(source != nil)
        #expect(session.gifTimelineFrames.isEmpty)
        session.undo()
        #expect(session.activeLayerID == id)
        #expect(session.gifTimelineSelectedFrameIndex == 1)
        let image = try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        #expect(try ImageImportTests().rgba(image, x: 16, y: 12)[2] > 240)
        session.redo()
        #expect(source != nil)
        session.history.reset()
        #expect(source == nil)
        session.addBlankLayer()
        #expect(session.gifTimelineFrames.isEmpty)
        #expect(source == nil)
    }

    @Test func reopeningAndResizingGIFKeepStillImageOrientation() async throws {
        let root = try temporaryFolder()
        let files = try ImageImportTests().asymmetricGIFFixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            for file in [files.gif] + files.pngs { try? FileManager.default.removeItem(at: file) }
        }
        var stills: [ImportedImage] = []
        for file in files.pngs { stills.append(try await ImageImporter.shared.decode(file)) }
        let session = EditorSession()
        await session.importImages([files.gif])
        let id = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(1)
        let url = root.appendingPathComponent("Orientation.comp")
        try await ProjectStore.shared.save(#require(session.projectSnapshot()), to: url)
        try FileManager.default.removeItem(at: files.gif)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let imported = ImageImportTests()
        for index in stills.indices.reversed() {
            await reopened.selectGIFTimelineFrame(index)
            let image = try #require(reopened.activeLayer.flatMap { reopened.displayedAsset(for: $0)?.image })
            for (x, y) in [(4, 3), (24, 3), (4, 18), (24, 18), (30, 22)] {
                #expect(try imported.rgba(image, x: x, y: y) == imported.rgba(stills[index].image, x: x, y: y))
            }
        }
        reopened.document?.layers[0].transform.rotation = 90
        let original = try #require(reopened.projectSnapshot())
        let options = ImageSizeOptions(width: 64, height: 72, resolution: 72, sampling: .nearest)
        reopened.applyImageSize(try await ImageResizer.shared.resize(original, to: options))
        await reopened.selectGIFTimelineFrame(1)
        let actual = try #require(reopened.activeLayer.flatMap { reopened.displayedAsset(for: $0)?.image })
        var stillManifest = original.manifest
        stillManifest.layers[0].gif = nil
        let stillSnapshot = ProjectSnapshot(manifest: stillManifest, images: [id: stills[1]])
        let resizedStill = try await ImageResizer.shared.resize(stillSnapshot, to: options)
        let expected = try #require(resizedStill.images[id]?.image)
        #expect(actual.width == expected.width && actual.height == expected.height)
        for x in [expected.width / 4, expected.width * 3 / 4] {
            for y in [expected.height / 4, expected.height * 3 / 4] {
                #expect(try imported.rgba(actual, x: x, y: y) == imported.rgba(expected, x: x, y: y))
            }
        }
    }

    @Test func sharedMaskCreationCountsExistingGIFFrameMasksAgainstTheBudget() async throws {
        let sourceURL = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let session = EditorSession()
        await session.importImages([sourceURL])
        let originalSource = try #require(session.activeLayer?.gifAnimation?.source)
        func solidMask(width: Int, height: Int) throws -> LayerMask {
            let context = try BrushRaster.context(width: width, height: height, mask: true)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(context.makeImage())
            return LayerMask(asset: try LayerMask.asset(from: image))
        }
        // Reuse immutable grids to simulate a near-budget animation without allocating hundreds of megabytes.
        let side = 512
        let mask = try solidMask(width: side, height: side)
        let count = DocumentLimits.documentPixelBudget / (side * side)
        var masks = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, mask) })
        let remainderRows = DocumentLimits.documentPixelBudget % (side * side) / side
        if remainderRows > 0 { masks[count] = try solidMask(width: side, height: remainderRows) }
        #expect(masks.count <= GIFTimelineLimits.maxFrames)
        let frames = (0..<masks.count).map {
            GIFTimelineFrame(index: $0, thumbnail: originalSource.frames[0].thumbnail, duration: 0.1)
        }
        let source = GIFSource(data: originalSource.data, frames: frames, width: originalSource.width, height: originalSource.height)
        session.document?.layers[0].gifAnimation = GIFAnimation(source: source)
        session.document?.layers[0].gifFrameMasks = masks
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 16, height: 24), transform: nil),
                                               antialiased: false), name: "Select Left Side")
        session.history.reset()
        let before = try #require(session.document)
        session.addMask()
        #expect(session.document == before)
        #expect(session.activeLayer?.mask == nil)
        #expect(!session.isModified && !session.canUndo)
        #expect(session.brushError == ProjectError.tooLarge.localizedDescription)
    }
}
