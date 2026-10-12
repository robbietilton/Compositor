import Testing
@testable import Compositor

@MainActor struct KeyboardShortcutMigrationTests {
    @Test func aNewDefaultDoesNotEraseUnrelatedCustomShortcuts() throws {
        let zoom = try #require(ShortcutDefinition.all.first { $0.title == "Zoom In" })
        let brush = try #require(ShortcutDefinition.all.first { $0.title == "Brush tool" })
        let saved = [zoom.id: ShortcutChord("2", 1), brush.id: ShortcutChord("9", 11)]

        let repaired = ShortcutSettings.sanitized(saved)

        #expect(repaired[zoom.id] == nil, "the new RGB default keeps Command-2")
        #expect(repaired[brush.id] == ShortcutChord("9", 11), "an unrelated customization is preserved")
        #expect(ShortcutSettings.problem(in: repaired) == nil)
    }

    @Test func validShortcutSwapsArePreserved() throws {
        let zoomIn = try #require(ShortcutDefinition.all.first { $0.title == "Zoom In" })
        let zoomOut = try #require(ShortcutDefinition.all.first { $0.title == "Zoom Out" })
        let saved = [zoomIn.id: zoomOut.original, zoomOut.id: zoomIn.original]

        #expect(ShortcutSettings.sanitized(saved) == saved)
    }
}
