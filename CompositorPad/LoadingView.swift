import UIKit

/// What a tab shows while its project opens, where an empty tab's New canvas card goes: "Loading “<name>”…", the
/// canvas's size once it's known, and a line for each step the open has reached, the one under way counting as it goes
/// and the ones done saying what they did. It goes as the project's first frame shows.
final class LoadingView: UIView {
    var progress: LoadingProgress? { didSet { if progress !== oldValue { setNeedsUpdateProperties() } } }

    private let card = NewCanvasView.card()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let lineStack = UIStackView()
    private lazy var content = UIStackView(arrangedSubviews: [titleLabel, captionLabel, lineStack])
    private var rows: [Row] = []
    /// The lines' font, read once with the caption's, so rows made later match those made first.
    private let lineFont = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
                                                            weight: .regular)
    /// The progress last shown, for saying once it's open.
    private weak var shown: LoadingProgress?

    /// A line: a spinner while its step is under way, a checkmark once it's done.
    private final class Row: UIStackView {
        let label = UILabel()
        private let spinner = UIActivityIndicatorView(style: .medium)
        private let check = UIImageView(image: UIImage(systemName: "checkmark",
                                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))

        init(font: UIFont) {
            super.init(frame: .zero)
            label.font = font
            label.numberOfLines = 0
            spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
            check.tintColor = .secondaryLabel
            check.contentMode = .center
            let glyph = UIView()
            for view in [spinner, check] as [UIView] {
                glyph.addSubview(view)
                view.translatesAutoresizingMaskIntoConstraints = false
                view.centerXAnchor.constraint(equalTo: glyph.centerXAnchor).isActive = true
                view.centerYAnchor.constraint(equalTo: glyph.centerYAnchor).isActive = true
            }
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.widthAnchor.constraint(equalToConstant: 20).isActive = true
            glyph.heightAnchor.constraint(equalToConstant: font.lineHeight).isActive = true
            addArrangedSubview(glyph)
            addArrangedSubview(label)
            spacing = 10
            alignment = .top
        }
        required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func show(_ line: LoadingProgress.Line) {
            label.text = line.text
            label.textColor = line.isDone ? .secondaryLabel : .label
            label.accessibilityTraits = line.isDone ? [] : .updatesFrequently
            check.isHidden = !line.isDone
            if line.isDone { spinner.stopAnimating() } else { spinner.startAnimating() }
            spinner.isHidden = line.isDone
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.accessibilityTraits = .header
        captionLabel.font = .preferredFont(forTextStyle: .callout)
        captionLabel.textColor = .secondaryLabel
        lineStack.axis = .vertical
        lineStack.spacing = 8
        content.axis = .vertical
        content.spacing = 18
        content.setCustomSpacing(6, after: titleLabel)
        card.addSubview(content)
        addSubview(card)
        for view in [card, content] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        // As wide as the New canvas card where there's room; the title stays put and the lines grow down, like a log.
        let width = card.widthAnchor.constraint(equalToConstant: 520)
        width.priority = .defaultHigh
        let top = card.topAnchor.constraint(equalTo: centerYAnchor, constant: -120)
        top.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor), width, top,
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            card.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Follows the progress shown: UIKit calls this again whenever anything it read from it changes.
    override func updateProperties() {
        super.updateProperties()
        guard let progress, progress.isShowing else {
            // Open: said once, in full, for VoiceOver. A failure says itself in its alert.
            if !isHidden, let shown, shown === progress, shown.ending == .shown {
                UIAccessibility.post(notification: .announcement, argument: "“\(shown.name)” is open.")
            }
            isHidden = true
            return
        }
        let appearing = isHidden
        isHidden = false
        shown = progress
        titleLabel.text = progress.title
        captionLabel.text = progress.caption
        captionLabel.isHidden = progress.caption == nil
        content.setCustomSpacing(captionLabel.isHidden ? 18 : 6, after: titleLabel)
        let lines = progress.lines
        while rows.count < lines.count {
            let row = Row(font: lineFont)
            rows.append(row)
            lineStack.addArrangedSubview(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= lines.count
            if index < lines.count { row.show(lines[index]) }
        }
        card.accessibilityElements = [titleLabel] + (captionLabel.isHidden ? [] : [captionLabel])
            + rows.prefix(lines.count).map(\.label)
        if appearing { UIAccessibility.post(notification: .layoutChanged, argument: titleLabel) }
    }
}
