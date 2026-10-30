import CoreGraphics
import Foundation
import UniformTypeIdentifiers

nonisolated enum PSDError: LocalizedError, Equatable {
    case truncated, unsupportedVersion, unsupportedColorMode, unsupportedDepth, unsupportedCompression
    var errorDescription: String? {
        switch self {
        case .truncated: "The Photoshop file could not be read. It may be damaged or incomplete."
        case .unsupportedVersion: "This Photoshop file uses a format version Compositor can’t read."
        case .unsupportedColorMode: "Only 8-bit RGB and CMYK Photoshop files can be imported."
        case .unsupportedDepth: "Only 8-bit RGB and CMYK Photoshop files can be imported."
        case .unsupportedCompression: "This Photoshop file uses a layer compression method that isn’t supported."
        }
    }
}

nonisolated struct PSDConversion: Identifiable, Equatable, Sendable {
    let id: UUID
    let layerName: String
    let message: String
    init(id: UUID = UUID(), layerName: String, message: String) {
        self.id = id
        self.layerName = layerName
        self.message = message
    }
}

struct PSDConversionRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let confirmTitle: String
    var conversions: [PSDConversion]
    /// The file is still being read: the sheet is up so the click feels answered, but it has
    /// nothing to report yet.
    var isReading: Bool
    init(id: UUID = UUID(), title: String, confirmTitle: String, conversions: [PSDConversion], isReading: Bool = false) {
        self.id = id
        self.title = title
        self.confirmTitle = confirmTitle
        self.conversions = conversions
        self.isReading = isReading
    }
}

nonisolated struct PSDDocument: @unchecked Sendable {
    var width: Int
    var height: Int
    var resolution: Double
    /// A CMYK file's profile, which its layers were converted to RGB through; nil for an RGB file.
    var cmykProfile: CMYKProfile?
    /// Bottom to top, including folders. Hidden section dividers are not stored.
    var layers: [PSDRecord]
}

nonisolated struct PSDRecord: @unchecked Sendable {
    var id: UUID
    var parentID: UUID?
    var name: String
    var isGroup = false
    var isVisible = true
    var opacity: Double = 1
    var blendKey = "norm"
    var clipping = false
    var croppedToCanvas = false
    var bounds = CGRect.zero
    var image: CGImage?
    var mask: CGImage?
    /// Where `mask` sits on the document, and the value everywhere outside it: Photoshop stores only the part of a
    /// mask that isn't that default.
    var maskBounds = CGRect.zero
    var maskDefault: UInt8 = 255
    var maskEnabled = true
    var maskLinked = true
    var adjustment: LayerAdjustment?
    var kind = PSDLayerKind.raster
    var shape: LayerShapeStyle?
    var shapeNotes: [String] = []
    /// Parsed Photoshop type, when the `TySh` block maps onto an editable text layer.
    var text: PSDText.Source?
    /// An artboard folder's rectangle on the canvas.
    var artboard: CGRect?
}

extension PSDDocument {
    /// A file with artboards as one document per artboard, in the file's order (the bottom of Photoshop's Layers panel
    /// first, which is usually the first artboard made): each the artboard's size, with its layers moved
    /// so the artboard's corner is the canvas's and no artboard folder around them. Nil for a file without artboards.
    /// Layers outside every artboard belong to none, so none of the documents has them.
    nonisolated func artboards() -> [(name: String, document: PSDDocument)]? {
        let boards = layers.filter { $0.isGroup && $0.artboard != nil }
        guard !boards.isEmpty else { return nil }
        let ids = Set(boards.map(\.id))
        let parents = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0.parentID) })
        func board(of id: UUID) -> UUID? {
            var next = parents[id] ?? nil
            while let parent = next {
                if ids.contains(parent) { return parent }
                next = parents[parent] ?? nil
            }
            return nil
        }
        return boards.compactMap { artboard in
            guard let rect = artboard.artboard?.integral else { return nil }
            let width = Int(rect.width), height = Int(rect.height)
            guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
                  width * height <= DocumentLimits.maxSurfacePixels else { return nil }
            let shift = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            let inside = layers.filter { board(of: $0.id) == artboard.id }.map { record -> PSDRecord in
                var moved = record
                if moved.parentID == artboard.id { moved.parentID = nil }
                moved.bounds = moved.isGroup ? CGRect(x: 0, y: 0, width: width, height: height) : moved.bounds.applying(shift)
                moved.maskBounds = moved.maskBounds.applying(shift)
                if let anchor = moved.text?.documentAnchor { moved.text?.documentAnchor = anchor.applying(shift) }
                return moved
            }
            return (artboard.name, PSDDocument(width: width, height: height, resolution: resolution, cmykProfile: cmykProfile,
                                               layers: inside))
        }
    }
}

nonisolated enum PSDLayerKind: Equatable, Sendable {
    case raster, group, adjustment, text, smartObject, effects, vector, other
}

extension LayerBlendMode {
    nonisolated static func fromPSD(_ key: String) -> LayerBlendMode? {
        switch key {
        case "norm": .normal
        case "mul ": .multiply
        case "scrn": .screen
        case "over": .overlay
        case "sLit": .softLight
        case "dark": .darken
        case "lite": .lighten
        case "diff": .difference
        case "div ": .colorDodge
        case "idiv": .colorBurn
        case "hue ": .hue
        case "sat ": .saturation
        case "colr": .color
        case "lum ": .luminosity
        case "lbrn": .linearBurn
        case "lddg": .linearDodge
        case "hLit": .hardLight
        case "vLit": .vividLight
        case "lLit": .linearLight
        case "pLit": .pinLight
        case "hMix": .hardMix
        case "smud": .exclusion
        case "fsub": .subtract
        case "fdiv": .divide
        // Dissolve, Darker Color and Lighter Color are deliberately absent: Compositor has no
        // equivalent, so they fall through to Normal and say so in the conversion report.
        default: nil
        }
    }
}

extension PSDRecord {
    nonisolated var blendMode: LayerBlendMode? { LayerBlendMode.fromPSD(blendKey) }
}
