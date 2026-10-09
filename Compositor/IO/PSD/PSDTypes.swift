import CoreGraphics
import Foundation
import UniformTypeIdentifiers

nonisolated enum PSDError: LocalizedError, Equatable {
    case truncated, unsupportedVersion, unsupportedColorMode, unsupportedDepth, unsupportedCompression
    var errorDescription: String? {
        switch self {
        case .truncated: String(localized: "The Photoshop file could not be read. It may be damaged or incomplete.")
        case .unsupportedVersion: String(localized: "This Photoshop file uses a format version Compositor can’t read.")
        case .unsupportedColorMode: String(localized: "Only 8-bit RGB Photoshop files can be imported.")
        case .unsupportedDepth: String(localized: "Only 8-bit RGB Photoshop files can be imported.")
        case .unsupportedCompression: String(localized: "This Photoshop file uses a layer compression method that isn’t supported.")
        }
    }
}

nonisolated struct PSDConversion: Identifiable, Equatable, Sendable {
    let id: UUID
    let layerName: String
    let message: LocalizedStringResource
    init(id: UUID = UUID(), layerName: String, message: LocalizedStringResource) {
        self.id = id
        self.layerName = layerName
        self.message = message
    }
}

nonisolated struct PSDDocument: @unchecked Sendable {
    var width: Int
    var height: Int
    var resolution: Double
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
    var shapeNotes: [LocalizedStringResource] = []
    /// Parsed Photoshop type, when the `TySh` block maps onto an editable text layer.
    var text: PSDText.Source?
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
