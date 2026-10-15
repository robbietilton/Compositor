import Foundation
import CoreGraphics

extension EditorSession {
    func projectSnapshot() -> ProjectSnapshot? {
        guard let document else { return nil }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        let layers = document.layers.map { layer in
            if let asset = layer.asset { images[layer.id] = asset }
            if let mask = layer.mask { masks[layer.id] = mask.asset }
            return ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: layer.transform, imageFile: layer.asset?.file(for: layer.id), parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png", maskEnabled: layer.mask?.isEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement, maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style, vectorPath: layer.liveVectorPath?.style, effects: layer.effects, text: layer.liveText?.style)
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
        let manifest = snapshot.manifest
        transformEdit = nil
        document = CanvasDocument(id: manifest.documentID, width: manifest.width, height: manifest.height,
            layers: snapshot.documentLayers, resolution: manifest.resolution ?? 72, guides: manifest.guides ?? [])
        activeLayerID = manifest.activeLayerID
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

    func createNewProject(width: Int, height: Int, resolution: Double = 72, background: CGColor? = nil) {
        guard !isProjectBusy, !isImporting, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else { return }
        clearProject()
        createDocument(width: width, height: height, emptyLayer: true, resolution: resolution, background: background)
    }
}

extension ProjectSnapshot {
    /// The layers the manifest records, each with its pixels, mask, effects and live text or shape. Opening a project
    /// and the edits that rebuild the document from a snapshot (canvas and image size, crop, trim) all build them here,
    /// so none of them leaves part of a layer behind.
    var documentLayers: [ImageLayer] {
        manifest.layers.map { record in
            ImageLayer(id: record.id, asset: images[record.id], name: record.name,
                       isVisible: record.isVisible, transform: record.transform, parentID: record.parentID, isGroup: record.isGroup == true, opacity: record.opacity ?? 1, blendMode: record.blendMode ?? .normal, mask: mask(for: record), maskSourceID: record.maskSourceID, adjustment: record.adjustment,
                       shape: LayerShape.loaded(record.shape, image: images[record.id]?.image),
                       vectorPath: images[record.id].flatMap { image in
                           record.vectorPath.flatMap { stored in
                               var style = stored
                               if manifest.version == 14, style.fill == nil, style.brushStroke == nil {
                                   if style.closed {
                                       style.fill = LayerVectorPathFill(red: style.red, green: style.green, blue: style.blue)
                                   } else {
                                       style.brushStroke = LayerVectorPathBrushStroke(
                                           red: style.red, green: style.green, blue: style.blue,
                                           diameter: min(style.lineWidth, 2_100), hardness: 1, opacity: 1
                                       )
                                   }
                               }
                               return LayerVectorPath.loaded(style: style, image: image.image)
                           }
                       },
                       effects: record.effects,
                       text: LayerText.loaded(record.text, image: images[record.id]?.image))
        }
    }
}
