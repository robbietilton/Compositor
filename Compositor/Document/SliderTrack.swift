import CoreGraphics

/// The colored tracks used by Camera Raw's color sliders, Hue/Saturation's and Color Balance's. Plain sliders keep the
/// system track.
enum CameraRawSliderTrack: Equatable {
    case plain
    case temperature
    case tint
    case chroma
    /// Neighboring hues around a color-family center, in degrees.
    case hue(Double)
    /// Gray to that family's own color.
    case saturation(Double)
    /// Dark to light in that family's hue.
    case luminance(Double)
    /// One color to its opposite, as Color Balance's Cyan / Red.
    case opposing(PaletteColor, PaletteColor)
    /// The whole hue circle, with that hue in the middle.
    case spectrum(Double)

    static let cyanRed = CameraRawSliderTrack.opposing(PaletteColor(red: 0.10, green: 0.72, blue: 0.80),
                                                       PaletteColor(red: 0.86, green: 0.18, blue: 0.20))
    static let magentaGreen = CameraRawSliderTrack.opposing(PaletteColor(red: 0.80, green: 0.22, blue: 0.70),
                                                            PaletteColor(red: 0.24, green: 0.70, blue: 0.30))
    static let yellowBlue = CameraRawSliderTrack.opposing(PaletteColor(red: 0.95, green: 0.82, blue: 0.18),
                                                          PaletteColor(red: 0.22, green: 0.40, blue: 0.92))

    /// Left-to-right track colors, in sRGB. Nil keeps the system track.
    var colors: [PaletteColor]? {
        switch self {
        case .plain:
            return nil
        case .temperature:
            return [PaletteColor(red: 0.22, green: 0.46, blue: 0.95), PaletteColor(red: 0.98, green: 0.82, blue: 0.18)]
        case .tint:
            return [PaletteColor(red: 0.28, green: 0.70, blue: 0.34), PaletteColor(red: 0.70, green: 0.40, blue: 0.64)]
        case .chroma:
            return [PaletteColor(red: 0.62, green: 0.62, blue: 0.64), PaletteColor(red: 0.86, green: 0.18, blue: 0.20)]
        case .hue(let degrees):
            return [Self.color(degrees: degrees - 50, saturation: 0.85, brightness: 0.9),
                    Self.color(degrees: degrees + 50, saturation: 0.85, brightness: 0.9)]
        case .saturation(let degrees):
            return [PaletteColor(red: 0.55, green: 0.55, blue: 0.56), Self.color(degrees: degrees, saturation: 0.9, brightness: 0.9)]
        case .luminance(let degrees):
            return [Self.color(degrees: degrees, saturation: 0.55, brightness: 0.18),
                    Self.color(degrees: degrees, saturation: 0.35, brightness: 0.95)]
        case .opposing(let from, let to):
            return [from, to]
        case .spectrum(let degrees):
            return stride(from: -180.0, through: 180, by: 30).map { Self.color(degrees: degrees + $0, saturation: 0.85, brightness: 0.9) }
        }
    }

    private static func color(degrees: Double, saturation: CGFloat, brightness: CGFloat) -> PaletteColor {
        PickerHSB(hue: degrees, saturation: saturation, brightness: brightness).rgb
    }
}

extension HueSaturationSettings {
    /// What a double-click puts a slider back to: Photoshop's colorize start, or no change.
    var resetValues: HueSaturationSettings { colorize ? .colorizeStart : HueSaturationSettings() }
    /// The middle of the selected color range; Master centers on red.
    var rangeHue: Double { Double(max(0, ColorRange.colorRanges.firstIndex(of: range) ?? 0)) * 60 }
    /// Colorizing picks an absolute hue, red to red; otherwise the track shows the shift around the range's color.
    var hueTrack: CameraRawSliderTrack { .spectrum(colorize ? 180 : rangeHue) }
    var saturationTrack: CameraRawSliderTrack {
        if colorize { return .saturation(hue) }
        return range == .master ? .chroma : .saturation(rangeHue)
    }
    static let lightnessTrack = CameraRawSliderTrack.opposing(.black, .white)
}
