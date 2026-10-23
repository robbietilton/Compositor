import AppKit

/// Painting: the brush tools, driven along points as a hand drives them along the pointer.
extension AgentTools {
    /// The brush tools by the names an agent uses, with the tool and mode each one is.
    private static let brushes: [String: (tool: NavigationTool, setup: (EditorSession) -> Void)] = [
        "brush": (.brush, { $0.brushMode = .paint }),
        "eraser": (.brush, { $0.brushMode = .erase }),
        "spot_healing": (.spotHealing, { _ in }),
        "clone_stamp": (.cloneStamp, { _ in }),
        "blur": (.blur, { $0.blurMode = .blur }),
        "smudge": (.blur, { $0.blurMode = .smudge }),
        "liquify": (.blur, { $0.blurMode = .liquify }),
    ]

    static var paintingTools: [AgentTool] {
        [
            AgentTool(name: "paint",
                      description: """
                        Paints strokes on a layer (or its mask) with a brush tool, as dragging it does, one undo step per \
                        stroke. Each stroke is a list of points [x, y] in document pixels, or [x, y, pressure] with \
                        pressure 0–1 for a pen's taper; points between are filled in. Tools: "brush" (paints `color`), \
                        "eraser", "spot_healing" (paints over a blemish and fills it from around it), "clone_stamp" \
                        (copies from `clone_source`, the offset kept along the stroke), "blur", "smudge", "liquify" \
                        (pushes pixels along the stroke). On a mask, white shows the layer and black hides it. The \
                        person's own brush settings are left as they were.
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "layer_id": Schema.layer,
                        "tool": Schema.string("Which brush tool.", oneOf: brushes.keys.sorted()),
                        "strokes": Schema.array("Strokes, each a list of [x, y] or [x, y, pressure] points.",
                                                of: Schema.array("One stroke.", of: .object(["type": "array", "items": ["type": "number"]]))),
                        "size": Schema.number("Brush diameter in pixels. Default 40."),
                        "hardness": Schema.number("Edge hardness, 0 (soft) to 1 (hard). Default 1."),
                        "opacity": Schema.number("0–1: the brush's opacity, or for Blur, Smudge and Liquify their strength. Default 1."),
                        "color": Schema.string("For the brush, #RRGGBB. Default the foreground color. On a mask, light paints white and dark black."),
                        "pressure_controls": Schema.string("What pen pressure changes, when points carry it. Default size.", oneOf: ["size", "opacity", "both"]),
                        "on_mask": Schema.boolean("Paint the layer's mask rather than its pixels."),
                        "clone_source": Schema.point("For Clone Stamp: where it copies from, for the stroke's first point."),
                        "sample_all_layers": Schema.boolean("For Clone Stamp: copy what all visible layers show, not just this layer."),
                        "healing_mode": Schema.string("For Spot Healing.", oneOf: SpotHealingMode.allCases.map(\.rawValue)),
                        "blur_radius": Schema.number("For Blur: how far it softens, in pixels. Default 5."),
                      ], required: ["tool", "strokes"])) { call in
                let session = try call.session()
                let layer = try call.layer(in: session)
                let name = try call.requiredString("tool")
                guard let brush = brushes[name] else { throw AgentError("`tool` is one of: \(brushes.keys.sorted().joined(separator: ", ")).") }
                let strokes = try strokePoints(call)
                let onMask = try call.bool("on_mask") ?? false
                guard !onMask || layer.mask != nil else { throw AgentError("That layer has no mask; add one with add_mask.") }

                // The person's tool and settings, to give back once the strokes are down.
                let kept = (tool: session.tool, settings: session.brushSettings, brushMode: session.brushMode, blurMode: session.blurMode,
                            healing: session.spotHealingMode, cloneSource: session.cloneSource, clone: session.cloneSettings,
                            maskWhite: session.maskPaintWhite)
                defer {
                    session.selectTool(kept.tool)
                    session.brushSettings = kept.settings
                    session.brushMode = kept.brushMode
                    session.blurMode = kept.blurMode
                    session.spotHealingMode = kept.healing
                    session.cloneSource = kept.cloneSource
                    session.cloneSettings = kept.clone
                    session.maskPaintWhite = kept.maskWhite
                }

                session.selectLayer(layer.id)
                session.isMaskSelected = onMask
                session.selectTool(brush.tool)
                guard session.tool == brush.tool else { throw AgentError("Compositor couldn't take up the \(name) tool: \(busyReason(session) ?? "it's busy").") }
                brush.setup(session)
                var settings = session.brushSettings
                settings.diameter = CGFloat(try call.double("size") ?? 40)
                settings.hardness = CGFloat(try call.double("hardness") ?? 1)
                settings.opacity = CGFloat(try call.double("opacity") ?? 1)
                settings.blurRadius = CGFloat(try call.double("blur_radius") ?? 5)
                // The pointer's own smoothing would pull the points off where they were asked to go.
                settings.smoothing = 0
                guard (1...5000).contains(settings.diameter), (0...1).contains(settings.hardness), (0.01...1).contains(settings.opacity),
                      (0.1...250).contains(settings.blurRadius) else {
                    throw AgentError("Out of range: size 1–5000, hardness 0–1, opacity 0.01–1, blur_radius 0.1–250.")
                }
                if let hex = try call.string("color") {
                    let color = try color(hex)
                    if onMask { session.maskPaintWhite = (color.red + color.green + color.blue) / 3 >= 0.5 }
                    else { settings.red = color.red; settings.green = color.green; settings.blue = color.blue }
                }
                let pressured = strokes.contains { $0.contains { $0.pressure != nil } }
                let controls = try call.string("pressure_controls", default: "size")
                settings.pressureSize = pressured && controls != "opacity"
                settings.pressureOpacity = pressured && controls != "size"
                session.brushSettings = settings
                if let mode = try call.string("healing_mode") {
                    guard let healing = SpotHealingMode(rawValue: mode) else { throw AgentError("`healing_mode` is one of: \(SpotHealingMode.allCases.map(\.rawValue).joined(separator: ", ")).") }
                    session.spotHealingMode = healing
                }
                if brush.tool == .cloneStamp {
                    guard let source = try call.point("clone_source") else { throw AgentError("Clone Stamp needs `clone_source`: where to copy from.") }
                    session.setCloneSource(source)
                    session.cloneSettings.aligned = true
                    session.cloneSettings.sampleAllLayers = try call.bool("sample_all_layers") ?? false
                }

                let before = session.history.undoCount
                for stroke in strokes {
                    let points = densified(stroke, spacing: max(1, settings.diameter * 0.1))
                    session.beginBrush(at: points[0].point, pressure: points[0].pressure)
                    guard session.brushStroke != nil || session.warpStroke != nil else {
                        throw AgentError(takeError(session) ?? session.paintRefusal ?? "That layer can't be painted with \(name).")
                    }
                    for point in points.dropFirst() { session.continueBrush(at: point.point, pressure: point.pressure) }
                    session.finishBrushImmediately()
                    if let error = takeError(session) { throw AgentError(error) }
                }
                let painted = session.history.undoCount - before
                return .text(painted > 0 ? "Painted \(painted) stroke\(painted == 1 ? "" : "s") with \(name) on “\(layer.name)”\(onMask ? "’s mask" : "")."
                                         : "The strokes left “\(layer.name)” as it was.")
            },
        ]
    }

    private struct StrokePoint {
        var point: CGPoint
        var pressure: CGFloat?
    }

    private static func strokePoints(_ call: AgentCall) throws -> [[StrokePoint]] {
        guard let strokes = call.arguments["strokes"]?.array, !strokes.isEmpty else { throw AgentError("`strokes` needs at least one stroke.") }
        return try strokes.map { stroke in
            guard let points = stroke.array, !points.isEmpty else { throw AgentError("Each stroke is a list of points.") }
            return try points.map { item in
                guard let values = item.array?.compactMap(\.number), values.count == item.array?.count,
                      values.count == 2 || values.count == 3, values.allSatisfy(\.isFinite) else {
                    throw AgentError("Each point is [x, y] or [x, y, pressure].")
                }
                return StrokePoint(point: CGPoint(x: values[0], y: values[1]),
                                   pressure: values.count == 3 ? CGFloat(min(1, max(0, values[2]))) : nil)
            }
        }
    }

    /// `points` with more in between wherever two lie further apart than `spacing`, pressure eased between them, so
    /// a few corners make a stroke as smooth as a dragged one.
    private static func densified(_ points: [StrokePoint], spacing: CGFloat) -> [StrokePoint] {
        var result = [points[0]]
        for next in points.dropFirst() {
            let last = result[result.count - 1]
            let steps = Int(ceil(hypot(next.point.x - last.point.x, next.point.y - last.point.y) / spacing))
            for step in 1...max(1, steps) {
                let t = CGFloat(step) / CGFloat(max(1, steps))
                let pressure = next.pressure.map { end in (last.pressure ?? end) + (end - (last.pressure ?? end)) * t }
                result.append(StrokePoint(point: CGPoint(x: last.point.x + (next.point.x - last.point.x) * t,
                                                         y: last.point.y + (next.point.y - last.point.y) * t), pressure: pressure))
            }
        }
        return result
    }
}
