import CoreImage
import Observation
import UIKit

/// The canvas on iPad: the document drawn on the GPU, painted with Apple Pencil or a finger, and moved and zoomed with
/// two fingers. The tools themselves are the editor's own (`EditorSession`); this view turns touches into their
/// document coordinates, as the Mac's `CanvasView` does with the mouse.
final class PadCanvasView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate, UIPointerInteractionDelegate {
    let session: EditorSession
    /// Whether a finger paints, as `DrawingInput` says: once Apple Pencil turns up, fingers can move the canvas instead.
    var fingerPaints = true
    /// Apple Pencil touched the canvas, hovered over it, or was tapped or squeezed.
    var pencilSeen: () -> Void = {}
    private let surface = MetalCanvasView(frame: .zero)
    private(set) lazy var overlayView = PadOverlayView(session: session)
    /// What touches do with the Move, Crop, Gradient, Shape, Type and selection tools, and with Clone Stamp's source.
    private(set) lazy var input: PadCanvasInput = {
        let input = PadCanvasInput(session: session)
        input.overlayChanged = { [weak self] in
            guard let self else { return }
            self.overlayView.textBox = self.input.textBox
            self.overlayView.setNeedsDisplay()
        }
        input.textOpened = { [weak self] point in self?.openedText(at: point) }
        return input
    }()
    /// The text being typed, while there is some, over the canvas and its overlays.
    private(set) var textEditor: PadTextEditor?
    private let sampleRing = SampleRingView()
    private lazy var compositor = PadCanvasCompositor(session: session)
    private var displayLink: CADisplayLink?
    private var needsRender = true
    /// What waits for the next frame to be drawn.
    private var nextFrame: [@Sendable () -> Void] = []
    /// What waits for the next frame to go on screen, and how many frames in a row found no drawable for it.
    private var nextFrameShown: [() -> Void] = []
    private var unshownFrames = 0

    /// The touch drawing or dragging with the current tool, and what it's doing.
    private var activeTouch: UITouch?
    private enum Drag {
        case paint
        /// The Move tool or a selection tool, which `input` follows.
        case tool
        case pan(CGPoint)
        case sample
        /// The Zoom tool, as on the Mac: a tap zooms in, a drag right or left zooms smoothly in or out.
        case zoom(start: CGPoint, zoom: CGFloat, moved: Bool)
    }
    private var drag: Drag?
    private var pinchStart: (zoom: CGFloat, anchor: CGPoint)?
    private var panLast: CGPoint?
    /// Where the brush is over the canvas, for the brush cursor: Apple Pencil or a finger touching with a brush, and
    /// the pointer or Apple Pencil hovering; with the keys held as they do.
    private var touchPointer: CGPoint?
    private var touchKeys: UIKeyModifierFlags = []
    private var hoverPointer: CGPoint?
    private var hoverKeys: UIKeyModifierFlags = []
    private lazy var clonePreview = ClonePreview(session: session)
    private lazy var pointerInteraction = UIPointerInteraction(delegate: self)
    private var pointerHidden = false

    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.105, alpha: 1)
        isMultipleTouchEnabled = true
        addSubview(surface)
        addSubview(overlayView)
        addSubview(sampleRing)
        compositor.needsRedraw = { [weak self] in self?.setNeedsRender() }
        compositor.textShownTransform = { [weak self] in self?.textEditor?.shownTransform }
        session.refreshCanvasPreview = { [weak self] in self?.setNeedsRender() }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 2
        // Three fingers are iPadOS's own: they undo and redo, through the window's undo manager.
        pan.maximumNumberOfTouches = 2
        // A trackpad's two-finger scroll moves the canvas too.
        pan.allowedScrollTypesMask = .continuous
        for gesture in [pinch, pan] as [UIGestureRecognizer] {
            // Fingers and a trackpad move the canvas; Apple Pencil only paints.
            gesture.allowedTouchTypes = [UITouch.TouchType.direct.rawValue, UITouch.TouchType.indirectPointer.rawValue].map { NSNumber(value: $0) }
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        addInteraction(UIPencilInteraction(delegate: self))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        addInteraction(pointerInteraction)
        isAccessibilityElement = true
        accessibilityLabel = "Canvas"
        accessibilityIdentifier = "editorCanvas"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsRender()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
        overlayView.frame = bounds
        let scale = traitCollection.displayScale
        // After the layout pass, as the Mac canvas does: the viewport is observed, and the window is mid-layout here.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.session.viewport.viewSize != self.bounds.size || self.session.viewport.backingScale != scale else { return }
            self.session.viewport.resize(to: self.bounds.size, backingScale: scale, documentSize: self.session.document?.size)
            self.setNeedsRender()
        }
    }

    func setNeedsRender() {
        needsRender = true
        displayLink?.isPaused = false
    }

    /// Runs `action` once the canvas's next frame is drawn, on a thread of Metal's.
    func afterNextFrame(_ action: @escaping @Sendable () -> Void) {
        nextFrame.append(action)
        setNeedsRender()
    }

    /// Runs `action` on the main thread as the canvas's next frame is handed to Core Animation, in the transaction that
    /// puts it on screen (the canvas presents with the transaction), so what `action` changes in the interface lands
    /// with the frame. A canvas that finds no drawable three frames running goes on without one, so nothing waits for
    /// good.
    func whenNextFrameShows(_ action: @escaping () -> Void) {
        nextFrameShown.append(action)
        setNeedsRender()
    }

    @objc private func tick() {
        guard needsRender else { displayLink?.isPaused = true; return }
        needsRender = false
        render()
    }

    /// Draws the frame, and asks for the next one when anything it read from the session changes. The display link
    /// calls it; tests call it to draw a frame without one.
    func render() {
        guard let renderer = GPUCanvasRenderer.shared else { return }
        surface.fit(scale: session.viewport.backingScale)
        let size = surface.metalLayer.drawableSize
        let frame = withObservationTracking {
            // Painting changes tiles inside the stroke; the revision is what says so.
            _ = session.brushRevision
            // The text editor first: the canvas draws the text being typed where the editor shows it.
            synchronizeTextEditor()
            synchronizeBrushCursor()
            return session.document.flatMap { compositor.frame($0, renderer: renderer, size: size) }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.setNeedsRender() }
        }
        let backdrop = CIImage(color: CIColor(red: 0.105, green: 0.105, blue: 0.105)).cropped(to: CGRect(origin: .zero, size: size))
        let presented = renderer.present(frame ?? backdrop, in: surface.metalLayer, drawn: nextFrame)
        nextFrame = []
        guard !nextFrameShown.isEmpty else { return }
        if presented || unshownFrames >= 2 {
            let shown = nextFrameShown
            nextFrameShown = []
            unshownFrames = 0
            shown.forEach { $0() }
        } else {
            unshownFrames += 1
            setNeedsRender()
        }
    }

    // MARK: Text

    /// Lays the editor over the text being typed, making it when typing starts and taking it away when it ends.
    func synchronizeTextEditor() {
        guard let draft = session.textDraft else {
            guard let editor = textEditor else { return }
            let hadFocus = editor.textView.isFirstResponder
            editor.removeFromSuperview()
            textEditor = nil
            if hadFocus { becomeFirstResponder() }
            return
        }
        let editor = textEditor ?? {
            let editor = PadTextEditor(session: session)
            editor.changed = { [weak self] in self?.setNeedsRender() }
            addSubview(editor)
            textEditor = editor
            return editor
        }()
        editor.synchronize(draft)
    }

    /// Text opened by a touch at `point`: the editor laid over it now, the caret where the touch came down.
    private func openedText(at point: CGPoint) {
        synchronizeTextEditor()
        guard let editor = textEditor else { return }
        editor.placeCaret(at: editor.textView.convert(point, from: self))
        setNeedsRender()
    }

    // MARK: Brush cursor

    /// The brush cursor, as the Mac's canvas shows it with a brush in hand: the brush's circle where Apple Pencil or a
    /// finger touches, or the pointer hovers, around a crosshair. Clone Stamp, once it has a source, shows no crosshair
    /// in its circle: its crosshair stays on the source, and between strokes the circle shows what a stroke there would
    /// stamp. Holding Option, or setting the source, brings the crosshair back.
    func synchronizeBrushCursor() {
        let tool = session.tool
        if pointerHidden != tool.isBrushTool {
            pointerHidden = tool.isBrushTool
            pointerInteraction.invalidate()
        }
        guard tool.isBrushTool, let document = session.document else {
            overlayView.brushCursor = nil
            return
        }
        let pointer = touchPointer ?? hoverPointer
        let brush = pointer.map { session.viewport.documentPoint(from: $0, documentSize: document.size) }
        let diameter = session.brushStroke?.settings.diameter ?? session.brushSettings.diameter
        let picking = (touchPointer == nil ? hoverKeys : touchKeys).contains(.alternate) || input.isDraggingSource
        let cloning = tool == .cloneStamp && session.cloneSource != nil && !picking
        var preview: CGImage?
        if cloning, session.brushStroke == nil, let brush, let offset = session.cloneStrokeOffset(at: brush) {
            preview = clonePreview.image(center: CGPoint(x: brush.x + offset.width, y: brush.y + offset.height),
                                         diameter: diameter, document: document)
        }
        overlayView.brushCursor = PadOverlayView.BrushCursor(
            point: pointer, diameter: max(1, diameter * session.viewport.pointsPerPixel), crosshair: !cloning,
            sample: input.cloneSourceMark(brush: brush).map { session.viewport.viewPoint(from: $0, documentSize: document.size) },
            preview: preview, previewOpacity: session.brushSettings.opacity,
            tip: preview == nil ? nil : clonePreview.tip(diameter: diameter, hardness: session.brushSettings.hardness))
    }

    /// The pointer, or Apple Pencil, hovering at `point` with `keys` held, or gone from over the canvas.
    func hover(at point: CGPoint?, keys: UIKeyModifierFlags = []) {
        hoverPointer = point
        hoverKeys = keys
        synchronizeBrushCursor()
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        // Only Apple Pencil hovers above the screen; a pointer is on it.
        if gesture.zOffset > 0 { pencilSeen() }
        switch gesture.state {
        case .began, .changed: hover(at: gesture.location(in: self), keys: gesture.modifierFlags)
        default: hover(at: nil)
        }
    }

    /// With a brush in hand the pointer hides over the canvas: the brush cursor's crosshair stands in for it, as the
    /// Mac's crosshair pointer does in the brush's circle.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        session.tool.isBrushTool ? .hidden() : nil
    }

    // MARK: Touches

    /// Whether a one-finger touch moves the canvas rather than using the tool: always with the Hand, and, once Apple
    /// Pencil has painted, with the tools that paint or draw, as in other iPad painting apps. A finger still moves
    /// layers, selects, crops, picks colors and zooms.
    static func touchMovesCanvas(tool: NavigationTool, pencil: Bool, fingerPaints: Bool) -> Bool {
        tool == .hand || (!pencil && !fingerPaints && (tool.isBrushTool || tool == .gradient || tool == .shape))
    }

    private func documentPoint(_ touch: UITouch) -> CGPoint? {
        guard let document = session.document else { return nil }
        return session.viewport.documentPoint(from: touch.location(in: self), documentSize: document.size)
    }

    /// Touched, the canvas takes the keyboard and the edit menu's commands from a field that had them, as the Mac's
    /// canvas takes the focus back; undo and redo, the system's three-finger gestures among them, reach the window's
    /// undo manager through it.
    override var canBecomeFirstResponder: Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFirstResponder { becomeFirstResponder() }
        guard activeTouch == nil, let touch = touches.first, event?.allTouches?.count == 1,
              session.document != nil, !session.isProjectBusy, !session.isImporting else { return }
        if touch.type == .pencil { pencilSeen() }
        let tool = session.tool
        let point = touch.location(in: self)
        let keys = event?.modifierFlags ?? []
        let adjusting = session.levels != nil || session.hueSaturation != nil || session.filterEdit != nil
        let paints = !Self.touchMovesCanvas(tool: tool, pencil: touch.type == .pencil, fingerPaints: fingerPaints)
        if tool == .cloneStamp, !adjusting, input.beginSourceDrag(at: point, keys: keys, paints: paints) {
            // Clone Stamp's source, set where the touch lands or moved by its crosshair, by a finger as by Apple Pencil.
            activeTouch = touch
            drag = .tool
            (touchPointer, touchKeys) = (point, keys)
        } else if !paints {
            activeTouch = touch
            drag = .pan(point)
        } else if adjusting, tool != .zoom {
            // While an adjustment's editor is open the canvas only moves and zooms: the edit holds the layers, as on the Mac.
            return
        } else if tool.isBrushTool, let pixel = documentPoint(touch) {
            activeTouch = touch
            drag = .paint
            (touchPointer, touchKeys) = (point, keys)
            session.beginBrush(at: pixel)
        } else if PadCanvasInput.handles(tool) {
            guard input.began(at: touch.location(in: self), keys: event?.modifierFlags ?? [], tapCount: touch.tapCount) else { return }
            activeTouch = touch
            drag = .tool
        } else if tool == .eyedropper {
            activeTouch = touch
            drag = .sample
            sampleRing.original = session.foregroundColor
            sample(touch)
        } else if tool == .zoom {
            activeTouch = touch
            drag = .zoom(start: touch.location(in: self), zoom: session.viewport.zoom, moved: false)
        }
        setNeedsRender()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let drag else { return }
        if touchPointer != nil { (touchPointer, touchKeys) = (touch.location(in: self), event?.modifierFlags ?? []) }
        switch drag {
        case .paint:
            // Apple Pencil reports up to 240 points a second; the display shows every fourth. All of them go into the
            // stroke.
            for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                guard let pixel = documentPoint(sample) else { continue }
                session.continueBrush(at: pixel)
            }
        case .tool:
            input.moved(to: touch.location(in: self), keys: event?.modifierFlags ?? [])
        case .pan(let last):
            let point = touch.location(in: self)
            session.viewport.translate(by: CGSize(width: point.x - last.x, height: point.y - last.y))
            self.drag = .pan(point)
        case .sample:
            sample(touch)
        case .zoom(let start, let zoom, var moved):
            let dx = touch.location(in: self).x - start.x
            if abs(dx) >= 3 { moved = true }
            // Doubling for every 100 points dragged, as on the Mac.
            if moved { session.zoom(to: zoom * pow(2, dx / 100), anchor: start) }
            self.drag = .zoom(start: start, zoom: zoom, moved: moved)
        }
        setNeedsRender()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        finishDrag(at: touch, cancelled: false, keys: event?.modifierFlags ?? [])
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        finishDrag(at: touch, cancelled: true, keys: event?.modifierFlags ?? [])
    }

    private func finishDrag(at touch: UITouch, cancelled: Bool, keys: UIKeyModifierFlags) {
        defer {
            activeTouch = nil
            drag = nil
            (touchPointer, touchKeys) = (nil, [])
            setNeedsRender()
        }
        switch drag {
        case .paint:
            let pixel = documentPoint(touch)
            defer { input.strokeEnded(at: pixel) }
            // A second finger coming down to zoom takes the canvas back, and the stroke it interrupted with it.
            if cancelled { session.cancelBrush(); return }
            if let pixel { session.continueBrush(at: pixel) }
            session.finishBrushImmediately()
        case .tool:
            if cancelled { input.cancelled() }
            else { input.ended(at: touch.location(in: self), keys: keys, tapCount: touch.tapCount) }
        case .zoom(let start, _, let moved):
            if !cancelled, !moved { session.zoom(to: session.viewport.zoom * 2, anchor: start) }
        case .sample:
            sampleRing.isHidden = true
        case .pan, nil:
            break
        }
    }

    /// The Eyedropper: the color under the touch, as the canvas shows it, becomes the foreground color, and the ring
    /// around the touch shows it against the color it replaces.
    private func sample(_ touch: UITouch) {
        guard session.canEditPalette, let pixel = documentPoint(touch),
              let color = session.sampleCompositeColor(at: pixel) else { return }
        session.foregroundColor = color
        sampleRing.sampled = color
        if session.showsSampleRing { sampleRing.show(at: touch.location(in: self)) }
    }

    // MARK: Gestures

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// A hand resting on the screen while Apple Pencil paints doesn't take the canvas away from the stroke, and three
    /// fingers are left to iPadOS's undo and redo.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if case .paint = drag, activeTouch?.type == .pencil { return false }
        return gestureRecognizer.numberOfTouches <= 2
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        let anchor = gesture.location(in: self)
        switch gesture.state {
        case .began:
            pinchStart = (session.viewport.zoom, anchor)
        case .changed:
            guard let start = pinchStart else { return }
            session.zoom(to: start.zoom * gesture.scale, anchor: anchor)
        default:
            pinchStart = nil
        }
        setNeedsRender()
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            panLast = point
        case .changed:
            guard let last = panLast else { return }
            session.viewport.translate(by: CGSize(width: point.x - last.x, height: point.y - last.y))
            panLast = point
        default:
            panLast = nil
        }
        setNeedsRender()
    }

    // MARK: Apple Pencil

    /// A double tap (or squeeze) on Apple Pencil switches between painting and erasing, as the system setting suggests.
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        pencilSeen()
        guard UIPencilInteraction.preferredTapAction == .switchEraser || UIPencilInteraction.preferredTapAction == .switchPrevious
        else { return }
        if session.tool != .brush { session.selectTool(.brush) }
        session.brushMode = session.brushMode == .paint ? .erase : .paint
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        pencilSeen()
    }
}
