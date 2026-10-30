import Compression
import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct ChannelPackTests {
    private func solid(_ gray: CGFloat, width: Int = 8, height: Int = 4) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// The first pixel of a Channel Pack PNG exactly as stored, read here rather than through Image I/O, whose decoding
    /// of color under transparent pixels differs between macOS versions; Image I/O must still open the file.
    private func firstPixel(_ data: Data) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil, "a PNG macOS can open")
        let bytes = [UInt8](data)
        var offset = 8, stream = [UInt8]()
        while offset + 8 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii)
            if type == "IDAT" { stream += bytes[offset + 8..<offset + 8 + length] }
            offset += 12 + length
        }
        // A zlib stream: two header bytes, raw deflate, then a four-byte checksum.
        let deflated = Array(stream[2..<(stream.count - 4)])
        var raw = [UInt8](repeating: 0, count: 1 << 16)
        let size = compression_decode_buffer(&raw, raw.count, deflated, deflated.count, nil, COMPRESSION_ZLIB)
        #expect(size > 4 && raw[0] == 0, "an unfiltered first row")
        return Array(raw[1...4])
    }

    private func document(alpha: CGFloat) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 8, height: 4)
        for (name, gray) in [("Red", 0.2), ("Green", 0.6), ("Blue", 1.0), ("Alpha", alpha)] {
            session.addPixelLayer(try solid(gray), at: .zero, name: name, editName: "Add")
        }
        return session
    }

    /// Layers named for their channels fill them without being picked, and a fully transparent alpha keeps the color
    /// under it, which an ordinary PNG would lose.
    @Test func layersNamedForChannelsPackIntoThemAndKeepColorUnderTransparency() async throws {
        let snapshot = try #require(try document(alpha: 0).projectSnapshot())
        let sources = ChannelPack.Channel.allCases.map { ChannelPack.defaultSource(for: $0, in: snapshot.manifest.layers) }
        #expect(sources.allSatisfy { if case .layer = $0 { true } else { false } })
        let packed = try await ImageExporter.shared.channelPack(snapshot, sources: sources, width: 8, height: 4)
        let pixel = try firstPixel(packed.data)
        #expect(abs(Int(pixel[0]) - 51) <= 1 && abs(Int(pixel[1]) - 153) <= 1 && pixel[2] == 255, "\(pixel)")
        #expect(pixel[3] == 0)
    }

    /// Solid sources, a hidden layer still used when it's picked, and a smaller size.
    @Test func blackWhiteAndHiddenLayersAtAnotherSize() async throws {
        let session = try document(alpha: 0.5)
        session.document!.layers[0].isVisible = false
        let snapshot = try #require(session.projectSnapshot())
        let red = snapshot.manifest.layers[0].id
        let packed = try await ImageExporter.shared.channelPack(snapshot, sources: [.layer(red), .black, .white, .white],
                                                                width: 4, height: 2)
        #expect(packed.preview.width == 4 && packed.preview.height == 2)
        let pixel = try firstPixel(packed.data)
        #expect(abs(Int(pixel[0]) - 51) <= 1 && pixel[1] == 0 && pixel[2] == 255 && pixel[3] == 255, "\(pixel)")
    }

    @Test func unnamedLayersLeaveColorBlackAndAlphaWhite() {
        let layers = [ProjectLayerRecord(id: UUID(), name: "Layer 1", isVisible: true,
                                         transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)), imageFile: nil)]
        #expect(ChannelPack.defaultSource(for: .red, in: layers) == .black)
        #expect(ChannelPack.defaultSource(for: .alpha, in: layers) == .white)
    }

    /// Image › Split Channels turns a layer into a folder of Red, Green, Blue and Alpha, in its place, which Channel
    /// Pack fills its channels from without being asked; undo puts the layer back.
    @Test func splitChannelsMakesLayersChannelPackPacksBack() async throws {
        let session = EditorSession()
        session.createDocument(width: 8, height: 4)
        let context = try #require(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 32,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        session.addPixelLayer(try #require(context.makeImage()), at: .zero, name: "Texture", editName: "Add")
        #expect(session.canSplitChannels)
        session.splitChannels()
        let layers = try #require(session.document?.layers)
        #expect(layers.map(\.name) == ["Texture", "Alpha", "Blue", "Green", "Red"])
        #expect(layers[0].isGroup && layers.dropFirst().allSatisfy { $0.parentID == layers[0].id })
        #expect(session.activeLayer?.name == "Red")

        let snapshot = try #require(session.projectSnapshot())
        let sources = ChannelPack.Channel.allCases.map { ChannelPack.defaultSource(for: $0, in: snapshot.manifest.layers) }
        let packed = try await ImageExporter.shared.channelPack(snapshot, sources: sources, width: 8, height: 4)
        let pixel = try firstPixel(packed.data)
        #expect(abs(Int(pixel[0]) - 51) <= 1 && abs(Int(pixel[1]) - 153) <= 1 && pixel[2] == 255 && pixel[3] == 255, "\(pixel)")

        session.undo()
        #expect(session.document?.layers.map(\.name) == ["Texture"])
    }
}
