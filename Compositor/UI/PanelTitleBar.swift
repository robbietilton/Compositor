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
}

extension View {
    func panelSurface() -> some View { modifier(PanelSurface()) }
}

private struct PanelSurface: ViewModifier {
    func body(content: Content) -> some View { content.background(PanelAppearance.content) }
}

struct PanelTitleColor: ViewModifier {
    func body(content: Content) -> some View { content.foregroundStyle(Color(nsColor: PanelAppearance.titleColor)) }
}

/// Panels' title bars: a centered title over the panel's header color, with no traffic lights (the Settings window
/// keeps its close button). The window's own title bar stays, made transparent, so it still drags, double-clicks and
/// carries the title for VoiceOver and the Window menu; the panel's content reaches up under it and draws the header
/// there (`panelTitle`). Nothing is added to the title bar itself.
enum PanelTitleBar {
    /// The header: the panel's darker band in Dark, the system's own in Light.
    static let headerColor = NSColor(name: nil) { appearance in
        CompositorAppearance.isLight(appearance) ? .windowBackgroundColor : PanelAppearance.darkHeader
    }

    static func install(in window: NSWindow, title: String, showsCloseButton: Bool = false) {
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.standardWindowButton(.closeButton)?.isHidden = !showsCloseButton
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    /// A titled window's title bar height, known before the window is on screen (where it measures nothing yet): what
    /// content reaching up under it makes room for, and what its header fills.
    static let standardHeight: CGFloat = {
        let reference = NSRect(x: 0, y: 0, width: 100, height: 100)
        return NSWindow.frameRect(forContentRect: reference, styleMask: [.titled, .closable]).height - reference.height
    }()

    /// After the appearance changes: the headers redraw in the new color.
    static func refreshAppearance() {
        for window in NSApp.windows where window.titlebarAppearsTransparent {
            window.contentView?.needsDisplay = true
        }
    }
}

extension View {
    /// The panel's header, under its transparent title bar: `title`, centered, on the header color.
    func panelTitle(_ title: String) -> some View { modifier(PanelTitle(title: title)) }
}

private struct PanelTitle: ViewModifier {
    let title: String

    // Over the content, raised into the title bar: the panel's own background reaches up there too, and a header
    // behind it was covered.
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            Text(title)
                .font(.system(size: NSFont.systemFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(PanelTitleColor())
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: PanelTitleBar.standardHeight)
                .background(Color(nsColor: PanelTitleBar.headerColor))
                .offset(y: -PanelTitleBar.standardHeight)
                .allowsHitTesting(false)
                // The window's own title says it.
                .accessibilityHidden(true)
        }
    }
}
