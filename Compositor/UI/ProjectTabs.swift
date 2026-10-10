import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Combine

struct ProjectWorkspaceView: View {
    let applicationDelegate: CompositorApplicationDelegate
    private var workspace: ProjectWorkspace { applicationDelegate.workspace }
    var body: some View {
        ContentView(session: workspace.current.session, applicationDelegate: applicationDelegate)
            .id(workspace.current.id)
            .disabled(workspace.isManaging)
            .psdConversionSheet(workspace.current.session)
            .rawDevelopSheet(workspace.current.session)
            .background {
                ProjectWindowBridge(controller: workspace.current.controller).frame(width: 0, height: 0)
            }
    }
}

/// A tab mid-drag: `id` is being reordered, `translation` is how far the pointer has moved from where the
/// press started, and `others`/`compactedX` are the rest of the visible tabs laid out as if `id` weren't
/// there — the row they slide into as the drop target changes. Captured once at drag start; `order` in
/// `projectTabOverflow` doesn't change again until the drag commits.
private struct TabReorderState {
    let id: UUID
    let others: [UUID]
    let widths: [UUID: CGFloat]
    let compactedX: [UUID: CGFloat]
    let startX: CGFloat
    let originX: CGFloat
    var translation: CGFloat = 0
    var targetIndex: Int = 0

    /// The gap the dragged tab is closest to: where it would land if let go now. Slot `k` opens where the k-th of
    /// the other tabs sits, or after the last one.
    func nearestSlot() -> Int {
        let x = originX + translation
        let end = others.last.map { (compactedX[$0] ?? startX) + (widths[$0] ?? 0) + projectTabSpacing } ?? startX
        let slots = others.map { compactedX[$0] ?? startX } + [end]
        return slots.indices.min { abs(slots[$0] - x) < abs(slots[$1] - x) } ?? 0
    }
}

private enum TabDragPhase {
    case changed(CGFloat)
    case ended(CGFloat)
}

struct ProjectTabStrip: View {
    let workspace: ProjectWorkspace
    /// An external pasteboard drag (a file, or a layer from the panel) is in the air over the app.
    @State private var dragging = false
    @State private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private let dragTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    /// The "New" drop slot's own natural width, measured once it appears.
    @State private var dropSlotWidth: CGFloat = 0
    /// A tab being reordered by drag, if any.
    @State private var reorder: TabReorderState?
    /// Mirrors the width `GeometryReader` offers `body`, for gesture handlers — they run outside a body
    /// evaluation and can't read its proxy directly. Never read *inside* the reader itself: the tabs it lays
    /// out have their own exact width, and sizing the reader's own budget from a value that a wider child
    /// could inflate would let it feed back into itself and get stuck believing it has unlimited room.
    @State private var slotWidth: CGFloat = 0

    private func widths() -> [UUID: CGFloat] {
        Dictionary(uniqueKeysWithValues: workspace.tabs.map {
            ($0.id, projectTabPillWidth($0, active: workspace.selectedID == $0.id, closable: workspace.canClose($0)))
        })
    }
    private func overflow(availableWidth: CGFloat) -> ProjectTabOverflow {
        projectTabOverflow(order: workspace.tabs.map(\.id), widths: widths(), selectedID: workspace.selectedID,
                           availableWidth: availableWidth, pillWidth: projectTabOverflowPillWidth)
    }
    private func contentWidth(_ layout: ProjectTabOverflow) -> CGFloat {
        layout.contentWidth + (dragging ? dropSlotWidth + projectTabSpacing : 0)
    }
    /// Gesture handlers run between body evaluations, so they work off the last width `GeometryReader` reported.
    private var currentLayout: ProjectTabOverflow { overflow(availableWidth: slotWidth) }

    var body: some View {
        GeometryReader { proxy in
            let layout = overflow(availableWidth: proxy.size.width)
            let width = contentWidth(layout)
            HStack(spacing: 0) {
                // Only as wide as the tabs actually drawn. A view that claims more than that hit-tests the
                // whole frame it's given even over the part with nothing in it, and on macOS 26 that click
                // does not pass through to the title bar (macOS 27 often does). The remainder is an explicit
                // window drag, so the middle of the title bar moves the window on both.
                tabs(layout: layout, contentWidth: width)
                    .frame(maxWidth: width, alignment: .leading)
                    .layoutPriority(1)
                TitleBarDragArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 34, alignment: .leading)
            .onAppear { slotWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, new in slotWidth = new }
        }
        .frame(height: 34)
    }

    private func tabs(layout: ProjectTabOverflow, contentWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let pill = layout.pill {
                OverflowTabsPill(workspace: workspace, hiddenIDs: layout.hiddenIDs)
                    .frame(width: pill.width, height: 28)
                    .offset(x: pill.x, y: 3)
            }
            ForEach(layout.visible) { slot in tabView(for: slot, contentWidth: contentWidth) }
            if dragging {
                NewTabDropSlot(workspace: workspace)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { dropSlotWidth = $0 }
                    .offset(x: layout.contentWidth + projectTabSpacing, y: 3)
            }
        }
        .frame(width: contentWidth, height: 34, alignment: .topLeading)
        .accessibilityLabel("Project tabs")
        .onReceive(dragTimer) { _ in
            // External drags don't deliver mouse-down to our window. Track the
            // drag pasteboard's new session, and clear on release/cancel.
            let pasteboard = NSPasteboard(name: .drag)
            if NSEvent.pressedMouseButtons == 0 {
                // A tab drag whose gesture was cancelled rather than ended (its tab closed under it) is over too.
                if reorder != nil { reorder = nil }
                dragging = false
                dragChangeCount = pasteboard.changeCount
            } else if pasteboard.changeCount != dragChangeCount {
                dragging = pasteboard.availableType(from: [.fileURL, .png, .tiff, NSPasteboard.PasteboardType(ProjectWorkspace.layerType)]) != nil
            }
        }
    }

    @ViewBuilder private func tabView(for slot: ProjectTabSlot, contentWidth: CGFloat) -> some View {
        if let tab = workspace.tabs.first(where: { $0.id == slot.id }) {
            let isDragged = reorder?.id == slot.id
            ProjectTabButton(workspace: workspace, tab: tab) { handleReorder(tab.id, $0) }
                .frame(width: slot.width, height: 28)
                .offset(x: renderX(for: slot, contentWidth: contentWidth), y: 3)
                .zIndex(isDragged ? 1 : 0)
                // The dragged tab tracks the pointer with no lag; the tabs it's crossing ease into their new
                // slot. Scoping the animation to this one value keeps it off the dragged tab's own offset.
                .animation(isDragged ? nil : .easeOut(duration: 0.15), value: reorder?.targetIndex)
        }
    }

    /// Where a slot actually renders: its static layout position, or — mid-drag — the dragged tab following
    /// the pointer (clamped to the row) and the rest opening a gap at the current drop target.
    private func renderX(for slot: ProjectTabSlot, contentWidth: CGFloat) -> CGFloat {
        guard let reorder else { return slot.x }
        if slot.id == reorder.id {
            return min(max(reorder.originX + reorder.translation, reorder.startX), max(reorder.startX, contentWidth - slot.width))
        }
        guard let x = reorder.compactedX[slot.id], let index = reorder.others.firstIndex(of: slot.id) else { return slot.x }
        let draggedWidth = reorder.widths[reorder.id] ?? 0
        return index >= reorder.targetIndex ? x + draggedWidth + projectTabSpacing : x
    }

    private func handleReorder(_ id: UUID, _ phase: TabDragPhase) {
        switch phase {
        case .changed(let translation):
            if reorder == nil {
                guard workspace.canSwitch, abs(translation) >= 3 else { return }
                workspace.select(id) // dragging a tab selects it, as it does in Safari and Chrome
                reorder = makeReorderState(for: id)
            }
            guard reorder?.id == id else { return }
            reorder?.translation = translation
            if let state = reorder { reorder?.targetIndex = state.nearestSlot() }
        case .ended:
            // Busy by the time the drag ends (a reload from disk, say): the tabs just go back where they were.
            if let state = reorder, state.id == id, workspace.canSwitch { commitReorder(state) }
            reorder = nil
        }
    }

    private func makeReorderState(for id: UUID) -> TabReorderState {
        let layout = currentLayout
        let tabWidths = widths()
        let others = layout.visible.map(\.id).filter { $0 != id }
        let startX = layout.visible.first?.x ?? 0
        var x = startX
        var compactedX: [UUID: CGFloat] = [:]
        for otherID in others {
            compactedX[otherID] = x
            x += (tabWidths[otherID] ?? 0) + projectTabSpacing
        }
        let originX = layout.visible.first { $0.id == id }?.x ?? startX
        return TabReorderState(id: id, others: others, widths: tabWidths, compactedX: compactedX, startX: startX, originX: originX)
    }

    /// Applies the drag's final drop target to the workspace's real order. Only the tabs that were visible
    /// when the drag started ever move; everything else stays exactly where it was.
    private func commitReorder(_ state: TabReorderState) {
        let order = workspace.tabs.map(\.id)
        guard let from = order.firstIndex(of: state.id) else { return }
        var target: Int
        if state.targetIndex < state.others.count, let neighbor = order.firstIndex(of: state.others[state.targetIndex]) {
            target = neighbor
        } else if let last = state.others.last, let lastIndex = order.firstIndex(of: last) {
            target = lastIndex + 1
        } else {
            target = from
        }
        if from < target { target -= 1 }
        workspace.moveTab(state.id, to: target)
    }
}

@MainActor
private func projectTabLabelWidth(_ tab: ProjectTab, active: Bool) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 12, weight: active ? .semibold : .medium)
    let titleWidth = (tab.title as NSString).size(withAttributes: [.font: font]).width
    let dotWidth: CGFloat = tab.session.isModified ? 10 : 0 // 5 px dot and 5 px gap
    return min(155, max(35, ceil(titleWidth) + dotWidth))
}

@MainActor
private func projectTabPillWidth(_ tab: ProjectTab, active: Bool, closable: Bool) -> CGFloat {
    // 11 px leading, 8 px trailing, 16 px close button, 5 px after close; with no close button, 11 px each side.
    projectTabLabelWidth(tab, active: active) + (closable ? 40 : 22)
}

/// Sized the same way the tab pills are: text measured at the same weight, plus the chevron and padding.
private func projectTabOverflowPillWidth(hiddenCount: Int) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    let text = projectTabOverflowLabel(for: hiddenCount)
    let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
    return ceil(textWidth) + 11 + 4 + 10 + 11 // leading, gap before chevron, chevron, trailing
}

/// The title-bar gap beside the tabs. A click here would otherwise land on the tabs' own container,
/// and on macOS 26 that mouse-down does not pass through to the window.
final class TitleBarDragView: NSView {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct TitleBarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarDragView { TitleBarDragView(frame: .zero) }
    func updateNSView(_ view: TitleBarDragView, context: Context) {}
}

private struct NewTabDropSlot: View {
    let workspace: ProjectWorkspace
    @State private var targeted = false
    var body: some View {
        Label("New", systemImage: "plus")
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).frame(height: 28)
            .background(targeted ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(targeted ? Color.accentColor : Color.secondary,
                style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [4, 3])))
            .contentShape(Capsule())
            .fixedSize()
            .help("Drop to open in a new canvas")
            .accessibilityLabel("Drop into new canvas")
            .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, ProjectWorkspace.layerType], delegate:
                ProjectTabDropDelegate(workspace: workspace, destination: nil, targeted: $targeted))
    }
}

/// The far-left pill standing in for the tabs that don't fit. Styled like an inactive tab pill; clicking it
/// drops a native menu below it listing the hidden tabs in their real order.
private struct OverflowTabsPill: View {
    let workspace: ProjectWorkspace
    let hiddenIDs: [UUID]
    private var label: String { projectTabOverflowLabel(for: hiddenIDs.count) }
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .opacity(workspace.canSwitch ? 1 : 0.5)
        .background(Color.white.opacity(0.035), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        // A SwiftUI Menu draws its own label, chevron first; this keeps the pill reading "3 more tabs ⌄".
        .overlay(OverflowMenuAnchor(label: label) {
            guard workspace.canSwitch else { return [] }
            return hiddenIDs.compactMap { id in
                workspace.tabs.first { $0.id == id }.map { tab in
                    ((tab.session.isModified ? "• " : "") + tab.title, { workspace.select(tab.id) })
                }
            }
        })
        .help(label)
        .accessibilityIdentifier("projectTabsOverflow")
    }
}

/// Clicking the overflow pill opens its menu just below it, as a pop-up button does.
private struct OverflowMenuAnchor: NSViewRepresentable {
    let label: String
    let items: () -> [(title: String, action: () -> Void)]
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.items = items
        view.setAccessibilityLabel(label)
    }
    final class AnchorView: NSView {
        var items: () -> [(title: String, action: () -> Void)] = { [] }
        private var actions: [() -> Void] = []
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
        override func accessibilityPerformPress() -> Bool { showMenu(); return true }
        override func mouseDown(with event: NSEvent) { showMenu() }
        private func showMenu() {
            let entries = items()
            guard !entries.isEmpty else { return }
            actions = entries.map(\.action)
            let menu = NSMenu()
            for (index, entry) in entries.enumerated() {
                let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
        }
        @objc private func choose(_ item: NSMenuItem) {
            if actions.indices.contains(item.tag) { actions[item.tag]() }
        }
    }
}

private struct ProjectTabButton: View {
    let workspace: ProjectWorkspace
    let tab: ProjectTab
    let onReorder: (TabDragPhase) -> Void
    @State private var targeted = false
    private var active: Bool { workspace.selectedID == tab.id }
    var body: some View {
        HStack(spacing: 0) {
            Button { workspace.select(tab.id) } label: {
                HStack(spacing: 5) {
                    if tab.session.isModified {
                        Circle().frame(width: 5, height: 5).accessibilityLabel("Unsaved changes")
                    }
                    Text(tab.title).font(.system(size: 12, weight: active ? .semibold : .medium)).lineLimit(1)
                }
                .frame(width: projectTabLabelWidth(tab, active: active), alignment: .leading)
                .padding(.leading, 11).padding(.trailing, workspace.canClose(tab) ? 8 : 11)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!workspace.canSwitch && !active)
            // A press that moves more than a few points reorders the tab instead of selecting it; either way
            // it selects, same as dragging a tab in Safari or Chrome.
            // Measured in the window, not the tab: the tab moves with the pointer, and measuring from a space that
            // moves along with it made the tab outrun the pointer.
            .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { onReorder(.changed($0.translation.width)) }
                .onEnded { onReorder(.ended($0.translation.width)) })
            // The only tab, still blank, has nothing to close: no button, and the pill closes up around its name.
            if workspace.canClose(tab) {
                Button { Task { await workspace.close(tab.id) } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 16, height: 28)
                        .padding(.trailing, 5)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("Close \(tab.title)").disabled(!workspace.canSwitch)
                    .accessibilityLabel("Close \(tab.title)")
            }
        }
        .frame(height: 28)
        .background(targeted ? Color.accentColor.opacity(0.3) : Color.white.opacity(active ? 0.12 : 0.035), in: Capsule())
        .overlay(Capsule().strokeBorder(targeted ? Color.accentColor : Color.white.opacity(active ? 0.22 : 0.08), lineWidth: targeted ? 2 : 1))
        .help(targeted ? "Add to \(tab.title)" : tab.title)
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, ProjectWorkspace.layerType], delegate:
            ProjectTabDropDelegate(workspace: workspace, destination: tab.id, targeted: $targeted))
    }
}

struct NewProjectDropTarget: ViewModifier {
    let workspace: ProjectWorkspace?
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
            .help(targeted ? "Open in a new project tab" : "New canvas (⌘N) · Drop images here for new tabs")
            .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, ProjectWorkspace.layerType], delegate:
                ProjectTabDropDelegate(workspace: workspace, destination: nil, targeted: $targeted))
    }
}

extension ProjectWorkspace {
    /// The tab a layer drag started from: drops carry only the layer's id, and the drag pasteboard can be read
    /// while the drag is still in the air, before any drop.
    var draggedLayerSource: UUID? {
        guard let value = NSPasteboard(name: .drag).string(forType: NSPasteboard.PasteboardType(Self.layerType)),
              let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return tabs.first { $0.session.document?.layers.contains { $0.id == id } == true }?.id
    }
    /// Dragging a layer onto the canvas or tab it already lives in would do nothing, so that isn't a drop target.
    /// Other tabs, a new tab, and every file drag still are.
    func canReceiveDrag(into destination: UUID?) -> Bool {
        guard let destination, let source = draggedLayerSource else { return true }
        return source != destination
    }
}

private struct ProjectTabDropDelegate: DropDelegate {
    let workspace: ProjectWorkspace?
    let destination: UUID?
    @Binding var targeted: Bool
    func validateDrop(info: DropInfo) -> Bool {
        // Option-dragging a layer duplicates it within the Layers panel, so it is not a drag to another project.
        if NSEvent.modifierFlags.contains(.option), info.hasItemsConforming(to: [ProjectWorkspace.layerType]) { return false }
        return workspace?.canSwitch == true && workspace?.canReceiveDrag(into: destination) == true
            && info.hasItemsConforming(to: [ProjectWorkspace.layerType, UTType.fileURL.identifier, UTType.image.identifier])
    }
    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard let workspace, validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [ProjectWorkspace.layerType, UTType.fileURL.identifier, UTType.image.identifier])
        Task { await workspace.receiveProviders(providers, into: destination) }
        return true
    }
}
