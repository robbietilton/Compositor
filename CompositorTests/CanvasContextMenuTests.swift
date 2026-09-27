import AppKit
import Testing
@testable import Compositor

/// The canvas right-click menu: what it offers depends on the tool in hand, and every item has to run
/// the command it names.
@MainActor
struct CanvasContextMenuTests {
    private func session(tool: NavigationTool) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300, emptyLayer: true)
        session.selectTool(tool)
        return session
    }

    private func item(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title.localizedName }
    }

    @Test func selectionToolsOfferTheSelectionCommands() {
        for tool in [NavigationTool.marquee, .lasso, .wand] {
            let menu = CanvasContextMenu.menu(for: session(tool: tool))
            let titles = menu.items.map(\.title)
            #expect(titles.contains("All".localizedName))
            #expect(titles.contains("Deselect".localizedName))
            #expect(titles.contains("Feather…".localizedName))
            #expect(titles.contains("Fill with Foreground Color".localizedName))
            #expect(titles.contains("Fit Canvas".localizedName))
        }
    }

    @Test func itemsRunTheCommandTheyName() {
        let session = session(tool: .marquee)
        let menu = CanvasContextMenu.menu(for: session)
        // Every item has to be wired to something, or clicking it would do nothing.
        for entry in menu.items where !entry.isSeparatorItem {
            #expect(entry.action != nil, "\(entry.title) has no action")
            #expect(entry.target != nil, "\(entry.title) has no target")
        }
        #expect(item("Deselect", in: menu)?.isEnabled == false)
    }

    @Test func theCropMenuFollowsWhetherACropIsShowing() {
        let session = session(tool: .crop)
        // Picking the crop tool puts a crop over the whole canvas, so both commands are live.
        let cropping = CanvasContextMenu.menu(for: session)
        #expect(session.cropRect != nil)
        #expect(item("Apply Crop", in: cropping)?.isEnabled == true)
        #expect(item("Cancel", in: cropping)?.isEnabled == true)

        session.cancelCrop()
        let cancelled = CanvasContextMenu.menu(for: session)
        #expect(session.cropRect == nil)
        #expect(item("Apply Crop", in: cancelled)?.isEnabled == false)
        #expect(item("Cancel", in: cancelled)?.isEnabled == false)
    }

    @Test func paintingToolsSkipTheSelectionCommands() {
        for tool in [NavigationTool.brush, .cloneStamp, .gradient] {
            let titles = CanvasContextMenu.menu(for: session(tool: tool)).items.map(\.title)
            #expect(!titles.contains("Feather…".localizedName), "\(tool) showed selection commands")
            #expect(!titles.contains("Apply Crop".localizedName), "\(tool) showed crop commands")
            #expect(titles.contains("Copy".localizedName))
        }
    }

    @Test func theTypeMenuOffersEditingWhileADraftIsOpen() {
        let session = session(tool: .type)
        let idle = CanvasContextMenu.menu(for: session)
        #expect(item("Done", in: idle)?.isEnabled == false)

        session.beginText(at: CGPoint(x: 20, y: 20))
        let editing = CanvasContextMenu.menu(for: session)
        #expect(item("Done", in: editing)?.isEnabled == true)
        #expect(item("Cancel", in: editing)?.isEnabled == true)
    }
}
