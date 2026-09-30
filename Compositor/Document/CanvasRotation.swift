import Accelerate
import CoreGraphics
import Foundation

/// Image › Image Rotation's quarter turns.
nonisolated enum CanvasRotation: String, CaseIterable, Sendable {
    case clockwise = "90° Clockwise"
    case counterclockwise = "90° Counter Clockwise"
    case halfTurn = "180°"

    /// Degrees clockwise.
    var degrees: CGFloat {
        switch self {
        case .clockwise: return 90
        case .counterclockwise: return -90
        case .halfTurn: return 180
        }
    }
    var swapsSides: Bool { self != .halfTurn }

    /// Where a point on a `width` × `height` document lands once the document is turned. Exact, with no
    /// trigonometry, so whole pixels stay whole.
    func map(width: CGFloat, height: CGFloat) -> CGAffineTransform {
        switch self {
        case .clockwise: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case .counterclockwise: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case .halfTurn: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        }
    }

    /// vImage's name for this turn. Rows run top to bottom in memory, as on the canvas, so clockwise is clockwise.
    private var vImageTurn: Int {
        switch self {
        case .clockwise: return kRotate90DegreesClockwise
        case .counterclockwise: return kRotate90DegreesCounterClockwise
        case .halfTurn: return kRotate180DegreesClockwise
        }
    }

    /// `image` (a layer's pixels, or with `mask` a mask's) turned by moving whole pixels, so nothing is resampled
    /// and turning back gives the same pixels. A vectorized copy, a few tens of milliseconds for a large photo.
    func turn(_ image: CGImage, mask: Bool) throws -> CGImage {
        let width = swapsSides ? image.height : image.width, height = swapsSides ? image.width : image.height
        let target = try BrushRaster.context(width: width, height: height, mask: mask)
        guard let targetData = target.data else { throw ExportError.render }
        var to = vImage_Buffer(data: targetData, height: vImagePixelCount(height), width: vImagePixelCount(width),
                               rowBytes: target.bytesPerRow)
        // The image's own bytes when they're already in the canvas's layout, as layers made by the editor are; the
        // turn only reads them. Anything else is drawn into that layout first.
        let layout = try BrushRaster.context(width: 1, height: 1, mask: mask)
        let bytes = image.dataProvider?.data
        var source: CGContext?
        var from: vImage_Buffer
        if image.bitsPerPixel == layout.bitsPerPixel, image.bitsPerComponent == 8, image.bitmapInfo == layout.bitmapInfo,
           image.colorSpace == layout.colorSpace, let bytes, let pointer = CFDataGetBytePtr(bytes),
           CFDataGetLength(bytes) >= image.bytesPerRow * (image.height - 1) + image.width * image.bitsPerPixel / 8 {
            from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pointer), height: vImagePixelCount(image.height),
                                 width: vImagePixelCount(image.width), rowBytes: image.bytesPerRow)
        } else {
            let drawn = try BrushRaster.context(width: image.width, height: image.height, mask: mask)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: mask, context: drawn)
            guard let data = drawn.data else { throw ExportError.render }
            from = vImage_Buffer(data: data, height: vImagePixelCount(image.height), width: vImagePixelCount(image.width),
                                 rowBytes: drawn.bytesPerRow)
            source = drawn
        }
        defer { withExtendedLifetime((bytes, source)) {} }
        let turn = UInt8(vImageTurn)
        let error: vImage_Error
        if mask {
            error = vImageRotate90_Planar8(&from, &to, turn, 0, vImage_Flags(kvImageNoFlags))
        } else {
            var clear: [UInt8] = [0, 0, 0, 0]
            error = vImageRotate90_ARGB8888(&from, &to, turn, &clear, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError, let turned = target.makeImage() else { throw ExportError.render }
        return turned
    }
}

extension LayerTransform {
    /// This placement turned with the document by `map`: its middle moves, its angle turns by `degrees`, and its
    /// size and flips stay as they are, since the turn applies after them. For layers whose pixels can't be turned
    /// (live text and shapes, which redraw from their settings).
    func turned(_ degrees: CGFloat, by map: CGAffineTransform) -> LayerTransform {
        var result = self
        let middle = center.applying(map)
        result.origin = CGPoint(x: middle.x - size.width / 2, y: middle.y - size.height / 2)
        result.rotation = (rotation + degrees).remainder(dividingBy: 360)
        return result
    }

    /// The placement of pixels that have themselves been turned by `rotation`, so the picture lands where
    /// `turned` would put it while its angle stays as it was: upright layers stay upright, and draw as quickly as
    /// they did. A quarter turn swaps the sides, and a flip across one axis becomes a flip across the other.
    func placingTurnedPixels(_ rotation: CanvasRotation, by map: CGAffineTransform) -> LayerTransform {
        var result = self
        let middle = center.applying(map)
        if rotation.swapsSides {
            result.size = CGSize(width: size.height, height: size.width)
            swap(&result.flipX, &result.flipY)
        }
        result.origin = CGPoint(x: middle.x - result.size.width / 2, y: middle.y - result.size.height / 2)
        return result
    }
}

extension CanvasGuide {
    /// This guide turned with a `width` × `height` document, so it stays on the same content.
    func turned(_ rotation: CanvasRotation, width: CGFloat, height: CGFloat) -> CanvasGuide {
        var guide = self
        switch (rotation, axis) {
        case (.clockwise, .vertical): guide.axis = .horizontal
        case (.clockwise, .horizontal): guide.axis = .vertical; guide.position = Double(height) - position
        case (.counterclockwise, .vertical): guide.axis = .horizontal; guide.position = Double(width) - position
        case (.counterclockwise, .horizontal): guide.axis = .vertical
        case (.halfTurn, .vertical): guide.position = Double(width) - position
        case (.halfTurn, .horizontal): guide.position = Double(height) - position
        }
        return guide
    }
}

/// Carries a turned document's pixels out of a detached task.
nonisolated private struct TurnedPixels: @unchecked Sendable {
    var layers: [UUID: ImportedImage] = [:]
    var masks: [UUID: ImportedImage] = [:]
}

extension EditorSession {
    /// Turns the whole canvas: every layer, folder and mask, the selection and the guides, as one undo step; a
    /// quarter turn swaps the canvas's width and height. Layer pixels are turned whole, off the main thread, rather
    /// than left at an angle, so nothing is resampled and the canvas draws and paints afterward as quickly as it did
    /// before. Live text and shapes keep their settings and turn by their angle instead.
    func rotateCanvas(_ rotation: CanvasRotation) async {
        commitTransform()
        cancelCrop()
        guard canEditLayers, let document else { return }
        finishOpacityEdit()
        isProjectBusy = true
        defer { isProjectBusy = false }
        let turnsPixels = { (layer: ImageLayer) in layer.liveText == nil && layer.liveShape == nil }
        // A mask on the layer's own grid follows its layer; one placed apart always has its pixels turned.
        let turnsMask = { (layer: ImageLayer) in layer.mask.map { $0.placement != nil || turnsPixels(layer) } ?? false }
        let jobs = document.layers.map { layer in
            (id: layer.id, image: turnsPixels(layer) ? layer.asset : nil, mask: turnsMask(layer) ? layer.mask?.asset : nil)
        }
        let pixels: TurnedPixels
        do {
            pixels = try await Task.detached(priority: .userInitiated) {
                var turned = TurnedPixels()
                for job in jobs {
                    if let asset = job.image {
                        turned.layers[job.id] = ImportedImage(image: try rotation.turn(asset.image, mask: false),
                            thumbnail: try rotation.turn(asset.thumbnail, mask: false), name: asset.name)
                    }
                    if let asset = job.mask {
                        turned.masks[job.id] = ImportedImage(image: try rotation.turn(asset.image, mask: true),
                            thumbnail: try rotation.turn(asset.thumbnail, mask: true), name: asset.name)
                    }
                }
                return turned
            }.value
        } catch { brushError = error.localizedDescription; return }
        // Nothing else can edit while busy, but only write over the document the pixels were turned from.
        guard self.document == document else { return }
        let map = rotation.map(width: document.size.width, height: document.size.height)
        var turned = CanvasDocument(id: document.id,
            width: rotation.swapsSides ? document.height : document.width,
            height: rotation.swapsSides ? document.width : document.height,
            layers: document.layers, resolution: document.resolution,
            guides: document.guides.map { $0.turned(rotation, width: document.size.width, height: document.size.height) })
        for index in turned.layers.indices {
            let layer = turned.layers[index]
            if turnsPixels(layer) {
                if let asset = pixels.layers[layer.id] { turned.layers[index].asset = asset }
                turned.layers[index].transform = layer.transform.placingTurnedPixels(rotation, by: map)
            } else {
                turned.layers[index].transform = layer.transform.turned(rotation.degrees, by: map)
            }
            if let mask = layer.mask, let asset = pixels.masks[layer.id] {
                turned.layers[index].mask = LayerMask(asset: asset, isEnabled: mask.isEnabled,
                    placement: mask.placement?.placingTurnedPixels(rotation, by: map), isLinked: mask.isLinked)
            }
        }
        if let selection = document.selection {
            var turn = map
            if let path = selection.path.copy(using: &turn) {
                turned.selection = DocumentSelection(path: path, antialiased: selection.antialiased, feather: selection.feather)
            }
        }
        beginEdit("Rotate Canvas " + rotation.rawValue)
        self.document = turned
        endEdit()
        brushRevision += 1
        if rotation.swapsSides { viewport.fit(documentSize: turned.size) }
    }
}