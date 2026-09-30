import CoreGraphics

extension EditorSession {
    /// The whole document for the Navigator, no more than `maxSide` pixels on its longer side (never enlarged). It is
    /// the same live composite the Magic Wand samples, so adjustments, masks and clipping show as on the canvas.
    ///
    /// The document is placed at the picture's size rather than drawn full size into a scaled context: adjustment and
    /// clipping surfaces take the size of what they draw, so a scaled context would still render them at full size.
    /// A bare session draws it, so a transform or preview in progress here (whose placement is full size) stays out;
    /// the picture shows the document as it is.
    func navigatorImage(maxSide: Int) -> CGImage? {
        guard let document, document.width > 0, document.height > 0, maxSide > 0 else { return nil }
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(document.width, document.height)))
        let width = max(1, Int((CGFloat(document.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(document.height) * scale).rounded()))
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return nil }
        context.interpolationQuality = .medium
        let small = document.placed(scaleX: CGFloat(width) / CGFloat(document.width),
                                    y: CGFloat(height) / CGFloat(document.height), width: width, height: height)
        EditorSession().drawLiveComposite(small, in: context)
        return context.makeImage()
    }
}

private extension CanvasDocument {
    /// This document drawn `x` × `y` times its size into `width` × `height`: every layer, folder and mask placement
    /// scaled, and blurs with them; the pixels untouched.
    func placed(scaleX x: CGFloat, y: CGFloat, width: Int, height: Int) -> CanvasDocument {
        func scaled(_ transform: LayerTransform) -> LayerTransform {
            var result = transform
            result.origin = CGPoint(x: transform.origin.x * x, y: transform.origin.y * y)
            result.size = CGSize(width: transform.size.width * x, height: transform.size.height * y)
            return result
        }
        return CanvasDocument(id: id, width: width, height: height, layers: layers.map { layer in
            var small = layer
            small.transform = scaled(layer.transform)
            if let placement = layer.mask?.placement { small.mask?.placement = scaled(placement) }
            // Blurs are measured in document pixels, so they shrink with everything else.
            if let radius = layer.adjustment?.blurRadius { small.adjustment?.blurRadius = radius * x }
            if let distance = layer.adjustment?.motionDistance { small.adjustment?.motionDistance = distance * x }
            return small
        }, resolution: resolution)
    }
}
