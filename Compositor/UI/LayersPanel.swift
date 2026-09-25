import SwiftUI

struct LayersPanel: View {
    @Bindable var session: EditorSession
    /// Dragging the panel's left edge sets it, within `widths`.
    var width: CGFloat = 252
    static let widths: ClosedRange<Double> = 202...352

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layers").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(session.document?.layers.count ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    .accessibilityIdentifier("layerCount")
            }.padding(18)
            Divider()
            LayerAppearanceControls(session: session, layerID: session.activeLayerID).id(session.activeLayerID)
            Divider()
            if let layers = session.document?.layers, !layers.isEmpty {
                NativeLayerList(session: session)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.3.layers.3d").font(.system(size: 25, weight: .light))
                    Text("No layers yet").font(.callout.weight(.medium))
                    Text(localized(session.document == nil ? "Create a canvas or import an image." : "Import an image or add a blank layer."))
                        .font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary).padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            // No spacing: each button's hit area supplies it (8 pt either side makes the 16 pt gap).
            HStack(spacing: 0) {
                Button { session.addBlankLayer() } label: { Image(systemName: "plus.square").footerHitArea() }
                    .help(localized("New blank layer (⇧⌘N)")).accessibilityLabel(localized("New blank layer"))
                    .accessibilityIdentifier("addBlankLayer").disabled(!session.canEditLayers)
                Button { session.groupSelectedLayers() } label: { Image(systemName: "folder.badge.plus").footerHitArea() }
                    .help(localized("Group selected layers (⌘G)")).accessibilityLabel(localized("New folder")).disabled(!session.canEditLayers)
                LayerMaskMenu(session: session)
                Menu {
                    ForEach(LayerEffectKind.allCases, id: \.self) { kind in
                        Button(localized(kind.rawValue) + "…") { session.addEffect(kind) }
                    }
                } label: { Image(systemName: "sparkles").footerHitArea() }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(localized("Layer effects: stroke and drop shadow")).accessibilityLabel(localized("Layer effects"))
                    .accessibilityIdentifier("layerEffects").disabled(!session.canEditEffects)
                Menu {
                    ForEach(AdjustmentKind.allCases, id: \.self) { kind in
                        Button(localized(kind.rawValue)) { session.addAdjustment(kind) }
                    }
                } label: { Image(systemName: "circle.lefthalf.filled").footerHitArea() }
                    .menuStyle(.borderlessButton).fixedSize().help(localized("New adjustment layer")).disabled(!session.canEditLayers)
                Spacer()
                Button { session.deleteLayerOrMask() } label: { Image(systemName: "trash").footerHitArea() }
                    .help(localized(session.selectedEffect != nil ? "Delete selected effect" : session.isMaskSelected ? "Delete layer mask" : session.selectedLayerIDs.count > 1 ? "Delete selected layers" : "Delete selected layer"))
                    .accessibilityLabel(localized(session.selectedEffect != nil ? "Delete selected effect" : session.isMaskSelected ? "Delete layer mask" : session.selectedLayerIDs.count > 1 ? "Delete selected layers" : "Delete selected layer"))
                    .accessibilityIdentifier("deleteLayer")
                    .disabled(!session.canEditLayers || session.activeLayer == nil)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4) // Plus the hit areas' 8 and 12: the original 16.

        }
        .frame(width: width)
        .task(id: session.adjustmentEditingID) {
            if let id = session.adjustmentEditingID { await session.beginAdjustmentEditing(id) }
        }
    }

}

extension View {
    /// Makes a small footer icon easier to click. The padding is the clickable area, so the
    /// footer's own spacing is reduced to match and every icon keeps its old position.
    /// (Negative padding to hand the space back does not work: the button then only answers
    /// clicks inside its shrunken frame.)
    func footerHitArea() -> some View {
        padding(.horizontal, 8).padding(.vertical, 12)
            .contentShape(Rectangle())
    }
}

