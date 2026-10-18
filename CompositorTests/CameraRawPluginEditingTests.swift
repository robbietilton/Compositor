import AppKit
import CameraRawHostContract
import Testing
@testable import Compositor

@MainActor
struct CameraRawPluginEditingTests {
    private func session() throws -> EditorSession {
        let context = try BrushRaster.context(width: 4, height: 4, mask: false)
        context.setFillColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Source"))
        return session
    }

    private func open(_ session: EditorSession) throws -> CameraRawPluginEdit {
        let layer = try #require(session.activeLayer)
        let edit = try CameraRawPluginEdit(session: session, layer: layer,
                                          documentID: #require(session.document?.id), renderReference: { source, _ in source })
        session.cameraRawPluginEdit = edit
        return edit
    }

    @Test func cancelLeavesDocumentAndHistoryUnchangedAndUnlocks() throws {
        let session = try session()
        let document = session.document
        let count = session.history.undoCount
        let edit = try open(session)
        #expect(!session.canEditLayers && !session.canUseHistory && !session.canStartProjectOperation)
        edit.cancel()
        #expect(session.document == document)
        #expect(session.history.undoCount == count)
        #expect(session.canEditLayers && session.canUseHistory && session.canStartProjectOperation)
    }

    @Test func applyReopenAndUndoKeepSourcePixels() async throws {
        let session = try session()
        let source = try #require(session.activeLayer?.asset?.image)
        let count = session.history.undoCount
        let edit = try open(session)
        var settings = CameraRawSettings()
        settings.exposure = 1
        try await edit.apply(payload: JSONEncoder().encode(settings))
        #expect(session.activeLayer?.asset?.image === source)
        #expect(session.activeLayer?.cameraRawOperation?.settings == settings)
        #expect(session.history.undoCount == count + 1)
        #expect(session.cameraRawPluginEdit == nil)
        let operation = session.activeLayer?.cameraRawOperation
        let reopened = try open(session)
        #expect(try JSONDecoder().decode(CameraRawSettings.self, from: reopened.initialPayload) == settings)
        #expect(reopened.seed == operation?.seed)
        reopened.cancel()
        session.undo()
        #expect(session.activeLayer?.cameraRawOperation == nil)
        #expect(session.activeLayer?.asset?.image === source)
        session.redo()
        #expect(session.activeLayer?.cameraRawOperation == operation)
    }

    @Test func identityRemovesExistingOperationButNewIdentityIsNoOp() async throws {
        let session = try session()
        let identity = try JSONEncoder().encode(CameraRawSettings())
        let count = session.history.undoCount
        try await open(session).apply(payload: identity)
        #expect(session.history.undoCount == count)
        var settings = CameraRawSettings()
        settings.temperature = 30
        try await open(session).apply(payload: JSONEncoder().encode(settings))
        try await open(session).apply(payload: identity)
        #expect(session.activeLayer?.cameraRawOperation == nil)
        #expect(session.history.undoCount == count + 2)
        session.undo()
        #expect(session.activeLayer?.cameraRawOperation?.settings == settings)
    }

    @Test func unchangedReopenDoesNotCreateAnUndoOrRewritePayload() async throws {
        let session = try session()
        var settings = CameraRawSettings()
        settings.exposure = 1
        try await open(session).apply(payload: JSONEncoder().encode(settings))
        let operation = session.activeLayer?.cameraRawOperation
        let count = session.history.undoCount
        let edit = try open(session)
        let object = try JSONSerialization.jsonObject(with: edit.initialPayload)
        let reordered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try await edit.apply(payload: reordered)
        #expect(session.activeLayer?.cameraRawOperation == operation)
        #expect(session.history.undoCount == count)
    }

    @Test func staleAndCancelledCallbacksCannotCommit() async throws {
        let session = try session()
        let edit = try open(session)
        var settings = CameraRawSettings()
        settings.exposure = 1
        let payload = try JSONEncoder().encode(settings)
        session.document?.layers[0].transform.origin.x += 1
        await #expect(throws: CameraRawPluginError.self) { try await edit.apply(payload: payload) }
        edit.cancel()
        await #expect(throws: CameraRawPluginError.self) { try await edit.apply(payload: payload) }
        #expect(session.activeLayer?.cameraRawOperation == nil)
    }

    @Test func fakePanelFactoryAndMissingPluginDoNotDirtyDocument() throws {
        let session = try session()
        let original = session.document
        session.beginCameraRawPlugin { _ in NSWindowController(window: nil) }
        #expect(session.cameraRawPluginEdit != nil)
        session.cameraRawPluginEdit?.cancel()
        session.beginCameraRawPlugin { _ in throw CameraRawPluginError.missingPlugin }
        #expect(session.cameraRawPluginEdit == nil)
        #expect(session.cameraRawPluginError != nil)
        #expect(session.document == original)
    }

    @Test func embeddedPluginLoadsThroughTheRealHostAndCancelsWithoutChanges() throws {
        let session = try session()
        let original = session.document
        let count = session.history.undoCount
        defer {
            session.cameraRawPluginWindow?.close()
            session.cameraRawPluginEdit?.cancel()
        }
        session.beginCameraRawPlugin()
        #expect(session.cameraRawPluginError == nil)
        let panel = try #require(session.cameraRawPluginWindow)
        let frameworkRoot = try #require(Bundle.main.privateFrameworksURL)
        let pluginBundle = try #require(Bundle(url: frameworkRoot.appendingPathComponent("CameraRawPlugin.framework")))
        #expect(panel.window?.title == pluginBundle.localizedString(forKey: "Camera Raw", value: nil, table: nil))
        #expect(session.cameraRawPluginEdit != nil)
        panel.close()
        #expect(session.cameraRawPluginEdit == nil)
        #expect(session.document == original)
        #expect(session.history.undoCount == count)
    }

    @Test func equalityAndOpaqueLimitationAreIndependentOfPanel() throws {
        let session = try session()
        let original = try #require(session.activeLayer)
        var adjusted = original
        adjusted.cameraRawOperation = CameraRawOperation(payload: Data("future".utf8), schemaVersion: 9)
        #expect(adjusted != original)
        session.document?.layers[0] = adjusted
        #expect(session.cameraRawLimitation != nil)
        #expect(throws: CameraRawPluginError.self) { try open(session) }
        #expect(session.activeLayer?.cameraRawOperation == adjusted.cameraRawOperation)
    }
}
