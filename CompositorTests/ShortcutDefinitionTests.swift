import AppKit
import Testing
@testable import Compositor

@MainActor
struct ShortcutDefinitionTests {
    private func seedEvent() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "x", charactersIgnoringModifiers: "x",
                                      isARepeat: false, keyCode: 7))
    }

    @Test func defaultShortcutTableIsValidAndUnique() {
        let definitions = ShortcutDefinition.all
        let ids = Set(definitions.map(\.id))

        #expect(ids.count == definitions.count)
        #expect(ShortcutSettings.problem(in: [:]) == nil)
        #expect(definitions.allSatisfy { $0.original.key.count == 1 })
    }

    @Test func everyMenuShortcutResolvesToItsRegisteredCommand() throws {
        let seed = try seedEvent()
        let menuDefinitions = ShortcutDefinition.all.filter(\.isMenu)

        for definition in menuDefinitions {
            let event = try #require(definition.original.event(like: seed))
            #expect(ShortcutSettings.shared.menuTitle(for: event) == definition.title,
                    "Shortcut did not resolve: \(definition.title) (\(definition.original.label))")
        }
    }

    @Test func expectedPhotoshopStyleMenuCommandsRemainRegistered() {
        let titles = Set(ShortcutDefinition.all.filter(\.isMenu).map(\.title))
        for title in ["Undo", "Redo", "Copy", "Copy Merged", "Paste", "Select All", "Deselect",
                      "Inverse Selection", "Transform Layer / Selection", "Duplicate / Layer via Copy"] {
            #expect(titles.contains(title))
        }
    }

    @Test func conflictingShortcutOverridesAreRejected() {
        let undo = ShortcutDefinition.all.first { $0.title == "Undo" && $0.isMenu }!
        let copy = ShortcutDefinition.all.first { $0.title == "Copy" && $0.isMenu }!
        let conflict = [undo.id: ShortcutChord("c", 1), copy.id: ShortcutChord("c", 1)]

        #expect(ShortcutSettings.problem(in: conflict) != nil)
    }
}
