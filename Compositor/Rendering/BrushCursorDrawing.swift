#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreGraphics

/// The brush cursor, drawn the same on the Mac and iPad: the brush's circle and Clone Stamp's source crosshair, each a
/// black line over a wider white one so they show on any image, and Clone Stamp's preview inside the circle.
enum BrushCursorDrawing {
    /// How far the crosshair's arms reach from the point it marks, in points.
    static let crosshairReach: CGFloat = 7

    /// The brush's circle in `circle`, in a context that draws y down. Inside it, Clone Stamp's `preview` of what a
    /// click would stamp, at `previewOpacity`, cut to one click's coverage, `tip`, so soft brushes preview softly;
    /// while hardness is being dragged, a dashed ring at that fraction of the radius; and Clone Stamp's source
    /// crosshair at `marker`.
    static func draw(circle: CGRect?, preview: CGImage?, previewOpacity: CGFloat, tip: CGImage?, hardness: CGFloat?,
                     marker: CGPoint?, in context: CGContext) {
        if let circle {
            if let preview {
                context.saveGState()
                context.addEllipse(in: circle)
                context.clip()
                context.setAlpha(previewOpacity)
                context.beginTransparencyLayer(in: circle, auxiliaryInfo: nil)
                context.interpolationQuality = .medium
                // The context draws y down; images draw bottom-up.
                context.translateBy(x: circle.minX, y: circle.maxY)
                context.scaleBy(x: 1, y: -1)
                let bounds = CGRect(origin: .zero, size: circle.size)
                context.draw(preview, in: bounds)
                // Keep only what one click would lay down, so soft brushes preview softly.
                if let tip {
                    context.setBlendMode(.destinationIn)
                    context.draw(tip, in: bounds)
                }
                context.endTransparencyLayer()
                context.restoreGState()
            }
            strokeCircle(circle, in: context)
            if let hardness, hardness > 0 {
                let inset = circle.width * (1 - hardness) / 2
                context.setLineDash(phase: 0, lengths: [4, 3])
                strokeCircle(circle.insetBy(dx: inset, dy: inset), in: context)
                context.setLineDash(phase: 0, lengths: [])
            }
        }
        if let marker { strokeCrosshair(at: marker, in: context) }
    }

    /// The circle in `rect`, dashed if the context's line dash is set, as the hardness ring is.
    static func strokeCircle(_ rect: CGRect, in context: CGContext) {
        context.setStrokeColor(PlatformColor.white.cgColor)
        context.setLineWidth(2.5)
        context.strokeEllipse(in: rect)
        context.setStrokeColor(PlatformColor.black.cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: rect)
    }

    /// The crosshair over `point`, its arms rounded at the ends.
    static func strokeCrosshair(at point: CGPoint, in context: CGContext) {
        let reach = crosshairReach
        context.move(to: CGPoint(x: point.x - reach, y: point.y))
        context.addLine(to: CGPoint(x: point.x + reach, y: point.y))
        context.move(to: CGPoint(x: point.x, y: point.y - reach))
        context.addLine(to: CGPoint(x: point.x, y: point.y + reach))
        let arms = context.path
        context.setLineCap(.round)
        context.setStrokeColor(PlatformColor.white.cgColor)
        context.setLineWidth(3)
        context.strokePath()
        if let arms { context.addPath(arms) }
        context.setStrokeColor(PlatformColor.black.cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }
}
