import AppKit
import CoreImage

nonisolated enum CameraRawUprightMode: String, CaseIterable, Sendable {
    case off = "Off"
    case guided = "Guided"
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
}

nonisolated enum CameraRawProjection: String, CaseIterable, Sendable {
    case perspective = "Perspective"
    case rectilinear = "Rectilinear"
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
}

/// A guide line in normalized image coordinates, 0…1 from the lower-left of the pixel grid.
nonisolated struct CameraRawGeometryGuide: Equatable, Sendable, Codable {
    var startX: Double = 0
    var startY: Double = 0
    var endX: Double = 0
    var endY: Double = 0

    var start: CGPoint { CGPoint(x: startX, y: startY) }
    var end: CGPoint { CGPoint(x: endX, y: endY) }
}

nonisolated struct CameraRawGeometrySettings: Equatable, Sendable {
    var upright: CameraRawUprightMode = .off
    var projection: CameraRawProjection = .perspective
    var vertical: Double = 0
    var horizontal: Double = 0
    var rotate: Double = 0
    var aspect: Double = 0
    var scale: Double = 0
    var offsetX: Double = 0
    var offsetY: Double = 0
    var constrainCrop = false
    var guides: [CameraRawGeometryGuide] = []

    static let toneRange: ClosedRange<Double> = -100...100
    static let rotateRange: ClosedRange<Double> = -45...45

    var adjusts: Bool {
        usesGuides || vertical != 0 || horizontal != 0 || rotate != 0 || aspect != 0 || scale != 0
            || offsetX != 0 || offsetY != 0
    }

    /// Guided only counts once a line is long enough to read. An empty Guided choice must not warp the picture.
    private var usesGuides: Bool {
        upright == .guided && guides.contains { hypot($0.endX - $0.startX, $0.endY - $0.startY) > 0.01 }
    }

    var normalized: Self {
        var result = self
        result.vertical = ImageAdjustmentPixels.clamp(vertical, Self.toneRange, 0)
        result.horizontal = ImageAdjustmentPixels.clamp(horizontal, Self.toneRange, 0)
        result.rotate = ImageAdjustmentPixels.clamp(rotate, Self.rotateRange, 0)
        result.aspect = ImageAdjustmentPixels.clamp(aspect, Self.toneRange, 0)
        result.scale = ImageAdjustmentPixels.clamp(scale, Self.toneRange, 0)
        result.offsetX = ImageAdjustmentPixels.clamp(offsetX, Self.toneRange, 0)
        result.offsetY = ImageAdjustmentPixels.clamp(offsetY, Self.toneRange, 0)
        result.guides = guides.filter { guide in
            hypot(guide.endX - guide.startX, guide.endY - guide.startY) > 0.01
        }
        return result
    }

    func applying(shows: Bool) -> Self { shows ? self : Self() }

    /// Perspective and affine geometry on the pixel grid. Output matches the input size unless Constrain Crop trims empty edges.
    func apply(_ image: CGImage) throws -> CGImage {
        let settings = normalized
        guard settings.adjusts else { return image }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return image }
        let (vertical, horizontal, rotate) = settings.effectiveCorrections()
        let corners = settings.outputCorners(width: width, height: height, vertical: vertical, horizontal: horizontal, rotation: rotate)
        func vector(_ point: CGPoint) -> CIVector { CIVector(x: point.x, y: point.y) }
        let warped = CIImage(cgImage: image).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": vector(corners[0]),
            "inputTopRight": vector(corners[1]),
            "inputBottomRight": vector(corners[2]),
            "inputBottomLeft": vector(corners[3]),
        ])
        var result = try PixelAdjust.render(warped, width: width, height: height, isMask: false)
        guard settings.constrainCrop else { return result }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(result, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { return result }
        var edges = [Int](repeating: 0, count: 4)
        brush_alpha_bounds(data.assumingMemoryBound(to: UInt8.self), width, height, context.bytesPerRow, &edges)
        let crop = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
        guard crop.width >= 1, crop.height >= 1, crop.width < CGFloat(width) || crop.height < CGFloat(height),
              let cropped = result.cropping(to: crop) else { return result }
        let fitted = try BrushRaster.context(width: width, height: height, mask: false)
        let scale = min(CGFloat(width) / crop.width, CGFloat(height) / crop.height)
        let draw = CGRect(x: (CGFloat(width) - crop.width * scale) / 2, y: (CGFloat(height) - crop.height * scale) / 2,
                          width: crop.width * scale, height: crop.height * scale)
        BrushRaster.draw(cropped, in: draw, mask: false, context: fitted)
        guard let fittedImage = fitted.makeImage() else { return result }
        return fittedImage
    }

    private func effectiveCorrections() -> (vertical: Double, horizontal: Double, rotate: Double) {
        switch upright {
        case .off:
            return (vertical, horizontal, rotate)
        case .guided:
            let guided = Self.guidedCorrections(guides: guides)
            return (vertical + guided.vertical, horizontal + guided.horizontal, rotate + guided.rotate)
        }
    }

    private static func guidedCorrections(guides: [CameraRawGeometryGuide]) -> (vertical: Double, horizontal: Double, rotate: Double) {
        guard let first = guides.first else { return (0, 0, 0) }
        let dx = first.endX - first.startX, dy = first.endY - first.startY
        let length = hypot(dx, dy)
        guard length > 1e-4 else { return (0, 0, 0) }
        let angle = atan2(dy, dx) * 180 / .pi
        var rotate = -angle
        if rotate > 45 { rotate -= 90 } else if rotate < -45 { rotate += 90 }
        var vertical = 0.0, horizontal = 0.0
        if guides.count > 1 {
            let second = guides[1]
            let sx = second.endX - second.startX, sy = second.endY - second.startY
            let sl = hypot(sx, sy)
            if sl > 1e-4 {
                let a2 = atan2(sy, sx) * 180 / .pi
                vertical = abs(a2) > 45 ? (a2 > 0 ? 25 : -25) : 0
                horizontal = abs(a2) <= 45 ? (a2 > 0 ? 25 : -25) : 0
            }
        }
        return (vertical, horizontal, rotate)
    }

    /// Core Image corner positions with y measured upward from the bottom.
    private func outputCorners(width: Int, height: Int, vertical: Double, horizontal: Double, rotation: Double) -> [CGPoint] {
        let w = Double(width), h = Double(height)
        let strength = projection == .perspective ? 1.0 : 0.55
        let v = vertical / 100 * w * 0.18 * strength
        let hz = horizontal / 100 * h * 0.18 * strength
        let aspectScale = 1 + aspect / 200
        let zoom = 1 + scale / 100
        let shiftX = offsetX / 100 * w * 0.15
        let shiftY = offsetY / 100 * h * 0.15
        var topLeft = CGPoint(x: -v + shiftX, y: h + shiftY)
        var topRight = CGPoint(x: w + v + shiftX, y: h + shiftY)
        var bottomRight = CGPoint(x: w + hz + shiftX, y: -shiftY)
        var bottomLeft = CGPoint(x: -hz + shiftX, y: -shiftY)
        let center = CGPoint(x: w / 2 + shiftX, y: h / 2 + shiftY)
        let radians = rotation * .pi / 180
        func rotated(_ point: CGPoint) -> CGPoint {
            let dx = point.x - center.x, dy = point.y - center.y
            let cosine = cos(radians), sine = sin(radians)
            return CGPoint(x: center.x + dx * cosine - dy * sine, y: center.y + dx * sine + dy * cosine)
        }
        topLeft = rotated(topLeft); topRight = rotated(topRight)
        bottomRight = rotated(bottomRight); bottomLeft = rotated(bottomLeft)
        if aspectScale != 1 {
            func scaled(_ point: CGPoint) -> CGPoint {
                CGPoint(x: center.x + (point.x - center.x) * aspectScale, y: center.y + (point.y - center.y) / aspectScale)
            }
            topLeft = scaled(topLeft); topRight = scaled(topRight)
            bottomRight = scaled(bottomRight); bottomLeft = scaled(bottomLeft)
        }
        if zoom != 1 {
            func zoomPoint(_ point: CGPoint) -> CGPoint {
                CGPoint(x: center.x + (point.x - center.x) * zoom, y: center.y + (point.y - center.y) * zoom)
            }
            topLeft = zoomPoint(topLeft); topRight = zoomPoint(topRight)
            bottomRight = zoomPoint(bottomRight); bottomLeft = zoomPoint(bottomLeft)
        }
        return [topLeft, topRight, bottomRight, bottomLeft]
    }
}

nonisolated enum CameraRawProcessVersion: String, CaseIterable, Sendable {
    case version1 = "Version 1"
    case version2 = "Version 2"
    case version3 = "Version 3"
    case version4 = "Version 4"
    case version5 = "Version 5"
    case version6 = "Version 6"
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
    var kernelValue: Int32 {
        switch self {
        case .version1: return 1
        case .version2: return 2
        case .version3: return 3
        case .version4: return 4
        case .version5: return 5
        case .version6: return 6
        }
    }

    /// What this process does to the calibration sliders on an already-rendered layer.
    var summary: String {
        switch self {
        case .version1:
            return "Earliest response. Hue, saturation, and shadow tint move about half as far as Version 6."
        case .version2:
            return "A little stronger than Version 1. The sliders below still fall well short of the current look."
        case .version3:
            return "Firmer color than Version 2. Primary shifts stay gentler than the current process."
        case .version4:
            return "The 2012 response. Calibration reaches most of the strength used by Version 6."
        case .version5:
            return "Close to the current process, with slightly softer primary and shadow shifts."
        case .version6:
            return "Current default. The calibration sliders below apply at full strength."
        }
    }
}

nonisolated struct CameraRawCalibrationSettings: Equatable, Sendable {
    var process: CameraRawProcessVersion = .version6
    var shadowTint: Double = 0
    var redHue: Double = 0
    var redSaturation: Double = 0
    var greenHue: Double = 0
    var greenSaturation: Double = 0
    var blueHue: Double = 0
    var blueSaturation: Double = 0

    static let toneRange: ClosedRange<Double> = -100...100

    var adjusts: Bool {
        shadowTint != 0 || redHue != 0 || redSaturation != 0 || greenHue != 0 || greenSaturation != 0
            || blueHue != 0 || blueSaturation != 0
    }

    var normalized: Self {
        var result = self
        result.shadowTint = ImageAdjustmentPixels.clamp(shadowTint, Self.toneRange, 0)
        result.redHue = ImageAdjustmentPixels.clamp(redHue, Self.toneRange, 0)
        result.redSaturation = ImageAdjustmentPixels.clamp(redSaturation, Self.toneRange, 0)
        result.greenHue = ImageAdjustmentPixels.clamp(greenHue, Self.toneRange, 0)
        result.greenSaturation = ImageAdjustmentPixels.clamp(greenSaturation, Self.toneRange, 0)
        result.blueHue = ImageAdjustmentPixels.clamp(blueHue, Self.toneRange, 0)
        result.blueSaturation = ImageAdjustmentPixels.clamp(blueSaturation, Self.toneRange, 0)
        return result
    }

    func applying(shows: Bool) -> Self { shows ? self : Self() }
}

extension CameraRawSettings {
    func applyCalibration(pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int) {
        let calibration = calibration.normalized
        guard calibration.adjusts else { return }
        adjust_camera_raw_calibration(pixels, width, height, stride,
                                      calibration.shadowTint,
                                      calibration.redHue, calibration.redSaturation,
                                      calibration.greenHue, calibration.greenSaturation,
                                      calibration.blueHue, calibration.blueSaturation,
                                      calibration.process.kernelValue)
    }
}
