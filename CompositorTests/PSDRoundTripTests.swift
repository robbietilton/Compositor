import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct PSDRoundTripTests {
    private func colorImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func grayImage(width: Int, height: Int, value: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func header(version: UInt16 = 1, width: UInt32 = 8, height: UInt32 = 8, depth: UInt16 = 8, mode: UInt16 = 3) -> Data {
        var data = Data("8BPS".utf8)
        func append(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        func append32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value >> 24))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        append(version)
        data.append(Data(count: 6))
        append(3)
        append32(height)
        append32(width)
        append(depth)
        append(mode)
        return data
    }

    @Test func roundTripLayersOrderVisibilityOpacityAndBlend() throws {
        let red = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        let blue = try colorImage(width: 2, height: 2, red: 0, green: 0, blue: 1)
        let composite = try colorImage(width: 4, height: 4, red: 0, green: 0, blue: 0, alpha: 0)
        var bottom = PSDRecord(id: UUID(), name: "Red")
        bottom.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        bottom.image = red
        bottom.opacity = 0.5
        bottom.blendKey = "mul "
        var top = PSDRecord(id: UUID(), name: "Blue")
        top.bounds = CGRect(x: 2, y: 0, width: 2, height: 2)
        top.image = blue
        top.isVisible = false
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 4, resolution: 144, layers: [bottom, top]), composite: composite)
        #expect(data.prefix(4) == Data("8BPS".utf8))
        let document = try PSDReader.read(data)
        #expect(document.width == 4 && document.height == 4)
        #expect(document.resolution == 144)
        #expect(document.layers.map(\.name) == ["Red", "Blue"])
        #expect(document.layers[0].isVisible)
        #expect(!document.layers[1].isVisible)
        #expect(abs(document.layers[0].opacity - 0.5) < 0.01)
        #expect(document.layers[0].blendKey == "mul ")
        #expect(document.layers[0].image?.width == 2)
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.conversions.isEmpty)
        #expect(imported.layers.map(\.name) == ["Red", "Blue"])
        #expect(imported.layers[0].blendMode == .multiply)
        #expect(imported.layers[1].isVisible == false)
    }

    @Test func roundTripGroupsMasksAndClipping() throws {
        let fill = try colorImage(width: 2, height: 2, red: 0, green: 1, blue: 0)
        let clipped = try colorImage(width: 2, height: 2, red: 1, green: 1, blue: 0)
        let mask = try grayImage(width: 2, height: 2, value: 1)
        let composite = try colorImage(width: 4, height: 4, red: 0, green: 0, blue: 0, alpha: 0)
        let groupID = UUID()
        var group = PSDRecord(id: groupID, name: "Stack")
        group.isGroup = true
        group.blendKey = "pass"
        var base = PSDRecord(id: UUID(), parentID: groupID, name: "Base")
        base.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        base.image = fill
        base.mask = mask
        var child = PSDRecord(id: UUID(), parentID: groupID, name: "Clipped")
        child.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        child.image = clipped
        child.clipping = true
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 4, resolution: 72, layers: [group, base, child]), composite: composite)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(imported.conversions.isEmpty)
        #expect(imported.layers.contains { $0.isGroup && $0.name == "Stack" })
        let folder = try #require(imported.layers.first { $0.isGroup })
        let importedBase = try #require(imported.layers.first { $0.name == "Base" })
        let importedChild = try #require(imported.layers.first { $0.name == "Clipped" })
        #expect(importedBase.parentID == folder.id)
        #expect(importedChild.parentID == folder.id)
        #expect(importedBase.mask != nil)
        #expect(importedChild.maskSourceID == importedBase.id)
    }

    @Test func importedGroupsFollowPhotoshopLsctOrder() throws {
        let fill = try colorImage(width: 2, height: 2, red: 0, green: 1, blue: 0)
        let composite = try colorImage(width: 4, height: 4, red: 0, green: 0, blue: 0, alpha: 0)
        let groupID = UUID()
        var group = PSDRecord(id: groupID, name: "Stack")
        group.isGroup = true
        var child = PSDRecord(id: UUID(), parentID: groupID, name: "Base")
        child.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        child.image = fill
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 4, resolution: 72, layers: [group, child]), composite: composite)
        #expect(lsctTypes(in: data) == [3, 1])
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let folder = try #require(imported.layers.first { $0.isGroup })
        #expect(folder.name == "Stack")
        #expect(imported.layers.first { $0.name == "Base" }?.parentID == folder.id)
    }

    @Test func oversizedLayerBoundsAreRejected() throws {
        #expect(throws: ImageImportError.tooLarge) {
            try PSDReader.read(oversizedLayerFile(width: 8, height: 8, layerWidth: 30_000, layerHeight: 30_000))
        }
        let fill = try colorImage(width: 20, height: 20, red: 1, green: 0, blue: 0)
        var layer = PSDRecord(id: UUID(), name: "Huge")
        layer.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        layer.image = fill
        let data = try PSDFixture.data(PSDDocument(width: 20, height: 20, resolution: 72, layers: [layer]), composite: fill)
        #expect(throws: ImageImportError.tooLarge) {
            try PSDReader.read(data, remainingPixels: 50)
        }
    }

    @Test func unusedSpotChannelsAreSkippedBeforeDecode() throws {
        let pixels = Data(repeating: 255, count: 4)
        var channels: [(id: Int16, payload: Data)] = []
        for id: Int16 in [-1, 0, 1, 2] {
            channels.append((id, rawChannel(pixels)))
        }
        // Compression 99 would throw if these planes were unpacked. 52 extras fill the 56-channel cap.
        let bogus = Data([0, 99, 0, 0])
        for id in Int16(3)...Int16(54) {
            channels.append((id, bogus))
        }
        let document = try PSDReader.read(layerFile(layerWidth: 2, layerHeight: 2, channels: channels))
        #expect(document.layers.count == 1)
        #expect(document.layers[0].image?.width == 2)
        #expect(document.layers[0].image?.height == 2)
    }

    @Test func unsupportedCompressionOnColorChannelsIsStillRejected() {
        let pixels = Data(repeating: 255, count: 4)
        let channels: [(id: Int16, payload: Data)] = [
            (-1, rawChannel(pixels)),
            (0, Data([0, 99, 0, 0])),
            (1, rawChannel(pixels)),
            (2, rawChannel(pixels)),
        ]
        #expect(throws: PSDError.unsupportedCompression) {
            try PSDReader.read(layerFile(layerWidth: 2, layerHeight: 2, channels: channels))
        }
    }

    @Test func matchesRequiresPhotoshopMagic() throws {
        let jpeg = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).psd")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: jpeg)
        defer { try? FileManager.default.removeItem(at: jpeg) }
        #expect(!PSDReader.matches(jpeg))
        let psd = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
        try Data("8BPS".utf8).write(to: psd)
        defer { try? FileManager.default.removeItem(at: psd) }
        #expect(PSDReader.matches(psd))
    }

    @Test func unknownBlendProducesConversionReport() throws {
        let fill = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var layer = PSDRecord(id: UUID(), name: "Vivid")
        layer.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        layer.image = fill
        layer.blendKey = "vLit"
        let data = try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [layer]), composite: fill)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(!imported.conversions.isEmpty)
        #expect(imported.conversions.contains { $0.layerName == "Vivid" && $0.message.contains("vLit") })
        #expect(imported.layers.first?.blendMode == .normal)
    }

    @Test func softLightImportsWithoutConversion() throws {
        let fill = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var layer = PSDRecord(id: UUID(), name: "Soft")
        layer.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        layer.image = fill
        layer.blendKey = "sLit"
        let data = try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [layer]), composite: fill)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(imported.conversions.isEmpty)
        #expect(imported.layers.first?.blendMode == .softLight)
    }

    /// Was folderOpacityIsReportedBecauseProjectsCannotStoreIt, which asserted the folder came in
    /// fully opaque with a conversion note. Folders took an opacity of their own in 1.1.6.
    @Test func folderOpacityImportsOntoTheFolder() throws {
        let fill = try colorImage(width: 2, height: 2, red: 0, green: 1, blue: 0)
        let groupID = UUID()
        var group = PSDRecord(id: groupID, name: "Stack")
        group.isGroup = true
        group.opacity = 0.5
        var child = PSDRecord(id: UUID(), parentID: groupID, name: "Base")
        child.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        child.image = fill
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 4, resolution: 72, layers: [group, child]), composite: fill)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let folder = try #require(imported.layers.first { $0.isGroup })
        // Photoshop stores opacity in one byte, so a half-opaque group comes back as 128/255.
        #expect(abs(folder.opacity - 0.5) < 0.01)
        #expect(!imported.conversions.contains { $0.layerName == "Stack" && $0.message.contains("opacity") })
    }

    @Test func unsupportedHeadersAreRejected() throws {
        #expect(throws: PSDError.unsupportedVersion) { try PSDReader.read(header(version: 2)) }
        #expect(throws: PSDError.unsupportedColorMode) { try PSDReader.read(header(mode: 4)) }
        #expect(throws: PSDError.unsupportedDepth) { try PSDReader.read(header(depth: 16)) }
        #expect(throws: ImageImportError.tooLarge) { try PSDReader.read(header(width: 30_001, height: 10)) }
    }

    @Test func importCreatesDocumentAndExistingCanvasGetsAGroup() async throws {
        let fill = try colorImage(width: 4, height: 2, red: 0, green: 0, blue: 1)
        var layer = PSDRecord(id: UUID(), name: "Sky")
        layer.bounds = CGRect(x: 0, y: 0, width: 4, height: 2)
        layer.image = fill
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 2, resolution: 72, layers: [layer]), composite: fill)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).psd")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.confirmConversions = { _ in true }
        await session.importImages([url])
        #expect(session.document?.size == CGSize(width: 4, height: 2))
        #expect(session.document?.layers.map(\.name) == ["Sky"])
        #expect(session.importError == nil)
        await session.importImages([url])
        #expect(session.document?.layers.contains { $0.isGroup && $0.name == url.deletingPathExtension().lastPathComponent } == true)
        #expect(session.document?.layers.filter { $0.name == "Sky" }.count == 2)
    }

    @Test func cancelledConversionLeavesTheDocumentUnchanged() async throws {
        let fill = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var layer = PSDRecord(id: UUID(), name: "Vivid")
        layer.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        layer.image = fill
        layer.blendKey = "vLit"
        let data = try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [layer]), composite: fill)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).psd")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.confirmConversions = { _ in false }
        await session.importImages([url])
        #expect(session.document == nil)
        #expect(!session.isImporting)
    }

    @Test func vectorMaskIsRasterizedWithFillAndStroke() throws {
        let canvas = CGSize(width: 200, height: 200)
        var extra: [String: Data] = [:]
        extra["vmsk"] = vectorMask(canvas: canvas, corners: [
            CGPoint(x: 120, y: 30), CGPoint(x: 120, y: 80), CGPoint(x: 20, y: 80), CGPoint(x: 20, y: 30)
        ])
        extra["SoCo"] = solidColor(red: 0, green: 110, blue: 255)
        extra["vstk"] = strokeStyle(fill: true, stroke: false, width: 1, red: 255, green: 255, blue: 0)
        let raster = try #require(try PSDVector.raster(extra: extra, canvas: canvas))
        #expect(raster.bounds.width >= 99 && raster.bounds.height >= 49)
        #expect(raster.image.width >= 99 && raster.image.height >= 49)
        extra["vstk"] = strokeStyle(fill: true, stroke: true, width: 10, red: 255, green: 255, blue: 0)
        extra["SoCo"] = solidColor(red: 0, green: 0, blue: 0)
        let stroked = try #require(try PSDVector.raster(extra: extra, canvas: canvas))
        #expect(stroked.bounds.width > raster.bounds.width)
        #expect(stroked.bounds.height > raster.bounds.height)
    }

    @Test func photoshopShapeExtrasRasterizeInPlace() throws {
        let circle = try #require(try PSDVector.raster(extra: PSDVectorFixtures.circle(), canvas: PSDVectorFixtures.canvas))
        #expect(abs(circle.bounds.midX - 618) < 8)
        #expect(abs(circle.bounds.midY - 677) < 8)
        #expect(abs(circle.bounds.width - 328) < 12)
        #expect(abs(circle.bounds.height - 328) < 12)
        let rectangle = try #require(try PSDVector.raster(extra: PSDVectorFixtures.rectangle(), canvas: PSDVectorFixtures.canvas))
        #expect(rectangle.bounds.width > 640)
        #expect(rectangle.bounds.height > 170)
        #expect(abs(rectangle.bounds.midX - 1268) < 20)
        #expect(abs(rectangle.bounds.midY - 244) < 20)
    }

    @Test func fillEllipseImportsAsALiveShape() throws {
        var extra = PSDVectorFixtures.circle()
        extra["vogk"] = originationData(type: 5, rect: CGRect(x: 454, y: 513, width: 328, height: 328))
        let live = try #require(try PSDVector.live(extra: extra, canvas: PSDVectorFixtures.canvas))
        #expect(live.style.kind == .ellipse)
        #expect(abs(live.style.green - 110 / 255) < 0.01)
        #expect(abs(live.style.blue - 1) < 0.01)
        #expect(live.notes.isEmpty)
        #expect(abs(live.bounds.minX - 454) < 1 && abs(live.bounds.width - 328) < 1)
        var record = PSDRecord(id: UUID(), name: "cercle-bleu")
        record.kind = .vector
        record.image = live.image
        record.bounds = live.bounds
        record.shape = live.style
        let imported = try PSDDocumentBuilder.makeImport(PSDDocument(width: 1920, height: 1080, resolution: 72, layers: [record]))
        #expect(imported.layers.first?.liveShape?.style.kind == .ellipse)
        #expect(imported.conversions.isEmpty)
        #expect(imported.layers.first?.liveShape?.image === imported.layers.first?.asset?.image)
    }

    @Test func strokedRectangleImportsAsALiveShapeAndReportsTheStroke() throws {
        var extra = PSDVectorFixtures.rectangle()
        extra["vogk"] = originationData(type: 2, rect: CGRect(x: 945, y: 153, width: 646, height: 182), radii: [0, 0, 0, 0])
        let live = try #require(try PSDVector.live(extra: extra, canvas: PSDVectorFixtures.canvas))
        #expect(live.style.kind == .rectangle)
        #expect(live.style.cornerRadius == 0)
        #expect(live.notes.contains { $0.contains("stroke") })
        var record = PSDRecord(id: UUID(), name: "rectangle-contour-jaune")
        record.kind = .vector
        record.image = live.image
        record.bounds = live.bounds
        record.shape = live.style
        record.shapeNotes = live.notes
        let imported = try PSDDocumentBuilder.makeImport(PSDDocument(width: 1920, height: 1080, resolution: 72, layers: [record]))
        #expect(imported.layers.first?.liveShape?.style.kind == .rectangle)
        #expect(imported.conversions.contains { $0.layerName == "rectangle-contour-jaune" && $0.message.contains("stroke") })
        #expect(!imported.conversions.contains { $0.message.contains("rasterized") })
    }

    @Test func fourSharpCornersInferARectangleWithoutOrigination() throws {
        var extra: [String: Data] = [:]
        extra["vmsk"] = vectorMask(canvas: CGSize(width: 200, height: 200), corners: [
            CGPoint(x: 120, y: 30), CGPoint(x: 120, y: 80), CGPoint(x: 20, y: 80), CGPoint(x: 20, y: 30)
        ])
        extra["SoCo"] = solidColor(red: 0, green: 110, blue: 255)
        extra["vstk"] = strokeStyle(fill: true, stroke: false, width: 1, red: 255, green: 255, blue: 0)
        let live = try #require(try PSDVector.live(extra: extra, canvas: CGSize(width: 200, height: 200)))
        #expect(live.style.kind == .rectangle)
        #expect(live.notes.isEmpty)
        #expect(live.bounds.width >= 99 && live.bounds.height >= 49)
    }

    @Test func hugeOriginationSizeIsRejectedWithoutTrapping() throws {
        var extra: [String: Data] = [:]
        extra["vogk"] = originationData(type: 5, rect: CGRect(x: 0, y: 0, width: 1e20, height: 1e20))
        extra["SoCo"] = solidColor(red: 0, green: 110, blue: 255)
        extra["vstk"] = strokeStyle(fill: true, stroke: false, width: 1, red: 255, green: 255, blue: 0)
        #expect(throws: ImageImportError.tooLarge) {
            try PSDVector.live(extra: extra, canvas: PSDVectorFixtures.canvas)
        }
    }

    @Test func nonFiniteOriginationSizeIsIgnored() throws {
        var extra: [String: Data] = [:]
        extra["vogk"] = originationData(type: 5, rect: CGRect(x: 10, y: 10, width: CGFloat.infinity, height: 100))
        extra["SoCo"] = solidColor(red: 0, green: 110, blue: 255)
        extra["vstk"] = strokeStyle(fill: true, stroke: false, width: 1, red: 255, green: 255, blue: 0)
        #expect(try PSDVector.live(extra: extra, canvas: PSDVectorFixtures.canvas) == nil)
    }

    @Test func hugeStrokeWidthIsRejectedWithoutTrapping() throws {
        var extra: [String: Data] = [:]
        extra["vmsk"] = vectorMask(canvas: CGSize(width: 200, height: 200), corners: [
            CGPoint(x: 120, y: 30), CGPoint(x: 120, y: 80), CGPoint(x: 20, y: 80), CGPoint(x: 20, y: 30)
        ])
        extra["SoCo"] = solidColor(red: 0, green: 0, blue: 0)
        extra["vstk"] = strokeStyle(fill: true, stroke: true, width: 1e20, red: 255, green: 255, blue: 0)
        #expect(throws: ImageImportError.tooLarge) {
            try PSDVector.raster(extra: extra, canvas: CGSize(width: 200, height: 200))
        }
    }

    private func originationData(type: UInt32, rect: CGRect, radii: [Double] = []) -> Data {
        var data = Data()
        func append32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value >> 24))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        func appendDouble(_ value: Double) {
            var bits = value.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        func appendUnit(_ key: String, _ value: Double) {
            data.append(contentsOf: Array(key.utf8))
            data.append(contentsOf: Array("UntF".utf8))
            data.append(contentsOf: Array("#Pxl".utf8))
            appendDouble(value)
        }
        data.append(contentsOf: Array("keyOriginType".utf8))
        data.append(contentsOf: Array("long".utf8))
        append32(type)
        data.append(contentsOf: Array("keyOriginShapeBBox".utf8))
        appendUnit("Left", rect.minX)
        appendUnit("Top ", rect.minY)
        appendUnit("Rght", rect.maxX)
        appendUnit("Btom", rect.maxY)
        if radii.count == 4 {
            data.append(contentsOf: Array("keyOriginRRectRadii".utf8))
            for (key, value) in zip(["topLeft", "topRight", "bottomRight", "bottomLeft"], radii) {
                appendUnit(key, value)
            }
        }
        return data
    }

    private func vectorMask(canvas: CGSize, corners: [CGPoint]) -> Data {
        var data = Data()
        func append32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value >> 24))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        func append16(_ value: Int16) {
            let raw = UInt16(bitPattern: value)
            data.append(UInt8(truncatingIfNeeded: raw >> 8))
            data.append(UInt8(truncatingIfNeeded: raw))
        }
        func appendPoint(_ point: CGPoint) {
            let y = Int32((Double(point.y) / Double(canvas.height)) * 0x1000000)
            let x = Int32((Double(point.x) / Double(canvas.width)) * 0x1000000)
            append32(UInt32(bitPattern: y))
            append32(UInt32(bitPattern: x))
        }
        func padRecord() { data.append(Data(count: 24)) }
        append32(3); append32(0)
        append16(6); padRecord()
        append16(8); padRecord()
        append16(0)
        append16(Int16(corners.count))
        data.append(Data(count: 22))
        for corner in corners {
            append16(1)
            appendPoint(corner)
            appendPoint(corner)
            appendPoint(corner)
        }
        return data
    }

    private func solidColor(red: Double, green: Double, blue: Double) -> Data {
        colorDescriptor(red: red, green: green, blue: blue)
    }

    private func colorDescriptor(red: Double, green: Double, blue: Double) -> Data {
        var data = Data("RGBC".utf8)
        func append(_ key: String, _ value: Double) {
            data.append(contentsOf: Array(key.utf8))
            data.append(contentsOf: Array("doub".utf8))
            var bits = value.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        append("Rd  ", red)
        append("Grn ", green)
        append("Bl  ", blue)
        return data
    }

    private func strokeStyle(fill: Bool, stroke: Bool, width: Double, red: Double, green: Double, blue: Double) -> Data {
        var data = Data()
        func flag(_ key: String, _ value: Bool) {
            data.append(contentsOf: Array(key.utf8))
            data.append(contentsOf: Array("bool".utf8))
            data.append(value ? 1 : 0)
        }
        flag("strokeEnabled", stroke)
        flag("fillEnabled", fill)
        data.append(contentsOf: Array("strokeStyleLineWidth".utf8))
        data.append(contentsOf: Array("UntF".utf8))
        data.append(contentsOf: Array("#Pxl".utf8))
        var bits = width.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        data.append(colorDescriptor(red: red, green: green, blue: blue))
        return data
    }

    private func lsctTypes(in data: Data) -> [UInt32] {
        var types: [UInt32] = []
        var search = data.startIndex
        let needle = Data("lsct".utf8)
        while let range = data.range(of: needle, in: search..<data.endIndex), range.upperBound + 8 <= data.endIndex {
            let typeAt = range.upperBound + 4
            types.append(UInt32(data[typeAt]) << 24 | UInt32(data[typeAt + 1]) << 16 | UInt32(data[typeAt + 2]) << 8 | UInt32(data[typeAt + 3]))
            search = range.upperBound
        }
        return types
    }

    private func rawChannel(_ plane: Data) -> Data {
        var data = Data([0, 0])
        data.append(plane)
        return data
    }

    private func oversizedLayerFile(width: UInt32, height: UInt32, layerWidth: Int32, layerHeight: Int32) -> Data {
        layerFile(canvasWidth: width, canvasHeight: height, layerWidth: layerWidth, layerHeight: layerHeight, channels: [
            (-1, Data([0, 0])), (0, Data([0, 0])), (1, Data([0, 0])), (2, Data([0, 0])),
        ])
    }

    private func layerFile(
        canvasWidth: UInt32 = 8,
        canvasHeight: UInt32 = 8,
        layerWidth: Int32,
        layerHeight: Int32,
        channels: [(id: Int16, payload: Data)]
    ) -> Data {
        var data = header(width: canvasWidth, height: canvasHeight)
        func append32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value >> 24))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        append32(0)
        append32(0)
        var records = Data()
        func rec16(_ value: UInt16) {
            records.append(UInt8(truncatingIfNeeded: value >> 8))
            records.append(UInt8(truncatingIfNeeded: value))
        }
        func rec32(_ value: UInt32) {
            records.append(UInt8(truncatingIfNeeded: value >> 24))
            records.append(UInt8(truncatingIfNeeded: value >> 16))
            records.append(UInt8(truncatingIfNeeded: value >> 8))
            records.append(UInt8(truncatingIfNeeded: value))
        }
        func recI16(_ value: Int16) { rec16(UInt16(bitPattern: value)) }
        func recI32(_ value: Int32) { rec32(UInt32(bitPattern: value)) }
        recI16(1)
        recI32(0)
        recI32(0)
        recI32(layerHeight)
        recI32(layerWidth)
        rec16(UInt16(channels.count))
        var payloads = Data()
        for channel in channels {
            recI16(channel.id)
            rec32(UInt32(channel.payload.count))
            payloads.append(channel.payload)
        }
        records.append(contentsOf: Array("8BIMnorm".utf8))
        records.append(contentsOf: [255, 0, 0, 0])
        rec32(12)
        rec32(0)
        rec32(0)
        records.append(3)
        records.append(contentsOf: Array("Big".utf8))
        var info = Data()
        func info32(_ value: UInt32) {
            info.append(UInt8(truncatingIfNeeded: value >> 24))
            info.append(UInt8(truncatingIfNeeded: value >> 16))
            info.append(UInt8(truncatingIfNeeded: value >> 8))
            info.append(UInt8(truncatingIfNeeded: value))
        }
        info32(UInt32(records.count + payloads.count))
        info.append(records)
        info.append(payloads)
        info32(0)
        append32(UInt32(info.count))
        data.append(info)
        return data
    }
}
