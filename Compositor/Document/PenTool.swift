import AppKit

/// Transient in-progress drawing state for the Pen tool.
/// Held purely in memory during an active drawing gesture; not saved to CanvasDocument or DocumentHistory.
struct PenDraft: Equatable, Sendable {
    var subpath: VectorSubpath
    var activeAnchorIndex: Int?
    var isDragging: Bool
    var pointer: CGPoint?
    /// When continuing an existing vector layer's open subpath, the layer it came from.
    var continuingLayerID: UUID?
    /// When continuing, whether the draft was reversed (started from the last endpoint instead of the first).
    var continuingReversed: Bool = false
    /// Whether the user has pressed down on the closing anchor (the first anchor), awaiting a drag or release.
    var isClosingCandidate: Bool = false
    /// View-space position where the closing click began, used to measure the drag threshold.
    var closingStartViewPoint: CGPoint? = nil

    init(subpath: VectorSubpath = VectorSubpath(), activeAnchorIndex: Int? = nil, isDragging: Bool = false, pointer: CGPoint? = nil, continuingLayerID: UUID? = nil, continuingReversed: Bool = false, isClosingCandidate: Bool = false, closingStartViewPoint: CGPoint? = nil) {
        self.subpath = subpath
        self.activeAnchorIndex = activeAnchorIndex
        self.isDragging = isDragging
        self.pointer = pointer
        self.continuingLayerID = continuingLayerID
        self.continuingReversed = continuingReversed
        self.isClosingCandidate = isClosingCandidate
        self.closingStartViewPoint = closingStartViewPoint
    }

    var isClosed: Bool { subpath.isClosed }
}

/// Result of a pen endpoint hit test against committed vector layers.
struct PenEndpointHit: Equatable, Sendable {
    /// The layer whose open subpath endpoint was hit.
    let layerID: UUID
    /// True if the hit was on the last point; false if on the first.
    let isLast: Bool
    /// The endpoint position in document coordinates.
    let point: CGPoint
}

/// Result of a pen vector layer hit test against committed vector layers.
/// Used when the pointer is near or inside a committed vector path (such as a closed path).
struct PenVectorLayerHit: Equatable, Sendable {
    /// The committed vector layer that was hit.
    let layerID: UUID
}

extension EditorSession {
    /// Begins or extends a pen path at `point` in document coordinates.
    func beginPen(at point: CGPoint) {
        guard tool == .pen, canEditLayers, point.x.isFinite, point.y.isFinite, document != nil else { return }

        if var draft = penDraft {
            // Append a new anchor point
            let newPoint = VectorPoint(anchor: point)
            draft.subpath.points.append(newPoint)
            draft.activeAnchorIndex = draft.subpath.points.count - 1
            draft.isDragging = true
            draft.pointer = point
            penDraft = draft
        } else {
            // Start a new draft
            var subpath = VectorSubpath()
            subpath.points.append(VectorPoint(anchor: point))
            penDraft = PenDraft(subpath: subpath, activeAnchorIndex: 0, isDragging: true, pointer: point)
        }
    }

    /// Drags symmetric Bézier handles from the active anchor to `point` in document coordinates.
    func dragPen(to point: CGPoint) {
        guard var draft = penDraft, draft.isDragging,
              let index = draft.activeAnchorIndex,
              draft.subpath.points.indices.contains(index),
              point.x.isFinite, point.y.isFinite else { return }

        let P = draft.subpath.points[index].anchor
        let dx = point.x - P.x
        let dy = point.y - P.y

        if hypot(dx, dy) >= 1 {
            draft.subpath.points[index].nextControl = CGPoint(x: P.x + dx, y: P.y + dy)
            draft.subpath.points[index].previousControl = CGPoint(x: P.x - dx, y: P.y - dy)
        } else {
            draft.subpath.points[index].nextControl = nil
            draft.subpath.points[index].previousControl = nil
        }

        draft.pointer = point
        penDraft = draft
    }

    /// Ends dragging handles on the active anchor.
    func endPenDrag() {
        guard var draft = penDraft else { return }
        draft.isDragging = false
        penDraft = draft
    }

    /// Updates the live preview pointer position in document coordinates.
    func movePen(to point: CGPoint?) {
        guard var draft = penDraft else { return }
        guard let point else {
            draft.pointer = nil
            penDraft = draft
            return
        }
        guard point.x.isFinite, point.y.isFinite else { return }
        draft.pointer = point
        penDraft = draft
    }

    /// Begins a closing candidate gesture on the first anchor, awaiting drag or release.
    func beginPenClosing(atViewPoint viewPoint: CGPoint) {
        guard var draft = penDraft, draft.subpath.points.count >= 2 else { return }
        draft.isClosingCandidate = true
        draft.closingStartViewPoint = viewPoint
        draft.isDragging = false
        draft.activeAnchorIndex = 0
        penDraft = draft
    }

    /// Shapes Bézier handles on the first anchor while dragging during a closing candidate gesture.
    func dragPenClosing(to point: CGPoint) {
        guard var draft = penDraft, draft.isClosingCandidate,
              !draft.subpath.points.isEmpty,
              point.x.isFinite, point.y.isFinite else { return }

        draft.isDragging = true
        let P = draft.subpath.points[0].anchor
        let dx = point.x - P.x
        let dy = point.y - P.y

        if hypot(dx, dy) >= 1 {
            draft.subpath.points[0].nextControl = CGPoint(x: P.x + dx, y: P.y + dy)
            draft.subpath.points[0].previousControl = CGPoint(x: P.x - dx, y: P.y - dy)
        } else {
            draft.subpath.points[0].nextControl = nil
            draft.subpath.points[0].previousControl = nil
        }
        draft.pointer = point
        penDraft = draft
    }

    /// Ends the closing candidate gesture and commits the closed path.
    func endPenClosing() {
        guard var draft = penDraft, draft.isClosingCandidate else { return }
        draft.isClosingCandidate = false
        draft.isDragging = false
        draft.closingStartViewPoint = nil
        penDraft = draft
        closePen()
    }

    /// Closes the current subpath and commits the vector layer.
    func closePen() {
        guard var draft = penDraft, draft.subpath.points.count >= 2 else { return }
        draft.subpath.isClosed = true
        let continuingID = draft.continuingLayerID
        penDraft = nil
        commitPen(subpath: draft.subpath, replacingLayerID: continuingID)
        if let activeID = activeLayerID {
            let target = DirectSelectionHitTarget(
                layerID: activeID,
                anchorIndex: VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0),
                kind: .anchor
            )
            penHoverAnchor = target
            penHoverVectorLayer = PenVectorLayerHit(layerID: activeID)
        }
    }

    /// Finishes an open path (e.g. via Enter/Return) and commits if valid.
    func finishPen() {
        guard let draft = penDraft else { return }
        let continuingID = draft.continuingLayerID
        penDraft = nil
        if draft.subpath.points.count >= 2 || draft.subpath.isClosed {
            commitPen(subpath: draft.subpath, replacingLayerID: continuingID)
        }
    }

    /// Cancels the in-progress Pen gesture without committing any layer or modifying history.
    func cancelPen() {
        if penDraft != nil {
            penDraft = nil
        }
        penHoverEndpoint = nil
        penHoverAnchor = nil
        penHoverVectorLayer = nil
    }

    /// Undoes the last anchor in the active Pen draft, or cancels the draft if 1 or 0 anchors remain.
    /// Operates purely on transient state without modifying or consuming DocumentHistory.
    func undoPenDraft() {
        guard var draft = penDraft else { return }

        if draft.isClosingCandidate {
            draft.isClosingCandidate = false
            draft.isDragging = false
            draft.closingStartViewPoint = nil
            penDraft = draft
            return
        }

        if draft.subpath.points.count <= 1 {
            penDraft = nil
        } else {
            draft.subpath.points.removeLast()
            draft.activeAnchorIndex = draft.subpath.points.count - 1
            draft.isDragging = false
            penDraft = draft
        }
    }

    /// Commits a completed VectorSubpath into a new or existing ImageLayer with canonical VectorModel and derived raster cache.
    /// When `replacingLayerID` is set, the existing layer is replaced in-place (continuation workflow).
    func commitPen(subpath: VectorSubpath, replacingLayerID: UUID? = nil) {
        guard canEditLayers, document != nil, subpath.isValid, !subpath.points.isEmpty else { return }

        // When continuing, preserve the original layer's stroke/fill if available.
        // New Pen paths are transparent by default: fill == nil, stroke == nil.
        let existingVector = replacingLayerID.flatMap { id in document?.layers.first { $0.id == id }?.vector }
        let stroke: VectorStrokeStyle? = existingVector?.stroke
        let fill: VectorFillStyle? = subpath.isClosed ? existingVector?.fill : nil

        // Compute document-space bounding box of the subpath
        let modelForBounds = VectorModel(subpaths: [subpath], fill: fill, stroke: stroke)
        let pathForBounds = VectorBridge.cgPath(from: modelForBounds)
        let rawBounds = pathForBounds.boundingBoxOfPath

        guard rawBounds.origin.x.isFinite, rawBounds.origin.y.isFinite,
              rawBounds.width.isFinite, rawBounds.height.isFinite else { return }

        let strokeWidth = (stroke?.isEnabled == true ? stroke?.width : nil) ?? CGFloat(penStrokeWidth)
        let miterLimit = stroke?.miterLimit ?? 10
        let miterPadding = ceil(strokeWidth * miterLimit / 2)
        let strokePadding = ceil(strokeWidth / 2)
        let padding = max(16, ceil(strokePadding + miterPadding + 4))
        let docRect = rawBounds.insetBy(dx: -padding, dy: -padding).integral
        let layerOrigin = docRect.origin
        let layerSize = CGSize(width: max(1, docRect.width), height: max(1, docRect.height))

        guard Int(layerSize.width) * Int(layerSize.height) <= Self.maxShapePixels else {
            brushError = "That vector path is too large. A vector path can cover up to 100 megapixels."
            return
        }

        // Translate subpath into layer-local coordinates
        let localSubpath = subpath.translated(by: CGPoint(x: -layerOrigin.x, y: -layerOrigin.y))
        let localModel = VectorModel(subpaths: [localSubpath], fill: fill, stroke: stroke)

        do {
            let image = try VectorRenderer.render(localModel, in: layerSize)
            if let replacingID = replacingLayerID,
               let idx = document?.layers.firstIndex(where: { $0.id == replacingID }),
               let thumbnail = try? PixelInvert.thumbnail(of: image) {
                // Replace the original layer in-place, preserving its position in the stack.
                let oldName = document!.layers[idx].name
                beginEdit("Extend Vector Path")
                document!.layers[idx].asset = ImportedImage(image: image, thumbnail: thumbnail, name: oldName)
                document!.layers[idx].transform = LayerTransform(origin: layerOrigin, size: layerSize)
                document!.layers[idx].vector = localModel
                activeLayerID = replacingID
                endEdit()
            } else {
                addPixelLayer(image, at: layerOrigin, name: nextVectorName(), editName: "New Vector Layer",
                              dropsSelection: false, vector: localModel)
            }
        } catch {
            brushError = error.localizedDescription
        }
    }

    /// Hit-tests committed vector layers for an open-subpath endpoint near `viewPoint`.
    /// Returns the nearest match within `tolerance` view points, or nil.
    func hitTestPenEndpoint(at viewPoint: CGPoint, tolerance: CGFloat = 10) -> PenEndpointHit? {
        guard let document else { return nil }
        var best: (hit: PenEndpointHit, distance: CGFloat)?
        for layer in document.layers where layer.isVisible && layer.vector != nil {
            guard let vector = layer.vector else { continue }
            let layerToDoc = layer.transform.layerToDocument
            for subpath in vector.subpaths where !subpath.isClosed && subpath.points.count >= 2 {
                let first = subpath.points[0].anchor.applying(layerToDoc)
                let last = subpath.points[subpath.points.count - 1].anchor.applying(layerToDoc)
                let firstView = viewport.viewPoint(from: first, documentSize: document.size)
                let lastView = viewport.viewPoint(from: last, documentSize: document.size)
                let dFirst = hypot(firstView.x - viewPoint.x, firstView.y - viewPoint.y)
                let dLast = hypot(lastView.x - viewPoint.x, lastView.y - viewPoint.y)
                if dFirst <= tolerance, dFirst < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (PenEndpointHit(layerID: layer.id, isLast: false, point: first), dFirst)
                }
                if dLast <= tolerance, dLast < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (PenEndpointHit(layerID: layer.id, isLast: true, point: last), dLast)
                }
            }
        }
        return best?.hit
    }

    private func hitTestClosedAnchor(
        in layer: ImageLayer,
        vector: VectorModel,
        layerToView: CGAffineTransform,
        viewPoint: CGPoint,
        tolerance: CGFloat
    ) -> VectorAnchorIndex? {
        var closestAnchor: VectorAnchorIndex?
        var minDistance = tolerance

        for (subpathIndex, subpath) in vector.subpaths.enumerated() where subpath.isClosed {
            for (anchorIndex, pt) in subpath.points.enumerated() {
                let anchorView = pt.anchor.applying(layerToView)
                let dist = hypot(anchorView.x - viewPoint.x, anchorView.y - viewPoint.y)
                if dist <= minDistance {
                    minDistance = dist
                    closestAnchor = VectorAnchorIndex(subpathIndex: subpathIndex, anchorIndex: anchorIndex)
                }
            }
        }
        return closestAnchor
    }

    private func vectorPathContains(
        vector: VectorModel,
        layerToView: CGAffineTransform,
        viewPoint: CGPoint,
        pointsPerPixel: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        var t = layerToView
        // 1. Check fill area of closed subpaths
        let closedSubpaths = vector.subpaths.filter(\.isClosed)
        if !closedSubpaths.isEmpty {
            let closedModel = VectorModel(subpaths: closedSubpaths, fill: vector.fill, stroke: nil)
            let closedLocalPath = VectorBridge.cgPath(from: closedModel)
            if let closedViewPath = closedLocalPath.copy(using: &t) {
                let fillRule = vector.fill?.fillRule.cgFillRule ?? .winding
                if closedViewPath.contains(viewPoint, using: fillRule) {
                    return true
                }
            }
        }

        // 2. Check stroke of all subpaths within stroke tolerance
        let localStrokeWidth = (vector.stroke?.isEnabled == true) ? (vector.stroke?.width ?? 1) : 1
        let viewStrokeWidth = localStrokeWidth * pointsPerPixel
        let hitWidth = max(viewStrokeWidth, tolerance * 2)

        let fullLocalPath = VectorBridge.cgPath(from: vector)
        if let fullViewPath = fullLocalPath.copy(using: &t) {
            let strokedViewPath = fullViewPath.copy(
                strokingWithWidth: hitWidth,
                lineCap: vector.stroke?.lineCap.cgCap ?? .round,
                lineJoin: vector.stroke?.lineJoin.cgJoin ?? .round,
                miterLimit: vector.stroke?.miterLimit ?? 10
            )
            if strokedViewPath.contains(viewPoint) {
                return true
            }
        }
        return false
    }

    /// Hit-tests for an anchor point in a closed subpath across visible vector layers.
    /// Layers are checked in visual stacking order (topmost first).
    /// If a higher layer's path occludes lower layers at `viewPoint`, lower layers are not tested.
    func hitTestPenClosedAnchor(at viewPoint: CGPoint, tolerance: CGFloat = 10) -> DirectSelectionHitTarget? {
        guard let document else { return nil }
        let docRect = viewport.documentRect(document.size)
        let pointsPerPixel = viewport.pointsPerPixel
        guard pointsPerPixel > 0 else { return nil }

        let docToView = CGAffineTransform(translationX: docRect.origin.x, y: docRect.origin.y)
            .scaledBy(x: pointsPerPixel, y: pointsPerPixel)

        for layer in document.layers.reversed() where layer.isVisible && layer.vector != nil {
            guard let vector = layer.vector, !vector.subpaths.isEmpty else { continue }
            let layerToDoc = layer.transform.layerToDocument
            let layerToView = layerToDoc.concatenating(docToView)

            // Check anchor in this layer
            if let anchorHit = hitTestClosedAnchor(in: layer, vector: vector, layerToView: layerToView, viewPoint: viewPoint, tolerance: tolerance) {
                return DirectSelectionHitTarget(layerID: layer.id, anchorIndex: anchorHit, kind: .anchor)
            }

            // If this layer's path covers viewPoint, it occludes lower layers so an anchor on a lower layer cannot win
            if vectorPathContains(vector: vector, layerToView: layerToView, viewPoint: viewPoint, pointsPerPixel: pointsPerPixel, tolerance: 6) {
                return nil
            }
        }
        return nil
    }

    /// Hit-tests committed vector layers for a click inside a closed subpath's fill area
    /// or within stroke tolerance of any subpath's stroke path, in view/screen space.
    /// Layers are checked in visual stacking order (topmost layer first).
    /// Returns the topmost matching layer, or nil.
    func hitTestPenVectorLayer(at viewPoint: CGPoint, tolerance: CGFloat = 6) -> PenVectorLayerHit? {
        guard let document else { return nil }
        let docRect = viewport.documentRect(document.size)
        let pointsPerPixel = viewport.pointsPerPixel
        guard pointsPerPixel > 0 else { return nil }

        let docToView = CGAffineTransform(translationX: docRect.origin.x, y: docRect.origin.y)
            .scaledBy(x: pointsPerPixel, y: pointsPerPixel)

        for layer in document.layers.reversed() where layer.isVisible && layer.vector != nil {
            guard let vector = layer.vector, !vector.subpaths.isEmpty else { continue }
            let layerToDoc = layer.transform.layerToDocument
            let layerToView = layerToDoc.concatenating(docToView)

            if vectorPathContains(vector: vector, layerToView: layerToView, viewPoint: viewPoint, pointsPerPixel: pointsPerPixel, tolerance: tolerance) {
                return PenVectorLayerHit(layerID: layer.id)
            }
        }
        return nil
    }

    /// Creates a document selection from the closed subpaths of the specified vector layer.
    /// The vector's CGPath is transformed from layer-local to document coordinates,
    /// then applied as the current DocumentSelection.
    func makeSelectionFromVector(layerID: UUID) {
        guard let document, canEditSelection,
              let layer = document.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else { return }

        let closedSubpaths = vector.subpaths.filter(\.isClosed)
        guard !closedSubpaths.isEmpty else { return }

        let closedModel = VectorModel(subpaths: closedSubpaths, fill: vector.fill, stroke: nil)
        let localPath = VectorBridge.cgPath(from: closedModel)
        var layerToDoc = layer.transform.layerToDocument
        guard let docPath = localPath.copy(using: &layerToDoc) else { return }

        applySelection(docPath, mode: .replace, name: "Make Selection")
    }

    /// Fills the closed subpaths of the specified vector layer using the current foreground color,
    /// painting directly into the layer's raster asset in document coordinates while preserving the VectorModel.
    func fillPathFromVector(layerID: UUID) {
        guard let document, canEditLayers,
              let index = document.layers.firstIndex(where: { $0.id == layerID }),
              let vector = document.layers[index].vector else { return }

        let closedSubpaths = vector.subpaths.filter(\.isClosed)
        guard !closedSubpaths.isEmpty else { return }

        let closedModel = VectorModel(subpaths: closedSubpaths, fill: vector.fill, stroke: nil)
        let localPath = VectorBridge.cgPath(from: closedModel)
        let fillRule = vector.fill?.fillRule.cgFillRule ?? .winding
        let fillColor = foregroundColor.cgColor

        paintIntoVectorLayer(at: index, name: "Fill Path", localPath: localPath) { context, path in
            context.setFillColor(fillColor)
            context.addPath(path)
            context.fillPath(using: fillRule)
        }
    }

    /// Strokes the subpaths of the specified vector layer using the current foreground color and stroke settings,
    /// painting directly into the layer's raster asset in document coordinates while preserving the VectorModel.
    func strokePathFromVector(layerID: UUID, recordHistory: Bool = true) {
        guard let document, canEditLayers,
              let index = document.layers.firstIndex(where: { $0.id == layerID }),
              let vector = document.layers[index].vector else { return }

        let validSubpaths = vector.subpaths.filter { $0.points.count >= 2 }
        guard !validSubpaths.isEmpty else { return }

        let strokeModel = VectorModel(subpaths: validSubpaths, fill: nil, stroke: vector.stroke)
        let localPath = VectorBridge.cgPath(from: strokeModel)

        let strokeWidth: CGFloat
        let lineCap: CGLineCap
        let lineJoin: CGLineJoin
        let miterLimit: CGFloat

        if let stroke = vector.stroke, stroke.isEnabled {
            strokeWidth = max(1.0, stroke.width)
            lineCap = stroke.lineCap.cgCap
            lineJoin = stroke.lineJoin.cgJoin
            miterLimit = stroke.miterLimit
        } else {
            strokeWidth = max(1.0, CGFloat(penStrokeWidth))
            lineCap = VectorLineCap.round.cgCap
            lineJoin = VectorLineJoin.round.cgJoin
            miterLimit = 10
        }

        let strokeColor = foregroundColor.cgColor

        paintIntoVectorLayer(at: index, name: "Stroke Path", localPath: localPath, recordHistory: recordHistory) { context, path in
            VectorRenderer.strokePath(
                path,
                width: strokeWidth,
                lineCap: lineCap,
                lineJoin: lineJoin,
                miterLimit: miterLimit,
                color: strokeColor,
                in: context
            )
        }
    }

    /// Commits the active pen draft and strokes it in exactly one history transaction named "Stroke Path".
    func strokePenDraft() {
        guard let draft = penDraft, draft.subpath.points.count >= 2 || draft.subpath.isClosed else { return }
        let continuingID = draft.continuingLayerID
        penDraft = nil

        finishOpacityEdit()
        beginEdit("Stroke Path")
        commitPen(subpath: draft.subpath, replacingLayerID: continuingID)
        if let layerID = activeLayerID {
            strokePathFromVector(layerID: layerID, recordHistory: false)
        }
        endEdit()
    }

    private func paintIntoVectorLayer(
        at index: Int,
        name: String,
        localPath: CGPath,
        recordHistory: Bool = true,
        _ draw: (CGContext, CGPath) -> Void
    ) {
        guard let document, index < document.layers.count else { return }
        let layer = document.layers[index]
        guard let vector = layer.vector else { return }

        let width = max(1, Int(layer.transform.size.width.rounded()))
        let height = max(1, Int(layer.transform.size.height.rounded()))

        guard width * height <= EditorSession.maxShapePixels else {
            brushError = ProjectError.tooLarge.localizedDescription
            return
        }

        do {
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            context.setShouldAntialias(true)

            // 1. Draw existing image if present
            if let existing = layer.asset?.image {
                BrushRaster.draw(existing, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
            }

            // 2. Prepare coordinate mapping and selection clipping
            let docToLayer = layer.transform.documentToLayer ?? .identity
            var layerToDoc = layer.transform.layerToDocument
            let docPath = localPath.copy(using: &layerToDoc) ?? localPath

            // 3. Apply selection clip if active
            if let selection = document.selection {
                if selection.isEmpty {
                    // Empty selection clips away all painting ("touch nothing")
                    return
                }
                let clip = try selection.clip(canvas: document.size)
                guard clip.coverage != nil, !clip.rect.isEmpty else {
                    return
                }
                context.saveGState()
                context.concatenate(docToLayer)
                clip.apply(to: context)
                draw(context, docPath)
                context.restoreGState()
            } else {
                // No selection: draw directly in layer-local coordinates
                context.saveGState()
                draw(context, localPath)
                context.restoreGState()
            }

            guard let newImage = context.makeImage() else {
                throw ExportError.render
            }
            let thumbnail = try PixelInvert.thumbnail(of: newImage)
            let assetName = layer.asset?.name ?? layer.name

            if recordHistory {
                finishOpacityEdit()
                beginEdit(name)
            }
            self.document?.layers[index].asset = ImportedImage(image: newImage, thumbnail: thumbnail, name: assetName)
            self.document?.layers[index].vector = vector
            self.document?.layers[index].transform = layer.transform
            if recordHistory {
                endEdit()
            }
            brushRevision += 1
        } catch {
            brushError = error.localizedDescription
        }
    }

    /// Begins continuing an existing vector layer's open subpath from `hit`.
    /// The draft's subpath is loaded in document coordinates so new anchors land correctly.
    func beginPenContinuation(from hit: PenEndpointHit) {
        guard let document, let layerIndex = document.layers.firstIndex(where: { $0.id == hit.layerID }),
              let vector = document.layers[layerIndex].vector,
              let subpath = vector.subpaths.first, !subpath.isClosed else { return }

        let layerToDoc = document.layers[layerIndex].transform.layerToDocument
        // Translate layer-local points to document coordinates
        var docSubpath = VectorSubpath(points: subpath.points.map { pt in
            VectorPoint(
                anchor: pt.anchor.applying(layerToDoc),
                previousControl: pt.previousControl?.applying(layerToDoc),
                nextControl: pt.nextControl?.applying(layerToDoc)
            )
        }, isClosed: false)

        // If the user clicked the first point, reverse so we always extend from the end
        let reversed = !hit.isLast
        if reversed {
            docSubpath.points.reverse()
            // Swap control handles after reversal
            docSubpath.points = docSubpath.points.map { pt in
                VectorPoint(anchor: pt.anchor, previousControl: pt.nextControl, nextControl: pt.previousControl)
            }
        }

        penDraft = PenDraft(
            subpath: docSubpath,
            activeAnchorIndex: docSubpath.points.count - 1,
            isDragging: false,
            pointer: nil,
            continuingLayerID: hit.layerID,
            continuingReversed: reversed
        )
    }

    func nextVectorName() -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("Vector \(number)") { number += 1 }
        return "Vector \(number)"
    }
}

extension VectorSubpath {
    /// Translates all anchor and control points in this subpath by delta.
    func translated(by delta: CGPoint) -> VectorSubpath {
        var result = self
        result.points = points.map { pt in
            let anchor = CGPoint(x: pt.anchor.x + delta.x, y: pt.anchor.y + delta.y)
            let prev = pt.previousControl.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            let next = pt.nextControl.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            return VectorPoint(anchor: anchor, previousControl: prev, nextControl: next)
        }
        return result
    }
}
