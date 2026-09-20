import AppKit
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct PSDTests {
    @Test func grayscaleCompositeBecomesRGBLayer() throws {
        var file = PSDBuffer()
        file.fourCC(PSDFourCC.file)
        file.u16(1)
        file.append([UInt8](repeating: 0, count: 6))
        file.u16(1)
        file.u32(1)
        file.u32(1)
        file.u16(8)
        file.u16(1)
        file.u32(0)
        file.u32(0)
        file.u32(0)
        file.u16(0)
        file.u8(160)
        let snapshot = try PSDReader.parse(file.data)
        #expect(snapshot.manifest.width == 1 && snapshot.manifest.height == 1)
        #expect(snapshot.manifest.layers.count == 1)
    }

    @Test func rleCompositeWithoutLayers() throws {
        var file = PSDBuffer()
        file.fourCC(PSDFourCC.file)
        file.u16(1)
        file.append([UInt8](repeating: 0, count: 6))
        file.u16(3)
        file.u32(1)
        file.u32(1)
        file.u16(8)
        file.u16(3)
        file.u32(0)
        file.u32(0)
        file.u32(0)
        file.u16(1)
        file.u16(2)
        file.u16(2)
        file.u16(2)
        file.u8(0); file.u8(200)
        file.u8(0); file.u8(0)
        file.u8(0); file.u8(0)
        let snapshot = try PSDReader.parse(file.data)
        #expect(snapshot.manifest.layers.count == 1)
        #expect(snapshot.images[snapshot.manifest.layers[0].id] != nil)
    }

    @Test func rejectsUnsupportedPhotoshopFiles() throws {
        var psb = PSDBuffer()
        psb.fourCC(PSDFourCC.file)
        psb.u16(2)
        psb.append([UInt8](repeating: 0, count: 6))
        psb.u16(4)
        psb.u32(1)
        psb.u32(1)
        psb.u16(8)
        psb.u16(3)
        do {
            _ = try PSDReader.parse(psb.data)
            Issue.record("PSB should be rejected")
        } catch PSDError.unsupportedVersion {}

        var cmyk = PSDBuffer()
        cmyk.fourCC(PSDFourCC.file)
        cmyk.u16(1)
        cmyk.append([UInt8](repeating: 0, count: 6))
        cmyk.u16(4)
        cmyk.u32(1)
        cmyk.u32(1)
        cmyk.u16(8)
        cmyk.u16(4)
        do {
            _ = try PSDReader.parse(cmyk.data)
            Issue.record("CMYK should be rejected")
        } catch PSDError.unsupportedColorMode {}

        var deep = PSDBuffer()
        deep.fourCC(PSDFourCC.file)
        deep.u16(1)
        deep.append([UInt8](repeating: 0, count: 6))
        deep.u16(4)
        deep.u32(1)
        deep.u32(1)
        deep.u16(16)
        deep.u16(3)
        do {
            _ = try PSDReader.parse(deep.data)
            Issue.record("16-bit should be rejected")
        } catch PSDError.unsupportedDepth {}
    }

    @Test func photoshopTypeRecognizesPSDExtension() {
        #expect(UTType.photoshopDocument.preferredFilenameExtension?.lowercased() == "psd")
        #expect(UTType.projectDocumentTypes.contains(where: { type in
            type.preferredFilenameExtension?.lowercased() == "psd" || type.tags[.filenameExtension]?.contains("psd") == true
        }))
        #expect(UTType.projectOpenTypes.contains(where: { $0.conforms(to: .image) }))
    }

    @Test func saveAndOpenRoundTrip() async throws {
        let session = EditorSession()
        session.createDocument(width: 2, height: 2)
        let bytes: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255]
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        session.document?.layers[0].opacity = 0.5
        session.document?.layers[0].blendMode = .multiply
        let snapshot = try #require(session.projectSnapshot())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PSD-\(UUID().uuidString).psd")
        defer { try? FileManager.default.removeItem(at: url) }
        try await PSDCodec.shared.save(snapshot, to: url)
        let loaded = try await PSDCodec.shared.load(from: url)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.document?.layers.count == 1)
        #expect(abs((reopened.document?.layers[0].opacity ?? 0) - 0.5) < 0.01)
        #expect(reopened.document?.layers[0].blendMode == .multiply)
        #expect(reopened.document?.layers[0].name == "Red")
        #expect(reopened.projectURL?.pathExtension.lowercased() == "psd")
        #expect(url.isProjectDocument)
    }

    @Test func layerOriginsRoundTripWithoutSwappingAxes() async throws {
        let session = EditorSession()
        session.createDocument(width: 50, height: 80)
        let bytes: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255]
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Offset"))
        session.document?.layers[0].transform.origin = CGPoint(x: 10, y: 40)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PSD-origin-\(UUID().uuidString).psd")
        defer { try? FileManager.default.removeItem(at: url) }
        try await PSDCodec.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await PSDCodec.shared.load(from: url), from: url)
        let origin = try #require(reopened.document?.layers.first?.transform.origin)
        #expect(origin.x == 10)
        #expect(origin.y == 40)

        session.document?.layers[0].transform.size = CGSize(width: 4, height: 2)
        session.document?.layers[0].transform.origin = CGPoint(x: 6, y: 24)
        let scaled = FileManager.default.temporaryDirectory.appendingPathComponent("PSD-scaled-\(UUID().uuidString).psd")
        defer { try? FileManager.default.removeItem(at: scaled) }
        try await PSDCodec.shared.save(try #require(session.projectSnapshot()), to: scaled)
        let baked = EditorSession()
        baked.installProject(try await PSDCodec.shared.load(from: scaled), from: scaled)
        let bakedOrigin = try #require(baked.document?.layers.first?.transform.origin)
        #expect(bakedOrigin.x == 6)
        #expect(bakedOrigin.y == 24)
    }

    @Test func masksGroupsClippingAndVisibilityRoundTrip() async throws {
        let session = EditorSession()
        session.createDocument(width: 2, height: 2)
        let redBytes: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255]
        let redImage = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(redBytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let blueBytes: [UInt8] = [0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255]
        let blueImage = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(blueBytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        session.insert(ImportedImage(image: redImage, thumbnail: redImage, name: "Red"))
        session.insert(ImportedImage(image: blueImage, thumbnail: blueImage, name: "Blue"))
        let redID = session.document?.layers.first(where: { $0.name == "Red" })?.id
        let blueID = session.document?.layers.first(where: { $0.name == "Blue" })?.id
        #expect(redID != nil && blueID != nil)
        if let redID, let index = session.document?.layers.firstIndex(where: { $0.id == redID }) {
            session.document?.layers[index].mask = LayerMask.solid(revealing: true)
        }
        if let blueID, let index = session.document?.layers.firstIndex(where: { $0.id == blueID }) {
            session.document?.layers[index].isVisible = false
        }
        if let redID, let blueID {
            #expect(session.linkMask(source: redID, target: blueID))
            session.selectLayers([redID, blueID], primary: blueID)
        }
        session.groupSelectedLayers()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PSD-structure-\(UUID().uuidString).psd")
        defer { try? FileManager.default.removeItem(at: url) }
        try await PSDCodec.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await PSDCodec.shared.load(from: url), from: url)
        let layers = reopened.document?.layers ?? []
        let groupID = layers.first(where: { $0.isGroup })?.id
        let loadedRed = layers.first(where: { $0.name == "Red" })
        let loadedBlue = layers.first(where: { $0.name == "Blue" })
        #expect(groupID != nil)
        #expect(loadedRed?.parentID == groupID)
        #expect(loadedBlue?.parentID == groupID)
        #expect(loadedRed?.mask != nil)
        #expect(loadedBlue?.maskSourceID == loadedRed?.id)
        #expect(loadedBlue?.isVisible == false)
        #expect(loadedRed?.isVisible == true)
    }

    @Test func uuidNamedPhotoshopURLIsAProjectDocument() {
        let url = URL(fileURLWithPath: "/tmp/06-6F1868A5-56F5-4004-B44B-065B823DD58.psd")
        #expect(url.projectExtension == "psd")
        #expect(url.hasPhotoshopFilename)
        #expect(url.isPhotoshopDocument)
        #expect(url.isProjectDocument)
        let upper = URL(fileURLWithPath: "/tmp/06-1F0A606C-CB51-4CCA-A0A4-97CA092B04EA.PSD")
        #expect(upper.hasPhotoshopFilename)
        #expect(upper.isPhotoshopDocument)
    }

    @Test func saveAsFilenameFollowsFormat() {
        #expect(SaveFormatPicker.filename("Untitled.comp", format: .photoshop) == "Untitled.psd")
        #expect(SaveFormatPicker.filename("Flyer", format: .compositor) == "Flyer.comp")
        #expect(SaveFormatPicker.filename("Untitled.PSD", format: .compositor) == "Untitled.comp")
    }

    @Test func uppercasePsdExtensionOpensAsProject() async throws {
        let url = try await writeSamplePSD()
        let upper = url.deletingLastPathComponent()
            .appendingPathComponent("06-1F0A606C-CB51-4CCA-A0A4-97CA092B04EA.PSD")
        try FileManager.default.copyItem(at: url, to: upper)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: upper)
        }
        let session = EditorSession()
        await session.importImages([upper])
        #expect(session.importError == nil)
        #expect(session.document?.layers.isEmpty == false)
        let controller = ProjectController(session: EditorSession())
        #expect(await controller.open(upper))
        #expect(controller.session.document?.layers.isEmpty == false)
    }

    @Test func importImagesOpensPhotoshopOnEmptyCanvas() async throws {
        let url = try await writeSamplePSD()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        #expect(session.importError == nil)
        #expect(session.document?.layers.isEmpty == false)
        #expect(session.projectURL?.pathExtension.lowercased() == "psd")
    }

    @Test func photoshopSignatureOpensWithoutPsdExtension() async throws {
        let url = try await writeSamplePSD()
        let renamed = url.deletingPathExtension().appendingPathExtension("dat")
        try FileManager.default.copyItem(at: url, to: renamed)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: renamed)
        }
        #expect(renamed.hasPhotoshopSignature)
        #expect(renamed.isPhotoshopDocument)
        let session = EditorSession()
        await session.importImages([renamed])
        #expect(session.importError == nil)
        #expect(session.document?.layers.isEmpty == false)
    }

    @Test func imageImporterRejectsPhotoshopAsRaster() async throws {
        let url = try await writeSamplePSD()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await ImageImporter.shared.decode(url)
            Issue.record("PSD should not import as a raster image")
        } catch ImageImportError.photoshopDocument {}
    }

    @Test func workspaceDropOpensPhotoshopAsProject() async throws {
        let url = try await writeSamplePSD()
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace()
        let provider = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        await ImageFileDrop.importProviders([provider], into: workspace.current.session, at: nil,
            workspace: workspace, destination: workspace.current.id)
        #expect(workspace.current.session.importError == nil)
        #expect(workspace.current.session.projectURL?.pathExtension.lowercased() == "psd")
        #expect(workspace.current.session.document?.layers.isEmpty == false)
    }

    private func writeSamplePSD() async throws -> URL {
        let session = EditorSession()
        session.createDocument(width: 2, height: 2)
        let bytes: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255]
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PSD-drop-\(UUID().uuidString).psd")
        try await PSDCodec.shared.save(try #require(session.projectSnapshot()), to: url)
        return url
    }
}
