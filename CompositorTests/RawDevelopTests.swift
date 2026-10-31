import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Importing a RAW file: the develop the import runs once Import is pressed.
@MainActor struct RawDevelopTests {
    /// A DNG the system's RAW engine develops: a 256 × 192 frame of demosaiced 16-bit RGB (a linear raw, as an iPhone's
    /// ProRAW is), a horizontal ramp, in one strip, with the tags DNG asks for and nothing more. Smaller than 160 × 120,
    /// the engine turns it down.
    private func dng() throws -> URL {
        let width = 256, height = 192
        func short(_ value: Int) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)] }
        func long(_ value: Int) -> [UInt8] { short(value & 0xffff) + short(value >> 16 & 0xffff) }
        func rational(_ numerator: Int, _ denominator: Int) -> [UInt8] { long(numerator) + long(denominator) }
        func ascii(_ text: String) -> [UInt8] { Array((text + "\0").utf8) }
        // (tag, type, count, value); TIFF's types: BYTE 1, ASCII 2, SHORT 3, LONG 4, RATIONAL 5 and SRATIONAL 10.
        var entries: [(tag: Int, type: Int, count: Int, value: [UInt8])] = [
            (254, 4, 1, long(0)),                                   // NewSubfileType: the image itself
            (256, 4, 1, long(width)), (257, 4, 1, long(height)),
            (258, 3, 3, short(16) + short(16) + short(16)),         // BitsPerSample
            (259, 3, 1, short(1)),                                  // Compression: none
            (262, 3, 1, short(34892)),                              // PhotometricInterpretation: LinearRaw
            (271, 2, 5, ascii("Test")), (272, 2, 5, ascii("Test")), // Make, Model
            (273, 4, 1, []),                                        // StripOffsets, once the layout is known
            (274, 3, 1, short(1)),                                  // Orientation
            (277, 3, 1, short(3)),                                  // SamplesPerPixel
            (278, 4, 1, long(height)), (279, 4, 1, long(width * height * 6)), // RowsPerStrip, StripByteCounts
            (284, 3, 1, short(1)),                                  // PlanarConfiguration: chunky
            (50706, 1, 4, [1, 4, 0, 0]), (50707, 1, 4, [1, 1, 0, 0]), // DNGVersion, DNGBackwardVersion
            (50708, 2, 5, ascii("Test")),                           // UniqueCameraModel
            (50717, 4, 3, long(65535) + long(65535) + long(65535)), // WhiteLevel
            (50721, 10, 9, (0..<9).flatMap { rational($0 % 4 == 0 ? 1 : 0, 1) }), // ColorMatrix1: XYZ as camera RGB
            (50728, 5, 3, (0..<3).flatMap { _ in rational(1, 1) }), // AsShotNeutral
            (50778, 3, 1, short(21)),                               // CalibrationIlluminant1: D65
        ]
        entries.sort { $0.tag < $1.tag }
        // The header, the directory, then the values too long for their entries, then the pixels.
        let valuesAt = 8 + 2 + 12 * entries.count + 4
        let pixelsAt = valuesAt + entries.reduce(0) { $0 + ($1.value.count > 4 ? $1.value.count : 0) }
        var directory = short(entries.count), values: [UInt8] = []
        for entry in entries {
            let value = entry.tag == 273 ? long(pixelsAt) : entry.value
            directory += short(entry.tag) + short(entry.type) + long(entry.count)
            if value.count > 4 {
                directory += long(valuesAt + values.count)
                values += value
            } else {
                directory += value + [UInt8](repeating: 0, count: 4 - value.count)
            }
        }
        directory += long(0)
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 6)
        for _ in 0..<height {
            for x in 0..<width {
                let value = short(x * 65535 / (width - 1))
                for _ in 0..<3 { pixels += value }
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
        try Data([0x49, 0x49, 42, 0] + long(8) + directory + values + pixels).write(to: url)
        return url
    }

    /// Import develops the full frame at 16 bits a channel unless the session is told otherwise: a 16-bit layer that
    /// keeps the RAW's latitude, or, with `developsRawAtSixteenBits` off as the iPad has it, an 8-bit one, dithered as
    /// RAW imports were before 16-bit layers.
    @Test(arguments: [true, false]) func importDevelopsAtTheDepthTheSessionSays(sixteenBit: Bool) async throws {
        let url = try dng()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        #expect(session.developsRawAtSixteenBits, "16 bits unless told otherwise")
        session.developsRawAtSixteenBits = sixteenBit
        session.confirmRawDevelop = { _, settings in settings }
        await session.importImages([url])
        #expect(session.importError == nil)
        let asset = try #require(session.activeLayer?.asset)
        #expect(asset.image.width == 256 && asset.image.height == 192 && asset.image.bitsPerComponent == 8)
        #expect((asset.deep?.bitsPerComponent == 16) == sixteenBit, "developed at \(sixteenBit ? 16 : 8) bits")
    }
}
