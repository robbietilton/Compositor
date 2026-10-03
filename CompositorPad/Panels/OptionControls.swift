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
    private var scrubStart: Double?

    init(caption: String?, unit: String? = nil, width: CGFloat, range: ClosedRange<Double>, sensitivity: Double = 1,
         format: @escaping (Double) -> String = NumberField.whole) {
        self.caption = caption.map { OptionControls.caption($0, color: .secondaryLabel) }
        self.range = range
        self.sensitivity = sensitivity
        self.format = format
        super.init(frame: .zero)
        field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
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

    /// Shows `value`, unless it's being typed over.
    func show(_ value: Double) {
        shown = value
        if !field.isEditing { field.text = format(value) }
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
        DispatchQueue.main.async { if textField.isFirstResponder { textField.selectAll(nil) } }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        onCommit?()
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
        guard onCommit != nil, field.isFirstResponder else { return super.keyCommands }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    @objc private func escapePressed() {
        field.resignFirstResponder()
        onCommit?()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if !live, let value = parsed { onChange(value) }
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
}

/// A caption to scrub, a slider and a field for the same value, as the Mac's brush settings have them.
final class SliderField: UIView {
    var onChange: (Double) -> Void = { _ in }
    /// A drag on the slider or the caption began, or ended.
    var onStart: () -> Void = {}
    var onFinish: () -> Void = {}
    /// Return or Escape ended typing in the field.
    var onCommit: (() -> Void)? {
        get { number.onCommit }
        set { number.onCommit = newValue }
    }

    private let slider = UISlider()
    private let number: NumberField
    /// The slider's range in the value's own units; the field and the caption may reach past it (see Radius).
    private let sliderRange: ClosedRange<Double>
    private let fieldRange: ClosedRange<Double>
    /// What the field shows for a value: percentages show 0...1 as 0...100.
    private let fieldScale: Double
    /// Value per point of a drag along the caption.
    private let sensitivity: Double
    private var value: Double = 0
    private var scrubStart: Double?

    /// `sliderWidth` fixes the slider's width, as in the tool options bar; without it the slider takes the room there
    /// is, as in the Layers panel.
    init(caption: String, unit: String? = nil, sliderRange: ClosedRange<Double>, fieldRange: ClosedRange<Double>,
         fieldScale: Double = 1, sensitivity: Double, sliderWidth: CGFloat? = 110,
         format: @escaping (Double) -> String = NumberField.whole) {
        self.sliderRange = sliderRange
        self.fieldRange = fieldRange
        self.fieldScale = fieldScale
        self.sensitivity = sensitivity
        number = NumberField(caption: nil, unit: unit, width: 50,
                             range: fieldRange.lowerBound * fieldScale...fieldRange.upperBound * fieldScale, format: format)
        super.init(frame: .zero)
        let label = OptionControls.caption(caption, color: .secondaryLabel)
        label.isUserInteractionEnabled = true
        label.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(scrubbed(_:))))
        slider.minimumValue = Float(sliderRange.lowerBound)
        slider.maximumValue = Float(sliderRange.upperBound)
        slider.accessibilityLabel = caption
        if let sliderWidth { slider.widthAnchor.constraint(equalToConstant: sliderWidth).isActive = true }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onChange(Double(self.slider.value))
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
        if !slider.isTracking { slider.value = Float(min(sliderRange.upperBound, max(sliderRange.lowerBound, value))) }
        number.show(value * fieldScale)
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set { slider.isEnabled = newValue; number.isEnabled = newValue }
    }

    @objc private func scrubbed(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard isEnabled else { return }
            scrubStart = value
            onStart()
        case .changed:
            guard let start = scrubStart else { return }
            let next = min(fieldRange.upperBound, max(fieldRange.lowerBound, start + Double(gesture.translation(in: self).x) * sensitivity))
            onChange(next)
        default:
            guard scrubStart != nil else { return }
            scrubStart = nil
            onFinish()
        }
    }
}
