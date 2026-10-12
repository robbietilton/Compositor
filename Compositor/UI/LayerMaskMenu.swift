import SwiftUI

/// Adds a mask in one click, as Photoshop's button does: all white, or with a selection, revealing just the
/// selection. Option-click adds the opposite: all black, or hiding the selection.
/// Enable/Disable and Delete live in the layer's context menu.
struct LayerMaskMenu: View {
    let session: EditorSession
    var body: some View {
        Button {
            session.addMask(revealing: NSApp.currentEvent?.modifierFlags.contains(.option) != true)
        } label: { FooterIcon(systemName: "rectangle.inset.filled") }
        .help(Text(L10n.string(session.selection == nil ? "Add layer mask (Option-click for a black mask)"
                                : "Add layer mask revealing the selection (Option-click to hide it)")))
        .accessibilityLabel(Text(L10n.string("Add layer mask")))
        .disabled(!session.layersLookEditable || session.selectedLayerIDs.count != 1 || session.activeLayer == nil
                  || session.activeLayer?.mask != nil)
    }
}

/// Over the canvas while it shows a mask by itself: whose mask it is, and a way back to the composite besides
/// Option-clicking the thumbnail again. Built in AppKit, as the canvas under it is, so its button gets its clicks.
struct MaskAloneBadge: NSViewRepresentable {
    let session: EditorSession
    let layer: ImageLayer
    func makeNSView(context: Context) -> CanvasPillView {
        CanvasPillView(symbol: "rectangle.inset.filled", closeLabel: "Stop viewing the mask",
                       closeHelp: "Show the image again (or Option-click the mask thumbnail)") { [session] in session.viewsMaskAlone = false }
    }
    func updateNSView(_ view: CanvasPillView, context: Context) {
        view.title = "Layer Mask"
        view.detail = layer.name
    }
}

/// Over the canvas while it proofs CMYK (View › CMYK › Proof Colors) or shows its gamut warning: one pill each, naming
/// the profile, with a way to turn that one off.
struct ProofBadge: NSViewRepresentable {
    let session: EditorSession
    /// The gamut warning's pill rather than the proof's.
    var gamut = false
    func makeNSView(context: Context) -> CanvasPillView {
        gamut ? CanvasPillView(symbol: "exclamationmark.triangle", closeLabel: "Hide the gamut warning",
                               closeHelp: "Stop marking colors the profile can't print") { [session] in session.showsGamutWarning = false }
              : CanvasPillView(symbol: "printer", closeLabel: "Stop proofing",
                               closeHelp: "Show the document's own colors again") { [session] in session.proofsColors = false }
    }
    func updateNSView(_ view: CanvasPillView, context: Context) {
        view.title = gamut ? "CMYK Gamut Warning" : "CMYK Proof"
        view.detail = session.proofProfile?.name ?? ""
    }
}

/// A pill at the foot of the canvas naming a way it's showing the document, with a button to leave it. Built in
/// AppKit, as the canvas under it is, so its button gets its clicks.
final class CanvasPillView: NSView {
    var title = "" { didSet { heading.stringValue = L10n.string(title); invalidateIntrinsicContentSize() } }
    var detail = "" { didSet { name.stringValue = detail; invalidateIntrinsicContentSize() } }
    private let heading = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let stack: NSStackView
    private let close: () -> Void

    init(symbol: String, closeLabel: String, closeHelp: String, close: @escaping () -> Void) {
        self.close = close
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        let title = heading
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        name.font = .systemFont(ofSize: 12)
        name.textColor = NSColor.white.withAlphaComponent(0.6)
        name.lineBreakMode = .byTruncatingTail
        let button = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.string(closeLabel)) ?? NSImage(),
                              target: nil, action: nil)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        button.toolTip = L10n.string(closeHelp)
        stack = NSStackView(views: [icon, title, name, button])
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 8)
        super.init(frame: .zero)
        button.target = self
        button.action = #selector(closeClicked)
        icon.contentTintColor = .white
        button.contentTintColor = .white
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 26),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: stack.fittingSize.width, height: 26) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func closeClicked() { close() }
}
