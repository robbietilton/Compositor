import AppKit
import SwiftUI

/// Local AppKit tracking keeps clicks and context menus native while a frame is moved within its strip.
struct GIFFrameDragSource<Content: View>: NSViewRepresentable {
    let canDrag: Bool
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onBegin: (CGFloat) -> Void
    let onEnd: () -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> Host { Host(rootView: AnyView(content())) }

    func updateNSView(_ view: Host, context: Context) {
        view.rootView = AnyView(content())
        view.canDrag = canDrag
        view.onClick = onClick
        view.onBegin = onBegin
        view.onEnd = onEnd
    }

    final class Host: NSView {
        private let host: NSHostingView<AnyView>
        var rootView: AnyView {
            get { host.rootView }
            set { host.rootView = newValue }
        }
        var canDrag = false
        var onClick: ((NSEvent.ModifierFlags) -> Void)?
        var onBegin: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?

        init(rootView: AnyView) {
            host = NSHostingView(rootView: rootView)
            super.init(frame: NSRect(x: 0, y: 0, width: GIFTimelineLayout.frameWidth, height: GIFTimelineLayout.frameHeight))
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            guard canDrag, let event = NSApp.currentEvent, !event.modifierFlags.contains(.control),
                  [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) else { return hit }
            return self
        }

        override func mouseDown(with down: NSEvent) {
            guard canDrag, let window else { super.mouseDown(with: down); return }
            var ancestor = superview
            while ancestor != nil && !(ancestor is any GIFFrameDragDestination) { ancestor = ancestor?.superview }
            guard let destination = ancestor as? any GIFFrameDragDestination else { super.mouseDown(with: down); return }
            let grabOffset = convert(down.locationInWindow, from: nil).x - bounds.midX
            var dragging = false
            defer {
                if dragging {
                    NSCursor.pop()
                    onEnd?()
                }
            }
            while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
                if event.type == .keyDown {
                    if event.keyCode == 53 { destination.finishFrameDrag(commit: false); return }
                    continue
                }
                if event.type == .leftMouseUp {
                    if dragging {
                        let valid = destination.trackFrameDrag(at: event.locationInWindow)
                        destination.finishFrameDrag(commit: valid)
                    } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
                        onClick?(down.modifierFlags)
                    }
                    return
                }
                if !dragging {
                    // Command-click toggles a batch target, including a click with a little pointer movement.
                    guard !down.modifierFlags.contains(.command) else { continue }
                    let dx = event.locationInWindow.x - down.locationInWindow.x
                    let dy = event.locationInWindow.y - down.locationInWindow.y
                    guard hypot(dx, dy) >= 6 else { continue }
                    dragging = true
                    NSCursor.closedHand.push()
                    onBegin?(grabOffset)
                }
                _ = destination.trackFrameDrag(at: event.locationInWindow)
            }
            destination.finishFrameDrag(commit: false)
        }
    }
}

@MainActor
protocol GIFFrameDragDestination: AnyObject {
    func trackFrameDrag(at windowPoint: CGPoint) -> Bool
    func finishFrameDrag(commit: Bool)
}
