import UIKit

/// The window's projects as tabs, as the Mac's toolbar shows them: one capsule per project with a dot while it has
/// changes not yet saved, and a close button. It takes the room the bar has between New Canvas and the zoom controls,
/// and scrolls when the tabs outgrow it. While the window is held on the tab in front, the other tabs and every close
/// button are dimmed, as on the Mac.
final class TabStripView: UIView {
    struct Tab: Equatable {
        let id: UUID
        let title: String
        let modified: Bool
    }

    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    /// Rename, Duplicate and the rest for a tab, from its context menu.
    var menu: (UUID) -> UIMenu? = { _ in nil }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var shown: (tabs: [Tab], active: UUID?, held: Bool) = ([], nil, false)

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        scroll.addSubview(stack)
        addSubview(scroll)
        for view in [scroll, stack] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        accessibilityLabel = "Project tabs"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// As wide as the bar allows, as the Mac's strip is: the bar gives a title view that asks for all the width the
    /// room between its leading and trailing items.
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.layoutFittingExpandedSize.width, height: 36) }

    /// Shows `tabs`, `active` in front. `held` on the tab in front, as while a dialog or an adjustment's editor holds
    /// the window on it, the other tabs and the close buttons take no touch.
    func show(_ tabs: [Tab], active: UUID?, held: Bool = false) {
        guard shown != (tabs, active, held) else { return }
        // Only whether the window is held changed, as when a tab's own menu comes up and holds it: the tabs are dimmed
        // or brought back where they are, since a menu goes with the tab it came from.
        let onlyHeld = shown.tabs == tabs && shown.active == active
        shown = (tabs, active, held)
        if onlyHeld {
            for pill in stack.arrangedSubviews.compactMap({ $0 as? TabPill }) { pill.show(active: pill.id == active, held: held) }
            return
        }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tab in tabs {
            let pill = TabPill(tab: tab, active: tab.id == active, held: held)
            pill.addAction(UIAction { [weak self] _ in self?.onSelect(tab.id) }, for: .touchUpInside)
            pill.onClose = { [weak self] in self?.onClose(tab.id) }
            pill.menu = { [weak self] in self?.menu(tab.id) }
            stack.addArrangedSubview(pill)
        }
        layoutIfNeeded()
        if let active, let pill = stack.arrangedSubviews.compactMap({ $0 as? TabPill }).first(where: { $0.id == active }) {
            scroll.scrollRectToVisible(pill.frame.insetBy(dx: -12, dy: 0), animated: false)
        }
    }
}

/// One project's tab: its name, a dot while it has changes not yet saved, and a close button; dimmed, the tab in front
/// apart from its close button, while the window is held on the tab in front.
private final class TabPill: UIControl {
    let id: UUID
    var onClose: () -> Void = {}
    var menu: () -> UIMenu? = { nil }
    private let title = UILabel()
    private let dot = UILabel()
    private let close: UIButton

    init(tab: TabStripView.Tab, active: Bool, held: Bool) {
        id = tab.id
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        close = UIButton(configuration: configuration)
        super.init(frame: .zero)
        title.text = tab.title
        title.lineBreakMode = .byTruncatingMiddle
        dot.text = "•"
        dot.font = .systemFont(ofSize: 14, weight: .bold)
        dot.isHidden = !tab.modified
        close.accessibilityLabel = "Close \(tab.title)"
        close.addAction(UIAction { [weak self] _ in self?.onClose() }, for: .primaryActionTriggered)
        let row = UIStackView(arrangedSubviews: [dot, title, close])
        row.spacing = 4
        row.alignment = .center
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 34),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        layer.cornerRadius = 17
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        isContextMenuInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = tab.title + (tab.modified ? ", edited" : "")
        show(active: active, held: held)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the tab in front or behind it, dimmed while the window is held on another.
    func show(active: Bool, held: Bool) {
        let dimmed = !active && held
        title.font = .systemFont(ofSize: 14, weight: active ? .semibold : .regular)
        title.textColor = active ? .label : dimmed ? .tertiaryLabel : .secondaryLabel
        dot.textColor = dimmed ? .tertiaryLabel : .secondaryLabel
        close.configuration?.baseForegroundColor = held ? .tertiaryLabel : .secondaryLabel
        close.isEnabled = !held
        isEnabled = !dimmed
        backgroundColor = active ? UIColor(white: 1, alpha: 0.14) : .clear
        layer.borderWidth = active ? 1 : 0
        accessibilityTraits = active ? [.button, .selected] : dimmed ? [.button, .notEnabled] : .button
    }

    /// The close button takes its own taps; anywhere else, the tab takes them, not the labels and stack it's made of.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit.isDescendant(of: close) ? hit : self
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = menu() else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menu })
    }
}
