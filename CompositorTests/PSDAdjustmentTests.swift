import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Adjustment layers and layer masks read from a PSD, laid out as Photoshop writes them.
struct PSDAdjustmentTests {
    private func shorts(_ values: [Int]) -> Data {
        values.reduce(into: Data()) { data, value in
            let bits = UInt16(bitPattern: Int16(value))
            data.append(contentsOf: [UInt8(bits >> 8), UInt8(bits & 0xFF)])
        }
    }

    @Test func levelsGammaIsInHundredths() throws {
        // RGB: input 2–254, gamma 1.00 (stored as 100); red, green and blue untouched; padded to Photoshop's 29 records.
        var data = shorts([2, 2, 254, 0, 255, 100] + Array(repeating: [0, 255, 0, 255, 100], count: 3).flatMap { $0 })
        data.append(Data(count: 292 - data.count))
        let levels = try #require(PSDAdjustments.levels(data)?.levels)
        #expect(levels.ranges[0] == LevelRange(black: 2, gamma: 1, white: 254, outputBlack: 0, outputWhite: 255))
        #expect(levels.ranges[1...3].allSatisfy { $0.gamma == 1 })
    }

    @Test func hueSaturationReadsMasterAndEachRange() throws {
        // Version 2, Colorize off; Colorize values (ignored), Master +5/+4/0; Reds' band and −30 saturation, +10 light.
        var data = shorts([2]) + Data([0, 0]) + shorts([23, 25, 0, 5, 4, 0, 315, 345, 15, 45, 0, -30, 10])
        data += shorts(Array(repeating: 0, count: 7 * 5))
        let settings = try #require(PSDAdjustments.hue(data)?.hsvSettings)
        #expect(!settings.colorize)
        #expect(settings.adjustments[.master] == RangeAdjustment(hue: 5, saturation: 4, lightness: 0))
        #expect(settings.adjustments[.reds] == RangeAdjustment(hue: 0, saturation: -30, lightness: 10))
        #expect(settings.bands[.reds] == HueBand(falloffStart: 315, rangeStart: 345, rangeEnd: 15, falloffEnd: 45))

        data[2] = 1  // Colorize on: its own values apply.
        let colorized = try #require(PSDAdjustments.hue(data)?.hsvSettings)
        #expect(colorized.colorize && colorized.adjustments[.master] == RangeAdjustment(hue: 23, saturation: 25, lightness: 0))
    }

    @Test func maskPatchSitsWhereItIsOnTheCanvas() throws {
        // A 2 × 2 white patch at (3, 1) on a 6 × 4 canvas, black everywhere else, on an adjustment layer (no pixels of its
        // own, so it covers the canvas): the patch must land at (3, 1), not stretch over the whole layer.
        let patch = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 2,
                                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        patch.setFillColor(gray: 1, alpha: 1)
        patch.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        var record = PSDRecord(id: UUID(), parentID: nil, name: "Levels")
        record.maskBounds = CGRect(x: 3, y: 1, width: 2, height: 2)
        record.maskDefault = 0
        let canvas = CGSize(width: 6, height: 4)
        let layer = ImageLayer(id: UUID(), asset: nil, name: "Levels", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: canvas), parentID: nil)
        let patchImage = try #require(patch.makeImage())
        let mask = try #require(PSDDocumentBuilder.maskOnLayerGrid(patchImage, record: record, layer: layer, canvas: canvas))
        #expect(mask.width == 6 && mask.height == 4)
        let pixels = try #require(mask.dataProvider?.data as Data?)
        let rows = (0..<4).map { y in (0..<6).map { x in pixels[y * mask.bytesPerRow + x] > 127 ? "#" : "." }.joined() }
        #expect(rows == ["......", "...##.", "...##.", "......"])
    }
}
