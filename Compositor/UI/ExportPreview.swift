import SwiftUI
import AppKit

/// A full-resolution encoded preview. Zoom changes only the viewport, never the exported pixels.
struct ExportPreview: NSViewRepresentable {
    let image: CGImage?
    let imageSize: CGSize
    let zoom: Double

    func makeNSView(context: Context) -> PreviewScrollView {
        PreviewScrollView()
    }

    func updateNSView(_ view: PreviewScrollView, context: Context) {
        view.update(image: image, size: imageSize, zoom: zoom)
    }

    final class PreviewScrollView: NSScrollView {
        private let surface = PreviewSurface()
        private var imageSize = CGSize.zero
        private var zoom: CGFloat = 1

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            drawsBackground = false
            hasHorizontalScroller = true
            hasVerticalScroller = true
            autohidesScrollers = true
            scrollerStyle = .overlay
            documentView = surface
            setAccessibilityLabel("Export preview")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(image: CGImage?, size: CGSize, zoom newZoom: Double) {
            let oldRect = surface.imageRect
            let visible = contentView.bounds
            let center = CGPoint(x: (visible.midX - oldRect.minX) / zoom,
                                 y: (visible.midY - oldRect.minY) / zoom)
            let firstImage = imageSize == .zero
            imageSize = size
            zoom = newZoom
            surface.image = image
            resizeSurface()
            let focus = firstImage ? CGPoint(x: size.width / 2, y: size.height / 2) : center
            let origin = CGPoint(x: surface.imageRect.minX + focus.x * zoom - visible.width / 2,
                                 y: surface.imageRect.minY + focus.y * zoom - visible.height / 2)
            contentView.scroll(to: contentView.constrainBoundsRect(CGRect(origin: origin, size: visible.size)).origin)
            reflectScrolledClipView(contentView)
            surface.needsDisplay = true
        }

        override func layout() {
            super.layout()
            resizeSurface()
        }

        private func resizeSurface() {
            let size = CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)
            let viewport = contentView.bounds.size
            surface.setFrameSize(CGSize(width: max(size.width, viewport.width), height: max(size.height, viewport.height)))
            surface.imageRect = CGRect(x: (surface.bounds.width - size.width) / 2,
                                       y: (surface.bounds.height - size.height) / 2,
                                       width: size.width, height: size.height)
        }
    }

    final class PreviewSurface: NSView {
        var image: CGImage?
        var imageRect = CGRect.zero
        private var dragPoint = CGPoint.zero
        override var isFlipped: Bool { true }

        override func resetCursorRects() {
            addCursorRect(visibleRect, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            dragPoint = event.locationInWindow
            NSCursor.closedHand.push()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let scroll = enclosingScrollView else { return }
            let point = event.locationInWindow
            var bounds = scroll.contentView.bounds
            bounds.origin.x -= point.x - dragPoint.x
            bounds.origin.y += point.y - dragPoint.y
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            dragPoint = point
        }

        override func mouseUp(with event: NSEvent) { NSCursor.pop() }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.setFillColor(NSColor(white: 0.24, alpha: 1).cgColor)
            context.fill(dirtyRect)
            context.setFillColor(NSColor(white: 0.32, alpha: 1).cgColor)
            for row in Int(floor(dirtyRect.minY / 12))..<Int(ceil(dirtyRect.maxY / 12)) {
                for column in Int(floor(dirtyRect.minX / 12))..<Int(ceil(dirtyRect.maxX / 12))
                    where (row + column).isMultiple(of: 2) {
                    context.fill(CGRect(x: column * 12, y: row * 12, width: 12, height: 12))
                }
            }
            guard let image else { return }
            context.saveGState()
            context.translateBy(x: imageRect.minX, y: imageRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = imageRect.width >= CGFloat(image.width) ? .none : .high
            context.draw(image, in: CGRect(origin: .zero, size: imageRect.size))
            context.restoreGState()
        }
    }
}
