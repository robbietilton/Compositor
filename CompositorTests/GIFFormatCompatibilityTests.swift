import AppKit
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct GIFFormatCompatibilityTests {
    private func package() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GIFFoundation-\(UUID()).comp")
    }

    private func asset(hdr: Bool) throws -> ImportedImage {
        let context = try DeepLayer.context(width: 32, height: 24, hdr: hdr)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        for y in 0..<24 {
            for x in 0..<32 {
                let offset = y * context.bytesPerRow / 2 + x * 4
                pixels[offset] = hdr ? Float16(2).bitPattern : UInt16(32768 + x)
                pixels[offset + 1] = 0; pixels[offset + 2] = 0
                pixels[offset + 3] = hdr ? Float16(1).bitPattern : 65535
            }
        }
        return try DeepLayer.asset(#require(context.makeImage()), name: hdr ? "HDR" : "16-Bit")
    }

    @Test(arguments: [1, 11, 12, 13, 14])
    func upstreamStillProjectsRemainReadable(version: Int) async throws {
        let file = try ImageImportTests().fixture(.png), url = package()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([file])
        let snapshot = try #require(session.projectSnapshot())
        var manifest = snapshot.manifest
        manifest.version = version
        try await ProjectStore.shared.save(ProjectSnapshot(manifest: manifest, images: snapshot.images), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == version && loaded.animations.isEmpty)
        let id = try #require(session.activeLayerID)
        #expect(loaded.images[id]?.image.width == snapshot.images[id]?.image.width)
        #expect(loaded.images[id]?.image.height == snapshot.images[id]?.image.height)
    }

    @Test func unsupportedForkVersionsCannotLoadOrReplaceAnExistingPackage() async throws {
        let file = try ImageImportTests().animatedGIFFixture(), url = package()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([file])
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        let path = url.appendingPathComponent("manifest.json"), original = try Data(contentsOf: path)
        for version in Array(15...26) + [0, ProjectManifest.current + 1] {
            var manifest = snapshot.manifest
            manifest.version = version
            await #expect(throws: ProjectError.self) {
                try await ProjectStore.shared.save(ProjectSnapshot(manifest: manifest, images: snapshot.images,
                    animations: snapshot.animations, frameMasks: snapshot.frameMasks), to: url)
            }
            #expect(try Data(contentsOf: path) == original)
            try JSONEncoder().encode(manifest).write(to: path)
            await #expect(throws: ProjectError.self) { try await ProjectStore.shared.load(from: url) }
            try original.write(to: path)
        }
        #expect(session.activeLayer?.gifAnimation != nil && session.gifTimelineSelectedFrameIndex == 0)
    }

    @Test(arguments: [12, 13, 14])
    func overlappingLegacyVersionsCannotSilentlyLoadGIFFields(version: Int) async throws {
        let file = try ImageImportTests().animatedGIFFixture(), url = package()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([file])
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        var manifest = snapshot.manifest
        manifest.version = version
        try JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("manifest.json"))
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.load(from: url) }
    }

    @Test func mixedGIFDeepHDRAndSmoothedShapeLayersSurviveResizeAndReopen() async throws {
        let file = try ImageImportTests().animatedGIFFixture(), url = package()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.createDocument(width: 32, height: 24)
        session.insert(try asset(hdr: false))
        let deepID = try #require(session.activeLayerID)
        session.insert(try asset(hdr: true))
        let hdrID = try #require(session.activeLayerID)
        await session.importImages([file])
        let gifID = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(1)
        await session.invertPixels()
        session.toggleGIFFrameMaskTarget()
        let captured = try #require(session.projectSnapshot())
        var manifest = captured.manifest
        let smoothing = LayerShapeStyle(kind: .rectangle, red: 1, green: 0, blue: 0,
                                        cornerRadius: 4, smoothing: true)
        manifest.layers[0].shape = smoothing
        let mixed = ProjectSnapshot(manifest: manifest, images: captured.images, masks: captured.masks,
            animations: captured.animations, frameMasks: captured.frameMasks)
        try await ProjectStore.shared.save(mixed, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == ProjectManifest.current)
        #expect(loaded.manifest.layers[0].shape?.smoothing == true)
        let resized = try await ImageResizer.shared.resize(loaded,
            to: ImageSizeOptions(width: 64, height: 48, resolution: 72))
        try await ProjectStore.shared.save(resized, to: url)
        let reopened = try await ProjectStore.shared.load(from: url)
        #expect(reopened.images[deepID]?.deep?.bitsPerComponent == 16)
        #expect(reopened.images[hdrID]?.isHDR == true)
        #expect(reopened.animations[gifID]?.selectedFrameIndex == 1)
        #expect(reopened.animations[gifID]?.framePixels[1]?.image.width == 64)
        #expect(reopened.frameMasks[gifID]?[1]?.isEnabled == true)
        #expect(reopened.frameMasks[gifID]?[1]?.asset.image.width == 64)
        let image = try await ImageExporter.shared.render(reopened)
        #expect(image.image.width == 64 && image.image.height == 48)
    }
}
