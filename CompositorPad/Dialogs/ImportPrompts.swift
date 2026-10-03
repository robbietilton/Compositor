import UIKit

/// What a Photoshop file will lose on the way in, listed before anything is applied, as the Mac's conversion report
/// lists it. The editor waits on the choice (`finishConversion`).
final class PSDConversionController: UITableViewController {
    private let session: EditorSession
    private var request: PSDConversionRequest?

    init(session: EditorSession) {
        self.session = session
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.finish(false)
        })
        isModalInPresentation = true
    }

    override func updateProperties() {
        super.updateProperties()
        // The file is still being read at first: the sheet is up so the tap feels answered, with nothing to list yet.
        guard let request = session.conversionRequest else { return }
        let changed = request != self.request
        self.request = request
        title = request.title
        let confirm = UIBarButtonItem(title: request.confirmTitle, style: .prominent, target: self, action: #selector(confirm))
        confirm.isEnabled = !request.isReading
        navigationItem.rightBarButtonItem = confirm
        if changed { tableView.reloadData() }
    }

    @objc private func confirm() { finish(true) }

    private func finish(_ confirmed: Bool) {
        session.finishConversion(confirmed)
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        request?.isReading == true ? 1 : request?.conversions.count ?? 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if let request, !request.isReading {
            let item = request.conversions[indexPath.row]
            content.text = item.layerName
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryText = item.message
        } else {
            content.text = "Reading the file…"
            content.textProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}

/// A RAW file holds more range than a layer can, so what to keep is chosen here, as on the Mac: the preview develops at
/// screen size while the sliders move, and the import then develops the full frame once (`finishRawDevelop`).
final class RawDevelopController: UIViewController {
    private let session: EditorSession
    private let url: URL
    private var settings: RawDevelopSettings
    private let preview = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var sliders: [(slider: UISlider, value: UILabel, keyPath: WritableKeyPath<RawDevelopSettings, Float>, format: String)] = []
    private let reset = UIButton(configuration: .glass())
    private var developing: Task<Void, Never>?

    init(session: EditorSession, url: URL, settings: RawDevelopSettings) {
        self.session = session
        self.url = url
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Develop “\(url.lastPathComponent)”"
        view.backgroundColor = .systemBackground
        isModalInPresentation = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.finish(nil)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Import", style: .prominent, target: self, action: #selector(importDeveloped))

        preview.contentMode = .scaleAspectFit
        preview.backgroundColor = UIColor(white: 0, alpha: 0.35)
        preview.layer.cornerRadius = 8
        preview.clipsToBounds = true
        spinner.hidesWhenStopped = true
        preview.addSubview(spinner)

        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = 14
        for (title, keyPath, range, format) in [("Exposure", \RawDevelopSettings.exposure, Float(-3)...3, "%.2f EV"),
                                                ("Temperature", \.temperature, 2000...12000, "%.0f K"),
                                                ("Tint", \.tint, -150...150, "%.0f"),
                                                ("Boost", \.boost, 0...1, "%.2f")] {
            let label = UILabel()
            label.text = title
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let slider = UISlider()
            slider.minimumValue = range.lowerBound
            slider.maximumValue = range.upperBound
            slider.accessibilityLabel = title
            let value = UILabel()
            value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
            value.textColor = .secondaryLabel
            value.textAlignment = .right
            value.widthAnchor.constraint(equalToConstant: 90).isActive = true
            slider.addAction(UIAction { [weak self, weak slider] _ in
                guard let self, let slider else { return }
                self.settings[keyPath: keyPath] = slider.value
                self.refresh()
            }, for: .valueChanged)
            sliders.append((slider, value, keyPath, format))
            let row = UIStackView(arrangedSubviews: [label, slider, value])
            row.spacing = 12
            rows.addArrangedSubview(row)
        }
        reset.configuration?.title = "Reset"
        reset.addAction(UIAction { [weak self] _ in
            self?.settings.reset()
            self?.refresh()
        }, for: .primaryActionTriggered)
        let footer = UIStackView(arrangedSubviews: [reset, UIView()])

        let content = UIStackView(arrangedSubviews: [preview, rows, footer])
        content.axis = .vertical
        content.spacing = 20
        view.addSubview(content)
        for view in [content, spinner] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            preview.heightAnchor.constraint(equalToConstant: 340),
            spinner.centerXAnchor.constraint(equalTo: preview.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
        ])
        refresh()
    }

    /// The sliders and values as `settings` has them, and a new preview, after a moment's pause in a slider's drag.
    private func refresh() {
        for row in sliders {
            let value = settings[keyPath: row.keyPath]
            if row.slider.value != value { row.slider.value = value }
            row.value.text = String(format: row.format, value)
        }
        reset.isEnabled = !settings.isAsShot
        developing?.cancel()
        let url = url, settings = settings
        developing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.spinner.startAnimating()
            let image = await RawImporter.Queue.shared.develop(url, settings: settings, limit: 800)
            guard !Task.isCancelled, let self else { return }
            self.spinner.stopAnimating()
            if let image { self.preview.image = UIImage(cgImage: image) }
        }
    }

    @objc private func importDeveloped() { finish(settings) }

    private func finish(_ settings: RawDevelopSettings?) {
        developing?.cancel()
        session.finishRawDevelop(settings)
        dismiss(animated: true)
    }
}
