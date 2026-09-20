import AppKit

extension LayerTransform {
    /// This placement mirrored across a vertical line at `axis` (or, not `horizontally`, a horizontal one): the
    /// picture flips, its angle turns the other way, and its middle crosses to the other side of the line.
    func mirrored(horizontally: Bool, across axis: CGFloat) -> LayerTransform {
        var result = self
        if horizontally {
            result.flipX.toggle()
            result.origin.x = 2 * axis - center.x - size.width / 2
        } else {
            result.flipY.toggle()
            result.origin.y = 2 * axis - center.y - size.height / 2
        }
        result.rotation = -rotation
        return result
    }
}

extension EditorSession {
    /// Flips the selected layer about its own middle — or several selected layers, or a folder's contents, about
    /// the middle of the box around them — as one undo step. Masks follow the link: a linked mask flips with its
    /// layer, an unlinked one stays where it is.
    func flipLayers(horizontally: Bool) {
        commitTransform()
        guard canTransform, let document else { return }
        let members: [ImageLayer]
        let axis: CGFloat
        if transformsAsGroup {
            guard let box = groupTransformBox else { return }
            members = groupTransformMembers
            axis = horizontally ? box.center.x : box.center.y
        } else {
            guard let layer = activeLayer else { return }
            members = [layer]
            axis = horizontally ? layer.transform.center.x : layer.transform.center.y
        }
        let ids = Set(members.map(\.id))
        guard !ids.isEmpty else { return }
        finishOpacityEdit()
        beginEdit(horizontally ? L10n.string("Flip Horizontal") : L10n.string("Flip Vertical"))
        for index in document.layers.indices where ids.contains(document.layers[index].id) {
            let layer = document.layers[index]
            let flipped = layer.transform.mirrored(horizontally: horizontally, across: axis)
            if let mask = layer.mask {
                self.document?.layers[index].mask?.placement = mask.placement(movingLayer: layer.transform, to: flipped)
            }
            self.document?.layers[index].transform = flipped
        }
        endEdit()
    }

    /// Flips the whole canvas: every layer, folder and placed mask, and the selection, mirrored across its middle,
    /// as one undo step.
    func flipCanvas(horizontally: Bool) {
        commitTransform()
        cancelCrop()
        guard canEditLayers, let document else { return }
        let axis = horizontally ? document.size.width / 2 : document.size.height / 2
        finishOpacityEdit()
        beginEdit(horizontally ? L10n.string("Flip Canvas Horizontal") : L10n.string("Flip Canvas Vertical"))
        for index in document.layers.indices {
            let layer = document.layers[index]
            self.document?.layers[index].transform = layer.transform.mirrored(horizontally: horizontally, across: axis)
            if let placement = layer.mask?.placement {
                self.document?.layers[index].mask?.placement = placement.mirrored(horizontally: horizontally, across: axis)
            }
        }
        if let selection = document.selection {
            var mirror = horizontally
                ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: document.size.width, ty: 0)
                : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: document.size.height)
            if let path = selection.path.copy(using: &mirror) {
                self.document?.selection = DocumentSelection(path: path, antialiased: selection.antialiased)
            }
        }
        endEdit()
    }
}
