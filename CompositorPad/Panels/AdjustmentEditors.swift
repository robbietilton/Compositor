import UIKit

/// The editors for Levels, Curves and Hue/Saturation, as the Mac's panels: for an adjustment layer, or for a layer's
/// own pixels from the Image menu. Each follows the edit the editor has open, and closes with OK or Cancel.
enum AdjustmentEditors {
    /// The adjustment layers the iPad has an editor for; the rest open on the Mac.
    static let kinds: Set<AdjustmentKind> = [.hsv, .levels, .curves]

    /// An editor for the edit `session` has open, if the iPad has one.
    static func editor(for session: EditorSession) -> AdjustmentEditorController? {
        if session.levels != nil { return LevelsEditorController(session: session) }
        if session.hueSaturation != nil { return HueSaturationEditorController(session: session) }
        if session.filterEdit?.kind == .curves { return CurvesEditorController(session: session) }
        return nil
    }
}

/// What the editors share: a title, their own controls, and Preview, Reset, Cancel and OK along the foot, as the Mac's
/// panels have them. They stay open until OK or Cancel; the canvas behind them can still be moved and zoomed.
class AdjustmentEditorController: UIViewController {
    let session: EditorSession
    let content = UIStackView()
    private let stack = UIStackView()
    private let heading: String
    private let preview = OptionControls.checkbox("Preview") { _ in }
    private let ok = OptionControls.button("OK", prominent: true) {}

    init(session: EditorSession, title: String) {
        self.session = session
        heading = title
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Whether the edit this shows is still open.
    var isOpen: Bool { false }
    var previews: Bool { true }
    func setPreview(_ on: Bool) {}
    func reset() {}
    func cancel() {}
    func commit() {}
    /// Puts the edit's values into the controls; run on every update, so UIKit follows what it reads.
    func refresh() {}

    /// Escape cancels, as the Mac's Cancel button takes it, for when the editor's own fields have the keyboard; the
    /// window passes it on otherwise. Return there is the field's, which Hue/Saturation's take as OK, as on the Mac.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Cancel", action: #selector(cancelKey(_:)), input: UIKeyCommand.inputEscape)]
    }
    @objc private func cancelKey(_ command: UIKeyCommand) { cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        let title = OptionControls.title(heading)
        content.axis = .vertical
        content.spacing = 14
        preview.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setPreview(!self.previews)
        }, for: .primaryActionTriggered)
        let reset = OptionControls.button("Reset") { [weak self] in self?.reset() }
        let cancel = OptionControls.button("Cancel") { [weak self] in self?.cancel() }
        ok.addAction(UIAction { [weak self] _ in self?.commit() }, for: .primaryActionTriggered)
        let footer = OptionControls.row([preview, reset, UIView(), cancel, ok], spacing: 10)
        for view in [title, content, footer] { stack.addArrangedSubview(view) }
        stack.axis = .vertical
        stack.spacing = 18
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            stack.widthAnchor.constraint(equalToConstant: 400),
        ])
    }

    /// As tall as the controls, which change as the edit does: a range's own settings, say.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: 400, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let size = CGSize(width: 440, height: ceil(fitting.height) + 36)
        if preferredContentSize != size { preferredContentSize = size }
    }

    override func updateProperties() {
        super.updateProperties()
        guard isOpen else { return }
        preview.isSelected = previews
        refresh()
    }
}

// MARK: Levels

final class LevelsEditorController: AdjustmentEditorController {
    private let channel = OptionControls.segments(LevelsChannel.allCases.map(\.rawValue)) { _ in }
    private let histogram = HistogramView()
    private let input = LevelsHandlesView(count: 3)
    private let output = LevelsHandlesView(count: 2)
    // Short captions: the rows sit under the histogram and the ramp, which say which they set. VoiceOver hears the Mac's
    // names.
    private let black = NumberField(caption: "Black", width: 64, range: 0...255)
    private let gamma = NumberField(caption: "Gamma", width: 64, range: 0.1...9.99, sensitivity: 0.01, format: { String(format: "%.2f", $0) })
    private let white = NumberField(caption: "White", width: 64, range: 0...255)
    private let outputBlack = NumberField(caption: "Black", width: 64, range: 0...255)
    private let outputWhite = NumberField(caption: "White", width: 64, range: 0...255)
    private let auto = OptionControls.button("Auto") {}
    private let note = OptionControls.caption("", color: .secondaryLabel)

    init(session: EditorSession) { super.init(session: session, title: "Levels") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var edit: LevelsEdit? { session.levels }
    private var settings: LevelsSettings { edit?.settings ?? LevelsSettings() }
    private func update(_ change: (inout LevelsSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateLevels(value, preview: edit?.preview ?? true)
    }
    private func change(_ key: WritableKeyPath<LevelRange, Double>, to value: Double) {
        update { settings in
            var range = settings.current
            range[keyPath: key] = value
            settings.current = range
        }
    }

    override var isOpen: Bool { edit != nil }
    override var previews: Bool { edit?.preview ?? true }
    override func setPreview(_ on: Bool) { session.updateLevels(settings, preview: on) }
    override func reset() {
        edit?.sampleMode = nil
        update { $0 = LevelsSettings() }
    }
    override func cancel() { session.cancelLevels() }
    override func commit() {
        let session = session
        Task { await session.commitLevels() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let channels = LevelsChannel.allCases
        channel.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let chosen = channels[max(0, self.channel.selectedSegmentIndex)]
            self.update { $0.channel = chosen }
        }, for: .valueChanged)
        input.onDrag = { [weak self] index, x in
            self?.update { $0.current = Self.range($0.current, input: index, at: x) }
        }
        output.onDrag = { [weak self] index, x in
            self?.change(index == 0 ? \.outputBlack : \.outputWhite, to: x.rounded())
        }
        for (field, key, name) in [(black, \LevelRange.black, "Input black"), (gamma, \.gamma, "Gamma"), (white, \.white, "Input white"),
                                   (outputBlack, \.outputBlack, "Output black"), (outputWhite, \.outputWhite, "Output white")] {
            field.live = true
            field.onChange = { [weak self] in self?.change(key, to: $0) }
            field.field.accessibilityLabel = name
        }
        auto.menu = UIMenu(children: LevelsAuto.allCases.map { mode in
            UIAction(title: mode.rawValue) { [weak self] _ in self?.session.autoLevels(mode) }
        })
        auto.showsMenuAsPrimaryAction = true
        let gradient = GradientBar()
        let inputFields = OptionControls.row([black, UIView(), gamma, UIView(), white])
        let outputFields = OptionControls.row([outputBlack, UIView(), outputWhite])
        for view in [channel, histogram, input, inputFields, gradient, output, outputFields, OptionControls.row([auto, UIView()]), note] as [UIView] {
            content.addArrangedSubview(view)
        }
        content.setCustomSpacing(0, after: histogram)
        content.setCustomSpacing(0, after: gradient)
        note.numberOfLines = 0
    }

    /// The input's triangle `index` dragged to `x`, from 0 to 255: black and white keep a level apart, and the gray one
    /// sets gamma by where it stands between them, as on the Mac.
    static func range(_ range: LevelRange, input index: Int, at x: Double) -> LevelRange {
        var range = range
        if index == 0 { range.black = min(range.white - 1, x.rounded()) }
        else if index == 2 { range.white = max(range.black + 1, x.rounded()) }
        else {
            let fraction = min(0.999, max(0.001, (x - range.black) / (range.white - range.black)))
            range.gamma = log(fraction) / log(0.5)
        }
        return range
    }

    override func refresh() {
        guard let edit else { return }
        let settings = edit.settings, current = settings.current
        channel.selectedSegmentIndex = settings.channel.index
        histogram.show(edit.histogram[settings.channel.index], channel: settings.channel, ready: edit.histogramReady)
        // The gray triangle stands where the input's midtone lands.
        input.positions = [current.black, current.black + (current.white - current.black) * pow(0.5, current.gamma), current.white]
        output.positions = [current.outputBlack, current.outputWhite]
        black.show(current.black)
        gamma.show(current.gamma)
        white.show(current.white)
        outputBlack.show(current.outputBlack)
        outputWhite.show(current.outputWhite)
        auto.isEnabled = edit.histogramReady && !edit.committing
        note.text = session.adjustmentOriginal != nil ? "Underlying pixels · alpha-weighted histogram"
            : session.selection == nil ? "Original pixels · alpha-weighted histogram" : "Original pixels · selection and alpha-weighted histogram"
        view.isUserInteractionEnabled = !edit.committing
    }
}

/// The input's tones as the Mac's Levels shows them: a bar for each of the 256 levels, scaled so a spike doesn't flatten
/// the rest.
final class HistogramView: UIView {
    private var bins: [Double] = []
    private var color = UIColor.gray
    private let loading = OptionControls.caption("Loading histogram…", color: .secondaryLabel)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0, alpha: 0.25)
        isOpaque = false
        contentMode = .redraw
        addSubview(loading)
        loading.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 150),
            loading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            loading.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ bins: [Double], channel: LevelsChannel, ready: Bool) {
        let color: UIColor = switch channel { case .rgb: .gray; case .red: .systemRed; case .green: .systemGreen; case .blue: .systemBlue }
        loading.isHidden = ready
        accessibilityLabel = "Original \(channel.rawValue) histogram"
        guard bins != self.bins || color != self.color else { return }
        self.bins = bins
        self.color = color
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let peak = LevelsHistogramDisplay.scale(for: bins)
        guard peak > 0, let context = UIGraphicsGetCurrentContext() else { return }
        let width = bounds.width / 256
        for (index, bin) in bins.enumerated() {
            let height = bounds.height * min(1, max(0, bin / peak))
            context.addRect(CGRect(x: CGFloat(index) * width, y: bounds.height - height, width: width + 0.1, height: height))
        }
        context.setFillColor(color.cgColor)
        context.fillPath()
    }
}

/// The triangles under a histogram or the output ramp, dragged along it: black, gray and white for the input, black and
/// white for the output. A finger takes the nearest one within reach.
final class LevelsHandlesView: UIView {
    /// Where each triangle stands, from 0 to 255.
    var positions: [Double] = [] { didSet { if positions != oldValue { setNeedsDisplay() } } }
    var onDrag: (Int, Double) -> Void = { _, _ in }
    private var dragging: Int?

    init(count: Int) {
        positions = count == 3 ? [0, 127.5, 255] : [0, 255]
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func x(of position: Double) -> CGFloat { CGFloat(position / 255) * bounds.width }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for (index, position) in positions.enumerated() {
            let x = x(of: position)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: x, y: 4))
            path.addLine(to: CGPoint(x: x + 7, y: 16))
            path.addLine(to: CGPoint(x: x - 7, y: 16))
            path.close()
            let fill: UIColor = index == 0 ? .black : index == positions.count - 1 ? .white : .gray
            context.setFillColor(fill.cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
            context.setStrokeColor(UIColor.gray.cgColor)
            context.setLineWidth(1)
            context.addPath(path.cgPath)
            context.strokePath()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let x = touch.location(in: self).x
        let nearest = positions.indices.min { abs(self.x(of: positions[$0]) - x) < abs(self.x(of: positions[$1]) - x) }
        dragging = nearest.flatMap { abs(self.x(of: positions[$0]) - x) <= PadCanvasInput.reach ? $0 : nil }
        drag(touch)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first { drag(touch) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { dragging = nil }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { dragging = nil }

    private func drag(_ touch: UITouch) {
        guard let dragging, bounds.width > 0 else { return }
        onDrag(dragging, min(255, max(0, Double(touch.location(in: self).x / bounds.width) * 255)))
    }
}

/// The output ramp, black to white.
private final class GradientBar: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let gradient = layer as! CAGradientLayer
        gradient.colors = [UIColor.black.cgColor, UIColor.white.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        heightAnchor.constraint(equalToConstant: 14).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: Curves

/// The Mac's rules for shaping a curve, in its own units, 0 to 255 on each axis: a press takes the nearest point within
/// `reach`, or else adds one there if there's room, and a dragged point keeps between its neighbors, while the end
/// points move only up and down.
enum CurveEditing {
    /// The point a press at (`x`, `y`) takes: an existing one within `reach`, or a new one, which goes into `points`.
    static func press(_ points: inout [CurvePoint], x: Double, y: Double, reach: Double = 14) -> Int? {
        if let index = points.indices.min(by: { hypot(points[$0].x - x, points[$0].y - y) < hypot(points[$1].x - x, points[$1].y - y) }),
           hypot(points[index].x - x, points[index].y - y) < reach {
            return index
        }
        guard points.count < 32, x > 1, x < 254, points.allSatisfy({ abs($0.x - x) > 1 }) else { return nil }
        points.append(CurvePoint(x: x, y: y))
        points.sort { $0.x < $1.x }
        return points.firstIndex { $0.x == x }
    }

    /// Point `index` dragged to (`x`, `y`).
    static func drag(_ points: inout [CurvePoint], index: Int, x: Double, y: Double) {
        guard points.indices.contains(index) else { return }
        points[index].y = y
        if index > 0, index < points.count - 1 { points[index].x = min(points[index + 1].x - 1, max(points[index - 1].x + 1, x)) }
    }
}

final class CurvesEditorController: AdjustmentEditorController {
    private let channel = OptionControls.segments(LevelsChannel.allCases.map(\.rawValue)) { _ in }
    private let curve = CurveView()
    private let point = OptionControls.caption("", color: .secondaryLabel)
    private let remove = OptionControls.button("Remove Point") {}

    init(session: EditorSession) { super.init(session: session, title: "Curves") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var edit: FilterEdit? { session.filterEdit }
    private func update(_ change: (inout CurvesSettings) -> Void) {
        guard var settings = edit?.settings else { return }
        change(&settings.curves)
        session.updateFilter(settings, preview: edit?.preview ?? true)
    }

    override var isOpen: Bool { edit?.kind == .curves }
    override var previews: Bool { edit?.preview ?? true }
    override func setPreview(_ on: Bool) {
        guard let edit else { return }
        session.updateFilter(edit.settings, preview: on)
    }
    override func reset() {
        curve.selected = nil
        update { $0.channels[$0.channel.index] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 255, y: 255)] }
    }
    override func cancel() { session.cancelFilter() }
    override func commit() {
        let session = session
        Task { await session.commitFilter() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let channels = LevelsChannel.allCases
        channel.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let chosen = channels[max(0, self.channel.selectedSegmentIndex)]
            self.curve.selected = nil
            self.update { $0.channel = chosen }
        }, for: .valueChanged)
        curve.onChange = { [weak self] points in self?.update { $0.channels[$0.channel.index] = points } }
        remove.addAction(UIAction { [weak self] _ in
            guard let self, let selected = self.curve.selected else { return }
            self.curve.selected = nil
            self.update { $0.channels[$0.channel.index].remove(at: selected) }
        }, for: .primaryActionTriggered)
        let hint = OptionControls.caption("Tap to add a point. Drag to adjust.", color: .secondaryLabel)
        for view in [channel, curve, hint, OptionControls.row([point, UIView(), remove])] as [UIView] { content.addArrangedSubview(view) }
    }

    override func refresh() {
        guard let settings = edit?.settings.curves else { return }
        channel.selectedSegmentIndex = settings.channel.index
        curve.settings = settings
        let points = settings.channels[settings.channel.index]
        if let selected = curve.selected, points.indices.contains(selected) {
            point.text = "Input \(Int(points[selected].x)) · Output \(Int(points[selected].y))"
            // The end points stay: a curve runs from 0 to 255.
            remove.isEnabled = selected > 0 && selected < points.count - 1
        } else {
            point.text = nil
            remove.isEnabled = false
        }
    }
}

/// The curve with its points over a grid, as the Mac draws it, shaped with a finger or Apple Pencil.
final class CurveView: UIView {
    var settings = CurvesSettings() { didSet { setNeedsDisplay() } }
    var selected: Int? { didSet { setNeedsDisplay() } }
    var onChange: ([CurvePoint]) -> Void = { _ in }
    private var dragging: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0, alpha: 0.35)
        contentMode = .redraw
        heightAnchor.constraint(equalToConstant: 260).isActive = true
        isAccessibilityElement = true
        accessibilityLabel = "Curve"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var points: [CurvePoint] { settings.channels[settings.channel.index] }
    private func position(_ point: CurvePoint) -> CGPoint {
        CGPoint(x: point.x / 255 * bounds.width, y: (1 - point.y / 255) * bounds.height)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(UIColor(white: 1, alpha: 0.12).cgColor)
        context.setLineWidth(1)
        for step in 0...4 {
            let fraction = CGFloat(step) / 4
            context.move(to: CGPoint(x: fraction * bounds.width, y: 0))
            context.addLine(to: CGPoint(x: fraction * bounds.width, y: bounds.height))
            context.move(to: CGPoint(x: 0, y: fraction * bounds.height))
            context.addLine(to: CGPoint(x: bounds.width, y: fraction * bounds.height))
        }
        context.strokePath()
        for x in 0...255 {
            let point = position(CurvePoint(x: Double(x), y: settings.value(Double(x), channel: settings.channel.index)))
            if x == 0 { context.move(to: point) } else { context.addLine(to: point) }
        }
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(2)
        context.strokePath()
        for (index, point) in points.enumerated() {
            let center = position(point)
            context.setFillColor((selected == index ? tintColor : UIColor.white).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        }
    }

    /// A touch in the curve's own units.
    private func curvePoint(_ touch: UITouch) -> (x: Double, y: Double) {
        let location = touch.location(in: self)
        return (min(255, max(0, Double(location.x / max(1, bounds.width)) * 255)),
                min(255, max(0, 255 - Double(location.y / max(1, bounds.height)) * 255)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let (x, y) = curvePoint(touch)
        var points = points
        // A fingertip reaches further than the Mac's pointer: 22 points, in the curve's units.
        let reach = max(14, Double(PadCanvasInput.reach / max(1, bounds.width)) * 255)
        dragging = CurveEditing.press(&points, x: x, y: y, reach: reach)
        guard let dragging else { return }
        selected = dragging
        CurveEditing.drag(&points, index: dragging, x: x, y: y)
        onChange(points)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let dragging else { return }
        let (x, y) = curvePoint(touch)
        var points = points
        CurveEditing.drag(&points, index: dragging, x: x, y: y)
        onChange(points)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { dragging = nil }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { dragging = nil }
}

// MARK: Hue/Saturation

final class HueSaturationEditorController: AdjustmentEditorController {
    private let range = PopUpButton()
    private let sliders = UIStackView()
    private let invert = OptionControls.checkbox("Apply outside this range instead") { _ in }
    private let colorize = OptionControls.checkbox("Colorize") { _ in }
    /// Whether the sliders were made for colorizing, whose ranges differ.
    private var slidersColorize: Bool?
    private var hue: SliderField?, saturation: SliderField?, lightness: SliderField?

    init(session: EditorSession) { super.init(session: session, title: "Hue/Saturation") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var edit: HueSaturationEdit? { session.hueSaturation }
    private var settings: HueSaturationSettings { edit?.settings ?? HueSaturationSettings() }
    private func update(_ change: (inout HueSaturationSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateHueSaturation(value, preview: edit?.preview ?? true)
    }

    override var isOpen: Bool { edit != nil }
    override var previews: Bool { edit?.preview ?? true }
    override func setPreview(_ on: Bool) { session.updateHueSaturation(settings, preview: on) }
    override func reset() { update { $0 = $0.colorize ? .colorizeStart : HueSaturationSettings() } }
    override func cancel() { session.cancelHueSaturation() }
    override func commit() {
        let session = session
        Task { await session.commitHueSaturation() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        range.accessibilityLabel = "Range"
        range.onChoose = { [weak self] name in
            guard let chosen = ColorRange(rawValue: name) else { return }
            self?.update { $0.range = chosen }
        }
        invert.addAction(UIAction { [weak self] _ in self?.update { $0.invertRange.toggle() } }, for: .primaryActionTriggered)
        // Photoshop starts colorizing at hue 0, saturation 25.
        colorize.addAction(UIAction { [weak self] _ in
            self?.update { $0 = $0.colorize ? HueSaturationSettings() : .colorizeStart }
        }, for: .primaryActionTriggered)
        sliders.axis = .vertical
        sliders.spacing = 12
        for view in [OptionControls.row([range, UIView()]), sliders, OptionControls.row([invert, UIView()]),
                     OptionControls.row([colorize, UIView()])] as [UIView] {
            content.addArrangedSubview(view)
        }
    }

    /// The sliders, made again when colorizing changes their ranges: hue −180 to 180, or 0 to 360 colorizing;
    /// saturation −100 to 100, or 0 to 100.
    private func makeSliders(colorize: Bool) {
        sliders.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func slider(_ caption: String, _ range: ClosedRange<Double>, unit: String? = nil,
                    _ key: WritableKeyPath<HueSaturationSettings, Double>) -> SliderField {
            let field = SliderField(caption: caption, unit: unit, sliderRange: range, fieldRange: range, sensitivity: 1, sliderWidth: 220)
            field.onChange = { [weak self] value in self?.update { $0[keyPath: key] = value.rounded() } }
            // Return in a field applies the adjustment, as on the Mac, where Levels' and Curves' fields keep it.
            field.onReturn = { [weak self] in self?.commit() }
            sliders.addArrangedSubview(field)
            return field
        }
        hue = slider("Hue", colorize ? 0...360 : -180...180, unit: "°", \.hue)
        saturation = slider("Saturation", colorize ? 0...100 : -100...100, \.saturation)
        lightness = slider("Lightness", -100...100, \.lightness)
        slidersColorize = colorize
    }

    override func refresh() {
        let settings = settings
        if slidersColorize != settings.colorize { makeSliders(colorize: settings.colorize) }
        range.show([ColorRange.allCases.map(\.rawValue)], chosen: settings.range.rawValue)
        range.isEnabled = !settings.colorize
        hue?.show(settings.hue)
        saturation?.show(settings.saturation)
        lightness?.show(settings.lightness)
        invert.superview?.isHidden = settings.range == .master || settings.colorize
        invert.isSelected = settings.invertRange
        colorize.isSelected = settings.colorize
    }
}
