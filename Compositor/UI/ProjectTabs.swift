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
            .background {
                ProjectWindowBridge(controller: workspace.current.controller).frame(width: 0, height: 0)
            }
    }
}

struct ProjectTabStrip: View {
    let workspace: ProjectWorkspace
    @State private var dragging = false
    /// Scrolled away from the first tab, so the left edge fades too.
    @State private var scrolledFromStart = false
    /// The tabs' own width, so the strip can claim only the room it uses.
    @State private var contentWidth: CGFloat?
    @State private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private let dragTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 0) {
            // Only as wide as the tabs themselves. A scroll view hit-tests its whole frame however little
            // it holds, so one stretched to the toolbar's full width swallows every title-bar drag that
            // starts in the middle of the window.
            tabs.frame(maxWidth: contentWidth ?? .infinity).layoutPriority(1)
            // The room the tabs don't need stays title bar, and keeps dragging the window.
            Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
        }
        .frame(height: 34, alignment: .center)
    }
    private var tabs: some View {
        ScrollViewReader { reader in
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(workspace.tabs) { tab in
                    ProjectTabButton(workspace: workspace, tab: tab).id(tab.id)
                }
                if dragging {
                    NewTabDropSlot(workspace: workspace).id("new-tab-drop")
                }
            }
            .frame(height: 34, alignment: .center)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .frame(height: 34, alignment: .center)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x > 1 } action: { _, scrolled in
            scrolledFromStart = scrolled
        }
        // Tabs fade out where they scroll under an edge instead of being cut off — the right edge always, the left
        // once scrolled away from the first tab. A mask rather than a painted gradient, so whatever the toolbar shows
        // behind them shows through.
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: scrolledFromStart ? 28 : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28)
            }
            .animation(.easeOut(duration: 0.15), value: scrolledFromStart)
        }
        .accessibilityLabel("Project tabs")
        .onChange(of: workspace.selectedID) { _, id in reader.scrollTo(id) }
        .onChange(of: dragging) { _, active in
            if active { reader.scrollTo("new-tab-drop", anchor: .trailing) }
            else { reader.scrollTo(workspace.selectedID) }
        }
        .onReceive(dragTimer) { _ in
            // External drags don't deliver mouse-down to our window. Track the
            // drag pasteboard's new session, and clear on release/cancel.
            let pasteboard = NSPasteboard(name: .drag)
            if NSEvent.pressedMouseButtons == 0 {
                dragging = false
                dragChangeCount = pasteboard.changeCount
            } else if pasteboard.changeCount != dragChangeCount {
                dragging = pasteboard.availableType(from: [.fileURL, .png, .tiff, NSPasteboard.PasteboardType(ProjectWorkspace.layerType)]) != nil
            }
        }
        }
    }
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
            .help("Drop to open in a new canvas")
            .accessibilityLabel("Drop into new canvas")
            .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, ProjectWorkspace.layerType], delegate:
                ProjectTabDropDelegate(workspace: workspace, destination: nil, targeted: $targeted))
    }
}

private struct ProjectTabButton: View {
    let workspace: ProjectWorkspace
    let tab: ProjectTab
    @State private var targeted = false
    private var active: Bool { workspace.selectedID == tab.id }
    var body: some View {
        HStack(spacing: 0) {
            Button { workspace.select(tab.id) } label: {
                HStack(spacing: 5) {
                    if tab.session.isModified { Circle().frame(width: 5, height: 5).accessibilityLabel("Unsaved changes") }
                    Text(tab.title).font(.system(size: 12, weight: active ? .semibold : .medium)).lineLimit(1)
                }
                .frame(minWidth: 35, maxWidth: 155)
                .padding(.leading, 11).padding(.trailing, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!workspace.canSwitch && !active)
            Button { Task { await workspace.close(tab.id) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 28)
                    .padding(.trailing, 5)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("Close \(tab.title)").disabled(!workspace.canSwitch)
                .accessibilityLabel("Close \(tab.title)")
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
