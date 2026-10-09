import Foundation

/// Display names for values whose raw value stays the English token stored in a project.
/// Each case is a string literal so the catalog extracts it.

extension SpotHealingMode {
    var localizedName: LocalizedStringResource {
        switch self {
        case .contentAware: "Content-Aware"
        case .createTexture: "Create Texture"
        case .proximityMatch: "Proximity Match"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawWhiteBalance {
    var localizedName: LocalizedStringResource {
        switch self {
        case .custom: "Custom"
        case .auto: "Auto"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawGlowStyle {
    var localizedName: LocalizedStringResource {
        switch self {
        case .diffusion: "Diffusion"
        case .bloom: "Bloom"
        case .halation: "Halation"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawVignetteStyle {
    var localizedName: LocalizedStringResource {
        switch self {
        case .highlightPriority: "Highlight Priority"
        case .colorPriority: "Color Priority"
        case .paintOverlay: "Paint Overlay"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawScopeMode {
    var localizedName: LocalizedStringResource {
        switch self {
        case .histogram: "Histogram"
        case .vectorscope: "Vectorscope"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawCurvePage {
    var localizedName: LocalizedStringResource {
        switch self {
        case .parametric: "Parametric"
        case .point: "Point"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawPointChannel {
    var localizedName: LocalizedStringResource {
        switch self {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawMixerPage {
    var localizedName: LocalizedStringResource {
        switch self {
        case .hsl: "HSL"
        case .color: "Color"
        case .point: "Point Color"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawMixerTab {
    var localizedName: LocalizedStringResource {
        switch self {
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .luminance: "Luminance"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawGradePage {
    var localizedName: LocalizedStringResource {
        switch self {
        case .threeWay: "Three-Way"
        case .shadows: "Shadows"
        case .midtones: "Midtones"
        case .highlights: "Highlights"
        case .global: "Global"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawUprightMode {
    var localizedName: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .guided: "Guided"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawProjection {
    var localizedName: LocalizedStringResource {
        switch self {
        case .perspective: "Perspective"
        case .rectilinear: "Rectilinear"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CameraRawProcessVersion {
    var localizedName: LocalizedStringResource {
        switch self {
        case .version1: "Version 1"
        case .version2: "Version 2"
        case .version3: "Version 3"
        case .version4: "Version 4"
        case .version5: "Version 5"
        case .version6: "Version 6"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension CanvasUnit {
    var localizedName: LocalizedStringResource {
        switch self {
        case .pixels: "Pixels"
        case .percent: "Percent"
        case .inches: "Inches"
        case .centimeters: "Centimeters"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension DitherStyle {
    var localizedName: LocalizedStringResource {
        switch self {
        case .atkinson: "Atkinson (Classic Mac)"
        case .floydSteinberg: "Floyd–Steinberg"
        case .bayer2: "Bayer 2 × 2"
        case .bayer4: "Bayer 4 × 4"
        case .bayer8: "Bayer 8 × 8"
        case .dots: "Halftone Dots"
        case .lines: "Halftone Lines"
        case .diamonds: "Halftone Diamonds"
        case .patterns: "Mac Patterns"
        case .ascii: "ASCII"
        case .scanlines: "Scanlines (CRT)"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension DitherPixelShape {
    var localizedName: LocalizedStringResource {
        switch self {
        case .square: "Square"
        case .dot: "Dot"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension DitherColors {
    var localizedName: LocalizedStringResource {
        switch self {
        case .blackWhite: "Black & White"
        case .twoColors: "Two Colors"
        case .original: "Original"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension FilterKind {
    var localizedName: LocalizedStringResource {
        switch self {
        case .gaussianBlur: "Gaussian Blur"
        case .motionBlur: "Motion Blur"
        case .addNoise: "Add Noise"
        case .vignette: "Vignette"
        case .bloomGlow: "Bloom / Glow"
        case .dither: "Dither"
        case .tonalContrast: "Tonal Contrast"
        case .lensCorrection: "Lens Correction"
        case .cameraRaw: "Camera Raw Filter"
        case .removeBackground: "Remove Background"
        case .contentAwareFill: "Content-Aware Fill"
        case .curves: "Curves"
        case .exposure: "Exposure"
        case .gradientMap: "Gradient Map"
        case .grain: "Grain"
        case .blackWhite: "Black & White"
        case .colorBalance: "Color Balance"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension BackgroundQuality {
    var localizedName: LocalizedStringResource {
        switch self {
        case .basic: "Basic"
        case .advanced: "Advanced"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension GradientStyle {
    var localizedName: LocalizedStringResource {
        switch self {
        case .foregroundToBackground: "Foreground to Background"
        case .foregroundToTransparent: "Foreground to Transparent"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension GradientShape {
    var localizedName: LocalizedStringResource {
        switch self {
        case .linear: "Linear"
        case .radial: "Radial"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension GridAppearance.Preset {
    var localizedName: LocalizedStringResource {
        switch self {
        case .lightGray: "Light Gray"
        case .lightBlue: "Light Blue"
        case .lightRed: "Light Red"
        case .green: "Green"
        case .mediumBlue: "Medium Blue"
        case .yellow: "Yellow"
        case .magenta: "Magenta"
        case .cyan: "Cyan"
        case .black: "Black"
        case .custom: "Custom"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension GridAppearance.Style {
    var localizedName: LocalizedStringResource {
        switch self {
        case .lines: "Lines"
        case .dashedLines: "Dashed Lines"
        case .dots: "Dots"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension ColorRange {
    var localizedName: LocalizedStringResource {
        switch self {
        case .master: "Master"
        case .reds: "Reds"
        case .yellows: "Yellows"
        case .greens: "Greens"
        case .cyans: "Cyans"
        case .blues: "Blues"
        case .magentas: "Magentas"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension HueSampleMode {
    var localizedName: LocalizedStringResource {
        switch self {
        case .replace: "Sample"
        case .add: "Add"
        case .remove: "Remove"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension TrimBasedOn {
    var localizedName: LocalizedStringResource {
        switch self {
        case .transparentPixels: "Transparent Pixels"
        case .topLeftPixelColor: "Top Left Pixel Color"
        case .bottomRightPixelColor: "Bottom Right Pixel Color"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension AdjustmentKind {
    var localizedName: LocalizedStringResource {
        switch self {
        case .hsv: "Hue/Saturation"
        case .levels: "Levels"
        case .curves: "Curves"
        case .exposure: "Exposure"
        case .gradientMap: "Gradient Map"
        case .grain: "Grain"
        case .addNoise: "Add Noise"
        case .gaussianBlur: "Gaussian Blur"
        case .motionBlur: "Motion Blur"
        case .invert: "Invert"
        case .blackWhite: "Black & White"
        case .colorBalance: "Color Balance"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension LayerBlendMode {
    var localizedName: LocalizedStringResource {
        switch self {
        case .normal: "Normal"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .linearBurn: "Linear Burn"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .linearDodge: "Linear Dodge (Add)"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .vividLight: "Vivid Light"
        case .linearLight: "Linear Light"
        case .pinLight: "Pin Light"
        case .hardMix: "Hard Mix"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .subtract: "Subtract"
        case .divide: "Divide"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension LayerEffectKind {
    var localizedName: LocalizedStringResource {
        switch self {
        case .stroke: "Stroke"
        case .shadow: "Drop Shadow"
        case .colorOverlay: "Color Overlay"
        case .innerShadow: "Inner Shadow"
        case .outerGlow: "Outer Glow"
        case .innerGlow: "Inner Glow"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension LayerSampling {
    var localizedName: LocalizedStringResource {
        switch self {
        case .nearest: "Nearest"
        case .smooth: "Smooth"
        case .high: "High quality"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension LevelsChannel {
    var localizedName: LocalizedStringResource {
        switch self {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension LevelsSample {
    var localizedName: LocalizedStringResource {
        switch self {
        case .black: "Black"
        case .gray: "Gray"
        case .white: "White"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension LevelsAuto {
    var localizedName: LocalizedStringResource {
        switch self {
        case .contrast: "Contrast"
        case .color: "Color"
        case .neutral: "Color + neutral midtones"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension WandMode {
    var localizedName: LocalizedStringResource {
        switch self {
        case .wand: "Wand"
        case .object: "Object"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension LassoKind {
    var localizedName: LocalizedStringResource {
        switch self {
        case .freehand: "Freehand"
        case .polygonal: "Polygonal"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension SelectionMode {
    var localizedName: LocalizedStringResource {
        switch self {
        case .replace: "New"
        case .add: "Add"
        case .subtract: "Subtract"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension EditorSession.SelectionAmountOperation {
    var localizedName: LocalizedStringResource {
        switch self {
        case .expand: "Expand"
        case .contract: "Contract"
        case .feather: "Feather"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension ShapeKind {
    var localizedName: LocalizedStringResource {
        switch self {
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension BrushToolMode {
    var localizedName: LocalizedStringResource {
        switch self {
        case .paint: "Paint"
        case .erase: "Erase"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension BlurToolMode {
    var localizedName: LocalizedStringResource {
        switch self {
        case .liquify: "Liquify"
        case .blur: "Blur"
        case .smudge: "Smudge"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}

extension TextAlignment {
    var localizedName: LocalizedStringResource {
        switch self {
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        }
    }
    var localizedTitle: String { String(localized: localizedName) }
}
