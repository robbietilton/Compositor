import CoreGraphics
import Foundation

extension EditorSession {
    func projectSnapshot() -> ProjectSnapshot? { projectSnapshot(of: document, activeLayerID: activeLayerID) }

    /// What a save made while editing goes on writes: the project as its last finished edit left it. An edit still
    /// open, as a selection being transformed or an adjustment layer being edited holds one, isn't in it, so the file
    /// never has it half done. Text being typed is in it as Done would put it, though it's still open.
    func saveSnapshot() -> ProjectSnapshot? {
        if let before = history.beforeOpenEdit {
            return projectSnapshot(of: before.document, activeLayerID: before.activeLayerID)
        }
        if let draft = textDraft, let applied = try? applyingText(draft) {
            return projectSnapshot(of: applied.document, activeLayerID: applied.activeLayerID)
        }
        return projectSnapshot()
    }

    func projectSnapshot(of document: CanvasDocument?, activeLayerID: UUID?) -> ProjectSnapshot? {
        guard let document else { return nil }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        let layers = document.layers.map { layer in
            if let asset = layer.asset { images[layer.id] = asset }
            if let mask = layer.mask { masks[layer.id] = mask.asset }
            return ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: layer.transform, imageFile: layer.asset == nil ? nil : "\(layer.id.uuidString).png", parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png", maskEnabled: layer.mask?.isEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement, maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style, effects: layer.effects, text: layer.liveText?.style)
        }
        return ProjectSnapshot(manifest: ProjectManifest(resolution: document.resolution, documentID: document.id, width: document.width,
            height: document.height, activeLayerID: activeLayerID, layers: layers,
            guides: document.guides.isEmpty ? nil : document.guides), images: images, masks: masks)
    }

    /// Called only after the entire package has successfully validated and loaded.
    func installProject(_ snapshot: ProjectSnapshot, from url: URL) {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        guideDrag = nil
        transformEdit = nil
        document = CanvasDocument(project: snapshot)
        activeLayerID = snapshot.manifest.activeLayerID
        projectURL = url
        renamingLayerID = nil
        history.reset()
        viewport.fit(documentSize: document!.size)
    }

    /// Replaces the document with what its package holds now, after something else wrote it. Unlike `installProject`
    /// it keeps the viewport, the collapsed folders and the selection where those layers still exist, so the
    /// reload is invisible beyond the change itself. Undo history is session-only and starts over, as after an open.
    func reloadProject(_ snapshot: ProjectSnapshot) {
        guard let url = projectURL else { return }
        let viewport = self.viewport
        let collapsed = collapsedGroupIDs
        let active = activeLayerID
        let selected = selectedLayerIDs
        installProject(snapshot, from: url)
        self.viewport = viewport
        let ids = Set(snapshot.manifest.layers.map(\.id))
        collapsedGroupIDs = collapsed.intersection(ids)
        if let active, ids.contains(active) {
            activeLayerID = active
            selectedLayerIDs = selected.intersection(ids).union([active])
        }
    }

    /// Readies the project for quitting or closing, rather than refusing over what's in progress. Edits on the canvas
    /// (a gradient waiting for Apply, pixels being moved) are applied, as switching tools does; an open dialog (a filter,
    /// Levels, Hue/Saturation, a layer effect, the color picker…) is canceled, as its Cancel button would, so nothing is
    /// applied that wasn't OK'd. A layer effect's panel can stay open beside other dialogs, some of which keep layers
    /// from being edited, so it's canceled after those, or its Cancel couldn't put the layer back; while the project is
    /// still busy it can't, so the panel stays open rather than closing over an effect that was never OK'd.
    func settlePendingEdits() async {
        if gradientEdit != nil { await commitGradient() }
        if pixelMove != nil { await finishPixelMove() }
        cancelFilter()
        cancelHueSaturation()
        cancelLevels()
        finishAdjustmentEditing(commit: false)
        cancelColorRange()
        selectionAmountOperation = nil
        if canEditBesideCanvasEdits { finishEffectsEditing(commit: false) }
        if colorPicker != nil { closeColorPicker(commit: false) }
    }

    func clearProject() {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        transformEdit = nil
        guideDrag = nil
        document = nil
        activeLayerID = nil
        renamingLayerID = nil
        projectURL = nil
        history.reset()
    }

    func createNewProject(width: Int, height: Int) {
        guard !isProjectBusy, !isImporting, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else { return }
        clearProject()
        createDocument(width: width, height: height, emptyLayer: true)
    }
}

extension CanvasDocument {
    /// The document a project's snapshot describes, its layers holding the snapshot's own images.
    init(project snapshot: ProjectSnapshot) {
        let manifest = snapshot.manifest
        self.init(id: manifest.documentID, width: manifest.width, height: manifest.height,
            layers: manifest.layers.map {
                ImageLayer(id: $0.id, asset: snapshot.images[$0.id], name: $0.name,
                           isVisible: $0.isVisible, transform: $0.transform, parentID: $0.parentID, isGroup: $0.isGroup == true, opacity: $0.opacity ?? 1, blendMode: $0.blendMode ?? .normal, mask: snapshot.mask(for: $0), maskSourceID: $0.maskSourceID, adjustment: $0.adjustment,
                           shape: LayerShape.loaded($0.shape, image: snapshot.images[$0.id]?.image),
                           effects: $0.effects,
                           text: LayerText.loaded($0.text, image: snapshot.images[$0.id]?.image))
            }, resolution: manifest.resolution ?? 72, guides: manifest.guides ?? [])
    }

    /// The images the GPU canvas's first frame draws from, for a document just put in an editor, as both platforms'
    /// canvases draw them: the pixels of each layer that shows, and of the layers it takes its mask from in turn, shown
    /// or not; their own masks, but not one placed apart from its layer, which is drawn from a copy resampled for the
    /// view; the masks of adjustments; and the masks of the folders the layers and adjustments drawn are in, but not one
    /// too large for a texture, which the frame leaves out. A clipping stack over a layer without pixels draws nothing,
    /// nor does an adjustment clipped to a layer outside one. Once a layer's effects are worked out, the canvas draws
    /// that layer from them instead.
    var canvasSources: [GPUTextureSource] {
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        let ids = renderLayers.map(\.id)
        var sources: [GPUTextureSource] = [], seen = Set<ObjectIdentifier>(), folders = Set<UUID>()
        func add(_ image: CGImage?, mask: Bool) {
            guard let image, seen.insert(ObjectIdentifier(image)).inserted else { return }
            sources.append(GPUTextureSource(image: image, mask: mask))
        }
        // A layer's own pixels and mask; false for one without pixels, which draws nothing.
        func own(_ layer: ImageLayer) -> Bool {
            guard let asset = layer.asset else { return false }
            if asset.raster == nil { add(asset.image, mask: false) }
            if let mask = layer.mask, mask.placement.map({ $0.samePlacement(as: layer.transform) }) ?? true {
                add(mask.enabledImage, mask: true)
            }
            return true
        }
        // A folder's or an adjustment's mask, which a frame leaves out when it's too large for a texture.
        func addMask(of layer: ImageLayer?) {
            guard let image = layer?.mask?.enabledImage,
                  max(image.width, image.height) <= GPUCanvasRenderer.largestTexture else { return }
            add(image, mask: true)
        }
        func inFolders(_ layer: ImageLayer) {
            var folder = layer.parentID
            while let id = folder, folders.insert(id).inserted {
                addMask(of: byID[id])
                folder = byID[id]?.parentID
            }
        }
        // Clipping stacks, as the canvases find them: a layer, not an adjustment, taking no mask, and the run of layers
        // just above it in its folder that take theirs from it.
        var stacks: [UUID: [ImageLayer]] = [:], stacked = Set<UUID>()
        for (index, id) in ids.enumerated() {
            guard let base = byID[id], base.maskSourceID == nil, base.adjustment == nil else { continue }
            var children: [ImageLayer] = []
            for childID in ids.dropFirst(index + 1) {
                guard let child = byID[childID], child.maskSourceID == id, child.parentID == base.parentID else { break }
                children.append(child)
            }
            guard !children.isEmpty else { continue }
            stacks[id] = children
            stacked.formUnion(children.map(\.id))
        }
        for id in ids where !stacked.contains(id) {
            guard let layer = byID[id] else { continue }
            if layer.adjustment != nil {
                guard layer.maskSourceID == nil else { continue }
                addMask(of: layer)
            } else if let children = stacks[id] {
                guard own(layer) else { continue }
                for child in children {
                    if child.adjustment != nil { addMask(of: child) } else { _ = own(child) }
                }
            } else {
                guard layer.asset != nil else { continue }
                var next: ImageLayer? = layer, visited = Set<UUID>()
                while let current = next, visited.insert(current.id).inserted, own(current) {
                    next = current.maskSourceID.flatMap { byID[$0] }
                }
            }
            inFolders(layer)
        }
        return sources
    }
}
