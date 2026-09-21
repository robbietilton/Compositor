import AppKit

/// Turns raster coverage into a selection outline along exact pixel edges.
nonisolated enum MaskTracing {
    /// Outline of a mask's pixels darker than 50% gray.
    static func darkPixels(in image: CGImage) -> CGPath? { trace(image, alpha: false) { $0 < 128 } }

    /// Outline of a mask's pixels lighter than 50% gray — what a mask shows.
    static func whitePixels(in image: CGImage) -> CGPath? { trace(image, alpha: false) { $0 >= 128 } }

    /// Outline of an image's pixels that are at least 50% opaque.
    static func opaquePixels(in image: CGImage) -> CGPath? { trace(image, alpha: true) { $0 >= 128 } }

    /// Outline, in the image's top-left pixel coordinates, of pixels whose gray value (or
    /// alpha) passes `test`. Outer boundaries run clockwise and holes counterclockwise, so
    /// the winding fill rule reproduces exactly the traced pixels. Nil when none pass.
    private static func trace(_ image: CGImage, alpha: Bool, _ test: (UInt8) -> Bool) -> CGPath? {
        let width = image.width, height = image.height
        // Alpha is read from RGBA pixels (the 4th byte); gray from a one-byte gray bitmap.
        let channels = alpha ? 4 : 1
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * channels,
                                      space: alpha ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                                                        : CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let offset = channels - 1
        func selected(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && test(bytes[(y * width + x) * channels + offset])
        }
        // Directed unit edges between selected and unselected pixels, keyed by start vertex.
        let stride = width + 1
        var outgoing: [Int: [Int]] = [:]
        func edge(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) { outgoing[y0 * stride + x0, default: []].append(y1 * stride + x1) }
        for y in 0..<height {
            for x in 0..<width where selected(x, y) {
                if !selected(x, y - 1) { edge(x, y, x + 1, y) }
                if !selected(x + 1, y) { edge(x + 1, y, x + 1, y + 1) }
                if !selected(x, y + 1) { edge(x + 1, y + 1, x, y + 1) }
                if !selected(x - 1, y) { edge(x, y + 1, x, y) }
            }
        }
        guard !outgoing.isEmpty else { return nil }
        let path = CGMutablePath()
        while let start = outgoing.keys.first {
            var loop: [Int] = []
            var current = start
            repeat {
                guard var ends = outgoing[current], let end = ends.popLast() else { break }
                outgoing[current] = ends.isEmpty ? nil : ends
                loop.append(current)
                current = end
            } while current != start
            // Keep only corners: drop vertices that continue in a straight line.
            var corners: [CGPoint] = []
            for (index, vertex) in loop.enumerated() {
                let previous = loop[(index + loop.count - 1) % loop.count], following = loop[(index + 1) % loop.count]
                let inX = vertex % stride - previous % stride, inY = vertex / stride - previous / stride
                let outX = following % stride - vertex % stride, outY = following / stride - vertex / stride
                if inX != outX || inY != outY { corners.append(CGPoint(x: vertex % stride, y: vertex / stride)) }
            }
            guard corners.count >= 3 else { continue }
            path.addLines(between: corners)
            path.closeSubpath()
        }
        return path.isEmpty ? nil : path
    }
}

extension EditorSession {
    /// Cmd-click on a mask thumbnail: the mask's black (hidden) areas become the
    /// selection. Shift adds to the current selection; Option subtracts from it.
    func loadMaskSelection(layerID: UUID, mode: SelectionMode = .replace) {
        guard canEditSelection, let layer = document?.layers.first(where: { $0.id == layerID }),
              let mask = layer.mask?.asset.image else { return }
        guard let traced = MaskTracing.darkPixels(in: mask) else { NSSound.beep(); return }
        var toDocument = BrushRaster.pixelToDocument(layer.maskTransform, width: mask.width, height: mask.height)
        guard let outline = traced.copy(using: &toDocument) else { return }
        applySelection(outline, mode: mode, name: String(localized: "Load Mask Selection"))
    }

    /// Cmd-click on a layer thumbnail: the layer's visible (≥ 50% opaque) pixels become
    /// the selection, ignoring its mask, as in Photoshop. Shift adds; Option subtracts.
    func loadLayerSelection(layerID: UUID, mode: SelectionMode = .replace) {
        guard canEditSelection, let layer = document?.layers.first(where: { $0.id == layerID }), !layer.isGroup,
              let image = layer.asset?.image else { NSSound.beep(); return }
        guard let traced = MaskTracing.opaquePixels(in: image) else { NSSound.beep(); return }
        var toDocument = BrushRaster.pixelToDocument(layer.transform, width: image.width, height: image.height)
        guard let outline = traced.copy(using: &toDocument) else { return }
        applySelection(outline, mode: mode, name: String(localized: "Load Layer Selection"))
    }
}
