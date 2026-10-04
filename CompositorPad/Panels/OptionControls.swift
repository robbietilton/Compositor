import UIKit

/// What the tool options bar and the Layers panel are made of, laid out as the Mac's bars are (a caption, the
/// control, a unit tight against its field) and sized for a finger.
enum OptionControls {
    static let titleFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    static let controlFont = UIFont.systemFont(ofSize: 14)

    static func title(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = titleFont
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    static func caption(_ text: String, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = controlFont
        label.textColor = color
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    /// A setting that is on or off, drawn as the Mac's checkboxes are.
    static func checkbox(_ title: String, action: @escaping (Bool) -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = controlFont
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.changesSelectionAsPrimaryAction = true
        button.configurationUpdateHandler = { button in
            let checked = button.isSelected && button.isEnabled
            button.configuration?.image = UIImage(systemName: button.isSelected ? "checkmark.square.fill" : "square")?
                .withTintColor(checked ? .tintColor : .secondaryLabel, renderingMode: .alwaysOriginal)
            button.configuration?.baseForegroundColor = button.isEnabled ? .label : .tertiaryLabel
        }
        button.addAction(UIAction { [weak button] _ in
            guard let button else { return }
            action(button.isSelected)
        }, for: .primaryActionTriggered)
        return button
    }

    /// A button that does one thing, as the Mac's bordered buttons do.
    static func button(_ title: String? = nil, symbol: String? = nil, label: String? = nil, prominent: Bool = false,
                       action: @escaping () -> Void) -> UIButton {
        var configuration = prominent ? UIButton.Configuration.borderedProminent() : UIButton.Configuration.gray()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = controlFont
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label ?? title
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        return button
    }

    /// Segments for a setting with a few named values, as the Mac's segmented pickers.
    static func segments(_ titles: [String], action: @escaping (Int) -> Void) -> UISegmentedControl {
        let control = UISegmentedControl(items: titles)
        control.setTitleTextAttributes([.font: controlFont], for: .normal)
        control.addAction(UIAction { [weak control] _ in
            guard let control else { return }
            action(control.selectedSegmentIndex)
        }, for: .valueChanged)
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }

    static func row(_ views: [UIView], spacing: CGFloat = 8) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views)
        row.spacing = spacing
        row.alignment = .center
        return row
    }
}

/// A pop-up button over named choices in groups, with a line between groups, as the Mac's pop-up menus.
final class PopUpButton: UIButton {
    private var choices: [[String]] = []
    private var chosen: String?
    var onChoose: (String) -> Void = { _ in }

    init() {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.indicator = .popup
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 8)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = OptionControls.controlFont
            return attributes
        }
        super.init(frame: .zero)
        self.configuration = configuration
        showsMenuAsPrimaryAction = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `chosen` among `choices`, rebuilding the menu only when either changes.
    func show(_ choices: [[String]], chosen: String) {
        guard choices != self.choices || chosen != self.chosen else { return }
        self.choices = choices
        self.chosen = chosen
        configuration?.title = chosen
        menu = UIMenu(children: choices.map { group in
            UIMenu(options: .displayInline, children: group.map { choice in
                UIAction(title: choice, state: choice == chosen ? .on : .off) { [weak self] _ in self?.onChoose(choice) }
            })
        })
    }
}

/// A number typed into a field, or scrubbed by dragging along its caption, as the Mac's scrubbable labels are.
/// The unit sits tight against the field.
final class NumberField: UIView, UITextFieldDelegate {
    /// The value changed: typed (when `live`) or scrubbed.
    var onChange: (Double) -> Void = { _ in }
    /// The field was left, or a scrub let go: the edit is over.
    var onFinish: () -> Void = {}
    /// A scrub began.
    var onScrubStart: () -> Void = {}
    /// Return or Escape ended the typing. A tool's bar hands the keyboard back to the canvas then, as the Mac's do; a
    /// dialog's fields leave Escape to the dialog, whose Cancel it is.
    var onCommit: (() -> Void)?
    /// Return in the field, once the value typed is in: what it confirms past the field, as Hue/Saturation's fields
    /// apply it on the Mac.
    var onReturn: (() -> Void)?
    /// Whether each keystroke that makes a number applies it, as the Transform bar's fields do; otherwise the value
    /// applies when the field is left, as the brush's do.
    var live = false

    let field = UITextField()
    private let caption: UILabel?
    /// What typing or scrubbing can set, and how much a point of scrubbing changes it; a dialog whose units change moves
    /// them.
    var range: ClosedRange<Double>
    var sensitivity: Double
    private let format: (Double) -> String
    private var shown: Double = 0
    /// Whether the text is what's been typed since the field took the keyboard, rather than the value shown: only that
    /// goes in when the field is left.
    private var drafted = false
    private var scrubStart: Double?

    init(caption: String?, unit: String? = nil, width: CGFloat, range: ClosedRange<Double>, sensitivity: Double = 1,
         format: @escaping (Double) -> String = NumberField.whole) {
        self.caption = caption.map { OptionControls.caption($0, color: .secondaryLabel) }
        self.range = range
        self.sensitivity = sensitivity
        self.format = format
        super.init(frame: .zero)
        field.font = Self.font
        field.textAlignment = .right
        // A quiet well, as the Mac's rounded fields read against its dark bars.
        field.borderStyle = .none
        field.backgroundColor = UIColor(white: 1, alpha: 0.08)
        field.layer.cornerRadius = 7
        field.layer.cornerCurve = .continuous
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        field.rightViewMode = .always
        field.heightAnchor.constraint(equalToConstant: 34).isActive = true
        field.keyboardType = .numbersAndPunctuation
        field.returnKeyType = .done
        field.delegate = self
        field.accessibilityLabel = caption ?? unit
        field.addAction(UIAction { [weak self] _ in self?.typed() }, for: .editingChanged)
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        var views: [UIView] = [field]
        if let caption = self.caption {
            caption.isUserInteractionEnabled = true
            caption.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(scrubbed(_:))))
            views.insert(caption, at: 0)
        }
        if let unit { views.append(OptionControls.caption(unit, color: .secondaryLabel)) }
        let row = OptionControls.row(views, spacing: 4)
        if let caption = self.caption { row.setCustomSpacing(6, after: caption) }
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)

    /// How wide a field must be to show any value of `range` with up to `decimals` decimals, as the Mac's filter fields
    /// show them whole: the usual 50 points, or more for long values, such as Exposure's Offset, 0.0125.
    static func width(toShow range: ClosedRange<Double>, decimals: Int) -> CGFloat {
        let whole = max(1, String(Int(max(abs(range.lowerBound), abs(range.upperBound)))).count)
        let widest = (range.lowerBound < 0 ? "-" : "") + String(repeating: "8", count: whole)
            + (decimals > 0 ? "." + String(repeating: "8", count: decimals) : "")
        // The text, the insets either side and a point for the caret.
        return max(50, ceil((widest as NSString).size(withAttributes: [.font: font]).width) + 16 + 1)
    }

    /// Shows `value`. While the field has the keyboard, a value from elsewhere, as the slider beside it or Undo, takes
    /// the place of what's been typed, selected to be typed over, as when the field was tapped; the value that typing
    /// itself applied leaves the typing as it is, as "1." on the way to 1.5.
    func show(_ value: Double) {
        shown = value
        guard field.isEditing else {
            field.text = format(value)
            return
        }
        if drafted, let typed = parsed, abs(typed - value) <= 1e-9 * max(1, abs(value)) { return }
        drafted = false
        guard field.text != format(value) else { return }
        field.text = format(value)
        field.selectAll(nil)
    }

    var isEnabled: Bool {
        get { field.isEnabled }
        set {
            field.isEnabled = newValue
            caption?.isUserInteractionEnabled = newValue
            caption?.textColor = newValue ? .secondaryLabel : .tertiaryLabel
        }
    }

    /// Gives the caption `width`, so the fields of a form line up under one another.
    func alignCaption(width: CGFloat) {
        guard let caption else { return }
        caption.setContentHuggingPriority(.defaultLow, for: .horizontal)
        caption.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func typed() {
        drafted = true
        guard live, let value = parsed else { return }
        onChange(value)
    }

    private var parsed: Double? {
        let text = (field.text ?? "").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(text), value.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    /// A tap selects the whole value, so a new one is typed over it; not once the field is left, which selecting would
    /// take the keyboard back to.
    func textFieldDidBeginEditing(_ textField: UITextField) {
        drafted = false
        DispatchQueue.main.async { if textField.isFirstResponder { textField.selectAll(nil) } }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        onCommit?()
        onReturn?()
        return true
    }

    /// How far Up and Down step the value while the field has the keyboard, Shift ten times as far, as the Mac's effect
    /// fields step; nil for the field's own arrows.
    var arrowStep: Double?

    override var keyCommands: [UIKeyCommand]? {
        guard field.isFirstResponder else { return super.keyCommands }
        var commands: [UIKeyCommand] = []
        if onCommit != nil { commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))) }
        if arrowStep != nil {
            for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow] {
                for flags in [UIKeyModifierFlags(), .shift] {
                    commands.append(UIKeyCommand(input: input, modifierFlags: flags, action: #selector(arrowPressed(_:))))
                }
            }
        }
        // Before the field's own Escape and arrows.
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands.isEmpty ? super.keyCommands : commands
    }

    @objc private func arrowPressed(_ command: UIKeyCommand) {
        guard let step = arrowStep else { return }
        let steps = (command.input == UIKeyCommand.inputUpArrow ? 1.0 : -1.0) * (command.modifierFlags.contains(.shift) ? 10 : 1)
        let value = min(range.upperBound, max(range.lowerBound, (parsed ?? shown) + steps * step))
        onChange(value)
        drafted = false
        show(value)
    }

    @objc private func escapePressed() {
        field.resignFirstResponder()
        onCommit?()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        // Only what was typed goes in: the text otherwise shows a value, perhaps one since moved by the slider.
        if drafted, !live, let value = parsed { onChange(value) }
        drafted = false
        onFinish()
        field.text = format(shown)
    }

    @objc private func scrubbed(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            scrubStart = shown
            onScrubStart()
        case .changed:
            guard let start = scrubStart else { return }
            let value = min(range.upperBound, max(range.lowerBound, start + Double(gesture.translation(in: self).x) * sensitivity))
            onChange(value)
            show(value)
        default:
            guard scrubStart != nil else { return }
            scrubStart = nil
            onFinish()
        }
    }

    /// No decimals.
    nonisolated static func whole(_ value: Double) -> String { String(Int(value.rounded())) }
    /// No trailing zeros on a whole number, two decimals otherwise, as the Mac's Transform fields show them.
    nonisolated static func upToTwoDecimals(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.005 ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }
    /// As many decimals as a value needs, up to `decimals`, as the Mac's filter fields show them.
    nonisolated static func upTo(_ decimals: Int) -> (Double) -> String {
        { value in
            var text = String(format: "%.\(decimals)f", value)
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return text == "-0" ? "0" : text
        }
    }
}

/// A caption to scrub, a slider and a field for the same value, as the Mac's brush settings have them.
final class SliderField: UIView, UIGestureRecognizerDelegate {
    var onChange: (Double) -> Void = { _ in }
    /// A double tap on the caption or the thumb, which puts the value back, as a double-click does on the Mac's colored
    /// sliders; nil for none.
    var onReset: (() -> Void)?
    /// The slider's colored track, as the Mac's color sliders draw theirs; plain keeps the system's.
    var track: CameraRawSliderTrack = .plain {
        didSet { if track != oldValue { slider.colors = track.colors } }
    }
    /// A drag on the slider or the caption began, or ended.
    var onStart: () -> Void = {}
    var onFinish: () -> Void = {}
    /// Return or Escape ended typing in the field.
    var onCommit: (() -> Void)? {
        get { number.onCommit }
        set { number.onCommit = newValue }
    }
    /// Return in the field, once the value typed is in.
    var onReturn: (() -> Void)? {
        get { number.onReturn }
        set { number.onReturn = newValue }
    }

    private let slider = GradientSlider()
    private let label: UILabel
    private let number: NumberField
    /// The slider's range in the value's own units; the field and the caption may reach past it (see Radius).
    private let sliderRange: ClosedRange<Double>
    /// Whether the slider gives the small values most of its travel, as the Mac's logarithmic sliders do.
    private let logarithmic: Bool
    /// How many decimals the slider sets values to, as the Mac's filter rows round them; nil for any.
    private let decimals: Int?
    private let fieldRange: ClosedRange<Double>
    /// What the field shows for a value: percentages show 0...1 as 0...100.
    private let fieldScale: Double
    /// Value per point of a drag along the caption.
    private let sensitivity: Double
    private var value: Double = 0
    private var scrubStart: Double?

    /// `sliderWidth` fixes the slider's width, as in the tool options bar; without it the slider takes the room there
    /// is, as in the Layers panel.
    /// `decimals` shows the field with as many decimals as a value needs, up to that many, in place of `format`.
    /// `fieldWidth` is the field's; an editor's rows make it as wide as their values need (`NumberField.width`).
    init(caption: String, unit: String? = nil, sliderRange: ClosedRange<Double>, fieldRange: ClosedRange<Double>,
         fieldScale: Double = 1, sensitivity: Double, logarithmic: Bool = false, decimals: Int? = nil, sliderWidth: CGFloat? = 110,
         fieldWidth: CGFloat = 50, format: @escaping (Double) -> String = NumberField.whole) {
        self.sliderRange = sliderRange
        self.fieldRange = fieldRange
        self.fieldScale = fieldScale
        self.sensitivity = sensitivity
        self.logarithmic = logarithmic
        self.decimals = decimals
        number = NumberField(caption: nil, unit: unit, width: fieldWidth,
                             range: fieldRange.lowerBound * fieldScale...fieldRange.upperBound * fieldScale,
                             format: decimals.map(NumberField.upTo) ?? format)
        label = OptionControls.caption(caption, color: .secondaryLabel)
        super.init(frame: .zero)
        label.isUserInteractionEnabled = true
        label.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(scrubbed(_:))))
        for view in [label, slider] as [UIView] {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            view.addGestureRecognizer(doubleTap)
        }
        slider.minimumValue = Float(sliderPosition(sliderRange.lowerBound))
        slider.maximumValue = Float(sliderPosition(sliderRange.upperBound))
        slider.accessibilityLabel = caption
        if let sliderWidth { slider.widthAnchor.constraint(equalToConstant: sliderWidth).isActive = true }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onChange(self.sliderValue(Double(self.slider.value)))
        }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in self?.onStart() }, for: .touchDown)
        slider.addAction(UIAction { [weak self] _ in self?.onFinish() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        number.onChange = { [weak self] in
            guard let self else { return }
            self.onChange($0 / self.fieldScale)
        }
        let row = OptionControls.row([label, slider, number], spacing: 8)
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ value: Double) {
        self.value = value
        if !slider.isTracking { slider.value = Float(sliderPosition(min(sliderRange.upperBound, max(sliderRange.lowerBound, value)))) }
        number.show(value * fieldScale)
    }

    /// Where the slider stands for `value`.
    private func sliderPosition(_ value: Double) -> Double { logarithmic ? log(value) : value }
    /// The value the slider sets standing at `position`, to the row's decimals.
    private func sliderValue(_ position: Double) -> Double {
        let value = logarithmic ? exp(position) : position
        guard let decimals else { return value }
        let step = pow(10, Double(decimals))
        return (value * step).rounded() / step
    }

    /// Gives every row's caption, and `labels` beside them, the widest one's width, so their sliders start and end in
    /// the same place, as the Mac's filter panel lines them up.
    static func alignCaptions(_ rows: [SliderField], with labels: [UILabel] = []) {
        let all = rows.map(\.label) + labels
        let width = all.map { ceil($0.intrinsicContentSize.width) }.max() ?? 0
        for label in all {
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set { slider.isEnabled = newValue; number.isEnabled = newValue }
    }

    /// How far Up and Down step the field's value while it has the keyboard, as the Mac's effect fields step.
    var arrowStep: Double? {
        get { number.arrowStep }
        set { number.arrowStep = newValue }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) { resets(at: gesture.location(in: self)) }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let tap = gesture as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2 else { return super.gestureRecognizerShouldBegin(gesture) }
        return onReset != nil && isEnabled && (gesture.view === label || onThumb(gesture.location(in: self)))
    }

    /// Puts the value back, as a double tap at `point` on the caption or the thumb does; whether it did.
    @discardableResult func resets(at point: CGPoint) -> Bool {
        guard let onReset, isEnabled, label.convert(label.bounds, to: self).contains(point) || onThumb(point) else { return false }
        onReset()
        return true
    }

    /// Whether `point` is on the slider's thumb, or a little way off it, as a finger lands.
    private func onThumb(_ point: CGPoint) -> Bool {
        let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: slider.trackRect(forBounds: slider.bounds), value: slider.value)
        return slider.convert(thumb, to: self).insetBy(dx: -8, dy: -8).contains(point)
    }

    /// What the row does, shown by the slider when the pointer rests on it, as the Mac's help.
    var toolTip: String? {
        get { slider.toolTip }
        set { slider.toolTip = newValue }
    }

    @objc private func scrubbed(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard isEnabled else { return }
            scrubStart = value
            onStart()
        case .changed:
            guard let start = scrubStart else { return }
            onChange(scrubbed(from: start, by: gesture.translation(in: self).x))
        default:
            guard scrubStart != nil else { return }
            scrubStart = nil
            onFinish()
        }
    }

    /// The value a drag of `distance` points along the caption makes of `start`: evenly, at the row's sensitivity,
    /// though the slider be logarithmic, as on the Mac.
    func scrubbed(from start: Double, by distance: CGFloat) -> Double {
        min(fieldRange.upperBound, max(fieldRange.lowerBound, start + Double(distance) * sensitivity))
    }
}

/// A slider whose track can be a gradient of colors, drawn across the whole track in place of the system's, as the
/// Mac's colored sliders draw theirs.
final class GradientSlider: UISlider {
    /// The track, a view so it changes at once, as the Mac's redraws, where a lone layer would ease to its new colors
    /// and place behind a drag.
    private let track = Track()
    /// The track's colors, left to right; nil for the system's track.
    var colors: [PaletteColor]? {
        didSet {
            let clear = colors == nil ? nil : UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
            setMinimumTrackImage(clear, for: .normal)
            setMaximumTrackImage(clear, for: .normal)
            track.gradient.colors = colors?.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
            track.isHidden = colors == nil
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.gradient.startPoint = CGPoint(x: 0, y: 0.5)
        track.gradient.endPoint = CGPoint(x: 1, y: 0.5)
        track.isHidden = true
        track.isUserInteractionEnabled = false
        insertSubview(track, at: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = trackRect(forBounds: bounds)
        let height = max(rect.height, 6)
        track.frame = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        track.layer.cornerRadius = height / 2
        sendSubviewToBack(track)
    }

    private final class Track: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        var gradient: CAGradientLayer { layer as! CAGradientLayer }
    }
}

/// A color, as the Mac's swatches draw it: a rounded rectangle with a white inner and a black outer edge. The rail's are
/// 30 points square; a filter's, 24; an effect's, 36 by 18. A finger can tap one from a little way off.
final class SwatchButton: UIControl {
    var color = PaletteColor.black {
        didSet { fill.backgroundColor = UIColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1) }
    }
    private let fill = UIView()

    init(size: CGSize, cornerRadius: CGFloat, inner: CGFloat = 1.5) {
        super.init(frame: .zero)
        fill.isUserInteractionEnabled = false
        fill.layer.cornerRadius = cornerRadius - 1
        fill.layer.cornerCurve = .continuous
        fill.layer.borderWidth = inner
        fill.layer.borderColor = UIColor.white.cgColor
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.black.cgColor
        addSubview(fill)
        fill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width), heightAnchor.constraint(equalToConstant: size.height),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1), fill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            fill.topAnchor.constraint(equalTo: topAnchor, constant: 1), fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// At least 44 points to a finger, around a smaller swatch.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: min(0, (bounds.width - 44) / 2), dy: min(0, (bounds.height - 44) / 2)).contains(point)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        if let touch, self.point(inside: touch.location(in: self), with: event) { sendActions(for: .primaryActionTriggered) }
    }

    /// `color` as the palette has colors, in sRGB.
    static func paletteColor(_ color: UIColor) -> PaletteColor? {
        guard let sRGB = color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = sRGB.components, c.count >= 3 else { return nil }
        return PaletteColor(red: min(1, max(0, c[0])), green: min(1, max(0, c[1])), blue: min(1, max(0, c[2])))
    }
}
