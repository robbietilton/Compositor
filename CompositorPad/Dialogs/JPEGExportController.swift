import UIKit

/// The Mac's Export JPEG dialog: the image as it will be encoded, at a quality and over a color for its transparent
/// areas, to look over up to 800% before exporting. `finish` gets the encoded file, or nil for Cancel.
final class JPEGExportController: UIViewController, UIScrollViewDelegate {
    /// The quality of the last export, which the next one starts from, as on the Mac.
    static let qualityKey = "jpegExportQuality"
    /// The zooms the buttons and the View menu step through, as the Mac's preview has them. 1 is 100%: one pixel of the
    /// JPEG to one of the screen, as the canvas counts it.
    static let steps: [CGFloat] = [0.25, 0.5, 1, 2, 4, 8]

    let raster: ExportRaster
    private let finish: (Data?) -> Void
    private(set) var options: JPEGOptions
    /// The latest encoding, and the settings it was made with.
    private(set) var result: JPEGResult?
    private var readyOptions: JPEGOptions?
    private var failure: String?
    /// The encoding in progress, which a newer setting cancels. Tests wait for it.
    private(set) var encoding: Task<Void, Never>?
    /// Whether the preview fits the whole image, as it does until it's zoomed.
    private var fits = true

    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let updating = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let quality = SliderField(caption: "Quality", unit: "%", sliderRange: 0...1, fieldRange: 0...1, fieldScale: 100,
                                      sensitivity: 0.005, sliderWidth: nil)
    private let matte = UIColorWell()
    private let status = OptionControls.caption("")
    private lazy var fitButton = OptionControls.button("Fit") { [weak self] in self?.fitCanvas(nil) }
    private lazy var zoomInButton = OptionControls.button(symbol: "plus.magnifyingglass", label: "Zoom In") { [weak self] in self?.zoomIn(nil) }
    private lazy var zoomOutButton = OptionControls.button(symbol: "minus.magnifyingglass", label: "Zoom Out") { [weak self] in self?.zoomOut(nil) }
    private lazy var exportButton = OptionControls.button("Export…", prominent: true) { [weak self] in self?.export() }

    init(raster: ExportRaster, finish: @escaping (Data?) -> Void) {
        self.raster = raster
        self.finish = finish
        var start = JPEGOptions()
        if let saved = UserDefaults.standard.object(forKey: Self.qualityKey) as? Double, saved.isFinite {
            start.quality = min(1, max(0, saved))
        }
        options = start
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        isModalInPresentation = true
        preferredContentSize = CGSize(width: 660, height: 620)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Export JPEG"
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let header = OptionControls.row([title, UIView(), fitButton, zoomInButton, zoomOutButton])

        // The image at 100% is its pixels in points of this screen; the scroll view's zoom is the preview's.
        let scale = max(1, traitCollection.displayScale)
        imageView.frame = CGRect(x: 0, y: 0, width: CGFloat(raster.image.width) / scale, height: CGFloat(raster.image.height) / scale)
        imageView.layer.minificationFilter = .trilinear
        scroll.addSubview(imageView)
        scroll.contentSize = imageView.frame.size
        scroll.delegate = self
        scroll.maximumZoomScale = Self.steps.last ?? 8
        scroll.contentInsetAdjustmentBehavior = .never
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        let preview = UIView()
        preview.backgroundColor = UIColor(white: 0.12, alpha: 1)
        preview.clipsToBounds = true
        preview.layer.cornerRadius = 8
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        updating.layer.cornerRadius = 8
        updating.clipsToBounds = true
        updating.contentView.addSubview(spinner)
        for view in [scroll, updating] { preview.addSubview(view) }
        for view in [scroll, updating, spinner] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: preview.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: preview.topAnchor), scroll.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
            updating.centerXAnchor.constraint(equalTo: preview.centerXAnchor), updating.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            updating.widthAnchor.constraint(equalToConstant: 56), updating.heightAnchor.constraint(equalToConstant: 56),
            spinner.centerXAnchor.constraint(equalTo: updating.contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: updating.contentView.centerYAnchor),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 330),
        ])
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)

        quality.onChange = { [weak self] value in self?.chooseQuality(value) }
        matte.title = "Background for transparency"
        matte.supportsAlpha = false
        matte.selectedColor = UIColor(srgbRed: options.red, green: options.green, blue: options.blue, alpha: 1)
        matte.addAction(UIAction { [weak self] _ in
            guard let self, let color = self.matte.selectedColor else { return }
            self.chooseMatte(color)
        }, for: .valueChanged)
        let background = OptionControls.row([OptionControls.caption("Background for transparency"), matte, UIView()])

        let size = OptionControls.caption("\(raster.image.width.formatted()) × \(raster.image.height.formatted()) px · sRGB",
                                          color: .secondaryLabel)
        status.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        let cancel = OptionControls.button("Cancel") { [weak self] in self?.cancel() }
        let footer = OptionControls.row([size, UIView(), status, cancel, exportButton], spacing: 12)

        let stack = UIStackView(arrangedSubviews: [header, preview, quality, background, footer])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(8, after: header)
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        encode()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroll.minimumZoomScale = min(fitZoom, Self.steps[0])
        if fits { scroll.zoomScale = fitZoom }
        zoomChanged()
    }

    // The dialog takes the keyboard while it's open: Return exports and Escape cancels, as the Mac's default and cancel
    // buttons, and the View menu's zoom commands zoom the preview rather than the canvas.
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnKey(_:))),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey(_:)))]
    }
    @objc private func returnKey(_ command: UIKeyCommand) { export() }
    @objc private func escapeKey(_ command: UIKeyCommand) { cancel() }
    @objc func zoomIn(_ sender: Any?) { step(1) }
    @objc func zoomOut(_ sender: Any?) { step(-1) }
    @objc func fitCanvas(_ sender: Any?) {
        fits = true
        scroll.setZoomScale(fitZoom, animated: true)
    }
    @objc func actualPixels(_ sender: Any?) { zoom(to: 1) }

    func chooseQuality(_ value: Double) {
        // In hundredths, as the Mac's slider steps.
        let quality = (min(1, max(0, value)) * 100).rounded() / 100
        guard quality != options.quality else { return }
        options.quality = quality
        encode()
    }

    func chooseMatte(_ color: UIColor) {
        guard let sRGB = color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = sRGB.components, c.count >= 3 else { return }
        options.red = min(1, max(0, c[0]))
        options.green = min(1, max(0, c[1]))
        options.blue = min(1, max(0, c[2]))
        encode()
    }

    /// Exports what the preview shows, once it's up to date.
    func export() {
        guard let result, readyOptions == options, failure == nil else { return }
        UserDefaults.standard.set(options.quality, forKey: Self.qualityKey)
        finish(result.data)
    }

    func cancel() {
        encoding?.cancel()
        finish(nil)
    }

    /// Encodes the image with the settings as they are now, a moment after the last change, as the Mac's dialog does.
    private func encode() {
        encoding?.cancel()
        failure = nil
        let requested = options, raster = raster
        encoding = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                let encoded = try await ImageExporter.shared.jpeg(raster, options: requested)
                try Task.checkCancellation()
                guard let self else { return }
                self.result = encoded
                self.readyOptions = requested
                self.imageView.image = UIImage(cgImage: encoded.preview)
            } catch is CancellationError {
                // A newer setting superseded this one.
            } catch {
                guard !Task.isCancelled else { return }
                self?.failure = error.localizedDescription
            }
            self?.refresh()
        }
        refresh()
    }

    private func refresh() {
        quality.show(options.quality)
        let ready = result != nil && readyOptions == options
        if let failure {
            status.text = failure
            status.textColor = .systemRed
        } else if ready, let result {
            status.text = ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file)
            status.textColor = .label
        } else {
            status.text = "Updating…"
            status.textColor = .secondaryLabel
        }
        updating.isHidden = ready || failure != nil
        exportButton.isEnabled = ready && failure == nil
    }

    // MARK: Zooming the preview

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { zoomChanged() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        fits = abs(scale - fitZoom) < 0.001
        zoomChanged()
    }

    /// The zoom at which the whole image fits the preview.
    private var fitZoom: CGFloat {
        let image = imageView.bounds.size, preview = scroll.bounds.size
        guard image.width > 0, image.height > 0, preview.width > 0, preview.height > 0 else { return 1 }
        return min(preview.width / image.width, preview.height / image.height)
    }

    /// The next zoom step past the current zoom, in `direction` (1 in, −1 out).
    private func step(_ direction: Int) {
        let zoom = scroll.zoomScale
        guard let next = direction > 0 ? Self.steps.first(where: { $0 > zoom * 1.001 }) : Self.steps.last(where: { $0 < zoom * 0.999 })
        else { return }
        self.zoom(to: next)
    }

    /// Zooms to `zoom` keeping `point` of the image, or the one in the middle of the preview, where it is on screen.
    private func zoom(to zoom: CGFloat, around point: CGPoint? = nil) {
        fits = false
        let middle = point ?? imageView.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), from: scroll)
        let size = CGSize(width: scroll.bounds.width / zoom, height: scroll.bounds.height / zoom)
        scroll.zoom(to: CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2, width: size.width, height: size.height),
                    animated: true)
    }

    /// A double tap switches between the whole image and 100% where it lands, as a double click does on the Mac.
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if fits { zoom(to: 1, around: gesture.location(in: imageView)) } else { fitCanvas(nil) }
    }

    /// Keeps a preview smaller than the view in its middle, shows the pixels from 100% up as they are, and enables the
    /// buttons that can zoom further.
    private func zoomChanged() {
        let content = scroll.contentSize, preview = scroll.bounds.size
        scroll.contentInset = UIEdgeInsets(top: max(0, (preview.height - content.height) / 2), left: max(0, (preview.width - content.width) / 2),
                                           bottom: 0, right: 0)
        imageView.layer.magnificationFilter = scroll.zoomScale >= 0.999 ? .nearest : .linear
        let zoom = scroll.zoomScale
        fitButton.isEnabled = !fits
        zoomInButton.isEnabled = Self.steps.contains { $0 > zoom * 1.001 }
        zoomOutButton.isEnabled = Self.steps.contains { $0 < zoom * 0.999 }
    }
}
