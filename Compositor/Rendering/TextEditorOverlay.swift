import AppKit

@MainActor
final class TextEditorOverlay: NSView, NSTextViewDelegate {
    let session: EditorSession
    var didChange: (() -> Void)?
    private var displayedDraft: TextDraft?
    private weak var editor: EditingTextView?
    private var appliedFlipX = false
    private var appliedFlipY = false
    private var appliedFlipSize = CGSize.zero

    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.12).cgColor
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func synchronize(documentSize: CGSize, viewport: CanvasViewport) {
        guard let draft = session.textDraft else {
            isHidden = true
            displayedDraft?.layout.suppressesEditorGlyphs = false
            displayedDraft = nil
            if let editor { resetNativeFlips(on: editor) }
            editor?.removeFromSuperview()
            editor = nil
            return
        }
        if displayedDraft !== draft {
            if let editor { resetNativeFlips(on: editor) }
            editor?.removeFromSuperview()
            guard let view = draft.layout.makeTextView() as? EditingTextView else { return }
            view.commit = { [weak self] in _ = self?.session.commitText(); self?.didChange?() }
            view.cancel = { [weak self] in self?.session.cancelText(); self?.didChange?() }
            view.delegate = self
            addSubview(view)
            editor = view
            displayedDraft = draft
            DispatchQueue.main.async { [weak self, weak view] in self?.window?.makeFirstResponder(view) }
        }
        guard let editor else { return }
        draft.layout.suppressesEditorGlyphs = draft.layerID != nil && draft.previewImage != nil
        editor.needsDisplay = true
        resetNativeFlips(on: editor)
        let natural = draft.layout.naturalSize()
        let transform = draft.transform
        let isEmpty = session.textStyle.content.isEmpty
        let minimumHeight = isEmpty
            ? max(natural.height, session.textStyle.fontSizePoints * max(1, draft.layout.resolution) / 72 * 1.35)
            : natural.height
        let isEmptyPointText = isEmpty && session.textStyle.layout == .point
        let minimumWidth = isEmptyPointText ? max(natural.width, 160) : natural.width
        let editingSize = CGSize(width: minimumWidth, height: minimumHeight)
        editor.frame = CGRect(origin: .zero, size: editingSize)
        bounds = CGRect(origin: .zero, size: editingSize)
        let scaleX = transform.size.width / max(1, natural.width)
        let scaleY = transform.size.height / max(1, natural.height)
        let viewSize = CGSize(width: editingSize.width * scaleX * viewport.pointsPerPixel,
                              height: editingSize.height * scaleY * viewport.pointsPerPixel)
        let center = viewport.viewPoint(from: CGPoint(
            x: transform.origin.x + editingSize.width * scaleX / 2,
            y: transform.origin.y + editingSize.height * scaleY / 2
        ), documentSize: documentSize)
        frameCenterRotation = 0
        frame = CGRect(x: center.x - viewSize.width / 2, y: center.y - viewSize.height / 2,
                       width: viewSize.width, height: viewSize.height)
        frameCenterRotation = transform.rotation
        // Set bounds after frame rotation. AppKit otherwise shifts the center when frame and bounds
        // have different aspect ratios (non-uniformly scaled text).
        bounds = CGRect(origin: .zero, size: editingSize)
        applyNativeFlips(x: transform.flipX, y: transform.flipY, size: editingSize, to: editor)
        isHidden = false
    }

    /// NSView's bounds transform, unlike a CALayer-only reflection, also maps mouse events and the caret.
    private func applyNativeFlips(x: Bool, y: Bool, size: CGSize, to view: NSView) {
        guard x || y else { return }
        view.translateOrigin(to: CGPoint(x: x ? size.width : 0, y: y ? size.height : 0))
        view.scaleUnitSquare(to: CGSize(width: x ? -1 : 1, height: y ? -1 : 1))
        appliedFlipX = x
        appliedFlipY = y
        appliedFlipSize = size
    }

    private func resetNativeFlips(on view: NSView) {
        guard appliedFlipX || appliedFlipY else { return }
        view.translateOrigin(to: CGPoint(x: appliedFlipX ? appliedFlipSize.width : 0,
                                         y: appliedFlipY ? appliedFlipSize.height : 0))
        view.scaleUnitSquare(to: CGSize(width: appliedFlipX ? -1 : 1, height: appliedFlipY ? -1 : 1))
        appliedFlipX = false
        appliedFlipY = false
        appliedFlipSize = .zero
    }

    func textDidChange(_ notification: Notification) {
        session.textDidChange()
        didChange?()
    }
}

@MainActor
final class EditingTextView: NSTextView {
    var commit: (() -> Void)?
    var cancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !hasMarkedText() { cancel?(); return }
        if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.command), !hasMarkedText() {
            commit?(); return
        }
        super.keyDown(with: event)
    }
}
