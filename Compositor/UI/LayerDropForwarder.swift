import AppKit
import SwiftUI

/// Laid over the Layers panel's blend and opacity controls while a layer drag that has left the list (for the system's
/// drag, to copy into another tab) is in progress: if it comes back over them, they hand it to the list as though it
/// were at the list's top, so a release puts the layer first, and show it as the list does, full size rather than as the
/// smaller copy image. Otherwise the window's own drop took it there, as a copy into this document.
struct LayerDropForwarder: NSViewRepresentable {
    let session: EditorSession
    func makeNSView(context: Context) -> ForwardingView {
        let view = ForwardingView()
        view.session = session
        view.registerForDraggedTypes([NativeLayerList.Coordinator.layerType])
        return view
    }
    func updateNSView(_ view: ForwardingView, context: Context) { view.session = session }

    final class ForwardingView: NSView {
        weak var session: EditorSession?
        private var table: NSTableView? { session?.layerList }

        /// The drag as the list sees it: just inside its top edge, above the first row it shows.
        private func moved(_ info: NSDraggingInfo) -> NSDraggingInfo? {
            guard let table, let scroll = table.enclosingScrollView else { return nil }
            let visible = scroll.contentView.bounds
            return MovedDraggingInfo(info, at: table.convert(NSPoint(x: visible.midX, y: visible.minY + 1), to: nil))
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let table, let moved = moved(sender) else { return [] }
            return table.draggingEntered(moved)
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let table, let moved = moved(sender) else { return [] }
            return table.draggingUpdated(moved)
        }
        override func draggingExited(_ sender: NSDraggingInfo?) {
            table?.draggingExited(sender.flatMap(moved))
        }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let table, let moved = moved(sender) else { return false }
            return table.prepareForDragOperation(moved)
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let table, let moved = moved(sender) else { return false }
            return table.performDragOperation(moved)
        }
        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            table?.concludeDragOperation(sender.flatMap(moved))
        }
        /// AppKit asks the view under a drag how its items look: as the list draws the row, full size, not the copy image.
        override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {
            guard let sender, let image = session?.layerDragImage else { return }
            let pointer = convert(sender.draggingLocation, from: nil)
            sender.draggingFormation = .none
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                let old = item.draggingFrame
                let across = old.width > 0 ? (pointer.x - old.minX) / old.width : 0.5
                let down = old.height > 0 ? (pointer.y - old.minY) / old.height : 0.5
                let size = image.size
                item.setDraggingFrame(NSRect(x: pointer.x - across * size.width, y: pointer.y - down * size.height,
                                             width: size.width, height: size.height), contents: image)
            }
        }
    }
}

/// A drag, passed on with its location moved: everything else is the drag's own.
private final class MovedDraggingInfo: NSObject, NSDraggingInfo {
    private let base: NSDraggingInfo
    private let location: NSPoint
    init(_ base: NSDraggingInfo, at location: NSPoint) { self.base = base; self.location = location }
    var draggingDestinationWindow: NSWindow? { base.draggingDestinationWindow }
    var draggingSourceOperationMask: NSDragOperation { base.draggingSourceOperationMask }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { base.draggedImageLocation }
    var draggedImage: NSImage? { base.draggedImage }
    var draggingPasteboard: NSPasteboard { base.draggingPasteboard }
    var draggingSource: Any? { base.draggingSource }
    var draggingSequenceNumber: Int { base.draggingSequenceNumber }
    func slideDraggedImage(to screenPoint: NSPoint) { base.slideDraggedImage(to: screenPoint) }
    var draggingFormation: NSDraggingFormation {
        get { base.draggingFormation }
        set { base.draggingFormation = newValue }
    }
    var animatesToDestination: Bool {
        get { base.animatesToDestination }
        set { base.animatesToDestination = newValue }
    }
    var numberOfValidItemsForDrop: Int {
        get { base.numberOfValidItemsForDrop }
        set { base.numberOfValidItemsForDrop = newValue }
    }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        base.enumerateDraggingItems(options: enumOpts, for: view, classes: classArray, searchOptions: searchOptions, using: block)
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { base.springLoadingHighlight }
    func resetSpringLoading() { base.resetSpringLoading() }
}
