import AppKit

/// Editing: selections, fills, filters, adjustment layers, undo, and the menus' commands.
extension AgentTools {
    static var editingTools: [AgentTool] {
        [
            AgentTool(name: "select",
                      description: """
                        Sets the selection, which fills, filters, masks and many commands then work inside: a "rectangle" \
                        or "ellipse" (x, y, width, height), a "polygon" (points), "all", "none", "invert", or "subject" \
                        (the main subject of the visible canvas, found by the Mac). `mode` adds to or subtracts from the \
                        selection there is.
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "shape": Schema.string("What to select.", oneOf: ["rectangle", "ellipse", "polygon", "all", "none", "invert", "subject"]),
                        "x": Schema.number("Left edge."), "y": Schema.number("Top edge."),
                        "width": Schema.number("Width."), "height": Schema.number("Height."),
                        "points": Schema.array("A polygon's corners, [[x, y], …], three or more.", of: Schema.point("[x, y]")),
                        "mode": Schema.string("Default replace.", oneOf: ["replace", "add", "subtract"]),
                        "feather": Schema.number("Soften the edge by this many pixels. Default 0."),
                      ], required: ["shape"])) { call in
                let session = try call.session()
                let mode: SelectionMode
                switch try call.string("mode", default: "replace") {
                case "replace": mode = .replace
                case "add": mode = .add
                case "subtract": mode = .subtract
                case let other: throw AgentError("`mode` is replace, add or subtract, not “\(other)”.")
                }
                let shape = try call.requiredString("shape")
                switch shape {
                case "all": session.selectAll()
                case "none": session.deselect()
                case "invert":
                    guard session.selection != nil else { throw AgentError("There's no selection to invert.") }
                    session.invertSelection()
                case "subject":
                    guard session.canSelectSubject else { throw AgentError("Select Subject can't run now.") }
                    await session.selectSubject(mode: mode)
                    if let error = takeError(session) { throw AgentError(error) }
                case "rectangle", "ellipse", "polygon":
                    let path: CGPath
                    if shape == "polygon" {
                        guard let items = call.arguments["points"]?.array, items.count >= 3 else { throw AgentError("A polygon needs three or more `points`.") }
                        let points = try items.map { item -> CGPoint in
                            guard let pair = item.array, pair.count == 2, let x = pair[0].number, let y = pair[1].number else {
                                throw AgentError("Each point is [x, y].")
                            }
                            return CGPoint(x: x, y: y)
                        }
                        let polygon = CGMutablePath()
                        polygon.addLines(between: points)
                        polygon.closeSubpath()
                        path = polygon
                    } else {
                        guard let x = try call.double("x"), let y = try call.double("y"), let width = try call.double("width"),
                              let height = try call.double("height"), width > 0, height > 0 else {
                            throw AgentError("A \(shape) needs x, y, and a width and height above 0.")
                        }
                        let rect = CGRect(x: x, y: y, width: width, height: height)
                        path = shape == "ellipse" ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
                    }
                    try select(path, mode: mode, feather: try call.double("feather") ?? 0, in: session,
                               name: shape == "polygon" ? "Polygonal Lasso" : shape == "ellipse" ? "Elliptical Marquee" : "Rectangular Marquee")
                case let other: throw AgentError("`shape` can't be “\(other)”.")
                }
                guard let selection = session.selection, !selection.isEmpty else { return .text("Nothing is selected.") }
                let bounds = selection.path.boundingBoxOfPath
                return .text("Selected an area \(Int(bounds.width))×\(Int(bounds.height)) at (\(Int(bounds.minX)), \(Int(bounds.minY))).")
            },
            AgentTool(name: "fill",
                      description: "Fills the selection on a pixel layer with a color (the whole layer when nothing is selected), as Edit › Fill does. A text layer with no selection takes the color as its text color.",
                      schema: Schema.object(["document": Schema.document, "layer_id": Schema.layer,
                                             "color": Schema.string("#RRGGBB.")], required: ["color"])) { call in
                let session = try call.session()
                let layer = try call.layer(in: session)
                let fill = try color(try call.requiredString("color"))
                session.selectLayer(layer.id)
                session.isMaskSelected = false
                guard session.canEditPixels else { throw AgentError("“\(layer.name)” has no pixels to fill: pick a pixel layer, or add one with add_layer.") }
                let revision = session.history.currentRevision
                let foreground = session.foregroundColor
                session.foregroundColor = fill
                await session.fillSelection(with: .foreground)
                session.foregroundColor = foreground
                if let error = takeError(session) { throw AgentError(error) }
                guard session.history.currentRevision != revision else { throw AgentError("Nothing was filled.") }
                return .text("Filled “\(layer.name)” with #\(fill.hex).")
            },
            AgentTool(name: "apply_filter",
                      description: """
                        Runs a filter on a pixel layer, inside the selection when there is one, as one undo step: as \
                        choosing it from the Filter or Image menu and pressing OK. Settings left out keep the values the \
                        panel last used. Content-Aware Fill fills the selection from its surroundings; Remove Background \
                        hides the background with a mask. Filters and their settings — \(AgentFilterSettings.reference).
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "layer_id": Schema.layer,
                        "filter": Schema.string("Which filter.", oneOf: FilterKind.allCases.map(\.rawValue)),
                        "settings": Schema.anyObject("The filter's settings, by name."),
                        "on_mask": Schema.boolean("Run it on the layer's mask instead of its pixels."),
                      ], required: ["filter"])) { call in
                let session = try call.session()
                let layer = try call.layer(in: session)
                let name = try call.requiredString("filter")
                guard let kind = FilterKind.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
                    throw AgentError("There's no filter “\(name)”. They are: \(FilterKind.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                session.selectLayer(layer.id)
                let onMask = try call.bool("on_mask") ?? false
                guard !onMask || layer.mask != nil else { throw AgentError("That layer has no mask.") }
                session.isMaskSelected = onMask
                if kind == .contentAwareFill, session.selection?.isEmpty != false { throw AgentError("Content-Aware Fill fills a selection; select the area first.") }
                let revision = session.history.currentRevision
                session.beginFilter(kind)
                guard let edit = session.filterEdit else {
                    throw AgentError(takeError(session) ?? "\(kind.rawValue) can't run on “\(layer.name)”: it runs on pixel layers, not folders or adjustment layers.")
                }
                var settings = edit.settings
                do { try AgentFilterSettings.apply(call.arguments["settings"] ?? .object([:]), for: kind, to: &settings) }
                catch { session.cancelFilter(); throw error }
                // A filter that finds its result itself commits its preview, so it needs one made.
                session.updateFilter(settings, preview: kind.isAutomatic)
                await session.commitFilter()
                if session.filterEdit === edit {
                    session.cancelFilter()
                    throw AgentError(takeError(session) ?? edit.previewError ?? "\(kind.rawValue) couldn't be applied.")
                }
                if let error = takeError(session) { throw AgentError(error) }
                guard session.history.currentRevision != revision else { return .text("\(kind.rawValue) left the image as it was, with those settings.") }
                return .text("Applied \(kind.rawValue) to “\(layer.name)”\(onMask ? "’s mask" : "").")
            },
            AgentTool(name: "add_adjustment_layer",
                      description: """
                        Adds an adjustment layer above the selected layer (or `above_layer_id`): it changes everything \
                        below it in its folder and stays editable with update_layer. `settings` takes the fields of a \
                        .comp manifest's `adjustment`, partial: e.g. Hue/Saturation {"hue": 20, "saturation": -30}, \
                        Exposure {"exposureSettings": {"exposure": 0.5}}, Gaussian Blur {"blurRadius": 8}, Color Balance \
                        {"colorBalanceSettings": {"midCyanRed": 20}}. get_document shows every field of one once made.
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "kind": Schema.string("Which adjustment.", oneOf: AdjustmentKind.allCases.map(\.rawValue)),
                        "settings": Schema.anyObject("Its settings, partial."),
                        "name": Schema.string("The layer's name."),
                        "above_layer_id": Schema.string("Put it above this layer. Omitted: above the selected one."),
                      ], required: ["kind"])) { call in
                let session = try call.session()
                let name = try call.requiredString("kind")
                guard let kind = AdjustmentKind.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
                    throw AgentError("There's no adjustment “\(name)”. They are: \(AdjustmentKind.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                if let above = try call.id("above_layer_id") {
                    guard session.document?.layers.contains(where: { $0.id == above }) == true else { throw AgentError("No layer has id \(above.uuidString).") }
                    session.selectLayer(above)
                }
                let before = Set(session.document?.layers.map(\.id) ?? [])
                session.beginEdit("New \(kind.rawValue) Adjustment")
                defer { session.endEdit() }
                session.addAdjustment(kind)
                guard let index = session.document?.layers.firstIndex(where: { !before.contains($0.id) }),
                      let layer = session.document?.layers[index], let adjustment = layer.adjustment else {
                    throw AgentError("The adjustment layer couldn't be added.")
                }
                // An agent sets the values itself, so the editor the app opens for a new adjustment stays closed.
                if session.adjustmentEditingID == layer.id { session.adjustmentEditingID = nil }
                if let patch = call.arguments["settings"], !patch.isNull {
                    let value = try patched(adjustment, with: patch, seeds: seededAdjustment(adjustment))
                    guard value.kind == kind, value.isValid else { throw AgentError("Those settings are out of range; see docs/project-format.md for each one's.") }
                    session.document?.layers[index].adjustment = value
                }
                if let name = try call.string("name") { session.renameLayer(layer.id, to: name) }
                return .json(try describe(session.document?.layers[index] ?? layer, in: session))
            },
            AgentTool(name: "undo",
                      description: "Undoes the last change (or `steps` of them), as Edit › Undo does: yours or the person's.",
                      schema: Schema.object(["document": Schema.document, "steps": Schema.integer("How many. Default 1.", minimum: 1, maximum: 100)])) { call in
                try history(call, undoing: true)
            },
            AgentTool(name: "redo",
                      description: "Redoes what was undone (or `steps` of it), as Edit › Redo does.",
                      schema: Schema.object(["document": Schema.document, "steps": Schema.integer("How many. Default 1.", minimum: 1, maximum: 100)])) { call in
                try history(call, undoing: false)
            },
        ]
    }

    static var commandTools: [AgentTool] {
        [
            AgentTool(name: "list_commands",
                      description: """
                        The commands in Compositor's menus, and its tools, as Search Commands (⌘F) finds them: each one's \
                        name for run_command, its key, and whether it can run now. `query` finds them the same fuzzy way.
                        """,
                      schema: Schema.object(["document": Schema.document,
                                             "query": Schema.string("Words or letters to look for, e.g. \"flip\" or \"blur\"."),
                                             "limit": Schema.integer("At most this many. Default 60.", minimum: 1, maximum: 1000)]),
                      readOnly: true) { call in
                let entries = CommandPaletteSearch.rank(commands(for: try call.tab().session), query: try call.string("query") ?? "")
                return .json(.array(entries.prefix(try call.int("limit") ?? 60).map { entry in
                    .object(["command": .string(entry.id), "shortcut": entry.shortcut.map { .string($0) } ?? .null,
                             "enabled": .bool(entry.isEnabled), "on": .bool(entry.isOn)])
                }))
            },
            AgentTool(name: "run_command",
                      description: """
                        Runs a menu command (or picks a tool) by its name from list_commands, e.g. "Layer › Flip Layer \
                        Horizontal" or "Image › Trim…", on the front document, as choosing it does. A name ending in “…” \
                        opens a dialog for the person to answer, so it's refused unless `allow_dialog` is true; prefer a \
                        tool of its own where there is one.
                        """,
                      schema: Schema.object(["document": Schema.document,
                                             "command": Schema.string("The command's name, exactly as list_commands gives it."),
                                             "allow_dialog": Schema.boolean("Run it even though it opens a dialog for the person.")],
                                            required: ["command"])) { call in
                let session = try call.tab().session
                let name = try call.requiredString("command")
                let entries = commands(for: session)
                guard let entry = entries.first(where: { $0.id == name }) ?? entries.first(where: { $0.title == name }) else {
                    let near = CommandPaletteSearch.rank(entries, query: name).prefix(5).map { "“\($0.id)”" }
                    throw AgentError("There's no command “\(name)”." + (near.isEmpty ? "" : " Close ones: \(near.joined(separator: ", ")).")
                    )
                }
                guard entry.isEnabled else { throw AgentError("“\(entry.id)” can't run now (its menu item is dimmed). \(busyReason(session).map { "Compositor is busy: \($0)." } ?? "It may need a selection, or a different kind of layer selected.")") }
                if entry.title.hasSuffix("…"), try call.bool("allow_dialog") != true {
                    throw AgentError("“\(entry.id)” opens a dialog the person would have to answer. Use a tool of its own if there is one, or pass allow_dialog: true.")
                }
                let revision = session.history.currentRevision
                entry.perform()
                // Many commands finish their work a moment later; wait for that, up to half a minute.
                for _ in 0..<300 {
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(100))
                    if !(session.isProjectBusy || session.showsBusy || session.isImporting) { break }
                }
                if let error = takeError(session) { throw AgentError(error) }
                let changed = session.history.currentRevision != revision
                return .text("Ran “\(entry.id)”." + (changed ? " Undo now undoes “\(session.history.undoName)”." : ""))
            },
        ]
    }

    /// Everything Search Commands lists for `session`'s window.
    static func commands(for session: EditorSession) -> [CommandPaletteEntry] {
        (NSApp.mainMenu.map { CommandPaletteMenu.entries(in: $0, skipping: CommandPaletteController.skipped) } ?? [])
            + CommandPaletteEntry.layerCommands(for: session) + CommandPaletteEntry.tools(for: session)
    }

    /// Selects `shape` the way the Marquee and Lasso do, softened by `feather`.
    private static func select(_ shape: CGPath, mode: SelectionMode, feather: Double, in session: EditorSession, name: String) throws {
        guard let document = session.document else { return }
        guard feather.isFinite, (0...1000).contains(feather) else { throw AgentError("`feather` runs from 0 to 1000 pixels.") }
        let canvas = CGPath(rect: CGRect(origin: .zero, size: document.size), transform: nil)
        let clipped = shape.intersection(canvas, using: .winding)
        let result: CGPath
        switch mode {
        case .replace: result = clipped
        case .add: result = session.selection.map { $0.path.union(clipped, using: .winding) } ?? clipped
        case .subtract:
            guard let current = session.selection else { throw AgentError("There's no selection to subtract from.") }
            result = current.path.subtracting(clipped, using: .winding)
        }
        session.setSelection(DocumentSelection(path: result, antialiased: session.selectionAntialiased, feather: feather), name: name)
    }

    private static func history(_ call: AgentCall, undoing: Bool) throws -> AgentResult {
        let session = try call.session(editing: false)
        var names: [String] = []
        for _ in 0..<(try call.int("steps") ?? 1) {
            guard undoing ? session.canUndo : session.canRedo else { break }
            names.append(undoing ? session.history.undoName : session.history.redoName)
            if undoing { session.undo() } else { session.redo() }
        }
        guard !names.isEmpty else { throw AgentError("There's nothing to \(undoing ? "undo" : "redo")" + (busyReason(session).map { " now: \($0)." } ?? ".")) }
        return .text("\(undoing ? "Undid" : "Redid"): \(names.joined(separator: ", ")).")
    }
}
