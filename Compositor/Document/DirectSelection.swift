import AppKit

/// Identifies an anchor point in a VectorModel by its subpath index and point index.
nonisolated struct VectorAnchorIndex: Hashable, Equatable, Sendable {
    var subpathIndex: Int
    var anchorIndex: Int

    init(subpathIndex: Int, anchorIndex: Int) {
        self.subpathIndex = subpathIndex
        self.anchorIndex = anchorIndex
    }
}

/// The side of a Bézier control handle on a vector point.
nonisolated enum DirectSelectionHandleSide: Hashable, Equatable, Sendable {
    case previous
    case next
}

/// The specific element within a vector point targeted by Direct Selection.
nonisolated enum DirectSelectionTargetKind: Hashable, Equatable, Sendable {
    case anchor
    case handle(DirectSelectionHandleSide)
}

/// A hit-test result targeting a specific anchor or control handle within a vector layer.
/// Transient UI interaction state only; never persisted or serialized.
nonisolated struct DirectSelectionHitTarget: Hashable, Equatable, Sendable {
    var layerID: UUID
    var anchorIndex: VectorAnchorIndex
    var kind: DirectSelectionTargetKind

    init(layerID: UUID, anchorIndex: VectorAnchorIndex, kind: DirectSelectionTargetKind) {
        self.layerID = layerID
        self.anchorIndex = anchorIndex
        self.kind = kind
    }
}

/// Transient representation of an individual Bézier control handle.
nonisolated struct SelectedHandle: Hashable, Equatable, Sendable {
    var anchorIndex: VectorAnchorIndex
    var side: DirectSelectionHandleSide

    init(anchorIndex: VectorAnchorIndex, side: DirectSelectionHandleSide) {
        self.anchorIndex = anchorIndex
        self.side = side
    }
}

/// The visual state for rendering a vector anchor or handle in Direct Selection.
nonisolated enum DirectSelectionVisualState: Hashable, Equatable, Sendable {
    case unselected
    case selected
    case hoveredUnselected
    case hoveredSelected

    var isSelected: Bool {
        self == .selected || self == .hoveredSelected
    }

    var isHovered: Bool {
        self == .hoveredUnselected || self == .hoveredSelected
    }
}

/// Transient selection state for vector anchor points and optional active control handle.
/// Kept purely in memory within EditorSession; never serialized to VectorModel or CanvasDocument.
struct VectorSelection: Equatable, Sendable {
    var layerID: UUID
    var selectedAnchors: Set<VectorAnchorIndex>
    var selectedHandle: SelectedHandle?

    init(
        layerID: UUID,
        selectedAnchors: Set<VectorAnchorIndex> = [],
        selectedHandle: SelectedHandle? = nil
    ) {
        self.layerID = layerID
        self.selectedAnchors = selectedAnchors
        self.selectedHandle = selectedHandle
    }
}

/// The target of an active Direct Selection drag gesture.
nonisolated enum DirectSelectionDragTarget: Equatable, Sendable {
    case anchors(Set<VectorAnchorIndex>)
    case handle(anchorIndex: VectorAnchorIndex, side: DirectSelectionHandleSide)
}

/// Transient drag state during an interactive anchor or handle drag gesture.
struct DirectSelectionDrag: Equatable, Sendable {
    var layerID: UUID
    var initialModel: VectorModel
    var currentModel: VectorModel
    var startDocumentPoint: CGPoint
    var target: DirectSelectionDragTarget
    var hasMoved: Bool

    var selectedAnchors: Set<VectorAnchorIndex> {
        if case .anchors(let set) = target {
            return set
        }
        return []
    }

    init(
        layerID: UUID,
        initialModel: VectorModel,
        currentModel: VectorModel,
        startDocumentPoint: CGPoint,
        target: DirectSelectionDragTarget,
        hasMoved: Bool = false
    ) {
        self.layerID = layerID
        self.initialModel = initialModel
        self.currentModel = currentModel
        self.startDocumentPoint = startDocumentPoint
        self.target = target
        self.hasMoved = hasMoved
    }

    init(
        layerID: UUID,
        initialModel: VectorModel,
        currentModel: VectorModel,
        startDocumentPoint: CGPoint,
        selectedAnchors: Set<VectorAnchorIndex>,
        hasMoved: Bool = false
    ) {
        self.init(
            layerID: layerID,
            initialModel: initialModel,
            currentModel: currentModel,
            startDocumentPoint: startDocumentPoint,
            target: .anchors(selectedAnchors),
            hasMoved: hasMoved
        )
    }
}

extension LayerTransform {
    /// Affine transform mapping layer-local pixel coordinates to document coordinates.
    var layerToDocument: CGAffineTransform {
        let w = max(1, size.width)
        let h = max(1, size.height)
        return CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .scaledBy(x: flipX ? -1 : 1, y: flipY ? -1 : 1)
            .translatedBy(x: -w / 2, y: -h / 2)
    }

    /// Affine transform mapping document coordinates to layer-local pixel coordinates.
    var documentToLayer: CGAffineTransform? {
        layerToDocument.inverted()
    }
}

extension EditorSession {
    /// Hit-tests for a vector element (anchor or handle) across visible vector layers in screen/view space.
    /// Handles belonging to currently selected anchors are tested first.
    /// If includeUnselectedHandles is true, handles of all anchors in visible layers are also tested.
    func hitTestDirectSelection(
        at viewPoint: CGPoint,
        hitRadius: CGFloat = 10.0,
        includeUnselectedHandles: Bool = false
    ) -> DirectSelectionHitTarget? {
        guard let document else { return nil }

        // 1. First priority: Check visible control handles of currently selected anchors
        if let selection = vectorSelection,
           let layer = document.layers.first(where: { $0.id == selection.layerID && $0.isVisible }),
           let vector = layer.vector {
            if let handleHit = hitTestSelectedHandles(in: layer, vector: vector, selectedAnchors: selection.selectedAnchors, viewPoint: viewPoint, hitRadius: hitRadius) {
                return DirectSelectionHitTarget(layerID: layer.id, anchorIndex: handleHit.anchorIndex, kind: .handle(handleHit.side))
            }
        }

        // 2. Second priority: If includeUnselectedHandles is true, check all handles in active/visible layers
        if includeUnselectedHandles {
            if let active = activeLayer, let vector = active.vector, active.isVisible {
                if let handleHit = hitTestAllHandles(in: active, vector: vector, viewPoint: viewPoint, hitRadius: hitRadius) {
                    return DirectSelectionHitTarget(layerID: active.id, anchorIndex: handleHit.anchorIndex, kind: .handle(handleHit.side))
                }
            }
            for layer in document.layers.reversed() where layer.isVisible && layer.vector != nil && layer.id != activeLayerID {
                guard let vector = layer.vector else { continue }
                if let handleHit = hitTestAllHandles(in: layer, vector: vector, viewPoint: viewPoint, hitRadius: hitRadius) {
                    return DirectSelectionHitTarget(layerID: layer.id, anchorIndex: handleHit.anchorIndex, kind: .handle(handleHit.side))
                }
            }
        }

        // 3. Third priority: Hit-test anchors across visible vector layers (active layer first)
        if let active = activeLayer, let vector = active.vector, active.isVisible {
            if let anchorHit = hitTestAnchor(in: active, vector: vector, viewPoint: viewPoint, hitRadius: hitRadius) {
                return DirectSelectionHitTarget(layerID: active.id, anchorIndex: anchorHit, kind: .anchor)
            }
        }

        for layer in document.layers.reversed() where layer.isVisible && layer.vector != nil && layer.id != activeLayerID {
            guard let vector = layer.vector else { continue }
            if let anchorHit = hitTestAnchor(in: layer, vector: vector, viewPoint: viewPoint, hitRadius: hitRadius) {
                return DirectSelectionHitTarget(layerID: layer.id, anchorIndex: anchorHit, kind: .anchor)
            }
        }

        return nil
    }

    private func hitTestSelectedHandles(
        in layer: ImageLayer,
        vector: VectorModel,
        selectedAnchors: Set<VectorAnchorIndex>,
        viewPoint: CGPoint,
        hitRadius: CGFloat
    ) -> (anchorIndex: VectorAnchorIndex, side: DirectSelectionHandleSide)? {
        guard let document else { return nil }
        let layerToDoc = layer.transform.layerToDocument

        var closest: (anchorIndex: VectorAnchorIndex, side: DirectSelectionHandleSide)?
        var minDistance = hitRadius

        for anchorIdx in selectedAnchors {
            let s = anchorIdx.subpathIndex
            let a = anchorIdx.anchorIndex
            guard vector.subpaths.indices.contains(s),
                  vector.subpaths[s].points.indices.contains(a) else { continue }

            let pt = vector.subpaths[s].points[a]

            if let prev = pt.previousControl {
                let prevDoc = prev.applying(layerToDoc)
                let prevView = viewport.viewPoint(from: prevDoc, documentSize: document.size)
                let dist = hypot(prevView.x - viewPoint.x, prevView.y - viewPoint.y)
                if dist <= minDistance {
                    minDistance = dist
                    closest = (anchorIdx, .previous)
                }
            }

            if let next = pt.nextControl {
                let nextDoc = next.applying(layerToDoc)
                let nextView = viewport.viewPoint(from: nextDoc, documentSize: document.size)
                let dist = hypot(nextView.x - viewPoint.x, nextView.y - viewPoint.y)
                if dist <= minDistance {
                    minDistance = dist
                    closest = (anchorIdx, .next)
                }
            }
        }

        return closest
    }

    private func hitTestAllHandles(
        in layer: ImageLayer,
        vector: VectorModel,
        viewPoint: CGPoint,
        hitRadius: CGFloat
    ) -> (anchorIndex: VectorAnchorIndex, side: DirectSelectionHandleSide)? {
        guard let document else { return nil }
        let layerToDoc = layer.transform.layerToDocument

        var closest: (anchorIndex: VectorAnchorIndex, side: DirectSelectionHandleSide)?
        var minDistance = hitRadius

        for (s, subpath) in vector.subpaths.enumerated() {
            for (a, pt) in subpath.points.enumerated() {
                let anchorIdx = VectorAnchorIndex(subpathIndex: s, anchorIndex: a)
                if let prev = pt.previousControl {
                    let prevDoc = prev.applying(layerToDoc)
                    let prevView = viewport.viewPoint(from: prevDoc, documentSize: document.size)
                    let dist = hypot(prevView.x - viewPoint.x, prevView.y - viewPoint.y)
                    if dist <= minDistance {
                        minDistance = dist
                        closest = (anchorIdx, .previous)
                    }
                }
                if let next = pt.nextControl {
                    let nextDoc = next.applying(layerToDoc)
                    let nextView = viewport.viewPoint(from: nextDoc, documentSize: document.size)
                    let dist = hypot(nextView.x - viewPoint.x, nextView.y - viewPoint.y)
                    if dist <= minDistance {
                        minDistance = dist
                        closest = (anchorIdx, .next)
                    }
                }
            }
        }

        return closest
    }

    /// Hit-tests for a vector anchor across visible vector layers in screen/view space.
    /// Preserved for full backward compatibility.
    func hitTestVectorAnchor(at viewPoint: CGPoint, hitRadius: CGFloat = 10.0) -> (layerID: UUID, anchor: VectorAnchorIndex)? {
        guard let document else { return nil }

        // 1. Check active layer first if it has vector data and is visible
        if let active = activeLayer, let vector = active.vector, active.isVisible {
            if let hit = hitTestAnchor(in: active, vector: vector, viewPoint: viewPoint, hitRadius: hitRadius) {
                return (active.id, hit)
            }
        }

        // 2. Check other visible vector layers from top to bottom
        for layer in document.layers.reversed() where layer.isVisible && layer.vector != nil && layer.id != activeLayerID {
            guard let vector = layer.vector else { continue }
            if let hit = hitTestAnchor(in: layer, vector: vector, viewPoint: viewPoint, hitRadius: hitRadius) {
                return (layer.id, hit)
            }
        }

        return nil
    }

    private func hitTestAnchor(
        in layer: ImageLayer,
        vector: VectorModel,
        viewPoint: CGPoint,
        hitRadius: CGFloat
    ) -> VectorAnchorIndex? {
        guard let document else { return nil }
        let layerToDoc = layer.transform.layerToDocument

        var closestAnchor: VectorAnchorIndex?
        var minDistance = hitRadius

        for (subpathIndex, subpath) in vector.subpaths.enumerated() {
            for (anchorIndex, pt) in subpath.points.enumerated() {
                let docPt = pt.anchor.applying(layerToDoc)
                let anchorView = viewport.viewPoint(from: docPt, documentSize: document.size)
                let dist = hypot(anchorView.x - viewPoint.x, anchorView.y - viewPoint.y)
                if dist <= minDistance {
                    minDistance = dist
                    closestAnchor = VectorAnchorIndex(subpathIndex: subpathIndex, anchorIndex: anchorIndex)
                }
            }
        }

        return closestAnchor
    }

    /// Selects or toggles an anchor in the given layer.
    func selectVectorAnchor(_ anchor: VectorAnchorIndex, in layerID: UUID, toggle: Bool = false) {
        if activeLayerID != layerID {
            activeLayerID = layerID
        }

        var anchors: Set<VectorAnchorIndex>
        if toggle {
            anchors = vectorSelection?.layerID == layerID ? (vectorSelection?.selectedAnchors ?? []) : []
            if anchors.contains(anchor) {
                anchors.remove(anchor)
            } else {
                anchors.insert(anchor)
            }
        } else {
            anchors = [anchor]
        }

        if anchors.isEmpty {
            vectorSelection = nil
        } else {
            vectorSelection = VectorSelection(layerID: layerID, selectedAnchors: anchors, selectedHandle: nil)
        }
    }

    /// Selects an individual control handle in the given layer.
    func selectVectorHandle(_ handle: SelectedHandle, in layerID: UUID) {
        if activeLayerID != layerID {
            activeLayerID = layerID
        }

        var anchors = vectorSelection?.layerID == layerID ? (vectorSelection?.selectedAnchors ?? []) : []
        anchors.insert(handle.anchorIndex)
        vectorSelection = VectorSelection(layerID: layerID, selectedAnchors: anchors, selectedHandle: handle)
    }

    /// Clears any selected handle while retaining anchor selection.
    func deselectVectorHandle() {
        guard var sel = vectorSelection else { return }
        sel.selectedHandle = nil
        vectorSelection = sel
    }

    /// Clears the anchor and handle selection.
    func deselectVectorAnchors() {
        vectorSelection = nil
        contextualHitTarget = nil
        directSelectionHoverTarget = nil
    }

    /// Updates the transient Direct Selection hover target at the specified view point.
    @discardableResult
    func updateDirectSelectionHover(at viewPoint: CGPoint?) -> DirectSelectionHitTarget? {
        guard tool == .directSelection, canEditLayers, let viewPoint else {
            if directSelectionHoverTarget != nil {
                directSelectionHoverTarget = nil
            }
            return nil
        }
        let target = hitTestDirectSelection(at: viewPoint)
        if directSelectionHoverTarget != target {
            directSelectionHoverTarget = target
        }
        return target
    }

    /// Clears the transient Direct Selection hover target.
    func clearDirectSelectionHover() {
        directSelectionHoverTarget = nil
    }

    /// Evaluates the visual state of a specific anchor for rendering.
    func visualStateForAnchor(_ anchorIndex: VectorAnchorIndex, in layerID: UUID) -> DirectSelectionVisualState {
        let isSelected = vectorSelection?.layerID == layerID && vectorSelection?.selectedAnchors.contains(anchorIndex) == true
        let isHovered = directSelectionHoverTarget?.layerID == layerID
            && directSelectionHoverTarget?.anchorIndex == anchorIndex
            && directSelectionHoverTarget?.kind == .anchor
        switch (isSelected, isHovered) {
        case (false, false): return .unselected
        case (true, false): return .selected
        case (false, true): return .hoveredUnselected
        case (true, true): return .hoveredSelected
        }
    }

    /// Evaluates the visual state of a specific Bézier handle for rendering.
    func visualStateForHandle(_ handle: SelectedHandle, in layerID: UUID) -> DirectSelectionVisualState {
        let isSelected = vectorSelection?.layerID == layerID && vectorSelection?.selectedHandle == handle
        let isHovered = directSelectionHoverTarget?.layerID == layerID
            && directSelectionHoverTarget?.anchorIndex == handle.anchorIndex
            && directSelectionHoverTarget?.kind == .handle(handle.side)
        switch (isSelected, isHovered) {
        case (false, false): return .unselected
        case (true, false): return .selected
        case (false, true): return .hoveredUnselected
        case (true, true): return .hoveredSelected
        }
    }

    /// Resolves the contextual hit target for Direct Selection at a given view point.
    /// Updates transient selection state if targeting an unselected anchor or handle,
    /// without mutating vector geometry, layer transforms, or recording history.
    @discardableResult
    func resolveDirectSelectionContextualTarget(at viewPoint: CGPoint) -> DirectSelectionHitTarget? {
        guard canEditLayers,
              let target = hitTestDirectSelection(at: viewPoint) else {
            contextualHitTarget = nil
            return nil
        }

        contextualHitTarget = target

        switch target.kind {
        case .anchor:
            let isAlreadySelected = vectorSelection?.layerID == target.layerID
                && vectorSelection?.selectedAnchors.contains(target.anchorIndex) == true
            if !isAlreadySelected {
                selectVectorAnchor(target.anchorIndex, in: target.layerID, toggle: false)
            }
        case .handle(let side):
            let handle = SelectedHandle(anchorIndex: target.anchorIndex, side: side)
            selectVectorHandle(handle, in: target.layerID)
        }

        return target
    }

    /// Initiates an anchor drag gesture on the clicked anchor.
    func beginDirectSelectionDrag(
        at docPoint: CGPoint,
        clickedAnchor: VectorAnchorIndex,
        in layerID: UUID,
        toggle: Bool
    ) {
        guard canEditLayers,
              let index = document?.layers.firstIndex(where: { $0.id == layerID }),
              let vector = document?.layers[index].vector else { return }

        directSelectionHoverTarget = nil

        if toggle {
            selectVectorAnchor(clickedAnchor, in: layerID, toggle: true)
            // If it was toggled off, do not initiate drag
            guard let selection = vectorSelection, selection.layerID == layerID,
                  selection.selectedAnchors.contains(clickedAnchor) else { return }
        } else {
            let alreadySelected = vectorSelection?.layerID == layerID
                && vectorSelection?.selectedAnchors.contains(clickedAnchor) == true
            if !alreadySelected {
                selectVectorAnchor(clickedAnchor, in: layerID, toggle: false)
            }
        }

        guard let currentSelection = vectorSelection, currentSelection.layerID == layerID,
              !currentSelection.selectedAnchors.isEmpty else { return }

        directSelectionDrag = DirectSelectionDrag(
            layerID: layerID,
            initialModel: vector,
            currentModel: vector,
            startDocumentPoint: docPoint,
            target: .anchors(currentSelection.selectedAnchors),
            hasMoved: false
        )
    }

    /// Initiates a control handle drag gesture on the clicked handle.
    func beginDirectSelectionHandleDrag(
        at docPoint: CGPoint,
        target: DirectSelectionHitTarget,
        side: DirectSelectionHandleSide
    ) {
        guard canEditLayers,
              let index = document?.layers.firstIndex(where: { $0.id == target.layerID }),
              let vector = document?.layers[index].vector else { return }

        directSelectionHoverTarget = nil

        let handle = SelectedHandle(anchorIndex: target.anchorIndex, side: side)
        selectVectorHandle(handle, in: target.layerID)

        directSelectionDrag = DirectSelectionDrag(
            layerID: target.layerID,
            initialModel: vector,
            currentModel: vector,
            startDocumentPoint: docPoint,
            target: .handle(anchorIndex: target.anchorIndex, side: side),
            hasMoved: false
        )
    }

    /// Updates anchor or handle positions during a drag gesture.
    func dragDirectSelection(to docPoint: CGPoint) {
        guard var drag = directSelectionDrag,
              let index = document?.layers.firstIndex(where: { $0.id == drag.layerID }) else { return }

        let layer = document!.layers[index]
        guard let docToLayer = layer.transform.documentToLayer else { return }

        let startLocal = drag.startDocumentPoint.applying(docToLayer)
        let currentLocal = docPoint.applying(docToLayer)
        let deltaLocal = CGPoint(x: currentLocal.x - startLocal.x, y: currentLocal.y - startLocal.y)

        if hypot(deltaLocal.x, deltaLocal.y) >= 0.5 {
            drag.hasMoved = true
        }

        var updatedModel = drag.initialModel

        switch drag.target {
        case .anchors(let anchors):
            for anchorIdx in anchors {
                let s = anchorIdx.subpathIndex
                let a = anchorIdx.anchorIndex
                guard updatedModel.subpaths.indices.contains(s),
                      updatedModel.subpaths[s].points.indices.contains(a) else { continue }

                let initPt = drag.initialModel.subpaths[s].points[a]
                let newAnchor = CGPoint(x: initPt.anchor.x + deltaLocal.x, y: initPt.anchor.y + deltaLocal.y)
                let newPrev = initPt.previousControl.map { CGPoint(x: $0.x + deltaLocal.x, y: $0.y + deltaLocal.y) }
                let newNext = initPt.nextControl.map { CGPoint(x: $0.x + deltaLocal.x, y: $0.y + deltaLocal.y) }

                updatedModel.subpaths[s].points[a] = VectorPoint(anchor: newAnchor, previousControl: newPrev, nextControl: newNext)
            }

        case .handle(let anchorIdx, let side):
            let s = anchorIdx.subpathIndex
            let a = anchorIdx.anchorIndex
            guard updatedModel.subpaths.indices.contains(s),
                  updatedModel.subpaths[s].points.indices.contains(a) else { break }

            let initPt = drag.initialModel.subpaths[s].points[a]
            switch side {
            case .previous:
                guard let initPrev = initPt.previousControl else { break }
                let newPrev = CGPoint(x: initPrev.x + deltaLocal.x, y: initPrev.y + deltaLocal.y)
                updatedModel.subpaths[s].points[a] = VectorPoint(
                    anchor: initPt.anchor,
                    previousControl: newPrev,
                    nextControl: initPt.nextControl
                )
            case .next:
                guard let initNext = initPt.nextControl else { break }
                let newNext = CGPoint(x: initNext.x + deltaLocal.x, y: initNext.y + deltaLocal.y)
                updatedModel.subpaths[s].points[a] = VectorPoint(
                    anchor: initPt.anchor,
                    previousControl: initPt.previousControl,
                    nextControl: newNext
                )
            }
        }

        drag.currentModel = updatedModel
        directSelectionDrag = drag

        // Live preview update
        document?.layers[index].vector = updatedModel
        redrawVector(at: index)
    }

    /// Ends an anchor or handle drag gesture, recording a single history transaction if moved.
    func endDirectSelectionDrag() {
        guard let drag = directSelectionDrag else { return }
        directSelectionDrag = nil

        guard drag.hasMoved,
              let index = document?.layers.firstIndex(where: { $0.id == drag.layerID }) else {
            // Restore initial model without creating history if no movement occurred
            if let index = document?.layers.firstIndex(where: { $0.id == drag.layerID }) {
                document?.layers[index].vector = drag.initialModel
                redrawVector(at: index)
            }
            return
        }

        // Restore pre-drag state first so beginEdit captures the clean pre-drag snapshot
        document?.layers[index].vector = drag.initialModel

        let actionName: String
        switch drag.target {
        case .anchors:
            actionName = "Move Vector Anchor"
        case .handle:
            actionName = "Move Vector Handle"
        }

        beginEdit(actionName)
        document?.layers[index].vector = drag.currentModel
        redrawVector(at: index)
        endEdit()
    }

    /// Cancels an in-progress anchor drag gesture, restoring original geometry without history.
    func cancelDirectSelectionDrag() {
        guard let drag = directSelectionDrag else { return }
        directSelectionDrag = nil

        if let index = document?.layers.firstIndex(where: { $0.id == drag.layerID }) {
            document?.layers[index].vector = drag.initialModel
            redrawVector(at: index)
        }
    }

    /// Cancels any active Direct Selection interaction and clears selection.
    func cancelDirectSelection() {
        cancelDirectSelectionDrag()
        vectorSelection = nil
        contextualHitTarget = nil
        directSelectionHoverTarget = nil
    }

    /// Deletes the currently selected vector anchors in Direct Selection mode as a single history transaction.
    func deleteSelectedVectorAnchors() {
        guard tool == .directSelection,
              canEditLayers,
              let selection = vectorSelection,
              !selection.selectedAnchors.isEmpty else { return }
        deleteVectorAnchors(selection.selectedAnchors, in: selection.layerID)
    }

    /// Deletes the specified vector anchors from the indicated vector layer as a single history transaction.
    func deleteVectorAnchors(_ toDelete: Set<VectorAnchorIndex>, in layerID: UUID) {
        guard canEditLayers,
              !toDelete.isEmpty,
              let index = document?.layers.firstIndex(where: { $0.id == layerID }),
              let initialModel = document?.layers[index].vector else { return }

        // 1. Group anchor indices to delete by subpathIndex
        var anchorsBySubpath: [Int: Set<Int>] = [:]
        for idx in toDelete {
            anchorsBySubpath[idx.subpathIndex, default: []].insert(idx.anchorIndex)
        }

        // 2. Perform deletion on each subpath
        var newSubpaths: [VectorSubpath] = []
        var emptySubpathsBefore = [Int](repeating: 0, count: initialModel.subpaths.count)
        var cumulativeEmpty = 0

        for (subpathIdx, subpath) in initialModel.subpaths.enumerated() {
            emptySubpathsBefore[subpathIdx] = cumulativeEmpty
            var pts = subpath.points
            if let toDeleteInSubpath = anchorsBySubpath[subpathIdx] {
                let sortedIndices = toDeleteInSubpath.sorted(by: >)
                for aIdx in sortedIndices {
                    if pts.indices.contains(aIdx) {
                        pts.remove(at: aIdx)
                    }
                }
            }

            if pts.isEmpty {
                // Subpath becomes empty -> Remove the empty subpath (Step 7)
                cumulativeEmpty += 1
            } else {
                var updatedSubpath = subpath
                updatedSubpath.points = pts
                if pts.count < 2 {
                    updatedSubpath.isClosed = false
                }
                newSubpaths.append(updatedSubpath)
            }
        }

        var newModel = initialModel
        newModel.subpaths = newSubpaths

        // 3. Record history transaction and apply mutation
        let actionName = toDelete.count == 1 ? "Delete Vector Anchor" : "Delete Vector Anchors"
        beginEdit(actionName)
        document?.layers[index].vector = newModel
        redrawVector(at: index)
        endEdit()

        // 4. Update selection state and clean up handles
        if var sel = vectorSelection, sel.layerID == layerID {
            var remappedAnchors = Set<VectorAnchorIndex>()
            for anchorIdx in sel.selectedAnchors where !toDelete.contains(anchorIdx) {
                let s = anchorIdx.subpathIndex
                let a = anchorIdx.anchorIndex
                guard s < initialModel.subpaths.count else { continue }
                let deletedBeforeInSubpath = anchorsBySubpath[s]?.filter({ $0 < a }).count ?? 0
                let newS = s - emptySubpathsBefore[s]
                let newA = a - deletedBeforeInSubpath
                remappedAnchors.insert(VectorAnchorIndex(subpathIndex: newS, anchorIndex: newA))
            }

            var remappedHandle: SelectedHandle? = nil
            if let handle = sel.selectedHandle, !toDelete.contains(handle.anchorIndex) {
                let s = handle.anchorIndex.subpathIndex
                let a = handle.anchorIndex.anchorIndex
                if s < initialModel.subpaths.count {
                    let deletedBeforeInSubpath = anchorsBySubpath[s]?.filter({ $0 < a }).count ?? 0
                    let newS = s - emptySubpathsBefore[s]
                    let newA = a - deletedBeforeInSubpath
                    remappedHandle = SelectedHandle(
                        anchorIndex: VectorAnchorIndex(subpathIndex: newS, anchorIndex: newA),
                        side: handle.side
                    )
                }
            }

            if remappedAnchors.isEmpty {
                vectorSelection = nil
            } else {
                vectorSelection = VectorSelection(
                    layerID: layerID,
                    selectedAnchors: remappedAnchors,
                    selectedHandle: remappedHandle
                )
            }
        }

        // 5. Clean up contextual hit target if it targeted a deleted anchor/handle
        if let target = contextualHitTarget, target.layerID == layerID {
            if toDelete.contains(target.anchorIndex) {
                contextualHitTarget = nil
            }
        }
    }

    /// Re-renders the raster asset and thumbnail for the vector layer at the specified index.
    func redrawVector(at index: Int) {
        guard let layer = document?.layers[index],
              let vector = layer.vector,
              let asset = layer.asset else { return }

        let size = CGSize(width: max(1, layer.transform.size.width.rounded()),
                          height: max(1, layer.transform.size.height.rounded()))
        guard let image = try? VectorRenderer.render(vector, in: size),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }

        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
    }
}
