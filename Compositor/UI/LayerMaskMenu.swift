import SwiftUI

/// Adds a mask in one click: all white, or with a selection, the selection black.
/// Enable/Disable and Delete live in the layer's context menu.
struct LayerMaskMenu: View {
    let session: EditorSession
    var body: some View {
        Button { session.addMask() } label: { Image(systemName: "rectangle.inset.filled").footerHitArea() }
            .buttonStyle(.borderless)
            .help((session.selection == nil ? "Add layer mask" : "Add layer mask (the selection becomes black)").localized)
            .accessibilityLabel("Add layer mask")
            .disabled(!session.canEditMask || session.activeLayer?.mask != nil)
    }
}
