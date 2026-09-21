import CoreGraphics
import Foundation

/// Rasterizes Photoshop vector masks (`vmsk`/`vsms`) and maps fill rectangles/ellipses
/// onto live shape layers, from Adobe’s 2019 Photoshop File Formats Specification
/// (additional layer information: `vmsk`, `vogk`, `SoCo`, `vstk`).
nonisolated enum PSDVector {
    struct Raster {
        var image: CGImage
        var bounds: CGRect
    }

    struct Live {
        var style: LayerShapeStyle
        var bounds: CGRect
        var image: CGImage
        var notes: [String]
    }

    static func live(extra: [String: Data], canvas: CGSize, remainingPixels: Int = 100_000_000) throws -> Live? {
        let stroke = extra["vstk"]
        let fillEnabled = stroke.flatMap { bool($0, key: "fillEnabled") } ?? (extra["SoCo"] != nil)
        let strokeEnabled = stroke.flatMap { bool($0, key: "strokeEnabled") } ?? false
        guard fillEnabled, let fill = extra["SoCo"].flatMap(rgb) else { return nil }
        guard let origin = origination(extra["vogk"]) ?? sharpRect(from: extra["vmsk"] ?? extra["vsms"], canvas: canvas) else {
            return nil
        }
        var box = origin.bounds.integral
        guard box.origin.x.isFinite, box.origin.y.isFinite else { return nil }
        guard let size = try pixelSize(box.size, remainingPixels: remainingPixels) else { return nil }
        box.size = CGSize(width: size.width, height: size.height)
        let style = LayerShapeStyle(kind: origin.kind, red: fill.r, green: fill.g, blue: fill.b, cornerRadius: origin.cornerRadius)
        let image = try EditorSession.shapeImage(style.kind, size: box.size, color: style.color, cornerRadius: style.cornerRadius)
        var notes: [String] = []
        if strokeEnabled {
            notes.append("The Photoshop stroke isn’t supported on shape layers and was omitted.")
        }
        notes.append(contentsOf: origin.notes)
        return Live(style: style, bounds: box, image: image, notes: notes)
    }

    static func raster(extra: [String: Data], canvas: CGSize, remainingPixels: Int = 100_000_000) throws -> Raster? {
        guard let mask = extra["vmsk"] ?? extra["vsms"],
              let path = path(from: mask, canvas: canvas) else { return nil }
        let fill = extra["SoCo"].flatMap(rgb)
        let stroke = extra["vstk"]
        let fillEnabled = stroke.flatMap { bool($0, key: "fillEnabled") } ?? (fill != nil)
        let strokeEnabled = stroke.flatMap { bool($0, key: "strokeEnabled") } ?? false
        let strokeColor = stroke.flatMap(rgb)
        let strokeWidth = stroke.flatMap { unit($0, key: "strokeStyleLineWidth") } ?? 1
        guard fillEnabled && fill != nil || strokeEnabled && strokeColor != nil else { return nil }
        guard CGFloat(strokeWidth).isFinite else { return nil }
        if strokeEnabled {
            guard (0...30_000).contains(strokeWidth) else { throw ImageImportError.tooLarge }
        }
        var box = path.boundingBoxOfPath
        if strokeEnabled { box = box.insetBy(dx: -ceil(strokeWidth / 2 + 1), dy: -ceil(strokeWidth / 2 + 1)) }
        box = box.integral
        guard box.origin.x.isFinite, box.origin.y.isFinite else { return nil }
        guard let size = try pixelSize(box.size, remainingPixels: remainingPixels) else { return nil }
        let width = size.width, height = size.height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.setShouldAntialias(true)
        context.addPath(path)
        if fillEnabled, let fill {
            context.setFillColor(CGColor(red: fill.r, green: fill.g, blue: fill.b, alpha: 1))
            if strokeEnabled, strokeColor != nil { context.fillPath(using: .winding) }
            else { context.drawPath(using: .fill) }
        }
        if strokeEnabled, let strokeColor {
            if fillEnabled { context.addPath(path) }
            context.setStrokeColor(CGColor(red: strokeColor.r, green: strokeColor.g, blue: strokeColor.b, alpha: 1))
            context.setLineWidth(strokeWidth)
            context.setLineJoin(.miter)
            context.setMiterLimit(10)
            context.setLineCap(.butt)
            context.drawPath(using: .stroke)
        }
        guard let image = context.makeImage() else { return nil }
        return Raster(image: image, bounds: CGRect(x: box.minX, y: box.minY, width: CGFloat(width), height: CGFloat(height)))
    }

    /// Rejects sizes that would trap on `Int(...)` or exceed the 30,000 px / remaining-pixel budget.
    private static func pixelSize(_ size: CGSize, remainingPixels: Int) throws -> (width: Int, height: Int)? {
        guard size.width.isFinite, size.height.isFinite else { return nil }
        let maxDimension: CGFloat = 30_000
        guard abs(size.width) <= maxDimension, abs(size.height) <= maxDimension else {
            throw ImageImportError.tooLarge
        }
        let budget = min(EditorSession.maxShapePixels, max(0, remainingPixels))
        guard size.width * size.height <= CGFloat(budget) else { throw ImageImportError.tooLarge }
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        guard width * height <= budget else { throw ImageImportError.tooLarge }
        return (width, height)
    }

    private struct Origination {
        var kind: ShapeKind
        var bounds: CGRect
        var cornerRadius: CGFloat = 0
        var notes: [String] = []
    }

    /// Photoshop `vogk` origination: 1/2 = rectangle (2 is rounded), 5 = ellipse.
    private static func origination(_ data: Data?) -> Origination? {
        guard let data, let type = int32(data, key: "keyOriginType") else { return nil }
        let kind: ShapeKind
        switch type {
        case 1, 2: kind = .rectangle
        case 5: kind = .ellipse
        default: return nil
        }
        let from = offset(of: "keyOriginShapeBBox", in: data) ?? 0
        guard let left = unit(data, key: "Left", from: from),
              let top = unit(data, key: "Top ", from: from),
              let right = unit(data, key: "Rght", from: from),
              let bottom = unit(data, key: "Btom", from: from) else { return nil }
        let bounds = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard bounds.width >= 1, bounds.height >= 1,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.size.width.isFinite, bounds.size.height.isFinite else { return nil }
        var origin = Origination(kind: kind, bounds: bounds)
        if kind == .rectangle, let radiiAt = offset(of: "keyOriginRRectRadii", in: data) {
            let keys = ["topLeft", "topRight", "bottomRight", "bottomLeft"]
            let radii = keys.compactMap { unit(data, key: $0, from: radiiAt) }
            if radii.count == 4 {
                let lo = radii.min() ?? 0, hi = radii.max() ?? 0
                if hi - lo > 0.5 { return nil }
                origin.cornerRadius = CGFloat(hi)
            }
        }
        return origin
    }

    private static func sharpRect(from data: Data?, canvas: CGSize) -> Origination? {
        guard let data, let path = path(from: data, canvas: canvas) else { return nil }
        var offset = 8
        var remaining = 0
        var anchors: [CGPoint] = []
        var sharp = true
        while offset + 26 <= data.count {
            let type = Int(i16(data, offset))
            let body = data.subdata(in: offset + 2 ..< offset + 26)
            offset += 26
            switch type {
            case 0, 3:
                if !anchors.isEmpty { return nil }
                remaining = Int(i16(body, 0))
            case 1, 2, 4, 5:
                guard remaining > 0, body.count >= 24 else { continue }
                remaining -= 1
                let incoming = point(body, 0, canvas: canvas)
                let anchor = point(body, 8, canvas: canvas)
                let outgoing = point(body, 16, canvas: canvas)
                if hypot(incoming.x - anchor.x, incoming.y - anchor.y) > 0.5
                    || hypot(outgoing.x - anchor.x, outgoing.y - anchor.y) > 0.5 {
                    sharp = false
                }
                anchors.append(anchor)
            default:
                continue
            }
        }
        guard sharp, anchors.count == 4 else { return nil }
        let box = path.boundingBoxOfPath
        guard box.width >= 1, box.height >= 1 else { return nil }
        return Origination(kind: .rectangle, bounds: box)
    }

    static func path(from data: Data, canvas: CGSize) -> CGPath? {
        guard data.count >= 8, canvas.width > 0, canvas.height > 0 else { return nil }
        let path = CGMutablePath()
        var offset = 8
        var remaining = 0
        var closed = true
        var first = true
        var previousOut = CGPoint.zero
        while offset + 26 <= data.count {
            let type = Int(i16(data, offset))
            let body = data.subdata(in: offset + 2 ..< offset + 26)
            offset += 26
            switch type {
            case 0, 3:
                if !first, closed { path.closeSubpath() }
                remaining = Int(i16(body, 0))
                closed = type == 0
                first = true
            case 1, 2, 4, 5:
                guard remaining > 0, body.count >= 24 else { continue }
                remaining -= 1
                let incoming = point(body, 0, canvas: canvas)
                let anchor = point(body, 8, canvas: canvas)
                let outgoing = point(body, 16, canvas: canvas)
                if first {
                    path.move(to: anchor)
                    first = false
                } else {
                    path.addCurve(to: anchor, control1: previousOut, control2: incoming)
                }
                previousOut = outgoing
            default:
                continue
            }
        }
        if !first, closed { path.closeSubpath() }
        return path.isEmpty ? nil : path
    }

    static func rgb(_ data: Data) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let r = double(data, key: "Rd  "), let g = double(data, key: "Grn "), let b = double(data, key: "Bl  ") else { return nil }
        func channel(_ value: Double) -> CGFloat { CGFloat(value > 1 ? min(255, max(0, value)) / 255 : min(1, max(0, value))) }
        return (channel(r), channel(g), channel(b))
    }

    static func bool(_ data: Data, key: String) -> Bool? {
        guard let start = offset(of: key, in: data) else { return nil }
        let type = start + key.utf8.count
        guard type + 5 <= data.count, ascii(data, type, 4) == "bool" else { return nil }
        return data[type + 4] != 0
    }

    static func unit(_ data: Data, key: String, from start: Int = 0) -> Double? {
        guard let keyAt = offset(of: key, in: data, from: start),
              let unit = offset(of: "UntF", in: data, from: keyAt) else { return nil }
        return double(at: unit + 8, in: data)
    }

    private static func int32(_ data: Data, key: String) -> Int32? {
        guard let start = offset(of: key, in: data) else { return nil }
        let type = start + key.utf8.count
        guard type + 8 <= data.count, ascii(data, type, 4) == "long" else { return nil }
        return i32(data, type + 4)
    }

    private static func point(_ bytes: Data, _ at: Int, canvas: CGSize) -> CGPoint {
        let y = Double(i32(bytes, at)) / 0x1000000
        let x = Double(i32(bytes, at + 4)) / 0x1000000
        return CGPoint(x: x * canvas.width, y: y * canvas.height)
    }

    private static func i32(_ bytes: Data, _ at: Int) -> Int32 {
        var value: Int32 = 0
        _ = withUnsafeMutableBytes(of: &value) { bytes.copyBytes(to: $0, from: at ..< at + 4) }
        return Int32(bigEndian: value)
    }

    private static func i16(_ bytes: Data, _ at: Int) -> Int16 {
        var value: Int16 = 0
        _ = withUnsafeMutableBytes(of: &value) { bytes.copyBytes(to: $0, from: at ..< at + 2) }
        return Int16(bigEndian: value)
    }

    private static func double(_ data: Data, key: String) -> Double? {
        guard let start = offset(of: key, in: data) else { return nil }
        let type = start + key.utf8.count
        guard type + 12 <= data.count, ascii(data, type, 4) == "doub" else { return nil }
        return double(at: type + 4, in: data)
    }

    private static func double(at offset: Int, in data: Data) -> Double? {
        guard offset + 8 <= data.count else { return nil }
        return Double(bitPattern: u64(data, offset))
    }

    private static func offset(of key: String, in data: Data, from start: Int = 0) -> Int? {
        let needle = Data(key.utf8)
        guard start < data.count, let range = data.range(of: needle, in: start ..< data.count) else { return nil }
        return range.lowerBound
    }

    private static func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
        String(bytes: data[offset ..< offset + count], encoding: .ascii) ?? ""
    }

    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset ..< offset + 8) }
        return UInt64(bigEndian: value)
    }
}
