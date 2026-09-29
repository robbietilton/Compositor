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
            if tool == .type, textDraft != nil { setDraftTextColor(color) }
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
            picker.editedText = (draft.id, draft.style)
        }
        colorPicker = picker
    }
    /// What the Type bar's swatch shows and edits: the text being edited, otherwise the foreground color the next
    /// text will use. A text layer that is only selected is not touched.
    /// With letters selected, it is the color of the first of them; with just a caret, the letter before it, the
    /// color typing there gives.
    var typeColor: PaletteColor {
        guard let draft = textDraft else { return foregroundColor }
        let selection = draft.selection
        return draft.style.color(at: selection.length > 0 ? selection.location : max(0, selection.location - 1))
    }
    func openTextColorPicker() {
        guard canEditPalette, colorPicker == nil, tool == .type else { return }
        let picker = ColorPickerState(target: .text(draftID: textDraft?.id), original: typeColor)
        if let draft = textDraft { picker.editedText = (draft.id, draft.style) }
        colorPicker = picker
    }
    /// Paints the selected letters of the text being edited, or all of it when nothing is selected.
    func setDraftTextColor(_ color: PaletteColor) {
        guard let selection = textDraft?.selection else { return }
        changeTextStyle { $0.setColor(color, in: selection) }
    }
    /// Puts back the colors the text being edited had when the picker opened.
    private func restoreDraftTextColors(_ original: LayerTextStyle) {
        changeTextStyle {
            $0.red = original.red; $0.green = original.green; $0.blue = original.blue
            $0.colorRuns = original.content == $0.content ? original.colorRuns : nil
        }
        refreshCanvasPreview?()
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
                    restoreDraftTextColors(edited.style)
                }
            case .text(let draftID):
                if tool == .type, textDraft?.id == draftID {
                    let color = commit ? colorPicker.color : colorPicker.original
                    if draftID != nil {
                        if commit { setDraftTextColor(color); refreshCanvasPreview?() }
                        else if let edited = colorPicker.editedText { restoreDraftTextColors(edited.style) }
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
            case .dither(let light):
                setDitherColor(commit ? colorPicker.color : colorPicker.original, light: light)
            case .dialog:
                dialogColorChange?(commit ? colorPicker.color : colorPicker.original)
                dialogColorChange = nil
            }
        }
        colorPicker = nil
        // Sampling clicked the canvas, which took the keys from the text: give them back.
        if textDraft != nil { canvasFocusRequest += 1 }
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
        setDraftTextColor(colorPicker.color)
        refreshCanvasPreview?()
    }
    /// While the picker is open on a Gradient Map end, the gradient (and canvas) follow its working color.
    func previewGradientMapColor() {
        guard let colorPicker, case .gradientMap(let highlights) = colorPicker.target else { return }
        setGradientMapColor(colorPicker.color, highlights: highlights)
    }
    /// Opens the app's picker on a dialog's color. `change` hears the working color as it moves, the chosen one on OK,
    /// and the original again on Cancel.
    func openDialogColorPicker(title: String, color: PaletteColor, change: @escaping (PaletteColor) -> Void) {
        guard colorPicker == nil else { return }
        dialogColorChange = change
        colorPicker = ColorPickerState(target: .dialog(title: title), original: color)
    }
    /// The picker is open for a dialog, which covers the canvas: there's nothing to sample.
    var pickingForDialog: Bool { if case .dialog = colorPicker?.target { true } else { false } }
    /// While the picker is open on a dialog's color, the dialog follows its working color.
    func previewDialogColor() {
        guard let colorPicker, case .dialog = colorPicker.target else { return }
        dialogColorChange?(colorPicker.color)
    }
    func openDitherColorPicker(light: Bool) {
        guard canEditPalette, colorPicker == nil, let edit = filterEdit, edit.kind == .dither, !edit.committing else { return }
        let value = light ? edit.settings.dither.light : edit.settings.dither.dark
        colorPicker = ColorPickerState(target: .dither(light: light),
                                       original: PaletteColor(red: value.red, green: value.green, blue: value.blue))
    }
    func previewDitherColor() {
        guard let colorPicker, case .dither(let light) = colorPicker.target else { return }
        setDitherColor(colorPicker.color, light: light)
    }
    private func setDitherColor(_ color: PaletteColor, light: Bool) {
        guard let edit = filterEdit, edit.kind == .dither, !edit.committing else { return }
        var settings = edit.settings
        if light { settings.dither.light = AdjustmentColor(color) } else { settings.dither.dark = AdjustmentColor(color) }
        guard settings != edit.settings else { return }
        updateFilter(settings, preview: edit.preview)
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
    /// Dither's Two Colors: the dark one or the light one.
    case dither(light: Bool)
    case text(draftID: UUID?)
    /// A dialog's own color, such as Export JPEG's background for transparency. The dialog is told as it changes.
    case dialog(title: String)
    var title: String {
        switch self {
        case .text: return "Color Picker (Text Color)"
        case .effect(let kind): return "Color Picker (\(kind.rawValue) Color)"
        case .palette(let background): return background ? "Color Picker (Background Color)" : "Color Picker (Foreground Color)"
        case .gradientMap(let highlights): return highlights ? "Color Picker (Gradient Map Highlights)" : "Color Picker (Gradient Map Shadows)"
        case .vignette: return "Color Picker (Vignette Color)"
        case .dither(let light): return light ? "Color Picker (Dither Light Color)" : "Color Picker (Dither Dark Color)"
        case .dialog(let title): return "Color Picker (\(title))"
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
    var editedText: (draftID: UUID, style: LayerTextStyle)?
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
