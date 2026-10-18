import CoreGraphics
import Foundation

/// What Clone Stamp would stamp, for the brush cursor to preview inside its circle between strokes, on the Mac and
/// iPad alike: the source around the brush, and one click's coverage to shape it. Each is kept until what it shows
/// changes.
final class ClonePreview {
    let session: EditorSession

    init(session: EditorSession) {
        self.session = session
    }

    private var tipCache: (diameter: CGFloat, hardness: CGFloat, image: CGImage?)?

    /// One click's coverage at the current brush size and hardness, painted by the brush engine
    /// itself, so the preview softens exactly as a click would. Rebuilt only when they change.
    func tip(diameter: CGFloat, hardness: CGFloat) -> CGImage? {
        if let cache = tipCache, cache.diameter == diameter, cache.hardness == hardness { return cache.image }
        var image: CGImage?
        let side = max(1, Int(diameter.rounded(.up)))
        let size = CGSize(width: side, height: side)
        let settings = BrushSettings(diameter: diameter, hardness: hardness, red: 1, green: 1, blue: 1)
        if let stroke = try? BrushStroke(layer: ImageLayer(name: "Tip", blankSize: size), mask: false, settings: settings, canvas: size),
           (try? stroke.append(CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2))) != nil,
           (try? stroke.flush()) != nil,
           let painted = try? stroke.paintSnapshot(),
           let context = try? BrushRaster.context(width: side, height: side, mask: false) {
            BrushRaster.draw(painted.asset.image, in: painted.bounds, mask: false, context: context)
            image = context.makeImage()
        }
        tipCache = (diameter, hardness, image)
        return image
    }

    private struct Key: Equatable {
        let center: CGPoint
        let diameter: CGFloat
        let scale: CGFloat
        let revision: Int
        let undoCount: Int
        let allLayers: Bool
        let layerID: UUID?
    }
    private var imageCache: (key: Key, image: CGImage?)?

    /// What a Clone Stamp click would copy into the brush circle: the source around `center`
    /// (document pixels), rendered for just that area at screen resolution and reused until the
    /// pointer, zoom, brush, or document changes.
    func image(center: CGPoint, diameter: CGFloat, document: CanvasDocument) -> CGImage? {
        let scale = session.viewport.pointsPerPixel * session.viewport.backingScale
        let key = Key(center: center, diameter: diameter, scale: scale, revision: session.brushRevision,
                      undoCount: session.history.undoCount, allLayers: session.cloneSettings.sampleAllLayers,
                      layerID: session.activeLayerID)
        if let cache = imageCache, cache.key == key { return cache.image }
        let side = min(1024, max(1, Int((diameter * scale).rounded(.up))))
        var image: CGImage?
        if diameter > 0, let context = try? BrushRaster.context(width: side, height: side, mask: false) {
            let perPixel = CGFloat(side) / diameter
            context.scaleBy(x: perPixel, y: perPixel)
            context.translateBy(x: diameter / 2 - center.x, y: diameter / 2 - center.y)
            context.interpolationQuality = .medium
            if session.cloneSettings.sampleAllLayers {
                session.drawLiveComposite(document, in: context)
            } else if let layer = session.activeLayer, let source = layer.asset?.image {
                let transform = session.displayedTransform(for: layer)
                LayerRenderer.draw(source, transform: transform, center: transform.center, in: context)
            }
            image = context.makeImage()
        }
        imageCache = (key, image)
        return image
    }
}
