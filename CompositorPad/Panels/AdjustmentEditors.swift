import UIKit

/// The editors for Levels, Curves, Hue/Saturation and the filters, as the Mac's panels: for an adjustment layer, or for
/// a layer's own pixels from the Image and Filter menus. Each follows the edit the editor has open, and closes with OK
/// or Cancel.
enum AdjustmentEditors {
    /// The adjustment layers the iPad has an editor for; the rest open on the Mac.
    static let kinds: Set<AdjustmentKind> = Set(AdjustmentKind.allCases.filter { kind in
        kind == .hsv || kind == .levels || kind == .curves || kind.filterKind.map(FilterEditorController.kinds.contains) == true
    })

    /// An editor for the edit `session` has open, if the iPad has one.
    static func editor(for session: EditorSession) -> AdjustmentEditorController? {
        if session.levels != nil { return LevelsEditorController(session: session) }
        if session.hueSaturation != nil { return HueSaturationEditorController(session: session) }
        if session.filterEdit?.kind == .curves { return CurvesEditorController(session: session) }
        if let kind = session.filterEdit?.kind, FilterEditorController.kinds.contains(kind) {
            return FilterEditorController(session: session, kind: kind)
        }
        if let editing = session.effectsEditing { return EffectEditorController(session: session, selection: editing) }
        return nil
    }
}

/// What the editors share, laid out as the Mac's panels: a title, the editor's own controls, the row with Preview, notes
/// under it, and Cancel and OK apart along the foot, under a line. The controls scroll when the editor is given less room
/// than they need, as the keyboard or a short window gives it. Editors stay open until OK or Cancel; the canvas behind
/// them can still be moved and zoomed.
class AdjustmentEditorController: UIViewController, UIColorPickerViewControllerDelegate {
    let session: EditorSession
    let content = UIStackView()
    /// Notes under the row with Preview, as each Mac panel has its own.
    let notes = UIStackView()
    private let titleLabel: UILabel
    private let heading = OptionControls.row([], spacing: 10)
    private let body = UIStackView()
    private let scroll = EditorScrollView()
    private let footer: UIStackView
    private let preview = OptionControls.checkbox("Preview") { _ in }
    private let ok = OptionControls.button("OK", prominent: true) {}
    private let limited = OptionControls.caption("Limited to the selection", color: .secondaryLabel)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let activityLabel = OptionControls.caption("", color: .secondaryLabel)

    init(session: EditorSession, title: String) {
        self.session = session
        titleLabel = OptionControls.title(title)
        footer = OptionControls.row([], spacing: 10)
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
    /// The row with Preview, laid out as the editor's Mac panel lays it out, `reset` being its Reset; none if empty, as
    /// an effect's panel has none.
    func previewRow(preview: UIView, reset: UIView) -> [UIView] { [preview, UIView()] }
    /// What sits at the far end of the title's row, as an effect's color does on the Mac.
    func headingAccessory() -> UIView? { nil }
    /// The foot of the editor: Cancel and OK apart under a line, as the Mac's filter panels have them, or together at
    /// the far end, as its effect panels do.
    enum Foot { case panel, effect }
    var foot: Foot { .panel }
    /// Whether the editor says when the selection limits it, as the Mac's filter and Hue/Saturation panels do. Never on
    /// an adjustment layer, which a selection doesn't limit.
    var notesSelection: Bool { true }

    /// What OK waits on, shown beside it as the Mac's panels show it.
    struct Activity {
        /// What the editor says it's doing, or nil for a spinner alone, as Levels has.
        var text: String?
        /// Whether the editor takes nothing meanwhile, as while OK applies the edit.
        var holds: Bool
    }
    /// What the editor is doing that OK waits on, if anything.
    var activity: Activity? { nil }
    /// Whether OK can be pressed now: not while a slow filter's preview is worked out, or can't be.
    var canCommit: Bool { true }

    // MARK: Picking colors

    /// The swatch the color picker points at.
    weak var pickerSource: UIView?
    private weak var shownPicker: UIColorPickerViewController?

    /// Whether the editor picks colors for `target`: a filter's, an adjustment's or an effect's.
    static func picks(_ target: ColorPickerTarget) -> Bool {
        switch target {
        case .vignette, .gradientMap, .dither, .effect: true
        case .palette, .text, .dialog: false
        }
    }

    /// Shows the system's color picker over the editor while one of its colors is being picked, as the Mac's opens on a
    /// swatch, and takes it away when the picking ends: by Escape or Return, or the edit's ending, which ends it too.
    private func followColorPicker() {
        let picking = session.colorPicker.map { Self.picks($0.target) } == true
        if picking, shownPicker == nil, presentedViewController == nil, let colorPicker = session.colorPicker {
            let picker = UIColorPickerViewController()
            picker.supportsAlpha = false
            let color = colorPicker.original
            picker.selectedColor = UIColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
            picker.delegate = self
            picker.modalPresentationStyle = .popover
            picker.popoverPresentationController?.sourceView = pickerSource ?? view
            present(picker, animated: true)
            shownPicker = picker
        } else if !picking, let picker = shownPicker {
            shownPicker = nil
            picker.dismiss(animated: true)
        }
    }

    /// The canvas follows the color as it's picked, as on the Mac.
    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard let colorPicker = session.colorPicker, let picked = SwatchButton.paletteColor(color) else { return }
        colorPicker.hsb.setRGB(picked)
        session.previewVignetteColor()
        session.previewGradientMapColor()
        session.previewDitherColor()
        session.previewEffectColor()
    }

    /// The picker put away with a tap off it, which is how the system's says OK: the color stays.
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        guard session.colorPicker.map({ Self.picks($0.target) }) == true else { return }
        session.closeColorPicker(commit: true)
    }

    /// Escape cancels, as the Mac's Cancel button takes it, for when the editor's own fields have the keyboard; the
    /// window passes it on otherwise. Return there is the field's, which Hue/Saturation's take as OK, as on the Mac.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Cancel", action: #selector(cancelKey(_:)), input: UIKeyCommand.inputEscape)]
    }
    @objc private func cancelKey(_ command: UIKeyCommand) { cancel() }

    override func loadView() { view = EditorView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        content.axis = .vertical
        content.spacing = 14
        notes.axis = .vertical
        notes.spacing = 6
        limited.numberOfLines = 0
        notes.addArrangedSubview(limited)
        preview.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setPreview(!self.previews)
        }, for: .primaryActionTriggered)
        let reset = OptionControls.button("Reset") { [weak self] in self?.reset() }
        let rowViews = previewRow(preview: preview, reset: reset)
        body.addArrangedSubview(content)
        if !rowViews.isEmpty { body.addArrangedSubview(OptionControls.row(rowViews, spacing: 18)) }
        body.addArrangedSubview(notes)
        body.axis = .vertical
        body.spacing = 14
        body.setCustomSpacing(18, after: content)
        scroll.addSubview(body)

        let cancel = OptionControls.button("Cancel") { [weak self] in self?.cancel() }
        ok.addAction(UIAction { [weak self] _ in self?.commit() }, for: .primaryActionTriggered)
        spinner.hidesWhenStopped = true
        let feet: [UIView] = foot == .panel ? [cancel, UIView(), spinner, activityLabel, ok] : [UIView(), spinner, activityLabel, cancel, ok]
        for view in feet { footer.addArrangedSubview(view) }
        let line = UIView()
        line.backgroundColor = .separator
        line.isHidden = foot == .effect
        heading.addArrangedSubview(titleLabel)
        heading.addArrangedSubview(UIView())
        if let accessory = headingAccessory() { heading.addArrangedSubview(accessory) }

        for view in [heading, scroll, line, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        let guide = view.safeAreaLayoutGuide
        // As tall as the controls when there's room; less, scrolling, when there isn't: below the controls' own resistance
        // to being squashed, so they scroll rather than shrink.
        let fits = scroll.heightAnchor.constraint(equalTo: body.heightAnchor)
        fits.priority = .defaultLow
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: guide.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            fits,
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            body.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            body.widthAnchor.constraint(equalToConstant: Self.width),
            line.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 14),
            line.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            line.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            line.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            footer.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 14),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -18),
        ])
    }

    /// How wide the editor's controls are.
    private static let width: CGFloat = 400

    /// As tall as everything in it, which changes as the edit does: a range's own settings, say; and as the room the
    /// popover keeps for its arrow, which it counts in the editor.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        func height(_ view: UIView) -> CGFloat {
            view.systemLayoutSizeFitting(CGSize(width: Self.width, height: UIView.layoutFittingCompressedSize.height),
                                         withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        }
        let tall = view.safeAreaInsets.top + 18 + height(heading) + 18 + height(body) + 14 + 1 + 14 + height(footer) + 18
            + view.safeAreaInsets.bottom
        let size = CGSize(width: Self.width + 40, height: ceil(tall))
        if preferredContentSize != size { preferredContentSize = size }
    }

    override func updateProperties() {
        super.updateProperties()
        guard isOpen else { return }
        preview.isSelected = previews
        limited.isHidden = !(notesSelection && session.adjustmentOriginal == nil && session.selection != nil)
        let activity = activity
        if activity == nil { spinner.stopAnimating() } else { spinner.startAnimating() }
        activityLabel.text = activity?.text
        activityLabel.isHidden = activity?.text == nil
        view.isUserInteractionEnabled = activity?.holds != true
        ok.isEnabled = canCommit
        refresh()
        followColorPicker()
    }
}

// MARK: Levels

/// An editor's scrolling, which leaves a drag that starts on a curve, a Levels triangle or a band handle to it, rather
/// than taking it to scroll, and holds no touch back first; the editor still scrolls from anywhere else.
private final class EditorScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        delaysContentTouches = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is CurveView || view is LevelsHandlesView || view is BandView ? false : super.touchesShouldCancel(in: view)
    }
}

/// An editor's view, where a touch a little way off a swatch, within the 44 points a finger needs, goes to the swatch,
/// though the swatch's row is shorter than that and UIKit asks no view about a point outside its parents.
private final class EditorView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard !(hit is UIControl) else { return hit }
        return swatch(at: point, in: self, visible: bounds, with: event) ?? hit
    }

    /// The swatch in `view` whose finger-sized area holds `point`, of those at least partly in sight: not hidden, and
    /// not scrolled out of `visible`, the part of the editor the views clipping it show.
    private func swatch(at point: CGPoint, in view: UIView, visible: CGRect, with event: UIEvent?) -> SwatchButton? {
        guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return nil }
        let frame = view.convert(view.bounds, to: self)
        if let swatch = view as? SwatchButton {
            let near = swatch.isEnabled && swatch.point(inside: swatch.convert(point, from: self), with: event)
            return near && frame.intersects(visible) ? swatch : nil
        }
        let shown = view.clipsToBounds ? visible.intersection(frame) : visible
        guard !shown.isNull else { return nil }
        return view.subviews.reversed().lazy.compactMap { self.swatch(at: point, in: $0, visible: shown, with: event) }.first
    }
}

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
    // Reset at the far end of Preview's row; a spinner alone while OK applies; the histogram's note in place of the
    // selection's, as the Mac's Levels has them.
    override func previewRow(preview: UIView, reset: UIView) -> [UIView] { [preview, UIView(), reset] }
    override var notesSelection: Bool { false }
    override var activity: Activity? { edit?.committing == true ? Activity(text: nil, holds: true) : nil }

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
        for view in [channel, histogram, input, inputFields, gradient, output, outputFields, OptionControls.row([auto, UIView()])] as [UIView] {
            content.addArrangedSubview(view)
        }
        notes.addArrangedSubview(note)
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

/// A ramp of colors, left to right: Levels' output, black to white, or Gradient Map's.
final class GradientBar: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var colors: [PaletteColor] = [.black, .white] {
        didSet { (layer as! CAGradientLayer).colors = colors.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) } }
    }
    init(height: CGFloat = 14) {
        super.init(frame: .zero)
        let gradient = layer as! CAGradientLayer
        gradient.colors = colors.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: Hue/Saturation's band

/// Hue/Saturation's color range control, as the Mac's and Photoshop's: the hues as they are, with red in the middle,
/// the selected range's band, the hues as the whole adjustment leaves them, and the band's handles in degrees either
/// side. Master shows the strips alone, keeping the control's height.
final class SpectrumView: UIView {
    let band = BandView()
    private let leading = OptionControls.caption("", color: .secondaryLabel)
    private let trailing = OptionControls.caption("", color: .secondaryLabel)

    var settings = HueSaturationSettings() { didSet { if settings != oldValue { show() } } }

    private func show() {
        band.settings = settings
        let readouts = HueBandControl.readouts(settings.band, inverted: settings.invertRange)
        leading.text = readouts.leading
        trailing.text = readouts.trailing
        let shows: CGFloat = settings.range != .master && !settings.colorize ? 1 : 0
        leading.alpha = shows
        trailing.alpha = shows
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let font = UIFont.monospacedDigitSystemFont(ofSize: HueBandMetrics.pad.readoutFontSize, weight: .regular)
        for label in [leading, trailing] {
            label.font = font
            label.alpha = 0
            label.isAccessibilityElement = false
        }
        let readouts = OptionControls.row([leading, UIView(), trailing])
        // Master keeps the row, its readouts hidden, so the control keeps its height.
        readouts.heightAnchor.constraint(equalToConstant: ceil(font.lineHeight)).isActive = true
        let stack = UIStackView(arrangedSubviews: [readouts, band])
        stack.axis = .vertical
        // The band's touch area reaches above its strips, into the gap under the readouts.
        stack.spacing = HueBandMetrics.pad.readoutGap - HueBandMetrics.pad.touchOutset
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        show()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The strips and the band, drawn and hit-tested by the shared `HueBandControl`, so they look and work as the Mac's.
/// A press takes a part of the band, a handle keeping where it was taken; with ⌘ held a drag scrolls the strips.
final class BandView: UIView {
    var settings = HueSaturationSettings() { didSet { if settings != oldValue { setNeedsDisplay() } } }
    /// The band as a drag leaves it.
    var onChange: (HueBand) -> Void = { _ in }
    /// The hue in the middle of the strips: red, until ⌘-drag scrolls them; red again whenever the editor opens.
    private(set) var offset = 0.0 { didSet { if offset != oldValue { setNeedsDisplay() } } }
    private var drag: HueBandDrag? { didSet { if drag?.activeHandles != oldValue?.activeHandles { setNeedsDisplay() } } }
    private let metrics = HueBandMetrics.pad
    /// Where the strips start: the touch area reaches past them above and below, to the 44 points a finger needs.
    var drawingOrigin: CGPoint { CGPoint(x: 0, y: metrics.touchOutset) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        heightAnchor.constraint(equalToConstant: metrics.height + metrics.touchOutset * 2).isActive = true
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        // Light or dark, and the screen's scale, which the handles keep to.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: BandView, _) in view.setNeedsDisplay() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var control: HueBandControl { HueBandControl(width: bounds.width, offset: offset, metrics: metrics) }
    private var showsBand: Bool { settings.range != .master && !settings.colorize }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.translateBy(x: drawingOrigin.x, y: drawingOrigin.y)
        control.draw(settings, dark: traitCollection.userInterfaceStyle == .dark, accent: tintColor.cgColor,
                     active: drag?.activeHandles ?? [], scale: traitCollection.displayScale, in: context)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first { press(at: touch.location(in: self).x, scrolls: event?.modifierFlags.contains(.command) == true) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first { drag(to: touch.location(in: self).x) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release() }

    /// A finger down at `x`, taking a part of the band, or with `scrolls` the strips.
    func press(at x: CGFloat, scrolls: Bool = false) {
        guard bounds.width > 0, showsBand || scrolls else { return }
        let taken = HueBandDrag.begin(at: x, band: settings.band, inverted: settings.invertRange, control: control, scrolls: scrolls)
        drag = taken
        // Beyond the band the nearest handle comes to the press at once.
        if taken.grab != .scroll, taken.band != settings.band { onChange(taken.band) }
    }
    func drag(to x: CGFloat) {
        guard let drag else { return }
        if drag.grab == .scroll {
            offset = drag.offset(at: x)
        } else {
            let band = drag.drag(to: x)
            if band != settings.band { onChange(band) }
        }
    }
    func release() { drag = nil }

    // As one adjustable element: its degrees read aloud, and a swipe moving the whole band, as on the Mac.
    override var accessibilityLabel: String? {
        get { showsBand ? "Color range" : "Hue spectrum" }
        set {}
    }
    override var accessibilityValue: String? {
        get { showsBand ? HueBandControl.spokenReadouts(settings.band) : nil }
        set {}
    }
    override func accessibilityIncrement() { moveBand(by: 5) }
    override func accessibilityDecrement() { moveBand(by: -5) }
    private func moveBand(by degrees: Double) {
        guard showsBand else { return }
        var band = settings.band
        band.move(.range, by: degrees)
        onChange(band)
    }
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
    private let remove = OptionControls.button("Remove point") {}

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
    override var activity: Activity? { edit?.committing == true ? Activity(text: "Applying…", holds: true) : nil }

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
        // The channel's curve back to a line, among the curve's own controls, as on the Mac.
        let reset = OptionControls.button("Reset curve") { [weak self] in self?.reset() }
        for view in [channel, curve, hint, OptionControls.row([point, UIView(), remove]), OptionControls.row([reset, UIView()])] as [UIView] {
            content.addArrangedSubview(view)
        }
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
    private let spectrum = SpectrumView()
    /// The eyedroppers, which set the range from the picture, and the targeted adjustment, which drags on it.
    private lazy var droppers = HueSampleMode.allCases.map { mode in
        Self.samplingButton(mode.symbol, badge: mode.badge, label: mode.rawValue + " color", help: mode.help) { [weak self] in
            guard let session = self?.session else { return }
            session.hueTargeting = false
            session.hueSampleMode = session.hueSampleMode == mode ? nil : mode
        }
    }
    private let droppersEnd: UIView = {
        let line = UIView()
        line.backgroundColor = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }()
    private lazy var targeted = Self.samplingButton("hand.point.up.left", badge: nil, label: "Targeted adjustment",
                                                    help: "Targeted adjustment: drag on the image to change that color's saturation, or its hue with Command held") {
        [weak self] in
        guard let session = self?.session else { return }
        session.hueSampleMode = nil
        session.hueTargeting.toggle()
    }
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
    /// Colorize first in Preview's row, as on the Mac.
    override func previewRow(preview: UIView, reset: UIView) -> [UIView] { [colorize, preview, reset, UIView()] }
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
        spectrum.band.onChange = { [weak self] band in self?.update { $0.band = band } }
        droppersEnd.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let rangeRow = OptionControls.row([range, UIView()] + droppers + [droppersEnd, targeted], spacing: 6)
        for view in [rangeRow, sliders, spectrum, OptionControls.row([invert, UIView()])] as [UIView] {
            content.addArrangedSubview(view)
        }
    }

    /// The sliders, made again when colorizing changes their ranges: hue −180 to 180, or 0 to 360 colorizing;
    /// saturation −100 to 100, or 0 to 100. Each has the Mac's colored track, and a double tap on its caption or thumb
    /// puts that one value back.
    private func makeSliders(colorize: Bool) {
        sliders.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func slider(_ caption: String, _ range: ClosedRange<Double>, unit: String? = nil,
                    _ key: WritableKeyPath<HueSaturationSettings, Double>) -> SliderField {
            let field = SliderField(caption: caption, unit: unit, sliderRange: range, fieldRange: range, sensitivity: 1, sliderWidth: nil,
                                    fieldWidth: NumberField.width(toShow: range, decimals: 0))
            field.onChange = { [weak self] value in self?.update { $0[keyPath: key] = value.rounded() } }
            field.onReset = { [weak self] in self?.update { $0[keyPath: key] = $0.resetValues[keyPath: key] } }
            field.toolTip = caption + ". Double-tap to reset."
            // Return in a field applies the adjustment, as on the Mac, where Levels' and Curves' fields keep it.
            field.onReturn = { [weak self] in self?.commit() }
            sliders.addArrangedSubview(field)
            return field
        }
        hue = slider("Hue", colorize ? 0...360 : -180...180, unit: "°", \.hue)
        saturation = slider("Saturation", colorize ? 0...100 : -100...100, \.saturation)
        lightness = slider("Lightness", -100...100, \.lightness)
        // The rows line up in columns, so the thumbs stand one above another at no change.
        SliderField.alignColumns([hue, saturation, lightness].compactMap { $0 })
        slidersColorize = colorize
    }

    /// An eyedropper or the targeted adjustment, as the Mac draws them: a symbol, with Add's and Remove's small badge.
    private static func samplingButton(_ symbol: String, badge: String?, label: String, help: String,
                                       action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15))
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .zero
        configuration.background.cornerRadius = 6
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.toolTip = help
        if let badge {
            let mark = UIImageView(image: UIImage(systemName: badge, withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold)))
            mark.tintColor = .label
            button.addSubview(mark)
            mark.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([mark.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: 9),
                                         mark.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: 8)])
        }
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 34), button.heightAnchor.constraint(equalToConstant: 32)])
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        return button
    }

    /// Shows the button armed, tinted as the Mac's, or not.
    private static func arm(_ button: UIButton, _ armed: Bool) {
        button.configuration?.background.backgroundColor = armed ? UIColor.tintColor.withAlphaComponent(0.25) : .clear
        button.accessibilityTraits = armed ? [.button, .selected] : .button
    }

    override func refresh() {
        let settings = settings
        if slidersColorize != settings.colorize { makeSliders(colorize: settings.colorize) }
        range.show([ColorRange.allCases.map(\.rawValue)], chosen: settings.range.rawValue)
        range.isEnabled = !settings.colorize
        hue?.show(settings.hue)
        saturation?.show(settings.saturation)
        lightness?.show(settings.lightness)
        hue?.track = settings.hueTrack
        saturation?.track = settings.saturationTrack
        lightness?.track = HueSaturationSettings.lightnessTrack
        invert.superview?.isHidden = settings.range == .master || settings.colorize
        // The color range control, its strips in Master too, as the Mac's and Photoshop's; the eyedroppers only for a
        // color range, which they set.
        spectrum.isHidden = settings.colorize
        spectrum.settings = settings
        let editsRange = settings.range != .master && !settings.colorize
        for (mode, dropper) in zip(HueSampleMode.allCases, droppers) {
            dropper.isHidden = !editsRange
            Self.arm(dropper, session.hueSampleMode == mode)
        }
        droppersEnd.isHidden = !editsRange
        targeted.isHidden = settings.colorize
        Self.arm(targeted, session.hueTargeting)
        invert.isSelected = settings.invertRange
        colorize.isSelected = settings.colorize
    }
}
