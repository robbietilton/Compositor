import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// Canvas Size and Image Size on iPad: the Mac's sheets as dialogs, which resize the project as one step to undo.
@MainActor struct PadSizeTests {
    /// A window with a 100 × 80 project.
    private func window() throws -> (EditorWindowController, EditorSession) {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let session = try #require(window.activeTab?.session)
        session.createNewProject(width: 100, height: 80)
        return (window, session)
    }

    /// Canvas Size grows the canvas around the anchor chosen, with the room added in the color chosen. The project
    /// waits while the dialog is open.
    @Test func canvasSizeGrowsTheCanvas() async throws {
        let (window, session) = try window()
        let dialog = try #require(window.canvasSizeDialog())
        #expect(session.isProjectBusy)
        dialog.loadViewIfNeeded()
        dialog.setDimension(150, widthAxis: true)
        dialog.chooseAnchor(0)
        dialog.chooseExtension("White")
        #expect(dialog.fill?.red == 1 && dialog.fill?.blue == 1)
        dialog.confirm()
        await window.resizing?.value

        #expect(session.document?.width == 150 && session.document?.height == 80)
        #expect(!session.isProjectBusy)
        #expect(session.history.undoName == "Canvas Size")
    }

    /// Relative to the current size, in percent and locked, a new width takes the height with it; a size that can't be
    /// used can't be applied, and Cancel lets the project go.
    @Test func canvasSizeWorksRelativeInPercent() throws {
        let (window, session) = try window()
        let dialog = try #require(window.canvasSizeDialog())
        dialog.loadViewIfNeeded()
        dialog.setRelative(true)
        dialog.chooseUnit(.percent)
        dialog.setLocked(true)
        dialog.setDimension(50, widthAxis: true)
        #expect(dialog.draft.width == 150 && dialog.draft.height == 120)

        dialog.setDimension(-100, widthAxis: true)
        #expect(!dialog.draft.valid && !dialog.confirmButton.isEnabled)
        dialog.cancel()
        #expect(!session.isProjectBusy)
        #expect(session.document?.width == 100)
    }

    /// Image Size resamples the layers to the size chosen.
    @Test func imageSizeResamplesTheLayers() async throws {
        let (window, session) = try window()
        let dialog = try #require(window.imageSizeDialog())
        dialog.loadViewIfNeeded()
        dialog.chooseUnit(.percent)
        dialog.setDimension(50, widthAxis: true)
        #expect(dialog.draft.width == 50 && dialog.draft.height == 40)
        dialog.confirm()
        await window.resizing?.value

        #expect(session.document?.width == 50 && session.document?.height == 40)
        #expect(session.history.undoName == "Image Size")
    }

    /// Without resampling, a print size sets only the resolution.
    @Test func withoutResamplingOnlyTheResolutionChanges() async throws {
        let (window, session) = try window()
        let dialog = try #require(window.imageSizeDialog())
        dialog.loadViewIfNeeded()
        dialog.setResample(false)
        // 100 pixels across half an inch.
        dialog.setDimension(0.5, widthAxis: true)
        #expect(dialog.draft.resolution == 200)
        dialog.confirm()
        await window.resizing?.value

        #expect(session.document?.width == 100 && session.document?.resolution == 200)
    }

    /// Sizes show as the Mac's sheets show them: up to three decimals, none on a whole number.
    @Test func sizesShowUpToThreeDecimals() {
        #expect(SizeDialogController.decimals(12.7) == "12.7")
        #expect(SizeDialogController.decimals(2) == "2")
        #expect(SizeDialogController.decimals(1000.0 / 9600) == "0.104")
        #expect(SizeDialogController.decimals(-0.0001) == "0")
    }
}
