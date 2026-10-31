import CoreGraphics
import Testing
@testable import Compositor

/// Hue/Saturation's color range control as Photoshop's: the strips with red in the middle, the band's parts a press
/// takes, what dragging each does, the readouts and the drawing. Shared by the Mac and the iPad.
struct HueBandControlTests {
    /// 360 points wide, so a point is a degree and x = degrees + 180, round the circle; the Mac's sizes.
    private let control = HueBandControl(width: 360, metrics: .mac)
    /// 315 / 345 / 15 / 45: at x 135, 165, 195 and 225.
    private let reds = ColorRange.reds.defaultBand
    /// 135 / 165 / 195 / 225: at x 315, 345, 15 and 45, across the ends.
    private let cyans = ColorRange.cyans.defaultBand

    private func part(_ band: HueBand, at x: CGFloat, inverted: Bool = false) -> HueBand.Part {
        control.part(at: x, of: band, inverted: inverted)
    }
    private func drag(_ band: HueBand, from x: CGFloat, to end: CGFloat, inverted: Bool = false) -> HueBand {
        HueBandDrag.begin(at: x, band: band, inverted: inverted, control: control).drag(to: end)
    }
    private func band(_ falloffStart: Double, _ rangeStart: Double, _ rangeEnd: Double, _ falloffEnd: Double) -> HueBand {
        HueBand(falloffStart: falloffStart, rangeStart: rangeStart, rangeEnd: rangeEnd, falloffEnd: falloffEnd)
    }

    // MARK: Mapping

    /// The same hue, round the circle.
    private func same(_ degrees: Double, _ other: Double) -> Bool { abs(HueBand.shortest(degrees, other)) < 1e-9 }

    @Test func redSitsInTheMiddleAndCyanAtBothEnds() {
        let mapping = HueBandMapping(width: 412)
        #expect(abs(mapping.x(of: 0) - 206) < 1e-9)
        #expect(abs(mapping.x(of: 180)) < 1e-9)
        #expect(abs(mapping.x(of: 90) - 309) < 1e-9)    // Yellow and green to the right,
        #expect(abs(mapping.x(of: 270) - 103) < 1e-9)   // blue and magenta to the left.
        #expect(same(mapping.degrees(at: 206), 0))
        #expect(same(mapping.degrees(at: 0), 180))
        // Scrolled, the offset is the hue in the middle, and the two stay each other's inverse.
        let scrolled = HueBandMapping(width: 412, offset: 120)
        #expect(abs(scrolled.x(of: 120) - 206) < 1e-9)
        for degrees in stride(from: 0.0, to: 360, by: 7.5) {
            #expect(same(scrolled.degrees(at: scrolled.x(of: degrees)), degrees))
            #expect(same(mapping.degrees(at: mapping.x(of: degrees)), degrees))
        }
        // Never clamped: past either end the hues go on round the circle.
        #expect(same(mapping.degrees(at: 412 + 103), 270))
        #expect(same(mapping.degrees(at: -103), 90))
        #expect(abs(mapping.degrees(spanning: 103) - 90) < 1e-9)
    }

    // MARK: Hit-testing

    @Test func aPressTakesThePartUnderIt() {
        #expect(part(reds, at: 165) == .handle(1))
        #expect(part(reds, at: 172) == .handle(1))   // The capsule's 2 points and 5 more.
        #expect(part(reds, at: 174) == .range)
        #expect(part(reds, at: 180) == .range)
        #expect(part(reds, at: 195) == .handle(2))
        #expect(part(reds, at: 150) == .falloff(.leading))
        #expect(part(reds, at: 210) == .falloff(.trailing))
        // A triangle stands outward of its degree, so it reaches further that way.
        #expect(part(reds, at: 135) == .handle(0))
        #expect(part(reds, at: 124) == .handle(0))
        #expect(part(reds, at: 140) == .handle(0))
        #expect(part(reds, at: 141) == .falloff(.leading))
        #expect(part(reds, at: 237) == .handle(3))
        #expect(part(reds, at: 238) == .outside)
        #expect(part(reds, at: 300) == .outside)
        #expect(part(reds, at: 20) == .outside)
        // At the Mac's own width the reach is still in points: 6 points beside the range start's capsule.
        let mac = HueBandControl(width: 412, metrics: .mac)
        #expect(mac.part(at: mac.mapping.x(of: 345) + 6, of: reds, inverted: false) == .handle(1))
        #expect(mac.part(at: mac.mapping.x(of: 345) + 8, of: reds, inverted: false) == .range)
    }

    @Test func aHandleLeavesTheMiddleThirdOfANarrowFill() {
        // 6° of falloff: each handle takes no more than 2 of it.
        let narrow = band(339, 345, 15, 45)
        #expect(part(narrow, at: 161) == .handle(0))
        #expect(part(narrow, at: 162) == .falloff(.leading))
        #expect(part(narrow, at: 163) == .handle(1))
    }

    @Test func coincidentHandlesGoToThePressesSide() {
        // No falloff: the triangle stands left of the pair, the capsule over it.
        let sharp = band(345, 345, 15, 45)
        #expect(part(sharp, at: 163) == .handle(0))
        #expect(part(sharp, at: 167) == .handle(1))
        // No range: two capsules in one place.
        let point = band(315, 0, 0, 45)
        #expect(part(point, at: 178) == .handle(1))
        #expect(part(point, at: 182) == .handle(2))
    }

    @Test func aBandAcrossTheEndsIsTakenOnBothSides() {
        #expect(part(cyans, at: 2) == .range)
        #expect(part(cyans, at: 358) == .range)
        #expect(part(cyans, at: 15) == .handle(2))
        #expect(part(cyans, at: 345) == .handle(1))
        #expect(part(cyans, at: 330) == .falloff(.leading))
        #expect(part(cyans, at: 30) == .falloff(.trailing))
        // A handle on cyan itself is half at each end.
        let atCyan = band(120, 150, 180, 210)
        #expect(part(atCyan, at: 2) == .handle(2))
        #expect(part(atCyan, at: 358) == .handle(2))
    }

    @Test func invertedTheFullStrengthIsOutsideAndTheRangeIsAGap() {
        #expect(part(reds, at: 0, inverted: true) == .range)
        #expect(part(reds, at: 300, inverted: true) == .range)
        #expect(part(reds, at: 180, inverted: true) == .outside)
        #expect(part(reds, at: 150, inverted: true) == .falloff(.leading))
        #expect(part(reds, at: 135, inverted: true) == .handle(0))
        // The range handles are triangles pointing into the gap.
        #expect(part(reds, at: 177, inverted: true) == .handle(1))
        #expect(part(reds, at: 183, inverted: true) == .handle(2))
        #expect(part(reds, at: 160, inverted: true) == .handle(1))
    }

    // MARK: Dragging

    @Test func theRangeFillMovesAllFour() {
        #expect(drag(reds, from: 180, to: 190) == band(325, 355, 25, 55))
        #expect(drag(reds, from: 180, to: 140) == band(275, 305, 335, 5))
        // Off either end and in at the other: the pointer keeps going past the control.
        #expect(drag(cyans, from: 2, to: -28) == band(105, 135, 165, 195))
        #expect(drag(cyans, from: 358, to: 398) == band(175, 205, 235, 265))
        // Inverted, the full strength is outside.
        #expect(drag(reds, from: 0, to: 10, inverted: true) == band(325, 355, 25, 55))
    }

    @Test func aFalloffFillMovesItsSidesPair() {
        #expect(drag(reds, from: 150, to: 140) == band(305, 335, 15, 45))
        #expect(drag(reds, from: 210, to: 230) == band(315, 345, 35, 65))
        // It stops at the other pair rather than passing it.
        #expect(drag(reds, from: 150, to: 200) == band(345, 15, 15, 45))
        #expect(drag(reds, from: 210, to: 160) == band(315, 345, 345, 15))
        // And the band stays under 350°, either side.
        #expect(drag(reds, from: 150, to: -200) == band(55, 85, 15, 45))
        #expect(drag(reds, from: 210, to: 600) == band(315, 345, 275, 305))
    }

    @Test func aHandleStopsAtItsNeighbor() {
        #expect(drag(reds, from: 165, to: 225) == band(315, 15, 15, 45))
        #expect(drag(reds, from: 165, to: 100) == band(315, 315, 15, 45))
        #expect(drag(reds, from: 195, to: 100) == band(315, 345, 345, 45))
        #expect(drag(reds, from: 195, to: 300) == band(315, 345, 45, 45))
        #expect(drag(reds, from: 135, to: 200) == band(345, 345, 15, 45))
        #expect(drag(reds, from: 225, to: 150) == band(315, 345, 15, 15))
        #expect(drag(reds, from: 225, to: 300) == band(315, 345, 15, 120))
        #expect(drag(reds, from: 135, to: 0) == band(180, 345, 15, 45))
        // The band stays under 350° and over 1°.
        #expect(drag(reds, from: 225, to: 359 + 360) == band(315, 345, 15, 305))
        #expect(drag(reds, from: 135, to: -300) == band(55, 345, 15, 45))
        #expect(drag(band(315, 345, 345, 345), from: 135, to: 200) == band(343, 345, 345, 345))
    }

    @Test func handlesWrapAcrossRedAndAcrossCyan() {
        // Across red, in the middle: the degrees wrap.
        #expect(drag(reds, from: 195, to: 170) == band(315, 345, 350, 45))
        #expect(drag(reds, from: 165, to: 190) == band(315, 10, 15, 45))
        // Across cyan, at the ends: the pointer leaves one end and the handle comes in at the other.
        #expect(drag(cyans, from: 15, to: -10) == band(135, 165, 170, 225))
        #expect(drag(cyans, from: 345, to: 370) == band(135, 190, 195, 225))
    }

    @Test func aHandleKeepsWhereItWasTaken() {
        // Taken 3 points right of its middle, it doesn't jump to the press.
        #expect(drag(reds, from: 168, to: 168) == reds)
        #expect(drag(reds, from: 168, to: 173) == band(315, 350, 15, 45))
        // Every drag is measured from the band at the press, so a stop at a neighbor recovers on the way back.
        let held = HueBandDrag.begin(at: 165, band: reds, inverted: false, control: control)
        #expect(held.drag(to: 260) == band(315, 15, 15, 45))
        #expect(held.drag(to: 170) == band(315, 350, 15, 45))
        #expect(held.drag(to: 165) == reds)
    }

    @Test func dragsWriteWholeDegrees() {
        let mac = HueBandControl(width: 412, metrics: .mac)
        let start = mac.mapping.x(of: 345)
        let moved = HueBandDrag.begin(at: start, band: reds, inverted: false, control: mac).drag(to: start + 7)
        #expect(moved == band(315, 351, 15, 45))   // 7 points is 6.1°.
        // A band in fractions stays as it is until it moves, then lands on whole degrees.
        let fractional = band(100.4, 130.4, 160.4, 190.4)
        #expect(drag(fractional, from: 325, to: 325) == fractional)
        #expect(drag(fractional, from: 325, to: 335) == band(110, 140, 170, 200))
        // A press beyond it brings a handle to a whole degree, and the others with it.
        #expect(drag(fractional, from: 60, to: 60) == band(100, 130, 160, 240))
        // A band so narrow that whole degrees would close it up, and so cover the whole circle, keeps its fractions.
        let narrow = band(100.75, 101, 101.25, 101.25)
        let middle = control.mapping.x(of: 101.125)
        #expect(drag(narrow, from: middle, to: middle + 10) == band(110.75, 111, 111.25, 111.25))
    }

    @Test func aPressBeyondTheBandBringsTheNearestHandle() {
        let brought = HueBandDrag.begin(at: 280, band: reds, inverted: false, control: control)
        #expect(brought.grab == .part(.handle(3)))
        #expect(brought.drag(to: 280) == band(315, 345, 15, 100))
        #expect(brought.drag(to: 290) == band(315, 345, 15, 110))
        #expect(drag(reds, from: 60, to: 60) == band(240, 345, 15, 45))
        // Inverted, the gap is beyond the band.
        #expect(drag(reds, from: 178, to: 178, inverted: true) == band(315, 358, 15, 45))
        // Of two handles in one place, the one that can move into the empty lane comes: with no trailing falloff, the
        // falloff end rather than the range end under it,
        let sharp = HueBandDrag.begin(at: 240, band: band(315, 345, 45, 45), inverted: false, control: control)
        #expect(sharp.grab == .part(.handle(3)))
        #expect(sharp.drag(to: 240) == band(315, 345, 45, 60))
        // and inverted with no leading falloff, the range start rather than the falloff start under it.
        let gap = HueBandDrag.begin(at: 178, band: band(345, 345, 15, 45), inverted: true, control: control)
        #expect(gap.grab == .part(.handle(1)))
        #expect(gap.drag(to: 178) == band(345, 358, 15, 45))
    }

    @Test func commandDragScrollsTheStrips() {
        let scroll = HueBandDrag.begin(at: 100, band: reds, inverted: false, control: control, scrolls: true)
        #expect(scroll.grab == .scroll)
        #expect(scroll.drag(to: 130) == reds)
        #expect(abs(scroll.offset(at: 130) - 330) < 1e-9)
        // The strips follow the pointer: red moves 30 points right.
        #expect(abs(HueBandMapping(width: 360, offset: scroll.offset(at: 130)).x(of: 0) - 210) < 1e-9)
        #expect(abs(scroll.offset(at: 70) - 30) < 1e-9)
    }

    @Test func theTakenHandlesAreTheOnesThatMove() {
        func active(_ x: CGFloat) -> [Int] { HueBandDrag.begin(at: x, band: reds, inverted: false, control: control).activeHandles }
        #expect(active(180) == [0, 1, 2, 3])
        #expect(active(150) == [0, 1])
        #expect(active(210) == [2, 3])
        #expect(active(165) == [1])
        #expect(active(300) == [3])
        #expect(HueBandDrag.begin(at: 180, band: reds, inverted: false, control: control, scrolls: true).activeHandles == [])
    }

    // MARK: Readouts

    @Test func readoutsShowEachSidesRamp() {
        let normal = HueBandControl.readouts(reds, inverted: false)
        #expect(normal.leading == "315° / 345°")
        #expect(normal.trailing == "15° \\ 45°")
        let inverted = HueBandControl.readouts(reds, inverted: true)
        #expect(inverted.leading == "315° \\ 345°")
        #expect(inverted.trailing == "15° / 45°")
        let fractional = HueBandControl.readouts(band(299.6, 329.5, 359.6, 29.4), inverted: false)
        #expect(fractional.leading == "300° / 330°")
        #expect(fractional.trailing == "0° \\ 29°")
        #expect(HueBandControl.spokenReadouts(reds)
                == "Falloff start 315 degrees, Range start 345 degrees, Range end 15 degrees, Falloff end 45 degrees")
    }

    // MARK: Drawing

    /// The control drawn by the shared code at the Mac's width, 2 pixels a point unless asked, its y pointing down as
    /// both platforms' views have it. Strips 0…10, lane 10…24, strips 24…34.
    private struct Drawn {
        let bytes: [UInt8]
        let width: Int
        let scale: CGFloat
        /// The pixel at a point, premultiplied RGBA.
        func at(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let index = (Int(y * scale) * width + Int(x * scale)) * 4
            return (0..<4).map { Int(bytes[index + $0]) }
        }
    }
    private func draw(_ settings: HueSaturationSettings, dark: Bool = true, active: [Int] = [], scale: CGFloat = 2) throws -> Drawn {
        let control = HueBandControl(width: 412, metrics: .mac)
        let width = Int(412 * scale), height = Int(control.metrics.height * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        control.draw(settings, dark: dark, accent: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), active: active, scale: scale,
                     in: context)
        let data = try #require(context.data)
        return Drawn(bytes: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)),
                     width: width, scale: scale)
    }
    private func near(_ value: [Int], _ target: [Int], _ tolerance: Int = 6) -> Bool {
        zip(value, target).allSatisfy { abs($0 - $1) <= tolerance }
    }
    private func x(_ degrees: Double) -> CGFloat { HueBandMapping(width: 412).x(of: degrees) }

    @Test func theStripsShowRedInTheMiddleAndTheBandBetween() throws {
        let reds = try draw(HueSaturationSettings(range: .reds))
        #expect(near(reds.at(206, 5), [255, 0, 0, 255]))                   // Red in the middle of the before strip,
        #expect(near(reds.at(1, 5), [0, 255, 255, 255], 12))              // cyan at both ends.
        #expect(near(reds.at(411, 5), [0, 255, 255, 255], 12))
        #expect(near(reds.at(206, 29), [255, 0, 0, 255]))                 // No change: the after strip is the same.
        #expect(near(reds.at(206, 17), [0xB4, 0xB4, 0xB4, 255], 2))       // The full strength, in Reds' middle.
        #expect(near(reds.at(x(330), 17), [0x63, 0x63, 0x66, 255], 2))    // The falloff.
        #expect(near(reds.at(x(345), 17), [255, 255, 255, 255], 2))       // The range start's capsule,
        #expect(near(reds.at(x(315) - 2, 21), [255, 255, 255, 255], 2))   // the falloff start's triangle, left of it.
        #expect(reds.at(x(315) + 0.25, 13)[0] < 0x63)                       // Its upright edge, on the degree.
        #expect(reds.at(x(100), 17)[3] == 0)                              // Beyond the band the lane is clear.
        #expect(near(reds.at(206, 0.25), [144, 55, 57, 255], 4))          // A hairline round each strip.
        #expect(near(reds.at(206, 33.75), [144, 55, 57, 255], 4))
        let light = try draw(HueSaturationSettings(range: .reds), dark: false)
        #expect(near(light.at(206, 17), [0x8E, 0x8E, 0x93, 255], 2))
        #expect(near(light.at(x(330), 17), [0xC7, 0xC7, 0xCC, 255], 2))
    }

    @Test func theAfterStripShowsTheWholeAdjustment() throws {
        let gray = try draw(HueSaturationSettings(saturation: -100, range: .reds))
        let middle = gray.at(206, 29)
        #expect(abs(middle[0] - middle[1]) <= 2 && abs(middle[1] - middle[2]) <= 2)   // Reds gone gray,
        #expect(near(gray.at(x(120), 29), [0, 255, 0, 255], 8))                       // greens untouched,
        #expect(near(gray.at(206, 5), [255, 0, 0, 255]))                              // and the before strip as it was.
        let darker = try draw(HueSaturationSettings(lightness: -100, range: .reds))
        #expect(near(darker.at(206, 29), [0, 0, 0, 255], 4))
        let shifted = try draw(HueSaturationSettings(hue: 120))                         // Master: red turns green.
        #expect(near(shifted.at(206, 29), [0, 255, 0, 255], 8))
    }

    @Test func aBandAcrossTheEndsIsDrawnAtBoth() throws {
        let cyans = try draw(HueSaturationSettings(range: .cyans))
        #expect(near(cyans.at(1, 17), [0xB4, 0xB4, 0xB4, 255], 2))
        #expect(near(cyans.at(411, 17), [0xB4, 0xB4, 0xB4, 255], 2))
        #expect(cyans.at(206, 17)[3] == 0)
        // A handle on cyan itself is half at each end.
        var split = HueSaturationSettings(range: .cyans)
        split.band = band(120, 150, 180, 210)
        let atCyan = try draw(split)
        #expect(near(atCyan.at(0.75, 17), [255, 255, 255, 255], 2))
        #expect(near(atCyan.at(411.25, 17), [255, 255, 255, 255], 2))
    }

    @Test func invertedTheFullStrengthIsDrawnOutside() throws {
        var settings = HueSaturationSettings(range: .reds)
        settings.invertRange = true
        let inverted = try draw(settings)
        #expect(near(inverted.at(20, 17), [0xB4, 0xB4, 0xB4, 255], 2))
        #expect(near(inverted.at(x(330), 17), [0x63, 0x63, 0x66, 255], 2))
        #expect(inverted.at(206, 17)[3] == 0)                              // The gap between is the excluded hues.
        #expect(near(inverted.at(x(345) + 2, 21), [255, 255, 255, 255], 2)) // The range start's triangle points into it.
    }

    @Test func masterShowsTheStripsWithAnEmptyLane() throws {
        let master = try draw(HueSaturationSettings(hue: 30))
        #expect(near(master.at(206, 5), [255, 0, 0, 255]))
        #expect(master.at(206, 17)[3] > 0 && master.at(206, 17)[3] < 64)  // A faint line,
        #expect(master.at(x(345), 12)[3] == 0)                             // and no handles.
        #expect(master.at(206, 21)[3] == 0)
    }

    @Test func theTakenHandleIsDrawnInTheAccentColor() throws {
        let taken = try draw(HueSaturationSettings(range: .reds), active: [1])
        let capsule = (x(345) * 2).rounded() / 2   // On a device pixel.
        #expect(near(taken.at(capsule - 2.25, 17), [0, 0, 255, 255], 24))
        let untaken = try draw(HueSaturationSettings(range: .reds))
        #expect(near(untaken.at(capsule - 2.25, 17), [0, 0, 0, 255], 24))
    }

    @Test func outlinesCoverWholePixelsAtOneAPoint() throws {
        let reds = try draw(HueSaturationSettings(range: .reds), scale: 1)
        // The range start's capsule: a pixel of outline either side of three white ones, none of them blended.
        let capsule = x(345).rounded()
        #expect(near(reds.at(capsule - 2, 17), [0, 0, 0, 255], 2))
        for column in [capsule - 1, capsule, capsule + 1] { #expect(near(reds.at(column, 17), [255, 255, 255, 255], 2)) }
        #expect(near(reds.at(capsule + 2, 17), [0, 0, 0, 255], 2))
        // The falloff start's triangle: its upright side and its floor.
        let triangle = x(315).rounded()
        #expect(near(reds.at(triangle, 15), [0, 0, 0, 255], 2))
        #expect(near(reds.at(triangle - 3, 23), [0, 0, 0, 255], 2))
    }
}
