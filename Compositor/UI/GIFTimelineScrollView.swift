import AppKit
import SwiftUI

/// A horizontal hosted view without a native scroller; GIFTimeline draws its own styled scrollbar.
struct GIFTimelineScrollView<Content: View>: NSViewRepresentable {
    @Binding var scrollOffset: CGFloat
    let contentWidth: CGFloat
    let canSelectFrames: Bool
    let frameIndices: [Int]
    let onSelectFrames: (Set<Int>) -> Void
    let onToggleFrameSelection: (Int) -> Void
    let onSelectionDragChanged: (Bool) -> Void
    let onFrameDragUpdated: (CGPoint, CGFloat, CGSize) -> Bool
    let onFrameDragExited: () -> Void
    let onFrameDrop: () -> Bool
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(scrollOffset: $scrollOffset) }

    func makeNSView(context: Context) -> Container {
        let view = Container(rootView: AnyView(content()), contentWidth: contentWidth)
        view.onScrollOffsetChanged = { [weak coordinator = context.coordinator] offset in
            coordinator?.updateScrollOffset(offset)
        }
        updateDragCallbacks(view)
        return view
    }

    func updateNSView(_ view: Container, context: Context) {
        view.onScrollOffsetChanged = { [weak coordinator = context.coordinator] offset in
            coordinator?.updateScrollOffset(offset)
        }
        updateDragCallbacks(view)
        view.update(rootView: AnyView(content()), contentWidth: contentWidth)
        view.setScrollOffset(scrollOffset)
    }

    private func updateDragCallbacks(_ view: Container) {
        view.canSelectFrames = canSelectFrames
        view.frameIndices = frameIndices
        view.onSelectFrames = onSelectFrames
        view.onToggleFrameSelection = onToggleFrameSelection
        view.onSelectionDragChanged = onSelectionDragChanged
        view.onFrameDragUpdated = onFrameDragUpdated
        view.onFrameDragExited = onFrameDragExited
        view.onFrameDrop = onFrameDrop
    }

    final class Coordinator {
        private var scrollOffset: Binding<CGFloat>

        init(scrollOffset: Binding<CGFloat>) { self.scrollOffset = scrollOffset }

        func updateScrollOffset(_ offset: CGFloat) {
            guard abs(scrollOffset.wrappedValue - offset) > 0.5 else { return }
            scrollOffset.wrappedValue = offset
        }
    }

    final class Container: NSScrollView, GIFFrameDragDestination {
        private let host: NSHostingView<AnyView>
        private var contentWidth: CGFloat
        private var boundsObserver: NSObjectProtocol?
        var onScrollOffsetChanged: ((CGFloat) -> Void)?
        var onFrameDragUpdated: ((CGPoint, CGFloat, CGSize) -> Bool)?
        var onFrameDragExited: (() -> Void)?
        var onFrameDrop: (() -> Bool)?
        var canSelectFrames = false {
            didSet { if !canSelectFrames { cancelSelectionDrag() } }
        }
        var frameIndices: [Int] = [] {
            didSet { if frameIndices != oldValue { cancelSelectionDrag() } }
        }
        var onSelectFrames: ((Set<Int>) -> Void)?
        var onToggleFrameSelection: ((Int) -> Void)?
        var onSelectionDragChanged: ((Bool) -> Void)?
        private var dragLocation: CGPoint?
        private var dragScrollTimer: Timer?
        private var isSelectingFrames = false
        private var previousSelectionPoint: CGPoint?
        private var selectionViewportSize: CGSize?
        private var selectionMonitor: Any?
        private var resignKeyObserver: NSObjectProtocol?
        private var selectionPress: SelectionPress?

        private struct SelectionPress {
            let point: CGPoint
            let index: Int?
            var isDragging = false
            var isCanceled = false
        }

        init(rootView: AnyView, contentWidth: CGFloat) {
            host = NSHostingView(rootView: Self.hostedContent(rootView, width: contentWidth))
            self.contentWidth = contentWidth
            super.init(frame: .zero)
            drawsBackground = false
            borderType = .noBorder
            hasHorizontalScroller = false
            hasVerticalScroller = false
            horizontalScrollElasticity = .none
            verticalScrollElasticity = .none
            documentView = host
            contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.onScrollOffsetChanged?(self.contentView.bounds.origin.x)
            }
            updateContentSize()
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            dragScrollTimer?.invalidate()
            if let selectionMonitor { NSEvent.removeMonitor(selectionMonitor) }
            if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        }

        override func layout() {
            super.layout()
            updateContentSize()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            guard canSelectFrames, let event = NSApp.currentEvent, event.type == .leftMouseDown,
                  event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
                  hit === contentView || hit.isDescendant(of: contentView) else { return hit }
            // Capture Command presses before a hosted thumbnail or the empty-space pan gesture.
            return self
        }

        override func mouseDown(with event: NSEvent) {
            guard canSelectFrames, event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control), let window else { super.mouseDown(with: event); return }
            clearSelectionPress()
            selectionPress = SelectionPress(point: event.locationInWindow, index: frameIndex(at: event.locationInWindow))
            selectionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self, self.selectionPress != nil else { return event }
                if event.type == .keyDown, event.keyCode == 53 {
                    self.cancelSelectionDrag()
                    return nil
                }
                if event.type == .flagsChanged, !event.modifierFlags.contains(.command) { self.cancelSelectionDrag() }
                return event
            }
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearSelectionPress() }
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let press = selectionPress else { super.mouseDragged(with: event); return }
            guard !press.isCanceled else { return }
            guard canSelectFrames, event.modifierFlags.contains(.command) else { cancelSelectionDrag(); return }
            if !press.isDragging {
                guard hypot(event.locationInWindow.x - press.point.x, event.locationInWindow.y - press.point.y) >= 6 else { return }
                selectionPress?.isDragging = true
                beginFrameSelection(at: press.point)
            }
            _ = trackFrameSelection(at: event.locationInWindow)
        }

        override func mouseUp(with event: NSEvent) {
            guard let press = selectionPress else { super.mouseUp(with: event); return }
            defer { clearSelectionPress() }
            guard !press.isCanceled, canSelectFrames, event.modifierFlags.contains(.command) else { return }
            if press.isDragging { _ = trackFrameSelection(at: event.locationInWindow) }
            else if let index = press.index, frameIndex(at: event.locationInWindow) == index { onToggleFrameSelection?(index) }
        }

        func beginFrameSelection(at windowPoint: CGPoint) {
            guard canSelectFrames else { return }
            stopDragScrolling()
            isSelectingFrames = true
            onSelectionDragChanged?(true)
            _ = trackFrameSelection(at: windowPoint)
        }

        @discardableResult func trackFrameSelection(at windowPoint: CGPoint) -> Bool {
            guard isSelectingFrames else { return false }
            return trackDrag(at: windowPoint)
        }

        func finishFrameSelection() { stopDragScrolling() }

        func trackFrameDrag(at windowPoint: CGPoint) -> Bool { trackDrag(at: windowPoint) }

        private func trackDrag(at windowPoint: CGPoint) -> Bool {
            let point = contentView.convert(windowPoint, from: nil)
            dragLocation = CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY)
            let valid = updateDragDestination()
            if valid, dragScrollTimer == nil {
                let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrollDuringDrag() }
                }
                dragScrollTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            } else if !valid {
                dragScrollTimer?.invalidate()
                dragScrollTimer = nil
            }
            return valid
        }

        func finishFrameDrag(commit: Bool) {
            guard !isSelectingFrames else { finishFrameSelection(); return }
            stopDragScrolling()
            if commit { _ = onFrameDrop?() }
            else { onFrameDragExited?() }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { clearSelectionPress(); stopDragScrolling() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func updateDragDestination() -> Bool {
            guard let dragLocation else { return false }
            if isSelectingFrames {
                guard canSelectFrames else { return false }
                let valid = (0...contentView.bounds.width).contains(dragLocation.x)
                    && (0...contentView.bounds.height).contains(dragLocation.y)
                if selectionViewportSize != contentView.bounds.size { previousSelectionPoint = nil }
                selectionViewportSize = contentView.bounds.size
                let point = CGPoint(x: dragLocation.x + contentView.bounds.minX, y: dragLocation.y)
                let positions = GIFTimelineLayout.selectionPositions(from: previousSelectionPoint ?? point, to: point,
                    count: frameIndices.count, contentWidth: contentWidth, viewportSize: contentView.bounds.size,
                    scrollOffset: contentView.bounds.minX)
                // Leaving the strip stops scrolling; reentry starts a new path instead of bridging outside it.
                previousSelectionPoint = valid ? point : nil
                if !positions.isEmpty { onSelectFrames?(Set(positions.map { frameIndices[$0] })) }
                return valid
            }
            return onFrameDragUpdated?(dragLocation, contentView.bounds.minX, contentView.bounds.size) ?? false
        }

        private func scrollDuringDrag() {
            guard let dragLocation else { return }
            let edge = min(40, contentView.bounds.width / 4)
            guard edge > 0 else { return }
            let left = max(0, min(1, (edge - dragLocation.x) / edge))
            let right = max(0, min(1, (dragLocation.x - contentView.bounds.width + edge) / edge))
            let delta = (right - left) * 9
            guard delta != 0 else { return }
            let oldOffset = contentView.bounds.minX
            setScrollOffset(oldOffset + delta)
            guard contentView.bounds.minX != oldOffset else { return }
            _ = updateDragDestination()
        }

        private func stopDragScrolling() {
            dragScrollTimer?.invalidate()
            dragScrollTimer = nil
            dragLocation = nil
            previousSelectionPoint = nil
            selectionViewportSize = nil
            if isSelectingFrames {
                isSelectingFrames = false
                onSelectionDragChanged?(false)
            }
        }

        private func frameIndex(at windowPoint: CGPoint) -> Int? {
            let point = contentView.convert(windowPoint, from: nil)
            guard contentView.bounds.contains(point) else { return nil }
            let positions = GIFTimelineLayout.selectionPositions(from: point, to: point, count: frameIndices.count,
                contentWidth: contentWidth, viewportSize: contentView.bounds.size, scrollOffset: contentView.bounds.minX)
            return positions.first.map { frameIndices[$0] }
        }

        private func cancelSelectionDrag() {
            selectionPress?.isCanceled = true
            if isSelectingFrames { stopDragScrolling() }
        }

        private func clearSelectionPress() {
            cancelSelectionDrag()
            selectionPress = nil
            if let selectionMonitor { NSEvent.removeMonitor(selectionMonitor); self.selectionMonitor = nil }
            if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver); self.resignKeyObserver = nil }
        }

        func update(rootView: AnyView, contentWidth: CGFloat) {
            host.rootView = Self.hostedContent(rootView, width: contentWidth)
            host.invalidateIntrinsicContentSize()
            self.contentWidth = contentWidth
            updateContentSize()
        }

        func setScrollOffset(_ offset: CGFloat) {
            let maximumOffset = max(0, host.frame.width - contentView.bounds.width)
            let x = min(maximumOffset, max(0, offset))
            guard abs(contentView.bounds.origin.x - x) > 0.5 else { return }
            contentView.scroll(to: NSPoint(x: x, y: 0))
            reflectScrolledClipView(contentView)
        }

        private func updateContentSize() {
            let viewport = contentView.bounds.size
            let size = NSSize(width: max(contentWidth, viewport.width), height: max(host.fittingSize.height, viewport.height))
            if host.frame.size != size { host.setFrameSize(size) }
            setScrollOffset(contentView.bounds.origin.x)
        }

        private static func hostedContent(_ content: AnyView, width: CGFloat) -> AnyView {
            // The document view fills the viewport even when there are only a few frames.
            // Center short strips; drag/drop and its overlays account for the same centering inset.
            AnyView(content.frame(width: width).frame(maxWidth: .infinity, alignment: .center))
        }
    }
}
