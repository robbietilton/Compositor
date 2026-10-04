import UIKit

/// The editor for one of a layer's effects, as the Mac's effect panel: the effect's name with its color, or Stroke's
/// position, beside it, its rows, and Cancel and OK. It stays bound to the layer that opened it, and its changes show
/// on the canvas as they're made.
final class EffectEditorController: AdjustmentEditorController {
    /// A row of the Mac's effect panel: a slider and an exact field, which can reach past the slider, as Distance does.
    struct Row {
        let caption: String
        let slider: ClosedRange<Double>
        let field: ClosedRange<Double>
        let unit: String
        /// What the field shows for a value: Opacity shows 0 to 1 as 0 to 100.
        var scale: Double = 1
        let get: (LayerEffects) -> Double?
        let set: (inout LayerEffects, Double) -> Void
    }

    /// Opacity, which the effects keep from 0 to 1 and show as a percentage.
    private static func opacity<Effect>(_ effect: WritableKeyPath<LayerEffects, Effect?>, _ value: WritableKeyPath<Effect, Double>) -> Row {
        Row(caption: "Opacity", slider: 0...1, field: 0...1, unit: "%", scale: 100, get: { $0[keyPath: effect]?[keyPath: value] },
            set: { $0[keyPath: effect]?[keyPath: value] = $1 })
    }
    private static func row<Effect>(_ caption: String, _ effect: WritableKeyPath<LayerEffects, Effect?>, _ value: WritableKeyPath<Effect, CGFloat>,
                                    slider: ClosedRange<Double>, field: ClosedRange<Double>? = nil, unit: String) -> Row {
        Row(caption: caption, slider: slider, field: field ?? slider, unit: unit,
            get: { $0[keyPath: effect].map { Double($0[keyPath: value]) } }, set: { $0[keyPath: effect]?[keyPath: value] = CGFloat($1) })
    }

    /// Each effect's rows, as the Mac's effect panel (EffectsSheet) has them.
    static let rows: [LayerEffectKind: [Row]] = [
        .stroke: [row("Size", \.stroke, \.size, slider: 0...20, field: 0...Double(StrokeEffect.maxSize), unit: "px"), opacity(\.stroke, \.opacity)],
        .shadow: [
            opacity(\.shadow, \.opacity), row("Angle", \.shadow, \.angle, slider: -180...180, unit: "°"),
            row("Distance", \.shadow, \.distance, slider: 0...100, field: 0...5000, unit: "px"),
            row("Blur", \.shadow, \.blur, slider: 0...100, field: 0...500, unit: "px"),
        ],
        .colorOverlay: [opacity(\.colorOverlay, \.opacity)],
        .innerShadow: [
            opacity(\.innerShadow, \.opacity), row("Angle", \.innerShadow, \.angle, slider: -180...180, unit: "°"),
            row("Distance", \.innerShadow, \.distance, slider: 0...50, field: 0...5000, unit: "px"),
            row("Blur", \.innerShadow, \.blur, slider: 0...100, field: 0...500, unit: "px"),
        ],
        .outerGlow: [row("Size", \.outerGlow, \.size, slider: 0...100, field: 0...500, unit: "px"), opacity(\.outerGlow, \.opacity)],
        .innerGlow: [row("Size", \.innerGlow, \.size, slider: 0...100, field: 0...500, unit: "px"), opacity(\.innerGlow, \.opacity)],
    ]

    let selection: LayerEffectSelection
    private var fields: [(row: Row, field: SliderField)] = []
    private let swatch = SwatchButton(size: CGSize(width: 36, height: 18), cornerRadius: 3, inner: 1)
    private let position = OptionControls.segments(["Outside", "Inside"]) { _ in }

    init(session: EditorSession, selection: LayerEffectSelection) {
        self.selection = selection
        super.init(session: session, title: selection.kind.rawValue)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var kind: LayerEffectKind { selection.kind }

    override var isOpen: Bool { session.effectsEditing == selection }
    override func cancel() { session.finishEffectsEditing(commit: false) }
    override func commit() { session.finishEffectsEditing(commit: true) }
    // The Mac's effect panel has no Preview or Reset: what's set shows as it's set.
    override func previewRow(preview: UIView, reset: UIView) -> [UIView] { [] }
    override var notesSelection: Bool { false }
    override var foot: Foot { .effect }
    override func headingAccessory() -> UIView? { kind == .stroke ? position : swatch }

    override func viewDidLoad() {
        swatch.accessibilityLabel = kind.rawValue + " color"
        swatch.toolTip = kind.rawValue + " color"
        swatch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pickerSource = self.swatch
            self.session.openEffectColorPicker(self.kind)
        }, for: .primaryActionTriggered)
        position.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let inside = self.position.selectedSegmentIndex == 1
            self.session.changeEffects { $0.stroke?.inside = inside }
        }, for: .valueChanged)
        super.viewDidLoad()
        var captions: [UILabel] = []
        // Stroke's color has a row of its own, under its position.
        if kind == .stroke {
            let label = OptionControls.caption("Color", color: .secondaryLabel)
            captions.append(label)
            // Spaced as a row's slider is from its caption, so the swatch starts where the sliders do.
            content.addArrangedSubview(OptionControls.row([label, swatch, UIView()], spacing: 8))
        }
        for row in Self.rows[kind] ?? [] {
            let field = SliderField(caption: row.caption, unit: row.unit, sliderRange: row.slider, fieldRange: row.field,
                                    fieldScale: row.scale, sensitivity: 1 / row.scale, sliderWidth: nil,
                                    fieldWidth: NumberField.width(toShow: row.field.lowerBound * row.scale...row.field.upperBound * row.scale, decimals: 0))
            field.arrowStep = 1
            field.onChange = { [weak self] value in self?.session.changeEffects { row.set(&$0, value) } }
            fields.append((row, field))
            content.addArrangedSubview(field)
        }
        SliderField.alignColumns(fields.map(\.field), with: captions)
    }

    override func refresh() {
        let effects = session.editingEffects
        // Undone, or gone with its layer: the window ends the editing, and the editor with it.
        guard effects.contains(kind) else { return }
        for (row, field) in fields {
            if let value = row.get(effects) { field.show(value) }
        }
        if let color = effects.color(kind) { swatch.color = color }
        position.selectedSegmentIndex = effects.stroke?.inside == true ? 1 : 0
    }
}
