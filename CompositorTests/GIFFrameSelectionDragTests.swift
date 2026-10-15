import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct GIFFrameSelectionDragTests {
    private typealias Strip = GIFTimelineScrollView<EmptyView>.Container

    private struct FrameProbe: NSViewRepresentable {
        let index: Int
        func makeNSView(context: Context) -> Probe { Probe(index: index) }
        func updateNSView(_ view: Probe, context: Context) {}

        final class Probe: NSView {
            let index: Int
            init(index: Int) { self.index = index; super.init(frame: .zero) }
            required init?(coder: NSCoder) { nil }
        }
    }

    private func makeStrip(indices: [Int], width: CGFloat = 700) -> (Strip, NSWindow) {
        let contentWidth = CGFloat(indices.count) * GIFTimelineLayout.frameStride + 16
        let content = AnyView(HStack(spacing: 8) {
            ForEach(indices, id: \.self) { index in
                FrameProbe(index: index).frame(width: GIFTimelineLayout.frameWidth, height: GIFTimelineLayout.frameHeight)
            }
        }.padding(.horizontal, 12).padding(.vertical, 5))
        let view = Strip(rootView: content, contentWidth: contentWidth)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 84),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.canSelectFrames = true
        view.frameIndices = indices
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func probes(in view: NSView) -> [FrameProbe.Probe] {
        if let probe = view as? FrameProbe.Probe { return [probe] }
        return view.subviews.flatMap { probes(in: $0) }
    }

    private func center(_ index: Int, in view: Strip) throws -> CGPoint {
        let document = try #require(view.documentView)
        let probe = try #require(probes(in: document).first { $0.index == index })
        return probe.convert(CGPoint(x: probe.bounds.midX, y: probe.bounds.midY), to: nil)
    }

    private func point(x: CGFloat, y: CGFloat = 42, in view: Strip) -> CGPoint {
        view.contentView.convert(CGPoint(x: x + view.contentView.bounds.minX, y: y), to: nil)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow,
                       flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func sweepAddsStableIdentitiesWithoutTogglingRevisitedFramesOrNavigatingTheCanvas() throws {
        let ids = [8, 2, 11, 0, 7]
        let (view, window) = makeStrip(indices: ids)
        defer { window.contentView = nil }
        var selection = GIFFrameSelection()
        selection.select(7, toggling: false, displayedIndex: 7)
        var toggles = 0, drops = 0, reorderUpdates = 0, changes: [Bool] = []
        view.onSelectFrames = { selection.include($0, displayedIndex: 7) }
        view.onToggleFrameSelection = { _ in toggles += 1 }
        view.onSelectionDragChanged = { changes.append($0) }
        view.onFrameDragUpdated = { _, _, _ in reorderUpdates += 1; return true }
        view.onFrameDrop = { drops += 1; return true }
        let start = try center(8, in: view), end = try center(0, in: view)
        view.mouseDown(with: try event(.leftMouseDown, at: start, in: window))
        // One large native drag event must include the thumbnails crossed between its endpoints.
        view.mouseDragged(with: try event(.leftMouseDragged, at: end, in: window))
        view.mouseDragged(with: try event(.leftMouseDragged, at: center(2, in: view), in: window))
        view.mouseUp(with: try event(.leftMouseUp, at: center(2, in: view), in: window))
        #expect(selection.indices == Set(ids))
        #expect(changes == [true, false])
        #expect(toggles == 0 && drops == 0 && reorderUpdates == 0)
    }

    @Test func commandClickWithPointerJitterStillTogglesOnlyItsFrame() throws {
        let (view, window) = makeStrip(indices: [9, 3, 6])
        defer { window.contentView = nil }
        var selected: Set<Int> = [], toggled: [Int] = [], changes: [Bool] = []
        view.onSelectFrames = { selected.formUnion($0) }
        view.onToggleFrameSelection = { toggled.append($0) }
        view.onSelectionDragChanged = { changes.append($0) }
        let start = try center(3, in: view), jitter = CGPoint(x: start.x + 3, y: start.y + 2)
        view.mouseDown(with: try event(.leftMouseDown, at: start, in: window))
        view.mouseDragged(with: try event(.leftMouseDragged, at: jitter, in: window))
        view.mouseUp(with: try event(.leftMouseUp, at: jitter, in: window))
        #expect(toggled == [3] && selected.isEmpty && changes.isEmpty)
    }

    @Test func commandPressesRouteToSelectionWhilePlainAndControlPressesKeepTheirNativeTargets() throws {
        let (view, window) = makeStrip(indices: [0, 1, 2])
        defer { window.contentView = nil }
        let location = try center(1, in: view)
        for flags: NSEvent.ModifierFlags in [.command, [], [.command, .control]] {
            let down = try event(.leftMouseDown, at: location, in: window, flags: flags)
            NSApp.postEvent(down, atStart: true)
            let fetched = try #require(NSApp.nextEvent(matching: .leftMouseDown, until: Date(timeIntervalSinceNow: 0.1),
                inMode: .default, dequeue: true))
            #expect(fetched.modifierFlags == flags)
            let target = view.hitTest(view.convert(location, from: nil))
            #expect((target === view) == (flags == .command))
        }
    }

    @Test(arguments: [2, 7, 20])
    func selectionUsesActualHostedThumbnailsInCenteredAndScrollingStrips(count: Int) throws {
        let ids = Array(0..<count).reversed().map { $0 + 10 }
        let (view, window) = makeStrip(indices: ids)
        defer { window.contentView = nil }
        if count == 20 { view.setScrollOffset(288) }
        var selected: Set<Int> = []
        view.onSelectFrames = { selected.formUnion($0) }
        let first = count == 20 ? 3 : 0, last = min(first + 3, count - 1)
        view.beginFrameSelection(at: try center(ids[first], in: view))
        #expect(view.trackFrameSelection(at: try center(ids[last], in: view)))
        view.finishFrameSelection()
        #expect(selected == Set(ids[first...last]))
    }

    @Test func pointerPathIgnoresGapsAndPaddingAndClipsToVisibleThumbnails() throws {
        let (view, window) = makeStrip(indices: Array(0..<12), width: 400)
        defer { window.contentView = nil }
        var selected: Set<Int> = []
        view.onSelectFrames = { selected.formUnion($0) }
        view.beginFrameSelection(at: point(x: 104, in: view)) // 8-point gap after frame 0.
        view.finishFrameSelection()
        #expect(selected.isEmpty)
        view.beginFrameSelection(at: point(x: 56, y: 2, in: view)) // Above the thumbnail band.
        #expect(view.trackFrameSelection(at: point(x: 350, y: 2, in: view)))
        view.finishFrameSelection()
        #expect(selected.isEmpty)
        view.beginFrameSelection(at: try center(0, in: view))
        #expect(!view.trackFrameSelection(at: point(x: 900, in: view)))
        view.finishFrameSelection()
        #expect(selected == [0, 1, 2, 3, 4]) // Frame 4 has four visible pixels; later frames stay hidden.
    }

    @Test func leavingTheStripDoesNotJoinUnrelatedPathsWhenReentering() throws {
        let (view, window) = makeStrip(indices: Array(0..<7), width: 800)
        defer { window.contentView = nil }
        var selected: Set<Int> = []
        view.onSelectFrames = { selected.formUnion($0) }
        view.beginFrameSelection(at: try center(0, in: view))
        #expect(!view.trackFrameSelection(at: point(x: 56, y: -100, in: view)))
        #expect(!view.trackFrameSelection(at: point(x: 700, y: -100, in: view)))
        #expect(view.trackFrameSelection(at: try center(6, in: view)))
        view.finishFrameSelection()
        #expect(selected == [0, 6])
        let diagonal = GIFTimelineLayout.selectionPositions(from: CGPoint(x: 56, y: 42), to: CGPoint(x: 440, y: -200),
            count: 5, contentWidth: 496, viewportSize: CGSize(width: 496, height: 84))
        #expect(diagonal == [0, 1])
    }

    @Test(arguments: [false, true])
    func stationaryEdgeScrollSelectsNewlyRevealedFramesAndStopsOnRelease(left: Bool) async throws {
        let (view, window) = makeStrip(indices: Array(0..<12), width: 250)
        defer { window.contentView = nil }
        if left { view.setScrollOffset(480) }
        var selected: Set<Int> = []
        view.onSelectFrames = { selected.formUnion($0) }
        let start = point(x: left ? 20 : 230, in: view), edge = point(x: left ? 3 : 247, in: view)
        view.mouseDown(with: try event(.leftMouseDown, at: start, in: window))
        view.mouseDragged(with: try event(.leftMouseDragged, at: edge, in: window))
        let initialOffset = view.contentView.bounds.minX
        let hidden = 3
        #expect(!selected.contains(hidden))
        try await Task.sleep(for: .milliseconds(300))
        #expect(left ? view.contentView.bounds.minX < initialOffset : view.contentView.bounds.minX > initialOffset)
        #expect(selected.contains(hidden))
        view.mouseUp(with: try event(.leftMouseUp, at: edge, in: window))
        let stoppedOffset = view.contentView.bounds.minX, stoppedSelection = selected
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.contentView.bounds.minX == stoppedOffset && selected == stoppedSelection)
    }

    @Test(arguments: [0, 1, 2, 3])
    func releasingCommandDisablingEditingChangingFramesOrRemovingTheViewStopsSelection(reason: Int) async throws {
        let (view, window) = makeStrip(indices: Array(0..<12), width: 250)
        defer { window.contentView = nil }
        var selected: Set<Int> = [], changes: [Bool] = []
        view.onSelectFrames = { selected.formUnion($0) }
        view.onSelectionDragChanged = { changes.append($0) }
        let start = point(x: 230, in: view), edge = point(x: 247, in: view)
        view.mouseDown(with: try event(.leftMouseDown, at: start, in: window))
        view.mouseDragged(with: try event(.leftMouseDragged, at: edge, in: window))
        switch reason {
        case 0: view.mouseDragged(with: try event(.leftMouseDragged, at: edge, in: window, flags: []))
        case 1: view.canSelectFrames = false
        case 2: view.frameIndices = Array(0..<8)
        default: window.contentView = nil
        }
        let stoppedOffset = view.contentView.bounds.minX, stoppedSelection = selected
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.contentView.bounds.minX == stoppedOffset && selected == stoppedSelection)
        #expect(changes == [true, false])
        view.mouseUp(with: try event(.leftMouseUp, at: edge, in: window))
        #expect(selected == stoppedSelection)
    }

    @Test(arguments: [0, 1, 2])
    func stationaryModifierReleaseEscapeAndWindowFocusLossStopEdgeScrolling(reason: Int) async throws {
        let (view, window) = makeStrip(indices: Array(0..<12), width: 250)
        defer { window.contentView = nil }
        var changes: [Bool] = []
        view.onSelectionDragChanged = { changes.append($0) }
        let start = point(x: 230, in: view), edge = point(x: 247, in: view)
        view.mouseDown(with: try event(.leftMouseDown, at: start, in: window))
        view.mouseDragged(with: try event(.leftMouseDragged, at: edge, in: window))
        if reason == 2 {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        } else {
            let type: NSEvent.EventType = reason == 0 ? .flagsChanged : .keyDown
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero,
                modifierFlags: reason == 0 ? [] : .command, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: reason == 0 ? "" : "\u{1b}", charactersIgnoringModifiers: reason == 0 ? "" : "\u{1b}",
                isARepeat: false, keyCode: reason == 0 ? 55 : 53))
            NSApp.postEvent(event, atStart: true)
            if let fetched = NSApp.nextEvent(matching: NSEvent.EventTypeMask(rawValue: 1 << type.rawValue),
                until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true) { NSApp.sendEvent(fetched) }
        }
        #expect(changes == [true, false])
        let stopped = view.contentView.bounds.minX
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.contentView.bounds.minX == stopped)
        view.mouseUp(with: try event(.leftMouseUp, at: edge, in: window))
    }
}
