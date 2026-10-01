import UIKit

/// The line along the foot of the window, as on the Mac: the zoom, the canvas's size and color space, and on the
/// right what the tool in hand does, or what the editor is busy with.
final class StatusBarView: UIView {
    var session: EditorSession? { didSet { if session !== oldValue { setNeedsUpdateProperties() } } }
    /// Whether a finger paints; once Apple Pencil has, fingers move the canvas instead, and the hints say so.
    var fingerPaints = true { didSet { setNeedsUpdateProperties() } }

    static let height: CGFloat = 30

    private let zoom = StatusBarView.label()
    private let size = StatusBarView.label()
    private let space = StatusBarView.label()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let hint = StatusBarView.label()

    override init(frame: CGRect) {
        super.init(frame: frame)
        zoom.widthAnchor.constraint(equalToConstant: 62).isActive = true
        hint.textAlignment = .right
        hint.lineBreakMode = .byTruncatingHead
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        let leading = UIStackView(arrangedSubviews: [zoom, size, space])
        leading.spacing = 16
        let trailing = UIStackView(arrangedSubviews: [spinner, hint])
        trailing.spacing = 6
        let row = UIStackView(arrangedSubviews: [leading, UIView(), trailing])
        row.spacing = 16
        row.alignment = .center
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.heightAnchor.constraint(equalToConstant: Self.height),
        ])
        leading.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessibilityElements = [zoom, size, space, hint]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateProperties() {
        super.updateProperties()
        guard let session else { return }
        if let document = session.document {
            zoom.text = Double(session.viewport.zoom).formatted(.percent.precision(.fractionLength(0...1)))
            size.text = "\(document.width) × \(document.height) px"
            space.text = "sRGB · Transparent"
        } else {
            zoom.text = nil
            size.text = "Ready when you are"
            space.text = nil
        }
        for label in [zoom, size, space] { label.isHidden = label.text == nil }
        if session.showsBusy || session.isImporting {
            spinner.startAnimating()
            hint.text = session.showsBusy ? "Working…" : "Importing images…"
        } else {
            spinner.stopAnimating()
            hint.text = session.document == nil ? nil : Self.hint(for: session, fingerPaints: fingerPaints)
        }
    }

    /// What the tool in hand does, as the Mac's status bar says it, for touch.
    static func hint(for session: EditorSession, fingerPaints: Bool) -> String {
        let fingers = fingerPaints ? "Two fingers move and zoom" : "Fingers move and zoom"
        let pencil = fingerPaints ? "Drag" : "Draw with Apple Pencil"
        switch session.tool {
        case .brush:
            return "\(pencil) to \(session.brushMode == .erase ? "erase" : "paint") · \(fingers)"
        case .spotHealing:
            return "\(pencil) over blemishes to heal · \(fingers)"
        case .cloneStamp where session.cloneSource == nil:
            return (fingerPaints ? "Tap" : "Tap with Apple Pencil") + " where to copy from · \(fingers)"
        case .cloneStamp:
            return "\(pencil) to clone · Drag the crosshair, or Option-tap, to copy from elsewhere · \(fingers)"
        case .blur:
            let action = session.blurMode == .blur ? "soften" : session.blurMode == .smudge ? "smudge" : "push pixels"
            return "\(pencil) to \(action) · \(fingers)"
        case .move:
            // A finger moves layers whether or not it paints.
            let move = session.transformAutoSelect ? "Drag on a layer to select and move it" : "Drag to move the layer"
            let handles = session.showsTransformControls ? " · Handles to resize · Circle to rotate" : ""
            return move + handles + " · Two fingers move and zoom"
        case .marquee:
            return "Drag \(session.marqueeKind == .ellipse ? "an ellipse" : "a rectangle") · Drag inside to move it · Two fingers move and zoom"
        case .lasso where session.lassoKind == .polygonal:
            return "Tap corners · Tap the first corner or double-tap to close · Two fingers move and zoom"
        case .lasso:
            return "Draw around what to select · Drag inside to move it · Two fingers move and zoom"
        case .wand:
            let tap = session.wandMode == .object ? "Tap an object to select it" : "Tap to select similar colors"
            return "\(tap) · Drag inside to move it · Two fingers move and zoom"
        case .crop:
            return "Drag a frame, or its edges · Drag inside to move it · Two fingers move and zoom"
        case .gradient:
            return (fingerPaints ? "Drag out a gradient" : "Drag out a gradient with Apple Pencil") + ", or move one of its ends · \(fingers)"
        case .shape:
            let shape = session.shapeKind == .ellipse ? "an ellipse" : "a " + session.shapeKind.rawValue.lowercased()
            return "Drag out \(shape)\(fingerPaints ? "" : " with Apple Pencil") · \(fingers)"
        case .type where session.textDraft != nil:
            return "Type · Drag the box's edges to wrap the text · Done keeps it, Cancel puts it back"
        case .type:
            return "Tap to type · Drag a box for a paragraph · Tap text to edit it · Two fingers move and zoom"
        case .eyedropper:
            return "Touch to pick up a color · Two fingers move and zoom"
        case .hand:
            return "Drag to pan · Pinch to zoom"
        case .zoom:
            return "Tap to zoom in · Drag right or left to zoom smoothly"
        case .idle:
            return "No tool selected"
        }
    }

    private static func label() -> UILabel {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        return label
    }
}
