import Foundation
import ImageIO
import CryptoKit

/// Reads data, never archived classes. Original bytes remain authoritative for future settings mappings.
nonisolated enum ProcreateBrushImporter {
    struct Result: Sendable {
        var brushes: [BrushPreset]
        var diagnostics: [String]
        var decodedShapeBytes = 0
    }
    /// Rebuild derived source metadata without replacing identity, opt-in or native calibration/overrides.
    static func remap(_ brush: BrushPreset, original: Data) throws -> BrushPreset {
        guard let source = brush.source else { return brush }
        let result = try read(original, filename: source.filename)
        guard let mapped = result.brushes.first(where: {
            $0.source?.archiveDigest == source.archiveDigest && $0.source?.memberPath == source.memberPath
                && $0.source?.definitions.first?.path == source.definitions.first?.path
        }) else { throw BrushImportError.invalid("Original brush definition not found.") }
        var updated = brush
        updated.source = mapped.source
        return updated
    }
    static func read(_ data: Data, filename: String) throws -> Result {
        let name = filename.lowercased()
        guard name.hasSuffix(".brush") || name.hasSuffix(".brushset") || name.hasSuffix(".brushlibrary") || name.hasSuffix(".brushset.zip") else {
            throw BrushImportError.invalid("Choose a .brush, .brushset or .brushlibrary file.")
        }
        var budget = BrushZIP.Budget()
        let archive = try files(data, budget: &budget)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var result = Result(brushes: [], diagnostics: [])
        if name.hasSuffix(".brushlibrary") {
            let members = archive.order.filter { $0.lowercased().hasSuffix(".brush") }
            var encountered: [String] = []
            for member in members {
                let folder = (member as NSString).deletingLastPathComponent
                if !encountered.contains(folder) { encountered.append(folder) }
            }
            let groups = ordered(encountered, folder: "", archive: archive, diagnostics: &result.diagnostics)
            for group in groups {
                let names = members.filter { ($0 as NSString).deletingLastPathComponent == group }.map { ($0 as NSString).lastPathComponent }
                let sorted = ordered(names, folder: group, archive: archive, diagnostics: &result.diagnostics)
                for member in sorted {
                    let path = group.isEmpty ? member : group + "/" + member
                    guard let nested = archive.data[path] else { throw BrushImportError.invalid("Missing library member: " + path) }
                    let child = try files(nested, budget: &budget)
                    guard !child.order.contains(where: { $0.lowercased().hasSuffix(".brush") }) else {
                        throw BrushImportError.invalid("Nested libraries beyond one member level aren’t supported.")
                    }
                    try append(child, digest: digest, filename: filename, member: path, collection: group, to: &result)
                }
            }
        } else {
            try append(archive, digest: digest, filename: filename, member: nil, collection: nil, to: &result)
        }
        guard !result.brushes.isEmpty, result.brushes.count <= 998 else {
            throw BrushImportError.invalid("No brush definitions found, or too many brushes for this collection.")
        }
        return result
    }

    private struct Files {
        var order: [String]
        var data: [String: Data]
    }
    private static func files(_ data: Data, budget: inout BrushZIP.Budget) throws -> Files {
        let zip = try BrushZIP(data, budget: &budget)
        var files: [String: Data] = [:]
        for entry in zip.entries {
            let bytes = try zip.read(entry)
            // Read image properties without decoding or caching a full raster.
            if ["png", "jpg", "jpeg", "tif", "tiff"].contains((entry.name as NSString).pathExtension.lowercased()) {
                try validateImage(bytes, name: entry.name)
            }
            files[entry.name] = bytes
        }
        return Files(order: zip.entries.map(\.name), data: files)
    }

    private static func validateImage(_ data: Data, name: String) throws {
        guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0,
              width.int64Value <= 32768, height.int64Value <= 32768,
              width.int64Value * height.int64Value <= 64 * 1024 * 1024 else {
            throw BrushImportError.invalid("Invalid or oversized image: " + name)
        }
    }

    private static func append(_ archive: Files, digest: String, filename: String, member: String?, collection: String?, to result: inout Result) throws {
        let definitions = archive.order.filter { ($0 as NSString).lastPathComponent == "Brush.archive" }
        let primary = definitions.filter { path in
            let parts = path.components(separatedBy: "/").dropLast()
            return !parts.contains("Reset") && !parts.contains(where: { $0.hasPrefix("Sub") })
        }
        let manifests = archive.order.filter { ($0 as NSString).lastPathComponent == "brushset.plist" }
        guard manifests.count <= 1 else { throw BrushImportError.invalid("Ambiguous brush-set ordering.") }
        var orderedPaths = primary
        var collectionName = collection
        if let manifest = manifests.first, let bytes = archive.data[manifest] {
            let plist = try propertyList(bytes)
            guard let object = plist as? [String: Any], let ids = object["brushes"] as? [String], ids.count <= 1000,
                  Set(ids).count == ids.count else { throw BrushImportError.invalid("Invalid brush-set ordering.") }
            let folder = (manifest as NSString).deletingLastPathComponent
            let prefix = folder.isEmpty ? "" : folder + "/"
            var paths: [String] = []
            for id in ids {
                guard BrushZIP.safePath(id), !id.contains("/"), primary.contains(prefix + id + "/Brush.archive") else {
                    throw BrushImportError.invalid("Brush-set ordering references a missing definition.")
                }
                paths.append(prefix + id + "/Brush.archive")
            }
            let unlisted = primary.filter { !paths.contains($0) }
            if !unlisted.isEmpty { result.diagnostics.append("Unlisted definitions appended in archive order: \(unlisted.count).") }
            orderedPaths = paths + unlisted
            collectionName = object["name"] as? String ?? collection
        }
        for path in orderedPaths {
            let folder = (path as NSString).deletingLastPathComponent
            let prefix = folder.isEmpty ? "" : folder + "/"
            let secondary = definitions.filter {
                $0.hasPrefix(prefix + "Sub") && !$0.components(separatedBy: "/").contains("Reset")
                    && !primary.contains($0)
            }.sorted()
            var sourceDefinitions: [BrushSource.Definition] = []
            var issues = ["Source settings are preserved. Native shape approximation does not reproduce source dynamics or rendering."]
            var brushName: String?
            for definition in [path] + secondary {
                let fields = try KeyedBrush(try required(archive.data[definition], definition))
                if definition == path { brushName = try fields.string("name") }
                let shape = try fields.string("bundledShapePath")
                let grain = try fields.string("bundledGrainPath")
                let owner = (definition as NSString).deletingLastPathComponent
                func resolve(_ reference: String?, kind: String) throws -> BrushAssetResolution? {
                    if let reference {
                        guard BrushZIP.safePath(reference) else { throw BrushImportError.invalid("Unsafe asset reference in " + definition) }
                        let asset = owner.isEmpty ? reference : owner + "/" + reference
                        if let bytes = archive.data[asset] {
                            try validateImage(bytes, name: asset)
                            return .embedded(path: asset)
                        }
                        if kind == "Shape", let mapping = BasicBrushShape(rawValue: reference) {
                            issues.append("\(definition): \(mapping.title); original tip pixels unavailable. Soft candidates require hardness calibration.")
                            return .procedural(mapping, revision: BasicBrushShape.revision)
                        }
                        if BrushHeadCatalog.names.contains(reference) {
                            issues.append("\(definition): Catalogued \(kind.lowercased()) reference missing: \(reference). No original image is bundled or downloaded; choose an explicit native substitute if appropriate.")
                            return .cataloguedMissing
                        }
                        issues.append("\(definition): \(kind) not embedded: \(reference)")
                        return .missing
                    }
                    if kind == "Shape" { issues.append("\(definition): Shape reference not supplied."); return .missing }
                    return nil
                }
                let shapeResolution = try resolve(shape, kind: "Shape")
                func decodeMask(_ resolution: BrushAssetResolution?, kind: String) throws -> BrushShapeTip? {
                    guard case .embedded(let asset) = resolution, let bytes = archive.data[asset] else { return nil }
                    guard result.decodedShapeBytes <= 8 * 1024 * 1024 - 2 * 256 * 256 else {
                        throw BrushImportError.invalid("Derived shape/grain masks exceed the 8 MiB import budget.")
                    }
                    do {
                        let image = try BrushShapeTip.decode(bytes, name: (asset as NSString).lastPathComponent)
                        result.decodedShapeBytes += image.luminance.count + image.alpha.count
                        return image
                    } catch {
                        issues.append("\(definition): \(kind) image unavailable: \(error.localizedDescription). Original bytes retained.")
                        return nil
                    }
                }
                let tip = try decodeMask(shapeResolution, kind: "Shape")
                let grainResolution = try resolve(grain, kind: "Grain")
                let grainTip = try decodeMask(grainResolution, kind: "Grain")
                sourceDefinitions.append(.init(path: definition, shapeReference: shape, grainReference: grain,
                    shapeResolution: shapeResolution, grainResolution: grainResolution, tip: tip, grainTip: grainTip))
            }
            if !secondary.isEmpty { issues.append("Dual brush: native painting requires explicit secondary-tip setup; original source dynamics are not mapped.") }
            let fallback = member.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? ((filename as NSString).deletingPathExtension)
            var brush = BrushPreset(name: brushName?.isEmpty == false ? brushName! : fallback)
            brush.source = BrushSource(archiveDigest: digest, filename: filename, definitions: sourceDefinitions,
                                       memberPath: member, collectionName: collectionName, issues: issues)
            if sourceDefinitions.first?.tip != nil { brush.roundDynamics.shape = ShapeBrushSettings(source: .embedded) }
            else if case .procedural(let basic, _) = sourceDefinitions.first?.shapeResolution, basic != .hard {
                brush.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: basic.generatedTip)
            }
            guard brush.isValid else { throw BrushImportError.invalid("Invalid brush metadata: " + path) }
            result.brushes.append(brush)
            result.diagnostics += issues.map { brush.name + ": " + $0 }
        }
        let covered = Set(orderedPaths.flatMap { path in
            let folder = (path as NSString).deletingLastPathComponent
            return definitions.filter { $0 == path || $0.hasPrefix((folder.isEmpty ? "" : folder + "/") + "Sub") }
        })
        guard definitions.allSatisfy({ $0.components(separatedBy: "/").contains("Reset") || covered.contains($0) }) else {
            throw BrushImportError.invalid("Orphan secondary brush definition.")
        }
        // Reset archives are preserved, and validated just like active definitions.
        for path in definitions where path.components(separatedBy: "/").contains("Reset") {
            _ = try KeyedBrush(try required(archive.data[path], path))
        }
    }

    /// Legacy library metadata stores alphabetic index + signed offset, followed by opaque icon data.
    private static func ordered(_ names: [String], folder: String, archive: Files, diagnostics: inout [String]) -> [String] {
        let metadata = archive.order.filter {
            ($0 as NSString).deletingLastPathComponent == folder && ($0 as NSString).lastPathComponent.hasPrefix(".procreate_meta.")
        }
        guard metadata.count == 1, let bytes = archive.data[metadata[0]],
              let text = String(data: bytes.prefix(while: { $0 != 0 }), encoding: .utf8) else {
            diagnostics.append("No usable ordering metadata for \(folder.isEmpty ? "library" : folder); using stable archive order.")
            return names
        }
        var rows: [(position: Int, name: String)] = []
        for (index, line) in text.split(separator: "\n").enumerated() {
            let parts = line.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, let delta = Int(parts[1]), (-20000...20000).contains(delta),
                  names.contains(String(parts[0])) else {
                diagnostics.append("Unknown ordering metadata for \(folder); using stable archive order."); return names
            }
            rows.append((index + delta, String(parts[0])))
        }
        guard Set(rows.map(\.name)).count == rows.count, Set(rows.map(\.position)).count == rows.count,
              rows.allSatisfy({ $0.position >= 0 && $0.position < rows.count }) else {
            diagnostics.append("Invalid ordering metadata for \(folder); using stable archive order."); return names
        }
        let listed = rows.sorted { $0.position < $1.position }.map(\.name)
        if listed.count != names.count { diagnostics.append("Unlisted library entries appended for \(folder).") }
        return listed + names.filter { !listed.contains($0) }
    }
    private static func required(_ data: Data?, _ name: String) throws -> Data {
        guard let data else { throw BrushImportError.invalid("Missing " + name) }; return data
    }
    private static func propertyList(_ data: Data) throws -> Any {
        guard data.count <= 2 * 1024 * 1024 else { throw BrushImportError.invalid("Property list exceeds 2 MiB.") }
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        var nodes = 0
        func walk(_ value: Any, depth: Int) throws {
            nodes += 1
            guard depth <= 64, nodes <= 100000 else { throw BrushImportError.invalid("Property list is too complex.") }
            if let array = value as? [Any] { for child in array { try walk(child, depth: depth + 1) } }
            else if let object = value as? [String: Any] { for child in object.values { try walk(child, depth: depth + 1) } }
        }
        try walk(plist, depth: 0)
        return plist
    }

    private struct KeyedBrush {
        let objects: [Any]
        let root: [String: Any]
        init(_ data: Data) throws {
            let raw = try propertyList(data)
            let normalized = try Self.normalize(raw)
            guard let archive = normalized as? [String: Any],
                  archive["$archiver"] as? String == "NSKeyedArchiver", let table = archive["$objects"] as? [Any],
                  table.count <= 10000, let top = archive["$top"] as? [String: Any],
                  let index = Self.uid(top["root"]), table.indices.contains(index),
                  let fields = table[index] as? [String: Any] else { throw BrushImportError.invalid("Invalid brush object table.") }
            objects = table; root = fields
            var visited = Set<Int>(), active = Set<Int>()
            func check(_ value: Any, depth: Int) throws {
                guard depth <= 64 else { throw BrushImportError.invalid("Archive object graph is too deep.") }
                if let reference = Self.uid(value) {
                    guard table.indices.contains(reference), !active.contains(reference) else { throw BrushImportError.invalid("Invalid or cyclic archive reference.") }
                    if visited.contains(reference) { return }
                    active.insert(reference); try check(table[reference], depth: depth + 1)
                    active.remove(reference); visited.insert(reference)
                } else if let list = value as? [Any] { for child in list { try check(child, depth: depth + 1) } }
                else if let object = value as? [String: Any] { for child in object.values { try check(child, depth: depth + 1) } }
            }
            for value in table { try check(value, depth: 0) }
        }
        private struct Reference { let index: Int }
        private static func uid(_ value: Any?) -> Int? { (value as? Reference)?.index }
        private static func normalize(_ value: Any) throws -> Any {
            if let array = value as? [Any] { return try array.map { try normalize($0) } }
            if let object = value as? [String: Any] { return try object.mapValues { try normalize($0) } }
            if value is NSString || value is NSNumber || value is NSData || value is NSDate { return value }
            // Serialize only the native UID scalar, not the whole archive: repeated large data objects
            // in a binary plist must never expand into an unbounded intermediate XML document.
            let xml = try PropertyListSerialization.data(fromPropertyList: ["reference": value], format: .xml, options: 0)
            guard xml.count <= 1024, let text = String(data: xml, encoding: .utf8),
                  let start = text.range(of: "<integer>"),
                  let end = text.range(of: "</integer>", range: start.upperBound..<text.endIndex),
                  let index = Int(text[start.upperBound..<end.lowerBound]) else {
                throw BrushImportError.invalid("Invalid archive reference type.")
            }
            return Reference(index: index)
        }
        func string(_ key: String) throws -> String? {
            guard var value = root[key] else { return nil }
            for _ in 0..<64 {
                guard let index = Self.uid(value) else { break }
                if index == 0 { return nil }
                value = objects[index]
            }
            guard let text = value as? String else { throw BrushImportError.invalid("Invalid string field: " + key) }
            return text == "$null" ? nil : text
        }
    }
}
