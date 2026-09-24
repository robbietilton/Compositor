import CoreGraphics
import Foundation

/// Centralized validation constants for vector document data.
nonisolated enum VectorLimits {
    public static let maxTotalAnchors = 50_000
    public static let maxSubpaths = 1_000
    public static let maxAnchorsPerSubpath = 10_000
    public static let maxCoordinateMagnitude: CGFloat = 1_000_000
    public static let minStrokeWidth: CGFloat = 0.01
    public static let maxStrokeWidth: CGFloat = 1_000
    public static let minMiterLimit: CGFloat = 1
    public static let maxMiterLimit: CGFloat = 100
}

nonisolated enum VectorLineCap: String, Codable, CaseIterable, Sendable {
    case butt = "Butt"
    case round = "Round"
    case square = "Square"

    public var cgCap: CGLineCap {
        switch self {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
    }
}

nonisolated enum VectorLineJoin: String, Codable, CaseIterable, Sendable {
    case miter = "Miter"
    case round = "Round"
    case bevel = "Bevel"

    public var cgJoin: CGLineJoin {
        switch self {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }
}

nonisolated enum VectorFillRule: String, Codable, CaseIterable, Sendable {
    case nonZero = "NonZero"
    case evenOdd = "EvenOdd"

    public var cgFillRule: CGPathFillRule {
        switch self {
        case .nonZero: return .winding
        case .evenOdd: return .evenOdd
        }
    }
}

/// An anchor point with optional cubic Bézier incoming/outgoing control handles.
/// Coordinates are in layer-local space.
nonisolated struct VectorPoint: Codable, Equatable, Sendable {
    public var anchor: CGPoint
    public var previousControl: CGPoint? = nil
    public var nextControl: CGPoint? = nil

    public init(anchor: CGPoint, previousControl: CGPoint? = nil, nextControl: CGPoint? = nil) {
        self.anchor = anchor
        self.previousControl = previousControl
        self.nextControl = nextControl
    }

    public var isValid: Bool {
        anchor.x.isFinite && anchor.y.isFinite &&
        abs(anchor.x) <= VectorLimits.maxCoordinateMagnitude &&
        abs(anchor.y) <= VectorLimits.maxCoordinateMagnitude &&
        (previousControl.map {
            $0.x.isFinite && $0.y.isFinite &&
            abs($0.x) <= VectorLimits.maxCoordinateMagnitude &&
            abs($0.y) <= VectorLimits.maxCoordinateMagnitude
        } ?? true) &&
        (nextControl.map {
            $0.x.isFinite && $0.y.isFinite &&
            abs($0.x) <= VectorLimits.maxCoordinateMagnitude &&
            abs($0.y) <= VectorLimits.maxCoordinateMagnitude
        } ?? true)
    }
}

/// An open or closed sequence of vector points.
nonisolated struct VectorSubpath: Codable, Equatable, Sendable {
    public var points: [VectorPoint] = []
    public var isClosed: Bool = false

    public init(points: [VectorPoint] = [], isClosed: Bool = false) {
        self.points = points
        self.isClosed = isClosed
    }

    public var isValid: Bool {
        points.count <= VectorLimits.maxAnchorsPerSubpath &&
        points.allSatisfy(\.isValid)
    }
}

/// Fill style configuration for a vector layer.
nonisolated struct VectorFillStyle: Codable, Equatable, Sendable {
    public var color: PaletteColor
    public var fillRule: VectorFillRule = .nonZero
    public var isEnabled: Bool = true

    public init(color: PaletteColor, fillRule: VectorFillRule = .nonZero, isEnabled: Bool = true) {
        self.color = color
        self.fillRule = fillRule
        self.isEnabled = isEnabled
    }
}

/// Stroke style configuration for a vector layer.
nonisolated struct VectorStrokeStyle: Codable, Equatable, Sendable {
    public var color: PaletteColor
    public var width: CGFloat = 1
    public var lineCap: VectorLineCap = .round
    public var lineJoin: VectorLineJoin = .round
    public var miterLimit: CGFloat = 10
    public var isEnabled: Bool = true

    public init(color: PaletteColor, width: CGFloat = 1, lineCap: VectorLineCap = .round,
                lineJoin: VectorLineJoin = .round, miterLimit: CGFloat = 10, isEnabled: Bool = true) {
        self.color = color
        self.width = width
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.miterLimit = miterLimit
        self.isEnabled = isEnabled
    }

    public var isValid: Bool {
        width.isFinite && (VectorLimits.minStrokeWidth...VectorLimits.maxStrokeWidth).contains(width) &&
        miterLimit.isFinite && (VectorLimits.minMiterLimit...VectorLimits.maxMiterLimit).contains(miterLimit)
    }
}

/// Canonical editable vector document model. Contains no reference types or cached CGImages.
nonisolated struct VectorModel: Codable, Equatable, Sendable {
    public var subpaths: [VectorSubpath] = []
    public var fill: VectorFillStyle? = nil
    public var stroke: VectorStrokeStyle? = nil

    public init(subpaths: [VectorSubpath] = [], fill: VectorFillStyle? = nil, stroke: VectorStrokeStyle? = nil) {
        self.subpaths = subpaths
        self.fill = fill
        self.stroke = stroke
    }

    public var totalAnchorCount: Int {
        subpaths.reduce(0) { $0 + $1.points.count }
    }

    public var isValid: Bool {
        subpaths.count <= VectorLimits.maxSubpaths &&
        totalAnchorCount <= VectorLimits.maxTotalAnchors &&
        subpaths.allSatisfy(\.isValid) &&
        (stroke?.isValid ?? true)
    }
}

/// Deterministic bridge translating the canonical VectorModel into a native CGPath.
nonisolated enum VectorBridge {
    public static func cgPath(from model: VectorModel) -> CGPath {
        guard model.isValid else { return CGPath(rect: .zero, transform: nil) }
        let path = CGMutablePath()

        for subpath in model.subpaths {
            guard !subpath.points.isEmpty else { continue }
            let points = subpath.points
            path.move(to: points[0].anchor)

            guard points.count >= 2 else { continue }

            for i in 0 ..< points.count - 1 {
                appendSegment(from: points[i], to: points[i + 1], into: path)
            }

            if subpath.isClosed {
                appendSegment(from: points[points.count - 1], to: points[0], into: path)
                path.closeSubpath()
            }
        }

        return path
    }

    private static func appendSegment(from a: VectorPoint, to b: VectorPoint, into path: CGMutablePath) {
        if a.nextControl == nil && b.previousControl == nil {
            path.addLine(to: b.anchor)
        } else {
            let control1 = a.nextControl ?? a.anchor
            let control2 = b.previousControl ?? b.anchor
            path.addCurve(to: b.anchor, control1: control1, control2: control2)
        }
    }
}

/// Minimal Core Graphics renderer for VectorModel, generating derived raster images for layer compositing.
nonisolated enum VectorRenderer {
    public static func render(_ model: VectorModel, in size: CGSize) throws -> CGImage {
        guard size.width >= 1, size.height >= 1, size.width.isFinite, size.height.isFinite else {
            throw ExportError.render
        }
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard width * height <= EditorSession.maxShapePixels else {
            throw ProjectError.tooLarge
        }

        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setShouldAntialias(true)

        // 1. Fill closed subpaths if fill is enabled
        if let fill = model.fill, fill.isEnabled {
            let closedSubpaths = model.subpaths.filter(\.isClosed)
            if !closedSubpaths.isEmpty {
                let fillModel = VectorModel(subpaths: closedSubpaths, fill: fill, stroke: nil)
                let fillPath = VectorBridge.cgPath(from: fillModel)
                context.saveGState()
                context.setFillColor(fill.color.cgColor)
                context.addPath(fillPath)
                context.fillPath(using: fill.fillRule.cgFillRule)
                context.restoreGState()
            }
        }

        // 2. Stroke all subpaths if stroke is enabled
        if let stroke = model.stroke, stroke.isEnabled {
            let fullPath = VectorBridge.cgPath(from: model)
            strokePath(
                fullPath,
                width: stroke.width,
                lineCap: stroke.lineCap.cgCap,
                lineJoin: stroke.lineJoin.cgJoin,
                miterLimit: stroke.miterLimit,
                color: stroke.color.cgColor,
                in: context
            )
        }

        guard let image = context.makeImage() else {
            throw ExportError.render
        }
        return image
    }

    /// Canonical stroke renderer matching vector geometry semantics.
    public static func strokePath(
        _ path: CGPath,
        width: CGFloat,
        lineCap: CGLineCap,
        lineJoin: CGLineJoin,
        miterLimit: CGFloat,
        color: CGColor,
        in context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(max(1.0, width))
        context.setLineCap(lineCap)
        context.setLineJoin(lineJoin)
        context.setMiterLimit(miterLimit)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}
