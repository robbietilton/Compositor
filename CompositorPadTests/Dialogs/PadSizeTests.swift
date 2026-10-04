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

    private let effects = LayerEffects(stroke: StrokeEffect(size: 4), shadow: ShadowEffect(distance: 20, blur: 10),
                                       outerGlow: OuterGlowEffect(size: 8))

    /// A gray layer and a text layer on the project, each carrying `effects`.
    private func layersWithEffects(in session: EditorSession) throws -> (pixels: UUID, text: UUID) {
        let context = try BrushRaster.context(width: 40, height: 40, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        let pixels = try #require(session.activeLayerID)
        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 20, y: 60), newLayer: true)
        session.textDraft?.style.content = "Hello"
        #expect(session.finishText())
        let text = try #require(session.activeLayer?.liveText != nil ? session.activeLayerID : nil)
        for id in [pixels, text] {
            let index = try #require(session.document?.layers.firstIndex { $0.id == id })
            session.document?.layers[index].effects = effects
        }
        return (pixels, text)
    }

    /// Canvas Size keeps every layer's effects, and a text layer's live text, as on the Mac.
    @Test func canvasSizeKeepsEffectsAndText() async throws {
        let (window, session) = try window()
        let (pixels, text) = try layersWithEffects(in: session)
        let style = try #require(session.document?.layers.first { $0.id == text }?.liveText?.style)
        let dialog = try #require(window.canvasSizeDialog())
        dialog.loadViewIfNeeded()
        dialog.setDimension(150, widthAxis: true)
        dialog.confirm()
        await window.resizing?.value

        #expect(session.document?.width == 150)
        for id in [pixels, text] { #expect(session.document?.layers.first { $0.id == id }?.effects == effects) }
        #expect(session.document?.layers.first { $0.id == text }?.liveText?.style == style)
    }

    /// Without resampling, Image Size keeps every layer's effects, and a text layer's live text, as on the Mac.
    @Test func imageSizeWithoutResamplingKeepsEffectsAndText() async throws {
        let (window, session) = try window()
        let (pixels, text) = try layersWithEffects(in: session)
        let style = try #require(session.document?.layers.first { $0.id == text }?.liveText?.style)
        let dialog = try #require(window.imageSizeDialog())
        dialog.loadViewIfNeeded()
        dialog.setResample(false)
        dialog.setDimension(0.5, widthAxis: true)
        dialog.confirm()
        await window.resizing?.value

        #expect(session.document?.resolution == 200)
        for id in [pixels, text] { #expect(session.document?.layers.first { $0.id == id }?.effects == effects) }
        #expect(session.document?.layers.first { $0.id == text }?.liveText?.style == style)
    }

    /// Image Size resamples the layers, so it scales their effects' sizes, distances and blurs with them, as the Mac's
    /// does.
    @Test func imageSizeScalesEffectsWithTheImage() async throws {
        let (window, session) = try window()
        let (pixels, _) = try layersWithEffects(in: session)
        let dialog = try #require(window.imageSizeDialog())
        dialog.loadViewIfNeeded()
        dialog.chooseUnit(.percent)
        dialog.setDimension(50, widthAxis: true)
        dialog.confirm()
        await window.resizing?.value

        #expect(session.document?.width == 50)
        let kept = try #require(session.document?.layers.first { $0.id == pixels }?.effects)
        #expect(kept.stroke?.size == 2 && kept.outerGlow?.size == 4)
        #expect(kept.shadow?.distance == 10 && kept.shadow?.blur == 5 && kept.shadow?.angle == effects.shadow?.angle)
    }

    /// Sizes show as the Mac's sheets show them: up to three decimals, none on a whole number.
    @Test func sizesShowUpToThreeDecimals() {
        #expect(SizeDialogController.decimals(12.7) == "12.7")
        #expect(SizeDialogController.decimals(2) == "2")
        #expect(SizeDialogController.decimals(1000.0 / 9600) == "0.104")
        #expect(SizeDialogController.decimals(-0.0001) == "0")
    }
}
