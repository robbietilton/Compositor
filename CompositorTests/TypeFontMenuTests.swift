import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct TypeFontMenuTests {
    /// Where the picker's binding writes. The setter a `Binding` takes is `@Sendable`, so what it captures has to be
    /// safe to hand on; the test reads it back on the main actor, where everything here runs.
    private final class Choice: @unchecked Sendable {
        var name: String
        init(_ name: String) { self.name = name }
    }

    private struct Menu {
        let button: NSPopUpButton
        let coordinator: TypeFontPicker.Coordinator
        let choice: Choice
    }

    /// A face whose name on screen is not the name the project stores — the whole reason the menu reads the system's
    /// name. PingFang is what a Chinese Mac sets most text in, so it is the one to look for first.
    private func namedFace() throws -> FontCatalog.Face {
        try #require(FontCatalog.faces.first { $0.postScriptName == "PingFangSC-Regular" }
                     ?? FontCatalog.faces.first { $0.title != $0.postScriptName })
    }

    /// The control a person opens, populated the way opening it populates it.
    private func fontMenu(showing fontName: String) throws -> Menu {
        let choice = Choice(fontName)
        let picker = TypeFontPicker(fontName: Binding(get: { choice.name }, set: { choice.name = $0 }))
        let coordinator = picker.makeCoordinator()
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        coordinator.button = button
        coordinator.menuNeedsUpdate(try #require(button.menu))
        return Menu(button: button, coordinator: coordinator, choice: choice)
    }

    @Test func theMenuNamesAFaceTheWayTheSystemDoes() throws {
        let face = try namedFace()
        #expect(face.title == NSFont(name: face.postScriptName, size: 13)?.displayName)
        #expect(face.title != face.postScriptName)
        #expect(FontCatalog.title(for: face.postScriptName) == face.title)
    }

    @Test func theCatalogHoldsEveryInstalledFaceOnce() {
        let faces = FontCatalog.faces
        #expect(faces.count > 20)
        #expect(Set(faces.map(\.postScriptName)).count == faces.count)
        #expect(faces.allSatisfy { NSFont(name: $0.postScriptName, size: 13) != nil })
    }

    @Test func theCatalogIsInTheOrderTheMenuReadsIt() {
        let titles = FontCatalog.faces.map(\.title)
        #expect(titles == titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func aFaceThisMacDoesNotHaveKeepsItsOwnName() {
        #expect(FontCatalog.title(for: "CompositorMissing-Face") == "CompositorMissing-Face")
    }

    @Test func theMenuShowsTheReadableNameAndHandsBackTheStoredOne() throws {
        let menu = try fontMenu(showing: "Helvetica")
        #expect(menu.button.numberOfItems == FontCatalog.faces.count)
        let helvetica = try #require(menu.button.itemArray.firstIndex { $0.representedObject as? String == "Helvetica" })
        #expect(menu.button.indexOfSelectedItem == helvetica)

        let face = try namedFace()
        let index = try #require(menu.button.itemArray.firstIndex { $0.representedObject as? String == face.postScriptName })
        #expect(menu.button.item(at: index)?.title == face.title)

        menu.button.selectItem(at: index)
        menu.coordinator.choose(menu.button)
        #expect(menu.choice.name == face.postScriptName)
    }

    @Test func aFaceThisMacDoesNotHaveStillHasARow() throws {
        let menu = try fontMenu(showing: "SomeFace-Regular")
        let index = try #require(menu.button.itemArray.firstIndex { $0.representedObject as? String == "SomeFace-Regular" })
        #expect(menu.button.indexOfSelectedItem == index)
        #expect(menu.button.item(at: index)?.title == "SomeFace-Regular")
    }

    @Test func aSelectionInSeveralFacesSaysSoInARowOfItsOwn() throws {
        let menu = try fontMenu(showing: "")
        // The row stands for no face, so choosing it can't set the text in a single one.
        #expect(menu.button.item(at: 0)?.title == "(Multiple)".localizedName)
        #expect(menu.button.indexOfSelectedItem == 0)
        #expect(TypeFontPicker.postScriptName(of: menu.button.item(at: 0)) == nil)
        menu.coordinator.choose(menu.button)
        #expect(menu.choice.name == "")
    }
}
