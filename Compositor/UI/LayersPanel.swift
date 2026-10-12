import SwiftUI

struct LayersPanel: View {
    @Bindable var session: EditorSession
    @State private var page = Page.layers
    /// Dragging the panel's left edge sets it, within `widths`.
    var width: CGFloat = 252
    /// No narrower than the footer: its icons can't shrink, and a footer wider than the panel pushed everything in
    /// it out past both edges, over the edge that resizes it.
    static let widths: ClosedRange<Double> = 222...352

    private enum Page { case layers, channels }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                panelTab(.layers, title: "Layers")
                panelTab(.channels, title: "Channel")
                Spacer()
                if page == .layers {
                    Text("\(session.document?.layers.count ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        .accessibilityIdentifier("layerCount")
                }
            }.padding(.horizontal, 10).padding(.vertical, 10)
            Divider()
            if page == .layers {
                layers
            } else {
                ChannelsPanel(session: session)
            }
        }
        .frame(width: width)
        .task(id: session.adjustmentEditingID) {
            if let id = session.adjustmentEditingID { await session.beginAdjustmentEditing(id) }
        }
    }

    private func panelTab(_ target: Page, title: String) -> some View {
        Button { page = target } label: {
            Text(L10n.string(title)).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 9).frame(height: 28)
                .background(page == target ? Color.white.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(target == .layers ? "layersTab" : "channelsTab")
    }

    @ViewBuilder private var layers: some View {
        LayerAppearanceControls(session: session, layerID: session.activeLayerID).id(session.activeLayerID)
        Divider()
        if let documentLayers = session.document?.layers, !documentLayers.isEmpty {
            NativeLayerList(session: session)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "square.3.layers.3d").font(.system(size: 25, weight: .light))
                Text(L10n.string("No layers yet")).font(.callout.weight(.medium))
                Text(L10n.string(session.document == nil ? "Create a canvas or import an image."
                                                         : "Import an image or add a blank layer."))
                    .font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary).padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        Divider()
        layerFooter
    }

    /// No spacing: each button's hit area supplies it (8 pt either side makes the 16 pt gap).
    private var layerFooter: some View {
        HStack(spacing: 0) {
            Button { session.addBlankLayer() } label: { FooterIcon(systemName: "plus.square") }
                .help(Text(L10n.string("New blank layer (⇧⌘N)"))).accessibilityLabel(Text(L10n.string("New blank layer")))
                .accessibilityIdentifier("addBlankLayer").disabled(!session.layersLookEditable)
            Button { session.groupSelectedLayers() } label: { FooterIcon(systemName: "folder.badge.plus") }
                .help(Text(L10n.string("Group selected layers (⌘G)"))).accessibilityLabel(Text(L10n.string("New folder"))).disabled(!session.layersLookEditable)
            LayerMaskMenu(session: session)
            Menu {
                ForEach(AdjustmentKind.allCases, id: \.self) { kind in
                    Button(L10n.string(kind.rawValue)) { session.addAdjustment(kind) }
                }
            } label: { Image(systemName: "circle.lefthalf.filled").footerHitArea() }
                .menuStyle(.borderlessButton).fixedSize().help(Text(L10n.string("New adjustment layer"))).disabled(!session.layersLookEditable)
            Menu {
                ForEach(LayerEffectKind.allCases, id: \.self) { kind in
                    Button(L10n.string(kind.rawValue) + "…") { session.addEffect(kind) }
                }
            } label: { Image(systemName: "sparkles").footerHitArea() }
                .menuStyle(.borderlessButton).fixedSize()
                .help(Text(L10n.string("Add layer effect"))).accessibilityLabel(Text(L10n.string("Layer effects")))
                .accessibilityIdentifier("layerEffects").disabled(!session.layersLookEditable || session.activeLayer?.isGroup != false || session.activeLayer?.asset == nil)
            Spacer()
            Button { session.deleteLayerOrMask() } label: { FooterIcon(systemName: "trash") }
                .help(Text(L10n.string(session.selectedEffect != nil ? "Delete selected effect"
                    : session.isMaskSelected ? "Delete layer mask"
                    : session.selectedLayerIDs.count > 1 ? "Delete selected layers" : "Delete selected layer")))
                .accessibilityLabel(Text(L10n.string(session.selectedEffect != nil ? "Delete selected effect"
                    : session.isMaskSelected ? "Delete layer mask"
                    : session.selectedLayerIDs.count > 1 ? "Delete selected layers" : "Delete selected layer")))
                .accessibilityIdentifier("deleteLayer")
                .disabled(!session.layersLookEditable || session.activeLayer == nil)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4) // Plus the hit areas' 8 and 12: the original 16.
    }
}

private struct ChannelsPanel: View {
    @Bindable var session: EditorSession
    @State private var thumbnails: [CanvasChannel: CGImage] = [:]

    var body: some View {
        VStack(spacing: 1) {
            ForEach(CanvasChannel.allCases, id: \.self) { channel in
                Button { session.canvasChannel = channel } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "eye")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 24)
                            .opacity(isVisible(channel) ? 1 : 0)
                        channelThumbnail(channel)
                        Text(L10n.string(channel.titleKey)).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(shortcutLabel(channel)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                    .background(session.canvasChannel == channel ? Color.accentColor.opacity(0.18)
                                                                  : Color.white.opacity(0.035))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.document == nil)
                .accessibilityIdentifier("channel.\(channel.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .task(id: NavigatorMinimap.RenderKey(document: session.document, revision: session.brushRevision)) {
            guard let image = session.navigatorImage(maxSide: 96) else { thumbnails = [:]; return }
            thumbnails = Dictionary(uniqueKeysWithValues: CanvasChannel.allCases.compactMap { channel in
                channel.thumbnail(from: image).map { (channel, $0) }
            })
        }
    }

    private func isVisible(_ channel: CanvasChannel) -> Bool {
        session.canvasChannel == .rgb || session.canvasChannel == channel
    }

    private func shortcutLabel(_ channel: CanvasChannel) -> String {
        let title = channel.titleKey + " Channel"
        guard let definition = ShortcutDefinition.all.first(where: { $0.title == title }) else {
            return "⌘\(channel.shortcut)"
        }
        return ShortcutSettings.shared.chord(definition).label
    }

    @ViewBuilder private func channelThumbnail(_ channel: CanvasChannel) -> some View {
        ZStack {
            Color(white: 0.15)
            if let image = thumbnails[channel] {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium).scaledToFit()
            }
        }
        .frame(width: 38, height: 38)
        .overlay { Rectangle().strokeBorder(Color.white.opacity(0.20), lineWidth: 1) }
    }
}

/// A footer button's icon: full strength when the button can be used, and as dim as the footer's menus (Effects,
/// Adjustments) when it can't. A plain button with its own color doesn't dim when disabled, so the footer looked
/// uneven, some disabled icons barely fading and others nearly gone.
struct FooterIcon: View {
    let systemName: String
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        // Disabled, as dim as the menus' icons (a quarter-strength white, measured): SwiftUI halves a disabled
        // button's own color again, so the button asks for half-strength white.
        Image(systemName: systemName)
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.white.opacity(0.5)))
            .footerHitArea()
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
