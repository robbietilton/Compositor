import AppKit

/// Sharpening and manual noise reduction. Amount is 0…150; the rest use Camera Raw's usual 0…100 ranges.
nonisolated struct CameraRawDetailSettings: Equatable, Sendable {
    var sharpenAmount: Double = 0
    var sharpenRadius: Double = 10
    var sharpenDetail: Double = 25
    var sharpenMasking: Double = 0
    var noiseLuminance: Double = 0
    var noiseLuminanceDetail: Double = 50
    var noiseLuminanceContrast: Double = 0
    var noiseColor: Double = 0
    var noiseColorDetail: Double = 50
    var noiseColorSmoothness: Double = 50

    static let sharpenAmountRange: ClosedRange<Double> = 0...150
    static let unitRange: ClosedRange<Double> = 0...100

    var adjustsSharpening: Bool { sharpenAmount != 0 }
    var adjustsNoise: Bool { noiseLuminance != 0 || noiseColor != 0 }
    var adjusts: Bool { adjustsSharpening || adjustsNoise }

    var normalized: Self {
        var result = self
        result.sharpenAmount = ImageAdjustmentPixels.clamp(sharpenAmount, Self.sharpenAmountRange, 0)
        result.sharpenRadius = ImageAdjustmentPixels.clamp(sharpenRadius, Self.unitRange, 10)
        result.sharpenDetail = ImageAdjustmentPixels.clamp(sharpenDetail, Self.unitRange, 25)
        result.sharpenMasking = ImageAdjustmentPixels.clamp(sharpenMasking, Self.unitRange, 0)
        result.noiseLuminance = ImageAdjustmentPixels.clamp(noiseLuminance, Self.unitRange, 0)
        result.noiseLuminanceDetail = ImageAdjustmentPixels.clamp(noiseLuminanceDetail, Self.unitRange, 50)
        result.noiseLuminanceContrast = ImageAdjustmentPixels.clamp(noiseLuminanceContrast, Self.unitRange, 0)
        result.noiseColor = ImageAdjustmentPixels.clamp(noiseColor, Self.unitRange, 0)
        result.noiseColorDetail = ImageAdjustmentPixels.clamp(noiseColorDetail, Self.unitRange, 50)
        result.noiseColorSmoothness = ImageAdjustmentPixels.clamp(noiseColorSmoothness, Self.unitRange, 50)
        return result
    }

    func applying(shows: Bool) -> Self { shows ? self : Self() }
}

/// Lens profile toggles, manual distortion, defringe, and lens-vignetting correction. Profile metadata is not
/// available on a rendered layer, so the profile sliders only scale generic correction strength.
nonisolated struct CameraRawOpticsSettings: Equatable, Sendable {
    var removeChromaticAberration = false
    var enableLensProfile = false
    var profileDistortion: Double = 100
    var profileVignetting: Double = 100
    /// −100…100, same sign convention as the Lens Correction filter.
    var distortion: Double = 0
    var purpleAmount: Double = 0
    /// Degrees on the color wheel, 0…360. The low handle must stay below the high handle.
    var purpleHueLow: Double = 270
    var purpleHueHigh: Double = 310
    var greenAmount: Double = 0
    var greenHueLow: Double = 60
    var greenHueHigh: Double = 120
    /// Brightens the corners to counter lens falloff. Midpoint is 0…100.
    var vignetteAmount: Double = 0
    var vignetteMidpoint: Double = 50

    static let toneRange: ClosedRange<Double> = -100...100
    static let unitRange: ClosedRange<Double> = 0...100
    static let hueRange: ClosedRange<Double> = 0...360

    var adjusts: Bool {
        removeChromaticAberration || enableLensProfile || distortion != 0 || purpleAmount != 0 || greenAmount != 0
            || vignetteAmount != 0
    }

    var normalized: Self {
        var result = self
        result.profileDistortion = ImageAdjustmentPixels.clamp(profileDistortion, Self.unitRange, 100)
        result.profileVignetting = ImageAdjustmentPixels.clamp(profileVignetting, Self.unitRange, 100)
        result.distortion = ImageAdjustmentPixels.clamp(distortion, Self.toneRange, 0)
        result.purpleAmount = ImageAdjustmentPixels.clamp(purpleAmount, Self.unitRange, 0)
        result.greenAmount = ImageAdjustmentPixels.clamp(greenAmount, Self.unitRange, 0)
        result.vignetteAmount = ImageAdjustmentPixels.clamp(vignetteAmount, Self.toneRange, 0)
        result.vignetteMidpoint = ImageAdjustmentPixels.clamp(vignetteMidpoint, Self.unitRange, 50)
        result.purpleHueLow = ImageAdjustmentPixels.clamp(purpleHueLow, Self.hueRange, 270)
        result.purpleHueHigh = ImageAdjustmentPixels.clamp(purpleHueHigh, Self.hueRange, 310)
        result.greenHueLow = ImageAdjustmentPixels.clamp(greenHueLow, Self.hueRange, 60)
        result.greenHueHigh = ImageAdjustmentPixels.clamp(greenHueHigh, Self.hueRange, 120)
        if result.purpleHueLow > result.purpleHueHigh { swap(&result.purpleHueLow, &result.purpleHueHigh) }
        if result.greenHueLow > result.greenHueHigh { swap(&result.greenHueLow, &result.greenHueHigh) }
        return result
    }

    func applying(shows: Bool) -> Self { shows ? self : Self() }

    /// Combined radial distortion passed to `lens_distort`, matching the Lens Correction filter scale.
    func distortionK(profileStrength: Double) -> Double {
        let manual = distortion / 100 * profileStrength
        let profile = enableLensProfile ? profileDistortion / 100 * profileStrength : 0
        return manual + profile
    }
}

nonisolated extension CameraRawSettings {
    func applyDetailOptics(pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int, scale: Double,
                           profileStrength: Double, sharpenMask: Bool) {
        let detail = detail.normalized
        let optics = optics.normalized
        if sharpenMask {
            adjust_camera_raw_sharpen_mask_overlay(pixels, width, height, stride,
                                                     detail.sharpenRadius, detail.sharpenDetail, detail.sharpenMasking, scale)
            return
        }
        if optics.adjusts {
            adjust_camera_raw_optics(pixels, width, height, stride,
                                     optics.removeChromaticAberration ? 1 : 0,
                                     optics.enableLensProfile ? 1 : 0,
                                     optics.profileDistortion, optics.profileVignetting,
                                     optics.distortionK(profileStrength: profileStrength),
                                     optics.purpleAmount, optics.purpleHueLow, optics.purpleHueHigh,
                                     optics.greenAmount, optics.greenHueLow, optics.greenHueHigh,
                                     optics.vignetteAmount, optics.vignetteMidpoint, scale)
        }
        if detail.adjusts {
            adjust_camera_raw_detail(pixels, width, height, stride,
                                     detail.sharpenAmount, detail.sharpenRadius, detail.sharpenDetail, detail.sharpenMasking,
                                     detail.noiseLuminance, detail.noiseLuminanceDetail, detail.noiseLuminanceContrast,
                                     detail.noiseColor, detail.noiseColorDetail, detail.noiseColorSmoothness, scale)
        }
    }
}
