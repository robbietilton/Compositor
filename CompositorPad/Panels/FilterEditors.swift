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
    }

    /// The kinds the iPad has this editor for; the Filter and Image menus offer them, and New Adjustment Layer the
    /// adjustments among them.
    static let kinds: Set<FilterKind> = [.gaussianBlur]

    /// Each kind's rows, as the Mac's filter panel (FilterSheet) lays them out, with its ranges, units and decimals.
    static let rows: [FilterKind: [Row]] = [
        .gaussianBlur: [Row(caption: "Radius", key: \.radius, range: 0.1...250, unit: "px", decimals: 1, logarithmic: true)],
    ]

    let kind: FilterKind
    private var fields: [(row: Row, field: SliderField)] = []

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
        let session = session
        Task { await session.commitFilter() }
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
        for row in Self.rows[kind] ?? [] {
            let step = pow(10, Double(row.decimals))
            let field = SliderField(caption: row.caption, unit: row.unit, sliderRange: row.range, fieldRange: row.range,
                                    sensitivity: 1 / step, logarithmic: row.logarithmic, decimals: row.decimals, sliderWidth: nil,
                                    fieldWidth: NumberField.width(toShow: row.range, decimals: row.decimals))
            field.onChange = { [weak self] value in self?.update { $0[keyPath: row.key] = value } }
            fields.append((row, field))
            content.addArrangedSubview(field)
        }
        SliderField.alignCaptions(fields.map(\.field))
    }

    override func refresh() {
        guard let settings = edit?.settings else { return }
        for (row, field) in fields { field.show(settings[keyPath: row.key]) }
    }
}
