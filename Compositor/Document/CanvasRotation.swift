import CoreGraphics
import Foundation

extension LayerTransform {
    /// This placement turned a quarter turn with the canvas it sits on (`width` × `height` before the turn): the
    /// middle moves to where the turn takes it and the angle turns with it. Nothing is resampled, and a layer on whole
    /// pixels stays on whole pixels.
    func quarterTurned(clockwise: Bool, canvas: CGSize) -> LayerTransform {
        var result = self
        let middle = clockwise ? CGPoint(x: canvas.height - center.y, y: center.x) : CGPoint(x: center.y, y: canvas.width - center.x)
        result.origin = CGPoint(x: middle.x - size.width / 2, y: middle.y - size.height / 2)
        result.rotation = (rotation + (clockwise ? 90 : -90)).truncatingRemainder(dividingBy: 360)
        return result
    }
}

extension CanvasGuide {
    /// A guide turned with the canvas: a vertical one becomes horizontal and the other way round, on the same content.
    func quarterTurned(clockwise: Bool, canvas: CGSize) -> CanvasGuide {
        var guide = self
        switch (axis, clockwise) {
        case (.vertical, true): guide.axis = .horizontal
        case (.vertical, false): guide.axis = .horizontal; guide.position = Double(canvas.width) - position
        case (.horizontal, true): guide.axis = .vertical; guide.position = Double(canvas.height) - position
        case (.horizontal, false): guide.axis = .vertical
        }
        return guide
    }
}

extension EditorSession {
    /// Turns the whole canvas a quarter turn, as Photoshop's Image Rotation does: width and height swap, and every
    /// layer, folder, placed mask, the selection and the guides turn with it, as one undo step. Layers are placed, not
    /// resampled, so nothing loses detail.
    func rotateCanvas(clockwise: Bool) {
        commitTransform()
        cancelCrop()
        guard canEditLayers, let document else { return }
        let canvas = document.size
        finishOpacityEdit()
        beginEdit(clockwise ? "Rotate Canvas 90° Clockwise" : "Rotate Canvas 90° Counterclockwise")
        var layers = document.layers
        for index in layers.indices {
            layers[index].transform = layers[index].transform.quarterTurned(clockwise: clockwise, canvas: canvas)
            if let placement = layers[index].mask?.placement {
                layers[index].mask?.placement = placement.quarterTurned(clockwise: clockwise, canvas: canvas)
            }
        }
        var turned = CanvasDocument(id: document.id, width: document.height, height: document.width, layers: layers,
                                    resolution: document.resolution,
                                    guides: document.guides.map { $0.quarterTurned(clockwise: clockwise, canvas: canvas) })
        if let selection = document.selection {
            var turn = clockwise ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: canvas.height, ty: 0)
                                 : CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: canvas.width)
            if let path = selection.path.copy(using: &turn) {
                turned.selection = DocumentSelection(path: path, antialiased: selection.antialiased, feather: selection.feather)
            }
        }
        self.document = turned
        viewport.fit(documentSize: turned.size)
        endEdit()
    }
}
