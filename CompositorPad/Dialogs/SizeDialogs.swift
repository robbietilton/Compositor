import UIKit

/// What Canvas Size and Image Size share, as the Mac's sheets have it: a title, the dialog's own fields, then Cancel and
/// the button that applies them. Return applies and Escape cancels, as the sheets' buttons do on the Mac.
class SizeDialogController: UIViewController {
    let content = UIStackView()
    let confirmButton: UIButton
    private let stack = UIStackView()
    private let heading: String

    init(title: String, confirm: String) {
        heading = title
        confirmButton = OptionControls.button(confirm, prominent: true) {}
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        isModalInPresentation = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Applies what the fields are set to, when they add up.
    func confirm() {}
    func cancel() {}
    /// Puts the draft's values into the fields.
    func refresh() {}

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = heading
        title.font = .systemFont(ofSize: 22, weight: .bold)
        content.axis = .vertical
        content.spacing = 14
        content.alignment = .leading
        let cancel = OptionControls.button("Cancel") { [weak self] in self?.cancel() }
        confirmButton.addAction(UIAction { [weak self] _ in self?.confirm() }, for: .primaryActionTriggered)
        let footer = OptionControls.row([cancel, UIView(), confirmButton])
        for view in [title, content, footer] { stack.addArrangedSubview(view) }
        stack.axis = .vertical
        stack.spacing = 18
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.widthAnchor.constraint(equalToConstant: 440),
        ])
        refresh()
    }

    /// As tall as the fields, which change as the dialog does: Custom's color, say.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: 440, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let size = CGSize(width: 488, height: ceil(fitting.height) + 48 + view.safeAreaInsets.top + view.safeAreaInsets.bottom)
        if preferredContentSize != size { preferredContentSize = size }
    }

    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnKey(_:))),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey(_:)))]
    }
    @objc private func returnKey(_ command: UIKeyCommand) { confirm() }
    @objc private func escapeKey(_ command: UIKeyCommand) { cancel() }

    /// How wide the fields' captions are, so the fields line up.
    static let captionWidth: CGFloat = 84

    /// A field for the width or height, typed or scrubbed along its caption.
    static func dimensionField(_ caption: String, onChange: @escaping (Double) -> Void) -> NumberField {
        let field = NumberField(caption: caption, width: 120, range: 1...30_000, format: decimals)
        field.live = true
        field.onChange = onChange
        field.alignCaption(width: captionWidth)
        return field
    }

    /// Up to three decimals, none on a whole number, as the Mac's sheets show sizes.
    nonisolated static func decimals(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// A line of the dialog's own text: secondary, or orange for a size that can't be used.
    static func note(_ text: String = "") -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }
}

// MARK: Canvas Size

/// Image › Canvas Size…, as the Mac's sheet: a new size for the canvas, in pixels, percent or print units, absolute or
/// relative to the current one, around a point that stays fixed, with a color for the room added. The artwork isn't
/// scaled.
final class CanvasSizeController: SizeDialogController {
    static let anchorNames = ["Top left", "Top center", "Top right", "Middle left", "Center", "Middle right",
                              "Bottom left", "Bottom center", "Bottom right"]
    static let extensions = ["Transparent", "Foreground", "Background", "Black", "White", "Custom"]

    private(set) var draft: CanvasSizeDraft
    private(set) var anchor = 4
    private(set) var extensionChoice = "Transparent"
    private(set) var customColor = PaletteColor.white
    private let foreground: PaletteColor
    private let background: PaletteColor
    private let finish: (CanvasSizeOptions?) -> Void

    private let units = PopUpButton()
    private lazy var width = Self.dimensionField("Width") { [weak self] in self?.setDimension($0, widthAxis: true) }
    private lazy var height = Self.dimensionField("Height") { [weak self] in self?.setDimension($0, widthAxis: false) }
    private lazy var relative = OptionControls.checkbox("Relative to current dimensions") { [weak self] in self?.setRelative($0) }
    private lazy var locked = OptionControls.checkbox("Lock original aspect ratio") { [weak self] in self?.setLocked($0) }
    private let newSize = SizeDialogController.note()
    private var anchorButtons: [UIButton] = []
    private let anchorName = OptionControls.caption("")
    private let extensionPicker = PopUpButton()
    private let customWell = UIColorWell()
    private var customRow: UIView?

    init(document: CanvasDocument, session: EditorSession, finish: @escaping (CanvasSizeOptions?) -> Void) {
        draft = CanvasSizeDraft(width: document.width, height: document.height, resolution: document.resolution)
        foreground = session.foregroundColor
        background = session.backgroundColor
        self.finish = finish
        super.init(title: "Canvas Size", confirm: "OK")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// What fills the room added: nothing when transparent, otherwise the color chosen.
    var fill: CanvasExtensionColor? {
        let color: PaletteColor
        switch extensionChoice {
        case "Transparent": return nil
        case "Foreground": color = foreground
        case "Background": color = background
        case "Black": color = .black
        case "White": color = .white
        default: color = customColor
        }
        return CanvasExtensionColor(red: color.red, green: color.green, blue: color.blue)
    }

    override func viewDidLoad() {
        let current = SizeDialogController.note("Current: \(draft.originalWidth) × \(draft.originalHeight) pixels")
        current.textColor = .label
        current.font = .preferredFont(forTextStyle: .body)
        let memory = SizeDialogController.note("\(CanvasSizeDraft.memory(width: draft.originalWidth, height: draft.originalHeight)) uncompressed RGBA canvas")
        units.accessibilityLabel = "Units"
        units.onChoose = { [weak self] in self?.chooseUnit(CanvasUnit(rawValue: $0) ?? .pixels) }

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 4
        for row in 0..<3 {
            let line = UIStackView()
            line.spacing = 4
            for column in 0..<3 {
                let index = row * 3 + column
                var configuration = UIButton.Configuration.plain()
                configuration.contentInsets = .zero
                let button = UIButton(configuration: configuration)
                button.accessibilityLabel = Self.anchorNames[index]
                button.widthAnchor.constraint(equalToConstant: 44).isActive = true
                button.heightAnchor.constraint(equalToConstant: 44).isActive = true
                button.addAction(UIAction { [weak self] _ in self?.chooseAnchor(index) }, for: .primaryActionTriggered)
                anchorButtons.append(button)
                line.addArrangedSubview(button)
            }
            grid.addArrangedSubview(line)
        }
        anchorName.font = .systemFont(ofSize: 14, weight: .semibold)
        let anchorNote = SizeDialogController.note("Keeps this point fixed. Artwork is not scaled; cropped content remains outside the canvas.")
        let anchorText = UIStackView(arrangedSubviews: [anchorName, anchorNote])
        anchorText.axis = .vertical
        anchorText.spacing = 6
        let anchorRow = UIStackView(arrangedSubviews: [grid, anchorText])
        anchorRow.spacing = 20
        anchorRow.alignment = .center

        extensionPicker.accessibilityLabel = "Canvas extension"
        extensionPicker.onChoose = { [weak self] in self?.chooseExtension($0) }
        customWell.title = "Extension Color"
        customWell.supportsAlpha = false
        customWell.selectedColor = UIColor(srgbRed: customColor.red, green: customColor.green, blue: customColor.blue, alpha: 1)
        customWell.addAction(UIAction { [weak self] _ in
            guard let self, let color = self.customWell.selectedColor else { return }
            self.chooseCustomColor(color)
        }, for: .valueChanged)
        let customRow = OptionControls.row([OptionControls.caption("Extension color", color: .secondaryLabel), customWell])
        self.customRow = customRow

        for view in [current, memory, OptionControls.row([OptionControls.caption("Units", color: .secondaryLabel), units]),
                     width, height, relative, locked, newSize,
                     OptionControls.caption("Anchor", color: .secondaryLabel), anchorRow,
                     OptionControls.row([OptionControls.caption("Canvas extension", color: .secondaryLabel), extensionPicker]),
                     customRow] as [UIView] {
            content.addArrangedSubview(view)
        }
        content.setCustomSpacing(4, after: current)
        anchorRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        newSize.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        super.viewDidLoad()
    }

    override func refresh() {
        units.show([CanvasUnit.allCases.map(\.rawValue)], chosen: draft.unit.rawValue)
        for (field, widthAxis) in [(width, true), (height, false)] {
            field.range = draft.scrubRange(widthAxis: widthAxis)
            field.sensitivity = draft.scrubSensitivity(widthAxis: widthAxis)
            field.show(draft.displayed(widthAxis: widthAxis))
        }
        relative.isSelected = draft.relative
        locked.isSelected = draft.locked
        if draft.valid {
            let width = Int(draft.width.rounded()), height = Int(draft.height.rounded())
            newSize.text = "New: \(width) × \(height) pixels · \(CanvasSizeDraft.memory(width: width, height: height)) uncompressed"
            newSize.textColor = .secondaryLabel
        } else {
            newSize.text = "Final dimensions must be 1–\(DocumentLimits.maxSide.formatted()) pixels per side."
            newSize.textColor = .systemOrange
        }
        for (index, button) in anchorButtons.enumerated() {
            let chosen = index == anchor
            button.configuration?.image = UIImage(systemName: chosen ? "circle.fill" : "circle")
            button.configuration?.baseForegroundColor = chosen ? .tintColor : .secondaryLabel
            button.accessibilityValue = chosen ? "Selected" : nil
        }
        anchorName.text = Self.anchorNames[anchor]
        extensionPicker.show([Self.extensions], chosen: extensionChoice)
        customRow?.isHidden = extensionChoice != "Custom"
        confirmButton.isEnabled = draft.valid
    }

    func setDimension(_ value: Double, widthAxis: Bool) {
        draft.set(value, widthAxis: widthAxis)
        refresh()
    }
    func chooseUnit(_ unit: CanvasUnit) {
        draft.unit = unit
        refresh()
    }
    func setRelative(_ on: Bool) {
        draft.relative = on
        refresh()
    }
    /// Locking keeps the width and works the height out from it, as the Mac's sheet does.
    func setLocked(_ on: Bool) {
        draft.locked = on
        if on { draft.set(draft.displayed(widthAxis: true), widthAxis: true) }
        refresh()
    }
    func chooseAnchor(_ index: Int) {
        anchor = index
        refresh()
    }
    func chooseExtension(_ choice: String) {
        extensionChoice = choice
        refresh()
        view.setNeedsLayout()
    }
    func chooseCustomColor(_ color: UIColor) {
        guard let sRGB = color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = sRGB.components, c.count >= 3 else { return }
        customColor = PaletteColor(red: min(1, max(0, c[0])), green: min(1, max(0, c[1])), blue: min(1, max(0, c[2])))
    }

    override func confirm() {
        guard draft.valid else { return }
        finish(CanvasSizeOptions(width: Int(draft.width.rounded()), height: Int(draft.height.rounded()), anchor: anchor, fill: fill))
    }
    override func cancel() { finish(nil) }
}

// MARK: Image Size

/// Image › Image Size…, as the Mac's sheet: a new size for the image, its layers resampled to it, or with Resample off
/// only a new print size and resolution.
final class ImageSizeController: SizeDialogController {
    private(set) var draft: ImageSizeDraft
    private let finish: (ImageSizeOptions?) -> Void

    private let units = PopUpButton()
    private lazy var width = Self.dimensionField("Width") { [weak self] in self?.setDimension($0, widthAxis: true) }
    private lazy var height = Self.dimensionField("Height") { [weak self] in self?.setDimension($0, widthAxis: false) }
    private lazy var locked = OptionControls.checkbox("Lock aspect ratio") { [weak self] in self?.setLocked($0) }
    private lazy var resolution: NumberField = {
        let field = NumberField(caption: "Resolution", unit: "pixels/inch", width: 120, range: 1...9600, format: SizeDialogController.decimals)
        field.live = true
        field.onChange = { [weak self] in self?.setResolution($0) }
        field.alignCaption(width: SizeDialogController.captionWidth)
        return field
    }()
    private lazy var resample = OptionControls.checkbox("Resample") { [weak self] in self?.setResample($0) }
    private let sampling = PopUpButton()
    private var samplingRow: UIView?
    private let samplingNote = SizeDialogController.note()
    private let result = SizeDialogController.note()

    init(document: CanvasDocument, finish: @escaping (ImageSizeOptions?) -> Void) {
        draft = ImageSizeDraft(width: document.width, height: document.height, resolution: document.resolution)
        self.finish = finish
        super.init(title: "Image Size", confirm: "Resize")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        let current = SizeDialogController.note("Current: \(draft.originalWidth) × \(draft.originalHeight) pixels")
        units.accessibilityLabel = "Units"
        units.onChoose = { [weak self] in self?.chooseUnit(CanvasUnit(rawValue: $0) ?? .pixels) }
        sampling.accessibilityLabel = "Sampling"
        sampling.onChoose = { [weak self] in self?.chooseSampling(LayerSampling(rawValue: $0) ?? .high) }
        let samplingRow = OptionControls.row([OptionControls.caption("Sampling", color: .secondaryLabel), sampling])
        self.samplingRow = samplingRow
        for view in [current, OptionControls.row([OptionControls.caption("Units", color: .secondaryLabel), units]),
                     width, height, locked, resolution, resample, samplingRow, samplingNote, result] as [UIView] {
            content.addArrangedSubview(view)
        }
        for label in [samplingNote, result] { label.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        super.viewDidLoad()
    }

    override func refresh() {
        units.show([draft.units.map(\.rawValue)], chosen: draft.unit.rawValue)
        for (field, widthAxis) in [(width, true), (height, false)] {
            field.range = draft.scrubRange(widthAxis: widthAxis)
            field.sensitivity = draft.scrubSensitivity(widthAxis: widthAxis)
            field.show(draft.displayed(widthAxis: widthAxis))
        }
        locked.isSelected = draft.locked
        locked.isEnabled = draft.resample
        resolution.show(draft.resolution)
        resample.isSelected = draft.resample
        sampling.show([LayerSampling.allCases.map(\.rawValue)], chosen: draft.sampling.rawValue)
        samplingRow?.isHidden = !draft.resample
        samplingNote.text = draft.resample ? "Resizes layer pixels and applies existing transforms. Undo restores the originals."
            : "Only print dimensions and resolution change. Pixels stay unchanged."
        if draft.valid {
            result.text = "Result: \(Int(draft.width.rounded())) × \(Int(draft.height.rounded())) pixels"
            result.textColor = .secondaryLabel
        } else {
            result.text = "Use 1–\(DocumentLimits.maxSide.formatted()) pixels per side, up to \(DocumentLimits.maxSurfaceMegapixels) megapixels, and 1–9,600 pixels/inch."
            result.textColor = .systemOrange
        }
        confirmButton.isEnabled = draft.valid
    }

    func setDimension(_ value: Double, widthAxis: Bool) {
        draft.set(value, widthAxis: widthAxis)
        refresh()
    }
    func chooseUnit(_ unit: CanvasUnit) {
        draft.unit = unit
        refresh()
    }
    func setLocked(_ on: Bool) {
        draft.locked = on
        refresh()
    }
    func setResolution(_ value: Double) {
        draft.setResolution(value)
        refresh()
    }
    func setResample(_ on: Bool) {
        draft.setResample(on)
        refresh()
        view.setNeedsLayout()
    }
    func chooseSampling(_ sampling: LayerSampling) {
        draft.sampling = sampling
        refresh()
    }

    override func confirm() {
        guard let options = draft.options else { return }
        finish(options)
    }
    override func cancel() { finish(nil) }
}
