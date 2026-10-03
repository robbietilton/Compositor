import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// The layer effect panel floats beside the canvas, so a crop, a transform, text or a gradient can be started while it
/// is open.
@MainActor
struct EffectsPanelTests {
    /// A pixel layer given a Stroke from the Layers panel's Effects menu, its panel open.
    private func openStrokePanel() async throws -> (session: EditorSession, layerID: UUID) {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        session.addEffect(.stroke)
        try #require(session.effectsEditing == LayerEffectSelection(layerID: id, kind: .stroke))
        return (session, id)
    }

    /// The panel's Size slider, then its Cancel, which takes the Stroke that was never OK'd off again.
    private func editAndCancel(_ session: EditorSession, layerID id: UUID) {
        session.changeEffects { $0.stroke?.size = 12 }
        #expect(session.document?.layers.first { $0.id == id }?.effects?.stroke?.size == 12, "the slider sizes the stroke")
        session.finishEffectsEditing(commit: false)
        #expect(session.effectsEditing == nil)
        #expect(session.document?.layers.first { $0.id == id }?.effects == nil, "Cancel takes the new Stroke off")
    }

    @Test func panelKeepsWorkingWhileCropping() async throws {
        let (session, id) = try await openStrokePanel()
        session.selectTool(.crop)
        try #require(session.cropRect != nil)
        editAndCancel(session, layerID: id)
    }

    @Test func panelKeepsWorkingWhileTransforming() async throws {
        let (session, id) = try await openStrokePanel()
        session.transformCommand()
        try #require(session.transformEdit != nil)
        editAndCancel(session, layerID: id)
    }

    /// ⌘T with a selection holds its undo step open and puts the whole project back on Cancel, so it OKs the panel as
    /// it starts: nothing the panel shows can be folded into the transform and lost with it.
    @Test func transformingASelectionOKsThePanel() async throws {
        let (session, id) = try await openStrokePanel()
        func stroke() -> StrokeEffect? { session.document?.layers.first { $0.id == id }?.effects?.stroke }
        session.changeEffects { $0.stroke?.size = 12 }
        session.selectAll()
        session.transformCommand()
        // The pixels are lifted in a task, so the transform opens a moment later.
        for _ in 0..<200 where session.transformEdit == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(session.transformEdit?.floating != nil)
        #expect(session.effectsEditing == nil, "⌘T OKs the panel")
        // The Size slider, were the panel still open, then the transform's Cancel (Escape).
        session.changeEffects { $0.stroke?.size = 20 }
        let shown = stroke()
        session.cancelTransform()
        #expect(stroke() == shown, "the transform's Cancel leaves the stroke as it was")
        #expect(stroke()?.size == 12 && session.effectsEditing == nil, "the panel stays OK'd, its stroke kept")
    }

    /// A gradient waiting for Apply doesn't stop the panel either, and applying it keeps what the panel set, as it's
    /// drawn into the layer as it is then.
    @Test func panelKeepsWorkingBesideAPendingGradient() async throws {
        let (session, id) = try await openStrokePanel()
        session.selectTool(.gradient)
        session.beginGradient(at: CGPoint(x: 2, y: 2))
        session.moveGradient(end: CGPoint(x: 30, y: 30))
        try #require(session.gradientEdit != nil)
        session.changeEffects { $0.stroke?.size = 12 }
        await session.commitGradient()
        try #require(session.gradientEdit == nil)
        #expect(session.document?.layers.first { $0.id == id }?.effects?.stroke?.size == 12, "applying keeps the stroke")
        session.beginGradient(at: CGPoint(x: 2, y: 2))
        session.moveGradient(end: CGPoint(x: 30, y: 30))
        try #require(session.gradientEdit != nil)
        session.finishEffectsEditing(commit: false)
        #expect(session.document?.layers.first { $0.id == id }?.effects == nil, "Cancel takes the new Stroke off")
    }

    @Test func panelKeepsWorkingWhileTyping() async throws {
        let (session, id) = try await openStrokePanel()
        session.selectTool(.type)
        // What a click on the canvas with the Type tool calls.
        session.beginText(at: CGPoint(x: 10, y: 10), newLayer: true)
        try #require(session.textDraft != nil)
        editAndCancel(session, layerID: id)
    }
}
