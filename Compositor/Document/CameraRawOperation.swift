import Foundation

/// A nondestructive plugin operation. Keep the original JSON bytes, including fields this app does not understand.
nonisolated struct CameraRawOperation: Codable, Equatable, Sendable {
    static let currentPluginID = "compositor.camera-raw"
    static let currentSchemaVersion = 1
    static let maximumPayloadBytes = 64 * 1024

    var pluginID: String
    var schemaVersion: Int
    /// Codable writes Data as base64, so loading and saving never reformats the plugin's JSON.
    var payload: Data
    var seed: UInt32

    init(payload: Data, seed: UInt32 = 0, pluginID: String = "compositor.camera-raw", schemaVersion: Int = 1) {
        self.pluginID = pluginID
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.seed = seed
    }

    /// Unknown plugins and schemas stay opaque. Never repair malformed settings while opening a project.
    var settings: CameraRawSettings? {
        guard hasValidMetadata, pluginID == Self.currentPluginID, schemaVersion == Self.currentSchemaVersion,
              let settings = try? JSONDecoder().decode(CameraRawSettings.self, from: payload),
              settings.isValid, Self.validNestedSettings(settings) else { return nil }
        return settings
    }

    var isValid: Bool {
        hasValidMetadata && (pluginID != Self.currentPluginID || schemaVersion != Self.currentSchemaVersion || settings != nil)
    }

    private var hasValidMetadata: Bool {
        !pluginID.isEmpty && pluginID.utf8.count <= 256
            && pluginID == pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
            && !pluginID.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && schemaVersion >= 1 && payload.count <= Self.maximumPayloadBytes
    }

    /// The destructive filter normalizes drafts before rendering. Persisted operations must instead reject bad fields,
    /// including inactive panels, so a later edit cannot turn hidden malformed values into a different grade.
    private static func validNestedSettings(_ settings: CameraRawSettings) -> Bool {
        let curve = settings.curve
        guard valid([curve.shadows, curve.darks, curve.lights, curve.highlights, curve.refineSaturation], in: -100...100),
              valid([curve.shadowSplit], in: 5...90),
              valid([curve.darkSplit], in: curve.shadowSplit + 2...95),
              valid([curve.lightSplit], in: curve.darkSplit + 2...98),
              [curve.rgb, curve.red, curve.green, curve.blue].allSatisfy(validCurve) else { return false }

        let mixer = settings.mixer
        guard [mixer.hue, mixer.saturation, mixer.luminance].allSatisfy({ $0.count == 8 && valid($0, in: -100...100) }),
              mixer.points.count <= 8,
              mixer.points.allSatisfy({ point in
                  valid([point.hue], in: 0...360) && valid([point.saturation, point.luminance], in: 0...1)
                      && valid([point.hueShift, point.saturationShift, point.luminanceShift], in: -100...100)
                      && valid([point.hueRange], in: 5...180)
                      && valid([point.saturationRange, point.luminanceRange], in: 0.05...1)
              }) else { return false }

        let grading = settings.grading
        guard valid([grading.blending], in: 0...100), valid([grading.balance], in: -100...100),
              grading.wheels.allSatisfy({ wheel in
                  valid([wheel.hue], in: 0...360) && valid([wheel.saturation], in: 0...100)
                      && valid([wheel.luminance], in: -100...100)
              }) else { return false }

        let detail = settings.detail
        guard valid([detail.sharpenAmount], in: CameraRawDetailSettings.sharpenAmountRange),
              valid([detail.sharpenRadius, detail.sharpenDetail, detail.sharpenMasking, detail.noiseLuminance,
                     detail.noiseLuminanceDetail, detail.noiseLuminanceContrast, detail.noiseColor,
                     detail.noiseColorDetail, detail.noiseColorSmoothness], in: CameraRawDetailSettings.unitRange) else { return false }

        let optics = settings.optics
        guard valid([optics.profileDistortion, optics.profileVignetting, optics.purpleAmount, optics.greenAmount,
                     optics.vignetteMidpoint], in: CameraRawOpticsSettings.unitRange),
              valid([optics.distortion, optics.vignetteAmount], in: CameraRawOpticsSettings.toneRange),
              valid([optics.purpleHueLow, optics.purpleHueHigh, optics.greenHueLow, optics.greenHueHigh],
                    in: CameraRawOpticsSettings.hueRange),
              optics.purpleHueLow <= optics.purpleHueHigh, optics.greenHueLow <= optics.greenHueHigh else { return false }

        let geometry = settings.geometry
        guard valid([geometry.vertical, geometry.horizontal, geometry.aspect, geometry.scale, geometry.offsetX,
                     geometry.offsetY], in: CameraRawGeometrySettings.toneRange),
              valid([geometry.rotate], in: CameraRawGeometrySettings.rotateRange),
              geometry.guides.allSatisfy({ guide in
                  valid([guide.startX, guide.startY, guide.endX, guide.endY], in: 0...1)
              }) else { return false }

        let calibration = settings.calibration
        return valid([calibration.shadowTint, calibration.redHue, calibration.redSaturation, calibration.greenHue,
                      calibration.greenSaturation, calibration.blueHue, calibration.blueSaturation],
                     in: CameraRawCalibrationSettings.toneRange)
    }

    private static func valid(_ values: [Double], in range: ClosedRange<Double>) -> Bool {
        values.allSatisfy { $0.isFinite && range.contains($0) }
    }

    private static func validCurve(_ points: [CurvePoint]) -> Bool {
        points.count >= 2 && points.first?.x == 0 && points.last?.x == 1
            && points.allSatisfy { valid([$0.x, $0.y], in: 0...1) }
            && zip(points, points.dropFirst()).allSatisfy { $0.x < $1.x }
    }
}
