import AppKit

/// White balance on an already-rendered layer. Raw lighting presets are absent: temperature and tint
/// are relative offsets, not kelvin.
nonisolated enum CameraRawWhiteBalance: String, CaseIterable, Sendable, Codable {
    case custom = "Custom"
    case auto = "Auto"
}

/// Glow's three looks. Warmth tints Diffusion and Bloom from cool to warm; Halation's fringe stays red.
nonisolated enum CameraRawGlowStyle: String, CaseIterable, Sendable, Codable {
    case diffusion = "Diffusion"
    case bloom = "Bloom"
    case halation = "Halation"
    var kernelValue: Int32 {
        switch self {
        case .diffusion: return 0
        case .bloom: return 1
        case .halation: return 2
        }
    }
}

/// Post-crop vignette. Highlight Priority is the style whose Highlights slider protects bright pixels.
nonisolated enum CameraRawVignetteStyle: String, CaseIterable, Sendable, Codable {
    case highlightPriority = "Highlight Priority"
    case colorPriority = "Color Priority"
    case paintOverlay = "Paint Overlay"
    var kernelValue: Int32 {
        switch self {
        case .highlightPriority: return 0
        case .colorPriority: return 1
        case .paintOverlay: return 2
        }
    }
}

/// Temporary clipping view while Option is held on a Light slider. Never written into the layer.
nonisolated enum CameraRawClipping: Int32, Sendable {
    /// Clipped channels lit on black. Exposure, Highlights, and Whites.
    case highlights = 1
    /// Clipped channels dark on white. Shadows and Blacks.
    case shadows = 2
}

/// Camera Raw Filter settings. Defaults leave the image unchanged.
nonisolated struct CameraRawSettings: Equatable, Sendable, Codable {
    static let exposureRange: ClosedRange<Double> = -5...5
    static let toneRange: ClosedRange<Double> = -100...100
    static let unitRange: ClosedRange<Double> = 0...100
    /// Share of a full warm/cool swing applied to red and blue. Kept here so the eyedropper inverts the same gains the kernel multiplies.
    static let temperatureGain = 0.35
    /// Magenta/green swing shared by red and blue.
    static let tintRedBlue = 0.15
    /// Magenta/green swing on green, opposite the other two channels.
    static let tintGreen = 0.30

    var whiteBalance: CameraRawWhiteBalance = .custom
    /// Relative cool-to-warm, −100…100. Positive is warmer.
    var temperature: Double = 0
    /// Green-to-magenta, −100…100. Positive is magenta.
    var tint: Double = 0
    /// Stops of linear light, −5…5.
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    /// Local contrast, −100…100. Texture is the finer band; Clarity is the broader one.
    var texture: Double = 0
    var clarity: Double = 0
    /// −100…100. Positive deepens contrast and saturation; negative lifts shadows and fades color.
    var dehaze: Double = 0
    /// 0…100. Range, spread, and warmth are idle while this stays at zero.
    var glow: Double = 0
    var glowStyle: CameraRawGlowStyle = .diffusion
    var glowRange: Double = 0
    var glowSpread: Double = 0
    var glowWarmth: Double = 0
    /// −100…100. Negative darkens the edges, positive lightens them. The center is left alone.
    var vignetteAmount: Double = 0
    var vignetteStyle: CameraRawVignetteStyle = .highlightPriority
    var vignetteMidpoint: Double = 50
    var vignetteRoundness: Double = 0
    var vignetteFeather: Double = 50
    /// Used only while `vignetteAmount` darkens, and only for Highlight Priority.
    var vignetteHighlights: Double = 0
    /// 0…100. Zero adds no grain. Size is mapped into the shared grain kernel's pixel scale.
    var grainAmount: Double = 0
    var grainSize: Double = 25
    var grainRoughness: Double = 50
    var curve = CameraRawCurveSettings()
    var mixer = CameraRawMixerSettings()
    var grading = CameraRawGradingSettings()
    var detail = CameraRawDetailSettings()
    var optics = CameraRawOpticsSettings()
    var geometry = CameraRawGeometrySettings()
    var calibration = CameraRawCalibrationSettings()

    var adjustsLight: Bool {
        exposure != 0 || contrast != 0 || highlights != 0 || shadows != 0 || whites != 0 || blacks != 0
    }
    var adjustsColor: Bool {
        temperature != 0 || tint != 0 || vibrance != 0 || saturation != 0
    }
    var adjustsEffects: Bool {
        texture != 0 || clarity != 0 || dehaze != 0 || glow != 0 || vignetteAmount != 0 || grainAmount != 0
    }
    var adjustsCurve: Bool { curve.adjusts }
    var adjustsMixer: Bool { mixer.adjusts }
    var adjustsGrading: Bool { grading.adjusts }
    var adjustsDetail: Bool { detail.adjusts }
    var adjustsOptics: Bool { optics.adjusts }
    var adjustsGeometry: Bool { geometry.adjusts }
    var adjustsCalibration: Bool { calibration.adjusts }
    var isIdentity: Bool {
        !adjustsLight && !adjustsColor && !adjustsEffects && !adjustsCurve && !adjustsMixer && !adjustsGrading
            && !adjustsDetail && !adjustsOptics && !adjustsGeometry && !adjustsCalibration
    }
    var isValid: Bool {
        Self.exposureRange.contains(exposure) && exposure.isFinite
            && [contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation,
            texture, clarity, dehaze, glowRange, glowSpread, glowWarmth, vignetteAmount, vignetteRoundness].allSatisfy {
                $0.isFinite && Self.toneRange.contains($0)
            }
        && [glow, vignetteMidpoint, vignetteFeather, vignetteHighlights, grainAmount, grainSize, grainRoughness].allSatisfy {
            $0.isFinite && Self.unitRange.contains($0)
        }
    }
    var normalized: Self {
        var result = self
        result.exposure = ImageAdjustmentPixels.clamp(exposure, Self.exposureRange, 0)
        result.contrast = ImageAdjustmentPixels.clamp(contrast, Self.toneRange, 0)
        result.highlights = ImageAdjustmentPixels.clamp(highlights, Self.toneRange, 0)
        result.shadows = ImageAdjustmentPixels.clamp(shadows, Self.toneRange, 0)
        result.whites = ImageAdjustmentPixels.clamp(whites, Self.toneRange, 0)
        result.blacks = ImageAdjustmentPixels.clamp(blacks, Self.toneRange, 0)
        result.temperature = ImageAdjustmentPixels.clamp(temperature, Self.toneRange, 0)
        result.tint = ImageAdjustmentPixels.clamp(tint, Self.toneRange, 0)
        result.vibrance = ImageAdjustmentPixels.clamp(vibrance, Self.toneRange, 0)
        result.saturation = ImageAdjustmentPixels.clamp(saturation, Self.toneRange, 0)
        result.texture = ImageAdjustmentPixels.clamp(texture, Self.toneRange, 0)
        result.clarity = ImageAdjustmentPixels.clamp(clarity, Self.toneRange, 0)
        result.dehaze = ImageAdjustmentPixels.clamp(dehaze, Self.toneRange, 0)
        result.glow = ImageAdjustmentPixels.clamp(glow, Self.unitRange, 0)
        result.glowRange = ImageAdjustmentPixels.clamp(glowRange, Self.toneRange, 0)
        result.glowSpread = ImageAdjustmentPixels.clamp(glowSpread, Self.toneRange, 0)
        result.glowWarmth = ImageAdjustmentPixels.clamp(glowWarmth, Self.toneRange, 0)
        result.vignetteAmount = ImageAdjustmentPixels.clamp(vignetteAmount, Self.toneRange, 0)
        result.vignetteMidpoint = ImageAdjustmentPixels.clamp(vignetteMidpoint, Self.unitRange, 50)
        result.vignetteRoundness = ImageAdjustmentPixels.clamp(vignetteRoundness, Self.toneRange, 0)
        result.vignetteFeather = ImageAdjustmentPixels.clamp(vignetteFeather, Self.unitRange, 50)
        result.vignetteHighlights = ImageAdjustmentPixels.clamp(vignetteHighlights, Self.unitRange, 0)
        result.grainAmount = ImageAdjustmentPixels.clamp(grainAmount, Self.unitRange, 0)
        result.grainSize = ImageAdjustmentPixels.clamp(grainSize, Self.unitRange, 25)
        result.grainRoughness = ImageAdjustmentPixels.clamp(grainRoughness, Self.unitRange, 50)
        result.curve = curve.normalized
        result.mixer = mixer.normalized
        result.grading = grading.normalized
        result.detail = detail.normalized
        result.optics = optics.normalized
        result.geometry = geometry.normalized
        result.calibration = calibration.normalized
        return result
    }

    /// The grade with a panel's eye turned off: that group's amounts become zero and the rest stay.
    func applying(showsLight: Bool, showsColor: Bool, showsEffects: Bool = true, showsCurve: Bool = true, showsMixer: Bool = true,
                  showsGrading: Bool = true, showsDetail: Bool = true, showsOptics: Bool = true, showsGeometry: Bool = true,
                  showsCalibration: Bool = true) -> Self {
        var result = self
        if !showsLight {
            result.exposure = 0
            result.contrast = 0
            result.highlights = 0
            result.shadows = 0
            result.whites = 0
            result.blacks = 0
        }
        if !showsColor {
            result.temperature = 0
            result.tint = 0
            result.vibrance = 0
            result.saturation = 0
        }
        if !showsEffects {
            result.texture = 0
            result.clarity = 0
            result.dehaze = 0
            result.glow = 0
            result.vignetteAmount = 0
            result.grainAmount = 0
        }
        if !showsCurve { result.curve = CameraRawCurveSettings() }
        if !showsMixer { result.mixer = CameraRawMixerSettings() }
        if !showsGrading { result.grading = CameraRawGradingSettings() }
        if !showsDetail { result.detail = CameraRawDetailSettings() }
        if !showsOptics { result.optics = CameraRawOpticsSettings() }
        if !showsGeometry { result.geometry = CameraRawGeometrySettings() }
        if !showsCalibration { result.calibration = CameraRawCalibrationSettings() }
        return result
    }

    /// Camera Raw's 0…100 size, in the pixel scale `adjust_grain` already uses.
    var grainKernelSize: Double { 0.5 + (grainSize / 100) * 19.5 }

    /// Channel multipliers for `temperature` and `tint`. Neutral is 1, 1, 1.
    var gains: (red: Double, green: Double, blue: Double) {
        let warm = temperature / 100
        let magenta = tint / 100
        return (1 + Self.temperatureGain * warm + Self.tintRedBlue * magenta,
                1 - Self.tintGreen * magenta,
                1 - Self.temperatureGain * warm + Self.tintRedBlue * magenta)
    }

    /// `clipping` draws the Option-drag overlay instead of the grade. Nil renders the image.
    /// `scale` is preview pixels per layer pixel. Grain uses `seed` so the pattern stays put while the panel is open.
    func apply(_ image: CGImage, clipping: CameraRawClipping? = nil, scale: CGFloat = 1, seed: UInt32 = 0, visualizePointColor: Int = -1,
               sharpenMask: Bool = false) throws -> CGImage {
        let settings = normalized
        if settings.isIdentity && clipping == nil && visualizePointColor < 0 && !sharpenMask { return image }
        guard settings.isValid else { throw ProjectError.invalid }
        let gains = settings.gains
        let mode = clipping?.rawValue ?? 0
        let pixelScale = scale > 0 ? Double(scale) : 1
        let paintColor = clipping == nil && !sharpenMask
            && (settings.adjustsCurve || settings.adjustsMixer || settings.adjustsGrading || visualizePointColor >= 0)
        let paintEffects = clipping == nil && !sharpenMask && settings.adjustsEffects
        let paintDetailOptics = clipping == nil && (settings.adjustsDetail || settings.adjustsOptics || sharpenMask)
        var source = image
        if clipping == nil && !sharpenMask && visualizePointColor < 0 && settings.adjustsGeometry {
            source = try settings.geometry.apply(source)
        }
        return try ImageAdjustmentPixels.run(source) { pixels, width, height, stride in
            if clipping == nil && !sharpenMask && settings.adjustsCalibration {
                settings.applyCalibration(pixels: pixels, width: width, height: height, stride: stride)
            }
            if settings.adjustsLight || settings.adjustsColor || clipping != nil {
                adjust_camera_raw(pixels, width, height, stride, gains.red, gains.green, gains.blue,
                                  settings.exposure, settings.contrast, settings.highlights, settings.shadows,
                                  settings.whites, settings.blacks, settings.vibrance, settings.saturation, mode)
            }
            if paintColor { settings.applyCurveColor(pixels, width: width, height: height, stride: stride, visualize: visualizePointColor) }
            if paintEffects {
                if settings.texture != 0 || settings.clarity != 0 || settings.dehaze != 0 || settings.glow != 0 || settings.vignetteAmount != 0 {
                    adjust_camera_raw_effects(pixels, width, height, stride,
                                              settings.texture, settings.clarity, settings.dehaze,
                                              settings.glow, settings.glowStyle.kernelValue, settings.glowRange,
                                              settings.glowSpread, settings.glowWarmth,
                                              settings.vignetteAmount, settings.vignetteMidpoint, settings.vignetteRoundness,
                                              settings.vignetteFeather, settings.vignetteHighlights, settings.vignetteStyle.kernelValue,
                                              pixelScale)
                }
                if settings.grainAmount > 0 {
                    adjust_grain(pixels, width, height, stride, settings.grainAmount, settings.grainKernelSize,
                                 settings.grainRoughness, seed, 0, 0, 1 / pixelScale)
                }
            }
            if paintDetailOptics {
                settings.applyDetailOptics(pixels: pixels, width: width, height: height, stride: stride, scale: pixelScale,
                                           profileStrength: PixelFilter.lensStrength, sharpenMask: sharpenMask)
            }
        }
    }

    /// Temperature and tint that bring one linear-light pixel to neutral, using the same gains `apply` multiplies.
    /// Nil when a channel is missing or the cast cannot be expressed as those two axes.
    static func neutralize(linearRed red: Double, green: Double, blue: Double) -> (temperature: Double, tint: Double)? {
        guard red > 1e-4, green > 1e-4, blue > 1e-4 else { return nil }
        let a1 = Self.temperatureGain * red
        let b1 = Self.tintRedBlue * red + Self.tintGreen * green
        let c1 = green - red
        let a2 = -Self.temperatureGain * blue
        let b2 = Self.tintRedBlue * blue + Self.tintGreen * green
        let c2 = green - blue
        let determinant = a1 * b2 - a2 * b1
        guard abs(determinant) > 1e-8 else { return nil }
        let warm = (c1 * b2 - c2 * b1) / determinant
        let magenta = (a1 * c2 - a2 * c1) / determinant
        guard warm.isFinite, magenta.isFinite else { return nil }
        return (warm * 100, magenta * 100)
    }

    static func neutralize(straightRed red: Double, green: Double, blue: Double) -> (temperature: Double, tint: Double)? {
        neutralize(linearRed: decode(red), green: decode(green), blue: decode(blue))
    }

    /// Gray-world balance of the opaque pixels. Nil when the image has no coverage or no solution.
    static func autoBalance(of image: CGImage) -> (temperature: Double, tint: Double)? {
        guard let average = averageLinear(image) else { return nil }
        return neutralize(linearRed: average.red, green: average.green, blue: average.blue)
    }

    private static func decode(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    private static func averageLinear(_ image: CGImage) -> (red: Double, green: Double, blue: Double)? {
        guard image.width > 0, image.height > 0 else { return nil }
        let context = try? BrushRaster.context(width: image.width, height: image.height, mask: false)
        guard let context else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for y in 0..<image.height {
            let row = y * context.bytesPerRow
            for x in 0..<image.width {
                let pixel = row + x * 4
                let alpha = Double(bytes[pixel + 3])
                if alpha == 0 { continue }
                red += decode(min(1, Double(bytes[pixel]) / alpha))
                green += decode(min(1, Double(bytes[pixel + 1]) / alpha))
                blue += decode(min(1, Double(bytes[pixel + 2]) / alpha))
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (red / count, green / count, blue / count)
    }
}

/// Histogram or the vectorscope shown in its place.
nonisolated enum CameraRawScopeMode: String, Sendable {
    case histogram = "Histogram"
    case vectorscope = "Vectorscope"
}

/// One RGB histogram and a hue/saturation vectorscope of the same graded pixels.
nonisolated struct CameraRawScope: Equatable, Sendable {
    static let binCount = 256
    static let scopeSide = 64
    var red: [Double]
    var green: [Double]
    var blue: [Double]
    /// Density from the center outward. Index `y * scopeSide + x`.
    var vectorscope: [Double]

    /// Shared vertical scale so the three ribbons stay comparable.
    var peak: Double {
        max(LevelsHistogramDisplay.scale(for: red),
            LevelsHistogramDisplay.scale(for: green),
            LevelsHistogramDisplay.scale(for: blue))
    }

    /// Counts the graded image. Fully transparent pixels are skipped.
    static func make(_ image: CGImage) -> Self? {
        guard image.width > 0, image.height > 0 else { return nil }
        guard let context = try? BrushRaster.context(width: image.width, height: image.height, mask: false) else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var bins = Array(repeating: 0.0, count: binCount * 4)
        levels_histogram(bytes, nil, image.width * image.height, &bins)
        var scope = Array(repeating: 0.0, count: scopeSide * scopeSide)
        let stride = context.bytesPerRow
        for y in 0..<image.height {
            let row = y * stride
            for x in 0..<image.width {
                let pixel = row + x * 4
                let alpha = Double(bytes[pixel + 3])
                if alpha == 0 { continue }
                let red = min(1, Double(bytes[pixel]) / alpha)
                let green = min(1, Double(bytes[pixel + 1]) / alpha)
                let blue = min(1, Double(bytes[pixel + 2]) / alpha)
                let maxChannel = max(red, green, blue)
                let minChannel = min(red, green, blue)
                let chroma = maxChannel - minChannel
                guard chroma > 1e-4, maxChannel > 1e-4 else { continue }
                var hue: Double
                if maxChannel == red { hue = (green - blue) / chroma }
                else if maxChannel == green { hue = 2 + (blue - red) / chroma }
                else { hue = 4 + (red - green) / chroma }
                hue = hue / 6
                if hue < 0 { hue += 1 }
                let angle = hue * 2 * Double.pi
                let saturation = chroma / maxChannel
                let plotX = 0.5 + cos(angle) * saturation * 0.48
                let plotY = 0.5 + sin(angle) * saturation * 0.48
                let column = min(scopeSide - 1, max(0, Int(plotX * Double(scopeSide))))
                let rowIndex = min(scopeSide - 1, max(0, Int(plotY * Double(scopeSide))))
                scope[rowIndex * scopeSide + column] += alpha / 255
            }
        }
        return Self(red: Array(bins[256..<512]), green: Array(bins[512..<768]), blue: Array(bins[768..<1024]), vectorscope: scope)
    }

    /// Paints clipped shadows blue and clipped highlights red. The histogram is counted before this.
    static func overlay(_ image: CGImage, shadows: Bool, highlights: Bool) throws -> CGImage {
        guard shadows || highlights else { return image }
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_camera_raw_clip_overlay(pixels, width, height, stride, shadows ? 1 : 0, highlights ? 1 : 0)
        }
    }

    /// Preview image plus the scope of the grade itself, without Option-drag or indicator paint.
    static func preview(_ job: FilterJob) throws -> (image: CGImage, scope: Self) {
        var grade = job
        grade.cameraRawClipping = nil
        grade.showsShadowClipping = false
        grade.showsHighlightClipping = false
        grade.visualizesPointColor = -1
        grade.showsSharpenMask = false
        let graded = try PixelFilter.run(grade)
        let scope = make(graded) ?? Self(red: Array(repeating: 0, count: binCount), green: Array(repeating: 0, count: binCount),
                                         blue: Array(repeating: 0, count: binCount), vectorscope: Array(repeating: 0, count: scopeSide * scopeSide))
        if job.cameraRawClipping != nil || job.showsSharpenMask { return (try PixelFilter.run(job), scope) }
        if job.showsShadowClipping || job.showsHighlightClipping {
            return (try overlay(graded, shadows: job.showsShadowClipping, highlights: job.showsHighlightClipping), scope)
        }
        return (graded, scope)
    }
}

extension EditorSession {
    /// The white-balance eyedropper: the clicked pixel of the original layer becomes neutral.
    func sampleCameraRawWhiteBalance(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, edit.samplesWhiteBalance, !edit.committing,
              let document, CGRect(origin: .zero, size: document.size).contains(point) else { return }
        let pixel = point.applying(edit.mapping.inverted())
        let rect = CGRect(x: floor(pixel.x), y: floor(pixel.y), width: 1, height: 1)
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(edit.original.image.width),
              pixel.y < CGFloat(edit.original.image.height), let sample = edit.original.image.cropping(to: rect) else { return }
        do {
            let context = try BrushRaster.context(width: 1, height: 1, mask: false)
            BrushRaster.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: context)
            guard let data = context.data else { return }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            guard bytes[3] > 0 else { return }
            let rgb = (0..<3).map { min(1, Double(bytes[$0]) / Double(bytes[3])) }
            guard let solved = CameraRawSettings.neutralize(straightRed: rgb[0], green: rgb[1], blue: rgb[2]) else { return }
            var settings = edit.settings
            settings.cameraRaw.temperature = solved.temperature
            settings.cameraRaw.tint = solved.tint
            settings.cameraRaw.whiteBalance = .custom
            updateFilter(settings, preview: edit.preview)
        } catch { brushError = error.localizedDescription }
    }

    /// White Balance > Auto. The mode is stored before the scan, so the picker moves on the click.
    /// The average of the original layer is taken off the main thread, then applied only if Auto is still selected.
    func applyCameraRawAutoWhiteBalance() async {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        var settings = edit.settings
        settings.cameraRaw.whiteBalance = .auto
        updateFilter(settings, preview: edit.preview)
        let image = edit.original.image
        let solved = await Task.detached(priority: .userInitiated) {
            CameraRawSettings.autoBalance(of: image)
        }.value
        guard filterEdit === edit, !edit.committing, edit.settings.cameraRaw.whiteBalance == .auto, let solved else { return }
        settings = edit.settings
        settings.cameraRaw.temperature = solved.temperature
        settings.cameraRaw.tint = solved.tint
        updateFilter(settings, preview: edit.preview)
    }

    /// Defringe eyedropper: centers the purple or green hue range on the clicked fringe color.
    func sampleCameraRawDefringe(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, edit.samplesDefringe, !edit.committing,
              let document, CGRect(origin: .zero, size: document.size).contains(point) else { return }
        let pixel = point.applying(edit.mapping.inverted())
        let rect = CGRect(x: floor(pixel.x), y: floor(pixel.y), width: 1, height: 1)
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(edit.original.image.width),
              pixel.y < CGFloat(edit.original.image.height), let sample = edit.original.image.cropping(to: rect) else { return }
        do {
            let context = try BrushRaster.context(width: 1, height: 1, mask: false)
            BrushRaster.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: context)
            guard let data = context.data else { return }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            guard bytes[3] > 0 else { return }
            let r = min(1, Double(bytes[0]) / Double(bytes[3]))
            let g = min(1, Double(bytes[1]) / Double(bytes[3]))
            let b = min(1, Double(bytes[2]) / Double(bytes[3]))
            let hue = Self.hueDegrees(red: r, green: g, blue: b)
            var settings = edit.settings
            let purpleCenter = 290.0, greenCenter = 90.0
            let span = 25.0
            if abs(hue - purpleCenter) < abs(hue - greenCenter) {
                settings.cameraRaw.optics.purpleHueLow = hue - span
                settings.cameraRaw.optics.purpleHueHigh = hue + span
                if settings.cameraRaw.optics.purpleAmount == 0 { settings.cameraRaw.optics.purpleAmount = 50 }
            } else {
                settings.cameraRaw.optics.greenHueLow = hue - span
                settings.cameraRaw.optics.greenHueHigh = hue + span
                if settings.cameraRaw.optics.greenAmount == 0 { settings.cameraRaw.optics.greenAmount = 50 }
            }
            settings.cameraRaw.optics = settings.cameraRaw.optics.normalized
            updateFilter(settings, preview: edit.preview)
        } catch { brushError = error.localizedDescription }
    }

    private static func hueDegrees(red: Double, green: Double, blue: Double) -> Double {
        let maxc = max(red, green, blue), minc = min(red, green, blue)
        let chroma = maxc - minc
        guard chroma > 1e-6 else { return 0 }
        let hue: Double
        if maxc == red { hue = (green - blue) / chroma }
        else if maxc == green { hue = 2 + (blue - red) / chroma }
        else { hue = 4 + (red - green) / chroma }
        var degrees = hue * 60
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    /// RGB under the pointer while Camera Raw is open. Outside the layer clears the readout.
    func updateCameraRawReadout(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw else { return }
        let image = edit.preparedPreview ?? edit.previewSource
        let pixel = point.applying(edit.previewMapping.inverted())
        let rect = CGRect(x: floor(pixel.x), y: floor(pixel.y), width: 1, height: 1)
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(image.width), pixel.y < CGFloat(image.height),
              let sample = image.cropping(to: rect) else {
            edit.cameraRawReadout = nil
            return
        }
        guard let context = try? BrushRaster.context(width: 1, height: 1, mask: false) else { return }
        BrushRaster.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: context)
        guard let data = context.data else { return }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        guard bytes[3] > 0 else { edit.cameraRawReadout = nil; return }
        let straight = (0..<3).map { min(255, (Int(bytes[$0]) * 255 + Int(bytes[3]) / 2) / Int(bytes[3])) }
        edit.cameraRawReadout = (straight[0], straight[1], straight[2])
    }

    func beginCameraRawDrag(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, let sample = cameraRawSample(at: point) else { return }
        edit.cameraRawDrag = CameraRawDrag(startY: point.y, settings: edit.settings.cameraRaw, tone: sample.tone, hue: sample.hue)
    }

    func dragCameraRaw(to point: CGPoint) {
        guard let edit = filterEdit, let drag = edit.cameraRawDrag else { return }
        let delta = Double(drag.startY - point.y) * 0.35
        var settings = edit.settings
        settings.cameraRaw = drag.settings
        if edit.targetsCameraRawCurve {
            if edit.cameraRawCurvePage == .parametric {
                let key = drag.settings.curve.region(for: drag.tone)
                settings.cameraRaw.curve[keyPath: key] = min(100, max(-100, drag.settings.curve[keyPath: key] + delta))
            } else {
                settings.cameraRaw.curve = drag.settings.curve.nudged(edit.cameraRawPointChannel, near: drag.tone, by: delta / 100)
            }
        } else if edit.targetsCameraRawMixer {
            let weights = CameraRawMixerSettings.weights(forHue: drag.hue)
            for index in 0..<8 where weights[index] > 0 {
                switch edit.cameraRawMixerTab {
                case .hue:
                    settings.cameraRaw.mixer.hue[index] = min(100, max(-100, drag.settings.mixer.hue[index] + delta * weights[index]))
                case .saturation:
                    settings.cameraRaw.mixer.saturation[index] = min(100, max(-100, drag.settings.mixer.saturation[index] + delta * weights[index]))
                case .luminance:
                    settings.cameraRaw.mixer.luminance[index] = min(100, max(-100, drag.settings.mixer.luminance[index] + delta * weights[index]))
                }
            }
        }
        updateFilter(settings, preview: edit.preview)
    }

    func sampleCameraRawPointColor(at point: CGPoint) {
        guard let edit = filterEdit, edit.samplesPointColor, let sample = cameraRawSample(at: point) else { return }
        var settings = edit.settings
        var color = CameraRawPointColor(hue: sample.hue, saturation: sample.saturation, luminance: sample.luminance)
        if settings.cameraRaw.mixer.points.indices.contains(edit.cameraRawPointIndex) {
            color.hueShift = settings.cameraRaw.mixer.points[edit.cameraRawPointIndex].hueShift
            color.saturationShift = settings.cameraRaw.mixer.points[edit.cameraRawPointIndex].saturationShift
            color.luminanceShift = settings.cameraRaw.mixer.points[edit.cameraRawPointIndex].luminanceShift
            settings.cameraRaw.mixer.points[edit.cameraRawPointIndex] = color
        } else if settings.cameraRaw.mixer.points.count < 8 {
            settings.cameraRaw.mixer.points.append(color)
            edit.cameraRawPointIndex = settings.cameraRaw.mixer.points.count - 1
        }
        updateFilter(settings, preview: edit.preview)
    }

    func beginCameraRawGeometryGuide(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, edit.drawingCameraRawGeometryGuide,
              let normalized = cameraRawNormalizedPoint(at: point) else { return }
        edit.cameraRawGuideDraft = (start: normalized, end: normalized)
    }

    func continueCameraRawGeometryGuide(to point: CGPoint) {
        guard let edit = filterEdit, edit.drawingCameraRawGeometryGuide, let normalized = cameraRawNormalizedPoint(at: point) else { return }
        guard var draft = edit.cameraRawGuideDraft else { return }
        draft.end = normalized
        edit.cameraRawGuideDraft = draft
    }

    func commitCameraRawGeometryGuide() {
        guard let edit = filterEdit, let draft = edit.cameraRawGuideDraft else { return }
        var settings = edit.settings
        settings.cameraRaw.geometry.guides.append(CameraRawGeometryGuide(startX: draft.start.x, startY: draft.start.y,
                                                                         endX: draft.end.x, endY: draft.end.y))
        settings.cameraRaw.geometry.upright = .guided
        edit.cameraRawGuideDraft = nil
        updateFilter(settings, preview: edit.preview)
    }

    private func cameraRawNormalizedPoint(at point: CGPoint) -> CGPoint? {
        guard let edit = filterEdit else { return nil }
        let image = edit.previewSource
        let pixel = point.applying(edit.previewMapping.inverted())
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(image.width), pixel.y < CGFloat(image.height) else { return nil }
        return CGPoint(x: pixel.x / CGFloat(image.width), y: pixel.y / CGFloat(image.height))
    }

    private func cameraRawSample(at point: CGPoint) -> (tone: Double, hue: Double, saturation: Double, luminance: Double)? {
        guard let edit = filterEdit else { return nil }
        let image = edit.preparedPreview ?? edit.previewSource
        let pixel = point.applying(edit.previewMapping.inverted())
        let rect = CGRect(x: floor(pixel.x), y: floor(pixel.y), width: 1, height: 1)
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(image.width), pixel.y < CGFloat(image.height),
              let sample = image.cropping(to: rect),
              let context = try? BrushRaster.context(width: 1, height: 1, mask: false) else { return nil }
        BrushRaster.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: context)
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        guard bytes[3] > 0 else { return nil }
        let red = min(1, Double(bytes[0]) / Double(bytes[3]))
        let green = min(1, Double(bytes[1]) / Double(bytes[3]))
        let blue = min(1, Double(bytes[2]) / Double(bytes[3]))
        let maxChannel = max(red, green, blue), minChannel = min(red, green, blue)
        let chroma = maxChannel - minChannel
        var hue = 0.0
        if chroma > 1e-6 {
            if maxChannel == red { hue = (green - blue) / chroma }
            else if maxChannel == green { hue = 2 + (blue - red) / chroma }
            else { hue = 4 + (red - green) / chroma }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let tone = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let saturation = maxChannel == 0 ? 0 : chroma / maxChannel
        return (tone, hue * 360, saturation, (maxChannel + minChannel) / 2)
    }
}
