import AppKit

/// Layers: adding them (empty, from an image, folders), changing what they are and how they draw, and arranging them.
extension AgentTools {
    static var layerTools: [AgentTool] {
        [
            AgentTool(name: "add_layer",
                      description: """
                        Adds a layer above the selected one (or above `above_layer_id`), in the same folder; above a \
                        folder, it goes inside it. `type` "image" brings in a picture given as base64 `image_data` or a \
                        file `path` (PNG, JPEG, HEIC, WebP, TIFF, GIF, SVG, PDF, PSD, camera RAW), centered unless \
                        `x`/`y` place its top-left corner, at its own size unless `width`/`height` scale it. "blank" is \
                        an empty layer, "folder" an empty folder. Answers with the new layer.
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "type": Schema.string("What to add.", oneOf: ["image", "blank", "folder"]),
                        "name": Schema.string("The layer's name."),
                        "image_data": Schema.string("For an image: its file's bytes, base64 (a data: URL is fine too)."),
                        "path": Schema.string("For an image: a file inside a folder granted in Agent Access."),
                        "above_layer_id": Schema.string("Put it above this layer. Omitted: above the selected one."),
                        "x": Schema.number("Left edge, in document pixels."),
                        "y": Schema.number("Top edge, in document pixels."),
                        "width": Schema.number("Width to scale to; alone, the height follows in proportion."),
                        "height": Schema.number("Height to scale to; alone, the width follows in proportion."),
                      ], required: ["type"])) { call in
                let session = try call.session()
                if let above = try call.id("above_layer_id") {
                    guard session.document?.layers.contains(where: { $0.id == above }) == true else { throw AgentError("No layer has id \(above.uuidString).") }
                    session.selectLayer(above)
                }
                let before = Set(session.document?.layers.map(\.id) ?? [])
                session.beginEdit("Add Layer")
                defer { session.endEdit() }
                switch try call.requiredString("type") {
                case "blank": session.addBlankLayer()
                case "folder": session.addGroup()
                case "image": try await importImage(call, into: session)
                case let other: throw AgentError("`type` is image, blank or folder, not “\(other)”.")
                }
                // The topmost of what came in that isn't inside something else that came in (a Photoshop file's folder).
                guard let added = session.document?.layers.last(where: { !before.contains($0.id) && $0.parentID.map(before.contains) != false }) else {
                    throw AgentError(takeError(session) ?? "Nothing was added.")
                }
                if let name = try call.string("name") { session.renameLayer(added.id, to: name) }
                if call.has("x") || call.has("y") || call.has("width") || call.has("height") {
                    try place(added.id, in: session, call: call)
                }
                return .json(try describe(session.document?.layers.first { $0.id == added.id } ?? added, in: session))
            },
            AgentTool(name: "update_layer",
                      description: """
                        Changes a layer, as one undo step: any of `name`, `visible`, `opacity` (0–1), `blend_mode`, \
                        `transform`, `effects` and `adjustment`. `transform`, `effects` and `adjustment` take only the \
                        fields to change, in the shape get_document shows (a .comp manifest's): e.g. {"origin": [10, 20]}, \
                        {"stroke": {"size": 6, "red": 1, "green": 0, "blue": 0}} or {"exposureSettings": {"exposure": 0.5}}. \
                        An effect set to null is removed. Blend modes: \(LayerBlendMode.allCases.map(\.rawValue).joined(separator: ", ")).
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "layer_id": Schema.layer,
                        "name": Schema.string("A new name."),
                        "visible": Schema.boolean("Shown or hidden."),
                        "opacity": Schema.number("0–1."),
                        "blend_mode": Schema.string("How it blends with what's below.", oneOf: LayerBlendMode.allCases.map(\.rawValue)),
                        "transform": Schema.anyObject("origin [x, y] (top-left), size [width, height], rotation (degrees clockwise), flipX, flipY, sampling."),
                        "effects": Schema.anyObject("stroke, shadow, colorOverlay, innerShadow, outerGlow, innerGlow: each partial, or null to remove."),
                        "adjustment": Schema.anyObject("For an adjustment layer: its settings, partial."),
                      ])) { call in
                let session = try call.session()
                let layer = try call.layer(in: session)
                guard let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else { throw AgentError("The layer is gone.") }
                var edited = layer
                if let name = try call.string("name") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { throw AgentError("A layer's name can't be empty.") }
                    edited.name = trimmed
                }
                if let visible = try call.bool("visible") { edited.isVisible = visible }
                if let opacity = try call.double("opacity") {
                    guard (0...1).contains(opacity) else { throw AgentError("Opacity runs from 0 to 1.") }
                    edited.opacity = opacity
                }
                if let mode = try call.string("blend_mode") {
                    guard let blend = LayerBlendMode(rawValue: mode) else { throw AgentError("“\(mode)” isn't a blend mode. They are: \(LayerBlendMode.allCases.map(\.rawValue).joined(separator: ", ")).") }
                    // Folders pass what's inside them through, so only Normal fits them.
                    guard !edited.isGroup || blend == .normal else { throw AgentError("A folder's blend mode stays Normal; set the layers inside it.") }
                    edited.blendMode = blend
                }
                if let patch = call.arguments["transform"], !patch.isNull {
                    let transform = try patched(layer.transform, with: patch)
                    guard transform.isValid else { throw AgentError("That transform is out of range: sizes 1–300,000 pixels, positions within ±1,000,000.") }
                    if let mask = layer.mask { edited.mask?.placement = mask.placement(movingLayer: layer.transform, to: transform) }
                    edited.transform = transform
                }
                if let patch = call.arguments["effects"], !patch.isNull {
                    let all = LayerEffects(stroke: StrokeEffect(), shadow: ShadowEffect(), colorOverlay: ColorOverlayEffect(),
                                           innerShadow: InnerShadowEffect(), outerGlow: OuterGlowEffect(), innerGlow: InnerGlowEffect())
                    let effects = try patched(layer.effects ?? LayerEffects(), with: patch, seeds: all)
                    guard effects.isValid else { throw AgentError("Those effect settings are out of range: colors and opacity 0–1, sizes 0–500.") }
                    edited.effects = effects.isEmpty ? nil : effects
                }
                if let patch = call.arguments["adjustment"], !patch.isNull {
                    guard let adjustment = layer.adjustment else { throw AgentError("Only an adjustment layer has adjustment settings.") }
                    let value = try patched(adjustment, with: patch, seeds: seededAdjustment(adjustment))
                    guard value.kind == adjustment.kind else { throw AgentError("An adjustment layer keeps its kind; add a new one for another.") }
                    guard value.isValid else { throw AgentError("Those adjustment settings are out of range; see docs/project-format.md for each one's.") }
                    edited.adjustment = value
                }
                session.beginEdit("Change Layer")
                session.document?.layers[index] = edited
                if edited.transform != layer.transform { session.redrawShape(at: index) }
                session.endEdit()
                return .json(try describe(session.document?.layers[index] ?? edited, in: session))
            },
            AgentTool(name: "select_layers",
                      description: "Selects layers, as clicking them in the Layers panel does; the first becomes the active layer, which tools and menu commands act on.",
                      schema: Schema.object(["document": Schema.document, "layer_ids": Schema.layers], required: ["layer_ids"])) { call in
                let session = try call.session()
                let ids = try existing(call.ids("layer_ids"), in: session)
                session.selectLayers(Set(ids), primary: ids.first)
                return .text("Selected \(ids.count) layer\(ids.count == 1 ? "" : "s").")
            },
            AgentTool(name: "delete_layers",
                      description: "Deletes layers (a folder with everything in it), as one undo step.",
                      schema: Schema.object(["document": Schema.document, "layer_ids": Schema.layers], required: ["layer_ids"])) { call in
                let session = try call.session()
                let ids = try existing(call.ids("layer_ids"), in: session)
                session.selectLayers(Set(ids), primary: ids.first)
                session.deleteSelectedLayers()
                let left = ids.filter { id in session.document?.layers.contains { $0.id == id } == true }
                guard left.isEmpty else { throw AgentError(takeError(session) ?? "Not every layer was deleted: one may be the base of a clipping mask, which asks the person what to do.") }
                return .text("Deleted \(ids.count) layer\(ids.count == 1 ? "" : "s").")
            },
            AgentTool(name: "duplicate_layers",
                      description: "Copies layers (a folder with what's in it), each just above its original. Answers with the copies.",
                      schema: Schema.object(["document": Schema.document, "layer_ids": Schema.layers], required: ["layer_ids"])) { call in
                let session = try call.session()
                let ids = try existing(call.ids("layer_ids"), in: session)
                let before = Set(session.document?.layers.map(\.id) ?? [])
                session.duplicateLayers(ids, editName: ids.count > 1 ? "Duplicate Layers" : "Duplicate Layer")
                let copies = session.document?.layers.filter { !before.contains($0.id) } ?? []
                return .json(.array(try copies.map { try describe($0, in: session) }))
            },
            AgentTool(name: "group_layers",
                      description: "Puts layers in a new folder, where the topmost of them was. Answers with the folder.",
                      schema: Schema.object(["document": Schema.document, "layer_ids": Schema.layers,
                                             "name": Schema.string("The folder's name.")], required: ["layer_ids"])) { call in
                let session = try call.session()
                let ids = try existing(call.ids("layer_ids"), in: session)
                let before = Set(session.document?.layers.map(\.id) ?? [])
                session.beginEdit("Group Layers")
                defer { session.endEdit() }
                session.selectLayers(Set(ids), primary: ids.first)
                session.groupSelectedLayers()
                guard let folder = session.document?.layers.first(where: { !before.contains($0.id) && $0.isGroup }) else {
                    throw AgentError("Those layers couldn't be grouped together; they may be in different folders.")
                }
                if let name = try call.string("name") { session.renameLayer(folder.id, to: name) }
                return .json(try describe(session.document?.layers.first { $0.id == folder.id } ?? folder, in: session))
            },
            AgentTool(name: "merge_layers",
                      description: "Merges layers into one pixel layer, as Layer › Merge Layers does (one layer: Merge Down, into the layer below; a folder: Merge Group).",
                      schema: Schema.object(["document": Schema.document, "layer_ids": Schema.layers], required: ["layer_ids"])) { call in
                let session = try call.session()
                let ids = try existing(call.ids("layer_ids"), in: session)
                let revision = session.history.currentRevision
                session.selectLayers(Set(ids), primary: ids.first)
                session.mergeLayers()
                guard session.history.currentRevision != revision else { throw AgentError(takeError(session) ?? "Those layers can't be merged.") }
                return .json(try describe(session.activeLayer ?? call.layer(in: session), in: session))
            },
            AgentTool(name: "move_layer",
                      description: "Moves a layer among the others in its folder: one step up or down, or to the top or bottom.",
                      schema: Schema.object(["document": Schema.document, "layer_id": Schema.layer,
                                             "to": Schema.string("Where to.", oneOf: ["up", "down", "top", "bottom"])], required: ["to"])) { call in
                let session = try call.session()
                let layer = try call.layer(in: session)
                session.selectLayer(layer.id)
                let to = try call.requiredString("to")
                let step: Int
                switch to {
                case "up", "top": step = 1
                case "down", "bottom": step = -1
                default: throw AgentError("`to` is up, down, top or bottom.")
                }
                guard session.canMoveActiveLayer(by: step) else { return .text("It's already at the \(step > 0 ? "top" : "bottom") of its folder.") }
                session.beginEdit("Reorder Layers")
                repeat { session.moveActiveLayer(by: step) } while (to == "top" || to == "bottom") && session.canMoveActiveLayer(by: step)
                session.endEdit()
                return .text("Moved “\(layer.name)” \(to).")
            },
            AgentTool(name: "add_mask",
                      description: """
                        Adds a layer mask to a layer that has none. With a selection, it reveals the selection (or hides it, \
                        with `reveal` false) and the selection is used up; without one, it reveals or hides the whole layer.
                        """,
                      schema: Schema.object(["document": Schema.document, "layer_id": Schema.layer,
                                             "reveal": Schema.boolean("White (shows) where selected; false for black. Default true.")])) { call in
                let session = try call.session()
                let layer = try call.layer(in: session)
                guard layer.mask == nil else { throw AgentError("That layer already has a mask.") }
                session.selectLayer(layer.id)
                session.addMask(revealing: try call.bool("reveal") ?? true)
                guard session.activeLayer?.mask != nil else { throw AgentError(takeError(session) ?? "A mask can't be added to that layer.") }
                return .text("Added a mask to “\(layer.name)”.")
            },
        ]
    }

    /// `ids`, each checked to be a layer of the document.
    static func existing(_ ids: [UUID], in session: EditorSession) throws -> [UUID] {
        guard !ids.isEmpty else { throw AgentError("Name at least one layer.") }
        let present = Set(session.document?.layers.map(\.id) ?? [])
        if let missing = ids.first(where: { !present.contains($0) }) { throw AgentError("No layer has id \(missing.uuidString).") }
        return ids
    }

    /// An adjustment with every group of settings filled in, from which a patch can start a group the layer hasn't
    /// stored yet.
    static func seededAdjustment(_ adjustment: LayerAdjustment) -> LayerAdjustment {
        var seeded = adjustment
        seeded.hsvSettings = adjustment.resolvedHSV
        seeded.exposureSettings = adjustment.exposure
        seeded.gradientMapSettings = adjustment.gradientMap
        seeded.grainSettings = adjustment.grain
        seeded.blackWhiteSettings = adjustment.blackWhite
        seeded.colorBalanceSettings = adjustment.colorBalance
        seeded.filterLayerSettings = adjustment.filterLayer
        return seeded
    }

    /// Brings an image in as a layer of `session`, from base64 or a file, the way dropping a file does, but without the
    /// sheets that ask the person first (a Photoshop file's conversion report, a RAW's develop settings).
    private static func importImage(_ call: AgentCall, into session: EditorSession) async throws {
        var folder: URL?
        defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
        let file: URL
        if let encoded = try call.string("image_data") {
            let base64 = encoded.hasPrefix("data:") ? String(encoded.drop { $0 != "," }.dropFirst()) : encoded
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
                throw AgentError("`image_data` isn't base64.")
            }
            guard let fileExtension = AgentImage.fileExtension(of: data) else {
                throw AgentError("`image_data` isn't an image Compositor reads: PNG, JPEG, HEIC, WebP, TIFF, GIF, SVG, PDF or PSD.")
            }
            let made = FileManager.default.temporaryDirectory.appendingPathComponent("Agent Images/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            folder = made
            // The file's name becomes the layer's.
            let name = (try call.string("name") ?? "Image").replacingOccurrences(of: "/", with: "-")
            file = made.appendingPathComponent(name).appendingPathExtension(fileExtension)
            try data.write(to: file)
        } else if let path = try call.string("path") {
            file = try AgentFolders.url(for: path)
            guard FileManager.default.fileExists(atPath: file.path) else { throw AgentError("Nothing at \(file.path).") }
        } else {
            throw AgentError("An image layer needs `image_data` or `path`.")
        }
        let conversions = session.confirmConversions, develop = session.confirmRawDevelop
        session.confirmConversions = { _ in true }
        session.confirmRawDevelop = { _, settings in settings }
        defer { session.confirmConversions = conversions; session.confirmRawDevelop = develop }
        await session.importImages([file])
        if let error = takeError(session) { throw AgentError("The image couldn't be brought in: \(error)") }
    }

    /// Places a new layer where the call's `x`, `y`, `width` and `height` say.
    private static func place(_ id: UUID, in session: EditorSession, call: AgentCall) throws {
        guard let index = session.document?.layers.firstIndex(where: { $0.id == id }), var layer = session.document?.layers[index] else { return }
        var transform = layer.transform
        let aspect = transform.size.width / max(1, transform.size.height)
        let width = try call.double("width"), height = try call.double("height")
        switch (width, height) {
        case let (width?, height?): transform.size = CGSize(width: width, height: height)
        case let (width?, nil): transform.size = CGSize(width: width, height: width / aspect)
        case let (nil, height?): transform.size = CGSize(width: height * aspect, height: height)
        default: break
        }
        // Scaled about its center when no position is given, as it was placed centered.
        let center = layer.transform.center
        transform.origin = CGPoint(x: try call.double("x") ?? center.x - transform.size.width / 2,
                                   y: try call.double("y") ?? center.y - transform.size.height / 2)
        guard transform.isValid else { throw AgentError("That size or position is out of range.") }
        if let mask = layer.mask { layer.mask?.placement = mask.placement(movingLayer: layer.transform, to: transform) }
        layer.transform = transform
        session.document?.layers[index] = layer
        session.redrawShape(at: index)
    }
}
