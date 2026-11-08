import SwiftUI

/// The tool rail's own icons, for the tools and modes SF Symbols has nothing to match, and the selection tools' bar's:
/// their shapes in an icon's frame, each filled or stroked in the rail's or the bar's color. scripts/rail-icons.swift
/// draws them into the iPad's icons too.
enum ToolIcons {
    /// Clone Stamp: a rubber stamp's round handle, neck, body and pad, to fill. SF Symbols has none.
    static func cloneStamp(in size: CGSize) -> Path {
        let w = size.width, h = size.height
        var stamp = Path()
        stamp.addEllipse(in: CGRect(x: w * 0.33, y: h * 0.02, width: w * 0.34, height: h * 0.30))
        stamp.addRect(CGRect(x: w * 0.43, y: h * 0.28, width: w * 0.14, height: h * 0.28))
        stamp.addRoundedRect(in: CGRect(x: w * 0.12, y: h * 0.54, width: w * 0.76, height: h * 0.22),
                             cornerSize: CGSize(width: w * 0.08, height: w * 0.08))
        stamp.addRect(CGRect(x: w * 0.06, y: h * 0.82, width: w * 0.88, height: h * 0.12))
        return stamp
    }

    /// The Gradient tool's frame, stroked `gradientFrameWidth` wide and clipping its dots.
    static func gradientFrame(in size: CGSize) -> Path {
        Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), cornerRadius: 3.5)
    }
    static let gradientFrameWidth: CGFloat = 1.4

    /// The Gradient tool's ramp, dithered into dots to fill inside its frame.
    static func gradientDots(in size: CGSize) -> Path {
        let frame = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let cell = frame.width / CGFloat(gradientPattern.count)
        var dots = Path()
        for (row, line) in gradientPattern.enumerated() {
            for (column, on) in line.enumerated() where on {
                dots.addRect(CGRect(x: frame.minX + CGFloat(column) * cell, y: frame.minY + CGFloat(row) * cell,
                                    width: cell, height: cell))
            }
        }
        return dots
    }

    /// A left-to-right ramp, Floyd–Steinberg dithered: 16×16 so each dot is exactly 1 pt inside the icon's 16 pt frame.
    private static let gradientPattern: [[Bool]] = {
        let size = 16
        var ramp = (0..<size).map { _ in (0..<size).map { CGFloat($0) / CGFloat(size - 1) } }
        var result = Array(repeating: Array(repeating: false, count: size), count: size)
        for y in 0..<size {
            for x in 0..<size {
                let on = ramp[y][x] >= 0.5
                result[y][x] = on
                let error = ramp[y][x] - (on ? 1 : 0)
                if x + 1 < size { ramp[y][x + 1] += error * 7 / 16 }
                guard y + 1 < size else { continue }
                if x > 0 { ramp[y + 1][x - 1] += error * 3 / 16 }
                ramp[y + 1][x] += error * 5 / 16
                if x + 1 < size { ramp[y + 1][x + 1] += error / 16 }
            }
        }
        return result
    }()

    /// The Lasso in Polygonal mode, laid out like the SF Symbol lasso but straight-sided: a wide loop, a knot below its
    /// right side and a short rope, each stroked with `polygonalLassoStyle`.
    static func polygonalLasso(in size: CGSize) -> [Path] {
        let unit = size.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
        var loop = Path()
        loop.addLines([point(1.2, 7.0), point(4.0, 2.4), point(11.8, 1.8), point(16.8, 5.2), point(15.6, 10.4), point(7.0, 11.6)])
        loop.closeSubpath()
        var knot = Path()
        knot.addLines([point(8.9, 10.9), point(13.3, 10.5), point(11.6, 14.5)])
        knot.closeSubpath()
        var rope = Path()
        rope.addLines([point(11.6, 14.5), point(12.9, 17.3)])
        return [loop, knot, rope]
    }
    static func polygonalLassoStyle(in size: CGSize) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.4 * size.width / 18, lineCap: .round, lineJoin: .round)
    }

    /// The Magic tool in Object mode: a selection's four corners, each stroked with `objectSelectionStyle`.
    static func objectSelectionCorners(in size: CGSize) -> [Path] {
        let unit = size.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
        return [
            [point(2, 6), point(2, 2), point(6, 2)],
            [point(12, 2), point(16, 2), point(16, 6)],
            [point(16, 12), point(16, 16), point(12, 16)],
            [point(6, 16), point(2, 16), point(2, 12)]
        ].map { corners in
            var corner = Path()
            corner.addLines(corners)
            return corner
        }
    }
    static func objectSelectionStyle(in size: CGSize) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.6 * size.width / 18, lineCap: .round, lineJoin: .round)
    }

    /// The pointer inside Object mode's corners, to fill.
    static func objectSelectionPointer(in size: CGSize) -> Path {
        let unit = size.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
        var cursor = Path()
        cursor.addLines([point(7, 5), point(7, 14), point(9.6, 11.7), point(11.3, 15.3),
                         point(13.2, 14.4), point(11.5, 10.9), point(14.5, 10.9)])
        cursor.closeSubpath()
        return cursor
    }

    /// Expand, Contract and Feather, the selection tools' bar's buttons.
    enum SelectionModify: CaseIterable { case expand, contract, feather }

    /// A part of an icon: its shape, stroked with `stroke` or else filled, at `opacity`.
    struct Part {
        var path: Path
        var stroke: StrokeStyle?
        var opacity: Double = 1
    }

    /// Expand is a small outline with arrows pointing out, Contract a large one with arrows pointing in, and Feather a
    /// solid square whose edge fades away.
    static func selectionModify(_ icon: SelectionModify, in size: CGSize) -> [Part] {
        let unit = size.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
        func square(_ inset: CGFloat) -> CGRect {
            CGRect(x: inset * unit, y: inset * unit, width: (18 - inset * 2) * unit, height: (18 - inset * 2) * unit)
        }
        let arrow = StrokeStyle(lineWidth: 1.4 * unit, lineCap: .round, lineJoin: .round)
        /// An arrow's lines at each of the four corners, from a top-left corner's points.
        func corners(_ lines: [[(CGFloat, CGFloat)]]) -> [Part] {
            [(false, false), (true, false), (false, true), (true, true)].flatMap { flipX, flipY in
                lines.map { line in
                    var path = Path()
                    path.addLines(line.map { x, y in point(flipX ? 18 - x : x, flipY ? 18 - y : y) })
                    return Part(path: path, stroke: arrow)
                }
            }
        }
        switch icon {
        case .expand:
            return [Part(path: Path(square(6.2)), stroke: StrokeStyle(lineWidth: 1.3 * unit, dash: [1.6 * unit, 1.2 * unit]))]
                + corners([[(4.3, 4.3), (1.6, 1.6)], [(1.6, 4.3), (1.6, 1.6), (4.3, 1.6)]])
        case .contract:
            return [Part(path: Path(square(1.4)), stroke: StrokeStyle(lineWidth: 1.3 * unit, dash: [1.8 * unit, 1.4 * unit]))]
                + corners([[(4.3, 4.3), (7.2, 7.2)], [(7.2, 4.8), (7.2, 7.2), (4.8, 7.2)]])
        case .feather:
            return [Part(path: Path(roundedRect: square(6), cornerRadius: 1 * unit)),
                    Part(path: Path(roundedRect: square(3.8), cornerRadius: 2 * unit), stroke: StrokeStyle(lineWidth: 1.3 * unit),
                         opacity: 0.6),
                    Part(path: Path(roundedRect: square(1.4), cornerRadius: 3.4 * unit), stroke: StrokeStyle(lineWidth: 1.2 * unit),
                         opacity: 0.28)]
        }
    }

    /// Draws `parts` in the foreground style.
    static func draw(_ parts: [Part], in context: GraphicsContext) {
        for part in parts {
            var context = context
            context.opacity = part.opacity
            if let stroke = part.stroke { context.stroke(part.path, with: .foreground, style: stroke) }
            else { context.fill(part.path, with: .foreground) }
        }
    }
}
