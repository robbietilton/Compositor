import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PenPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    var isFinite: Bool { x.isFinite && y.isFinite }
}

public struct PenPathNode: Codable, Equatable, Sendable {
    public var anchor: PenPoint
    public var inHandle: PenPoint
    public var outHandle: PenPoint

    public init(anchor: PenPoint, inHandle: PenPoint? = nil, outHandle: PenPoint? = nil) {
        self.anchor = anchor
        self.inHandle = inHandle ?? anchor
        self.outHandle = outHandle ?? anchor
    }

    var isFinite: Bool { anchor.isFinite && inHandle.isFinite && outHandle.isFinite }
}

public struct PenColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var isValid: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

public enum PenPathMode: String, Codable, CaseIterable, Sendable {
    case shape = "Shape"
    case line = "Line"
}

public struct PenPathRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let isVisible: Bool
    public let mode: PenPathMode
    public let closed: Bool
    public let color: PenColor
    public let lineWidth: Double
    /// Anchor and handle coordinates are document pixels, not layer-local normalized values.
    public let nodes: [PenPathNode]
    public let approximateLength: Double
}

public struct PenPathSample: Codable, Equatable, Sendable {
    public let fraction: Double
    public let distance: Double
    public let position: PenPoint
    public let tangent: PenPoint
    public let normal: PenPoint
    public let angle: Double
}

public struct CreatePenPathRequest: Sendable {
    public var name: String?
    public var mode: PenPathMode
    public var color: PenColor
    public var lineWidth: Double
    public var nodes: [PenPathNode]
    public var aboveLayerID: UUID?

    public init(name: String? = nil, mode: PenPathMode, color: PenColor, lineWidth: Double = 4,
                nodes: [PenPathNode], aboveLayerID: UUID? = nil) {
        self.name = name
        self.mode = mode
        self.color = color
        self.lineWidth = lineWidth
        self.nodes = nodes
        self.aboveLayerID = aboveLayerID
    }
}

public struct UpdatePenPathRequest: Sendable {
    public var name: String?
    public var mode: PenPathMode?
    public var color: PenColor?
    public var lineWidth: Double?
    public var nodes: [PenPathNode]?
    public var isVisible: Bool?

    public init(name: String? = nil, mode: PenPathMode? = nil, color: PenColor? = nil,
                lineWidth: Double? = nil, nodes: [PenPathNode]? = nil, isVisible: Bool? = nil) {
        self.name = name
        self.mode = mode
        self.color = color
        self.lineWidth = lineWidth
        self.nodes = nodes
        self.isVisible = isVisible
    }
}

public enum PenProjectError: LocalizedError, Equatable {
    case invalidProject
    case unsupportedVersion(Int)
    case invalidPath(String)
    case pathNotFound
    case pathInUse
    case cannotEncodeImage

    public var errorDescription: String? {
        switch self {
        case .invalidProject: "The project is missing, damaged, or is not a .comp package."
        case .unsupportedVersion(let version): "Project format version \(version) is not supported by this MCP server."
        case .invalidPath(let reason): "The Pen path is invalid: \(reason)"
        case .pathNotFound: "No editable Pen path has that layer ID."
        case .pathInUse: "The path layer is used as a live mask source and cannot be deleted safely."
        case .cannotEncodeImage: "The Pen path preview PNG could not be encoded."
        }
    }
}

/// Edits Compositor packages through their public format. PNGs are written before an atomic manifest replacement,
/// so an open Compositor document observes a complete update and reloads it safely.
public final class PenProjectEditor: @unchecked Sendable {
    /// Must match `ProjectManifest.current` in the app. Every project the app saves is written at that version, and
    /// a path written into an older project must not be read as a version 14 path (which the app migrates to painted).
    public static let currentProjectVersion = 17
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func listPaths(in projectURL: URL) throws -> [PenPathRecord] {
        try coordinatedRead(projectURL) { url in
            let manifest = try loadManifest(at: url)
            return try layers(in: manifest).compactMap { try record(from: $0) }
        }
    }

    /// Arc-length samples for text-on-path, arrowheads and other consumers. This mirrors the app's
    /// `VectorPathGeometry` contract while keeping the MCP response independent of UI state.
    public func samples(for record: PenPathRecord, at fractions: [Double]) throws -> [PenPathSample] {
        guard fractions.count <= 1_000, fractions.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw PenProjectError.invalidPath("sample offsets must be between 0 and 1")
        }
        var points = [record.nodes[0].anchor]
        let segmentCount = record.closed ? record.nodes.count : record.nodes.count - 1
        for index in 0..<segmentCount {
            let first = record.nodes[index]
            let second = record.nodes[(index + 1) % record.nodes.count]
            for step in 1...64 {
                points.append(cubic(first.anchor, first.outHandle, second.inHandle, second.anchor,
                                    t: Double(step) / 64))
            }
        }
        var lengths = [Double](repeating: 0, count: points.count)
        for index in 1..<points.count {
            lengths[index] = lengths[index - 1] + hypot(points[index].x - points[index - 1].x,
                                                        points[index].y - points[index - 1].y)
        }
        guard let total = lengths.last, total > 0 else { throw PenProjectError.invalidPath("zero-length path") }
        return fractions.map { fraction in
            let requested = fraction * total
            var upper = 1
            while upper < lengths.count - 1, lengths[upper] < requested { upper += 1 }
            let lower = upper - 1
            let segment = max(lengths[upper] - lengths[lower], Double.ulpOfOne)
            let amount = min(max((requested - lengths[lower]) / segment, 0), 1)
            let start = points[lower]
            let end = points[upper]
            let magnitude = max(hypot(end.x - start.x, end.y - start.y), Double.ulpOfOne)
            let tangent = PenPoint(x: (end.x - start.x) / magnitude, y: (end.y - start.y) / magnitude)
            return PenPathSample(
                fraction: fraction,
                distance: requested,
                position: PenPoint(x: start.x + (end.x - start.x) * amount,
                                   y: start.y + (end.y - start.y) * amount),
                tangent: tangent,
                normal: PenPoint(x: -tangent.y, y: tangent.x),
                angle: atan2(tangent.y, tangent.x)
            )
        }
    }

    @discardableResult
    public func createPath(in projectURL: URL, request: CreatePenPathRequest) throws -> PenPathRecord {
        try validate(mode: request.mode, color: request.color, lineWidth: request.lineWidth, nodes: request.nodes)
        return try coordinatedWrite(projectURL) { url in
            var manifest = try loadManifest(at: url)
            var projectLayers = try layers(in: manifest)
            let id = UUID()
            let name = try validName(request.name ?? nextName(layers: projectLayers))
            let rendered = try render(mode: request.mode, color: request.color,
                                      lineWidth: request.lineWidth, nodes: request.nodes)
            var layer: [String: Any] = [
                "id": id.uuidString,
                "name": name,
                "isVisible": true,
                "isGroup": false,
                "opacity": 1.0,
                "blendMode": "Normal",
                "imageFile": "\(id.uuidString).png",
                "transform": transformJSON(for: rendered.box),
                "vectorPath": styleJSON(mode: request.mode, color: request.color,
                                        lineWidth: request.lineWidth, nodes: rendered.normalizedNodes)
            ]
            if let above = request.aboveLayerID {
                guard let index = projectLayers.firstIndex(where: { string($0["id"]) == above.uuidString }) else {
                    throw PenProjectError.invalidPath("above_layer_id does not exist")
                }
                layer["parentID"] = projectLayers[index]["parentID"]
                projectLayers.insert(layer, at: index + 1)
            } else {
                projectLayers.append(layer)
            }
            manifest["layers"] = projectLayers
            manifest["activeLayerID"] = id.uuidString
            manifest["version"] = max(number(manifest["version"]).map(Int.init) ?? 1, Self.currentProjectVersion)
            try writePNG(rendered.image, id: id, projectURL: url)
            try writeManifest(manifest, projectURL: url)
            return try record(from: layer) ?? { throw PenProjectError.invalidProject }()
        }
    }

    @discardableResult
    public func updatePath(in projectURL: URL, id: UUID, request: UpdatePenPathRequest) throws -> PenPathRecord {
        try coordinatedWrite(projectURL) { url in
            var manifest = try loadManifest(at: url)
            var projectLayers = try layers(in: manifest)
            guard let index = projectLayers.firstIndex(where: { string($0["id"]) == id.uuidString }),
                  let current = try record(from: projectLayers[index]) else { throw PenProjectError.pathNotFound }
            let changesPath = request.mode != nil || request.color != nil || request.lineWidth != nil || request.nodes != nil
            if !changesPath {
                // Renaming or hiding leaves the path, its fill, stroke and erasing, and its pixels untouched.
                var layer = projectLayers[index]
                if let name = request.name { layer["name"] = try validName(name) }
                if let isVisible = request.isVisible { layer["isVisible"] = isVisible }
                projectLayers[index] = layer
                manifest["layers"] = projectLayers
                try writeManifest(manifest, projectURL: url)
                return try record(from: layer) ?? { throw PenProjectError.invalidProject }()
            }
            if let style = projectLayers[index]["vectorPath"] as? [String: Any],
               style["fill"] != nil || style["brushStroke"] != nil ||
                (style["eraseStrokes"] as? [Any])?.isEmpty == false ||
                (style["subpathStarts"] as? [Any])?.isEmpty == false {
                // Rewriting these from MCP would drop the fill, brush stroke or erasing, or join separated pieces.
                throw PenProjectError.invalidPath(
                    "this path has a fill, a brush stroke, erasing or separate pieces; change its shape in Compositor")
            }
            let mode = request.mode ?? current.mode
            let color = request.color ?? current.color
            let lineWidth = request.lineWidth ?? current.lineWidth
            let nodes = request.nodes ?? current.nodes
            try validate(mode: mode, color: color, lineWidth: lineWidth, nodes: nodes)
            let rendered = try render(mode: mode, color: color, lineWidth: lineWidth, nodes: nodes)
            var layer = projectLayers[index]
            if let name = request.name { layer["name"] = try validName(name) }
            if let isVisible = request.isVisible { layer["isVisible"] = isVisible }
            layer["imageFile"] = "\(id.uuidString).png"
            layer["transform"] = transformJSON(for: rendered.box)
            layer["vectorPath"] = styleJSON(mode: mode, color: color, lineWidth: lineWidth,
                                             nodes: rendered.normalizedNodes)
            // A Pen path and another live pixel source cannot truthfully describe the same fallback PNG.
            layer.removeValue(forKey: "shape")
            layer.removeValue(forKey: "text")
            layer.removeValue(forKey: "adjustment")
            projectLayers[index] = layer
            manifest["layers"] = projectLayers
            manifest["activeLayerID"] = id.uuidString
            manifest["version"] = max(number(manifest["version"]).map(Int.init) ?? 1, Self.currentProjectVersion)
            try writePNG(rendered.image, id: id, projectURL: url)
            try writeManifest(manifest, projectURL: url)
            return try record(from: layer) ?? { throw PenProjectError.invalidProject }()
        }
    }

    public func deletePath(in projectURL: URL, id: UUID) throws {
        try coordinatedWrite(projectURL) { url in
            var manifest = try loadManifest(at: url)
            var projectLayers = try layers(in: manifest)
            guard let index = projectLayers.firstIndex(where: { string($0["id"]) == id.uuidString }),
                  try record(from: projectLayers[index]) != nil else { throw PenProjectError.pathNotFound }
            guard !projectLayers.contains(where: { string($0["maskSourceID"]) == id.uuidString }) else {
                throw PenProjectError.pathInUse
            }
            projectLayers.remove(at: index)
            manifest["layers"] = projectLayers
            if string(manifest["activeLayerID"]) == id.uuidString {
                manifest["activeLayerID"] = projectLayers.last?["id"] ?? NSNull()
            }
            try writeManifest(manifest, projectURL: url)
            let imageURL = url.appendingPathComponent("images/\(id.uuidString).png")
            try? fileManager.removeItem(at: imageURL)
        }
    }

    private struct RenderedPath {
        let image: CGImage
        let box: CGRect
        let normalizedNodes: [PenPathNode]
    }

    private func render(mode: PenPathMode, color: PenColor, lineWidth: Double,
                        nodes: [PenPathNode]) throws -> RenderedPath {
        let points = nodes.flatMap { [$0.anchor.cgPoint, $0.inHandle.cgPoint, $0.outHandle.cgPoint] }
        guard let first = points.first else { throw PenProjectError.invalidPath("no nodes") }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        // The PNG is only the transparent identity backing for an editable path. Its color and width are
        // metadata used by Pen controls and future explicit Fill/Stroke commands; the path itself adds no pixels.
        _ = color
        _ = lineWidth
        let padding: CGFloat = 1
        let box = CGRect(x: minX - padding, y: minY - padding,
                         width: max(1, maxX - minX + padding * 2),
                         height: max(1, maxY - minY + padding * 2)).integral
        // Match the app's Pen limit (`DocumentLimits.maxSide`): a larger layer could not be edited there, and one
        // past `LayerTransform.isValid` (300,000 wide or placed beyond 1,000,000) makes the project unopenable.
        guard box.width <= 30_000, box.height <= 30_000,
              abs(box.minX) <= 1_000_000, abs(box.minY) <= 1_000_000 else {
            throw PenProjectError.invalidPath("bounds exceed Compositor's surface limits")
        }
        let normalized = nodes.map { node in
            PenPathNode(
                anchor: PenPoint(x: (node.anchor.x - box.minX) / box.width,
                                 y: (node.anchor.y - box.minY) / box.height),
                inHandle: PenPoint(x: (node.inHandle.x - box.minX) / box.width,
                                   y: (node.inHandle.y - box.minY) / box.height),
                outHandle: PenPoint(x: (node.outHandle.x - box.minX) / box.width,
                                    y: (node.outHandle.y - box.minY) / box.height)
            )
        }
        // The app backs an unpainted path with one transparent pixel stretched over the layer; a full-size
        // transparent PNG would only spend the document's pixel budget.
        let width = 1
        let height = 1
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw PenProjectError.cannotEncodeImage
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw PenProjectError.cannotEncodeImage }
        return RenderedPath(image: image, box: box, normalizedNodes: normalized)
    }

    private func path(nodes: [PenPathNode], size: CGSize, closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = nodes.first else { return path }
        func point(_ value: PenPoint) -> CGPoint { CGPoint(x: value.x * size.width, y: value.y * size.height) }
        path.move(to: point(first.anchor))
        for index in 1..<nodes.count {
            path.addCurve(to: point(nodes[index].anchor), control1: point(nodes[index - 1].outHandle),
                          control2: point(nodes[index].inHandle))
        }
        if closed, let last = nodes.last {
            path.addCurve(to: point(first.anchor), control1: point(last.outHandle), control2: point(first.inHandle))
            path.closeSubpath()
        }
        return path
    }

    private func record(from layer: [String: Any]) throws -> PenPathRecord? {
        guard let style = layer["vectorPath"] as? [String: Any] else { return nil }
        guard let idString = string(layer["id"]), let id = UUID(uuidString: idString),
              let name = string(layer["name"]), let modeString = string(style["mode"]),
              let mode = PenPathMode(rawValue: modeString),
              let red = number(style["red"]), let green = number(style["green"]), let blue = number(style["blue"]),
              let lineWidth = number(style["lineWidth"]), let encodedNodes = style["nodes"] as? [[String: Any]],
              let transform = layer["transform"] as? [String: Any] else { throw PenProjectError.invalidProject }
        let normalized = try encodedNodes.map(decodeNode)
        let nodes = try normalized.map { try documentNode($0, transform: transform) }
        let color = PenColor(red: red, green: green, blue: blue)
        try validate(mode: mode, color: color, lineWidth: lineWidth, nodes: nodes)
        return PenPathRecord(id: id, name: name, isVisible: bool(layer["isVisible"]) ?? true,
                             mode: mode, closed: mode == .shape, color: color, lineWidth: lineWidth,
                             nodes: nodes, approximateLength: approximateLength(nodes: nodes, closed: mode == .shape))
    }

    private func documentNode(_ node: PenPathNode, transform: [String: Any]) throws -> PenPathNode {
        guard let origin = point(transform["origin"]), let size = point(transform["size"]),
              size.x > 0, size.y > 0 else { throw PenProjectError.invalidProject }
        let rotation = (number(transform["rotation"]) ?? 0) * .pi / 180
        let flipX = bool(transform["flipX"]) ?? false
        let flipY = bool(transform["flipY"]) ?? false
        func map(_ point: PenPoint) -> PenPoint {
            let x = (point.x - 0.5) * size.x * (flipX ? -1 : 1)
            let y = (point.y - 0.5) * size.y * (flipY ? -1 : 1)
            return PenPoint(x: origin.x + size.x / 2 + x * cos(rotation) - y * sin(rotation),
                            y: origin.y + size.y / 2 + x * sin(rotation) + y * cos(rotation))
        }
        return PenPathNode(anchor: map(node.anchor), inHandle: map(node.inHandle), outHandle: map(node.outHandle))
    }

    private func validate(mode: PenPathMode, color: PenColor, lineWidth: Double,
                          nodes: [PenPathNode]) throws {
        guard nodes.count >= (mode == .shape ? 3 : 2) else {
            throw PenProjectError.invalidPath(mode == .shape ? "a Shape needs at least three nodes" : "a Line needs at least two nodes")
        }
        guard nodes.count <= 10_000 else { throw PenProjectError.invalidPath("more than 10,000 nodes") }
        guard nodes.allSatisfy(\.isFinite), nodes.flatMap({ [$0.anchor, $0.inHandle, $0.outHandle] })
            .allSatisfy({ abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else {
            throw PenProjectError.invalidPath("coordinates must be finite and within +/-1,000,000 pixels")
        }
        guard color.isValid else { throw PenProjectError.invalidPath("RGB values must be between 0 and 1") }
        guard lineWidth.isFinite, (1...5_000).contains(lineWidth) else {
            throw PenProjectError.invalidPath("line_width must be between 1 and 5,000")
        }
    }

    private func decodeNode(_ value: [String: Any]) throws -> PenPathNode {
        guard let anchor = point(value["anchor"]), let incoming = point(value["inHandle"]),
              let outgoing = point(value["outHandle"]) else { throw PenProjectError.invalidProject }
        return PenPathNode(anchor: anchor, inHandle: incoming, outHandle: outgoing)
    }

    private func styleJSON(mode: PenPathMode, color: PenColor, lineWidth: Double,
                           nodes: [PenPathNode]) -> [String: Any] {
        [
            "mode": mode.rawValue,
            "red": color.red,
            "green": color.green,
            "blue": color.blue,
            "lineWidth": lineWidth,
            "closed": mode == .shape,
            "nodes": nodes.map { node in
                ["anchor": [node.anchor.x, node.anchor.y],
                 "inHandle": [node.inHandle.x, node.inHandle.y],
                 "outHandle": [node.outHandle.x, node.outHandle.y]]
            }
        ]
    }

    private func transformJSON(for box: CGRect) -> [String: Any] {
        ["origin": [box.minX, box.minY], "size": [box.width, box.height], "rotation": 0,
         "flipX": false, "flipY": false, "sampling": "High quality"]
    }

    private func approximateLength(nodes: [PenPathNode], closed: Bool) -> Double {
        let segmentCount = closed ? nodes.count : max(0, nodes.count - 1)
        var result = 0.0
        for index in 0..<segmentCount {
            let first = nodes[index]
            let second = nodes[(index + 1) % nodes.count]
            var previous = first.anchor
            for step in 1...32 {
                let current = cubic(first.anchor, first.outHandle, second.inHandle, second.anchor,
                                    t: Double(step) / 32)
                result += hypot(current.x - previous.x, current.y - previous.y)
                previous = current
            }
        }
        return result
    }

    private func cubic(_ p0: PenPoint, _ p1: PenPoint, _ p2: PenPoint, _ p3: PenPoint, t: Double) -> PenPoint {
        let u = 1 - t
        return PenPoint(x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
                        y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y)
    }

    private func loadManifest(at projectURL: URL) throws -> [String: Any] {
        guard projectURL.pathExtension.lowercased() == "comp",
              (try? projectURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw PenProjectError.invalidProject
        }
        let data = try Data(contentsOf: projectURL.appendingPathComponent("manifest.json"), options: [.mappedIfSafe])
        guard data.count <= 4 * 1024 * 1024,
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              string(manifest["format"]) == "com.compositor.project",
              let versionNumber = number(manifest["version"]) else { throw PenProjectError.invalidProject }
        let version = Int(versionNumber)
        guard (1...Self.currentProjectVersion).contains(version) else { throw PenProjectError.unsupportedVersion(version) }
        _ = try layers(in: manifest)
        return manifest
    }

    private func layers(in manifest: [String: Any]) throws -> [[String: Any]] {
        guard let layers = manifest["layers"] as? [[String: Any]], layers.count <= 10_000 else {
            throw PenProjectError.invalidProject
        }
        return layers
    }

    private func writePNG(_ image: CGImage, id: UUID, projectURL: URL) throws {
        let imagesURL = projectURL.appendingPathComponent("images", isDirectory: true)
        try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PenProjectError.cannotEncodeImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PenProjectError.cannotEncodeImage }
        try (data as Data).write(to: imagesURL.appendingPathComponent("\(id.uuidString).png"), options: .atomic)
    }

    private func writeManifest(_ manifest: [String: Any], projectURL: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 4 * 1024 * 1024 else { throw PenProjectError.invalidProject }
        try data.write(to: projectURL.appendingPathComponent("manifest.json"), options: .atomic)
        try? fileManager.removeItem(at: projectURL.appendingPathComponent("QuickLook", isDirectory: true))
    }

    private func nextName(layers: [[String: Any]]) -> String {
        let base = "Path"
        let names = Set(layers.compactMap { string($0["name"]) })
        var number = 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    private func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 16_384 else { throw PenProjectError.invalidPath("invalid layer name") }
        return name
    }

    private func coordinatedRead<T>(_ url: URL, body: (URL) throws -> T) throws -> T {
        try body(normalized(url))
    }

    private func coordinatedWrite<T>(_ url: URL, body: (URL) throws -> T) throws -> T {
        try body(normalized(url))
    }

    private func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath).standardizedFileURL
    }
}

private func string(_ value: Any?) -> String? { value as? String }
private func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
private func bool(_ value: Any?) -> Bool? { (value as? NSNumber)?.boolValue }
private func point(_ value: Any?) -> PenPoint? {
    guard let pair = value as? [Any], pair.count == 2,
          let x = number(pair[0]), let y = number(pair[1]) else { return nil }
    return PenPoint(x: x, y: y)
}
