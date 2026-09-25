import AppKit
import Observation

nonisolated struct PaletteColor: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    static let black = PaletteColor(red: 0, green: 0, blue: 0)
    static let white = PaletteColor(red: 1, green: 1, blue: 1)
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red; self.green = green; self.blue = blue
    }
    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: min(1, max(0, rgb.redComponent)), green: min(1, max(0, rgb.greenComponent)), blue: min(1, max(0, rgb.blueComponent)))
    }
}

extension EditorSession {
    var foregroundColor: PaletteColor {
        get { PaletteColor(red: brushSettings.red, green: brushSettings.green, blue: brushSettings.blue) }
        set { brushSettings.red = newValue.red; brushSettings.green = newValue.green; brushSettings.blue = newValue.blue }
    }
    var canEditPalette: Bool { _ = showsBusy; return !isProjectBusy && brushStroke == nil }
    func paletteColor(background: Bool) -> PaletteColor {
        if isMaskSelected { return (background ? !maskPaintWhite : maskPaintWhite) ? .white : .black }
        return background ? backgroundColor : foregroundColor
    }
    func setPaletteColor(_ color: PaletteColor, background: Bool) {
        guard canEditPalette else { return }
        if isMaskSelected {
            let white = color == .white
            maskPaintWhite = background ? !white : white
        } else if background { backgroundColor = color }
        else {
            foregroundColor = color
            // Type paints in the foreground color, so text being edited follows the swatch. A text layer merely
            // selected keeps its color: it changes only while its text is open for editing.
            if tool == .type, textDraft != nil {
                changeTextStyle { $0.red = color.red; $0.green = color.green; $0.blue = color.blue }
            }
        }
    }
    func swapPaletteColors() {
        guard canEditPalette else { return }
        if isMaskSelected { maskPaintWhite.toggle() }
        else {
            let old = foregroundColor
            setPaletteColor(backgroundColor, background: false)
            backgroundColor = old
        }
    }
    func resetPaletteColors() {
        guard canEditPalette else { return }
        if isMaskSelected { maskPaintWhite = false }
        else { setPaletteColor(.black, background: false); backgroundColor = .white }
    }

    func openColorPicker(background: Bool) {
        guard canEditPalette, !isMaskSelected else { return }
        let picker = ColorPickerState(background: background, original: paletteColor(background: background))
        // Text being edited follows the foreground color, so it previews the picker's working color as the Type
        // bar's own swatch does, and goes back to its own color on Cancel.
        if !background, tool == .type, let draft = textDraft {
            picker.editedText = (draft.id, PaletteColor(red: draft.style.red, green: draft.style.green, blue: draft.style.blue))
        }
        colorPicker = picker
    }
    /// What the Type bar's swatch shows and edits: the text being edited, otherwise the foreground color the next
    /// text will use. A text layer that is only selected is not touched.
    var typeColor: PaletteColor {
        guard let style = textDraft?.style else { return foregroundColor }
        return PaletteColor(red: style.red, green: style.green, blue: style.blue)
    }
    func openTextColorPicker() {
        guard canEditPalette, colorPicker == nil, tool == .type else { return }
        colorPicker = ColorPickerState(target: .text(draftID: textDraft?.id), original: typeColor)
    }
    /// Opens the app's picker on a layer effect's color.
    func openEffectColorPicker(_ kind: LayerEffectKind) {
        guard canEditPalette, colorPicker == nil, effectsEditing != nil else { return }
        colorPicker = ColorPickerState(target: .effect(kind: kind), original: editingEffects.color(kind) ?? .black)
    }
    func closeColorPicker(commit: Bool) {
        if let colorPicker {
            switch colorPicker.target {
            case .palette(let background):
                if commit, !isMaskSelected { setPaletteColor(colorPicker.color, background: background) }
                else if !commit, let edited = colorPicker.editedText, tool == .type, textDraft?.id == edited.draftID {
                    let color = edited.color
                    changeTextStyle { $0.red = color.red; $0.green = color.green; $0.blue = color.blue }
                    refreshCanvasPreview?()
                }
            case .text(let draftID):
                if tool == .type, textDraft?.id == draftID {
                    let color = commit ? colorPicker.color : colorPicker.original
                    if draftID != nil {
                        changeTextStyle { $0.red = color.red; $0.green = color.green; $0.blue = color.blue }
                        refreshCanvasPreview?()
                    } else if commit {
                        textDefaults.red = color.red; textDefaults.green = color.green; textDefaults.blue = color.blue
                    }
                    // The text color is the foreground color: picking one in the Type bar moves the swatch too.
                    if commit, !isMaskSelected { foregroundColor = color }
                }
            case .effect(let kind):
                let color = commit ? colorPicker.color : colorPicker.original
                changeEffects { $0.setColor(color, for: kind) }
            case .gradientMap(let highlights):
                // The end has been previewing the working color; Cancel puts the original back.
                setGradientMapColor(commit ? colorPicker.color : colorPicker.original, highlights: highlights)
            case .vignette:
                setVignetteColor(commit ? colorPicker.color : colorPicker.original)
            }
        }
        colorPicker = nil
    }
    /// Opens the app's color picker on one end of the Gradient Map being edited (Shadows or Highlights).
    func openGradientMapColorPicker(highlights: Bool) {
        guard canEditPalette, colorPicker == nil, let edit = filterEdit, edit.kind == .gradientMap, !edit.committing else { return }
        let value = highlights ? edit.settings.gradientMap.highlights : edit.settings.gradientMap.shadows
        colorPicker = ColorPickerState(target: .gradientMap(highlights: highlights),
                                       original: PaletteColor(red: value.red, green: value.green, blue: value.blue))
    }
    func openVignetteColorPicker() {
        guard canEditPalette, colorPicker == nil, let edit = filterEdit, edit.kind == .vignette, !edit.committing else { return }
        let value = edit.settings.vignetteColor
        colorPicker = ColorPickerState(target: .vignette,
                                       original: PaletteColor(red: value.red, green: value.green, blue: value.blue))
    }
    /// While the picker is open on an effect's color, the canvas follows its working color.
    func previewEffectColor() {
        guard let colorPicker, case .effect(let kind) = colorPicker.target else { return }
        changeEffects { $0.setColor(colorPicker.color, for: kind) }
    }
    /// Preview the picker's working color in the active on-canvas text draft.
    func previewTextColor() {
        guard let colorPicker else { return }
        let draftID: UUID?
        switch colorPicker.target {
        case .text(let id): draftID = id
        case .palette(background: false): draftID = colorPicker.editedText?.draftID
        default: return
        }
        guard let draftID, tool == .type, textDraft?.id == draftID else { return }
        let color = colorPicker.color
        changeTextStyle { $0.red = color.red; $0.green = color.green; $0.blue = color.blue }
        refreshCanvasPreview?()
    }
    /// While the picker is open on a Gradient Map end, the gradient (and canvas) follow its working color.
    func previewGradientMapColor() {
        guard let colorPicker, case .gradientMap(let highlights) = colorPicker.target else { return }
        setGradientMapColor(colorPicker.color, highlights: highlights)
    }
    func previewVignetteColor() {
        guard let colorPicker, case .vignette = colorPicker.target else { return }
        setVignetteColor(colorPicker.color)
    }
    private func setVignetteColor(_ color: PaletteColor) {
        guard let edit = filterEdit, edit.kind == .vignette, !edit.committing else { return }
        var settings = edit.settings
        settings.vignetteColor = AdjustmentColor(color)
        guard settings != edit.settings else { return }
        updateFilter(settings, preview: edit.preview)
    }
    private func setGradientMapColor(_ color: PaletteColor, highlights: Bool) {
        guard let edit = filterEdit, edit.kind == .gradientMap, !edit.committing else { return }
        var settings = edit.settings
        if highlights { settings.gradientMap.highlights = AdjustmentColor(color) } else { settings.gradientMap.shadows = AdjustmentColor(color) }
        guard settings != edit.settings else { return }
        updateFilter(settings, preview: edit.preview)
    }
    /// Loads the canvas color under a document point into the open picker.
    func sampleIntoColorPicker(at point: CGPoint) {
        guard let colorPicker, let color = sampleCompositeColor(at: point) else { return }
        colorPicker.hsb.setRGB(color)
    }

    /// Composited sRGB color of the visible layers at one document pixel, as shown on
    /// the canvas. Nil outside the canvas or over fully transparent pixels.
    func sampleCompositeColor(at point: CGPoint) -> PaletteColor? {
        guard let document, point.x >= 0, point.y >= 0,
              point.x < document.size.width, point.y < document.size.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Map the target pixel onto the 1×1 context in the renderer's top-left space.
            context.translateBy(x: 0, y: 1)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -point.x.rounded(.down), y: -point.y.rounded(.down))
        drawLiveComposite(document, in: context)

            return true
        }
        guard drawn, pixel[3] > 0 else { return nil }
        let alpha = CGFloat(pixel[3])
        func channel(_ value: UInt8) -> CGFloat { (min(alpha, CGFloat(value)) / alpha * 255).rounded() / 255 }
        return PaletteColor(red: channel(pixel[0]), green: channel(pixel[1]), blue: channel(pixel[2]))
    }
}

/// What the open color picker edits: a palette swatch, or one end of the Gradient Map being edited.
enum ColorPickerTarget: Equatable {
    case palette(background: Bool)
    /// A layer effect's own color.
    case effect(kind: LayerEffectKind)
    case gradientMap(highlights: Bool)
    case vignette
    case text(draftID: UUID?)
    var title: String {
        switch self {
        case .text: return "Color Picker (Text Color)"
        case .effect(let kind): return "Color Picker (\(kind.rawValue) Color)"
        case .palette(let background): return background ? "Color Picker (Background Color)" : "Color Picker (Foreground Color)"
        case .gradientMap(let highlights): return highlights ? "Color Picker (Gradient Map Highlights)" : "Color Picker (Gradient Map Shadows)"
        case .vignette: return "Color Picker (Vignette Color)"
        }
    }
}

/// The open color picker's working color. Nothing is written to the palette until OK.
@Observable
final class ColorPickerState {
    let target: ColorPickerTarget
    var background: Bool { target == .palette(background: true) }
    let original: PaletteColor
    /// The foreground picker opened while text was being edited: that text and the color it had.
    var editedText: (draftID: UUID, color: PaletteColor)?
    var hsb: PickerHSB
    var color: PaletteColor { hsb.rgb.quantized }
    init(target: ColorPickerTarget, original: PaletteColor) {
        self.target = target
        self.original = original
        hsb = PickerHSB(original)
    }
    convenience init(background: Bool, original: PaletteColor) {
        self.init(target: .palette(background: background), original: original)
    }
}

/// Hue in degrees, saturation and brightness 0...1. Kept as the picker's source of
/// truth so hue survives dragging through grays and black.
struct PickerHSB: Equatable {
    var hue: CGFloat
    var saturation: CGFloat
    var brightness: CGFloat

    init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        self.hue = hue; self.saturation = saturation; self.brightness = brightness
    }
    init(_ color: PaletteColor) {
        self.init(hue: 0, saturation: 0, brightness: 0)
        setRGB(color)
    }

    var rgb: PaletteColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return PaletteColor(red: r + m, green: g + m, blue: b + m)
    }

    /// Updates from RGB while keeping the previous hue for grays and the previous
    /// saturation for black, matching how Photoshop's field behaves.
    mutating func setRGB(_ color: PaletteColor) {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let delta = high - low
        brightness = high
        if high > 0 { saturation = delta / high }
        guard delta > 0 else { return }
        var h: CGFloat
        if high == color.red { h = (color.green - color.blue) / delta }
        else if high == color.green { h = (color.blue - color.red) / delta + 2 }
        else { h = (color.red - color.green) / delta + 4 }
        h *= 60
        hue = h < 0 ? h + 360 : h
    }
}

extension PaletteColor {
    /// Snaps to the 8-bit values that painting and export actually store.
    var quantized: PaletteColor {
        PaletteColor(red: (red * 255).rounded() / 255, green: (green * 255).rounded() / 255, blue: (blue * 255).rounded() / 255)
    }
    var hex: String {
        String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    /// Accepts `RRGGBB` or shorthand `RGB`, with or without a leading `#`.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255)
    }
}
