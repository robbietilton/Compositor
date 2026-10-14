import UIKit

/// The Eyedropper's ring while it samples, as the Mac's sample ring: the color under the touch above, the foreground
/// color it replaces below. On iPad it matters more than on the Mac, as the finger hides the pixel it's on.
final class SampleRingView: UIView {
    var original = PaletteColor.black { didSet { setNeedsDisplay() } }
    var sampled = PaletteColor.black { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Around `point`, at the Mac's size.
    func show(at point: CGPoint) {
        frame = CGRect(x: point.x - 58, y: point.y - 58, width: 116, height: 116)
        isHidden = false
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let ring = UIBezierPath(ovalIn: bounds.insetBy(dx: 15, dy: 15))
        ring.lineWidth = 24
        UIColor(white: 0.45, alpha: 1).setStroke()
        ring.stroke()
        ring.lineWidth = 16
        for (color, y) in [(sampled, CGFloat(0)), (original, bounds.midY)] {
            context.saveGState()
            UIBezierPath(rect: CGRect(x: 0, y: y, width: bounds.width, height: bounds.height / 2)).addClip()
            UIColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).setStroke()
            ring.stroke()
            context.restoreGState()
        }
    }
}
