import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct GIFFrameReorderingTests {
    @Test(arguments: [(0, 3), (3, 0), (1, 2), (2, 1)])
    func movingFramesKeepsTheirTimingEditsAndSelection(move: (Int, Int)) async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.addGIFFrameMask(at: move.0, for: id)
        session.toggleGIFFrameMaskEnabled(at: move.0, for: id)
        session.isMaskSelected = false
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 6, hardness: 1, red: 0, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 8, y: 12))
        #expect(session.finishBrushImmediately())
        session.toggleGIFFrameMaskTarget()
        let source = try #require(session.activeLayer?.gifAnimation?.source)
        let pixels = try #require(session.activeLayer?.gifAnimation?.framePixels[move.0]?.image)
        let mask = try #require(session.activeLayer?.gifFrameMasks[move.0])
        let before = session.document
        let count = session.history.undoCount
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(position: 1), for: id)
        session.toggleGIFPlayback(for: id)
        session.moveGIFFrame(at: move.0, to: move.1, for: id)

        var expected = Array(0..<4)
        expected.insert(expected.remove(at: move.0), at: move.1)
        #expect(session.gifTimelineFrames.map(\.index) == expected)
        #expect(session.gifTimelineFrames.map(\.duration) == expected.map { source.frames[$0].duration })
        #expect(abs(session.gifTimelineFrames.reduce(0) { $0 + $1.duration }
            - source.frames.reduce(0) { $0 + $1.duration }) < 0.000001)
        #expect(session.activeLayer?.gifAnimation?.source === source)
        #expect(session.activeLayer?.gifAnimation?.hasValidFrameOrder == true)
        #expect(session.activeLayer?.gifAnimation?.framePixels[move.0]?.image === pixels)
        #expect(session.activeLayer?.gifFrameMasks[move.0] == mask)
        #expect(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image } === pixels)
        #expect(session.gifTimelineSelectedFrameIndex == move.0 && session.isGIFFrameMaskSelected)
        #expect(session.activeLayerID == id && session.selectedLayerIDs == [id])
        #expect(!session.gifTimelineIsPlaying && session.gifTimelinePlaybackSpeed.multiplier == 2)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Reorder GIF Frames")
        let after = session.document
        session.undo()
        #expect(session.document == before && session.gifTimelineFrames.map(\.index) == Array(0..<4))
        session.redo()
        #expect(session.document == after && session.gifTimelineFrames.map(\.index) == expected)
    }

    @Test func canceledSamePositionAndInvalidMovesDoNotEditTheDocument() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let before = session.document
        let count = session.history.undoCount
        session.toggleGIFPlayback(for: id)
        session.pauseGIFForEditing(for: id)
        #expect(!session.gifTimelineIsPlaying)
        session.moveGIFFrame(at: 0, to: 0, for: id)
        session.moveGIFFrame(at: 0, to: -1, for: id)
        session.moveGIFFrame(at: 0, to: 4, for: id)
        session.moveGIFFrame(at: 99, to: 1, for: id)
        session.moveGIFFrame(at: 0, to: 1, for: UUID())
        #expect(session.document == before && session.history.undoCount == count)
        #expect(session.activeLayer?.gifAnimation?.frameOrder == nil)
        session.addBlankLayer()
        let inactive = session.document
        let inactiveCount = session.history.undoCount
        session.moveGIFFrame(at: 0, to: 1, for: id)
        #expect(session.document == inactive && session.history.undoCount == inactiveCount)
    }

    @Test func movedCopiesAndDeletedFramesRoundTripWithTheirSourceComposition() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorGIFReorder-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: folder) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.addGIFFrameMask(at: 1, for: id)
        session.toggleGIFFrameMaskEnabled(at: 1, for: id)
        await session.duplicateGIFFrame(at: 1, for: id)
        await session.deleteGIFFrame(at: 1, for: id)
        session.moveGIFFrame(at: 4, to: 3, for: id)
        session.moveGIFFrame(at: 3, to: 0, for: id)
        let expected = [3, 0, 2, 4]
        #expect(session.gifTimelineFrames.map(\.index) == expected)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == ProjectManifest.current)
        let package = folder.appendingPathComponent("Reordered.comp")
        try await ProjectStore.shared.save(snapshot, to: package)
        try FileManager.default.removeItem(at: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: package), from: package)
        #expect(reopened.gifTimelineFrames.map(\.index) == expected)
        #expect(reopened.gifTimelineFrames.map(\.duration) == session.gifTimelineFrames.map(\.duration))
        #expect(reopened.gifTimelineSelectedFrameIndex == 4 && !reopened.gifTimelineIsPlaying)
        #expect(reopened.activeLayer?.gifFrameMasks[4]?.isEnabled == false)
        #expect(reopened.activeLayer?.gifAnimation?.deletedFrameIndices == [1])
        for (index, channel) in [(3, 0), (0, 0), (2, 1), (4, 2)] {
            await reopened.selectGIFTimelineFrame(index)
            let image = try #require(reopened.activeLayer.flatMap { reopened.displayedAsset(for: $0)?.image })
            #expect(try ImageImportTests().rgba(image, x: 8, y: 12)[channel] > 240)
        }
        await reopened.duplicateGIFFrame(at: 3, for: id)
        #expect(reopened.gifTimelineFrames.map(\.index) == [3, 5, 0, 2, 4])
        await reopened.deleteGIFFrame(at: 0, for: id)
        #expect(reopened.gifTimelineFrames.map(\.index) == [3, 5, 2, 4])
    }

    @Test func insertionTargetsClampAndDoNotOscillateAtTheBoundary() {
        #expect(GIFTimelineLayout.destination(for: -100, count: 4, current: 2) == 0)
        #expect(GIFTimelineLayout.destination(for: 10_000, count: 4, current: 0) == 3)
        #expect(GIFTimelineLayout.destination(for: 56, count: 4, current: 0) == 0)
        #expect(GIFTimelineLayout.destination(for: 107, count: 4, current: 0) == 0)
        #expect(GIFTimelineLayout.destination(for: 109, count: 4, current: 0) == 1)
        #expect(GIFTimelineLayout.destination(for: 103, count: 4, current: 1) == 1)
        #expect(GIFTimelineLayout.destination(for: 99, count: 4, current: 1) == 0)
        #expect(GIFTimelineLayout.destination(for: 248, count: 4, current: 0) == 2)
        #expect(GIFTimelineLayout.destination(for: .nan, count: 4, current: 1) == 1)
        #expect(GIFTimelineLayout.destination(for: 56, count: 0, current: 0) == 0)
    }

    private struct FrameProbe: NSViewRepresentable {
        let index: Int
        func makeNSView(context: Context) -> Probe { Probe(index: index) }
        func updateNSView(_ view: Probe, context: Context) {}

        final class Probe: NSView {
            let index: Int
            init(index: Int) {
                self.index = index
                super.init(frame: .zero)
            }
            required init?(coder: NSCoder) { nil }
        }
    }

    private func strip(count: Int) -> AnyView {
        AnyView(HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                FrameProbe(index: index)
                    .frame(width: GIFTimelineLayout.frameWidth, height: GIFTimelineLayout.frameHeight)
            }
        }.padding(.horizontal, GIFTimelineLayout.padding).padding(.vertical, 5))
    }

    private func probes(in view: NSView) -> [FrameProbe.Probe] {
        if let probe = view as? FrameProbe.Probe { return [probe] }
        return view.subviews.flatMap { probes(in: $0) }
    }

    /// Exercise hosted thumbnail geometry, not just the drop formula: short strips used to
    /// be centered by NSHostingView while drop targets and the insertion gap ignored that inset.
    @Test(arguments: [2, 7, 20])
    func thumbnailsAndDragTargetsShareTheCenteredOrigin(count: Int) throws {
        let width = CGFloat(count) * GIFTimelineLayout.frameStride + 16
        let view = GIFTimelineScrollView<EmptyView>.Container(rootView: strip(count: count), contentWidth: width)
        view.frame = CGRect(x: 0, y: 0, width: 700, height: 84)
        view.layoutSubtreeIfNeeded()
        let document = try #require(view.documentView)
        let thumbnails = probes(in: document)
        #expect(thumbnails.count == count)
        for index in 0..<min(count, 6) {
            let thumbnail = try #require(thumbnails.first { $0.index == index })
            let center = CGPoint(x: thumbnail.bounds.midX, y: thumbnail.bounds.midY)
            let point = view.contentView.convert(center, from: thumbnail)
            let inset = max(0, (700 - width) / 2)
            let expected = inset + GIFTimelineLayout.padding + CGFloat(index) * GIFTimelineLayout.frameStride
                + GIFTimelineLayout.frameWidth / 2
            #expect(abs(point.x - expected) < 0.5)
            #expect(abs(GIFTimelineLayout.frameCenterX(at: index, contentWidth: width, viewportWidth: 700,
                scrollOffset: 0) - point.x) < 0.5)
            for grabOffset in [CGFloat(-24), 0, 24] {
                var destination: Int?
                view.onFrameDragUpdated = { location, offset, viewport in
                    let inset = GIFTimelineLayout.centeringInset(contentWidth: width, viewportWidth: viewport.width)
                    destination = GIFTimelineLayout.destination(for: location.x + offset - grabOffset - inset,
                        count: count, current: 0)
                    return true
                }
                let grab = CGPoint(x: center.x + grabOffset, y: center.y)
                #expect(view.trackFrameDrag(at: thumbnail.convert(grab, to: nil)))
                view.finishFrameDrag(commit: false)
                #expect(destination == index)
            }
        }
    }

    @Test func shrinkingAndResizingTheStripKeepThumbnailsAndDropCoordinatesAligned() throws {
        let view = GIFTimelineScrollView<EmptyView>.Container(rootView: strip(count: 12), contentWidth: 1_168)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 84)
        view.layoutSubtreeIfNeeded()
        view.setScrollOffset(288)
        #expect(view.contentView.bounds.minX == 288)
        let scrolledDocument = try #require(view.documentView)
        let middle = try #require(probes(in: scrolledDocument).first { $0.index == 5 })
        var destination: Int?
        var viewportX: CGFloat?
        view.onFrameDragUpdated = { location, offset, viewport in
            viewportX = location.x
            let inset = GIFTimelineLayout.centeringInset(contentWidth: 1_168, viewportWidth: viewport.width)
            destination = GIFTimelineLayout.destination(for: location.x + offset - inset, count: 12, current: 0)
            return true
        }
        #expect(view.trackFrameDrag(at: middle.convert(CGPoint(x: middle.bounds.midX, y: middle.bounds.midY), to: nil)))
        view.finishFrameDrag(commit: false)
        #expect(destination == 5)
        #expect(viewportX.map { abs($0 - 248) < 0.5 } == true)
        view.update(rootView: strip(count: 3), contentWidth: 304)
        view.layoutSubtreeIfNeeded()
        #expect(view.contentView.bounds.minX == 0)
        for width in [CGFloat(700), 200, 304, 900] {
            view.frame.size.width = width
            view.layoutSubtreeIfNeeded()
            let document = try #require(view.documentView)
            let first = try #require(probes(in: document).first { $0.index == 0 })
            let point = view.contentView.convert(CGPoint(x: first.bounds.midX, y: first.bounds.midY), from: first)
            let expected = max(0, (width - 304) / 2) + 56
            #expect(abs(point.x - expected) < 0.5)
            #expect(abs(GIFTimelineLayout.frameCenterX(at: 0, contentWidth: 304, viewportWidth: width,
                scrollOffset: 0) - point.x) < 0.5)
            #expect(view.contentView.bounds.minX == 0)
            var destination: Int?
            view.onFrameDragUpdated = { location, offset, viewport in
                let inset = GIFTimelineLayout.centeringInset(contentWidth: 304, viewportWidth: viewport.width)
                destination = GIFTimelineLayout.destination(for: location.x + offset - inset, count: 3, current: 2)
                return true
            }
            #expect(view.trackFrameDrag(at: first.convert(CGPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)))
            view.finishFrameDrag(commit: false)
            #expect(destination == 0)
        }
    }

    @Test func holdingAtAnEdgeScrollsAndEndingTheDragStopsTheTimer() async throws {
        let view = GIFTimelineScrollView<EmptyView>.Container(
            rootView: AnyView(Color.clear.frame(width: 1_000, height: 74)), contentWidth: 1_000)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 90)
        view.layoutSubtreeIfNeeded()
        var offset: CGFloat = 0
        var updates = 0
        var drops = 0
        view.onFrameDragUpdated = { _, scrollOffset, _ in
            offset = scrollOffset
            updates += 1
            return true
        }
        view.onFrameDrop = { drops += 1; return true }
        #expect(view.trackFrameDrag(at: CGPoint(x: 196, y: 40)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(offset > 0 && offset <= 800)
        view.finishFrameDrag(commit: true)
        #expect(drops == 1)
        let stopped = updates
        try await Task.sleep(for: .milliseconds(80))
        #expect(updates == stopped)
        view.onFrameDragUpdated = { _, _, _ in false }
        #expect(!view.trackFrameDrag(at: CGPoint(x: 210, y: 40)))
        view.finishFrameDrag(commit: false)
        #expect(drops == 1)
    }
}
