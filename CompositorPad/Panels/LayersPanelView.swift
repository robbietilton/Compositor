import UIKit

/// The Layers panel, as the Mac's: how many layers there are, the active layer's blend mode and opacity, the layers
/// top first with their visibility, thumbnails and masks, and the buttons that add and delete them. A long press on a
/// layer opens the Mac's menu for it; dragging it moves it, above another layer or into a folder.
final class LayersPanelView: UIView, UICollectionViewDelegate, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    var session: EditorSession? {
        didSet {
            guard session !== oldValue else { return }
            // Another tab's layers: none of this one's rows carry over.
            rows = []
            rowsByID = [:]
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            dataSource.apply(snapshot, animatingDifferences: false)
            setNeedsUpdateProperties()
        }
    }
    /// A project is opening in the tab: it has no layers yet, but isn't waiting for any to be made.
    var isOpening = false { didSet { if isOpening != oldValue { setNeedsUpdateProperties() } } }
    /// Shows the rename prompt.
    weak var presenter: UIViewController?

    static let width: CGFloat = 252

    private let count = UILabel()
    private let blend = PopUpButton()
    private let opacity = SliderField(caption: "Opacity", unit: "%", sliderRange: 0...1, fieldRange: 0...1, fieldScale: 100,
                                      sensitivity: 0.01, sliderWidth: nil)
    private lazy var list = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
    private let empty = UIStackView()
    private let emptyDetail = UILabel()
    private let dropLine = UIView()
    private let dropFolder = UIView()
    private var footer: [(button: UIButton, enabled: (EditorSession) -> Bool)] = []

    /// A layer's row as last shown; one that differs from the next is drawn again.
    fileprivate struct Row: Equatable {
        let layer: ImageLayer
        let depth: Int
        let visible: Bool
        let selected: Bool
        /// Whether the row's picture or its mask's is the paint target: outlined, as on the Mac.
        let target: Target?
        let collapsed: Bool
        let enabled: Bool
        let canvas: CGSize
        let clippedTo: String?
        var id: UUID { layer.id }
        enum Target { case image, mask }
    }
    private var rows: [Row] = []
    private var rowsByID: [UUID: Row] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        let title = UILabel()
        title.text = "Layers"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .tertiaryLabel
        let header = OptionControls.row([title, UIView(), count])

        blend.accessibilityLabel = "Blend mode"
        blend.onChoose = { [weak self] name in
            guard let mode = LayerBlendMode(rawValue: name) else { return }
            self?.session?.setLayerBlendMode(mode)
        }
        blend.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let blendRow = OptionControls.row([OptionControls.caption("Blend", color: .secondaryLabel), blend])
        opacity.onStart = { [weak self] in self?.session?.beginOpacityEdit() }
        opacity.onChange = { [weak self] in self?.session?.setLayerOpacity($0) }
        opacity.onFinish = { [weak self] in self?.session?.finishOpacityEdit() }
        let appearance = UIStackView(arrangedSubviews: [blendRow, opacity])
        appearance.axis = .vertical
        appearance.spacing = 10

        list.backgroundColor = .clear
        list.delegate = self
        list.dragDelegate = self
        list.dropDelegate = self
        list.dragInteractionEnabled = true
        list.accessibilityIdentifier = "layersList"
        let registration = UICollectionView.CellRegistration<LayerRowCell, UUID> { [weak self] cell, _, id in
            guard let self, let session = self.session, let row = self.rowsByID[id] else { return }
            cell.configure(row, session: session)
            cell.onRename = { [weak self] in self?.rename(id) }
            cell.onEditAdjustment = { [weak self] in self?.editAdjustment(id) }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: list) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        for indicator in [dropLine, dropFolder] {
            indicator.isHidden = true
            indicator.isUserInteractionEnabled = false
            indicator.layer.zPosition = 10
            list.addSubview(indicator)
        }
        dropLine.backgroundColor = .tintColor
        dropLine.layer.cornerRadius = 1
        dropFolder.layer.borderColor = UIColor.tintColor.cgColor
        dropFolder.layer.borderWidth = 2
        dropFolder.layer.cornerRadius = 8

        let emptyIcon = UIImageView(image: UIImage(systemName: "square.3.layers.3d",
                                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .light)))
        emptyIcon.tintColor = .secondaryLabel
        let emptyTitle = UILabel()
        emptyTitle.text = "No layers yet"
        emptyTitle.font = .preferredFont(forTextStyle: .callout).withWeight(.medium)
        emptyTitle.textColor = .secondaryLabel
        emptyDetail.font = .preferredFont(forTextStyle: .caption1)
        emptyDetail.textColor = .secondaryLabel
        emptyDetail.numberOfLines = 0
        emptyDetail.textAlignment = .center
        for view in [emptyIcon, emptyTitle, emptyDetail] as [UIView] { empty.addArrangedSubview(view) }
        empty.axis = .vertical
        empty.alignment = .center
        empty.spacing = 10

        let footerRow = UIStackView()
        footerRow.alignment = .center
        func footerButton(_ symbol: String, _ label: String, enabled: @escaping (EditorSession) -> Bool,
                          action: ((EditorSession) -> Void)?) -> UIButton {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            configuration.baseForegroundColor = .secondaryLabel
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = label
            button.toolTip = label
            button.widthAnchor.constraint(equalToConstant: 40).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            if let action {
                button.addAction(UIAction { [weak self] _ in if let session = self?.session { action(session) } }, for: .primaryActionTriggered)
            }
            footer.append((button, enabled))
            return button
        }
        let add = footerButton("plus.square", "New blank layer", enabled: { $0.canEditLayers }) { $0.addBlankLayer() }
        let group = footerButton("folder.badge.plus", "New folder", enabled: { $0.canEditLayers }) { $0.groupSelectedLayers() }
        let mask = footerButton("rectangle.inset.filled", "Add layer mask",
                                enabled: { $0.canEditMask && $0.activeLayer?.mask == nil }) { $0.addMask(revealing: true) }
        // Effects are edited in a panel the iPad doesn't have yet; shown dimmed, as the rail's tools that don't work by
        // touch are, so the footer reads as the Mac's does.
        let effects = footerButton("sparkles", "Layer effects (not on iPad yet)", enabled: { _ in false }, action: nil)
        let adjustments = footerButton("circle.lefthalf.filled", "New adjustment layer", enabled: { $0.canEditLayers && $0.document != nil },
                                       action: nil)
        // The Mac's list; the kinds without an editor on iPad yet are dimmed.
        adjustments.menu = UIMenu(children: AdjustmentKind.allCases.map { kind in
            let available = AdjustmentEditors.kinds.contains(kind) || kind == .invert
            return UIAction(title: kind.rawValue + (kind.isEditable ? "…" : ""), attributes: available ? [] : .disabled) { [weak self] _ in
                self?.session?.addAdjustment(kind)
            }
        })
        adjustments.showsMenuAsPrimaryAction = true
        let delete = footerButton("trash", "Delete", enabled: { $0.canEditLayers && $0.activeLayer != nil }) { $0.deleteLayerOrMask() }
        for view in [add, group, mask, effects, adjustments, UIView(), delete] as [UIView] { footerRow.addArrangedSubview(view) }

        let lines = (0..<3).map { _ in EditorWindowController.separator(vertical: false) }
        for view in [header, lines[0], appearance, lines[1], list, empty, lines[2], footerRow] as [UIView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            lines[0].topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            appearance.topAnchor.constraint(equalTo: lines[0].bottomAnchor, constant: 12),
            appearance.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), appearance.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            lines[1].topAnchor.constraint(equalTo: appearance.bottomAnchor, constant: 12),
            list.topAnchor.constraint(equalTo: lines[1].bottomAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor), list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.bottomAnchor.constraint(equalTo: lines[2].topAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            footerRow.topAnchor.constraint(equalTo: lines[2].bottomAnchor),
            footerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), footerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            footerRow.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ] + lines.flatMap { [$0.leadingAnchor.constraint(equalTo: leadingAnchor), $0.trailingAnchor.constraint(equalTo: trailingAnchor)] })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func layout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    // MARK: Following the editor

    override func updateProperties() {
        super.updateProperties()
        guard let session else { return }
        let layers = session.document?.layers ?? []
        count.text = "\(layers.count)"
        let active = session.activeLayer
        blend.show(LayerBlendMode.groups.map { $0.map(\.rawValue) }, chosen: (active.map { session.displayedBlendMode(for: $0) } ?? .normal).rawValue)
        blend.isEnabled = session.canEditAppearance
        opacity.show(active?.opacity ?? 1)
        opacity.isEnabled = session.canEditOpacity
        for (button, enabled) in footer { button.isEnabled = enabled(session) }
        let deleteTitle = session.selectedEffect != nil ? "Delete selected effect" : session.isMaskSelected ? "Delete layer mask"
            : session.selectedLayerIDs.count > 1 ? "Delete selected layers" : "Delete selected layer"
        footer.last?.button.accessibilityLabel = deleteTitle
        footer.last?.button.toolTip = deleteTitle

        empty.isHidden = !layers.isEmpty || session.document == nil && isOpening
        emptyDetail.text = session.document == nil ? "Create a canvas or import an image." : "Import an image or add a blank layer."
        show(rows(of: session))
    }

    private func rows(of session: EditorSession) -> [Row] {
        let byID = Dictionary(uniqueKeysWithValues: (session.document?.layers ?? []).map { ($0.id, $0) })
        let enabled = session.canEditLayers
        let canvas = session.document?.size ?? CGSize(width: 1, height: 1)
        let single = session.selectedLayerIDs.count == 1
        return session.layerRows.compactMap { entry in
            guard let layer = byID[entry.layer.id] else { return nil }
            let target: Row.Target? = single && session.activeLayerID == layer.id ? (session.isMaskSelected ? .mask : .image) : nil
            return Row(layer: layer, depth: entry.depth, visible: entry.visible,
                       selected: session.selectedEffect == nil && session.selectedLayerIDs.contains(layer.id),
                       target: target, collapsed: session.collapsedGroupIDs.contains(layer.id), enabled: enabled, canvas: canvas,
                       clippedTo: layer.maskSourceID.map { source in byID[source]?.name ?? "Missing source" })
        }
    }

    private func show(_ next: [Row]) {
        let old = rows
        rows = next
        rowsByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(next.map(\.id))
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let changed = next.filter { row in oldByID[row.id].map { $0 != row } ?? false }.map(\.id)
        snapshot.reconfigureItems(changed)
        let reordered = old.map(\.id) != next.map(\.id)
        guard reordered || !changed.isEmpty else { return }
        dataSource.apply(snapshot, animatingDifferences: reordered && !old.isEmpty && window != nil)
    }

    // MARK: Selecting

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        // The editor holds the selection; a tap goes to it (see `LayerRowCell`), and the rows draw what it says.
        false
    }

    fileprivate static func select(_ id: UUID, in session: EditorSession, rows: [UUID], modifiers: UIKeyModifierFlags) {
        if modifiers.contains(.command) {
            var ids = session.selectedLayerIDs
            if ids.contains(id), ids.count > 1 { ids.remove(id) } else { ids.insert(id) }
            session.selectLayers(ids, primary: ids.contains(id) ? id : session.activeLayerID)
        } else if modifiers.contains(.shift), let anchor = session.activeLayerID.flatMap({ rows.firstIndex(of: $0) }),
                  let index = rows.firstIndex(of: id) {
            session.selectLayers(Set(rows[min(anchor, index)...max(anchor, index)]), primary: id)
        } else if session.selectedLayerIDs == [id] {
            // A tap on the row of the one selected layer targets the layer itself, even when its mask was the target,
            // so transforming then moves layer and mask together.
            if session.isMaskSelected {
                session.commitTransform()
                session.selectLayerTarget(id, mask: false)
            }
        } else {
            session.selectLayers([id], primary: id)
        }
    }

    private func rename(_ id: UUID) {
        guard let session, session.canEditLayers, let layer = session.document?.layers.first(where: { $0.id == id }),
              let presenter else { return }
        let alert = UIAlertController(title: "Rename Layer", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = layer.name
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak session, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name != layer.name else { return }
            session?.renameLayer(id, to: name)
        })
        presenter.present(alert, animated: true)
    }

    // MARK: The layer's menu

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let session, let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        // As on the Mac, the row pressed becomes the selection unless it's already part of it.
        if !session.selectedLayerIDs.contains(id) { session.selectLayerTarget(id, mask: false) }
        else if session.activeLayerID != id { session.selectLayers(session.selectedLayerIDs, primary: id) }
        return UIContextMenuConfiguration(identifier: id as NSUUID, previewProvider: nil) { [weak self] _ in
            self?.menu(for: id, in: session)
        }
    }

    /// An adjustment layer's editor, as a double click on its thumbnail opens it on the Mac, for the kinds the iPad has one
    /// for.
    private func editAdjustment(_ id: UUID) {
        guard let session, session.canEditLayers,
              let kind = session.document?.layers.first(where: { $0.id == id })?.adjustment?.kind,
              AdjustmentEditors.kinds.contains(kind) else { return }
        session.selectLayer(id)
        session.adjustmentEditingID = id
    }

    /// The Mac's menu for a layer's row, in its order.
    private func menu(for id: UUID, in session: EditorSession) -> UIMenu {
        let layer = session.activeLayer
        func action(_ title: String, _ symbol: String? = nil, enabled: Bool, destructive: Bool = false,
                    _ perform: @escaping (EditorSession) -> Void) -> UIAction {
            var attributes: UIMenuElement.Attributes = enabled ? [] : .disabled
            if destructive { attributes.insert(.destructive) }
            return UIAction(title: title, image: symbol.flatMap { UIImage(systemName: $0) }, attributes: attributes) { [weak session] _ in
                if let session { perform(session) }
            }
        }
        let editable = session.canEditLayers && layer != nil
        let deleteTitle = session.isMaskSelected && layer?.mask != nil ? "Delete Mask"
            : session.selectedLayerIDs.count > 1 ? "Delete Selected Layers" : "Delete Layer"
        let adjustment = session.document?.layers.first { $0.id == id }?.adjustment
        let basics = UIMenu(options: .displayInline, children: (adjustment == nil ? [] : [
            action("Edit Adjustment…", "slider.horizontal.3", enabled: editable && AdjustmentEditors.kinds.contains(adjustment!.kind)) {
                [weak self] _ in self?.editAdjustment(id)
            },
        ]) + [
            action("Duplicate Layer", "plus.square.on.square", enabled: editable) { $0.duplicateActiveLayer() },
            action("Rename…", "pencil", enabled: editable && session.selectedLayerIDs.count == 1) { [weak self] _ in self?.rename(id) },
            action(deleteTitle, "trash", enabled: editable, destructive: true) { $0.deleteLayerOrMask() },
        ])
        var arranging: [UIMenuElement] = [
            action(layer?.maskSourceID != nil ? "Release Clipping Mask" : "Create Clipping Mask",
                   enabled: session.activeLayerID.map { session.canToggleClippingMask($0) } ?? false) { session in
                if let id = session.activeLayerID { session.toggleClippingMask(id) }
            },
            action("Group Selected Layers", "folder.badge.plus",
                   enabled: session.canEditLayers && (session.document?.layers.count ?? 0) < 10_000 && !session.selectedLayerIDs.isEmpty) {
                $0.groupSelectedLayers()
            },
        ]
        // A folder can be ungrouped: its layers stay where they are, and the folder goes.
        if layer?.isGroup == true {
            arranging.append(action("Ungroup Layers", enabled: session.canUngroupLayers) { $0.ungroupLayers() })
        }
        arranging.append(action("Move Out of Folder", enabled: session.canEditLayers && layer?.parentID != nil) { $0.moveActiveLayerOutOfGroup() })
        arranging.append(action(session.mergeTitle, enabled: session.canMergeLayers) { $0.mergeLayers() })
        let hasMask = layer?.mask != nil
        let canAddMask = session.canEditMask && !hasMask
        let addMask: UIMenuElement = canAddMask
            ? UIMenu(title: "Add Mask", image: UIImage(systemName: "rectangle.inset.filled"), children: [
                action("Reveal All (White)", enabled: true) { $0.selectLayerTarget(id, mask: false); $0.addMask(revealing: true) },
                action("Hide All (Black)", enabled: true) { $0.selectLayerTarget(id, mask: false); $0.addMask(revealing: false) },
            ])
            : action("Add Mask", "rectangle.inset.filled", enabled: false) { _ in }
        let masks = UIMenu(options: .displayInline, children: [
            addMask,
            action(layer?.mask?.isEnabled == false ? "Enable Mask" : "Disable Mask", enabled: session.canEditMask && hasMask) {
                $0.selectLayerTarget(id, mask: false)
                $0.toggleLayerMask()
            },
            action("Delete Mask", enabled: session.canEditMask && hasMask) {
                $0.selectLayerTarget(id, mask: false)
                $0.deleteLayerMask()
            },
            action(layer?.mask?.isLinked == false ? "Link Mask" : "Unlink Mask",
                   enabled: session.canEditLayers && hasMask && layer?.isGroup == false && layer?.adjustment == nil) { session in
                if let id = session.activeLayerID { session.toggleMaskLink(id) }
            },
        ])
        let visibility = action(layer?.isVisible == false ? "Show Layer" : "Hide Layer", layer?.isVisible == false ? "eye" : "eye.slash",
                                enabled: editable) { session in
            if let id = session.activeLayerID { session.toggleLayerVisibility(id) }
        }
        return UIMenu(children: [basics, UIMenu(options: .displayInline, children: arranging), masks,
                                 UIMenu(options: .displayInline, children: [visibility])])
    }

    // MARK: Moving layers

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning dragSession: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard let session, session.canEditLayers, let id = dataSource.itemIdentifier(for: indexPath) else { return [] }
        // The row dragged brings the other selected rows along when it's one of them, as on the Mac.
        let ids = dragged(session.selectedLayerIDs.contains(id) ? session.selectedLayerIDs : [id], in: session)
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = ids
        return [item]
    }

    /// Every layer being dragged, in the order the list shows them, leaving out anything inside a dragged folder,
    /// which the folder brings along itself.
    private func dragged(_ ids: Set<UUID>, in session: EditorSession) -> [UUID] {
        let carried = ids.reduce(into: Set<UUID>()) { $0.formUnion(session.descendantIDs(of: $1)) }
        return session.layerRows.map(\.layer.id).filter { ids.contains($0) && !carried.contains($0) }
    }

    private func draggedIDs(_ dropSession: UIDropSession) -> [UUID]? {
        guard dropSession.localDragSession != nil, dropSession.items.count == 1 else { return nil }
        return dropSession.items.first?.localObject as? [UUID]
    }

    /// Where a drop at `point` goes, as the Mac's list places it: above the row it's over (or below, past the row's
    /// middle), or into a folder when it's over a folder's middle.
    private func dropTarget(at point: CGPoint) -> (row: Int, intoFolder: Bool) {
        guard !rows.isEmpty else { return (0, false) }
        if let indexPath = list.indexPathForItem(at: point), let frame = list.layoutAttributesForItem(at: indexPath)?.frame {
            let fraction = (point.y - frame.minY) / max(1, frame.height)
            if rows[indexPath.item].layer.isGroup, fraction > 0.25, fraction < 0.75 { return (indexPath.item, true) }
            return (fraction < 0.5 ? indexPath.item : indexPath.item + 1, false)
        }
        let top = list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.minY ?? 0
        return (point.y < top ? 0 : rows.count, false)
    }

    private func accepts(_ ids: [UUID], at target: (row: Int, intoFolder: Bool)) -> Bool {
        guard let session, session.canEditLayers, !ids.isEmpty else { return false }
        let parent = target.intoFolder ? rows[target.row].id : (rows.indices.contains(target.row) ? rows[target.row].layer.parentID : nil)
        return ids.allSatisfy { session.canPlaceLayer($0, in: parent) }
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate dropSession: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        let target = dropTarget(at: dropSession.location(in: list))
        guard let ids = draggedIDs(dropSession), accepts(ids, at: target) else {
            showDropTarget(nil)
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        showDropTarget(target)
        return UICollectionViewDropProposal(operation: .move, intent: .unspecified)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        showDropTarget(nil)
        let target = dropTarget(at: coordinator.session.location(in: list))
        guard let ids = draggedIDs(coordinator.session), accepts(ids, at: target) else { return }
        place(ids, at: target.row, intoFolder: target.intoFolder)
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession) { showDropTarget(nil) }
    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) { showDropTarget(nil) }

    /// A line where the layers will go, or an outline around the folder they'll go into, as the Mac's list shows.
    private func showDropTarget(_ target: (row: Int, intoFolder: Bool)?) {
        dropLine.isHidden = target == nil || target?.intoFolder == true
        dropFolder.isHidden = target?.intoFolder != true
        guard let target, !rows.isEmpty else { return }
        let frame = { (row: Int) in self.list.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame ?? .zero }
        if target.intoFolder {
            dropFolder.frame = frame(target.row).insetBy(dx: 4, dy: 1)
        } else {
            let y = target.row < rows.count ? frame(target.row).minY : frame(rows.count - 1).maxY
            let depth = rows.indices.contains(target.row) ? rows[target.row].depth : 0
            let indent = 8 + CGFloat(min(depth, 8)) * 20
            dropLine.frame = CGRect(x: indent, y: y - 1, width: list.bounds.width - indent - 8, height: 2)
        }
    }

    /// Moves the layers to the drop: above the row, into the folder, or to the bottom. The layers that moved stay
    /// selected, so they can be dragged on together.
    @discardableResult private func place(_ ids: [UUID], at row: Int, intoFolder: Bool) -> Bool {
        guard let session else { return false }
        // Where the drop lands is worked out once: each layer placed shifts the rows beneath it.
        let current = session.layerRows
        let parent: UUID?, above: UUID?, atBottom: Bool
        if intoFolder {
            parent = rows[row].id; above = nil; atBottom = false
        } else if row >= current.count {
            parent = nil; above = nil; atBottom = true
        } else {
            let target = current[row].layer
            parent = target.parentID; above = target.id; atBottom = false
        }
        // Dropped above a layer (or at the very bottom) the last one placed ends up nearest it, so they go in from the
        // top down; dropped into a folder each lands on top, so they go in from the bottom up.
        let order = intoFolder ? Array(ids.reversed()) : ids
        session.beginEdit(ids.count > 1 ? "Move Layers" : "Move Layer")
        var placed = false
        for id in order { placed = session.placeLayer(id, in: parent, above: above, atBottom: atBottom) || placed }
        if placed { session.selectLayers(Set(ids), primary: ids.first) }
        session.endEdit()
        return placed
    }
}

/// A layer's row: its visibility, the folder's disclosure, its picture framed by the canvas, its mask and the link
/// between them, its name and size, and its effects under it, as the Mac's rows are.
private final class LayerRowCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    static let height: CGFloat = 56
    static let effectHeight: CGFloat = 28

    var onRename: () -> Void = {}
    /// A double tap on an adjustment layer's thumbnail.
    var onEditAdjustment: () -> Void = {}
    private weak var session: EditorSession?
    private var layerID: UUID?
    private var rowIDs: () -> [UUID] = { [] }

    private let background = UIView()
    private let eye = UIButton(configuration: .plain())
    private let disclosure = UIButton(configuration: .plain())
    private let thumbnail = ThumbnailControl()
    private let link = UIButton(configuration: .plain())
    private let maskThumbnail = ThumbnailControl()
    private let maskOff = UILabel()
    private let name = UILabel()
    private let detail = UILabel()
    private let effects = UIStackView()
    private var indentation: NSLayoutConstraint!
    private var thumbnailSize: [NSLayoutConstraint] = []
    private var maskSize: [NSLayoutConstraint] = []
    private var maskSlotWidth: NSLayoutConstraint!
    private var maskGap: NSLayoutConstraint!
    private var height: NSLayoutConstraint!
    private var thumbnailKey: ThumbnailKey?
    private var maskKey: ThumbnailKey?

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.layer.cornerRadius = 8
        background.layer.cornerCurve = .continuous
        background.isUserInteractionEnabled = false
        eye.configuration?.baseForegroundColor = .secondaryLabel
        eye.addAction(UIAction { [weak self] _ in self?.perform { $0.toggleLayerVisibility($1) } }, for: .primaryActionTriggered)
        disclosure.configuration?.baseForegroundColor = .secondaryLabel
        disclosure.configuration?.contentInsets = .zero
        disclosure.addAction(UIAction { [weak self] _ in self?.perform { $0.toggleGroupExpansion($1) } }, for: .primaryActionTriggered)
        thumbnail.addAction(UIAction { [weak self] _ in self?.perform { $0.selectLayerTarget($1, mask: false) } }, for: .primaryActionTriggered)
        maskThumbnail.addAction(UIAction { [weak self] _ in self?.perform { $0.selectLayerTarget($1, mask: true) } }, for: .primaryActionTriggered)
        link.configuration?.baseForegroundColor = .secondaryLabel
        link.configuration?.contentInsets = .zero
        // The chain symbol runs corner to corner; turned 45° counterclockwise it stands upright in the narrow gap.
        link.transform = CGAffineTransform(rotationAngle: -.pi / 4)
        link.addAction(UIAction { [weak self] _ in self?.perform { $0.toggleMaskLink($1) } }, for: .primaryActionTriggered)
        maskOff.text = "╱"
        maskOff.font = .systemFont(ofSize: 32, weight: .medium)
        maskOff.textColor = .systemRed
        maskOff.isUserInteractionEnabled = false
        name.font = .systemFont(ofSize: 14)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        effects.axis = .vertical

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        for gesture in [tap, doubleTap] {
            gesture.delegate = self
            contentView.addGestureRecognizer(gesture)
        }

        let thumbnailSlot = UILayoutGuide(), maskSlot = UILayoutGuide()
        contentView.addLayoutGuide(thumbnailSlot)
        contentView.addLayoutGuide(maskSlot)
        for view in [background, eye, disclosure, thumbnail, link, maskThumbnail, maskOff, name, detail, effects] as [UIView] {
            contentView.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let middle = Self.height / 2
        indentation = disclosure.leadingAnchor.constraint(equalTo: eye.trailingAnchor)
        maskSlotWidth = maskSlot.widthAnchor.constraint(equalToConstant: 0)
        maskGap = maskSlot.leadingAnchor.constraint(equalTo: thumbnailSlot.trailingAnchor, constant: 5)
        thumbnailSize = [thumbnail.widthAnchor.constraint(equalToConstant: 36), thumbnail.heightAnchor.constraint(equalToConstant: 36)]
        maskSize = [maskThumbnail.widthAnchor.constraint(equalToConstant: 30), maskThumbnail.heightAnchor.constraint(equalToConstant: 30)]
        height = contentView.heightAnchor.constraint(equalToConstant: Self.height)
        height.priority = .init(999)
        NSLayoutConstraint.activate([
            height,
            background.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            background.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            background.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
            background.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1),
            eye.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            eye.centerYAnchor.constraint(equalTo: contentView.topAnchor, constant: middle),
            eye.widthAnchor.constraint(equalToConstant: 32), eye.heightAnchor.constraint(equalToConstant: 44),
            indentation,
            disclosure.centerYAnchor.constraint(equalTo: contentView.topAnchor, constant: middle),
            disclosure.widthAnchor.constraint(equalToConstant: 18), disclosure.heightAnchor.constraint(equalToConstant: 44),
            thumbnailSlot.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor),
            thumbnailSlot.widthAnchor.constraint(equalToConstant: 36),
            thumbnail.centerXAnchor.constraint(equalTo: thumbnailSlot.centerXAnchor),
            thumbnail.centerYAnchor.constraint(equalTo: contentView.topAnchor, constant: middle),
            maskGap, maskSlotWidth,
            link.centerXAnchor.constraint(equalTo: maskSlot.leadingAnchor, constant: -6.5),
            link.centerYAnchor.constraint(equalTo: contentView.topAnchor, constant: middle),
            link.widthAnchor.constraint(equalToConstant: 12), link.heightAnchor.constraint(equalToConstant: 30),
            maskThumbnail.centerXAnchor.constraint(equalTo: maskSlot.centerXAnchor),
            maskThumbnail.centerYAnchor.constraint(equalTo: contentView.topAnchor, constant: middle),
            maskOff.centerXAnchor.constraint(equalTo: maskThumbnail.centerXAnchor),
            maskOff.centerYAnchor.constraint(equalTo: maskThumbnail.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: maskSlot.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            name.bottomAnchor.constraint(equalTo: contentView.topAnchor, constant: middle - 1),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor), detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            detail.topAnchor.constraint(equalTo: contentView.topAnchor, constant: middle + 2),
            effects.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            effects.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            effects.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.height),
        ] + thumbnailSize + maskSize)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    fileprivate func configure(_ row: LayersPanelView.Row, session: EditorSession) {
        let layer = row.layer
        let changedLayer = layerID != layer.id
        self.session = session
        layerID = layer.id
        rowIDs = { [weak session] in session?.layerRows.map(\.layer.id) ?? [] }
        let indent = CGFloat(min(row.depth, 8)) * 20 + (layer.maskSourceID == nil ? 0 : 20)
        indentation.constant = indent

        eye.configuration?.image = UIImage(systemName: layer.isVisible ? "eye" : "eye.slash",
                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 13))
        eye.accessibilityLabel = "\(layer.isVisible ? "Hide" : "Show") \(layer.name)"
        eye.isEnabled = row.enabled
        disclosure.isHidden = !layer.isGroup
        disclosure.isEnabled = row.enabled
        disclosure.configuration?.image = UIImage(systemName: row.collapsed ? "chevron.right" : "chevron.down",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        disclosure.accessibilityLabel = row.collapsed ? "Expand folder" : "Collapse folder"

        // Pixel layers and masks show the whole canvas with their pixels where they sit, as Photoshop does; editable
        // text, adjustments and folders show a symbol. Pictures are drawn again only when what they show changes.
        let editableText = layer.liveText != nil
        let framed = layer.adjustment == nil && !layer.isGroup && !editableText
        let size = framed ? CanvasThumbnail.fittedSize(canvas: row.canvas, box: 36) : CGSize(width: 36, height: 36)
        thumbnailSize[0].constant = size.width
        thumbnailSize[1].constant = size.height
        let key = ThumbnailKey(image: layer.asset.map { ObjectIdentifier($0.thumbnail) }, transform: layer.transform,
                               canvas: row.canvas, editableText: editableText, symbol: Self.symbol(for: layer))
        if changedLayer || key != thumbnailKey {
            thumbnailKey = key
            if let symbol = key.symbol {
                thumbnail.show(symbol: symbol, quarterTurn: layer.adjustment?.kind == .curves)
            } else {
                thumbnail.show(CanvasThumbnail.layer(layer.asset?.thumbnail, transform: layer.transform, canvas: row.canvas, box: 36))
            }
        }
        let maskFitted = CanvasThumbnail.fittedSize(canvas: row.canvas, box: 30)
        maskSize[0].constant = maskFitted.width
        maskSize[1].constant = maskFitted.height
        let maskKey = ThumbnailKey(image: layer.mask.map { ObjectIdentifier($0.asset.thumbnail) }, transform: layer.maskTransform, canvas: row.canvas)
        if changedLayer || maskKey != self.maskKey {
            self.maskKey = maskKey
            if let mask = layer.mask {
                maskThumbnail.show(CanvasThumbnail.mask(mask.asset.thumbnail, transform: layer.maskTransform, canvas: row.canvas, box: 30))
            }
        }
        maskThumbnail.isHidden = layer.mask == nil
        maskSlotWidth.constant = layer.mask == nil ? 0 : 30
        maskOff.isHidden = layer.mask?.isEnabled != false
        let linkable = layer.mask != nil && layer.adjustment == nil && !layer.isGroup
        maskGap.constant = linkable ? 13 : 5
        link.isHidden = !linkable
        link.configuration?.image = layer.mask?.isLinked == false ? nil
            : UIImage(systemName: "link", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        link.accessibilityLabel = layer.mask?.isLinked == false ? "Link mask: \(layer.name)" : "Unlink mask: \(layer.name)"
        let usable = !session.showsBusy && !session.isImporting
        for control in [thumbnail, maskThumbnail, link] as [UIControl] { control.isEnabled = usable }
        thumbnail.accessibilityLabel = "Select \(editableText ? "text" : "image"): \(layer.name)"
        maskThumbnail.accessibilityLabel = "Select mask: \(layer.name)"
        thumbnail.outline(row.target == .image ? .tintColor : nil)
        maskThumbnail.outline(row.target == .mask ? .tintColor : nil)

        name.text = (layer.maskSourceID == nil ? "" : "↳ ") + layer.name
        detail.text = row.clippedTo.map { "Clipped to \($0)" }
            ?? (editableText ? "Text" : layer.adjustment != nil ? "Adjustment" : layer.isGroup ? "Folder" : layer.sizeLabel)
        background.backgroundColor = row.selected ? UIColor.tintColor.withAlphaComponent(0.28) : .clear
        contentView.alpha = row.visible ? 1 : 0.35

        effects.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for kind in layer.effects?.kinds ?? [] {
            effects.addArrangedSubview(effectRow(kind, enabled: layer.effects?.isEnabled(kind) == true, indent: indent, editable: row.enabled))
        }
        height.constant = Self.height + CGFloat(layer.effects?.kinds.count ?? 0) * Self.effectHeight

        isAccessibilityElement = false
        accessibilityElements = [eye, disclosure, thumbnail, link, maskThumbnail, name, detail, effects].filter { !$0.isHidden }
        name.accessibilityTraits = row.selected ? [.button, .selected] : .button
    }

    /// An effect under its layer, with its own visibility, as the Mac's effect rows. Editing it is the Mac's for now.
    private func effectRow(_ kind: LayerEffectKind, enabled: Bool, indent: CGFloat, editable: Bool) -> UIView {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: enabled ? "eye" : "eye.slash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11))
        configuration.baseForegroundColor = .secondaryLabel
        let eye = UIButton(configuration: configuration)
        eye.accessibilityLabel = (enabled ? "Hide " : "Show ") + kind.rawValue
        eye.isEnabled = editable
        eye.addAction(UIAction { [weak self] _ in self?.perform { $0.toggleEffect(kind, on: $1) } }, for: .primaryActionTriggered)
        let label = UILabel()
        label.text = kind.rawValue
        label.font = .systemFont(ofSize: 12)
        label.textColor = enabled ? .label : .secondaryLabel
        let row = UIView()
        for view in [eye, label] as [UIView] {
            row.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: Self.effectHeight),
            eye.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 40 + indent),
            eye.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            eye.widthAnchor.constraint(equalToConstant: 28), eye.heightAnchor.constraint(equalToConstant: Self.effectHeight),
            label.leadingAnchor.constraint(equalTo: eye.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
        ])
        return row
    }

    private func perform(_ action: (EditorSession, UUID) -> Void) {
        guard let session, let layerID else { return }
        action(session, layerID)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let session, let layerID else { return }
        LayersPanelView.select(layerID, in: session, rows: rowIDs(), modifiers: gesture.modifierFlags)
    }

    /// A double tap renames, or on an adjustment's thumbnail opens its editor, as a double click does on the Mac.
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        let onThumbnail = thumbnail.frame.insetBy(dx: -8, dy: -8).contains(gesture.location(in: contentView))
        if onThumbnail, let session, let layerID, session.document?.layers.first(where: { $0.id == layerID })?.adjustment != nil {
            onEditAdjustment()
        } else {
            onRename()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // A double tap renames without holding up the single tap that selects, as the Mac's list selects on mouse down.
        gestureRecognizer.view === other.view
    }

    /// The symbol a row shows for what has no pixels to picture: an adjustment's, editable text's, a folder's.
    private static func symbol(for layer: ImageLayer) -> String? {
        if let adjustment = layer.adjustment { return adjustment.kind.symbol }
        if layer.liveText != nil { return "textformat" }
        return layer.isGroup ? "folder" : nil
    }
}

/// What a row's picture shows, so it's drawn again only when one of these changes.
private struct ThumbnailKey: Equatable {
    let image: ObjectIdentifier?
    let transform: LayerTransform
    let canvas: CGSize
    var editableText = false
    var symbol: String?
}

/// A row's picture, or its mask's, which selects what it shows as the target when tapped.
private final class ThumbnailControl: UIControl {
    private let image = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFit
        image.tintColor = .secondaryLabel
        image.isUserInteractionEnabled = false
        layer.cornerRadius = 3
        clipsToBounds = true
        addSubview(image)
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor),
            image.topAnchor.constraint(equalTo: topAnchor), image.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ picture: UIImage) {
        image.contentMode = .scaleAspectFit
        image.transform = .identity
        image.image = picture
    }

    /// A symbol at 80% of the slot, as the Mac's folder and adjustment icons are drawn; Curves' turned a quarter.
    func show(symbol: String, quarterTurn: Bool) {
        image.contentMode = .center
        image.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        image.transform = quarterTurn ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
    }

    func outline(_ color: UIColor?) {
        layer.borderColor = color?.cgColor
        layer.borderWidth = color == nil ? 0 : 2
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
