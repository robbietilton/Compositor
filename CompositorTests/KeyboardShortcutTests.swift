import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct KeyboardShortcutTests {
    /// Settings kept in a throwaway defaults suite, so a test never touches the person's real shortcuts.
    private func defaults(saving saved: [String: ShortcutChord] = [:]) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "KeyboardShortcutTests-\(UUID().uuidString)"))
        if !saved.isEmpty { defaults.set(try JSONEncoder().encode(saved), forKey: "keyboardShortcuts.v1") }
        return defaults
    }

    @Test func savedShortcutsForCommandsThatNoLongerExistAreIgnored() throws {
        let saved = ["Menus:Gone Command": ShortcutChord("k", 1), "Menus:Undo": ShortcutChord("y", 1)]
        let settings = ShortcutSettings(defaults: try defaults(saving: saved))
        #expect(settings.menu("z", modifiers: .command) == ShortcutChord("y", 1))
    }

    /// A saved shortcut the rules now refuse drops on its own; the person's other shortcuts survive the update.
    @Test func aRefusedSavedShortcutDropsAlone() throws {
        let saved = ["Text Editing:Finish editing text": ShortcutChord("k", 0), "Menus:Undo": ShortcutChord("y", 1)]
        let settings = ShortcutSettings(defaults: try defaults(saving: saved))
        #expect(settings.menu("z", modifiers: .command) == ShortcutChord("y", 1), "the valid one survives")
        #expect(settings.overrides["Text Editing:Finish editing text"] == nil, "the refused one falls back to its default")
    }

    /// SwiftUI's `.delete` is U+0008; the list records the Delete key as U+007F, as NSEvent reports it. The Fill and
    /// Content-Aware Fill menu keys must still find their entries, or changing them in Keyboard Shortcuts does nothing.
    @Test func deleteKeyMenuShortcutsFindTheirEntries() throws {
        let settings = ShortcutSettings(defaults: try defaults())
        #expect(settings.menu(.delete, modifiers: .option) == ShortcutChord("\u{7f}", 2))
        let fill = try #require(ShortcutDefinition.all.first { $0.title == "Fill with Foreground" })
        settings.save([fill.id: ShortcutChord("f", 3)])
        #expect(settings.menu(.delete, modifiers: .option) == ShortcutChord("f", 3))
        // And the Delete key still reaches the menu as the Delete key.
        #expect(ShortcutChord("\u{7f}", 2).keyboardShortcut == KeyboardShortcut(.delete, modifiers: .option))
    }
}

extension KeyboardShortcutTests {
    @Test func cmykItemsStartWithoutAKeyAndTakeOne() throws {
        let settings = ShortcutSettings(defaults: try defaults())
        #expect(settings.assigned("CMYK Proof Colors") == nil)
        #expect(settings.assigned("CMYK Gamut Warning") == nil)
        #expect(ShortcutSettings.problem(in: [:]) == nil, "two commands without a key don't conflict")
        settings.save(["Menus:CMYK Proof Colors": ShortcutChord("y", 1)])
        #expect(settings.assigned("CMYK Proof Colors") == KeyboardShortcut("y", modifiers: .command))
        #expect(ShortcutChord.unassigned.label == "None")
    }

    /// A key that types nothing (a dead key on some layouts) must not be taken for an unassigned command's key.
    @Test func aKeyWithNoCharactersPassesThrough() throws {
        let settings = ShortcutSettings(defaults: try defaults())
        settings.save(["Menus:Undo": ShortcutChord("y", 1)])
        let dead = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, characters: "", charactersIgnoringModifiers: "",
                                                 isARepeat: false, keyCode: 33))
        #expect(settings.canvasEvent(dead) === dead)
        #expect(settings.textEvent(dead) === dead)
    }
}

extension KeyboardShortcutTests {
    /// A cleared default has no key at all, rather than falling back to its default, and frees the key for another.
    @Test func aClearedShortcutHasNoKey() throws {
        let settings = ShortcutSettings(defaults: try defaults())
        let undo = try #require(ShortcutDefinition.all.first { $0.isMenu && $0.title == "Undo" })
        let proof = "Menus:CMYK Proof Colors"
        #expect(ShortcutSettings.problem(in: [proof: ShortcutChord("z", 1)]) != nil, "⌘Z is Undo's")
        settings.save([undo.id: .unassigned, proof: ShortcutChord("z", 1)])
        #expect(settings.menu("z", modifiers: .command).isNone)
        #expect(settings.menu("z", modifiers: .command).keyboardShortcut == nil)
        #expect(settings.assigned("CMYK Proof Colors") == KeyboardShortcut("z", modifiers: .command))
    }

    @Test func aClearedCanvasKeyDoesNothing() throws {
        let settings = ShortcutSettings(defaults: try defaults())
        let brush = try #require(ShortcutDefinition.all.first { $0.title == "Brush tool" })
        settings.save([brush.id: .unassigned])
        func key(_ characters: String, _ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: code))
        }
        #expect(settings.canvasEvent(try key("b", 11)) == nil)
        let v = try key("v", 9)
        #expect(settings.canvasEvent(v) === v, "other keys still reach the canvas")
    }

    /// A key that types a non-Latin letter (here Russian и, on the B key) reads as the Latin letter of the same key, so
    /// tool shortcuts work on any layout; a Latin key is left alone.
    @Test func nonLatinLayoutsReachTheShortcutsOnTheSameKeys() throws {
        func key(_ typed: String, code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, characters: typed, charactersIgnoringModifiers: typed,
                                          isARepeat: false, keyCode: code))
        }
        let latin = try #require(LatinKeys.character(for: 11, shift: false))
        #expect(LatinKeys.event(try key("и", code: 11)).charactersIgnoringModifiers == latin)
        #expect(LatinKeys.event(try key("b", code: 11)).charactersIgnoringModifiers == "b")
    }
}
