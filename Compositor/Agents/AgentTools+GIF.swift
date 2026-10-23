import Foundation

/// Animated GIF layers: their frames and how long each shows. A frame is named by its number from gif_frames, which
/// stays with it when frames around it are added or taken away.
extension AgentTools {
    static var gifTools: [AgentTool] {
        [
            AgentTool(name: "gif_frames",
                      description: """
                        An animated GIF layer's frames in playing order: each frame's number (what edit_gif takes), how \
                        long it shows, and whether it was painted on. The selected frame is the one the canvas shows, and \
                        the one painting, filters and fills change.
                        """,
                      schema: Schema.object(["document": Schema.document, "layer_id": Schema.layer]), readOnly: true) { call in
                let session = try call.session(editing: false)
                let layer = try call.layer(in: session)
                guard let animation = layer.gifAnimation else { throw AgentError("“\(layer.name)” isn't an animated GIF layer.") }
                let timing = animation.timing
                let frames = animation.frames.enumerated().map { position, frame -> JSONValue in
                    .object(["frame": .number(Double(frame.index)), "position": .number(Double(position)),
                             "delay": .number(timing.delay(for: frame)), "edited": .bool(animation.framePixels[frame.index] != nil)])
                }
                return .json(.object([
                    "layer_id": .string(layer.id.uuidString),
                    "selected_frame": session.selectedGIFFrameIndex(for: layer.id).map { .number(Double($0)) } ?? .null,
                    "delay_mode": .string(timing.mode == .uniform ? "uniform" : "per_frame"),
                    "uniform_delay": .number(timing.uniformDelay),
                    "frames": .array(frames),
                ]))
            },
            AgentTool(name: "edit_gif",
                      description: """
                        Changes an animated GIF layer's frames, as its timeline does. "select" shows a frame, so render, \
                        paint, filters and fills then work on it; "duplicate" copies one just after itself; "delete" \
                        takes frames away (one must stay); "set_delays" sets how long frames show, in seconds: `delay` \
                        for every frame alike, or `delays` frame by frame ({"3": 0.5}).
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "layer_id": Schema.layer,
                        "action": Schema.string("What to do.", oneOf: ["select", "duplicate", "delete", "set_delays"]),
                        "frame": Schema.integer("For select and duplicate: the frame's number from gif_frames.", minimum: 0),
                        "frames": Schema.array("For delete: frame numbers.", of: .object(["type": "integer"])),
                        "delay": Schema.number("For set_delays: seconds for every frame alike."),
                        "delays": Schema.anyObject("For set_delays: seconds by frame number, e.g. {\"0\": 0.5, \"3\": 1}."),
                      ], required: ["action"])) { call in
                let session = try call.session()
                let layer = try call.layer(in: session)
                guard let animation = layer.gifAnimation else { throw AgentError("“\(layer.name)” isn't an animated GIF layer.") }
                session.selectLayer(layer.id)
                let numbers = Set(animation.frameReferences.map(\.index))
                func frame() throws -> Int {
                    guard let frame = try call.int("frame") else { throw AgentError("Name the `frame`, by its number from gif_frames.") }
                    guard numbers.contains(frame) else { throw AgentError("There's no frame \(frame); gif_frames lists them.") }
                    return frame
                }
                let revision = session.history.currentRevision
                switch try call.requiredString("action") {
                case "select":
                    let chosen = try frame()
                    await session.selectGIFTimelineFrame(chosen)
                    if let error = takeError(session) { throw AgentError(error) }
                    guard session.selectedGIFFrameIndex(for: layer.id) == chosen else { throw AgentError("Frame \(chosen) couldn't be shown.") }
                    return .text("Frame \(chosen) is selected.")
                case "duplicate":
                    await session.duplicateGIFFrame(at: try frame(), for: layer.id)
                case "delete":
                    guard let items = call.arguments["frames"]?.array, !items.isEmpty else { throw AgentError("List the `frames` to delete.") }
                    let chosen = Set(items.compactMap { $0.number.map(Int.init) })
                    guard chosen.count == items.count, chosen.isSubset(of: numbers) else { throw AgentError("Not every one of those is a frame; gif_frames lists them.") }
                    guard chosen.count < numbers.count else { throw AgentError("A GIF keeps at least one frame.") }
                    await session.deleteGIFFrames(at: chosen, for: layer.id)
                case "set_delays":
                    var timing = animation.timing
                    if let delay = try call.double("delay") {
                        timing.mode = .uniform
                        timing.uniformDelay = delay
                    }
                    if let delays = call.arguments["delays"]?.object {
                        timing.mode = .perFrame
                        for (key, value) in delays {
                            guard let number = Int(key), numbers.contains(number), let seconds = value.number else {
                                throw AgentError("`delays` maps frame numbers to seconds; “\(key)” isn't a frame.")
                            }
                            timing.frameDelays[number] = seconds
                        }
                    }
                    guard timing != animation.timing else { throw AgentError("Give `delay` or `delays`.") }
                    guard timing.isValid(for: numbers) else {
                        throw AgentError("Delays run \(GIFFrameTiming.delayRange.lowerBound)–\(GIFFrameTiming.delayRange.upperBound) seconds.")
                    }
                    session.setGIFFrameTiming(timing, for: layer.id)
                case let other:
                    throw AgentError("`action` is select, duplicate, delete or set_delays, not “\(other)”.")
                }
                if let error = takeError(session) { throw AgentError(error) }
                guard session.history.currentRevision != revision else { throw AgentError("Nothing changed: \(busyReason(session) ?? "the timeline may still be reading a frame").") }
                return .text("Done: undo now undoes “\(session.history.undoName)”.")
            },
        ]
    }
}
