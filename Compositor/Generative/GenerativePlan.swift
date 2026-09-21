import CoreGraphics
import Foundation

/// An output shape the image models accept. They take a named ratio, never pixel dimensions.
nonisolated struct GenerativeAspectRatio: Equatable, Sendable {
    let width: Int
    let height: Int
    var label: String { "\(width):\(height)" }
    var value: CGFloat { CGFloat(width) / CGFloat(height) }

    /// The ratios every supported model accepts.
    static let standard: [GenerativeAspectRatio] = [
        .init(width: 1, height: 1), .init(width: 2, height: 3), .init(width: 3, height: 2),
        .init(width: 3, height: 4), .init(width: 4, height: 3), .init(width: 4, height: 5),
        .init(width: 5, height: 4), .init(width: 9, height: 16), .init(width: 16, height: 9),
        .init(width: 21, height: 9)]

    static func nearest(to aspect: CGFloat, in ratios: [GenerativeAspectRatio] = standard) -> GenerativeAspectRatio {
        ratios.min { abs(log(aspect / $0.value)) < abs(log(aspect / $1.value)) } ?? ratios[0]
    }
}

/// The output resolutions the image models offer, named as the API names them.
nonisolated enum GenerativeSize: String, CaseIterable, Comparable, Sendable {
    case k1 = "1K", k2 = "2K", k4 = "4K"
    var longEdge: CGFloat { self == .k1 ? 1024 : self == .k2 ? 2048 : 4096 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.longEdge < rhs.longEdge }
}

/// Which part of the document goes to the model, and at what size. The models have no mask input and
/// repaint whatever they are sent, so the plan sends the target with enough of its surroundings to match,
/// in a shape the model accepts, and the app keeps only the target from what comes back.
nonisolated struct GenerativePlan: Equatable, Sendable {
    /// Document pixels sent to the model. Whole pixels, in the shape of `ratio`. It reaches past `bounds`
    /// only where the canvas ran out; nothing is drawn there.
    let region: CGRect
    let ratio: GenerativeAspectRatio
    let size: GenerativeSize
    /// Pixel size of the image sent. Never larger than `region`: the model gains nothing from an upscale.
    let sendSize: CGSize

    /// Generated pixels per document pixel. Below 1, the result is enlarged to fit and looks softer.
    var detail: CGFloat { min(1, size.longEdge / max(region.width, region.height)) }

    /// - Parameters:
    ///   - target: bounds of what is to change, in document pixels.
    ///   - bounds: where real pixels may be sampled: the canvas, or for Expand the enlarged canvas.
    ///   - largest: the biggest output the model (or the user) allows.
    ///   - fixed: a size the user picked; nil picks the smallest that holds the region's detail.
    static func make(target: CGRect, bounds: CGRect, largest: GenerativeSize = .k4, fixed: GenerativeSize? = nil) -> GenerativePlan? {
        let target = target.integral.intersection(bounds)
        guard !target.isNull, target.width >= 1, target.height >= 1 else { return nil }
        // Context on every side: the model needs surroundings to match light, grain and perspective.
        let pad = max(128, (max(target.width, target.height) / 2).rounded())
        let padded = target.insetBy(dx: -pad, dy: -pad).intersection(bounds)
        let ratio = GenerativeAspectRatio.nearest(to: padded.width / padded.height)
        // Grow, never shrink, to the ratio, so the target and its context always stay inside.
        var width = padded.width, height = padded.height
        if width / height < ratio.value { width = (height * ratio.value).rounded(.up) }
        else { height = (width / ratio.value).rounded(.up) }
        let region = CGRect(x: origin(padded.minX, padded.width, width, bounds.minX, bounds.width),
                            y: origin(padded.minY, padded.height, height, bounds.minY, bounds.height),
                            width: width, height: height)
        let long = max(width, height)
        let wanted: GenerativeSize = long <= 1280 ? .k1 : long <= 2560 ? .k2 : .k4
        let size = min(fixed ?? wanted, largest)
        let scale = min(1, size.longEdge / long)
        return GenerativePlan(region: region, ratio: ratio, size: size,
                              sendSize: CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded())))
    }

    /// Grows `[start, start + length]` to `grown` about its middle, slid back inside the bounds where it
    /// fits and centred on them where it does not.
    private static func origin(_ start: CGFloat, _ length: CGFloat, _ grown: CGFloat, _ boundsStart: CGFloat, _ boundsLength: CGFloat) -> CGFloat {
        guard grown <= boundsLength else { return (boundsStart + (boundsLength - grown) / 2).rounded(.down) }
        let centred = (start - (grown - length) / 2).rounded(.down)
        return min(max(centred, boundsStart), boundsStart + boundsLength - grown)
    }

    /// The part of a returned image that stands for `region`. The models sometimes answer in another shape
    /// than asked; then the middle of the answer, in the region's shape, is the best match.
    func source(in returned: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: returned)
        guard returned.width >= 1, returned.height >= 1 else { return full }
        let asked = region.width / region.height, got = returned.width / returned.height
        guard abs(log(got / asked)) > 0.03 else { return full }
        let size = got > asked ? CGSize(width: returned.height * asked, height: returned.height)
                               : CGSize(width: returned.width, height: returned.width / asked)
        return CGRect(x: (returned.width - size.width) / 2, y: (returned.height - size.height) / 2, width: size.width, height: size.height)
    }
}
