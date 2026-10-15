import AppKit
import SwiftUI

/// A frame strip whose selection changes the image shown on the canvas.
struct GIFTimeline: View {
    let layerName: String
    let frames: [GIFTimelineFrame]
    let selectedFrameIndex: Int
    let isPlaying: Bool
    let playbackSpeed: GIFPlaybackSpeed
    let playbackScope: GIFPlaybackScope
    let canPlay: Bool
    let playbackLayerIDs: [UUID]
    let sourceFrames: [GIFTimelineFrame]
    let timing: GIFFrameTiming
    let onionSkin: GIFOnionSkinPreview
    let frameMaskIndices: Set<Int>
    let enabledFrameMaskIndices: Set<Int>
    let hasSelectedFrameMask: Bool
    let isSelectedFrameMaskEnabled: Bool
    let isFrameMaskSelected: Bool
    let frameMaskControlsLookEditable: Bool
    let canEditFrameMask: Bool
    let canEditFrames: Bool
    let canEditTiming: Bool
    let onSelectFrame: (Int) async -> Void
    let onTogglePlayback: () -> Void
    let onStopPlayback: () -> Void
    let onChangePlaybackSpeed: (GIFPlaybackSpeed) -> Void
    let onChangePlaybackScope: (GIFPlaybackScope) -> Void
    let onPlayAllFrames: () async -> Void
    let onChangeTiming: (GIFFrameTiming) -> Void
    let onToggleFrameMask: () -> Void
    let onToggleFrameMaskEnabled: () -> Void
    let onAddFrameMask: (Int) async -> Void
    let onAddFrameMasks: (Set<Int>) async -> Void
    let onDeleteFrameMask: (Int) -> Void
    let onDeleteFrameMasks: (Set<Int>) -> Void
    let onToggleFrameMaskEnabledAtIndex: (Int) -> Void
    let onPrepareFrameMaskCopy: (Int) -> GIFFrameMaskCopyRequest?
    let onCopyFrameMask: (GIFFrameMaskCopyRequest, Set<Int>) -> Bool
    let onDuplicateFrame: (Int) async -> Void
    let onDeleteFrames: (Set<Int>) async -> Void
    let onMoveFrame: (Int, Int) -> Void
    let onBeginFrameDrag: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var headerViewportWidth: CGFloat = 166
    @State private var frameSelection = GIFFrameSelection()
    @State private var scrollOffset: CGFloat = 0
    @State private var timelineDragStartOffset: CGFloat?
    @State private var scrollbarStartOffset: CGFloat?
    @State private var isTimelineDragging = false
    @State private var isScrollbarDragging = false
    @State private var isSelectingFrames = false
    @State private var frameDragLocation: CGPoint?
    @State private var draggedFrameIndex: Int?
    @State private var frameDropPosition: Int?
    @State private var frameGrabOffset: CGFloat = 0
    @State private var frameDragViewportSize = CGSize.zero
    @State private var isFrameSettling = false
    @State private var frameSettlementTask: Task<Void, Never>?
    @State private var maskCopyRequest: GIFFrameMaskCopyRequest?

    private static let frameStride = GIFTimelineLayout.frameStride
    private var contentWidth: CGFloat { CGFloat(frames.count) * Self.frameStride + 16 }
    private var isDragging: Bool { isTimelineDragging || isScrollbarDragging || isSelectingFrames || draggedFrameIndex != nil }

    private struct PlaybackState: Equatable {
        let isPlaying: Bool
        let speed: GIFPlaybackSpeed
        let scope: GIFPlaybackScope
        let frameIndices: [Int]
        let frameDurations: [TimeInterval]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        GIFPlaybackControls(layerName: layerName, isPlaying: isPlaying, playbackScope: playbackScope,
                                            canPlay: canPlay, headerViewportWidth: headerViewportWidth,
                                            onTogglePlayback: onTogglePlayback, onChangePlaybackScope: onChangePlaybackScope)
                        Button {
                            if frameSelection.indices.count > 1 {
                                let targets = frameSelection.indices
                                Task { await onAddFrameMasks(targets) }
                            } else { onToggleFrameMask() }
                        } label: {
                            Image(systemName: "rectangle.inset.filled")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isFrameMaskSelected && frameSelection.indices.count <= 1 && !isPlaying
                                    ? Color.accentColor : Color.secondary)
                                .frame(width: 24, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // Keep the icons steady during decoding; their actions still check frame availability.
                        .disabled(isPlaying || (frameSelection.indices.count > 1
                            ? !canEditFrameMask || frameSelection.indices.isSubset(of: frameMaskIndices) : !frameMaskControlsLookEditable))
                        .help(frameMaskButtonHelp)
                        .accessibilityLabel(frameMaskButtonLabel)
                        .accessibilityValue(frameSelection.indices.count > 1 ? "\(frameSelection.indices.count) selected frames"
                            : isFrameMaskSelected ? "Mask selected" : "Image selected")
                        .accessibilityIdentifier("gifFrameMask")
                        Button(action: onToggleFrameMaskEnabled) {
                            Image(systemName: isSelectedFrameMaskEnabled ? "eye" : "eye.slash")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(frameMaskControlsLookEditable && hasSelectedFrameMask && !isPlaying
                                    ? Color.secondary : Color.secondary.opacity(0.45))
                                .frame(width: 24, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!frameMaskControlsLookEditable || !hasSelectedFrameMask || isPlaying)
                        .help(frameMaskVisibilityHelp)
                        .accessibilityLabel(frameMaskVisibilityLabel)
                        .accessibilityValue(hasSelectedFrameMask ? (isSelectedFrameMaskEnabled ? "Enabled" : "Disabled") : "No mask")
                        .accessibilityIdentifier("gifFrameMaskVisibility")
                        GIFOnionSkinControls(preview: onionSkin, canPreview: frames.count > 1, isPlaying: isPlaying)
                        GIFDelayControls(frames: sourceFrames, timing: timing, canEdit: canEditTiming && !isPlaying,
                                         onStopPlayback: onStopPlayback, onChange: onChangeTiming)
                    }
                }
                .scrollIndicators(.never)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerViewportWidth = $0 }
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .help("Command-drag across thumbnails to select frames. Drag a thumbnail to reorder, or empty space to scroll.")
                    .accessibilityHidden(true)
                Text(isFrameMaskSelected ? "Editing mask" : "Editing frame")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("gifTimelineEditTarget")
                Divider().frame(height: 12)
                Text(frameSelection.indices.count > 1 ? "\(frameSelection.indices.count) selected" : "\(frames.count) frames")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("\(frames.count) frames. Command-click to toggle frames, or Command-drag to select frames along the pointer's path.")
                    .accessibilityLabel(frameSelection.indices.count > 1
                        ? "\(frameSelection.indices.count) selected of \(frames.count) frames" : "\(frames.count) frames")
                    .accessibilityIdentifier("gifTimelineFrameCount")
                Divider().frame(height: 12)
                GIFPlaybackSpeedControl(playbackSpeed: playbackSpeed, canPlay: canPlay,
                                        onChangePlaybackSpeed: onChangePlaybackSpeed)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)

            Divider()

            GeometryReader { geometry in
                let draggedPosition = draggedFrameIndex.flatMap { index in frames.firstIndex(where: { $0.index == index }) }
                VStack(spacing: 0) {
                    GIFTimelineScrollView(scrollOffset: $scrollOffset, contentWidth: contentWidth,
                                          canSelectFrames: !isFrameSettling,
                                          frameIndices: frames.map(\.index),
                                          onSelectFrames: { targets in
                                              guard !targets.isSubset(of: frameSelection.indices) else { return }
                                              frameSelection.include(targets, displayedIndex: selectedFrameIndex)
                                          },
                                          onToggleFrameSelection: { clickFrame($0, toggling: true) },
                                          onSelectionDragChanged: { selecting in
                                              isSelectingFrames = selecting
                                              if selecting { onStopPlayback() }
                                          },
                                          onFrameDragUpdated: updateFrameDrag,
                                          onFrameDragExited: { frameDropPosition = nil },
                                          onFrameDrop: dropFrame) {
                        LazyHStack(spacing: 8) {
                            ForEach(Array(frames.enumerated()), id: \.element.id) { position, frame in
                                GIFFrameDragSource(canDrag: canEditFrames && frames.count > 1 && !isFrameSettling,
                                                   onClick: { clickFrame(frame.index, toggling: $0.contains(.command)) },
                                                   onBegin: { offset in
                                                       frameGrabOffset = offset
                                                       draggedFrameIndex = frame.index
                                                       frameDropPosition = position
                                                       onBeginFrameDrag()
                                                   }, onEnd: endFrameDrag) {
                                    frameThumbnail(frame, number: framePosition(at: position, origin: draggedPosition) + 1)
                                }
                                .frame(width: GIFTimelineLayout.frameWidth, height: GIFTimelineLayout.frameHeight)
                                .opacity(draggedFrameIndex == frame.index ? 0 : 1)
                                .offset(x: frameOffset(at: position, origin: draggedPosition))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(width: contentWidth, alignment: .leading)
                        .contentShape(Rectangle())
                        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86), value: frameDropPosition)
                        .simultaneousGesture(timelineDragGesture(viewportWidth: geometry.size.width))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if let frameDropPosition {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white.opacity(0.035))
                                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.16)) }
                                .frame(width: GIFTimelineLayout.frameWidth, height: GIFTimelineLayout.frameHeight)
                                .position(x: GIFTimelineLayout.frameCenterX(at: frameDropPosition,
                                    contentWidth: contentWidth, viewportWidth: geometry.size.width, scrollOffset: scrollOffset),
                                    y: geometry.size.height / 2 - 8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let draggedFrameIndex, let frameDragLocation,
                           let frame = frames.first(where: { $0.index == draggedFrameIndex }),
                           let position = frames.firstIndex(where: { $0.index == draggedFrameIndex }) {
                            frameThumbnail(frame, number: framePosition(at: position, origin: position) + 1)
                                .frame(width: GIFTimelineLayout.frameWidth, height: GIFTimelineLayout.frameHeight)
                                .scaleEffect(reduceMotion || isFrameSettling ? 1 : 1.06)
                                .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                                .position(x: frameDragLocation.x - frameGrabOffset, y: frameDragLocation.y - 4)
                                .transition(.opacity)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .clipped()

                    scrollbar(viewportWidth: geometry.size.width)
                }
            }
        }
        .background(Color(white: 0.16))
        .accessibilityIdentifier("gifTimeline")
        .popover(isPresented: Binding(get: { maskCopyRequest != nil }, set: { shown in
            if !shown { maskCopyRequest = nil }
        }), arrowEdge: .top) {
            if let request = maskCopyRequest {
                GIFFrameMaskCopyPopover(request: request, frames: frames, frameMaskIndices: frameMaskIndices,
                    canEdit: canEditFrameMask && frameMaskIndices.contains(request.sourceFrameIndex),
                    onCopy: { onCopyFrameMask(request, $0) }, onCancel: { maskCopyRequest = nil })
            }
        }
        .onAppear { reconcileFrameSelection() }
        .onChange(of: frames.map(\.index)) {
            reconcileFrameSelection()
        }
        .onChange(of: selectedFrameIndex) { frameSelection.followDisplayedFrame(selectedFrameIndex) }
        .onChange(of: isPlaying) {
            if isPlaying { frameSelection.select(selectedFrameIndex, toggling: false, displayedIndex: selectedFrameIndex) }
        }
        .onChange(of: playbackLayerIDs) {
            if playbackScope == .all, isPlaying { onStopPlayback() }
        }
        .onChange(of: canPlay) { if !canPlay, isPlaying { onStopPlayback() } }
        .task(id: PlaybackState(isPlaying: isPlaying, speed: playbackSpeed, scope: playbackScope, frameIndices: frames.map(\.index),
                               frameDurations: frames.map(\.duration))) {
            await playFramesWhileNeeded()
        }
        .onDisappear {
            frameSettlementTask?.cancel()
            clearFrameDrag()
            frameSelection = GIFFrameSelection()
            maskCopyRequest = nil
            onStopPlayback()
        }
    }

    private func reconcileFrameSelection() {
        frameSelection.reconcile(with: Set(frames.map(\.index)), displayedIndex: selectedFrameIndex)
    }

    private func clickFrame(_ index: Int, toggling: Bool) {
        guard frames.contains(where: { $0.index == index }) else { return }
        onStopPlayback()
        frameSelection.select(index, toggling: toggling, displayedIndex: selectedFrameIndex)
        if !toggling { Task { await onSelectFrame(index) } }
        else if frameSelection.indices.count == 1, let remaining = frameSelection.indices.first, remaining != selectedFrameIndex {
            Task { await onSelectFrame(remaining) }
        }
    }

    private func frameOffset(at position: Int, origin: Int?) -> CGFloat {
        guard position != origin else { return 0 }
        return CGFloat(framePosition(at: position, origin: origin) - position) * Self.frameStride
    }

    private func framePosition(at position: Int, origin: Int?) -> Int {
        guard let destination = frameDropPosition, let origin else { return position }
        if position == origin { return destination }
        if origin < destination, position > origin, position <= destination { return position - 1 }
        if origin > destination, position >= destination, position < origin { return position + 1 }
        return position
    }

    private func updateFrameDrag(location: CGPoint, offset: CGFloat, viewportSize: CGSize) -> Bool {
        frameDragLocation = location
        frameDragViewportSize = viewportSize
        guard canEditFrames, let draggedFrameIndex,
              let origin = frames.firstIndex(where: { $0.index == draggedFrameIndex }),
              (0...viewportSize.width).contains(location.x),
              (0...viewportSize.height).contains(location.y) else {
            frameDropPosition = nil
            return false
        }
        let inset = GIFTimelineLayout.centeringInset(contentWidth: contentWidth, viewportWidth: viewportSize.width)
        frameDropPosition = GIFTimelineLayout.destination(for: location.x + offset - frameGrabOffset - inset,
            count: frames.count, current: frameDropPosition ?? origin)
        return true
    }

    private func dropFrame() -> Bool {
        guard canEditFrames, let draggedFrameIndex, let frameDropPosition else { return false }
        onMoveFrame(draggedFrameIndex, frameDropPosition)
        settleFrame(at: frameDropPosition)
        return true
    }

    private func endFrameDrag() {
        guard !isFrameSettling, let draggedFrameIndex,
              let origin = frames.firstIndex(where: { $0.index == draggedFrameIndex }) else { return }
        settleFrame(at: origin)
    }

    private func settleFrame(at position: Int) {
        frameSettlementTask?.cancel()
        withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.86)) {
            isFrameSettling = true
            frameDragLocation = CGPoint(x: GIFTimelineLayout.frameCenterX(at: position, contentWidth: contentWidth,
                viewportWidth: frameDragViewportSize.width, scrollOffset: scrollOffset) + frameGrabOffset,
                y: frameDragViewportSize.height / 2 + 4)
        }
        frameSettlementTask = Task {
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 180)) }
            catch { return }
            clearFrameDrag()
        }
    }

    private func clearFrameDrag() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            draggedFrameIndex = nil
            frameDropPosition = nil
            frameDragLocation = nil
            isFrameSettling = false
        }
    }

    private func playFramesWhileNeeded() async {
        if playbackScope == .all {
            if isPlaying, canPlay { await onPlayAllFrames() }
            return
        }
        guard isPlaying, canPlay, let selectedPosition = frames.firstIndex(where: { $0.index == selectedFrameIndex }) else { return }
        do {
            try await GIFPreviewPlayback.play(durations: frames.map { playbackSpeed.duration(for: $0) },
                                               startingAt: selectedPosition) { position in
                await onSelectFrame(frames[position].index)
            }
        } catch {
            // Playback paused, its settings changed, or the timeline closed.
        }
    }

    private func timelineDragGesture(viewportWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard draggedFrameIndex == nil, !isSelectingFrames, !NSEvent.modifierFlags.contains(.command) else { return }
                if timelineDragStartOffset == nil { timelineDragStartOffset = scrollOffset }
                isTimelineDragging = true
                guard let timelineDragStartOffset else { return }
                scrollOffset = clampedOffset(timelineDragStartOffset - value.translation.width, viewportWidth: viewportWidth)
            }
            .onEnded { _ in
                timelineDragStartOffset = nil
                isTimelineDragging = false
            }
    }

    @ViewBuilder
    private func scrollbar(viewportWidth: CGFloat) -> some View {
        let trackWidth = max(0, viewportWidth - 24)
        let maximumOffset = max(0, contentWidth - viewportWidth)
        let ratio = min(1, viewportWidth / max(1, contentWidth))
        let thumbWidth = min(trackWidth, max(min(28, trackWidth), trackWidth * ratio))

        if maximumOffset > 0, trackWidth > 0 {
            let maximumThumbOffset = max(0, trackWidth - thumbWidth)
            let thumbOffset = maximumOffset == 0 ? 0 : maximumThumbOffset * scrollOffset / maximumOffset

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: 0.10))
                    .frame(height: 4)

                Capsule()
                    .fill(isDragging ? Color(white: 0.76) : Color(white: 0.40))
                    .frame(height: 4)
                    .frame(width: thumbWidth, height: 14)
                    .offset(x: thumbOffset)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if scrollbarStartOffset == nil { scrollbarStartOffset = scrollOffset }
                                isScrollbarDragging = true
                                guard let scrollbarStartOffset else { return }
                                let delta = value.translation.width / max(1, maximumThumbOffset) * maximumOffset
                                scrollOffset = clampedOffset(scrollbarStartOffset + delta, viewportWidth: viewportWidth)
                            }
                            .onEnded { _ in
                                scrollbarStartOffset = nil
                                isScrollbarDragging = false
                            }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Timeline scrollbar")
                    .accessibilityValue("\(Int((scrollOffset / Self.frameStride).rounded()) + 1) of \(frames.count)")
                    .help("Drag to scroll through animation frames")
            }
            .frame(height: 14)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
            .animation(.easeOut(duration: 0.12), value: isDragging)
        } else {
            Color.clear.frame(height: 16)
        }
    }

    private func clampedOffset(_ offset: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        min(max(0, contentWidth - viewportWidth), max(0, offset))
    }

    private var frameMaskButtonLabel: String {
        if frameSelection.indices.count > 1 { return "Add masks to \(frameSelection.indices.count) selected frames" }
        if hasSelectedFrameMask { return isFrameMaskSelected ? "Edit frame pixels" : "Edit this frame’s mask" }
        return "Add a mask to the selected frame"
    }

    private var frameMaskButtonHelp: String {
        if frameSelection.indices.count > 1 { return "Add masks to selected frames without replacing existing masks." }
        guard hasSelectedFrameMask else { return "Add a mask to this frame." }
        return isFrameMaskSelected ? "Edit the frame's pixels." : "Edit this frame's mask."
    }

    private var frameMaskVisibilityLabel: String {
        guard hasSelectedFrameMask else { return "No mask on the selected frame" }
        return isSelectedFrameMaskEnabled ? "Disable this frame’s mask" : "Enable this frame’s mask"
    }

    private var frameMaskVisibilityHelp: String {
        isSelectedFrameMaskEnabled ? "Disable this frame’s mask in the canvas and exports."
            : "Enable this frame’s mask in the canvas and exports."
    }

    private func frameThumbnail(_ frame: GIFTimelineFrame, number: Int) -> some View {
        let isSelected = frameSelection.indices.contains(frame.index)
        let isDisplayed = frame.index == selectedFrameIndex
        let targets: Set<Int> = isSelected ? frameSelection.indices : [frame.index]
        return Button {
            clickFrame(frame.index, toggling: NSEvent.modifierFlags.contains(.command))
        } label: {
            VStack(spacing: 3) {
                Image(decorative: frame.thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 82, height: 52)
                    .clipped()
                    .padding(3)
                    .background(Color(white: 0.22), in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.12),
                                          lineWidth: isSelected ? (isDisplayed ? 2 : 1.5) : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if frameMaskIndices.contains(frame.index) {
                            Image(systemName: "rectangle.inset.filled")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 3))
                                .padding(4)
                                .accessibilityHidden(true)
                        }
                    }
                Text("\(number)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isDisplayed ? Color.primary : isSelected ? Color.accentColor : Color.secondary)
            }
            .frame(width: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if targets.count > 1 { batchFrameMenu(targets: targets) }
            else { singleFrameMenu(frame) }
        }
        .help("Click to display frame \(number). Command-click to toggle selection; Command-drag to select frames along the path. Drag to reorder this frame.")
        .accessibilityLabel("Frame \(number)")
        .accessibilityValue(isSelected ? (isDisplayed ? "Selected, displayed" : "Selected") : isDisplayed ? "Displayed" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("gifTimelineFrame\(number)")
    }

    @ViewBuilder private func batchFrameMenu(targets: Set<Int>) -> some View {
        let canAddMasks = canEditFrameMask && !targets.isSubset(of: frameMaskIndices)
        let canDeleteMasks = canEditFrameMask && !targets.isDisjoint(with: frameMaskIndices)
        let canDeleteFrames = canEditFrames && targets.count < frames.count
        if canAddMasks {
            Button("Add Masks") { Task { await onAddFrameMasks(targets) } }
        }
        if canDeleteMasks {
            Button("Delete Masks", role: .destructive) { onDeleteFrameMasks(targets) }
        }
        if canAddMasks || canDeleteMasks { Divider() }
        Button("Delete \(targets.count) Frames", role: .destructive) {
            Task { await onDeleteFrames(targets) }
        }
        .disabled(!canDeleteFrames)
    }

    @ViewBuilder private func singleFrameMenu(_ frame: GIFTimelineFrame) -> some View {
        if frameMaskIndices.contains(frame.index) {
            Button("Delete Mask") { onDeleteFrameMask(frame.index) }
                .disabled(!canEditFrameMask)
        } else {
            Button("Add Mask") { Task { await onAddFrameMask(frame.index) } }
                .disabled(!canEditFrameMask)
        }
        Button(enabledFrameMaskIndices.contains(frame.index) ? "Disable Mask" : "Enable Mask") {
            onToggleFrameMaskEnabledAtIndex(frame.index)
        }
        .disabled(!canEditFrameMask || !frameMaskIndices.contains(frame.index))
        Button("Copy Mask to Frames…") { maskCopyRequest = onPrepareFrameMaskCopy(frame.index) }
            .disabled(!canEditFrameMask || !frameMaskIndices.contains(frame.index) || frames.count <= 1)
        Divider()
        Button("Duplicate Frame") { Task { await onDuplicateFrame(frame.index) } }
            .disabled(!canEditFrames || frames.count >= GIFTimelineLimits.maxFrames)
        Button("Delete Frame", role: .destructive) { Task { await onDeleteFrames([frame.index]) } }
            .disabled(!canEditFrames || frames.count <= 1)
    }
}
