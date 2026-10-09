import AppKit
import SwiftUI

/// The palette: a search field over the ranked commands. ↑/↓ choose, Return runs, Esc closes.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    let run: (CommandPaletteEntry) -> Void
    let close: () -> Void
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search commands and tools", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 17))
                .padding(.horizontal, 16).padding(.vertical, 13)
                .focused($searching)
                .onKeyPress(.upArrow) { model.move(by: -1); return .handled }
                .onKeyPress(.downArrow) { model.move(by: 1); return .handled }
                .onSubmit { if let entry = model.selected { run(entry) } }
                .onExitCommand(perform: close)
            Divider()
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                            row(entry, chosen: index == model.selection)
                                .id(entry.id)
                                .onTapGesture { run(entry) }
                        }
                    }
                    // Nothing below the last row: the list runs on under the panel's bottom edge.
                    .padding([.horizontal, .top], 6)
                }
                .frame(maxHeight: .infinity)
                .overlay {
                    if model.results.isEmpty { Text("No commands match").foregroundStyle(.secondary) }
                }
                .onChange(of: model.selection) { _, _ in
                    if let id = model.selected?.id { scroller.scrollTo(id) }
                }
            }
        }
        // The whole panel: the list fills it to the bottom edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panel's title bar is transparent and hidden; its height isn't a margin to keep.
        .ignoresSafeArea()
        // Once the panel is the key window, a moment after it appears: asked for sooner, the field didn't take it,
        // and typing beeped until it was clicked.
        .onAppear { DispatchQueue.main.async { searching = true } }
    }

    private func row(_ entry: CommandPaletteEntry, chosen: Bool) -> some View {
        HStack(spacing: 6) {
            // A checkmark where the menu shows one; other rows start at the edge rather than keeping room for it.
            if entry.isOn {
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).frame(width: 12)
            }
            Text(L10n.text(entry.title)).lineLimit(1)
            Spacer()
            if let shortcut = entry.shortcut { Text(L10n.text(shortcut)).font(.callout.monospaced()).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(chosen ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(entry.isEnabled ? .primary : .tertiary)
        .contentShape(Rectangle())
    }
}

/// Shows the palette over the editor window and runs what's chosen. It closes when it loses focus, so a click in
/// the editor puts it away.
@MainActor
final class CommandPaletteController {
    static let shared = CommandPaletteController()
    /// Left out of the palette: the palette itself and the system menus.
    static let skipped: Set<String> = ["Search Commands…", "Window", "Help", "Services"]

    private(set) var panel: PalettePanel?
    private weak var window: NSWindow?
    var isOpen: Bool { panel?.isVisible == true }

    /// F on the canvas: opens the palette over `window`, or closes it when it's already open. `menu` is the menu bar to list,
    /// the app's own unless a test passes one.
    func toggle(session: EditorSession, over window: NSWindow?, menu: NSMenu? = nil) {
        if isOpen { close(); return }
        self.window = window
        let bar = menu ?? NSApp.mainMenu
        let entries = (bar.map { CommandPaletteMenu.entries(in: $0, skipping: Set(Self.skipped.map(L10n.text))) } ?? []) + CommandPaletteEntry.layerCommands(for: session)
            + CommandPaletteEntry.tools(for: session)
        let model = CommandPaletteModel(entries: entries)
        let panel = self.panel ?? makePanel()
        let host = NSHostingView(rootView: CommandPaletteView(model: model, run: { [weak self] in self?.run($0) },
                                                             close: { [weak self] in self?.close() }))
        // The panel keeps the size given below rather than growing to what SwiftUI would like.
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 290)
        panel.contentView = host
        panel.setContentSize(NSSize(width: 460, height: 290))
        if let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 230, y: frame.midY - 145))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Closes the palette, gives the editor back its focus, then runs the entry once the main actor is next free,
    /// so a command that looks at the key window finds the editor.
    func run(_ entry: CommandPaletteEntry) {
        guard entry.isEnabled else { NSSound.beep(); return }
        close()
        window?.makeKeyAndOrderFront(nil)
        Task { @MainActor in entry.perform() }
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // A launcher, not a window: no close, minimise or zoom buttons.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.onResignKey = { [weak self] in self?.close() }
        self.panel = panel
        return panel
    }
}

/// A panel that can take the keyboard and says when it loses it.
final class PalettePanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
