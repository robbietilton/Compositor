import AppKit

/// Draws the centered title in the existing title bar without adding an AppKit toolbar.
final class PanelTitleBar: NSTextField {
    static func install(in window: NSWindow, title: String) {
        guard let frameView = window.contentView?.superview else { return }
        let titleCenter: CGFloat
        if let close = window.standardWindowButton(.closeButton), close.superview != nil {
            let center = NSPoint(x: close.bounds.midX, y: close.bounds.midY)
            titleCenter = close.convert(center, to: frameView).y
        } else {
            let inset = (window.frame.height - window.contentLayoutRect.maxY) / 2
            titleCenter = frameView.isFlipped ? frameView.bounds.minY + inset : frameView.bounds.maxY - inset
        }

        window.title = title
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }

        let label: PanelTitleBar
        if let existing = frameView.subviews.first(where: { $0 is PanelTitleBar }) as? PanelTitleBar {
            label = existing
        } else {
            label = PanelTitleBar(frame: .zero)
            frameView.addSubview(label, positioned: .above, relativeTo: nil)
        }
        label.stringValue = title
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: frameView.bounds.minX + 12, y: titleCenter - height / 2,
                             width: max(0, frameView.bounds.width - 24), height: height)
        label.autoresizingMask = [.width, frameView.isFlipped ? .maxYMargin : .minYMargin]
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        textColor = .labelColor
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The original title bar still receives drags and double-clicks through the label.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
