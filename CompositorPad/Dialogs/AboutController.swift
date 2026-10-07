import UIKit

/// The app menu's About, as the Mac's About panel: the app's icon, name and version, read from its bundle so a build of
/// your own shows its own; then where its source is, and the license it's under, whose notice goes with every copy.
/// Done or Escape puts it away.
final class AboutController: UIViewController {
    /// Where the app's source is.
    static let sourceURL = URL(string: "https://github.com/robbietilton/Compositor")!

    /// The app's name, as the Home Screen shows it.
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Compositor"
    }

    /// The version and, in parentheses, the build, as the Mac's About panel says them.
    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "Version \(version) (\(build))"
    }

    /// The license, from the copy of the repository's LICENSE the app carries.
    static var license: String {
        Bundle.main.url(forResource: "LICENSE", withExtension: nil).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// The app's icon, as the Home Screen shows it: the asset catalog's, or else the last of the files the Info.plist
    /// lists, the largest.
    static var icon: UIImage? {
        let info = Bundle.main.infoDictionary
        let icons = (info?["CFBundleIcons~ipad"] ?? info?["CFBundleIcons"]) as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let names = [primary?["CFBundleIconName"] as? String] + ((primary?["CFBundleIconFiles"] as? [String]) ?? []).reversed()
        return names.lazy.compactMap { $0.flatMap { UIImage(named: $0) } }.first
    }

    /// `text` with each paragraph on one line, for the sheet to wrap to its own width: the license's lines are broken
    /// to fit a terminal's.
    static func paragraphs(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n\n")
    }

    /// Opens a link, in the browser. Tests catch what it's handed instead.
    var open: (URL) -> Void = { UIApplication.shared.open($0) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })

        let icon = UIImageView(image: Self.icon)
        icon.contentMode = .scaleAspectFill
        icon.layer.cornerRadius = 22
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        let name = Self.label(Self.appName, font: UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: 28, weight: .bold)))
        name.accessibilityTraits = .header
        let version = Self.label(Self.version, font: .preferredFont(forTextStyle: .subheadline), color: .secondaryLabel)

        var configuration = UIButton.Configuration.plain()
        configuration.title = "github.com/robbietilton/Compositor"
        configuration.image = UIImage(systemName: "arrow.up.forward")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        let link = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.open(Self.sourceURL) })
        link.titleLabel?.adjustsFontForContentSizeCategory = true
        link.accessibilityLabel = "Source code on GitHub"
        link.accessibilityHint = "Opens the app’s source code in the browser."

        let license = UITextView()
        license.text = Self.paragraphs(Self.license)
        license.font = .preferredFont(forTextStyle: .footnote)
        license.adjustsFontForContentSizeCategory = true
        license.textColor = .secondaryLabel
        license.isEditable = false
        license.backgroundColor = .secondarySystemBackground
        license.layer.cornerRadius = 10
        license.layer.cornerCurve = .continuous
        license.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        license.accessibilityLabel = "License"

        let header = UIStackView(arrangedSubviews: [icon, name, version, link])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 4
        header.setCustomSpacing(16, after: icon)
        let stack = UIStackView(arrangedSubviews: [header, license])
        stack.axis = .vertical
        stack.spacing = 20
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            icon.widthAnchor.constraint(equalToConstant: 96), icon.heightAnchor.constraint(equalToConstant: 96),
            // Room for a few lines of the license, however large the text.
            license.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    private static func label(_ text: String, font: UIFont, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    // Escape puts it away, as Done does: it takes the keyboard while it's up, as the window's dialogs do.
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey(_:)))]
    }
    @objc private func escapeKey(_ command: UIKeyCommand) { dismiss(animated: true) }
}
