import CoreGraphics
import Foundation

/// The Move tool's Align and Distribute commands, as in Photoshop.
nonisolated enum LayerAlignment: String, CaseIterable, Sendable {
    case left = "Left Edges", horizontalCenter = "Horizontal Centers", right = "Right Edges"
    case top = "Top Edges", verticalCenter = "Vertical Centers", bottom = "Bottom Edges"

    var symbol: String {
        switch self {
        case .left: return "align.horizontal.left"
        case .horizontalCenter: return "align.horizontal.center"
        case .right: return "align.horizontal.right"
        case .top: return "align.vertical.top"
        case .verticalCenter: return "align.vertical.center"
        case .bottom: return "align.vertical.bottom"
        }
    }

    /// How far `box` moves to line up with `target`.
    func offset(of box: CGRect, to target: CGRect) -> CGSize {
        switch self {
        case .left: return CGSize(width: target.minX - box.minX, height: 0)
        case .horizontalCenter: return CGSize(width: target.midX - box.midX, height: 0)
        case .right: return CGSize(width: target.maxX - box.maxX, height: 0)
        case .top: return CGSize(width: 0, height: target.minY - box.minY)
        case .verticalCenter: return CGSize(width: 0, height: target.midY - box.midY)
        case .bottom: return CGSize(width: 0, height: target.maxY - box.maxY)
        }
    }
}

nonisolated enum LayerDistribution: String, CaseIterable, Sendable {
    case horizontalCenters = "Horizontal Centers", verticalCenters = "Vertical Centers"
    case horizontalSpacing = "Horizontal Spacing", verticalSpacing = "Vertical Spacing"

    var symbol: String {
        switch self {
        case .horizontalCenters: return "distribute.horizontal.center"
        case .verticalCenters: return "distribute.vertical.center"
        case .horizontalSpacing: return "distribute.horizontal.fill"
        case .verticalSpacing: return "distribute.vertical.fill"
        }
    }
    var isHorizontal: Bool { self == .horizontalCenters || self == .horizontalSpacing }

    /// How far each of `boxes` moves, in their order. The outermost two stay put and the rest are spread evenly
    /// between them: their middles, or the gaps between them.
    func offsets(of boxes: [CGRect]) -> [CGSize] {
        guard boxes.count > 2 else { return boxes.map { _ in .zero } }
        let start = { (box: CGRect) in isHorizontal ? box.minX : box.minY }
        let length = { (box: CGRect) in isHorizontal ? box.width : box.height }
        let order = boxes.indices.sorted { start(boxes[$0]) + length(boxes[$0]) / 2 < start(boxes[$1]) + length(boxes[$1]) / 2 }
        let first = boxes[order.first!], last = boxes[order.last!]
        var offsets = boxes.map { _ in CGSize.zero }
        let steps = CGFloat(order.count - 1)
        switch self {
        case .horizontalCenters, .verticalCenters:
            let from = start(first) + length(first) / 2, to = start(last) + length(last) / 2
            for (rank, index) in order.enumerated() {
                let middle = from + (to - from) * CGFloat(rank) / steps
                let delta = middle - (start(boxes[index]) + length(boxes[index]) / 2)
                offsets[index] = isHorizontal ? CGSize(width: delta, height: 0) : CGSize(width: 0, height: delta)
            }
        case .horizontalSpacing, .verticalSpacing:
            let span = start(last) + length(last) - start(first)
            let gap = (span - order.reduce(0) { $0 + length(boxes[$1]) }) / steps
            var position = start(first)
            for index in order {
                let delta = position - start(boxes[index])
                offsets[index] = isHorizontal ? CGSize(width: delta, height: 0) : CGSize(width: 0, height: delta)
                position += length(boxes[index]) + gap
            }
        }
        return offsets
    }
}

extension EditorSession {
    /// What Align and Distribute move: each selected layer on its own, and each selected folder's contents as one,
    /// with the upright box around them. A layer inside a selected folder moves with the folder.
    var alignmentItems: [(members: [ImageLayer], box: CGRect)] {
        guard let document, canEditLayers else { return [] }
        let visible = document.effectiveVisibleIDs
        let parents = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0.parentID) })
        func selectedAncestor(of id: UUID) -> UUID? {
            var current = parents[id] ?? nil
            for _ in 0..<64 {
                guard let parent = current else { return nil }
                if selectedLayerIDs.contains(parent) { return parent }
                current = parents[parent] ?? nil
            }
            return nil
        }
        // Each moving layer, under the outermost selected folder above it, or itself.
        var groups: [UUID: [ImageLayer]] = [:]
        var order: [UUID] = []
        for layer in document.layers where layer.asset != nil && !layer.isGroup && visible.contains(layer.id) {
            var owner = selectedLayerIDs.contains(layer.id) ? layer.id : nil
            var ancestor = selectedAncestor(of: layer.id)
            while let folder = ancestor { owner = folder; ancestor = selectedAncestor(of: folder) }
            guard let owner else { continue }
            if groups[owner] == nil { order.append(owner) }
            groups[owner, default: []].append(layer)
        }
        return order.compactMap { owner in
            guard let members = groups[owner] else { return nil }
            let box = members.map { layer in
                let points = DistortWarp.corners(of: layer.transform)
                let xs = points.map(\.x), ys = points.map(\.y)
                return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            }.reduce(CGRect.null) { $0.union($1) }
            return (members, box)
        }
    }

    /// Align lines things up with the selection when there is one, with the canvas when one thing is selected, and
    /// otherwise with the box around them all.
    /// Cheap enough for menus and buttons to ask on every redraw; the commands themselves find what moves.
    var canAlignLayers: Bool { canEditLayers && !selectedLayerIDs.isEmpty }
    var canDistributeLayers: Bool { canEditLayers && selectedLayerIDs.count > 2 }

    func alignLayers(_ alignment: LayerAlignment) {
        commitTransform()
        let items = alignmentItems
        guard let document, !items.isEmpty else { return }
        let target: CGRect
        if let selection, !selection.isEmpty { target = selection.path.boundingBoxOfPath }
        else if items.count == 1 { target = CGRect(origin: .zero, size: document.size) }
        else { target = items.map(\.box).reduce(CGRect.null) { $0.union($1) } }
        move(items, by: items.map { alignment.offset(of: $0.box, to: target) }, name: "Align " + alignment.rawValue)
    }

    func distributeLayers(_ distribution: LayerDistribution) {
        commitTransform()
        let items = alignmentItems
        guard items.count > 2 else { return }
        move(items, by: distribution.offsets(of: items.map(\.box)), name: "Distribute " + distribution.rawValue)
    }

    /// Moves each item's layers by its offset, rounded to whole pixels so nothing lands between them and has to be
    /// resampled, as one undo step. Masks follow their link, as they do in a move.
    private func move(_ items: [(members: [ImageLayer], box: CGRect)], by offsets: [CGSize], name: String) {
        var moves: [UUID: CGSize] = [:]
        for (item, offset) in zip(items, offsets) {
            let whole = CGSize(width: offset.width.rounded(), height: offset.height.rounded())
            guard whole != .zero else { continue }
            for layer in item.members { moves[layer.id] = whole }
        }
        guard !moves.isEmpty, let document else { return }
        finishOpacityEdit()
        beginEdit(name)
        for index in document.layers.indices {
            let layer = document.layers[index]
            guard let offset = moves[layer.id] else { continue }
            var moved = layer.transform
            moved.origin.x += offset.width
            moved.origin.y += offset.height
            if let mask = layer.mask {
                self.document?.layers[index].mask?.placement = mask.placement(movingLayer: layer.transform, to: moved)
            }
            self.document?.layers[index].transform = moved
        }
        endEdit()
    }
}