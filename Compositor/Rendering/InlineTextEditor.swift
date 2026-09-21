import AppKit

/// A native text system on the canvas: selection, marked text/IME, clipboard and local undo
/// stay with NSTextView. Its logical bounds are layer pixels; the containing view supplies zoom.
final class CanvasTextView: NSTextView {
    weak var editor: InlineTextEditor?
    private let textUndo = UndoManager()
    override var undoManager: UndoManager? { textUndo }
    override func keyDown(with event: NSEvent) {
        guard let event = ShortcutSettings.shared.textEvent(event) else { return }
        if event.keyCode == 53 { editor?.canvas?.session.cancelText(); return }
        // Option with the arrows sets spacing, as in Photoshop: left and right the tracking, up and down the
        // leading. Shift makes each step ten.
        if event.modifierFlags.contains(.option), [123, 124, 125, 126].contains(event.keyCode),
           let session = editor?.canvas?.session {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: session.changeTextStyle { $0.tracking -= step }
            case 124: session.changeTextStyle { $0.tracking += step }
            // Up closes the lines up, down opens them out, counting from whatever Auto works out to.
            case 126: session.changeTextStyle { $0.leading = max(1, $0.lineHeight - step) }
            default: session.changeTextStyle { $0.leading = $0.lineHeight + step }
            }
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
            _ = editor?.canvas?.session.finishText()
            return
        }
        super.keyDown(with: event)
    }
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    // The editor sets the cursor for the whole box — the I-beam over the text, resize arrows over the edges.
    override func resetCursorRects() {}
}

final class InlineTextEditor: NSView, NSTextViewDelegate {
    weak var canvas: CanvasView?
    let textView = CanvasTextView(frame: .zero)
    fileprivate var draftID: UUID?
    private var shownStyle: LayerTextStyle?
    private var synchronizing = false
    private var logicalSize = CGSize(width: 360, height: 160)
    private var handleSize: CGFloat = 6
    private var shownTransform: LayerTransform?
    private struct Geometry: Equatable {
        let transform: LayerTransform
        let logicalSize: CGSize
        let anchor: CGPoint
        let scale: CGFloat
    }
    private var shownGeometry: Geometry?
    private var measuredStyle: LayerTextStyle?
    private var measuredSize: CGSize = .zero
    private var resize: (handle: Int, draft: TextDraft, transform: LayerTransform, start: CGPoint)?
    /// The transform the editor is actually showing. Point text grows as it is typed, so this is not always the
    /// draft's own transform, and a resize has to start from what is on screen or the text jumps.
    override var isFlipped: Bool { true }

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        textView.editor = self
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.setAccessibilityLabel("Canvas text")
        // Both backed by layers from the start. Left to AppKit, the text surface's layer is first placed in the
        // canvas's own layer tree and only moved inside this view a frame later; with a flipped layer, whose
        // mirroring hangs off that placement, the move is visible as a jump.
        wantsLayer = true
        textView.wantsLayer = true
        textView.layer?.anchorPoint = .zero
        addSubview(textView)
        clipsToBounds = false
        // Shown once it has been placed, so a flipped layer never appears for a frame at the unmirrored spot.
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func synchronize(_ draft: TextDraft) {
        guard let canvas, let document = canvas.session.document else { return }
        let fresh = draftID != draft.id
        draftID = draft.id
        let style = draft.style
        let layer = document.layers.first { $0.id == draft.layerID }
        // Point text has no box: it is as big as what has been typed, growing as it is typed.
        if let boxSize = style.boxSize {
            logicalSize = boxSize
        } else {
            if measuredStyle != style {
                measuredSize = EditorSession.textBoxSize(style)
                measuredStyle = style
            }
            logicalSize = measuredSize
        }
        var transform = draft.transform ?? LayerTransform(origin: draft.origin, size: logicalSize)
        // Point text already on a layer grows as it is typed too, keeping whatever scale the layer was given.
        if style.boxSize == nil, draft.transform != nil, let asset = layer?.asset, asset.image.width > 0 {
            let factor = transform.size.width / CGFloat(asset.image.width)
            // A rotated layer turns about its center, so growing it swings its corner away and the text drifts as it
            // is typed. The top-left corner is put back where it was, which is where the commit leaves it too.
            let anchor = transform.point(.zero)
            transform.size = CGSize(width: logicalSize.width * factor, height: logicalSize.height * factor)
            let moved = transform.point(.zero)
            transform.origin.x += anchor.x - moved.x
            transform.origin.y += anchor.y - moved.y
        }
        shownTransform = transform
        let scale = canvas.session.viewport.pointsPerPixel
        let anchor = canvas.session.viewport.viewPoint(from: transform.point(.zero), documentSize: document.size)
        let geometry = Geometry(transform: transform, logicalSize: logicalSize, anchor: anchor, scale: scale)
        if fresh || shownGeometry != geometry {
            // AppKit's frame rotation participates in both drawing and event-coordinate conversion.
            frameRotation = 0
            frame = CGRect(origin: canvas.session.viewport.viewPoint(from: transform.point(.zero), documentSize: document.size),
                           size: CGSize(width: transform.size.width * scale, height: transform.size.height * scale))
            bounds = CGRect(origin: .zero, size: logicalSize)
            // The canvas is flipped, so a positive frame rotation turns the editor clockwise on screen, the way a layer's
            // own rotation is measured. Negating it turned the editor the opposite way from the text it is editing.
            frameRotation = transform.rotation
            // Rotating a flipped NSView can move its logical origin. Keep the layer's top-left pinned.
            let actual = convert(CGPoint.zero, to: canvas)
            setFrameOrigin(CGPoint(x: frame.origin.x + anchor.x - actual.x, y: frame.origin.y + anchor.y - actual.y))
            let padding = LayerTextStyle.padding
            let textFrame = bounds.insetBy(dx: padding, dy: padding)
            if textView.frame != textFrame { textView.frame = textFrame }
            // Mirroring belongs to the text surface, leaving resize handles in their logical order.
            mirror = (transform.flipX, transform.flipY)
            applyMirror()
            handleSize = max(2, 6 / max(0.01, scale * transform.size.width / logicalSize.width))
            shownGeometry = geometry
            needsDisplay = true
        }
        if shownStyle != style {
            synchronizing = true
            let selection = textView.selectedRange()
            if textView.string != style.content { textView.string = style.content }
            let attributes = EditorSession.textAttributes(style)
            textView.typingAttributes = attributes
            if !textView.hasMarkedText() {
                textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textView.string.utf16.count))
                textView.setSelectedRange(NSRange(location: min(selection.location, textView.string.utf16.count),
                    length: min(selection.length, max(0, textView.string.utf16.count - selection.location))))
            }
            textView.insertionPointColor = (attributes[.foregroundColor] as? NSColor) ?? .white
            shownStyle = style
            synchronizing = false
            needsDisplay = true
        }
        if isHidden { isHidden = false }
        if fresh {
            textView.undoManager?.removeAllActions()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.canvas?.session.textDraft?.id == draft.id else { return }
                if self.window?.firstResponder is NSText, self.window?.firstResponder !== self.textView { return }
                self.window?.makeFirstResponder(self.textView)
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !synchronizing, let session = canvas?.session, var draft = session.textDraft else { return }
        draft.style.content = textView.string
        shownStyle = draft.style
        session.textDraft = draft
        // NSTextView draws the changed glyphs itself. Refresh the box's overflow marker
        // without resetting the text container's geometry on every keystroke.
        needsDisplay = true
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        textView.string.utf16.count - affectedCharRange.length + (replacementString?.utf16.count ?? 0) <= 100_000
    }

    private var handleTracking: NSTrackingArea?
    /// Mirrors the text surface for a flipped layer, about the middle of the surface. A layer transform turns
    /// about its anchor point, and AppKit sets that (and the layer's position) when it lays the view out, so this
    /// runs again after every layout and once more before drawing.
    private var mirror: (x: Bool, y: Bool) = (false, false)
    private func applyMirror() {
        guard let layer = textView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard mirror.x || mirror.y else {
            if !layer.affineTransform().isIdentity { layer.setAffineTransform(.identity) }
            return
        }
        // Placed by hand: until AppKit has laid this view out, the text surface's layer is still positioned in the
        // canvas's coordinates, and mirroring about a layer that is somewhere else is a jump on the first frame.
        layer.anchorPoint = .zero
        layer.bounds = CGRect(origin: .zero, size: textView.bounds.size)
        layer.position = textView.frame.origin
        let shift = CGPoint(x: mirror.x ? textView.bounds.width : 0, y: mirror.y ? textView.bounds.height : 0)
        layer.setAffineTransform(CGAffineTransform(translationX: shift.x, y: shift.y)
            .scaledBy(x: mirror.x ? -1 : 1, y: mirror.y ? -1 : 1))
    }
    override func layout() {
        super.layout()
        applyMirror()
    }
    override func viewWillDraw() {
        super.viewWillDraw()
        // Attaching the text surface's layer into this view's layer tree clears its transform, and that happens
        // after everything else: without this, a flipped layer's first frame is drawn unmirrored.
        applyMirror()
    }

    /// The cursor follows the same test the mouse does: arrows over the edges and corners, the I-beam over the
    /// text. Cursor rects are no use here — the box can be rotated, and AppKit does not map them through a
    /// view's rotation — so this view watches the pointer itself.
    private var cursorTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow,
                                                         .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self)
        addTrackingArea(area)
        cursorTracking = area
    }
    override func mouseEntered(with event: NSEvent) { showCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { showCursor(at: convert(event.locationInWindow, from: nil)) }
    override func cursorUpdate(with event: NSEvent) { showCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { NSCursor.iBeam.set() }
    private func showCursor(at point: CGPoint) {
        guard resize == nil, canvas?.session.colorPicker == nil else { return }
        guard let index = handle(at: point) else { NSCursor.iBeam.set(); return }
        handleCursor(index).set()
    }

    /// Every mouse move while the box is open, wherever the pointer is. Tracking areas stop arriving once the text
    /// surface has the mouse, which left the cursor stuck on whatever it was last set to.
    private var moveMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor); self.moveMonitor = nil }
        guard window != nil else { return }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, self.window === event.window else { return event }
            self.showCursor(at: self.convert(event.locationInWindow, from: nil))
            return event
        }
    }
    deinit {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
    }

    /// The arrows for the edge or corner a handle resizes, turned with the text box.
    private func handleCursor(_ index: Int) -> NSCursor {
        guard #available(macOS 15.0, *) else { return .resizeLeftRight }
        let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .topLeft, .top, .topRight, .right]
        let rotation = canvas?.session.textDraft?.transform?.rotation ?? 0
        let turns = (Int((rotation / 45).rounded()) % 8 + 8) % 8
        let ordered: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right]
        let position = ordered[(ordered.firstIndex(of: positions[index])! + turns) % 4]
        return .frameResize(position: position, directions: [.inward, .outward])
    }

    /// How far either side of an edge counts as that edge, in the box's own units. Capped so a small box keeps a
    /// middle to type in.
    /// The Move tool's box grabs within 10 screen points of an edge; the handles here are drawn 6 points across, so
    /// the same reach is 10/6 of one.
    private var edgeReach: CGFloat { min(handleSize * 10 / 6, min(bounds.width, bounds.height) / 3) }

    /// The edge or corner at a point, in handle order: a band along each edge, as the Move tool's box has, rather
    /// than only the handle squares. Nil anywhere else, which is the text.
    private func handle(at point: CGPoint) -> Int? {
        let reach = edgeReach
        let left = point.x <= reach, right = point.x >= bounds.width - reach
        let top = point.y <= reach, bottom = point.y >= bounds.height - reach
        guard point.x >= -reach, point.x <= bounds.width + reach,
              point.y >= -reach, point.y <= bounds.height + reach else { return nil }
        switch (left, right, top, bottom) {
        case (true, _, true, _): return 0
        case (_, true, true, _): return 2
        case (_, true, _, true): return 4
        case (true, _, _, true): return 6
        case (_, _, true, _): return 1
        case (_, true, _, _): return 3
        case (_, _, _, true): return 5
        case (true, _, _, _): return 7
        default: return nil
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if canvas?.session.colorPicker != nil { return nil }
        let local = convert(point, from: superview)
        if handle(at: local) != nil { return self }
        return super.hitTest(point)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let box = NSBezierPath(rect: bounds.insetBy(dx: handleSize / 12, dy: handleSize / 12))
        box.lineWidth = handleSize / 6
        box.stroke()
        for unit in LayerTransform.handles {
            let rect = CGRect(x: unit.x * bounds.width - handleSize / 2, y: unit.y * bounds.height - handleSize / 2,
                              width: handleSize, height: handleSize)
            NSColor.white.setFill(); rect.fill()
            NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: rect).stroke()
        }
        // Text that doesn't fit is marked by a plus drawn in the bottom-right handle, as in Photoshop.
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            let range = layout.glyphRange(for: container)
            if NSMaxRange(range) < layout.numberOfGlyphs {
                let unit = LayerTransform.handles[4]
                let center = CGPoint(x: unit.x * bounds.width, y: unit.y * bounds.height)
                let arm = handleSize * 0.42
                let plus = NSBezierPath()
                plus.move(to: CGPoint(x: center.x - arm, y: center.y)); plus.line(to: CGPoint(x: center.x + arm, y: center.y))
                plus.move(to: CGPoint(x: center.x, y: center.y - arm)); plus.line(to: CGPoint(x: center.x, y: center.y + arm))
                plus.lineWidth = handleSize / 6
                NSColor.black.setStroke()
                plus.stroke()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let canvas, let document = canvas.session.document, let draft = canvas.session.textDraft,
              let handle = handle(at: convert(event.locationInWindow, from: nil)) else { return }
        let transform = shownTransform ?? draft.transform ?? LayerTransform(origin: draft.origin, size: logicalSize)
        let pixel = canvas.session.viewport.documentPoint(from: canvas.convert(event.locationInWindow, from: nil), documentSize: document.size)
        // Dragging a handle turns point text into a box of the size it has right now, which then holds the text and
        // wraps it, rather than scaling the text. Its scale and rotation are whatever the layer already had.
        var fixed = draft
        if fixed.style.boxSize == nil {
            fixed.style.boxSize = logicalSize
            fixed.transform = transform
            fixed.origin = transform.origin
            canvas.session.textDraft = fixed
        }
        resize = (handle, fixed, transform, pixel)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let resize, let canvas, let document = canvas.session.document else { return }
        let point = canvas.session.viewport.documentPoint(from: canvas.convert(event.locationInWindow, from: nil), documentSize: document.size)
        let old = resize.transform
        let dx = point.x - resize.start.x, dy = point.y - resize.start.y
        let localX = dx * cos(old.radians) + dy * sin(old.radians)
        let localY = -dx * sin(old.radians) + dy * cos(old.radians)
        let unit = LayerTransform.handles[resize.handle]
        var left: CGFloat = 0, top: CGFloat = 0, right = old.size.width, bottom = old.size.height
        let source = resize.draft.style.boxSize ?? logicalSize
        let minW = 16 * old.size.width / source.width, minH = 16 * old.size.height / source.height
        if unit.x == 0 { left = min(localX, right - minW) }
        if unit.x == 1 { right = max(left + minW, right + localX) }
        if unit.y == 0 { top = min(localY, bottom - minH) }
        if unit.y == 1 { bottom = max(top + minH, bottom + localY) }
        var draft = resize.draft
        draft.style.boxSize = CGSize(width: ((right - left) * source.width / old.size.width).rounded(),
                                     height: ((bottom - top) * source.height / old.size.height).rounded())
        guard draft.style.boxIsValid else { return }
        var transform = old
        transform.size = CGSize(width: draft.style.boxSize!.width * old.size.width / source.width,
                                height: draft.style.boxSize!.height * old.size.height / source.height)
        let anchor = old.point(CGPoint(x: left / old.size.width, y: top / old.size.height))
        let current = transform.point(.zero)
        transform.origin.x += anchor.x - current.x
        transform.origin.y += anchor.y - current.y
        guard transform.isValid else { return }
        draft.origin = transform.origin
        draft.transform = transform
        canvas.session.textDraft = draft
        canvas.synchronizeDisplay()
    }
    override func mouseUp(with event: NSEvent) { resize = nil; window?.makeFirstResponder(textView) }
}

extension CanvasView {
    func synchronizeInlineText() {
        guard let draft = session.textDraft else {
            if inlineTextEditor != nil {
                let hadFocus = window?.firstResponder === inlineTextEditor?.textView
                inlineTextEditor?.removeFromSuperview()
                inlineTextEditor = nil
                needsDisplay = true
                if hadFocus { window?.makeFirstResponder(self) }
            }
            return
        }
        if inlineTextEditor?.draftID != draft.id { needsDisplay = true }
        if inlineTextEditor == nil {
            let editor = InlineTextEditor(canvas: self)
            inlineTextEditor = editor
            addSubview(editor)
            needsDisplay = true
        }
        inlineTextEditor?.synchronize(draft)
    }

    func beginTextGesture(at point: CGPoint, event: NSEvent) {
        guard let document = session.document, session.finishText() else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        let visible = document.effectiveVisibleIDs
        if let layer = document.layers.reversed().first(where: { visible.contains($0.id) && $0.liveText != nil && $0.transform.contains(pixel) }) {
            session.selectLayer(layer.id)
            session.editActiveText()
            synchronizeInlineText()
            inlineTextEditor?.textView.mouseDown(with: event)
        } else {
            textBoxAnchor = pixel
            textBoxRect = CGRect(origin: pixel, size: .zero)
        }
        needsDisplay = true
    }

    func dragTextGesture(to point: CGPoint) {
        guard let anchor = textBoxAnchor, let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        textBoxRect = DragBox.rect(from: anchor, to: pixel, square: false, fromCenter: false)
        needsDisplay = true
    }

    func finishTextGesture() {
        guard let rect = textBoxRect else { return }
        textBoxAnchor = nil; textBoxRect = nil
        if rect.width < 4 && rect.height < 4 { session.beginText(at: rect.origin, newLayer: true) }
        else { session.beginText(in: rect) }
        synchronizeInlineText()
        needsDisplay = true
    }

    func drawTextBoxDraft() {
        guard let rect = textBoxRect, let document = session.document else { return }
        let origin = session.viewport.viewPoint(from: rect.origin, documentSize: document.size)
        let scale = session.viewport.pointsPerPixel
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: CGRect(origin: origin, size: CGSize(width: rect.width * scale, height: rect.height * scale)))
        path.lineWidth = 1
        path.stroke()
    }
}
