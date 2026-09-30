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
                    .padding(6)
                }
                .onChange(of: model.selection) { _, _ in
                    if let id = model.selected?.id { scroller.scrollTo(id) }
                }
            }
            if model.results.isEmpty {
                Text("No commands match").foregroundStyle(.secondary).padding(20)
            }
        }
        .frame(width: 560, height: 380)
        // The panel's title bar is transparent and hidden; its height isn't a margin to keep.
        .ignoresSafeArea()
        .onAppear { searching = true }
    }

    private func row(_ entry: CommandPaletteEntry, chosen: Bool) -> some View {
        HStack {
            Text(entry.title).lineLimit(1)
            Spacer()
            if let shortcut = entry.shortcut { Text(shortcut).font(.callout.monospaced()).foregroundStyle(.secondary) }
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
    static let skipped: Set<String> = ["Command Palette…", "Window", "Help", "Services"]

    private(set) var panel: PalettePanel?
    private weak var window: NSWindow?
    var isOpen: Bool { panel?.isVisible == true }

    /// ⌥⌘P: opens the palette over `window`, or closes it when it's already open. `menu` is the menu bar to list,
    /// the app's own unless a test passes one.
    func toggle(session: EditorSession, over window: NSWindow?, menu: NSMenu? = nil) {
        if isOpen { close(); return }
        self.window = window
        let bar = menu ?? NSApp.mainMenu
        let entries = (bar.map { CommandPaletteMenu.entries(in: $0, skipping: Self.skipped) } ?? []) + CommandPaletteEntry.tools(for: session)
        let model = CommandPaletteModel(entries: entries)
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: CommandPaletteView(model: model, run: { [weak self] in self?.run($0) },
                                                                      close: { [weak self] in self?.close() }))
        panel.setContentSize(NSSize(width: 560, height: 380))
        if let frame = window?.frame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - 280, y: frame.maxY - 110))
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
