import UIKit

/// The bar under the tabs with the settings of the tool in hand, as the Mac's tool header: the tool's name, then
/// what it can be set to. A tool that doesn't work by touch yet says so. The bar scrolls when its settings outgrow
/// the window.
final class ToolOptionsBar: UIView {
    var session: EditorSession? {
        didSet {
            guard session !== oldValue else { return }
            shownKey = nil
            setNeedsUpdateProperties()
        }
    }
    /// Opens the foreground color's picker from the brush's Color swatch, as the rail's swatch does.
    var onChooseForeground: (UIView) -> Void = { _ in }

    static let height: CGFloat = 50

    private let scroll = UIScrollView()
    private let content = UIStackView()
    /// What the bar was built for; it's built again when that changes, and only its values are updated otherwise.
    private var shownKey: Key?
    /// Puts the session's current values into the controls. Run on every update, so UIKit follows what they read.
    private var refreshers: [(EditorSession) -> Void] = []
    /// Whether the bar being built has space of its own, which keeps what follows it at the bar's end.
    private var hasSpace = false

    private struct Key: Equatable {
        let tool: NavigationTool
        let brushMode: BrushToolMode
        let blurMode: BlurToolMode
        let maskSelected: Bool
        let hasDocument: Bool
        /// An ellipse shows Anti-alias and a rectangle doesn't; Wand and Object have settings of their own.
        let marqueeKind: LassoKind
        let wandMode: WandMode
        /// A line has a width and a rectangle a corner radius.
        let shapeKind: ShapeKind
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        content.spacing = 14
        content.alignment = .center
        scroll.addSubview(content)
        addSubview(scroll)
        for view in [scroll, content] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -18),
            content.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            content.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            // At least as wide as the bar, so a trailing spacer can push Cancel and Apply to its end.
            content.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -36),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateProperties() {
        super.updateProperties()
        guard let session else { return }
        let key = Key(tool: session.tool, brushMode: session.brushMode, blurMode: session.blurMode,
                      maskSelected: session.isMaskSelected, hasDocument: session.document != nil,
                      marqueeKind: session.marqueeKind, wandMode: session.wandMode, shapeKind: session.shapeKind)
        if key != shownKey {
            shownKey = key
            build(for: session)
        }
        for refresh in refreshers { refresh(session) }
    }

    private func build(for session: EditorSession) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        refreshers = []
        hasSpace = false
        switch session.tool {
        case .move: buildTransform()
        case .marquee, .lasso, .wand: buildSelection(for: session)
        case .crop: buildCrop()
        case .gradient: buildGradient(for: session)
        case .shape: buildShape(for: session)
        case let tool where tool.isBrushTool && ToolRailView.touchTools.contains(tool): buildBrush(for: session)
        case .hand, .zoom: buildNavigation(zoom: session.tool == .zoom)
        case .eyedropper: buildEyedropper()
        case .idle: add(OptionControls.title("Select a tool"))
        case let tool:
            add(OptionControls.title(Self.name(of: tool)))
            add(OptionControls.caption("Not on iPad yet", color: .secondaryLabel))
        }
        // The room to spare goes after the settings, unless the bar's own space keeps its last controls at its end.
        if !hasSpace { add(UIView()) }
        scroll.contentOffset = .zero
    }

    private func add(_ view: UIView) { content.addArrangedSubview(view) }

    /// Space for the room the bar has to spare, so what's added after it sits at the bar's end, as on the Mac.
    private func addSpace() {
        add(UIView())
        hasSpace = true
    }

    /// The tool's name as the Mac's header shows it, without its key.
    static func name(of tool: NavigationTool) -> String {
        switch tool {
        case .marquee: "Marquee"
        case .lasso: "Lasso"
        case .wand: "Magic"
        case .crop: "Crop"
        case .spotHealing: "Spot Healing"
        case .cloneStamp: "Clone Stamp"
        case .gradient: "Gradient"
        case .shape: "Shape"
        case .type: "Type"
        default: tool.label.components(separatedBy: " (").first ?? tool.label
        }
    }

    // MARK: Transform

    private func buildTransform() {
        let title = OptionControls.title("Transform")
        let autoSelect = OptionControls.checkbox("Auto Select") { [weak self] in self?.session?.transformAutoSelect = $0 }
        // Hidden, a drag anywhere moves the layer, with no handle in the way.
        let controls = OptionControls.checkbox("Show Controls") { [weak self] in self?.session?.showsTransformControls = $0 }
        let x = transformField("X") { $0.origin.x = $1 }
        let y = transformField("Y") { $0.origin.y = $1 }
        let width = transformField("W", range: 1...30_000) { [weak self] value, number in self?.resize(&value, to: number, width: true) }
        let height = transformField("H", range: 1...30_000) { [weak self] value, number in self?.resize(&value, to: number, width: false) }
        let lock = OptionControls.checkbox("") { [weak self] in self?.session?.locksTransformRatio = $0 }
        lock.configurationUpdateHandler = { button in
            button.configuration?.image = UIImage(systemName: "link")
            button.configuration?.baseForegroundColor = button.isSelected ? .tintColor : .secondaryLabel
            button.configuration?.background.backgroundColor = button.isSelected ? UIColor.tintColor.withAlphaComponent(0.18) : .clear
        }
        lock.accessibilityLabel = "Lock aspect ratio"
        let scale = NumberField(caption: "Scale", unit: "%", width: 64, range: 0.1...30_000, format: NumberField.upToTwoDecimals)
        scale.live = true
        scale.onChange = { [weak self] number in
            guard let self, number > 0 else { return }
            let pixelSize = self.pixelSize
            self.change { $0 = $0.scaled(toPercent: number, pixelSize: pixelSize) }
        }
        scale.onFinish = { [weak self] in self?.finishFields() }
        let angle = transformField("Angle", unit: "°", width: 60, range: -360...360) { $0.rotation = $1.truncatingRemainder(dividingBy: 360) }
        let sampling = PopUpButton()
        sampling.accessibilityLabel = "Sampling"
        sampling.onChoose = { [weak self] name in
            guard let mode = LayerSampling(rawValue: name) else { return }
            self?.change { $0.sampling = mode }
            self?.finishFields()
        }
        let flipH = OptionControls.button("Flip H") { [weak self] in self?.change { $0.flipX.toggle() }; self?.finishFields() }
        let flipV = OptionControls.button("Flip V") { [weak self] in self?.change { $0.flipY.toggle() }; self?.finishFields() }
        let cancel = OptionControls.button("Cancel") { [weak self] in self?.session?.cancelTransform() }
        let apply = OptionControls.button("Apply", prominent: true) { [weak self] in self?.session?.commitTransform() }
        let pending = OptionControls.row([cancel, apply])

        for view in [title, autoSelect, controls, x, y, width, height, lock, scale, angle, sampling, flipH, flipV] as [UIView] { add(view) }
        content.setCustomSpacing(6, after: width)
        content.setCustomSpacing(6, after: height)
        addSpace()
        add(pending)

        refreshers.append { [weak self] session in
            guard let self else { return }
            title.text = session.transformTargetsMask ? "Transform Mask" : "Transform"
            autoSelect.isSelected = session.transformAutoSelect
            autoSelect.isEnabled = session.document != nil
            controls.isSelected = session.showsTransformControls
            controls.isEnabled = session.document != nil
            lock.isSelected = session.locksTransformRatio
            let value = self.shownTransform
            x.show(value.origin.x)
            y.show(value.origin.y)
            width.show(value.size.width)
            height.show(value.size.height)
            scale.show(value.scalePercent(pixelSize: self.pixelSize))
            angle.show(value.rotation)
            sampling.show([LayerSampling.allCases.map(\.rawValue)], chosen: value.sampling.rawValue)
            // Numbers describe an ordinary transform; while distorted, the handles are the controls.
            let editable = (session.canTransform || session.transformEdit != nil) && session.transformEdit?.corners == nil
            for field in [x, y, width, height, scale, angle] { field.isEnabled = editable }
            for control in [lock, sampling, flipH, flipV] as [UIControl] { control.isEnabled = editable }
            // Only an edit that waits for them (typed values, a distortion) has anything to cancel or apply; a drag
            // applies itself when it's let go.
            let waiting = session.transformEdit?.persistent == true
            pending.alpha = waiting ? 1 : 0
            pending.isUserInteractionEnabled = waiting
        }
    }

    /// The transform the fields show: the one being edited, else the active layer's.
    private var shownTransform: LayerTransform {
        guard let session else { return LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)) }
        return session.transformEdit?.draft ?? session.activeLayer.map { session.editedTransform(for: $0) }
            ?? LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1))
    }

    /// 100% scale: the layer's pixels (a blank layer's size before this edit, so typing doesn't compound).
    private var pixelSize: CGSize { session?.transformPixelSize ?? session?.activeLayer?.size ?? shownTransform.size }

    private func transformField(_ caption: String, unit: String? = nil, width: CGFloat = 70,
                                range: ClosedRange<Double> = -30_000...30_000,
                                set: @escaping (inout LayerTransform, CGFloat) -> Void) -> NumberField {
        let field = NumberField(caption: caption, unit: unit, width: width, range: range, format: NumberField.upToTwoDecimals)
        field.live = true
        field.onChange = { [weak self] number in self?.change { set(&$0, CGFloat(number)) } }
        field.onFinish = { [weak self] in self?.finishFields() }
        return field
    }

    /// A value typed or scrubbed shows on the canvas as it changes and is applied, as one undo step, once the field is
    /// done with it, as on the Mac: a transform never resamples the layer's pixels, so there is nothing to confirm. An
    /// edit already waiting for Apply takes it as part of that edit.
    private func change(_ update: (inout LayerTransform) -> Void) {
        guard let session else { return }
        if session.transformEdit == nil {
            session.beginTransform(persistent: false)
            session.transformEdit?.fromFields = true
        }
        guard var value = session.transformEdit?.draft else { return }
        update(&value)
        session.previewTransform(value)
    }

    private func finishFields() {
        if session?.transformEdit?.fromFields == true { session?.commitTransform() }
    }

    private func resize(_ value: inout LayerTransform, to number: CGFloat, width: Bool) {
        guard number >= 1 else { return }
        let locked = session?.locksTransformRatio == true
        if width {
            if locked { value.size.height *= number / value.size.width }
            value.size.width = number
        } else {
            if locked { value.size.width *= number / value.size.height }
            value.size.height = number
        }
    }

    // MARK: Brushes

    private func buildBrush(for session: EditorSession) {
        let tool = session.tool
        let name = tool == .spotHealing ? "Spot Healing" : tool == .cloneStamp ? "Clone Stamp" : tool == .blur ? "Smear"
            : session.brushMode == .erase ? "Eraser" : "Brush"
        add(OptionControls.title(name))

        if tool == .brush {
            let modes = BrushToolMode.allCases
            let picker = OptionControls.segments(modes.map(\.rawValue)) { [weak self] in self?.session?.brushMode = modes[$0] }
            add(picker)
            refreshers.append { picker.selectedSegmentIndex = modes.firstIndex(of: $0.brushMode) ?? 0 }
        }
        if tool == .blur {
            let modes = BlurToolMode.allCases
            let picker = OptionControls.segments(modes.map(\.rawValue)) { [weak self] in self?.session?.blurMode = modes[$0] }
            add(picker)
            refreshers.append { picker.selectedSegmentIndex = modes.firstIndex(of: $0.blurMode) ?? 0 }
        }

        let size = NumberField(caption: "Size", unit: "px", width: 56, range: 1...2000)
        size.onChange = { [weak self] in self?.session?.brushSettings.diameter = CGFloat($0) }
        add(size)
        refreshers.append { size.show(Double($0.brushSettings.diameter)) }

        let hardness = SliderField(caption: "Hardness", unit: "%", sliderRange: 0...1, fieldRange: 0...1, fieldScale: 100, sensitivity: 0.01)
        hardness.onChange = { [weak self] in self?.session?.brushSettings.hardness = CGFloat($0) }
        add(hardness)
        refreshers.append { hardness.show(Double($0.brushSettings.hardness)) }

        let opacity = SliderField(caption: tool == .blur ? "Strength" : "Opacity", unit: "%", sliderRange: 0.01...1,
                                  fieldRange: 0.01...1, fieldScale: 100, sensitivity: 0.01)
        opacity.onChange = { [weak self] in self?.session?.brushSettings.opacity = CGFloat($0) }
        add(opacity)
        refreshers.append { opacity.show(Double($0.brushSettings.opacity)) }

        // Blur softens by a radius of its own, apart from how strongly it lays the softening down. The slider covers
        // everyday radii; typing or scrubbing reaches up to 50.
        if tool == .blur, session.blurMode == .blur {
            let radius = SliderField(caption: "Radius", unit: "px", sliderRange: 0.5...20, fieldRange: 0.5...50, sensitivity: 0.1,
                                     format: { abs($0 - $0.rounded()) < 0.05 ? String(Int($0.rounded())) : String(format: "%.1f", $0) })
            radius.onChange = { [weak self] in self?.session?.brushSettings.blurRadius = CGFloat($0) }
            add(radius)
            refreshers.append { radius.show(Double($0.brushSettings.blurRadius)) }
        }
        // Paint and Erase only: healing, cloning and smearing have their own feel.
        if tool == .brush {
            let smoothing = SliderField(caption: "Smoothing", sliderRange: 0...100, fieldRange: 0...100, sensitivity: 1)
            smoothing.onChange = { [weak self] in self?.session?.brushSettings.smoothing = CGFloat($0) }
            add(smoothing)
            refreshers.append { smoothing.show(Double($0.brushSettings.smoothing)) }
        }

        if session.isMaskSelected {
            let paint = OptionControls.segments(["Black · Hide", "White · Reveal"]) { [weak self] in self?.session?.maskPaintWhite = $0 == 1 }
            add(paint)
            refreshers.append { paint.selectedSegmentIndex = $0.maskPaintWhite ? 1 : 0 }
        } else if tool != .cloneStamp, tool != .blur {
            let swatch = ColorSwatchButton()
            swatch.accessibilityLabel = "Foreground color"
            swatch.addAction(UIAction { [weak self, weak swatch] _ in
                guard let swatch else { return }
                self?.onChooseForeground(swatch)
            }, for: .primaryActionTriggered)
            add(OptionControls.row([OptionControls.caption("Color", color: .secondaryLabel), swatch], spacing: 8))
            refreshers.append { session in
                swatch.color = session.foregroundColor
                swatch.isEnabled = session.canEditPalette
            }
        }
        addSpace()
        if session.isMaskSelected { add(OptionControls.caption("Mask", color: .secondaryLabel)) }

        refreshers.append { [weak self] session in
            self?.content.isUserInteractionEnabled = !session.showsBusy
            self?.content.alpha = session.showsBusy ? 0.5 : 1
        }
    }

    // MARK: Selections

    private func buildSelection(for session: EditorSession) {
        let tool = session.tool
        add(OptionControls.title(Self.name(of: tool)))
        // The outline's shape, or how the Magic tool selects; changing it drops an outline being drawn.
        if tool == .marquee {
            let kinds = LassoKind.marqueeChoices
            let picker = OptionControls.segments(kinds.map(\.rawValue)) { [weak self] index in
                self?.session?.cancelLasso()
                self?.session?.marqueeKind = kinds[index]
            }
            add(picker)
            refreshers.append { picker.selectedSegmentIndex = kinds.firstIndex(of: $0.marqueeKind) ?? 0 }
        } else if tool == .wand {
            let modes = WandMode.allCases
            let picker = OptionControls.segments(modes.map(\.rawValue)) { [weak self] index in
                self?.session?.cancelLasso()
                self?.session?.wandMode = modes[index]
            }
            add(picker)
            refreshers.append { picker.selectedSegmentIndex = modes.firstIndex(of: $0.wandMode) ?? 0 }
        } else {
            let kinds = LassoKind.lassoChoices
            let picker = OptionControls.segments(kinds.map(\.rawValue)) { [weak self] index in
                self?.session?.cancelLasso()
                self?.session?.lassoKind = kinds[index]
            }
            add(picker)
            refreshers.append { picker.selectedSegmentIndex = kinds.firstIndex(of: $0.lassoKind) ?? 0 }
        }
        // New, Add or Subtract. On a keyboard, Shift and Option choose for one outline, and this shows them held.
        let modes = SelectionMode.allCases
        let mode = OptionControls.segments(modes.map(\.rawValue)) { [weak self] in self?.session?.selectionModeChoice = modes[$0] }
        add(mode)
        refreshers.append { mode.selectedSegmentIndex = modes.firstIndex(of: $0.displayedSelectionMode) ?? 0 }

        if tool == .wand, session.wandMode == .wand {
            let tolerance = NumberField(caption: "Tolerance", width: 44, range: 0...255)
            tolerance.onChange = { [weak self] in self?.session?.wandSettings.tolerance = Int($0.rounded()) }
            let sizes = WandSampleSize.allCases
            let sample = PopUpButton()
            sample.accessibilityLabel = "Sample Size"
            sample.onChoose = { [weak self] title in
                if let size = sizes.first(where: { $0.title == title }) { self?.session?.wandSettings.sampleSize = size }
            }
            let layers = OptionControls.segments(["This Layer", "All Layers"]) { [weak self] in self?.session?.wandSettings.sampleAllLayers = $0 == 1 }
            let contiguous = OptionControls.checkbox("Contiguous") { [weak self] in self?.session?.wandSettings.contiguous = $0 }
            for view in [tolerance, sample, layers, contiguous] as [UIView] { add(view) }
            refreshers.append { session in
                tolerance.show(Double(session.wandSettings.tolerance))
                sample.show([sizes.map(\.title)], chosen: session.wandSettings.sampleSize.title)
                layers.selectedSegmentIndex = session.wandSettings.sampleAllLayers ? 1 : 0
                contiguous.isSelected = session.wandSettings.contiguous
            }
        }
        if tool == .wand, session.wandMode == .object {
            let layers = OptionControls.segments(["This Layer", "All Layers"]) { [weak self] in
                self?.session?.objectSelectionSettings.sampleAllLayers = $0 == 1
            }
            // Positive values tighten the detected outline, negative ones loosen it.
            let edge = NumberField(caption: "Edge", unit: "px", width: 40, range: -10...10)
            edge.onChange = { [weak self] in self?.session?.objectSelectionSettings.edgeOffset = Int($0.rounded()) }
            for view in [layers, edge] as [UIView] { add(view) }
            refreshers.append { session in
                layers.selectedSegmentIndex = session.objectSelectionSettings.sampleAllLayers ? 1 : 0
                edge.show(Double(session.objectSelectionSettings.edgeOffset))
            }
        }
        // Rectangles land on whole pixels, so smoothing doesn't apply, as in Photoshop; ellipses curve.
        if tool != .marquee || session.marqueeKind == .ellipse {
            let antialias = OptionControls.checkbox("Anti-alias") { [weak self] in self?.session?.selectionAntialiased = $0 }
            add(antialias)
            refreshers.append { antialias.isSelected = $0.selectionAntialiased }
        }
        add(modifyControl("Expand", amount: \.selectionExpandAmount, range: 1...500) { $0.expandSelection(by: $1) })
        add(modifyControl("Contract", amount: \.selectionContractAmount, range: 1...500) { $0.contractSelection(by: $1) })
        add(modifyControl("Feather", amount: \.selectionFeatherAmount, range: 1...250, disablesAmount: false) { $0.featherSelection(by: $1) })
        addSpace()
        let empty = OptionControls.caption("Empty selection", color: .secondaryLabel)
        let deselect = OptionControls.button("Deselect") { [weak self] in self?.session?.deselect() }
        add(empty)
        add(deselect)

        refreshers.append { [weak self] session in
            empty.isHidden = session.selection?.isEmpty != true
            deselect.isHidden = session.selection == nil
            deselect.isEnabled = session.canEditSelection
            let usable = !session.showsBusy && session.document != nil
            self?.content.isUserInteractionEnabled = usable
            self?.content.alpha = usable ? 1 : 0.5
        }
    }

    /// The Mac's Gradient bar: the gradient's shape and colors, Reverse and Opacity, and while a gradient waits for them,
    /// Cancel and Apply.
    private func buildGradient(for session: EditorSession) {
        let shapes = GradientShape.allCases
        let shape = OptionControls.segments(shapes.map(\.rawValue)) { [weak self] in self?.session?.gradientSettings.shape = shapes[$0] }
        let swatch = GradientSwatch()
        let styles = GradientStyle.allCases
        let style = PopUpButton()
        style.accessibilityLabel = "Colors"
        style.onChoose = { [weak self] name in
            guard let style = GradientStyle(rawValue: name) else { return }
            self?.session?.gradientSettings.style = style
        }
        let reverse = OptionControls.checkbox("Reverse") { [weak self] in self?.session?.gradientSettings.reversed = $0 }
        let opacity = SliderField(caption: "Opacity", unit: "%", sliderRange: 0.01...1, fieldRange: 0.01...1, fieldScale: 100,
                                  sensitivity: 0.01)
        opacity.onChange = { [weak self] in self?.session?.gradientSettings.opacity = CGFloat($0) }
        let cancel = OptionControls.button("Cancel") { [weak self] in self?.session?.cancelGradient() }
        let apply = OptionControls.button("Apply", prominent: true) { [weak self] in
            guard let session = self?.session else { return }
            Task { await session.commitGradient() }
        }
        let pending = OptionControls.row([cancel, apply])

        for view in [OptionControls.title("Gradient"), shape, swatch, style, reverse, opacity] as [UIView] { add(view) }
        addSpace()
        if session.isMaskSelected { add(OptionControls.caption("Mask", color: .secondaryLabel)) }
        add(pending)

        refreshers.append { [weak self] session in
            shape.selectedSegmentIndex = shapes.firstIndex(of: session.gradientSettings.shape) ?? 0
            swatch.colors = session.gradientColors(mask: false)
            style.show([styles.map(\.rawValue)], chosen: session.gradientSettings.style.rawValue)
            reverse.isSelected = session.gradientSettings.reversed
            opacity.show(Double(session.gradientSettings.opacity))
            let waiting = session.gradientEdit != nil
            pending.alpha = waiting ? 1 : 0
            pending.isUserInteractionEnabled = waiting
            let usable = !session.showsBusy && session.document != nil
            self?.content.isUserInteractionEnabled = usable
            self?.content.alpha = usable ? 1 : 0.5
        }
    }

    /// The Mac's Shape bar: the shape, a line's width or a rectangle's corner radius, and the foreground color it's
    /// filled with.
    private func buildShape(for session: EditorSession) {
        let kinds = ShapeKind.allCases
        let kind = OptionControls.segments(kinds.map(\.rawValue)) { [weak self] index in
            self?.session?.cancelShape()
            self?.session?.shapeKind = kinds[index]
        }
        add(OptionControls.title("Shape"))
        add(kind)
        refreshers.append { kind.selectedSegmentIndex = kinds.firstIndex(of: $0.shapeKind) ?? 0 }
        if session.shapeKind == .line {
            let width = SliderField(caption: "Width", unit: "px", sliderRange: 1...100, fieldRange: 1...5000, sensitivity: 1)
            width.onChange = { [weak self] in self?.session?.shapeLineWidth = min(5000, max(1, $0.rounded())) }
            add(width)
            refreshers.append { width.show($0.shapeLineWidth) }
        }
        if session.shapeKind == .rectangle {
            let radius = SliderField(caption: "Radius", unit: "px", sliderRange: 0...200, fieldRange: 0...5000, sensitivity: 1)
            radius.onChange = { [weak self] in self?.session?.shapeCornerRadius = min(5000, max(0, $0.rounded())) }
            add(radius)
            refreshers.append { radius.show($0.shapeCornerRadius) }
        }
        // Shapes fill with the foreground color; the swatch opens its picker, as the rail's does.
        let swatch = ColorSwatchButton()
        swatch.accessibilityLabel = "Fill color"
        swatch.addAction(UIAction { [weak self, weak swatch] _ in
            guard let swatch else { return }
            self?.onChooseForeground(swatch)
        }, for: .primaryActionTriggered)
        add(OptionControls.row([OptionControls.caption("Fill", color: .secondaryLabel), swatch], spacing: 8))

        refreshers.append { [weak self] session in
            swatch.color = session.foregroundColor
            swatch.isEnabled = session.canEditPalette
            let usable = !session.showsBusy && session.document != nil
            self?.content.isUserInteractionEnabled = usable
            self?.content.alpha = usable ? 1 : 0.5
        }
    }

    /// The frame's shapes in the Crop bar, as the Mac's has them.
    static let cropRatios = ["Free", "Original", "1:1", "4:3", "3:4", "16:9", "9:16"]

    /// The Mac's Crop bar: the frame's ratio and size, then Cancel and Apply Crop.
    private func buildCrop() {
        let ratio = PopUpButton()
        ratio.accessibilityLabel = "Ratio"
        ratio.onChoose = { [weak self] choice in
            guard let session = self?.session else { return }
            session.cropRatioChoice = choice
            session.changeCropRatio()
        }
        let size = OptionControls.caption("", color: .secondaryLabel)
        size.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        let cancel = OptionControls.button("Cancel") { [weak self] in self?.session?.cancelCrop() }
        let apply = OptionControls.button("Apply Crop", prominent: true) { [weak self] in
            guard let session = self?.session else { return }
            Task { await session.commitCrop() }
        }
        add(OptionControls.title("Crop"))
        add(OptionControls.row([OptionControls.caption("Ratio", color: .secondaryLabel), ratio]))
        add(size)
        addSpace()
        add(OptionControls.row([cancel, apply]))

        refreshers.append { [weak self] session in
            ratio.show([Self.cropRatios], chosen: session.cropRatioChoice)
            size.text = session.cropRect.map { "\(Int($0.width)) × \(Int($0.height)) px" }
            size.isHidden = session.cropRect == nil
            cancel.isEnabled = session.cropRect != nil
            apply.isEnabled = session.cropRect != nil
            let usable = !session.showsBusy && session.document != nil
            self?.content.isUserInteractionEnabled = usable
            self?.content.alpha = usable ? 1 : 0.5
        }
    }

    /// A button and the pixels it works by, as the Mac's Expand, Contract and Feather, which keeps its amount open
    /// without a selection.
    private func modifyControl(_ title: String, amount: ReferenceWritableKeyPath<EditorSession, Int>, range: ClosedRange<Double>,
                               disablesAmount: Bool = true, action: @escaping (EditorSession, Int) -> Void) -> UIView {
        let button = OptionControls.button(title) { [weak self] in
            guard let session = self?.session else { return }
            action(session, session[keyPath: amount])
        }
        let field = NumberField(caption: nil, unit: "px", width: 44, range: range)
        field.onChange = { [weak self] in self?.session?[keyPath: amount] = Int($0.rounded()) }
        refreshers.append { session in
            field.show(Double(session[keyPath: amount]))
            button.isEnabled = session.canModifySelection
            if disablesAmount { field.isEnabled = session.canModifySelection }
        }
        return OptionControls.row([button, field], spacing: 5)
    }

    // MARK: Eyedropper

    private func buildEyedropper() {
        add(OptionControls.title("Eyedropper"))
        let ring = OptionControls.checkbox("Sample Ring") { [weak self] in self?.session?.showsSampleRing = $0 }
        add(ring)
        refreshers.append { ring.isSelected = $0.showsSampleRing }
    }

    // MARK: Hand and Zoom

    private func buildNavigation(zoom: Bool) {
        add(OptionControls.title(zoom ? "Zoom" : "Pan"))
        guard zoom else { return }
        let field = NumberField(caption: nil, unit: "%", width: 76, range: 0.1...3200, sensitivity: 1, format: { value in
            String(format: "%.2f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        })
        field.field.accessibilityLabel = "Zoom percentage"
        field.onChange = { [weak self] percent in
            guard let session = self?.session, !session.isProjectBusy else { return }
            session.zoom(to: CGFloat(percent / 100))
        }
        add(field)
        refreshers.append { session in
            field.show(Double(session.viewport.zoom * 100))
            field.isEnabled = session.document != nil && !session.showsBusy
        }
    }
}

/// A color as the Mac's swatches draw it: a rounded rectangle with a white inner and a black outer edge.
/// A gradient's colors from end to end over a checkerboard, so transparency reads as transparency, as the Mac's
/// Gradient bar shows them.
final class GradientSwatch: UIView {
    var colors: [CGColor] = [] { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        layer.cornerRadius = 3
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0, alpha: 0.5).cgColor
        widthAnchor.constraint(equalToConstant: 56).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(bounds)
        let tile: CGFloat = 4
        context.setFillColor(UIColor(white: 0.5, alpha: 0.45).cgColor)
        for row in 0..<Int(ceil(bounds.height / tile)) {
            for column in 0..<Int(ceil(bounds.width / tile)) where (row + column).isMultiple(of: 2) {
                context.fill(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile))
            }
        }
        guard colors.count >= 2,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)
        else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: bounds.width, y: 0), options: [])
    }
}

final class ColorSwatchButton: UIControl {
    var color = PaletteColor.black {
        didSet { fill.backgroundColor = UIColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1) }
    }
    private let fill = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill.isUserInteractionEnabled = false
        fill.layer.cornerRadius = 4
        fill.layer.borderWidth = 1
        fill.layer.borderColor = UIColor.white.cgColor
        layer.cornerRadius = 5
        layer.borderWidth = 1
        layer.borderColor = UIColor.black.cgColor
        addSubview(fill)
        fill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44), heightAnchor.constraint(equalToConstant: 26),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1), fill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            fill.topAnchor.constraint(equalTo: topAnchor, constant: 1), fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.4 } }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        if let touch, bounds.contains(touch.location(in: self)) { sendActions(for: .primaryActionTriggered) }
    }
}
