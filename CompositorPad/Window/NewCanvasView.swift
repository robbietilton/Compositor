import UIKit

/// What an empty tab shows, as the Mac's does: a new canvas's size, typed or picked from the presets, and the other
/// ways in, opening a project or bringing in an image. The projects opened lately are listed under it.
final class NewCanvasView: UIView, UITextFieldDelegate {
    var onCreate: (Int, Int) -> Void = { _, _ in }
    var onOpen: () -> Void = {}
    var onImportPhotos: () -> Void = {}
    var onImportFiles: () -> Void = {}
    var onOpenRecent: (URL) -> Void = { _ in }

    private let width = NewCanvasView.field("1920")
    private let height = NewCanvasView.field("1080")
    private let caption = UILabel()
    private let create = UIButton(configuration: .prominentGlass())
    private let recent = UIStackView()
    private let recentTitle = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let card = Self.card()

        let title = UILabel()
        title.text = "New canvas"
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        var presetsConfiguration = UIButton.Configuration.plain()
        presetsConfiguration.image = UIImage(systemName: "ellipsis")
        presetsConfiguration.baseForegroundColor = .label
        let presets = UIButton(configuration: presetsConfiguration)
        presets.accessibilityLabel = "Preset sizes"
        presets.showsMenuAsPrimaryAction = true
        presets.menu = UIMenu(children: CanvasPreset.groups.map { group in
            UIMenu(options: .displayInline, children: group.map { preset in
                UIAction(title: preset.title, subtitle: "\(preset.width) × \(preset.height) px") { [weak self] _ in
                    self?.width.text = String(preset.width)
                    self?.height.text = String(preset.height)
                    self?.validate()
                }
            })
        })
        let header = UIStackView(arrangedSubviews: [title, UIView(), presets])

        // Between the fields, as tall as they are, so it sits level with them rather than their labels.
        var swapConfiguration = UIButton.Configuration.plain()
        swapConfiguration.image = UIImage(systemName: "arrow.left.arrow.right")
        swapConfiguration.baseForegroundColor = .secondaryLabel
        let swap = UIButton(configuration: swapConfiguration)
        swap.accessibilityLabel = "Swap width and height"
        swap.setHelp("Swap width and height", hint: nil)
        swap.addAction(UIAction { [weak self] _ in self?.swapSize() }, for: .primaryActionTriggered)
        swap.translatesAutoresizingMaskIntoConstraints = false
        swap.widthAnchor.constraint(equalToConstant: 44).isActive = true
        swap.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let size = UIStackView(arrangedSubviews: [Self.labeled("Width", width), swap, Self.labeled("Height", height)])
        size.spacing = 16
        size.alignment = .bottom
        size.distribution = .equalCentering
        for field in [width, height] {
            field.delegate = self
            field.addAction(UIAction { [weak self] _ in self?.validate() }, for: .editingChanged)
        }

        caption.font = .preferredFont(forTextStyle: .callout)
        caption.numberOfLines = 0

        var openConfiguration = UIButton.Configuration.glass()
        openConfiguration.title = "Open project"
        let open = UIButton(configuration: openConfiguration)
        open.addAction(UIAction { [weak self] _ in self?.onOpen() }, for: .primaryActionTriggered)
        var importConfiguration = UIButton.Configuration.glass()
        importConfiguration.title = "Import image"
        let importButton = UIButton(configuration: importConfiguration)
        // From Photos, or from Files, where Photoshop and RAW files usually are.
        importButton.menu = UIMenu(children: [
            UIAction(title: "From Photos", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.onImportPhotos() },
            UIAction(title: "From Files", image: UIImage(systemName: "folder")) { [weak self] _ in self?.onImportFiles() },
        ])
        importButton.showsMenuAsPrimaryAction = true
        create.configuration?.title = "Create canvas"
        create.addAction(UIAction { [weak self] _ in self?.createCanvas() }, for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [open, importButton, UIView(), create])
        buttons.spacing = 10

        recentTitle.text = "Recent"
        recentTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        recentTitle.textColor = .secondaryLabel
        recent.axis = .vertical
        recent.spacing = 2

        let content = UIStackView(arrangedSubviews: [header, size, caption, buttons, recentTitle, recent])
        content.axis = .vertical
        content.spacing = 22
        content.setCustomSpacing(10, after: recentTitle)
        card.addSubview(content)
        addSubview(card)
        for view in [card, content] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 520),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
        ])
        validate()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The card an empty tab's form sits on, and an opening tab's Loading card too.
    static func card() -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor(white: 0.18, alpha: 0.96)
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        return card
    }

    /// Lists up to five recent projects, or hides the list when there are none.
    func showRecent(_ urls: [URL]) {
        recent.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for url in urls.prefix(5) {
            var configuration = UIButton.Configuration.plain()
            configuration.title = url.deletingPathExtension().lastPathComponent
            configuration.subtitle = url.deletingLastPathComponent().lastPathComponent
            configuration.image = UIImage(systemName: "doc.richtext")
            configuration.imagePadding = 10
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
            let button = UIButton(configuration: configuration)
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in self?.onOpenRecent(url) }, for: .primaryActionTriggered)
            recent.addArrangedSubview(button)
        }
        recentTitle.isHidden = urls.isEmpty
        recent.isHidden = urls.isEmpty
    }

    private func validate() {
        let valid = size != nil
        caption.text = valid ? "Transparent canvas · sRGB" : "Enter whole numbers from 1 to \(DocumentLimits.maxSide.formatted()) pixels."
        caption.textColor = valid ? .secondaryLabel : .systemOrange
        create.isEnabled = valid
    }

    private var size: (Int, Int)? {
        guard let w = CanvasDocument.validDimension(width.text ?? ""), let h = CanvasDocument.validDimension(height.text ?? "") else { return nil }
        return (w, h)
    }

    private func swapSize() {
        (width.text, height.text) = (height.text, width.text)
        validate()
    }

    private func createCanvas() {
        endEditing(true)
        guard let size else { return }
        onCreate(size.0, size.1)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === width { height.becomeFirstResponder() } else { createCanvas() }
        return true
    }

    private static func field(_ value: String) -> UITextField {
        let field = UITextField()
        field.text = value
        field.keyboardType = .numberPad
        field.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
        field.borderStyle = .none
        field.backgroundColor = UIColor(white: 1, alpha: 0.07)
        field.layer.cornerRadius = 8
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        // The unit as far in from the well's right edge as the number is from its left, as the Mac's field has it. The
        // field takes a label on its own at the label's width, so it comes in a view that has the margin too.
        let unit = UILabel()
        unit.text = "px"
        unit.textColor = .secondaryLabel
        unit.sizeToFit()
        let trailing = UIView(frame: CGRect(x: 0, y: 0, width: unit.bounds.width + 12, height: unit.bounds.height))
        trailing.addSubview(unit)
        field.rightView = trailing
        field.rightViewMode = .always
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 44).isActive = true
        field.widthAnchor.constraint(equalToConstant: 190).isActive = true
        return field
    }

    private static func labeled(_ title: String, _ field: UITextField) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 15, weight: .medium)
        field.accessibilityLabel = title
        let stack = UIStackView(arrangedSubviews: [label, field])
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }
}
