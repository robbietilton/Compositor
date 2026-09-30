import AppKit

/// One thing the command palette can run: a menu command or a tool.
struct CommandPaletteEntry: Identifiable {
    /// Unique among the entries: the title, with its position added when an earlier entry has the same title (the
    /// View menu has two items called "Snap").
    let id: String
    /// Its full path, as the palette shows it and searches it: "Filter › Gaussian Blur…".
    let title: String
    /// Its current key, "⌥⌘P", or nil.
    let shortcut: String?
    /// False when its menu item is disabled right now: listed, greyed, and never run.
    let isEnabled: Bool
    let perform: @MainActor () -> Void

    init(id: String, title: String? = nil, shortcut: String?, isEnabled: Bool, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title ?? id
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

/// Fuzzy matching as launchers do it: the query's letters must appear in order; each one scores, more at the start
/// of a word and more again right after the previous match, so "gb" finds Gaussian Blur before Debug.
enum CommandPaletteSearch {
    static func score(_ query: String, in text: String) -> Int? {
        let wanted = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !wanted.isEmpty else { return 0 }
        let letters = Array(text.lowercased())
        var total = 0, from = 0, previous = -2
        for character in wanted {
            guard let found = letters[from...].firstIndex(of: character) else { return nil }
            let wordStart = found == 0 || !(letters[found - 1].isLetter || letters[found - 1].isNumber)
            total += 1 + (wordStart ? 8 : 0) + (found == previous + 1 ? 5 : 0)
            previous = found
            from = found + 1
        }
        // Between equal matches, the shorter title is the likelier one.
        return total * 100 - letters.count
    }

    /// The entries that match, best first, with enabled ones ahead of disabled; with no query, all of them in menu
    /// order, enabled first.
    static func rank(_ entries: [CommandPaletteEntry], query: String) -> [CommandPaletteEntry] {
        let scored = entries.enumerated().compactMap { index, entry in
            score(query, in: entry.title).map { (entry, $0, index) }
        }
        return scored.sorted { a, b in
            if a.0.isEnabled != b.0.isEnabled { return a.0.isEnabled }
            if query.isEmpty || a.1 == b.1 { return a.2 < b.2 }
            return a.1 > b.1
        }.map(\.0)
    }
}

/// The menu bar as palette entries: every item that does something, with its path ("Layer › Rename Layer…"), its
/// key and whether it's enabled now. Read afresh each time the palette opens, so titles that change with state
/// ("Undo Brush Stroke") are current.
enum CommandPaletteMenu {
    /// `skipping` holds titles left out: top-level menus (Window, Help) and single items (the palette's own).
    /// The app menu, the first in the bar, is always left out.
    static func entries(in menu: NSMenu, skipping: Set<String>) -> [CommandPaletteEntry] {
        var seen: [String: Int] = [:]
        return collect(menu, root: menu, path: [], skipping: skipping, seen: &seen)
    }

    private static func collect(_ menu: NSMenu, root: NSMenu, path: [String], skipping: Set<String>,
                                seen: inout [String: Int]) -> [CommandPaletteEntry] {
        // SwiftUI brings a menu's titles, checkmarks and enabled states up to date only when it's about to open, through
        // its delegate; ask for that, then let AppKit validate, so what's read is what the menu would show now.
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        var result: [CommandPaletteEntry] = []
        var sameTitle: [String: Int] = [:]
        for (index, item) in menu.items.enumerated() {
            guard !item.isSeparatorItem, !item.isHidden, !skipping.contains(item.title), !item.title.isEmpty else { continue }
            if let submenu = item.submenu {
                if path.isEmpty, index == 0 { continue } // The app menu: About, Hide, Quit.
                result += collect(submenu, root: root, path: path + [item.title], skipping: skipping, seen: &seen)
                continue
            }
            // SwiftUI takes the action off a disabled item, so an item without one is listed greyed rather than dropped.
            let titles = path + [item.title]
            let title = titles.joined(separator: " › ")
            let occurrence = sameTitle[item.title, default: 0]
            sameTitle[item.title] = occurrence + 1
            let count = seen[title, default: 0]
            seen[title] = count + 1
            result.append(CommandPaletteEntry(
                id: count == 0 ? title : "\(title) (\(count + 1))", title: title,
                shortcut: shortcut(of: item), isEnabled: item.isEnabled,
                // Found again by its path when run, so a menu SwiftUI has rebuilt since the palette opened still works.
                perform: { [weak root] in
                    guard let root, let (menu, position) = locate(titles, occurrence: occurrence, in: root) else { NSSound.beep(); return }
                    menu.performActionForItem(at: position)
                }))
        }
        return result
    }

    /// The menu holding the item at `titles` (menu titles, then the item's), and its position there; `occurrence`
    /// picks among items with the same title.
    private static func locate(_ titles: [String], occurrence: Int, in root: NSMenu) -> (NSMenu, Int)? {
        var menu = root
        for title in titles.dropLast() {
            guard let submenu = menu.items.first(where: { $0.title == title && $0.submenu != nil })?.submenu else { return nil }
            menu = submenu
        }
        let matches = menu.items.indices.filter { menu.items[$0].title == titles.last && menu.items[$0].submenu == nil }
        return matches.indices.contains(occurrence) ? (menu, matches[occurrence]) : nil
    }

    /// The key as the menu shows it, "⌥⌘P". An uppercase key equivalent implies Shift, as it does in AppKit.
    static func shortcut(of item: NSMenuItem) -> String? {
        guard let character = item.keyEquivalent.first else { return nil }
        let flags = item.keyEquivalentModifierMask
        let shifted = flags.contains(.shift) || (character.isLetter && character.isUppercase)
        let bits = (flags.contains(.command) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.control) ? 4 : 0) | (shifted ? 8 : 0)
        // AppKit's Delete key equivalent is U+0008; Keyboard Shortcuts records and labels Delete as U+007F.
        let key = character == "\u{8}" ? "\u{7f}" : String(character).lowercased()
        return ShortcutChord(key, bits).label
    }
}

extension CommandPaletteEntry {
    /// The tools, run by choosing them. With no document open there is nothing to use them on, so they're disabled.
    static func tools(for session: EditorSession) -> [CommandPaletteEntry] {
        NavigationTool.allCases.filter { $0 != .idle }.map { tool in
            CommandPaletteEntry(id: "Tool › \(tool.label)", shortcut: nil, isEnabled: session.document != nil,
                                perform: { [weak session] in session?.selectTool(tool) })
        }
    }
}

/// What the palette shows: the query, the ranked results and which one is chosen.
@MainActor @Observable
final class CommandPaletteModel {
    let entries: [CommandPaletteEntry]
    var query = "" { didSet { selection = 0 } }
    var selection = 0

    init(entries: [CommandPaletteEntry]) { self.entries = entries }

    var results: [CommandPaletteEntry] { CommandPaletteSearch.rank(entries, query: query) }
    var selected: CommandPaletteEntry? {
        let results = results
        return results.indices.contains(selection) ? results[selection] : nil
    }

    /// ↑ and ↓, wrapping at either end.
    func move(by step: Int) {
        let count = results.count
        guard count > 0 else { selection = 0; return }
        selection = ((selection + step) % count + count) % count
    }
}
