import UIKit

/// The text being typed, on the canvas, as the Mac's InlineTextEditor has it: UIKit's text system edits it — selection,
/// marked text and dictation, Scribble, the clipboard, the text's own undo — in a box laid over the canvas, scaled and
/// turned with the layer. Its glyphs are clear: the canvas draws the text underneath as the layer's own pixels, so
/// what is typed looks the same at any zoom as it will once it's committed. A finger on an edge of the box resizes it.
final class PadTextEditor: UIView, UITextViewDelegate {
    let session: EditorSession
    /// Laid out by TextKit 1, as the text is drawn and measured (see `EditorSession.textImage`), so the caret and the
    /// selection sit on the glyphs the canvas draws. The text view holds only its container; the storage is kept here.
    let textView: PadCanvasTextView
    private let storage = NSTextStorage()
    private(set) var draftID: UUID?
    /// Where the editor shows the text, which the canvas draws it at.
    private(set) var shownTransform: LayerTransform?
    /// Something the canvas draws changed here, the box's size, say.
    var changed: () -> Void = {}
    /// How far a finger may land from an edge of the box to resize it, in screen points.
    static let reach: CGFloat = 22

    /// The style the text view shows; a change from elsewhere, the bar's, is put back into it.
    private var shownStyle: LayerTextStyle?
    /// The style after a change UIKit has accepted but not yet made, with its color and face runs moved to fit.
    private var pendingStyle: LayerTextStyle?
    private var synchronizing = false
    private var logicalSize = CGSize(width: 360, height: 160)
    private var measured: (style: LayerTextStyle, size: CGSize)?
    /// Screen points to a unit of the box, which its handles are drawn and reached by.
    private var pointsPerUnit: CGFloat = 1
    /// The box, in the text's own units. The view reaches a handle's width past it all round, as UIKit draws a view only
    /// within its bounds.
    private var box: CGRect { CGRect(origin: .zero, size: logicalSize) }
    /// The handles' size, 8 screen points across, in the box's units.
    private var handleSize: CGFloat { max(2, 8 / pointsPerUnit) }
    private var resize: (handle: Int, draft: TextDraft, transform: LayerTransform, start: CGPoint)?
    /// A touch has put the caret, so opening existing text leaves it there rather than after the text.
    private var caretPlaced = false

    init(session: EditorSession) {
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        container.heightTracksTextView = true
        layout.addTextContainer(container)
        textView = PadCanvasTextView(frame: .zero, textContainer: container)
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false
        textView.editor = self
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        // Typed as it's typed, as on the Mac: nothing corrected, capitalized or underlined on the canvas.
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.accessibilityLabel = "Canvas text"
        addSubview(textView)
        // Shown once it has been placed, so it never appears for a moment where it doesn't belong.
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func synchronize(_ draft: TextDraft) {
        guard let document = session.document else { return }
        let fresh = draftID != draft.id
        draftID = draft.id
        if fresh { caretPlaced = false }
        let style = draft.style
        // Point text has no box: it is as big as what has been typed, growing as it is typed.
        if let boxSize = style.boxSize {
            logicalSize = boxSize
        } else {
            if measured?.style != style { measured = (style, EditorSession.textBoxSize(style)) }
            logicalSize = measured?.size ?? logicalSize
        }
        let layer = document.layers.first { $0.id == draft.layerID }
        let transform = draft.shownTransform(logicalSize: logicalSize, layerWidth: layer?.asset?.image.width)
        shownTransform = transform
        place(transform, in: document)
        if shownStyle != style { show(style) }
        if isHidden { isHidden = false }
        if fresh {
            textView.undoManager?.removeAllActions()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session.textDraft?.id == draft.id else { return }
                self.textView.becomeFirstResponder()
                // Opening existing text puts the caret after it, ready to add to it, unless a touch already placed it.
                if draft.layerID != nil, !self.caretPlaced {
                    self.textView.selectedRange = NSRange(location: self.textView.text.utf16.count, length: 0)
                }
            }
        }
    }

    /// The box in the text's own units, scaled to the canvas and turned with the layer, its text mirrored for a flipped
    /// layer while the handles stay in their order.
    private func place(_ transform: LayerTransform, in document: CanvasDocument) {
        let scale = session.viewport.pointsPerPixel
        let sx = transform.size.width * scale / logicalSize.width, sy = transform.size.height * scale / logicalSize.height
        pointsPerUnit = max(0.01, sx)
        self.transform = .identity
        bounds = box.insetBy(dx: -handleSize, dy: -handleSize)
        center = session.viewport.viewPoint(from: transform.center, documentSize: document.size)
        self.transform = CGAffineTransform(rotationAngle: transform.radians).scaledBy(x: sx, y: sy)
        // The box's lines are drawn at the size they're shown.
        contentScaleFactor = min(8, max(1, traitCollection.displayScale * sx))
        let padding = LayerTextStyle.padding
        textView.transform = .identity
        textView.bounds = CGRect(x: 0, y: 0, width: max(1, logicalSize.width - padding * 2), height: max(1, logicalSize.height - padding * 2))
        textView.center = CGPoint(x: logicalSize.width / 2, y: logicalSize.height / 2)
        textView.transform = CGAffineTransform(scaleX: transform.flipX ? -1 : 1, y: transform.flipY ? -1 : 1)
        setNeedsDisplay()
    }

    /// The style in the text view: its letters and faces, clear, and the caret in the color it types.
    private func show(_ style: LayerTextStyle) {
        synchronizing = true
        defer { synchronizing = false }
        let selection = textView.selectedRange
        if textView.text != style.content { textView.text = style.content }
        var attributes = EditorSession.textAttributes(style)
        attributes[.foregroundColor] = UIColor.clear
        let length = textView.text.utf16.count
        if textView.markedTextRange == nil {
            textView.textStorage.setAttributes(attributes, range: NSRange(location: 0, length: length))
            for run in style.fontRuns ?? [] where EditorSession.containsTextRun(run.location, run.length, in: length) {
                let font = UIFont(name: run.fontName, size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
                textView.textStorage.addAttribute(.font, value: font, range: NSRange(location: run.location, length: run.length))
            }
            textView.selectedRange = NSRange(location: min(selection.location, length),
                                             length: min(selection.length, max(0, length - selection.location)))
        }
        let caret = selection.length > 0 ? selection.location : max(0, selection.location - 1)
        attributes[.font] = UIFont(name: style.fontName(at: caret), size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
        textView.typingAttributes = attributes
        shownStyle = style
        updateCaretColor(style)
        setNeedsDisplay()
    }

    /// Puts the caret at `point`, in the text view's coordinates, as a tap on text opening it does.
    func placeCaret(at point: CGPoint) {
        guard let position = textView.closestPosition(to: point) else { return }
        textView.selectedTextRange = textView.textRange(from: position, to: position)
        caretPlaced = true
    }

    private func updateCaretColor(_ style: LayerTextStyle) {
        let location = textView.selectedRange.location
        let color = style.color(at: location > 0 ? location - 1 : 0)
        textView.tintColor = UIColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    // MARK: Typing

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView.text.utf16.count - range.length + text.utf16.count <= 100_000 else { return false }
        if !synchronizing, let style = session.textStyle(replacing: range, with: text, after: pendingStyle) { pendingStyle = style }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !synchronizing,
              let draft = session.textDraft(changedTo: textView.text, selection: textView.selectedRange, pending: pendingStyle) else { return }
        pendingStyle = nil
        shownStyle = draft.style
        session.textDraft = draft
        // UIKit lays the letters out itself; the box's marker for text that doesn't fit may change.
        setNeedsDisplay()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !synchronizing, session.textDraft?.id == draftID else { return }
        let selection = textView.selectedRange
        if session.textDraft?.selection != selection { session.textDraft?.selection = selection }
        if let style = session.textDraft?.style { updateCaretColor(style) }
    }

    // MARK: The box

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let handle = handleSize, box = box
        let accent = Platform.accentColor.cgColor
        context.setStrokeColor(accent)
        context.setLineWidth(handle / 6)
        context.stroke(box.insetBy(dx: handle / 12, dy: handle / 12))
        for unit in LayerTransform.handles {
            let square = CGRect(x: unit.x * box.width - handle / 2, y: unit.y * box.height - handle / 2, width: handle, height: handle)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(square)
            context.setStrokeColor(accent)
            context.stroke(square)
        }
        // Text that doesn't fit is marked by a plus drawn in the bottom-right handle, as in Photoshop.
        let layout = textView.layoutManager
        layout.ensureLayout(for: textView.textContainer)
        if NSMaxRange(layout.glyphRange(for: textView.textContainer)) < layout.numberOfGlyphs {
            let unit = LayerTransform.handles[4]
            let center = CGPoint(x: unit.x * box.width, y: unit.y * box.height)
            let arm = handle * 0.42
            context.move(to: CGPoint(x: center.x - arm, y: center.y))
            context.addLine(to: CGPoint(x: center.x + arm, y: center.y))
            context.move(to: CGPoint(x: center.x, y: center.y - arm))
            context.addLine(to: CGPoint(x: center.x, y: center.y + arm))
            context.setStrokeColor(UIColor.black.cgColor)
            context.strokePath()
        }
    }

    /// How far either side of an edge counts as that edge, in the box's own units: a finger's reach, capped so a small
    /// box keeps a middle to type in.
    private var edgeReach: CGFloat { min(Self.reach / pointsPerUnit, min(box.width, box.height) / 3) }

    /// The edge or corner at a point, in handle order: a band along each edge, as the Mac's box has. Nil anywhere else,
    /// which is the text.
    private func handle(at point: CGPoint) -> Int? {
        let reach = edgeReach, box = box
        guard point.x >= -reach, point.x <= box.width + reach, point.y >= -reach, point.y <= box.height + reach else { return nil }
        let left = point.x <= reach, right = point.x >= box.width - reach
        let top = point.y <= reach, bottom = point.y >= box.height - reach
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

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        box.insetBy(dx: -edgeReach, dy: -edgeReach).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event) else { return nil }
        if handle(at: point) != nil { return self }
        return super.hitTest(point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard resize == nil, let touch = touches.first, let canvas = superview, let document = session.document,
              let draft = session.textDraft, let handle = handle(at: touch.location(in: self)) else { return }
        let transform = shownTransform ?? draft.transform ?? LayerTransform(origin: draft.origin, size: logicalSize)
        let pixel = session.viewport.documentPoint(from: touch.location(in: canvas), documentSize: document.size)
        // A handle turns point text into a box of the size it has right now, which then holds the text and wraps it,
        // rather than scaling it.
        let fixed = draft.boxed(logicalSize: logicalSize, shown: transform)
        if draft.style.boxSize == nil { session.textDraft = fixed }
        resize = (handle, fixed, transform, pixel)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let resize, let touch = touches.first, let canvas = superview, let document = session.document else { return }
        let point = session.viewport.documentPoint(from: touch.location(in: canvas), documentSize: document.size)
        guard let draft = resize.draft.resized(handle: resize.handle, from: resize.transform, start: resize.start, to: point) else { return }
        session.textDraft = draft
        changed()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { endResize() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { endResize() }
    private func endResize() {
        guard resize != nil else { return }
        resize = nil
        textView.becomeFirstResponder()
    }
}

/// The text view the editor types into. Escape puts the text back as it was and ⌘Return keeps it, as on the Mac.
final class PadCanvasTextView: UITextView {
    weak var editor: PadTextEditor?
    /// Undo and Redo take back what was typed since the text opened, as the Mac's do, apart from the project's history.
    private let textUndo = UndoManager()
    override var undoManager: UndoManager? { textUndo }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey(_:))),
         UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commandReturnKey(_:)))]
    }
    @objc private func escapeKey(_ command: UIKeyCommand) { editor?.session.cancelText() }
    @objc private func commandReturnKey(_ command: UIKeyCommand) { _ = editor?.session.finishText() }
}
