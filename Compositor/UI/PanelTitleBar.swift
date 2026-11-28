import AppKit
import SwiftUI

enum PanelAppearance {
    static let darkHeader = NSColor(srgbRed: 37.0 / 255, green: 37.0 / 255, blue: 37.0 / 255, alpha: 1)

    static let content = Color(nsColor: NSColor(name: nil) { appearance in
        guard !CompositorAppearance.isLight(appearance) else { return .clear }
        return NSColor(srgbRed: 29.0 / 255, green: 29.0 / 255, blue: 29.0 / 255, alpha: 1)
    })

    static let titleColor = NSColor(name: nil) { appearance in
        guard !CompositorAppearance.isLight(appearance) else { return .labelColor }
        return NSColor(srgbRed: 161.0 / 255, green: 160.0 / 255, blue: 161.0 / 255, alpha: 1)
    }
    static let title = Color(nsColor: titleColor)
}

/// Draws the centered title in the existing title bar without adding an AppKit toolbar.
final class PanelTitleBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private var closeButtonFrame: NSRect?

    static func install(in window: NSWindow, title: String, showsCloseButton: Bool = false) {
        guard let content = window.contentView, let frameView = content.superview else { return }
        // AppKit can report an empty contentLayoutRect before a panel is shown. Use the title height
        // for the window's style, and stop at the content edge when the content has its own inset.
        let reference = NSRect(x: 0, y: 0, width: 100, height: 100)
        let style = window.styleMask.subtracting(.fullSizeContentView)
        let nativeHeight = NSWindow.frameRect(forContentRect: reference, styleMask: style).height - reference.height
        let contentFrame = content.convert(content.bounds, to: frameView)
        let contentInset = frameView.isFlipped ? contentFrame.minY - frameView.bounds.minY : frameView.bounds.maxY - contentFrame.maxY
        let height = contentInset > 0 ? min(nativeHeight, contentInset) : nativeHeight
        guard height > 0 else { return }

        var titleInset = height / 2
        if let close = window.standardWindowButton(.closeButton), close.superview != nil {
            let center = NSPoint(x: close.bounds.midX, y: close.bounds.midY)
            let y = close.convert(center, to: frameView).y
            let inset = frameView.isFlipped ? y - frameView.bounds.minY : frameView.bounds.maxY - y
            if (0..<height).contains(inset) { titleInset = inset }
        }

        window.title = title
        window.titleVisibility = .hidden
        let close = window.standardWindowButton(.closeButton)
        close?.isHidden = !showsCloseButton
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }

        let bar: PanelTitleBar
        if let existing = frameView.subviews.first(where: { $0 is PanelTitleBar }) as? PanelTitleBar {
            bar = existing
        } else {
            bar = PanelTitleBar(frame: .zero)
            frameView.addSubview(bar, positioned: .above, relativeTo: nil)
        }
        let y = frameView.isFlipped ? frameView.bounds.minY : frameView.bounds.maxY - height
        bar.frame = NSRect(x: frameView.bounds.minX, y: y, width: frameView.bounds.width, height: height)
        bar.autoresizingMask = [.width, frameView.isFlipped ? .maxYMargin : .minYMargin]
        bar.closeButtonFrame = showsCloseButton ? close.map { bar.convert($0.bounds, from: $0) } : nil
        bar.needsDisplay = true
        bar.label.stringValue = title
        let labelHeight = bar.label.intrinsicContentSize.height
        bar.label.frame = NSRect(x: 12, y: titleInset - labelHeight / 2,
                                 width: max(0, bar.bounds.width - 24), height: labelHeight)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = PanelAppearance.titleColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.autoresizingMask = [.width]
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !CompositorAppearance.isLight(effectiveAppearance) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Leave the native close button visible through the title-bar fill without moving it.
        if let closeButtonFrame {
            let shape = NSBezierPath(rect: bounds)
            shape.appendOval(in: closeButtonFrame.insetBy(dx: -1, dy: -1))
            shape.windingRule = .evenOdd
            shape.addClip()
        }
        PanelAppearance.darkHeader.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    // The original title bar still receives drags and double-clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
