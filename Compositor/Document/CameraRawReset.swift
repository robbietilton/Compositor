import Foundation

/// The Camera Raw panel's sections, each of which can be put back to its defaults on its own.
nonisolated enum CameraRawGroup: String, CaseIterable, Sendable {
    case light = "Light"
    case color = "Color"
    case effects = "Effects"
    case curve = "Curve"
    case mixer = "Color Mixer"
    case grading = "Color Grading"
    case detail = "Detail"
    case optics = "Optics"
    case geometry = "Geometry"
    case calibration = "Calibration"
}

nonisolated extension CameraRawSettings {
    /// These settings with `group` back to its defaults, choices and midpoints included; the other sections unchanged.
    func resetting(_ group: CameraRawGroup) -> Self {
        var result = self
        Self.copy(group, from: CameraRawSettings(), to: &result)
        return result
    }

    /// New settings carrying only `group` from these.
    func keeping(_ group: CameraRawGroup) -> Self {
        var result = CameraRawSettings()
        Self.copy(group, from: self, to: &result)
        return result
    }

    /// Whether `group` is as new settings have it, so there is nothing to reset.
    func isDefault(_ group: CameraRawGroup) -> Bool { keeping(group) == CameraRawSettings() }

    private static func copy(_ group: CameraRawGroup, from source: Self, to target: inout Self) {
        switch group {
        case .light:
            target.exposure = source.exposure
            target.contrast = source.contrast
            target.highlights = source.highlights
            target.shadows = source.shadows
            target.whites = source.whites
            target.blacks = source.blacks
        case .color:
            target.whiteBalance = source.whiteBalance
            target.temperature = source.temperature
            target.tint = source.tint
            target.vibrance = source.vibrance
            target.saturation = source.saturation
        case .effects:
            target.texture = source.texture
            target.clarity = source.clarity
            target.dehaze = source.dehaze
            target.glow = source.glow
            target.glowStyle = source.glowStyle
            target.glowRange = source.glowRange
            target.glowSpread = source.glowSpread
            target.glowWarmth = source.glowWarmth
            target.vignetteAmount = source.vignetteAmount
            target.vignetteStyle = source.vignetteStyle
            target.vignetteMidpoint = source.vignetteMidpoint
            target.vignetteRoundness = source.vignetteRoundness
            target.vignetteFeather = source.vignetteFeather
            target.vignetteHighlights = source.vignetteHighlights
            target.grainAmount = source.grainAmount
            target.grainSize = source.grainSize
            target.grainRoughness = source.grainRoughness
        case .curve: target.curve = source.curve
        case .mixer: target.mixer = source.mixer
        case .grading: target.grading = source.grading
        case .detail: target.detail = source.detail
        case .optics: target.optics = source.optics
        case .geometry: target.geometry = source.geometry
        case .calibration: target.calibration = source.calibration
        }
    }
}

extension FilterEdit {
    /// Whether the panel's eye for `group` is open.
    func shows(_ group: CameraRawGroup) -> Bool {
        switch group {
        case .light: return showsCameraRawLight
        case .color: return showsCameraRawColor
        case .effects: return showsCameraRawEffects
        case .curve: return showsCameraRawCurve
        case .mixer: return showsCameraRawMixer
        case .grading: return showsCameraRawGrading
        case .detail: return showsCameraRawDetail
        case .optics: return showsCameraRawOptics
        case .geometry: return showsCameraRawGeometry
        case .calibration: return showsCameraRawCalibration
        }
    }

    func setShows(_ group: CameraRawGroup, _ shown: Bool) {
        switch group {
        case .light: showsCameraRawLight = shown
        case .color: showsCameraRawColor = shown
        case .effects: showsCameraRawEffects = shown
        case .curve: showsCameraRawCurve = shown
        case .mixer: showsCameraRawMixer = shown
        case .grading: showsCameraRawGrading = shown
        case .detail: showsCameraRawDetail = shown
        case .optics: showsCameraRawOptics = shown
        case .geometry: showsCameraRawGeometry = shown
        case .calibration: showsCameraRawCalibration = shown
        }
    }
}

extension EditorSession {
    /// Puts one section of the open Camera Raw panel back to its defaults. The section shows again, since its eye
    /// only appears while it changes something: left hidden, the next change to it would be made unseen.
    func resetCameraRaw(_ group: CameraRawGroup) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        var settings = edit.settings
        settings.cameraRaw = settings.cameraRaw.resetting(group)
        edit.setShows(group, true)
        if group == .mixer { edit.cameraRawPointIndex = 0 }
        if group == .geometry { edit.cameraRawGuideDraft = nil }
        updateFilter(settings, preview: edit.preview)
    }
}
