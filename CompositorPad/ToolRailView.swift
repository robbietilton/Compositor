import UIKit

/// The tools down the left, in the Mac's order, with the foreground and background colors under them. Tools that have
/// no touch interaction yet are shown, and dimmed, so the rail reads as the Mac's does.
final class ToolRailView: UIView, UIColorPickerViewControllerDelegate {
    var session: EditorSession? { didSet { if session !== oldValue { setNeedsUpdateProperties() } } }
    /// Whether a finger paints; the window keeps the choice.
    var fingerPaints = true { didSet { setNeedsUpdateProperties() } }
    var onFingerPaintsChange: (Bool) -> Void = { _ in }
    /// Shows the color picker and the mask's color choice over the window.
    weak var presenter: UIViewController?

    /// What a finger or Apple Pencil can do on the canvas so far.
    static let touchTools: Set<NavigationTool> = [.move, .marquee, .lasso, .wand, .crop, .brush, .blur, .gradient, .shape,
                                                    .eyedropper, .hand, .zoom]

    private let tools = NavigationTool.allCases.filter { $0 != .idle }
    private var buttons: [NavigationTool: UIButton] = [:]
    private let foreground = SwatchButton(), background = SwatchButton()
    private let fingerButton = UIButton(configuration: .plain())
    private var pickingBackground = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.14, alpha: 1)
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 8
        column.alignment = .center
        for tool in tools {
            var configuration = UIButton.Configuration.plain()
            configuration.baseForegroundColor = .label
            configuration.contentInsets = .zero
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = tool.label
            button.toolTip = tool.label
            button.layer.cornerRadius = 9
            button.layer.cornerCurve = .continuous
            button.addAction(UIAction { [weak self] _ in self?.session?.selectTool(tool) }, for: .primaryActionTriggered)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 44), button.heightAnchor.constraint(equalToConstant: 44)])
            buttons[tool] = button
            column.addArrangedSubview(button)
        }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false

        // The two colors overlap as on the Mac, background behind and below; swap and reset beside them.
        let swatches = UIView()
        swatches.translatesAutoresizingMaskIntoConstraints = false
        for (swatch, isBackground) in [(background, true), (foreground, false)] {
            swatch.accessibilityLabel = isBackground ? "Background color" : "Foreground color"
            swatch.addAction(UIAction { [weak self] _ in self?.chooseColor(background: isBackground) }, for: .primaryActionTriggered)
            swatches.addSubview(swatch)
            swatch.translatesAutoresizingMaskIntoConstraints = false
        }
        let swap = Self.smallButton("arrow.left.and.right", label: "Swap colors") { [weak self] in self?.session?.swapPaletteColors() }
        swap.imageView?.transform = CGAffineTransform(rotationAngle: .pi / 4)
        let reset = Self.smallButton("arrow.counterclockwise", label: "Default colors") { [weak self] in self?.session?.resetPaletteColors() }
        for button in [swap, reset] { swatches.addSubview(button); button.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            swatches.widthAnchor.constraint(equalToConstant: 46), swatches.heightAnchor.constraint(equalToConstant: 46),
            foreground.leadingAnchor.constraint(equalTo: swatches.leadingAnchor), foreground.topAnchor.constraint(equalTo: swatches.topAnchor),
            background.leadingAnchor.constraint(equalTo: swatches.leadingAnchor, constant: 16),
            background.topAnchor.constraint(equalTo: swatches.topAnchor, constant: 16),
            swap.leadingAnchor.constraint(equalTo: foreground.trailingAnchor), swap.bottomAnchor.constraint(equalTo: background.topAnchor),
            reset.topAnchor.constraint(equalTo: foreground.bottomAnchor), reset.trailingAnchor.constraint(equalTo: background.leadingAnchor),
        ])
        column.addArrangedSubview(swatches)
        column.setCustomSpacing(18, after: buttons[tools.last!]!)

        var finger = UIButton.Configuration.plain()
        finger.image = UIImage(systemName: "hand.point.up.left")
        fingerButton.configuration = finger
        fingerButton.accessibilityLabel = "Paint with a finger"
        fingerButton.toolTip = "Paint with a finger (once Apple Pencil touches the canvas, fingers move it instead)"
        fingerButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.fingerPaints.toggle()
            self.onFingerPaintsChange(self.fingerPaints)
        }, for: .primaryActionTriggered)

        addSubview(scroll)
        addSubview(fingerButton)
        for view in [scroll, fingerButton] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: fingerButton.topAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            column.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            fingerButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            fingerButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
            fingerButton.widthAnchor.constraint(equalToConstant: 44), fingerButton.heightAnchor.constraint(equalToConstant: 44),
            widthAnchor.constraint(equalToConstant: 60),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateProperties() {
        super.updateProperties()
        guard let session else { return }
        for tool in tools {
            guard let button = buttons[tool] else { continue }
            let selected = session.tool == tool
            button.configuration?.image = UIImage(systemName: Self.symbol(for: tool, in: session),
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 19))
            button.backgroundColor = selected ? UIColor(white: 1, alpha: 0.12) : .clear
            button.layer.borderWidth = selected ? 1 : 0
            button.layer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor
            button.accessibilityTraits = selected ? [.button, .selected] : .button
            let available = Self.touchTools.contains(tool)
            button.isEnabled = available && session.document != nil
            button.alpha = available ? 1 : 0.35
        }
        foreground.color = session.paletteColor(background: false)
        background.color = session.paletteColor(background: true)
        for swatch in [foreground, background] { swatch.isEnabled = session.canEditPalette }
        fingerButton.configuration?.baseForegroundColor = fingerPaints ? .tintColor : .secondaryLabel
        fingerButton.backgroundColor = fingerPaints ? UIColor.tintColor.withAlphaComponent(0.18) : .clear
        fingerButton.layer.cornerRadius = 22
        fingerButton.accessibilityValue = fingerPaints ? "On" : "Off"
    }

    /// The Mac rail's icons: SF Symbols, the Marquee's following its shape and the Brush's its mode.
    static func symbol(for tool: NavigationTool, in session: EditorSession) -> String {
        tool == .marquee && session.marqueeKind == .ellipse ? "circle.dashed" : session.symbol(for: tool)
    }

    // MARK: Colors

    /// Picks the foreground or background color, with the picker pointing at `anchor` (the color's swatch by default).
    func chooseColor(background: Bool, from anchor: UIView? = nil) {
        guard let session, let presenter else { return }
        let source = anchor ?? (background ? self.background : foreground)
        // A mask paints in black or white only; the Mac asks which, as this does.
        if session.isMaskSelected {
            let sheet = UIAlertController(title: background ? "Mask background" : "Mask foreground", message: nil,
                                          preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Black · Hide", style: .default) { _ in session.setPaletteColor(.black, background: background) })
            sheet.addAction(UIAlertAction(title: "White · Reveal", style: .default) { _ in session.setPaletteColor(.white, background: background) })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = source
            presenter.present(sheet, animated: true)
            return
        }
        pickingBackground = background
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        let current = session.paletteColor(background: background)
        picker.selectedColor = UIColor(srgbRed: current.red, green: current.green, blue: current.blue, alpha: 1)
        picker.delegate = self
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = source
        presenter.present(picker, animated: true)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard let sRGB = color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = sRGB.components, c.count >= 3 else { return }
        session?.setPaletteColor(PaletteColor(red: min(1, max(0, c[0])), green: min(1, max(0, c[1])), blue: min(1, max(0, c[2]))),
                                 background: pickingBackground)
    }

    private static func smallButton(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .medium))
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        return button
    }
}

/// A color, as the Mac's swatches draw it: a rounded square with a white inner and a black outer edge.
private final class SwatchButton: UIControl {
    var color = PaletteColor.black {
        didSet { fill.backgroundColor = UIColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1) }
    }
    private let fill = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill.isUserInteractionEnabled = false
        fill.layer.cornerRadius = 7
        fill.layer.cornerCurve = .continuous
        fill.layer.borderWidth = 1.5
        fill.layer.borderColor = UIColor.white.cgColor
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.black.cgColor
        addSubview(fill)
        fill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30), heightAnchor.constraint(equalToConstant: 30),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1), fill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            fill.topAnchor.constraint(equalTo: topAnchor, constant: 1), fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        if let touch, bounds.contains(touch.location(in: self)) { sendActions(for: .primaryActionTriggered) }
    }
}
