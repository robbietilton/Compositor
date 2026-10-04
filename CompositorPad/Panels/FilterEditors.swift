import UIKit

/// The editor for a filter, or an adjustment layer of the same kind, as the Mac's filter panel: a row for each of the
/// filter's settings, then Preview, and Cancel and OK. Like the Mac's, it has no Reset.
final class FilterEditorController: AdjustmentEditorController {
    /// A row of the Mac's filter panel: a slider and an exact field for one setting.
    struct Row {
        let caption: String
        let key: WritableKeyPath<FilterSettings, Double>
        let range: ClosedRange<Double>
        let unit: String?
        /// How many decimals the row sets and shows.
        let decimals: Int
        /// Whether the slider gives the small values most of its travel.
        let logarithmic: Bool
        /// What the row does, as the Mac's help says it.
        var help: String? = nil
        /// What the row does, as VoiceOver's hint says it (`setHelp`); none where the caption says it.
        var hint: String? = nil
        /// When the row shows, as Remove Background's Advanced rows; always if nil.
        var shown: ((FilterSettings) -> Bool)? = nil
        /// The row's colored track, as the Mac's Camera Raw sliders: a double tap on its caption or thumb then puts the
        /// value back, a plain track's too. Nil for the system's slider, which doesn't reset.
        var track: ((FilterSettings) -> CameraRawSliderTrack)? = nil
    }

    /// A color, as a swatch that opens the color picker on it, titled.
    struct Swatch {
        let title: String
        let value: (FilterSettings) -> AdjustmentColor
        let open: (EditorSession) -> Void
    }

    /// What the Mac's filter panel puts in a filter's editor, in order. A control with `shown` shows only when it says
    /// so, as Dither's rows for its style. A control's `help` is the Mac's, and its `hint` VoiceOver's (`setHelp`).
    enum Control {
        case slider(Row)
        /// A choice among `titles`, as segments, captioned or not; `chosen` reads which, and `choose` sets it. `hints` has
        /// each segment's, which VoiceOver reads on its own.
        case choice(caption: String?, titles: [String], help: String?, hints: [String]?, chosen: (FilterSettings) -> Int,
                    choose: (inout FilterSettings, Int) -> Void)
        /// A choice among `groups` of names, as a pop-up, captioned.
        case popUp(caption: String, groups: [[String]], help: String? = nil, hint: String? = nil, chosen: (FilterSettings) -> String,
                   choose: (inout FilterSettings, String) -> Void, shown: ((FilterSettings) -> Bool)? = nil)
        case checkbox(String, WritableKeyPath<FilterSettings, Bool>, help: String? = nil, hint: String? = nil,
                      shown: ((FilterSettings) -> Bool)? = nil)
        /// Text typed into a field, captioned, as Dither's Characters.
        case field(caption: String, key: WritableKeyPath<FilterSettings, String>, help: String?, hint: String?,
                   shown: ((FilterSettings) -> Bool)? = nil)
        /// A section's title, as Color Balance's Shadows, Midtones and Highlights.
        case heading(String)
        /// The gradient the settings make, left to right, as Gradient Map's bar.
        case gradient((FilterSettings) -> [AdjustmentColor])
        /// Swatches side by side, each with its title after it, as Gradient Map's ends, or before it, as Dither's Dark
        /// and Light; a tap opens the color picker on one.
        case swatches([Swatch], titlesFirst: Bool = false, shown: ((FilterSettings) -> Bool)? = nil)
        /// A color, as a swatch that opens the color picker on it.
        case color(caption: String, help: String?, hint: String?, value: (FilterSettings) -> AdjustmentColor, open: (EditorSession) -> Void)
        /// What the filter does, in the panel's words.
        case text(String)
        /// A note on a setting, quieter.
        case note(String)
    }

    /// Each kind's controls, as the Mac's filter panel (FilterSheet) lays them out, with its ranges, units and decimals.
    static let controls: [FilterKind: [Control]] = [
        .gaussianBlur: [.slider(Row(caption: "Radius", key: \.radius, range: 0.1...250, unit: "px", decimals: 1, logarithmic: true))],
        .motionBlur: [
            .slider(Row(caption: "Angle", key: \.angle, range: -90...90, unit: "°", decimals: 0, logarithmic: false)),
            .slider(Row(caption: "Distance", key: \.distance, range: 1...2000, unit: "px", decimals: 0, logarithmic: true)),
        ],
        .addNoise: [
            .slider(Row(caption: "Amount", key: \.amount, range: 0.1...400, unit: "%", decimals: 1, logarithmic: true)),
            .choice(caption: "Distribution", titles: ["Uniform", "Gaussian"], help: nil, hints: nil, chosen: { $0.gaussian ? 1 : 0 },
                    choose: { $0.gaussian = $1 == 1 }),
            .checkbox("Monochromatic", \.monochromatic),
        ],
        .exposure: [
            .slider(Row(caption: "Exposure", key: \.exposure.exposure, range: ExposureSettings.exposureRange, unit: nil, decimals: 2,
                        logarithmic: false)),
            .slider(Row(caption: "Offset", key: \.exposure.offset, range: ExposureSettings.offsetRange, unit: nil, decimals: 4, logarithmic: false)),
            .slider(Row(caption: "Gamma", key: \.exposure.gamma, range: ExposureSettings.gammaRange, unit: nil, decimals: 2, logarithmic: true)),
        ],
        .grain: [
            .slider(Row(caption: "Amount", key: \.grain.amount, range: GrainSettings.amountRange, unit: nil, decimals: 0, logarithmic: false)),
            .slider(Row(caption: "Size", key: \.grain.size, range: GrainSettings.sizeRange, unit: "px", decimals: 1, logarithmic: true)),
            .slider(Row(caption: "Roughness", key: \.grain.roughness, range: GrainSettings.roughnessRange, unit: nil, decimals: 0,
                        logarithmic: false)),
        ],
        .bloomGlow: [
            .slider(Row(caption: "Amount", key: \.bloomAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)),
            .slider(Row(caption: "Radius", key: \.bloomRadius, range: 1...150, unit: "px", decimals: 0, logarithmic: true)),
        ],
        .tonalContrast: [
            .slider(Row(caption: "Amount", key: \.tonalAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)),
            .slider(Row(caption: "Shadows", key: \.tonalShadows, range: -100...100, unit: "%", decimals: 0, logarithmic: false)),
            .slider(Row(caption: "Midtones", key: \.tonalMidtones, range: -100...100, unit: "%", decimals: 0, logarithmic: false)),
            .slider(Row(caption: "Highlights", key: \.tonalHighlights, range: -100...100, unit: "%", decimals: 0, logarithmic: false)),
            .slider(Row(caption: "Radius", key: \.tonalRadius, range: 1...100, unit: "px", decimals: 0, logarithmic: true)),
        ],
        .contentAwareFill: [.text("Fill the selection using surrounding pixels from this layer.")],
        .removeBackground: [
            .text("Hide the background behind a layer mask, keeping the foreground subjects. The pixels stay, so the background can be painted back at any time."),
            .choice(caption: nil, titles: BackgroundQuality.allCases.map(\.rawValue),
                    help: "Basic is quick; Advanced refines the mask against the layer's own detail, for hair and fur",
                    hints: BackgroundQuality.allCases.map(\.hint),
                    chosen: { BackgroundQuality.allCases.firstIndex(of: $0.backgroundQuality) ?? 0 },
                    choose: { $0.backgroundQuality = BackgroundQuality.allCases[$1] }),
            .slider(Row(caption: "Refine", key: \.refineEdges, range: 0...40, unit: "px", decimals: 0, logarithmic: false,
                        help: "Pull the mask onto the image's own edges, which recovers hair and fur",
                        hint: "Pulls the mask onto the image's own edges, recovering hair and fur.", shown: { $0.backgroundQuality == .advanced })),
            .slider(Row(caption: "Contrast", key: \.matteContrast, range: 0...100, unit: "%", decimals: 0, logarithmic: false,
                        help: "Clear the haze that leaves background showing through thin areas",
                        hint: "Clears the haze that leaves background showing through thin areas.", shown: { $0.backgroundQuality == .advanced })),
            .slider(Row(caption: "Shift Edge", key: \.shiftEdge, range: -10...10, unit: "px", decimals: 0, logarithmic: false,
                        help: "Shrink the mask to drop the rim of background color around the subject, or grow it",
                        hint: "Shrinks the mask to drop the rim of background color around the subject, or grows it.",
                        shown: { $0.backgroundQuality == .advanced })),
        ],
        .vignette: [
            .color(caption: "Color", help: "Choose the vignette color", hint: "Opens the color picker for the vignette.", value: \.vignetteColor,
                   open: { $0.openVignetteColorPicker() }),
            .slider(Row(caption: "Amount", key: \.vignetteAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false,
                        help: "Blend the chosen color into the edges while keeping the center unchanged",
                        hint: "Blends the chosen color into the edges, keeping the center unchanged.")),
            .slider(Row(caption: "Midpoint", key: \.vignetteMidpoint, range: 0...100, unit: "%", decimals: 0, logarithmic: false)),
            .slider(Row(caption: "Roundness", key: \.vignetteRoundness, range: -100...100, unit: nil, decimals: 0, logarithmic: false)),
            .slider(Row(caption: "Feather", key: \.vignetteFeather, range: 0...100, unit: "%", decimals: 0, logarithmic: false)),
            .slider(Row(caption: "Highlights", key: \.vignetteHighlights, range: 0...100, unit: "%", decimals: 0, logarithmic: false,
                        help: "Protect bright areas near the edge", hint: "Protects bright areas near the edge.")),
        ],
        .gradientMap: [
            .gradient { settings in [settings.gradientMap.ends.dark, settings.gradientMap.ends.light] },
            .swatches([Swatch(title: "Shadows", value: \.gradientMap.shadows, open: { $0.openGradientMapColorPicker(highlights: false) }),
                       Swatch(title: "Highlights", value: \.gradientMap.highlights, open: { $0.openGradientMapColorPicker(highlights: true) })]),
            .checkbox("Reverse", \.gradientMap.reversed),
        ],
        // The rows each style uses, as the Mac's panel shows them.
        .dither: [
            .popUp(caption: "Style", groups: DitherStyle.groups.map { $0.map(\.rawValue) }, chosen: { $0.dither.style.rawValue },
                   choose: { settings, name in if let style = DitherStyle(rawValue: name) { settings.dither.style = style } }),
            .slider(Row(caption: "Pixel Size", key: \.dither.pixelSize, range: DitherSettings.pixelSizeRange, unit: "px", decimals: 0,
                        logarithmic: false, help: "Make each dithered pixel this many pixels across, for a chunky old-screen look",
                        hint: "Makes each dithered pixel this many pixels across, for a chunky old-screen look.",
                        shown: { $0.dither.style.usesPixelSize })),
            // Text Size's and Line Spacing's help say only what their captions do, so they have no hint.
            .slider(Row(caption: "Text Size", key: \.dither.textSize, range: DitherSettings.textSizeRange, unit: "px", decimals: 0,
                        logarithmic: false, help: "The height of each line of characters", shown: { $0.dither.style == .ascii })),
            .slider(Row(caption: "Line Spacing", key: \.dither.lineSpacing, range: DitherSettings.lineSpacingRange, unit: "px", decimals: 0,
                        logarithmic: false, help: "How far apart the screen's lines are", shown: { $0.dither.style == .scanlines })),
            .slider(Row(caption: "Glow", key: \.dither.glow, range: 0...100, unit: "%", decimals: 0, logarithmic: false,
                        help: "Light blooming around the lines, like a CRT's phosphors",
                        hint: "Blooms light around the lines, like a CRT's phosphors.", shown: { $0.dither.style == .scanlines })),
            .slider(Row(caption: "Dots", key: \.dither.dots, range: 0...100, unit: "%", decimals: 0, logarithmic: false,
                        help: "Break the lines into glowing beads", hint: "Breaks the lines into glowing beads.",
                        shown: { $0.dither.style == .scanlines })),
            .slider(Row(caption: "Wobble", key: \.dither.wobble, range: DitherSettings.wobbleRange, unit: "px", decimals: 0, logarithmic: false,
                        help: "Make the lines waver sideways down the screen, like a CRT losing sync",
                        hint: "Makes the lines waver sideways down the screen, like a CRT losing sync.", shown: { $0.dither.style == .scanlines })),
            .slider(Row(caption: "Cell Size", key: \.dither.cellSize, range: DitherSettings.cellSizeRange, unit: "px", decimals: 0,
                        logarithmic: false, shown: { $0.dither.style.isHalftone })),
            .slider(Row(caption: "Angle", key: \.dither.angle, range: -90...90, unit: "°", decimals: 0, logarithmic: false,
                        shown: { $0.dither.style.isHalftone })),
            .field(caption: "Characters", key: \.dither.characters,
                   help: "The characters to draw with, in any order: each spot gets the one whose ink best matches its tone",
                   hint: "Draws each spot with the one of these characters whose ink best matches its tone.",
                   shown: { $0.dither.style == .ascii }),
            .slider(Row(caption: "Tones", key: \.dither.levels, range: DitherSettings.levelsRange, unit: nil, decimals: 0, logarithmic: false,
                        help: "Tones per channel: 2 is pure black and white", hint: "Sets how many levels each channel has; 2 is pure black and white.",
                        shown: { $0.dither.style.hasTones })),
            .slider(Row(caption: "Diffusion", key: \.dither.diffusion, range: 0...100, unit: "%", decimals: 0, logarithmic: false,
                        help: "How much of each pixel's error spreads to its neighbors. Less gives flatter areas",
                        hint: "Spreads each pixel's error to its neighbors; less gives flatter areas.",
                        shown: { $0.dither.style.diffuses })),
            .slider(Row(caption: "Density", key: \.dither.density, range: -100...100, unit: nil, decimals: 0, logarithmic: false,
                        help: "More ink (darker) or less before dithering", hint: "Darkens with more ink, or lightens with less, before dithering.")),
            .slider(Row(caption: "Contrast", key: \.dither.contrast, range: -100...100, unit: nil, decimals: 0, logarithmic: false)),
            .popUp(caption: "Colors", groups: [DitherColors.allCases.map(\.rawValue)], chosen: { $0.dither.colors.rawValue },
                   choose: { settings, name in if let colors = DitherColors(rawValue: name) { settings.dither.colors = colors } }),
            .swatches([Swatch(title: "Dark", value: \.dither.dark, open: { $0.openDitherColorPicker(light: false) }),
                       Swatch(title: "Light", value: \.dither.light, open: { $0.openDitherColorPicker(light: true) })],
                      titlesFirst: true, shown: { $0.dither.colors == .twoColors }),
            .popUp(caption: "Pixel Shape", groups: [DitherPixelShape.allCases.map(\.rawValue)],
                   help: "Draw each chunky pixel as a solid square, or as a round dot like a dot-matrix screen",
                   hint: "Draws each chunky pixel as a solid square, or as a round dot like a dot-matrix screen.",
                   chosen: { $0.dither.pixelShape.rawValue },
                   choose: { settings, name in if let shape = DitherPixelShape(rawValue: name) { settings.dither.pixelShape = shape } },
                   shown: { $0.dither.pixelSize > 1 && $0.dither.style.usesPixelSize }),
            .checkbox("Light on Dark", \.dither.lightOnDark, help: "Draw the marks for the light tones on the dark color, like a glowing screen",
                      hint: "Draws the marks for the light tones on the dark color, like a glowing screen.", shown: { $0.dither.style.drawsMarks }),
        ],
        // Each slider says how bright that family of colors becomes, as Photoshop's do.
        .blackWhite: [
            family("Reds", \.blackWhite.reds, hue: 0), family("Yellows", \.blackWhite.yellows, hue: 60),
            family("Greens", \.blackWhite.greens, hue: 120), family("Cyans", \.blackWhite.cyans, hue: 180),
            family("Blues", \.blackWhite.blues, hue: 240), family("Magentas", \.blackWhite.magentas, hue: 300),
            .checkbox("Tint", \.blackWhite.tint, help: "Color the result while keeping its tones, for a sepia or a cyanotype",
                      hint: "Colors the result while keeping its tones, for a sepia or a cyanotype."),
            .slider(Row(caption: "Hue", key: \.blackWhite.tintHue, range: 0...360, unit: "°", decimals: 0, logarithmic: false,
                        shown: { $0.blackWhite.tint }, track: { _ in .plain })),
            .slider(Row(caption: "Saturation", key: \.blackWhite.tintSaturation, range: 0...100, unit: "%", decimals: 0, logarithmic: false,
                        shown: { $0.blackWhite.tint }, track: { .saturation($0.blackWhite.tintHue) })),
        ],
        .colorBalance: [
            .heading("Shadows"),
            balance("Cyan / Red", \.colorBalance.shadowCyanRed, .cyanRed),
            balance("Magenta / Green", \.colorBalance.shadowMagentaGreen, .magentaGreen),
            balance("Yellow / Blue", \.colorBalance.shadowYellowBlue, .yellowBlue),
            .heading("Midtones"),
            balance("Cyan / Red", \.colorBalance.midCyanRed, .cyanRed),
            balance("Magenta / Green", \.colorBalance.midMagentaGreen, .magentaGreen),
            balance("Yellow / Blue", \.colorBalance.midYellowBlue, .yellowBlue),
            .heading("Highlights"),
            balance("Cyan / Red", \.colorBalance.highlightCyanRed, .cyanRed),
            balance("Magenta / Green", \.colorBalance.highlightMagentaGreen, .magentaGreen),
            balance("Yellow / Blue", \.colorBalance.highlightYellowBlue, .yellowBlue),
            .checkbox("Preserve Luminosity", \.colorBalance.preserveLuminosity,
                      help: "Put each pixel's brightness back afterwards, so only the color moves",
                      hint: "Puts each pixel's brightness back afterward, so only the color moves."),
        ],
        .lensCorrection: [
            .slider(Row(caption: "Remove Distortion", key: \.distortion, range: -100...100, unit: nil, decimals: 0, logarithmic: false)),
            .note("Positive straightens lines that bow outward (barrel); negative, lines that bow inward (pincushion)."),
        ],
    ]

    nonisolated private static func palette(_ color: AdjustmentColor) -> PaletteColor {
        PaletteColor(red: color.red, green: color.green, blue: color.blue)
    }

    /// Black & White's row for a family of colors, its track dark to light in the family's hue.
    private static func family(_ caption: String, _ key: WritableKeyPath<FilterSettings, Double>, hue: Double) -> Control {
        .slider(Row(caption: caption, key: key, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false,
                    track: { _ in .luminance(hue) }))
    }
    /// Color Balance's row for a pair of colors, its track from one to the other.
    private static func balance(_ caption: String, _ key: WritableKeyPath<FilterSettings, Double>, _ track: CameraRawSliderTrack) -> Control {
        .slider(Row(caption: caption, key: key, range: ColorBalanceSettings.range, unit: nil, decimals: 0, logarithmic: false,
                    track: { _ in track }))
    }

    /// The kinds the iPad has this editor for; the Filter and Image menus offer them, and New Adjustment Layer the
    /// adjustments among them.
    static let kinds = Set(controls.keys)

    /// Each kind's slider rows, in order.
    static let rows: [FilterKind: [Row]] = controls.mapValues { controls in
        controls.compactMap { if case .slider(let row) = $0 { row } else { nil } }
    }

    let kind: FilterKind
    private var fields: [(row: Row, field: SliderField)] = []
    /// Why the preview couldn't be made, in orange, as the Mac's panel says it.
    private let error = OptionControls.caption("", color: .systemOrange)
    /// Puts the edit's values into the controls other than sliders.
    private var refreshers: [(FilterSettings) -> Void] = []

    init(session: EditorSession, kind: FilterKind) {
        self.kind = kind
        super.init(session: session, title: kind.rawValue)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var edit: FilterEdit? { session.filterEdit }
    private func update(_ change: (inout FilterSettings) -> Void) {
        guard var settings = edit?.settings else { return }
        change(&settings)
        session.updateFilter(settings, preview: edit?.preview ?? true)
    }

    override var isOpen: Bool { edit?.kind == kind }
    override var previews: Bool { edit?.preview ?? true }
    override func setPreview(_ on: Bool) {
        guard let edit else { return }
        session.updateFilter(edit.settings, preview: on)
    }
    override func cancel() { session.cancelFilter() }
    override func commit() {
        // OK waits for a slow filter's preview, as the Mac's disabled OK does; Return with it.
        guard canCommit else { return }
        let session = session
        Task { await session.commitFilter() }
    }
    override var canCommit: Bool {
        guard let edit else { return false }
        return !(kind.isAutomatic && (edit.preparing || edit.previewError != nil))
    }
    /// Applying… while OK applies the filter; Working… while a slow one (Remove Background, Content-Aware Fill) works out
    /// its preview, as the Mac's panel says. A quick one says nothing, so the panel doesn't flicker as a slider moves.
    override var activity: Activity? {
        guard let edit else { return nil }
        if edit.committing { return Activity(text: "Applying…", holds: true) }
        if edit.preparing, kind.isAutomatic { return Activity(text: "Working…", holds: false) }
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        var captions: [UILabel] = []
        /// Adds `view` to the controls, showing only while `shown` says so.
        func add(_ view: UIView, shown: ((FilterSettings) -> Bool)?) {
            content.addArrangedSubview(view)
            if let shown { refreshers.append { view.isHidden = !shown($0) } }
        }
        for control in Self.controls[kind] ?? [] {
            switch control {
            case .slider(let row):
                let step = pow(10, Double(row.decimals))
                let field = SliderField(caption: row.caption, unit: row.unit, sliderRange: row.range, fieldRange: row.range,
                                        sensitivity: 1 / step, logarithmic: row.logarithmic, decimals: row.decimals, sliderWidth: nil,
                                        fieldWidth: NumberField.width(toShow: row.range, decimals: row.decimals))
                field.onChange = { [weak self] value in self?.update { $0[keyPath: row.key] = value } }
                field.setHelp(row.help, hint: row.hint)
                if row.track != nil {
                    field.onReset = { [weak self] in self?.update { $0[keyPath: row.key] = FilterSettings()[keyPath: row.key] } }
                    // VoiceOver has Reset among the slider's actions, so that's no hint.
                    field.setHelp(row.help ?? row.caption + ". Double-click to reset.", hint: row.hint)
                }
                fields.append((row, field))
                content.addArrangedSubview(field)
            case .choice(let caption, let titles, let help, let hints, let chosen, let choose):
                let segments = OptionControls.segments(titles) { [weak self] index in self?.update { choose(&$0, index) } }
                segments.setHelp(help, hints: hints ?? [])
                refreshers.append { segments.selectedSegmentIndex = chosen($0) }
                let views = (caption.map { [OptionControls.caption($0, color: .secondaryLabel)] } ?? []) + [segments, UIView()]
                content.addArrangedSubview(OptionControls.row(views, spacing: 10))
            case .popUp(let caption, let groups, let help, let hint, let chosen, let choose, let shown):
                let popUp = PopUpButton()
                popUp.accessibilityLabel = caption
                popUp.setHelp(help, hint: hint)
                popUp.onChoose = { [weak self] name in self?.update { choose(&$0, name) } }
                refreshers.append { popUp.show(groups, chosen: chosen($0)) }
                add(OptionControls.row([OptionControls.caption(caption, color: .secondaryLabel), popUp, UIView()], spacing: 10), shown: shown)
            case .checkbox(let title, let key, let help, let hint, let shown):
                let box = OptionControls.checkbox(title) { [weak self] on in self?.update { $0[keyPath: key] = on } }
                box.setHelp(help, hint: hint)
                refreshers.append { box.isSelected = $0[keyPath: key] }
                add(OptionControls.row([box, UIView()]), shown: shown)
            case .field(let caption, let key, let help, let hint, let shown):
                let field = UITextField()
                field.borderStyle = .roundedRect
                field.font = .monospacedSystemFont(ofSize: OptionControls.controlFont.pointSize, weight: .regular)
                field.autocorrectionType = .no
                field.autocapitalizationType = .none
                field.spellCheckingType = .no
                field.accessibilityLabel = caption
                field.setHelp(help, hint: hint)
                field.addAction(UIAction { [weak self, weak field] _ in
                    guard let text = field?.text else { return }
                    self?.update { $0[keyPath: key] = text }
                }, for: .editingChanged)
                // Return only ends the typing, as in the Mac's field.
                field.addAction(UIAction { _ in }, for: .editingDidEndOnExit)
                refreshers.append { if !field.isEditing { field.text = $0[keyPath: key] } }
                add(OptionControls.row([OptionControls.caption(caption, color: .secondaryLabel), field], spacing: 10), shown: shown)
            case .color(let caption, let help, let hint, let value, let open):
                let label = OptionControls.caption(caption, color: .secondaryLabel)
                let swatch = SwatchButton(size: CGSize(width: 24, height: 24), cornerRadius: 6)
                swatch.accessibilityLabel = caption
                swatch.setHelp(help, hint: hint)
                swatch.addAction(UIAction { [weak self, weak swatch] _ in
                    guard let self else { return }
                    self.pickerSource = swatch
                    open(self.session)
                }, for: .primaryActionTriggered)
                refreshers.append { swatch.color = Self.palette(value($0)) }
                captions.append(label)
                // Spaced as a row's slider is from its caption, so the swatch starts where the sliders do.
                content.addArrangedSubview(OptionControls.row([label, swatch, UIView()], spacing: 8))
            case .gradient(let colors):
                let bar = GradientBar(height: 20)
                bar.layer.cornerRadius = 4
                bar.layer.cornerCurve = .continuous
                bar.layer.borderWidth = 1
                bar.layer.borderColor = UIColor.black.withAlphaComponent(0.35).cgColor
                bar.clipsToBounds = true
                refreshers.append { bar.colors = colors($0).map(Self.palette) }
                content.addArrangedSubview(bar)
            case .swatches(let ends, let titlesFirst, let shown):
                let pairs = ends.map { end -> UIView in
                    let swatch = SwatchButton(size: CGSize(width: 24, height: 24), cornerRadius: 6)
                    swatch.accessibilityLabel = end.title + " color"
                    swatch.setHelp("Choose the \(end.title.lowercased()) color", hint: "Opens the color picker.")
                    swatch.addAction(UIAction { [weak self, weak swatch] _ in
                        guard let self else { return }
                        self.pickerSource = swatch
                        end.open(self.session)
                    }, for: .primaryActionTriggered)
                    refreshers.append { swatch.color = Self.palette(end.value($0)) }
                    let title = OptionControls.caption(end.title, color: .label)
                    return OptionControls.row(titlesFirst ? [title, swatch] : [swatch, title], spacing: 8)
                }
                add(OptionControls.row(pairs + [UIView()], spacing: titlesFirst ? 18 : 20), shown: shown)
            case .heading(let title):
                let label = OptionControls.caption(title, color: .label)
                label.font = .preferredFont(forTextStyle: .headline)
                content.addArrangedSubview(label)
            case .text(let text):
                let label = OptionControls.caption(text, color: .label)
                label.numberOfLines = 0
                content.addArrangedSubview(label)
            case .note(let text):
                let note = OptionControls.caption(text, color: .secondaryLabel)
                note.numberOfLines = 0
                content.addArrangedSubview(note)
            }
        }
        SliderField.alignColumns(fields.map(\.field), with: captions)
        error.numberOfLines = 0
        notes.insertArrangedSubview(error, at: 0)
    }

    override func refresh() {
        guard let settings = edit?.settings else { return }
        for (row, field) in fields {
            field.show(settings[keyPath: row.key])
            field.isHidden = row.shown?(settings) == false
            if let track = row.track { field.track = track(settings) }
        }
        for refresh in refreshers { refresh(settings) }
        error.text = edit?.previewError
        error.isHidden = edit?.previewError == nil
    }
}

private extension BackgroundQuality {
    /// What choosing it does, as VoiceOver's hint says it on its segment.
    var hint: String {
        switch self {
        case .basic: "Makes a quick mask."
        case .advanced: "Refines the mask against the layer's own detail, for hair and fur."
        }
    }
}
