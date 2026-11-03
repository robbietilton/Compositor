import SwiftUI

struct LayersPanel: View {
    @Bindable var session: EditorSession
    /// Dragging the panel's left edge sets it, within `widths`.
    var width: CGFloat = 261
    /// No narrower than the footer: its icons can't shrink, and a footer wider than the panel pushed everything in
    /// it out past both edges, over the edge that resizes it.
    static let widths: ClosedRange<Double> = 261...372

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LayersHeader(session: session)
            Divider()
            LayerAppearanceControls(session: session, layerID: session.activeLayerID).id(session.activeLayerID)
            Divider()
            if let layers = session.document?.layers, !layers.isEmpty {
                if session.isFilteringLayers, session.filteredLayerRows.isEmpty {
                    LayersUnavailableView("No layers match the filter.", systemImage: "line.3.horizontal.decrease.circle.fill") {
                        Button("Clear All") {
                            session.clearLayerSearch()
                            session.clearLayerTypeFilter()
                        }
                        .controlSize(.large)
                    }
                } else {
                    NativeLayerList(session: session)
                }
            } else {
                LayersUnavailableView("No layers yet", systemImage: "square.3.layers.3d") {
                    Text(session.document == nil ? "Create a canvas or import a file." : "Import a file or add a blank layer.")
                }
            }
            Divider()
            LayersFooter(session: session)

        }
        .frame(width: width)
        .task(id: session.adjustmentEditingID) {
            if let id = session.adjustmentEditingID { await session.beginAdjustmentEditing(id) }
        }
    }
}

/// The panel's empty states: a light icon over a title, with a line or two of detail beneath.
private struct LayersUnavailableView<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 25, weight: .light))
            Text(title).font(.callout.weight(.medium))
            content()
                .font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary).padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The buttons under the layers: new layer, folder, mask, adjustment and filter layers, effects, and delete.
struct LayersFooter: View {
    let session: EditorSession

    var body: some View {
        // No spacing: each button's hit area supplies it (8 pt either side makes the 16 pt gap).
        HStack(spacing: 0) {
            Button { session.addBlankLayer() } label: { FooterIcon(systemName: "plus.square") }
                .help("New blank layer (⇧⌘N)").accessibilityLabel("New blank layer")
                .accessibilityIdentifier("addBlankLayer").disabled(!session.layersLookEditable)
            Button { session.groupSelectedLayers() } label: { FooterIcon(systemName: "folder.badge.plus") }
                .help("Group selected layers (⌘G)").accessibilityLabel("New folder").disabled(!session.layersLookEditable)
            LayerMaskMenu(session: session)
            // Two menus, as the menu bar has: the Image menu's adjustments, then the Filter menu's filters.
            FooterMenu(systemName: "circle.lefthalf.filled", items: AdjustmentKind.imageAdjustments.map { kind in
                (kind.rawValue, { session.addAdjustment(kind) })
            })
                .help("New adjustment layer").accessibilityLabel("New adjustment layer")
                .disabled(!session.layersLookEditable)
            FooterMenu(items: AdjustmentKind.filters.map { kind in
                (kind.rawValue, { session.addAdjustment(kind) })
            }) { CheckerCircleIcon() }
                .help("New filter layer").accessibilityLabel("New filter layer")
                .disabled(!session.layersLookEditable)
            FooterMenu(systemName: "sparkles", items: LayerEffectKind.allCases.map { kind in
                (kind.rawValue + "…", { session.addEffect(kind) })
            })
                .help("Add layer effect").accessibilityLabel("Layer effects")
                .accessibilityIdentifier("layerEffects").disabled(!session.layersLookEditable || session.activeLayer?.isGroup != false || session.activeLayer?.asset == nil)
            Spacer()
            Button { session.deleteLayerOrMask() } label: { FooterIcon(systemName: "trash") }
                .help(session.selectedEffect != nil ? "Delete selected effect" : session.isMaskSelected ? "Delete layer mask" : session.selectedLayerIDs.count > 1 ? "Delete selected layers" : "Delete selected layer")
                .accessibilityLabel(session.selectedEffect != nil ? "Delete selected effect" : session.isMaskSelected ? "Delete layer mask" : session.selectedLayerIDs.count > 1 ? "Delete selected layers" : "Delete selected layer")
                .accessibilityIdentifier("deleteLayer")
                .disabled(!session.layersLookEditable || session.activeLayer == nil)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4) // Plus the hit areas' 8 and 12: the original 16.
    }
}

/// A footer button that opens a menu, with the plain buttons' whole hit area: a SwiftUI Menu's pop-up button is only as
/// tall as its icon, however much room its label is given. Its arrow is the pop-up's.
struct FooterMenu<Icon: View>: View {
    let items: [(title: String, action: @MainActor () -> Void)]
    @ViewBuilder let icon: () -> Icon
    @State private var anchor = FooterMenuAnchor()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { anchor.show(items) } label: {
            HStack(spacing: 3) {
                icon()
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.white.opacity(0.5)))
            .background(FooterMenuAnchorView(anchor: anchor))
            // As wide as a pop-up button's, its arrow taking the room the plain buttons give to padding; as tall as theirs.
            .padding(.horizontal, 4).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }
}

extension FooterMenu where Icon == Image {
    init(systemName: String, items: [(title: String, action: @MainActor () -> Void)]) {
        self.init(items: items) { Image(systemName: systemName) }
    }
}

/// The filter layers' button: a ring with a checkered disc inside, beside the adjustments' half-filled circle. The
/// ring is the system's own circle, so it matches that icon's size and weight.
struct CheckerCircleIcon: View {
    var body: some View {
        Image(systemName: "circle").overlay {
            Canvas { context, size in
                // The disc a little inside the ring, four squares across it.
                let side = min(size.width, size.height) * 0.62
                let disc = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
                context.clip(to: Path(ellipseIn: disc))
                let square = side / 4
                for row in 0..<4 {
                    for column in 0..<4 where (row + column) % 2 == 0 {
                        context.fill(Path(CGRect(x: disc.minX + CGFloat(column) * square, y: disc.minY + CGFloat(row) * square,
                                                 width: square, height: square)), with: .foreground)
                    }
                }
            }
        }
    }
}

/// Where a `FooterMenu`'s menu opens: just above its icon, which sits at the bottom of the window.
@MainActor final class FooterMenuAnchor {
    weak var view: NSView?

    func show(_ items: [(title: String, action: @MainActor () -> Void)]) {
        guard let view else { return }
        let menu = NSMenu()
        for item in items { menu.addItem(FooterMenuItem(title: item.title, action: item.action)) }
        // The menu's top-left corner goes at the point given, so its own height plus a gap above the icon's top.
        let top = menu.size.height + 6
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? -top : view.bounds.maxY + top), in: view)
    }
}

private final class FooterMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(title: title, action: #selector(choose), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("Not used") }

    @objc private func choose() { MainActor.assumeIsolated { run() } }
}

private struct FooterMenuAnchorView: NSViewRepresentable {
    let anchor: FooterMenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = Passthrough()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }

    /// Only a place to open from: clicks go on to the button.
    private final class Passthrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
