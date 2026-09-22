import AppKit
import Foundation
import CoreGraphics
import Testing
@testable import Compositor

@MainActor
struct EditorAutomationTests {
    private func structured(_ result: [String: Any]) throws -> [String: Any] {
        try #require(result["structuredContent"] as? [String: Any])
    }

    private func revision(_ result: [String: Any]) throws -> Int {
        try #require(try structured(result)["revision"] as? Int)
    }

    @Test func schemasAreNamedUniqueAndStrict() throws {
        let automation = EditorAutomation(workspace: ProjectWorkspace())
        let names = try automation.tools.map { try #require($0["name"] as? String) }
        #expect(Set(names).count == names.count)
        #expect(names.contains("list_documents"))
        #expect(names.contains("describe_document"))
        #expect(names.contains("paint_stroke"))
        #expect(names.contains("render_document"))
        for tool in automation.tools {
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(properties["document_id"] != nil)
        }
    }

    @Test func nativeShapeTextSelectionAndHistoryRoundTrip() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        let created = try await automation.call("new_document", arguments: ["width": 120, "height": 90, "new_tab": false])
        let firstRevision = try revision(created)
        #expect(workspace.current.session.document?.size == CGSize(width: 120, height: 90))

        _ = try await automation.call("shape_operation", arguments: [
            "kind": "Rectangle", "x": 10, "y": 12, "width": 40, "height": 30,
            "color": ["red": 1, "green": 0, "blue": 0], "expected_revision": firstRevision
        ])
        #expect(workspace.current.session.activeLayer?.liveShape?.style.kind == .rectangle)

        let afterText = try await automation.call("text_operation", arguments: [
            "action": "create", "content": "Automation", "x": 20, "y": 50,
            "font_size": 18, "color": ["red": 0, "green": 0, "blue": 1]
        ])
        #expect(workspace.current.session.activeLayer?.liveText?.style.content == "Automation")

        _ = try await automation.call("selection_operation", arguments: [
            "action": "rectangle", "x": 0, "y": 0, "width": 60, "height": 60
        ])
        #expect(workspace.current.session.selection?.isEmpty == false)
        _ = try await automation.call("history_operation", arguments: ["action": "undo", "expected_revision": try revision(afterText) + 1])
        #expect(workspace.current.session.selection == nil)
    }

    @Test func effectOperationAppliesParametersAndRejectsInvalidValues() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 80, "height": 60, "new_tab": false])
        _ = try await automation.call("shape_operation", arguments: [
            "kind": "Rectangle", "x": 8, "y": 8, "width": 30, "height": 20,
            "color": ["red": 0.2, "green": 0.3, "blue": 0.4]
        ])
        let id = try #require(workspace.current.session.activeLayerID)
        let added = try await automation.call("effect_operation", arguments: [
            "action": "add", "kind": "stroke", "layer_id": id.uuidString,
            "size": 4, "opacity": 1, "color": ["red": 1, "green": 1, "blue": 1]
        ])
        _ = added
        let stroke = try #require(workspace.current.session.activeLayer?.effects?.stroke)
        #expect(stroke.size == 4)
        #expect(stroke.color == PaletteColor(red: 1, green: 1, blue: 1))
        let revision = try self.revision(added)
        _ = try await automation.call("history_operation", arguments: ["action": "undo", "expected_revision": revision])
        #expect(workspace.current.session.activeLayer?.effects?.stroke == nil)
        do {
            _ = try await automation.call("effect_operation", arguments: [
                "action": "add", "kind": "stroke", "layer_id": id.uuidString, "opacity": 2
            ])
            Issue.record("Expected invalid effect opacity to fail")
        } catch {
            #expect(error.localizedDescription.contains("out of range"))
        }
        #expect(workspace.current.session.activeLayer?.effects?.stroke == nil)
    }

    @Test func adjustmentOperationAppliesValuesAndRejectsInvalidAdds() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 80, "height": 60, "new_tab": false])
        let added = try await automation.call("adjustment_operation", arguments: [
            "action": "add", "kind": AdjustmentKind.hsv.rawValue, "hue": 30, "saturation": 40
        ])
        let adjustment = try #require(workspace.current.session.activeLayer?.adjustment)
        #expect(adjustment.kind == .hsv)
        #expect(adjustment.hue == 30)
        #expect(adjustment.saturation == 40)
        _ = try await automation.call("history_operation", arguments: [
            "action": "undo", "expected_revision": try revision(added)
        ])
        #expect(workspace.current.session.document?.layers.count == 1)

        do {
            _ = try await automation.call("adjustment_operation", arguments: [
                "action": "add", "kind": AdjustmentKind.hsv.rawValue, "hue": 999
            ])
            Issue.record("Expected invalid hue to fail")
        } catch {
            #expect(error.localizedDescription.contains("out of range"))
        }
        #expect(workspace.current.session.document?.layers.count == 1)

        let levelsData = try JSONEncoder().encode(LayerAdjustment(kind: .levels))
        let levelsObject = try #require(try JSONSerialization.jsonObject(with: levelsData) as? [String: Any])
        do {
            _ = try await automation.call("adjustment_operation", arguments: [
                "action": "add", "kind": AdjustmentKind.hsv.rawValue, "value": levelsObject
            ])
            Issue.record("Expected mismatched adjustment kind to fail")
        } catch {
            #expect(error.localizedDescription.contains("must match"))
        }
        #expect(workspace.current.session.document?.layers.count == 1)
    }

    @Test func selectionMaskConsumesSelectionAndCanBeDisabled() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 80, "height": 60, "new_tab": false])
        _ = try await automation.call("shape_operation", arguments: [
            "kind": "Rectangle", "x": 8, "y": 8, "width": 60, "height": 40,
            "color": ["red": 1, "green": 1, "blue": 1]
        ])
        let id = try #require(workspace.current.session.activeLayerID)
        _ = try await automation.call("selection_operation", arguments: [
            "action": "ellipse", "x": 20, "y": 15, "width": 36, "height": 26
        ])
        _ = try await automation.call("mask_operation", arguments: [
            "action": "add", "layer_id": id.uuidString, "revealing": false, "from_selection": true
        ])
        let mask = try #require(workspace.current.session.activeLayer?.mask)
        #expect(workspace.current.session.selection == nil)
        #expect(mask.isEnabled)
        #expect(mask.asset.image.width == 60 && mask.asset.image.height == 40)
        let maskedImage = try await ImageExporter.shared.render(try #require(workspace.current.session.projectSnapshot())).image
        let maskedPixels = NSBitmapImageRep(cgImage: maskedImage)
        #expect(try #require(maskedPixels.colorAt(x: 38, y: 28)).alphaComponent > 0.99)
        #expect(try #require(maskedPixels.colorAt(x: 10, y: 10)).alphaComponent == 0)
        _ = try await automation.call("mask_operation", arguments: [
            "action": "enable", "layer_id": id.uuidString, "enabled": false
        ])
        #expect(workspace.current.session.activeLayer?.mask?.isEnabled == false)
        let unmaskedImage = try await ImageExporter.shared.render(try #require(workspace.current.session.projectSnapshot())).image
        #expect(try #require(NSBitmapImageRep(cgImage: unmaskedImage).colorAt(x: 10, y: 10)).alphaComponent > 0.99)

        _ = try await automation.call("layer_operation", arguments: ["action": "add"])
        let base = try #require(workspace.current.session.activeLayerID)
        do {
            _ = try await automation.call("mask_operation", arguments: [
                "action": "select", "layer_id": base.uuidString, "target": "mask"
            ])
            Issue.record("Selecting a mask target without a mask should fail")
        } catch {
            #expect(error.localizedDescription.contains("no mask"))
        }
    }

    @Test func rejectedMaskOperationDoesNotChangeLayerSelection() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 40, "height": 30, "new_tab": false])
        let first = try #require(workspace.current.session.activeLayerID)
        _ = try await automation.call("layer_operation", arguments: ["action": "add"])
        let selected = try #require(workspace.current.session.activeLayerID)

        await #expect(throws: (any Error).self) {
            _ = try await automation.call("mask_operation", arguments: [
                "action": "enable", "layer_id": first.uuidString, "enabled": false
            ])
        }
        #expect(workspace.current.session.activeLayerID == selected)
    }

    @Test func humanOpacityGestureRejectsAgentEditsAndHTMLImport() async throws {
        let workspace = ProjectWorkspace(), router = MCPRouter(workspace: ProjectWorkspace())
        let api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 40, "height": 30, "new_tab": false])
        let session = workspace.current.session
        session.beginOpacityEdit()
        #expect(session.opacityEditLayerID != nil)
        await #expect(throws: (any Error).self) {
            _ = try await api.call("shape_operation", arguments: ["kind": "Rectangle", "x": 0, "y": 0, "width": 10, "height": 10])
        }
        await #expect(throws: (any Error).self) {
            _ = try await api.call("new_document", arguments: ["width": 20, "height": 20])
        }
        #expect(workspace.tabs.count == 1)
        #expect(session.opacityEditLayerID != nil)
        session.finishOpacityEdit()
        _ = try await api.call("shape_operation", arguments: ["kind": "Rectangle", "x": 0, "y": 0, "width": 10, "height": 10])
        #expect(session.document?.layers.count == 2)

        _ = try await router.editor.call("new_document", arguments: ["width": 40, "height": 30, "new_tab": false])
        router.workspace.current.session.beginOpacityEdit()
        let result = await router.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "import_html", "arguments": ["html": "<p>Blocked</p>", "width": 40, "height": 30]]])
        #expect((result?["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(router.workspace.tabs.count == 1)
        router.workspace.current.session.finishOpacityEdit()
    }

    @Test func staleRevisionIsRejectedBeforeMutation() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        let created = try await automation.call("new_document", arguments: ["width": 40, "height": 30, "new_tab": false])
        let old = try revision(created)
        _ = try await automation.call("layer_operation", arguments: ["action": "add", "expected_revision": old])
        let count = workspace.current.session.document?.layers.count
        do {
            _ = try await automation.call("layer_operation", arguments: ["action": "add", "expected_revision": old])
            Issue.record("Expected stale revision to fail")
        } catch {
            #expect(error.localizedDescription.contains("revision"))
        }
        #expect(workspace.current.session.document?.layers.count == count)
    }

    @Test func transportOpenedProjectCannotBeSilentlyReplaced() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 40, "height": 30, "new_tab": false])
        let saved = try await automation.call("read_project_data", arguments: [:])
        let data = try #require(try structured(saved)["data"] as? String)
        _ = try await automation.call("open_project_data", arguments: ["data": data])
        let importedID = workspace.current.id
        workspace.current.session.history.reset()

        await #expect(throws: (any Error).self) {
            _ = try await automation.call("new_document", arguments: ["width": 12, "height": 10, "new_tab": false])
        }
        #expect(workspace.current.id == importedID)
        #expect(workspace.current.session.document?.size == CGSize(width: 40, height: 30))

        _ = try await automation.call("new_document", arguments: [
            "width": 12, "height": 10, "new_tab": false, "discard_changes": true
        ])
        workspace.current.session.history.reset()
        _ = try await automation.call("close_document", arguments: [:])
        #expect(workspace.tabs.count == 1)
        #expect(workspace.current.id != importedID)
    }

    @Test func closingBackgroundDocumentRejectsItsActiveHumanEdit() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 40, "height": 30, "new_tab": false])
        let background = workspace.current
        _ = try await automation.call("new_document", arguments: ["width": 20, "height": 20, "new_tab": true])
        background.session.beginOpacityEdit()
        #expect(background.session.opacityEditLayerID != nil)

        await #expect(throws: (any Error).self) {
            _ = try await automation.call("close_document", arguments: [
                "document_id": background.id.uuidString, "discard_changes": true
            ])
        }
        #expect(workspace.tabs.contains(where: { $0.id == background.id }))
        #expect(background.session.opacityEditLayerID != nil)
        background.session.finishOpacityEdit()
    }

    @Test func projectDataAndRenderedImageAreSelfContained() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 32, "height": 24, "new_tab": false])
        _ = try await automation.call("shape_operation", arguments: [
            "kind": "Ellipse", "x": 4, "y": 3, "width": 20, "height": 16,
            "color": ["red": 0.25, "green": 0.5, "blue": 0.75]
        ])
        let saved = try await automation.call("read_project_data", arguments: [:])
        let savedBody = try structured(saved)
        let data = try #require(savedBody["data"] as? String)
        #expect(Data(base64Encoded: data) != nil)

        _ = try await automation.call("open_project_data", arguments: ["data": data])
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current.session.document?.size == CGSize(width: 32, height: 24))
        #expect(workspace.current.session.activeLayer?.liveShape?.style.kind == .ellipse)

        let rendered = try await automation.call("render_document", arguments: [:])
        let content = try #require(rendered["content"] as? [[String: Any]])
        let image = try #require(content.first(where: { $0["type"] as? String == "image" }))
        #expect(image["mimeType"] as? String == "image/png")
        #expect(Data(base64Encoded: try #require(image["data"] as? String))?.isEmpty == false)
    }

    @Test func paintUsesRequestedToolFamilyTipAndColor() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 48, "height": 32, "new_tab": false])
        let id = try #require(workspace.current.session.activeLayerID)
        _ = try await automation.call("paint_stroke", arguments: [
            "mode": "paint", "layer_id": id.uuidString,
            "points": [["x": 20, "y": 16], ["x": 22, "y": 16]],
            "diameter": 12, "hardness": 1, "opacity": 1,
            "color": ["red": 1, "green": 0, "blue": 0]
        ])
        #expect(workspace.current.session.brushSettings.diameter == 12)
        #expect(workspace.current.session.foregroundColor == PaletteColor(red: 1, green: 0, blue: 0))
        let raster = try await ImageExporter.shared.render(try #require(workspace.current.session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: raster.width, height: raster.height, bitsPerComponent: 8,
            bytesPerRow: raster.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(raster, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let center = (16 * raster.width + 21) * 4
        #expect(bytes[center] > 240 && bytes[center + 1] < 10 && bytes[center + 2] < 10 && bytes[center + 3] > 240)
        let outside = (2 * raster.width + 2) * 4
        #expect(bytes[outside + 3] == 0)
    }

    @Test func cameraRawSettingsCodableRoundTripAndCapabilitiesExposeNestedModel() async throws {
        var settings = CameraRawSettings()
        settings.exposure = 1.25
        settings.curve.shadows = -20
        settings.mixer.hue[3] = 17
        settings.grading.highlights.hue = 210
        settings.detail.sharpenAmount = 45
        settings.optics.removeChromaticAberration = true
        settings.geometry.guides = [CameraRawGeometryGuide(startX: 0.1, startY: 0.2, endX: 0.8, endY: 0.2)]
        settings.calibration.blueSaturation = 12
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(CameraRawSettings.self, from: encoded) == settings)

        let automation = EditorAutomation(workspace: ProjectWorkspace())
        let result = try await automation.call("get_capabilities", arguments: [:])
        let models = try #require(try structured(result)["filter_models"] as? [String: Any])
        let camera = try #require(models[FilterKind.cameraRaw.rawValue] as? [String: Any])
        #expect(camera["curve"] is [String: Any])
        #expect(camera["mixer"] is [String: Any])
        #expect(camera["detail"] is [String: Any])
        #expect(camera["geometry"] is [String: Any])
        #expect(camera["calibration"] is [String: Any])
    }

    @Test func cameraRawRejectsUnsafeMixerLengthsAndClosesTheEdit() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 24, "height": 24, "new_tab": false])
        _ = try await automation.call("shape_operation", arguments: [
            "kind": "Rectangle", "x": 2, "y": 2, "width": 20, "height": 20,
            "color": ["red": 0.5, "green": 0.5, "blue": 0.5]
        ])
        let id = try #require(workspace.current.session.activeLayerID)
        do {
            _ = try await automation.call("filter_operation", arguments: [
                "layer_id": id.uuidString, "kind": FilterKind.cameraRaw.rawValue,
                "parameters": ["mixer": ["hue": [1, 2]]]
            ])
            Issue.record("Expected unsafe mixer array length to fail")
        } catch {
            #expect(error.localizedDescription.contains("array lengths"))
        }
        #expect(workspace.current.session.filterEdit == nil)
        #expect(workspace.current.session.canEditLayers)
    }

    @Test func dataImportRejectsManifestFilenameTraversal() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 8, "height": 8, "new_tab": false])
        let saved = try await automation.call("read_project_data", arguments: [:])
        let encoded = try #require(try structured(saved)["data"] as? String)
        let raw = try #require(Data(base64Encoded: encoded))
        var object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        object["images"] = ["../escape.png": Data([0]).base64EncodedString()]
        let poisoned = try JSONSerialization.data(withJSONObject: object).base64EncodedString()
        do {
            _ = try await automation.call("open_project_data", arguments: ["data": poisoned])
            Issue.record("Expected invalid filenames to fail")
        } catch {
            #expect(error.localizedDescription.contains("filenames"))
        }
        #expect(workspace.tabs.count == 1)
    }
}
