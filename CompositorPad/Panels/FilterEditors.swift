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
        /// When the row shows, as Remove Background's Advanced rows; always if nil.
        var shown: ((FilterSettings) -> Bool)? = nil
    }

    /// What the Mac's filter panel puts in a filter's editor, in order.
    enum Control {
        case slider(Row)
        /// A choice among `titles`, as segments, captioned or not; `chosen` reads which, and `choose` sets it.
        case choice(caption: String?, titles: [String], help: String?, chosen: (FilterSettings) -> Int, choose: (inout FilterSettings, Int) -> Void)
        case checkbox(String, WritableKeyPath<FilterSettings, Bool>)
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
            .choice(caption: "Distribution", titles: ["Uniform", "Gaussian"], help: nil, chosen: { $0.gaussian ? 1 : 0 },
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
                    chosen: { BackgroundQuality.allCases.firstIndex(of: $0.backgroundQuality) ?? 0 },
                    choose: { $0.backgroundQuality = BackgroundQuality.allCases[$1] }),
            .slider(Row(caption: "Refine", key: \.refineEdges, range: 0...40, unit: "px", decimals: 0, logarithmic: false,
                        help: "Pull the mask onto the image's own edges, which recovers hair and fur", shown: { $0.backgroundQuality == .advanced })),
            .slider(Row(caption: "Contrast", key: \.matteContrast, range: 0...100, unit: "%", decimals: 0, logarithmic: false,
                        help: "Clear the haze that leaves background showing through thin areas", shown: { $0.backgroundQuality == .advanced })),
            .slider(Row(caption: "Shift Edge", key: \.shiftEdge, range: -10...10, unit: "px", decimals: 0, logarithmic: false,
                        help: "Shrink the mask to drop the rim of background color around the subject, or grow it",
                        shown: { $0.backgroundQuality == .advanced })),
        ],
        .lensCorrection: [
            .slider(Row(caption: "Remove Distortion", key: \.distortion, range: -100...100, unit: nil, decimals: 0, logarithmic: false)),
            .note("Positive straightens lines that bow outward (barrel); negative, lines that bow inward (pincushion)."),
        ],
    ]

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
        for control in Self.controls[kind] ?? [] {
            switch control {
            case .slider(let row):
                let step = pow(10, Double(row.decimals))
                let field = SliderField(caption: row.caption, unit: row.unit, sliderRange: row.range, fieldRange: row.range,
                                        sensitivity: 1 / step, logarithmic: row.logarithmic, decimals: row.decimals, sliderWidth: nil,
                                        fieldWidth: NumberField.width(toShow: row.range, decimals: row.decimals))
                field.onChange = { [weak self] value in self?.update { $0[keyPath: row.key] = value } }
                field.toolTip = row.help
                fields.append((row, field))
                content.addArrangedSubview(field)
            case .choice(let caption, let titles, let help, let chosen, let choose):
                let segments = OptionControls.segments(titles) { [weak self] index in self?.update { choose(&$0, index) } }
                if let help { segments.addInteraction(UIToolTipInteraction(defaultToolTip: help)) }
                refreshers.append { segments.selectedSegmentIndex = chosen($0) }
                let views = (caption.map { [OptionControls.caption($0, color: .secondaryLabel)] } ?? []) + [segments, UIView()]
                content.addArrangedSubview(OptionControls.row(views, spacing: 10))
            case .checkbox(let title, let key):
                let box = OptionControls.checkbox(title) { [weak self] on in self?.update { $0[keyPath: key] = on } }
                refreshers.append { box.isSelected = $0[keyPath: key] }
                content.addArrangedSubview(OptionControls.row([box, UIView()]))
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
        SliderField.alignCaptions(fields.map(\.field))
        error.numberOfLines = 0
        notes.insertArrangedSubview(error, at: 0)
    }

    override func refresh() {
        guard let settings = edit?.settings else { return }
        for (row, field) in fields {
            field.show(settings[keyPath: row.key])
            field.isHidden = row.shown?(settings) == false
        }
        for refresh in refreshers { refresh(settings) }
        error.text = edit?.previewError
        error.isHidden = edit?.previewError == nil
    }
}
