import Metal
import QuartzCore
import UIKit

/// The GPU canvas's surface on iPad: a Metal layer under the canvas's overlays, as the Mac's `MetalCanvasView` is.
final class MetalCanvasView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        metalLayer.device = GPUCanvasRenderer.shared?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Core Image writes the frame with a compute pass.
        metalLayer.framebufferOnly = false
        metalLayer.presentsWithTransaction = true
        metalLayer.isOpaque = true
        isOpaque = true
        // Touches go to the canvas behind it.
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Sizes the drawable to the view in screen pixels.
    func fit(scale: CGFloat) {
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }
}
