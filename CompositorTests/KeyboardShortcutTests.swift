import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct KeyboardShortcutTests {
    /// Settings kept in a throwaway defaults suite, so a test never touches the person's real shortcuts.
    private func settings() -> ShortcutSettings {
        ShortcutSettings(defaults: UserDefaults(suiteName: "KeyboardShortcutTests-\(UUID().uuidString)")!)
    }

    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    @Test func defaultsHaveUniqueIDsAndNoConflicts() {
        let ids = ShortcutDefinition.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ShortcutSettings.problem(in: [:]) == nil)
    }

    @Test func unassignedHasNoKeyAndReadsAsNone() {
        #expect(ShortcutChord.unassigned.isNone)
        #expect(ShortcutChord.unassigned.keyboardShortcut == nil)
        #expect(ShortcutChord.unassigned.label == "None")
        #expect(ShortcutChord("z", 1).keyboardShortcut == KeyboardShortcut("z", modifiers: .command))
    }

    @Test func clearedMenuShortcutHasNoKeyRatherThanItsDefault() throws {
        let settings = settings()
        let undo = try #require(ShortcutDefinition.all.first { $0.isMenu && $0.title == "Undo" })
        settings.save([undo.id: .unassigned])
        #expect(settings.menu("z", modifiers: .command).isNone)
        #expect(ShortcutSettings.problem(in: [undo.id: .unassigned]) == nil, "several cleared shortcuts never conflict")
    }

    @Test func clearedCanvasKeyIsSwallowed() throws {
        let settings = settings()
        let brush = try #require(ShortcutDefinition.all.first { $0.title == "Brush tool" })
        settings.save([brush.id: .unassigned])
        #expect(settings.canvasEvent(key("b", code: 11)) == nil)
        #expect(settings.canvasEvent(key("v", code: 9)) != nil, "other keys still reach the canvas")
    }

    @Test func overridesForTitlesThatNoLongerExistAreIgnored() {
        let defaults = UserDefaults(suiteName: "KeyboardShortcutTests-\(UUID().uuidString)")!
        let saved = ["Menus:Gone Command": ShortcutChord("k", 1), "Menus:Undo": ShortcutChord("y", 1)]
        defaults.set(try! JSONEncoder().encode(saved), forKey: "keyboardShortcuts.v1")
        let settings = ShortcutSettings(defaults: defaults)
        #expect(settings.menu("z", modifiers: .command) == ShortcutChord("y", 1))
    }

    @Test func everyFilterAdjustmentAndLayerMenuCommandIsAssignable() {
        let titles = Set(ShortcutDefinition.all.filter { $0.group == ShortcutDefinition.moreGroup }.map(\.title))
        for kind in FilterKind.allCases where kind != .contentAwareFill && !kind.isImageAdjustment {
            #expect(titles.contains("Filter › \(kind.rawValue)…"), "\(kind.rawValue)")
        }
        for kind in [FilterKind.blackWhite, .colorBalance, .exposure, .gradientMap, .grain] {
            #expect(titles.contains("Image › \(kind.rawValue)…"), "\(kind.rawValue)")
        }
        for kind in AdjustmentKind.allCases {
            #expect(titles.contains("Layer › New Adjustment Layer › \(kind.rawValue)"), "\(kind.rawValue)")
        }
        #expect(titles.contains("Select › Color Range…"))
    }

    @Test func assignableCommandsStartEmptyAndTakeAKey() throws {
        let settings = settings()
        #expect(settings.assigned("Select › Color Range…").isNone)
        let id = "\(ShortcutDefinition.moreGroup):Select › Color Range…"
        settings.save([id: ShortcutChord("k", 5)])
        #expect(settings.assigned("Select › Color Range…") == ShortcutChord("k", 5))
        settings.save([:])
        #expect(settings.assigned("Select › Color Range…").isNone, "Restore Defaults clears it again")
    }

    @Test func menuShortcutsNeedCommandOptionOrControl() {
        let id = "\(ShortcutDefinition.moreGroup):Select › Color Range…"
        #expect(ShortcutSettings.problem(in: [id: ShortcutChord("k", 0)]) != nil, "a plain letter")
        #expect(ShortcutSettings.problem(in: [id: ShortcutChord("k", 8)]) != nil, "Shift alone")
        #expect(ShortcutSettings.problem(in: [id: ShortcutChord("k", 1)]) == nil)
        #expect(ShortcutSettings.problem(in: [id: ShortcutChord("z", 1)]) != nil, "taken by Undo")
        // Defaults keep working even where they break the rule (Content-Aware Fill is Shift-Delete).
        #expect(ShortcutSettings.problem(in: [:]) == nil)
    }

    @Test func sheetListsEveryGroup() {
        #expect(KeyboardShortcutsSheet.groups == ["Menus", ShortcutDefinition.moreGroup, "Canvas & Layers", "Text Editing"])
        let grouped = Set(KeyboardShortcutsSheet.groups)
        #expect(ShortcutDefinition.all.allSatisfy { grouped.contains($0.group) }, "no definition is left out of the sheet")
    }

    /// SwiftUI's `.delete` is U+0008; the list records the Delete key as U+007F, as NSEvent reports it. The Fill and
    /// Content-Aware Fill menu keys must still find their entries, or changing them in Keyboard Shortcuts does nothing.
    @Test func deleteKeyMenuShortcutsFindTheirEntries() throws {
        let settings = settings()
        #expect(settings.menu(.delete, modifiers: .option) == ShortcutChord("\u{7f}", 2))
        let fill = try #require(ShortcutDefinition.all.first { $0.title == "Fill with Foreground" })
        settings.save([fill.id: ShortcutChord("f", 3)])
        #expect(settings.menu(.delete, modifiers: .option) == ShortcutChord("f", 3))
        // And the Delete key still reaches the menu as the Delete key.
        #expect(ShortcutChord("\u{7f}", 2).keyboardShortcut == KeyboardShortcut(.delete, modifiers: .option))
    }

    /// An override saved by an older version that a newer rule refuses (a plain letter on a menu command, or a key a
    /// new default now takes) is dropped on its own; the person's other shortcuts survive the update.
    @Test func anOverrideTheRulesNowRefuseDropsAloneOnLoad() throws {
        let defaults = UserDefaults(suiteName: "KeyboardShortcutTests-\(UUID().uuidString)")!
        let saved = ["Menus:Curves": ShortcutChord("k", 0), "Menus:Undo": ShortcutChord("y", 1)]
        defaults.set(try JSONEncoder().encode(saved), forKey: "keyboardShortcuts.v1")
        let settings = ShortcutSettings(defaults: defaults)
        #expect(settings.menu("z", modifiers: .command) == ShortcutChord("y", 1), "the valid override survives")
        #expect(settings.menu("m", modifiers: .command) == ShortcutChord("m", 1), "the refused one falls back to its default")
    }

    /// A key that types nothing (a dead key on some layouts) reads as no key at all; it must not be taken for a
    /// command whose shortcut was cleared.
    @Test func aKeyWithNoCharactersIsNotAClearedCommand() throws {
        let settings = settings()
        let brush = try #require(ShortcutDefinition.all.first { $0.title == "Brush tool" })
        settings.save([brush.id: .unassigned])
        let dead = key("", code: 33)
        #expect(settings.canvasEvent(dead)?.charactersIgnoringModifiers == "", "passed on as it was, not turned into B")
        #expect(settings.textEvent(dead)?.charactersIgnoringModifiers == "")
    }

    /// ⊗ in the sheet must record "no key", not drop the row's entry (which would bring the default back).
    @Test func clearingInTheSheetRecordsNoKey() throws {
        let undo = try #require(ShortcutDefinition.all.first { $0.isMenu && $0.title == "Undo" })
        let draft = KeyboardShortcutsSheet.clearing(undo.id, in: [:])
        #expect(draft[undo.id]?.isNone == true)
        let settings = settings()
        settings.save(draft)
        #expect(settings.menu("z", modifiers: .command).isNone)
    }
}
