import AppKit
import Testing
@testable import Compositor

@MainActor
struct PhotoshopAutomationTests {
    @Test func layeredPhotoshopImportPreservesNamesVisibilityAndSingleUndo() async throws {
        let workspace = ProjectWorkspace(), api = EditorAutomation(workspace: ProjectWorkspace())
        let editor = EditorAutomation(workspace: workspace)
        _ = try await editor.call("new_document", arguments: ["width": 16, "height": 12, "new_tab": false])
        let context = try BrushRaster.context(width: 4, height: 4, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        var bottom = PSDRecord(id: UUID(), name: "Base photograph")
        bottom.bounds = CGRect(x: 0, y: 0, width: 4, height: 4); bottom.image = image
        var top = PSDRecord(id: UUID(), name: "Retouch")
        top.bounds = CGRect(x: 2, y: 2, width: 4, height: 4); top.image = image; top.isVisible = false
        let bytes = try PSDFixture.data(PSDDocument(width: 16, height: 12, resolution: 144, layers: [bottom, top]), composite: image)
        _ = try await editor.call("import_image", arguments: ["filename": "Layered.psd", "data": bytes.base64EncodedString()])
        let layers = try #require(workspace.current.session.document?.layers)
        #expect(layers.count == 4)
        #expect(layers[1].isGroup && layers[1].name == "Layered")
        #expect(layers[2].name == "Base photograph" && layers[2].isVisible)
        #expect(layers[3].name == "Retouch" && !layers[3].isVisible)
        #expect(layers[2].parentID == layers[1].id && layers[3].parentID == layers[1].id)
        _ = try await editor.call("history_operation", arguments: ["action": "undo"])
        #expect(workspace.current.session.document?.layers.count == 1)
        #expect(!workspace.isManaging && !workspace.current.session.isProjectBusy)

        // Import into an empty tab also creates the Photoshop canvas at its native dimensions.
        _ = try await api.call("import_image", arguments: ["filename": "Layered.psd", "data": bytes.base64EncodedString()])
        #expect(api.workspace.current.session.document?.width == 16)
        #expect(api.workspace.current.session.document?.layers.count == 2)
    }

    @Test func malformedPhotoshopDataDoesNotMutateOrLeaveEditorBusy() async throws {
        let workspace = ProjectWorkspace()
        let editor = EditorAutomation(workspace: workspace)
        _ = try await editor.call("new_document", arguments: ["width": 16, "height": 12, "new_tab": false])
        let before = workspace.current.session.document
        await #expect(throws: (any Error).self) {
            _ = try await editor.call("import_image", arguments: ["filename": "Broken.psd", "data": Data("broken".utf8).base64EncodedString()])
        }
        #expect(workspace.current.session.document == before)
        #expect(!workspace.isManaging && !workspace.current.session.isProjectBusy)
    }
}
