import CoreGraphics
import Foundation

/// A user-placed alignment line. Horizontal guides sit at a document Y; vertical at a document X.
nonisolated struct CanvasGuide: Codable, Equatable, Sendable, Hashable {
    enum Axis: String, Codable, Sendable { case horizontal, vertical }
    var id: UUID
    var axis: Axis
    /// Document pixels: Y for a horizontal guide, X for a vertical one.
    var position: Double

    func offset(x: CGFloat, y: CGFloat) -> CanvasGuide {
        var guide = self
        guide.position += Double(axis == .vertical ? x : y)
        return guide
    }

    func scaled(x: CGFloat, y: CGFloat) -> CanvasGuide {
        var guide = self
        guide.position *= Double(axis == .vertical ? x : y)
        return guide
    }

    /// Mirrors this guide when it runs perpendicular to the flip, so it stays on the same content.
    func mirrored(horizontally: Bool, across center: CGFloat) -> CanvasGuide {
        var guide = self
        if (horizontally && axis == .vertical) || (!horizontally && axis == .horizontal) {
            guide.position = Double(2 * center) - guide.position
        }
        return guide
    }
}

/// Non-printing layout grid: a major line every `spacing` px, split into `subdivisions`
/// (64 px and eight, every 8 px, until changed in View > Grid Settings…).
struct LayoutGrid: Equatable {
    static let spacingRange = 2...4096
    static let subdivisionRange = 1...64

    /// Pixels between major lines.
    let spacing: Int
    /// Parts each major square is split into; never finer than a pixel.
    let subdivisions: Int
    var step: CGFloat { CGFloat(spacing) / CGFloat(subdivisions) }

    init(spacing: Int = 64, subdivisions: Int = 8) {
        self.spacing = min(max(spacing, Self.spacingRange.lowerBound), Self.spacingRange.upperBound)
        self.subdivisions = min(max(subdivisions, Self.subdivisionRange.lowerBound), Self.subdivisionRange.upperBound, self.spacing)
    }

    /// Every grid line along a document edge, including subdivisions, in whole pixels.
    /// Counted from the origin rather than added up, so an uneven step doesn't drift off the majors.
    func lines(along length: CGFloat) -> [CGFloat] {
        guard length >= 0 else { return [0] }
        let count = Int((length / step + 0.001).rounded(.down))
        return (0...count).map { (CGFloat($0) * step).rounded() }
    }

    func isMajor(_ value: CGFloat) -> Bool {
        abs(value.rounded().truncatingRemainder(dividingBy: CGFloat(spacing))) < 0.001
    }
}

/// How the layout grid is drawn (View > Grid Settings…), after Photoshop's Guides, Grid & Slices settings.
/// Lines are drawn at the chosen opacity; subdivisions are dotted and fainter still.
struct GridAppearance: Equatable {
    enum Preset: String, CaseIterable, Identifiable {
        case lightGray = "Light Gray", lightBlue = "Light Blue", lightRed = "Light Red", green = "Green",
             mediumBlue = "Medium Blue", yellow = "Yellow", magenta = "Magenta", cyan = "Cyan", black = "Black",
             custom = "Custom"
        var id: Self { self }

        /// Nil for Custom, which uses the appearance's own color.
        var color: PaletteColor? {
            switch self {
            case .lightGray: PaletteColor(red: 0.7, green: 0.7, blue: 0.7)
            case .lightBlue: PaletteColor(red: 0.29, green: 0.78, blue: 1)
            case .lightRed: PaletteColor(red: 1, green: 0.4, blue: 0.4)
            case .green: PaletteColor(red: 0.25, green: 0.8, blue: 0.25)
            case .mediumBlue: PaletteColor(red: 0.2, green: 0.4, blue: 1)
            case .yellow: PaletteColor(red: 1, green: 1, blue: 0)
            case .magenta: PaletteColor(red: 1, green: 0, blue: 1)
            case .cyan: PaletteColor(red: 0, green: 1, blue: 1)
            case .black: .black
            case .custom: nil
            }
        }
    }

    /// The major lines' pattern; subdivisions stay dotted.
    enum Style: String, CaseIterable, Identifiable {
        case lines = "Lines", dashedLines = "Dashed Lines", dots = "Dots"
        var id: Self { self }

        /// On and off lengths in screen points; empty for a solid line.
        var dashes: [CGFloat] {
            switch self {
            case .lines: []
            case .dashedLines: [4, 3]
            case .dots: [1, 2]
            }
        }
    }

    static let opacityRange = 1...100

    var preset: Preset = .lightGray
    /// Used while `preset` is Custom; kept when another preset is chosen, so switching back finds it.
    var customColor = PaletteColor(red: 0.7, green: 0.7, blue: 0.7)
    var style: Style = .lines
    /// The major lines' opacity, in percent.
    var opacity = 45

    var color: PaletteColor { preset.color ?? customColor }
    var majorAlpha: CGFloat {
        CGFloat(min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)) / 100
    }
    /// Subdivisions at a little over half the majors' opacity: 28% beside the default 45%.
    var subdivisionAlpha: CGFloat { majorAlpha * 28 / 45 }
}

/// In-progress create or move; the document is updated only when the drag finishes.
struct GuideDrag: Equatable {
    var id: UUID
    var axis: CanvasGuide.Axis
    var position: Double
    var isNew: Bool
    var original: Double?
}

extension EditorSession {
    /// Cyan, as Photoshop's default guide color.
    static let guideColor = CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 0.9)
    static let guideHitDistance: CGFloat = 5

    var canClearGuides: Bool { document.map { !$0.guides.isEmpty } ?? false }
    var canEditGuides: Bool {
        _ = showsBusy
        return document != nil && !locksGuides && !isProjectBusy && !isImporting && !showsNewDocument
            && levels == nil && hueSaturation == nil && filterEdit == nil && renamingLayerID == nil
    }

    /// Guides as currently shown, including a drag in progress.
    var displayedGuides: [CanvasGuide] {
        var guides = document?.guides ?? []
        guard let drag = guideDrag else { return guides }
        let current = CanvasGuide(id: drag.id, axis: drag.axis, position: drag.position)
        if let index = guides.firstIndex(where: { $0.id == drag.id }) {
            guides[index] = current
        } else if drag.isNew {
            guides.append(current)
        }
        return guides
    }

    func hitGuide(at viewPoint: CGPoint, tolerance: CGFloat = guideHitDistance) -> CanvasGuide? {
        guard showsGuides, !locksGuides, let document else { return nil }
        var best: (guide: CanvasGuide, distance: CGFloat)?
        for guide in displayedGuides {
            let distance: CGFloat
            if guide.axis == .vertical {
                let x = viewport.viewPoint(from: CGPoint(x: guide.position, y: 0), documentSize: document.size).x
                distance = abs(viewPoint.x - x)
            } else {
                let y = viewport.viewPoint(from: CGPoint(x: 0, y: guide.position), documentSize: document.size).y
                distance = abs(viewPoint.y - y)
            }
            if distance <= tolerance, best.map({ distance < $0.distance }) ?? true {
                best = (guide, distance)
            }
        }
        return best?.guide
    }

    func beginGuideCreation(axis: CanvasGuide.Axis, at position: Double) {
        guard canEditGuides else { return }
        showsGuides = true
        guideDrag = GuideDrag(id: UUID(), axis: axis, position: snappedGuidePosition(position, axis: axis, excluding: nil),
                              isNew: true, original: nil)
        refreshCanvasPreview?()
    }

    func beginGuideMove(_ guide: CanvasGuide) {
        guard canEditGuides else { return }
        guideDrag = GuideDrag(id: guide.id, axis: guide.axis, position: guide.position, isNew: false, original: guide.position)
        refreshCanvasPreview?()
    }

    func moveGuideDrag(to position: Double) {
        guard var drag = guideDrag else { return }
        drag.position = snappedGuidePosition(position, axis: drag.axis, excluding: drag.id)
        guideDrag = drag
        refreshCanvasPreview?()
    }

    /// `delete` is true when the pointer was released on a ruler (cancel a new guide, remove an existing one).
    func finishGuideDrag(delete: Bool) {
        guard let drag = guideDrag else { return }
        guideDrag = nil
        if delete {
            if drag.isNew {
                refreshCanvasPreview?()
                return
            }
            beginEdit("Delete Guide")
            document?.guides.removeAll { $0.id == drag.id }
            endEdit()
            refreshCanvasPreview?()
            return
        }
        if drag.isNew {
            beginEdit("New Guide")
            document?.guides.append(CanvasGuide(id: drag.id, axis: drag.axis, position: drag.position))
            endEdit()
        } else if drag.original != drag.position {
            beginEdit("Move Guide")
            if let index = document?.guides.firstIndex(where: { $0.id == drag.id }) {
                document?.guides[index].position = drag.position
            }
            endEdit()
        }
        refreshCanvasPreview?()
    }

    func cancelGuideDrag() {
        guideDrag = nil
        refreshCanvasPreview?()
    }

    func clearGuides() {
        guard canClearGuides else { return }
        beginEdit("Clear Guides")
        document?.guides = []
        endEdit()
        refreshCanvasPreview?()
    }

    func addGuide(_ guide: CanvasGuide) {
        guard canEditGuides else { return }
        showsGuides = true
        beginEdit("New Guide")
        document?.guides.append(guide)
        endEdit()
    }

    /// Alignment lines a move or crop may snap to, according to View > Snap and Snap To.
    func alignmentSnapTargets(excluding moving: Set<UUID> = [], includeCenters: Bool) -> (xs: [CGFloat], ys: [CGFloat]) {
        guard snapEnabled, let document else { return ([], []) }
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
        if snapToDocumentBounds {
            xs += [0, document.size.width]
            ys += [0, document.size.height]
            if includeCenters {
                xs.append(document.size.width / 2)
                ys.append(document.size.height / 2)
            }
        }
        if snapToLayers {
            for layer in document.renderLayers where layer.asset != nil && !moving.contains(layer.id) {
                let corners = DistortWarp.corners(of: displayedTransform(for: layer))
                let cornerXs = corners.map(\.x), cornerYs = corners.map(\.y)
                guard let minX = cornerXs.min(), let maxX = cornerXs.max(),
                      let minY = cornerYs.min(), let maxY = cornerYs.max() else { continue }
                xs += includeCenters
                    ? [minX.rounded(), ((minX + maxX) / 2).rounded(), maxX.rounded()]
                    : [minX.rounded(), maxX.rounded()]
                ys += includeCenters
                    ? [minY.rounded(), ((minY + maxY) / 2).rounded(), maxY.rounded()]
                    : [minY.rounded(), maxY.rounded()]
            }
        }
        // Hidden extras do not snap, matching Photoshop.
        if snapToGrid, showsGrid {
            xs += layoutGrid.lines(along: document.size.width)
            ys += layoutGrid.lines(along: document.size.height)
        }
        if snapToGuides, showsGuides {
            for guide in displayedGuides {
                if guide.axis == .vertical { xs.append(CGFloat(guide.position)) }
                else { ys.append(CGFloat(guide.position)) }
            }
        }
        return (xs, ys)
    }

    func snappedGuidePosition(_ position: Double, axis: CanvasGuide.Axis, excluding: UUID?) -> Double {
        guard snapEnabled, let document else { return position }
        let tolerance = TransformSnap.distance / max(viewport.pointsPerPixel, 0.0001)
        var targets: [CGFloat] = []
        let length = axis == .vertical ? document.size.width : document.size.height
        if snapToGrid, showsGrid { targets += layoutGrid.lines(along: length) }
        if snapToGuides, showsGuides {
            targets += displayedGuides.filter { $0.axis == axis && $0.id != excluding }.map { CGFloat($0.position) }
        }
        if snapToDocumentBounds {
            targets += [0, length / 2, length]
        }
        if snapToLayers {
            for layer in document.renderLayers where layer.asset != nil {
                let corners = DistortWarp.corners(of: displayedTransform(for: layer))
                let values = axis == .vertical ? corners.map(\.x) : corners.map(\.y)
                guard let min = values.min(), let max = values.max() else { continue }
                targets += [min.rounded(), ((min + max) / 2).rounded(), max.rounded()]
            }
        }
        let value = CGFloat(position)
        var best: CGFloat?
        for target in targets where abs(target - value) <= tolerance {
            if let current = best, abs(current - value) <= abs(target - value) { continue }
            best = target
        }
        return Double(best ?? value)
    }
}
