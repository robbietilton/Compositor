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
    /// A toggle that's on now (Snap To › Layers, Show Grid), checked as its menu item is, so it's clear choosing it
    /// turns it off.
    let isOn: Bool
    let perform: @MainActor () -> Void

    init(id: String, title: String? = nil, shortcut: String?, isEnabled: Bool, isOn: Bool = false,
         perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title ?? id.components(separatedBy: " › ").map { localized($0) }.joined(separator: " › ")
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.isOn = isOn
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
        // How the typed text was found, best first: whole at the start of a word ("lasso" in Lasso); each typed word
        // starting a word, in order ("new layer" in New Blank Layer); whole inside a word; spaces aside; and last the
        // letters scattered, as an abbreviation ("gb" in Gaussian Blur). "lasso" is the Lasso, not "Layer › … Hue/
        // Saturation" with an l, a, s, s and o spread through it.
        let title = String(letters), phrase = query.lowercased().trimmingCharacters(in: .whitespaces)
        let words = phrase.split(separator: " ").map(String.init)
        let tier: Int
        if wordsStartWords([phrase], in: title) {
            tier = 5
        } else if words.count > 1, wordsStartWords(words, in: title) {
            tier = 4
        } else if title.contains(phrase) {
            tier = 3
        } else if title.replacingOccurrences(of: " ", with: "").contains(String(wanted)) {
            tier = 2
        } else {
            tier = 1
        }
        // Found the same way, a clearly shorter title is the likelier one; titles within a few letters of each other
        // keep their order, so a tool's modes (Rectangular, then Elliptical Marquee) come as its tabs show them.
        // Scattered letters are ranked by how well they fall instead.
        return tier * 1_000_000 + (tier == 1 ? total * 100 : 0) - letters.count / 4
    }

    /// Each word starts a word of `title`, in order.
    private static func wordsStartWords(_ words: [String], in title: String) -> Bool {
        var from = title.startIndex
        for word in words {
            var found: String.Index?
            var search = from
            while let range = title.range(of: word, range: search..<title.endIndex) {
                if range.lowerBound == title.startIndex || !title[title.index(before: range.lowerBound)].isLetter {
                    found = range.upperBound; break
                }
                search = title.index(after: range.lowerBound)
            }
            guard let next = found else { return false }
            from = next
        }
        return true
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
                shortcut: shortcut(of: item), isEnabled: item.isEnabled, isOn: item.state == .on,
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
    /// Commands that live on buttons rather than in the menu bar, so the palette finds them too: adding a layer mask,
    /// as the Layers panel's mask button does (Option for the black one).
    static func layerCommands(for session: EditorSession) -> [CommandPaletteEntry] {
        let canAdd = session.canEditMask && session.activeLayer?.mask == nil
        let selected = session.selection != nil
        return [
            CommandPaletteEntry(id: selected ? "Layer › Add Layer Mask from Selection" : "Layer › Add Layer Mask",
                                shortcut: nil, isEnabled: canAdd,
                                perform: { [weak session] in session?.addMask(revealing: true) }),
            CommandPaletteEntry(id: selected ? "Layer › Add Layer Mask Hiding Selection" : "Layer › Add Layer Mask (Hide All)",
                                shortcut: nil, isEnabled: canAdd,
                                perform: { [weak session] in session?.addMask(revealing: false) }),
        ]
    }

    /// Every tool, and each of a tool's modes on its own, by the name someone would search for: Liquify is a mode of
    /// the Smear tool, Polygonal Lasso a mode of the Lasso, and neither is in a menu. The tool's key shows where a
    /// command's shortcut would.
    static func tools(for session: EditorSession) -> [CommandPaletteEntry] {
        typealias Setup = (EditorSession) -> Void
        let tools: [(String, String, NavigationTool, Setup?)] = [
            ("Move / Transform", "V", .move, nil),
            ("Rectangular Marquee", "M", .marquee, { $0.marqueeKind = .rectangle }),
            ("Elliptical Marquee", "M", .marquee, { $0.marqueeKind = .ellipse }),
            ("Lasso", "L", .lasso, { $0.lassoKind = .freehand }),
            ("Polygonal Lasso", "L", .lasso, { $0.lassoKind = .polygonal }),
            ("Magic Wand", "W", .wand, { $0.wandMode = .wand }),
            ("Object Selection", "W", .wand, { $0.wandMode = .object }),
            ("Crop", "C", .crop, nil),
            ("Brush", "B", .brush, { $0.brushMode = .paint }),
            ("Eraser", "E", .brush, { $0.brushMode = .erase }),
            ("Spot Healing Brush", "J", .spotHealing, nil),
            ("Clone Stamp", "S", .cloneStamp, nil),
            ("Liquify", "R", .blur, { $0.blurMode = .liquify }),
            ("Blur", "R", .blur, { $0.blurMode = .blur }),
            ("Smudge", "R", .blur, { $0.blurMode = .smudge }),
            ("Gradient", "G", .gradient, nil),
            ("Rectangle", "U", .shape, { $0.shapeKind = .rectangle }),
            ("Ellipse", "U", .shape, { $0.shapeKind = .ellipse }),
            ("Line", "U", .shape, { $0.shapeKind = .line }),
            ("Type", "T", .type, nil),
            ("Eyedropper", "I", .eyedropper, nil),
            ("Hand", "H", .hand, nil),
            ("Zoom", "Z", .zoom, nil),
        ]
        return tools.map { name, key, tool, setup in
            CommandPaletteEntry(id: "Tool › \(name)", shortcut: key, isEnabled: session.document != nil,
                                perform: { [weak session] in
                                    guard let session else { return }
                                    session.selectTool(tool)
                                    // Only once the tool is in hand, as its own Tab or key would switch it.
                                    if session.tool == tool { setup?(session) }
                                })
        }
    }
}

/// What the palette shows: the query, the ranked results and which one is chosen.
@MainActor @Observable
final class CommandPaletteModel {
    let entries: [CommandPaletteEntry]
    // Only a real change goes back to the top: pressing Return writes the same text back, which used to move the
    // choice to the first row just before it ran.
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
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
