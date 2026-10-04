import CoreGraphics

/// Where the hues sit along Hue/Saturation's color range control: red in the middle and cyan at both ends, as
/// Photoshop has them, unless Command-drag has scrolled the strips. Never clamped: past either end the hues go on
/// round the circle, so a drag off one end comes back in at the other.
nonisolated struct HueBandMapping: Equatable, Sendable {
    var width: CGFloat
    /// The hue in the middle. Only the view's: never saved, and red again whenever the panel opens.
    var offset = 0.0

    func x(of degrees: Double) -> CGFloat {
        CGFloat(HueBand.forward(offset - 180, degrees) / 360) * width
    }

    func degrees(at x: CGFloat) -> Double {
        HueBand.forward(0, degrees(spanning: x) + offset - 180)
    }

    /// The degrees a distance along the strips covers.
    func degrees(spanning points: CGFloat) -> Double {
        width > 0 ? Double(points / width) * 360 : 0
    }
}

/// The color range control's sizes, in points, on the Mac and on the iPad.
nonisolated struct HueBandMetrics: Equatable, Sendable {
    /// Each strip of hues, before and after.
    var stripHeight: CGFloat = 10
    /// The lane between the strips, where the band and its handles are.
    var laneHeight: CGFloat
    /// The range handles' capsule.
    var capsule: CGSize
    /// The falloff handles' right triangle, its upright side on the handle's degree.
    var triangle: CGSize
    /// How far beyond its shape a handle still takes a press.
    var reach: CGFloat
    /// The readouts above the strips, and the gap under them.
    var readoutFontSize: CGFloat
    var readoutGap: CGFloat = 4
    /// How far above and below the strips a press still lands.
    var touchOutset: CGFloat = 0

    static let mac = HueBandMetrics(laneHeight: 14, capsule: CGSize(width: 4, height: 12), triangle: CGSize(width: 7, height: 12),
                                    reach: 5, readoutFontSize: 11)
    /// Larger handles and reach for a finger, and 44 points to touch.
    static let pad = HueBandMetrics(laneHeight: 16, capsule: CGSize(width: 5, height: 14), triangle: CGSize(width: 8, height: 14),
                                    reach: 12, readoutFontSize: 12, touchOutset: 4)

    /// The two strips and the lane between them.
    var height: CGFloat { stripHeight * 2 + laneHeight }
}

/// The color range control's colors, a light and a dark sRGB value each, for each platform to pick as its appearance
/// is. Photoshop's rule in either theme: the full strength stands out most from the panel, the falloff halfway.
nonisolated enum HueBandColor: CaseIterable, Sendable {
    /// The full-strength fill.
    case range
    case falloff
    case handleFill
    case handleStroke
    /// A hairline round each strip, so cyan and yellow keep an edge on a light panel.
    case stripBorder
    /// Master's lane, empty but for a faint line.
    case emptyLane

    /// Red, green, blue and alpha, 0…1.
    func components(dark: Bool) -> [CGFloat] {
        func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> [CGFloat] {
            [red / 255, green / 255, blue / 255, alpha]
        }
        switch self {
        case .range: return dark ? rgb(0xB4, 0xB4, 0xB4) : rgb(0x8E, 0x8E, 0x93)
        case .falloff: return dark ? rgb(0x63, 0x63, 0x66) : rgb(0xC7, 0xC7, 0xCC)
        case .handleFill: return rgb(0xFF, 0xFF, 0xFF)
        case .handleStroke: return dark ? rgb(0, 0, 0) : rgb(0x3A, 0x3A, 0x3C)
        case .stripBorder: return dark ? rgb(84, 84, 88, 0.65) : rgb(60, 60, 67, 0.29)
        case .emptyLane: return dark ? rgb(255, 255, 255, 0.12) : rgb(0, 0, 0, 0.1)
        }
    }

    func cgColor(dark: Bool) -> CGColor {
        let value = components(dark: dark)
        return CGColor(srgbRed: value[0], green: value[1], blue: value[2], alpha: value[3])
    }
}

/// Hue/Saturation's color range control, as Photoshop's: the hues as they are in a strip above, as the whole
/// adjustment leaves them in a strip below, and in the lane between the selected range's band, a full-strength fill
/// between two capsule handles with a falloff fill each side of it out to a triangle handle. Drawn and hit-tested here
/// with CoreGraphics alone, apart from any one interface, which adds its own text for the readouts.
nonisolated struct HueBandControl: Equatable, Sendable {
    var mapping: HueBandMapping
    var metrics: HueBandMetrics

    init(width: CGFloat, offset: Double = 0, metrics: HueBandMetrics) {
        mapping = HueBandMapping(width: width, offset: offset)
        self.metrics = metrics
    }

    var beforeStrip: CGRect { CGRect(x: 0, y: 0, width: mapping.width, height: metrics.stripHeight) }
    var lane: CGRect { CGRect(x: 0, y: metrics.stripHeight, width: mapping.width, height: metrics.laneHeight) }
    var afterStrip: CGRect {
        CGRect(x: 0, y: metrics.stripHeight + metrics.laneHeight, width: mapping.width, height: metrics.stripHeight)
    }

    /// The full strength's edges are capsules and the falloff's ends triangles; inverted, the full strength is outside
    /// the falloff handles, so they swap.
    static func isCapsule(_ index: Int, inverted: Bool) -> Bool {
        inverted ? index == 0 || index == 3 : index == 1 || index == 2
    }

    /// Which way a triangle points from its upright side: outward, left for the starts and right for the ends;
    /// inverted, the range's triangles point inward, into the gap.
    static func pointing(_ index: Int, inverted: Bool) -> CGFloat {
        let outward: CGFloat = index < 2 ? -1 : 1
        return inverted ? -outward : outward
    }

    /// Each handle's shape in degrees either side of it.
    func shapes(inverted: Bool) -> [ClosedRange<Double>] {
        (0..<4).map { index in
            if Self.isCapsule(index, inverted: inverted) {
                let half = mapping.degrees(spanning: metrics.capsule.width / 2)
                return -half...half
            }
            let length = mapping.degrees(spanning: metrics.triangle.width)
            return Self.pointing(index, inverted: inverted) < 0 ? -length...0 : 0...length
        }
    }

    /// What a press at `x` takes, at any height in the control.
    func part(at x: CGFloat, of band: HueBand, inverted: Bool) -> HueBand.Part {
        band.part(at: mapping.degrees(at: x), reach: mapping.degrees(spanning: metrics.reach), shapes: shapes(inverted: inverted),
                  inverted: inverted)
    }

    /// The readouts beside the strips, as Photoshop's: the falloff and range starts on the leading side, the range and
    /// falloff ends on the trailing side, the slashes echoing the ramps up and down, which turn over when inverted.
    static func readouts(_ band: HueBand, inverted: Bool) -> (leading: String, trailing: String) {
        let degrees = band.handles.map { (Int($0.rounded()) % 360 + 360) % 360 }
        let (up, down) = inverted ? ("\\", "/") : ("/", "\\")
        return ("\(degrees[0])° \(up) \(degrees[1])°", "\(degrees[2])° \(down) \(degrees[3])°")
    }

    /// The four handles, read aloud.
    static func spokenReadouts(_ band: HueBand) -> String {
        let names = ["Falloff start", "Range start", "Range end", "Falloff end"]
        return zip(names, band.handles).map { "\($0) \((Int($1.rounded()) % 360 + 360) % 360) degrees" }.joined(separator: ", ")
    }

    /// A hue at full saturation and brightness.
    static func pureHue(_ degrees: Double) -> (red: Double, green: Double, blue: Double) {
        let sector = HueBand.forward(0, degrees) / 60
        let rise = sector - sector.rounded(.down)
        switch Int(sector) {
        case 0: return (1, rise, 0)
        case 1: return (1 - rise, 1, 0)
        case 2: return (0, 1, rise)
        case 3: return (0, 1 - rise, 1)
        case 4: return (rise, 0, 1)
        default: return (1, 0, 1 - rise)
        }
    }

    /// Draws the strips and the lane from the context's origin, its y axis pointing down as SwiftUI's and UIKit's do.
    /// The handles in `active` are the ones a press took, stroked in `accent`; `scale` is the device pixels in a point,
    /// which the handles and hairlines keep to. Anything across an end is drawn at both.
    func draw(_ settings: HueSaturationSettings, dark: Bool, accent: CGColor, active: [Int] = [], scale: CGFloat,
              in context: CGContext) {
        let width = mapping.width
        guard width > 0 else { return }
        let scale = max(1, scale)
        // Photoshop's "all hues at full saturation", before and after the whole adjustment, Saturation and Lightness too.
        let response = HueSaturationFilter.hueResponse(settings)
        drawStrip(beforeStrip, in: context) { Self.pureHue($0) }
        drawStrip(afterStrip, in: context) { degrees in
            let pure = Self.pureHue(degrees)
            return HueSaturationFilter.adjust(red: pure.red, green: pure.green, blue: pure.blue, settings: settings, response: response)
        }
        context.setStrokeColor(HueBandColor.stripBorder.cgColor(dark: dark))
        context.setLineWidth(1 / scale)
        for strip in [beforeStrip, afterStrip] { context.stroke(strip.insetBy(dx: 0.5 / scale, dy: 0.5 / scale)) }
        let lane = lane
        guard settings.range != .master, !settings.colorize else {
            // Master has no band; the lane stays, so the control keeps its height.
            context.setFillColor(HueBandColor.emptyLane.cgColor(dark: dark))
            context.fill(CGRect(x: 0, y: lane.midY - 1, width: width, height: 2))
            return
        }
        func snapped(_ x: CGFloat) -> CGFloat { (x * scale).rounded() / scale }
        let band = settings.band, inverted = settings.invertRange
        let handles = band.handles
        context.saveGState()
        context.clip(to: lane)
        /// Fills the lane from one hue forward to another.
        func fill(_ from: Double, _ to: Double, _ color: HueBandColor) {
            let start = mapping.x(of: from)
            let end = snapped(start + CGFloat(HueBand.forward(from, to) / 360) * width)
            context.setFillColor(color.cgColor(dark: dark))
            for shift in [-width, 0, width] {
                context.fill(CGRect(x: snapped(start) + shift, y: lane.minY, width: end - snapped(start), height: lane.height))
            }
        }
        // Inverted, the full strength is outside the band, and between the range handles is the gap it leaves out.
        if inverted {
            fill(handles[3], handles[0], .range)
        } else {
            fill(handles[1], handles[2], .range)
        }
        fill(handles[0], handles[1], .falloff)
        fill(handles[2], handles[3], .falloff)
        // The taken handles last, so their stroke is whole where two meet.
        for index in [0, 1, 2, 3].filter({ !active.contains($0) }) + active.filter({ (0..<4).contains($0) }) {
            let path = handlePath(index, at: snapped(mapping.x(of: handles[index])), inverted: inverted)
            let taken = active.contains(index)
            let lineWidth: CGFloat = taken ? 1.5 : 1
            // The shapes' edges are on device pixels, so an outline an odd number of pixels wide, as 1 point is at 1x,
            // would cover half of two; nudged, it covers whole ones.
            let nudge = (lineWidth * scale).truncatingRemainder(dividingBy: 2) / 2 / scale
            for shift in [-width, 0, width] {
                context.saveGState()
                context.translateBy(x: shift + nudge, y: nudge)
                context.addPath(path)
                context.setFillColor(HueBandColor.handleFill.cgColor(dark: dark))
                context.fillPath()
                context.addPath(path)
                context.setStrokeColor(taken ? accent : HueBandColor.handleStroke.cgColor(dark: dark))
                context.setLineWidth(lineWidth)
                context.setLineJoin(.round)
                context.strokePath()
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    /// A capsule centered on `x`, or a triangle standing on the lane's floor with its upright side on `x`.
    private func handlePath(_ index: Int, at x: CGFloat, inverted: Bool) -> CGPath {
        if Self.isCapsule(index, inverted: inverted) {
            let size = metrics.capsule
            let rect = CGRect(x: x - size.width / 2, y: lane.midY - size.height / 2, width: size.width, height: size.height)
            return CGPath(roundedRect: rect, cornerWidth: size.width / 2, cornerHeight: size.width / 2, transform: nil)
        }
        let size = metrics.triangle, floor = lane.maxY - 1
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: floor - size.height))
        path.addLine(to: CGPoint(x: x, y: floor))
        path.addLine(to: CGPoint(x: x + Self.pointing(index, inverted: inverted) * size.width, y: floor))
        path.closeSubpath()
        return path
    }

    /// A strip with a color stop every degree, end to end: smooth at any size and scale.
    private func drawStrip(_ rect: CGRect, in context: CGContext,
                           color: (Double) -> (red: Double, green: Double, blue: Double)) {
        var components: [CGFloat] = [], locations: [CGFloat] = []
        components.reserveCapacity(361 * 4)
        locations.reserveCapacity(361)
        for step in 0...360 {
            let shown = color(HueBand.forward(0, mapping.offset - 180 + Double(step)))
            components += [CGFloat(shown.red), CGFloat(shown.green), CGFloat(shown.blue), 1]
            locations.append(CGFloat(step) / 360)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorSpace: space, colorComponents: components, locations: locations,
                                        count: locations.count) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.midY), end: CGPoint(x: rect.maxX, y: rect.midY),
                                   options: [])
        context.restoreGState()
    }
}

/// A press and drag on the color range control. Every drag applies its whole distance from the press to the band as
/// it was then, so a move a neighbor stopped recovers as the pointer comes back, and nothing drifts. The pointer keeps
/// control past either end, and what it moves comes in at the other.
nonisolated struct HueBandDrag: Equatable, Sendable {
    /// What a press takes: a part of the band, or with Command the strips themselves, to scroll them as Photoshop does.
    enum Grab: Equatable, Sendable {
        case part(HueBand.Part)
        case scroll
    }
    let grab: Grab
    /// The band as the press left it.
    let band: HueBand
    /// The strips' offset at the press.
    let offset: Double
    private let start: CGFloat
    private let mapping: HueBandMapping

    /// A press at `x`. A handle keeps where it was taken rather than jumping there, as a slider's knob does; beyond the
    /// band, though, the nearer of the two handles beside the press comes to it, and the drag goes on from there.
    static func begin(at x: CGFloat, band: HueBand, inverted: Bool, control: HueBandControl, scrolls: Bool = false) -> HueBandDrag {
        let mapping = control.mapping
        if scrolls { return HueBandDrag(grab: .scroll, band: band, offset: mapping.offset, start: x, mapping: mapping) }
        let part = control.part(at: x, of: band, inverted: inverted)
        guard part == .outside else { return HueBandDrag(grab: .part(part), band: band, offset: mapping.offset, start: x, mapping: mapping) }
        let pressed = mapping.degrees(at: x).rounded()
        var brought = whole(band)
        // Only the two handles either side of the empty lane can always move into it; another in the same place, as
        // with no falloff, may be held there by its neighbor.
        let nearest = (inverted ? [1, 2] : [0, 3]).min {
            abs(HueBand.shortest(brought.handles[$0], pressed)) < abs(HueBand.shortest(brought.handles[$1], pressed))
        } ?? 0
        brought.move(.handle(nearest), by: HueBand.shortest(brought.handles[nearest], pressed))
        return HueBandDrag(grab: .part(.handle(nearest)), band: brought, offset: mapping.offset, start: x, mapping: mapping)
    }

    /// The band with the pointer at `x`, on whole degrees as Photoshop keeps it.
    func drag(to x: CGFloat) -> HueBand {
        guard case .part(let part) = grab else { return band }
        let delta = mapping.degrees(spanning: x - start).rounded()
        guard delta != 0 else { return band }
        var moved = Self.whole(band)
        moved.move(part, by: delta)
        return moved
    }

    /// The strips' offset with the pointer at `x`: scrolling, they follow it.
    func offset(at x: CGFloat) -> Double {
        guard grab == .scroll else { return offset }
        return HueBand.forward(0, offset - mapping.degrees(spanning: x - start))
    }

    /// The handles that move, to show which the press took.
    var activeHandles: [Int] {
        switch grab {
        case .scroll, .part(.outside): []
        case .part(.range): [0, 1, 2, 3]
        case .part(.falloff(.leading)): [0, 1]
        case .part(.falloff(.trailing)): [2, 3]
        case .part(.handle(let index)): [index]
        }
    }

    /// The band rounded to whole degrees, unless that would close it up.
    private static func whole(_ band: HueBand) -> HueBand {
        func round(_ degrees: Double) -> Double { HueBand.forward(0, degrees.rounded()) }
        let whole = HueBand(falloffStart: round(band.falloffStart), rangeStart: round(band.rangeStart),
                            rangeEnd: round(band.rangeEnd), falloffEnd: round(band.falloffEnd))
        return HueBand.forward(whole.falloffStart, whole.falloffEnd) > 1 ? whole : band
    }
}
