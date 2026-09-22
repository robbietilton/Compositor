import AppKit
import Testing
@testable import Compositor

@MainActor
struct AdvancedAutomationTests {
    @Test func cropAndCanvasResizePreserveEditableTypesAndEffects() async throws {
        let workspace = ProjectWorkspace()
        let api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 200, "height": 140])
        _ = try await api.call("text_operation", arguments: ["action": "create", "content": "Editable", "font_size": 20, "x": 30, "y": 20])
        let session = workspace.current.session
        let textID = try #require(session.activeLayerID)
        _ = try await api.call("effect_operation", arguments: ["action": "add", "kind": LayerEffectKind.stroke.rawValue, "layer_id": textID.uuidString])
        let original = try #require(session.document?.layers.first(where: { $0.id == textID }))
        _ = try await api.call("canvas_operation", arguments: ["action": "crop", "x": 10, "y": 10, "width": 160, "height": 110])
        let cropped = try #require(session.document?.layers.first(where: { $0.id == textID }))
        #expect(cropped.liveText?.style.content == "Editable")
        #expect(cropped.effects == original.effects)
        #expect(cropped.transform.origin.x == original.transform.origin.x - 10)
        session.undo()
        #expect(session.document?.width == 200)
        #expect(session.document?.layers.first(where: { $0.id == textID })?.liveText?.style.content == "Editable")
    }

    @Test func gradientPixelsAndGuideLockAreRealOperations() async throws {
        let workspace = ProjectWorkspace(), api: EditorAutomation
        api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 64, "height": 32])
        let session = workspace.current.session
        let id = try #require(session.activeLayerID)
        _ = try await api.call("gradient_operation", arguments: ["layer_id": id.uuidString, "start_x": 0, "start_y": 0, "end_x": 64, "end_y": 0, "foreground": ["red": 1, "green": 0, "blue": 0], "background": ["red": 0, "green": 0, "blue": 1]])
        let image = try #require(session.activeLayer?.asset?.image)
        let bitmap = NSBitmapImageRep(cgImage: image)
        #expect(try #require(bitmap.colorAt(x: 2, y: 10)).redComponent > 0.8)
        #expect(try #require(bitmap.colorAt(x: 60, y: 10)).blueComponent > 0.8)
        _ = try await api.call("guide_operation", arguments: ["action": "add", "axis": "vertical", "position": 21])
        #expect(session.document?.guides.first?.position == 21)
        _ = try await api.call("guide_operation", arguments: ["action": "lock", "locked": true])
        await #expect(throws: (any Error).self) { _ = try await api.call("guide_operation", arguments: ["action": "clear"]) }
        #expect(session.document?.guides.count == 1)
    }

    @Test func scalingKeepsSourcePixelsAndEditableLayers() async throws {
        let workspace = ProjectWorkspace(), api: EditorAutomation
        api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 200, "height": 100])
        _ = try await api.call("shape_operation", arguments: ["kind": ShapeKind.rectangle.rawValue, "x": 10, "y": 20, "width": 30, "height": 20])
        let layer = try #require(workspace.current.session.activeLayer)
        _ = try await api.call("canvas_operation", arguments: ["action": "scale_image", "width": 400, "height": 200])
        let scaled = try #require(workspace.current.session.activeLayer)
        #expect(scaled.liveShape != nil)
        #expect(scaled.asset?.image === layer.asset?.image)
        #expect(scaled.transform.origin.x == layer.transform.origin.x * 2)
        #expect(scaled.transform.size.width == layer.transform.size.width * 2)
    }

    @Test func sampleSelectionRejectsPointsOutsideCanvas() async throws {
        let workspace = ProjectWorkspace()
        let api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 40, "height": 20])
        for point in [CGPoint(x: -1, y: 0), CGPoint(x: 40, y: 10), CGPoint(x: 10, y: 20)] {
            await #expect(throws: (any Error).self) {
                _ = try await api.call("sample_selection", arguments: [
                    "kind": "wand", "x": point.x, "y": point.y
                ])
            }
        }
        #expect(workspace.current.session.selection == nil)
    }

    @Test func rejectedSampleDoesNotChangeTheActiveLayer() async throws {
        let workspace = ProjectWorkspace(), api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 40, "height": 20])
        let first = try #require(workspace.current.session.activeLayerID)
        _ = try await api.call("layer_operation", arguments: ["action": "add"])
        let selected = try #require(workspace.current.session.activeLayerID)

        await #expect(throws: (any Error).self) {
            _ = try await api.call("sample_selection", arguments: [
                "kind": "wand", "layer_id": first.uuidString, "x": 40, "y": 10
            ])
        }
        #expect(workspace.current.session.activeLayerID == selected)
    }

    @Test func cancelledMagicWandDoesNotCommitOrLeaveTheEditorBusy() async throws {
        let workspace = ProjectWorkspace(), api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 40, "height": 20])
        let session = workspace.current.session
        let history = session.history.undoCount

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await session.magicWand(at: CGPoint(x: 1, y: 1), mode: .replace)
        }
        await task.value

        #expect(session.selection == nil)
        #expect(session.history.undoCount == history)
        #expect(!session.isProjectBusy)
    }

    @Test func objectSelectionHonorsLayerSamplingAndWorkspaceBusyGuard() async throws {
        let workspace = ProjectWorkspace()
        let api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 40, "height": 20])
        _ = try await api.call("layer_operation", arguments: ["action": "add_group"])
        let groupID = try #require(workspace.current.session.activeLayerID)
        await #expect(throws: (any Error).self) {
            _ = try await api.call("sample_selection", arguments: [
                "kind": "object", "layer_id": groupID.uuidString, "x": 1, "y": 1,
                "sample_all_layers": false
            ])
        }
        #expect(workspace.current.session.objectSelectionSettings.sampleAllLayers == true)

        workspace.isManaging = true
        defer { workspace.isManaging = false }
        let before = workspace.current.session.locksGuides
        await #expect(throws: (any Error).self) {
            _ = try await api.call("guide_operation", arguments: ["action": "lock", "locked": !before])
        }
        #expect(workspace.current.session.locksGuides == before)
    }

    @Test func trimAndClearGuidesRejectIneffectiveRequests() async throws {
        let workspace = ProjectWorkspace()
        let api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 40, "height": 20])
        await #expect(throws: (any Error).self) {
            _ = try await api.call("guide_operation", arguments: ["action": "clear"])
        }
        await #expect(throws: (any Error).self) {
            _ = try await api.call("canvas_operation", arguments: ["action": "trim"])
        }
        #expect(workspace.current.session.document?.size == CGSize(width: 40, height: 20))
    }

    @Test func scaleImageRejectsGuidesThatWouldExceedProjectBounds() async throws {
        let workspace = ProjectWorkspace()
        let api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 200, "height": 100])
        _ = try await api.call("guide_operation", arguments: [
            "action": "add", "axis": "vertical", "position": 1_000_000
        ])
        await #expect(throws: (any Error).self) {
            _ = try await api.call("canvas_operation", arguments: [
                "action": "scale_image", "width": 400, "height": 200
            ])
        }
        #expect(workspace.current.session.document?.width == 200)
        #expect(workspace.current.session.document?.guides.first?.position == 1_000_000)
    }

    @Test func directGuideAndMaskChangesInvalidateExpectedRevision() async throws {
        let workspace = ProjectWorkspace()
        let api = EditorAutomation(workspace: workspace)
        let created = try await api.call("new_document", arguments: ["width": 40, "height": 20])
        let originalRevision = try revision(created)
        let session = workspace.current.session
        session.document?.guides.append(CanvasGuide(id: UUID(), axis: .vertical, position: 8))
        await #expect(throws: (any Error).self) {
            _ = try await api.call("guide_operation", arguments: [
                "action": "lock", "locked": true, "expected_revision": originalRevision
            ])
        }

        let described = try await api.call("describe_document", arguments: [:])
        let layerID = try #require(session.activeLayerID)
        let added = try await api.call("mask_operation", arguments: [
            "action": "add", "layer_id": layerID.uuidString, "expected_revision": try revision(described)
        ])
        let maskRevision = try revision(added)
        let index = try #require(session.document?.layers.firstIndex(where: { $0.id == layerID }))
        session.document?.layers[index].mask?.isEnabled.toggle()
        await #expect(throws: (any Error).self) {
            _ = try await api.call("guide_operation", arguments: [
                "action": "lock", "locked": true, "expected_revision": maskRevision
            ])
        }
    }

    @Test func maskTransformsRequireAnUnlinkedMaskAndUndoAsOneStep() async throws {
        let workspace = ProjectWorkspace()
        let api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 80, "height": 60])
        _ = try await api.call("shape_operation", arguments: [
            "kind": ShapeKind.rectangle.rawValue, "x": 10, "y": 10, "width": 30, "height": 20
        ])
        let session = workspace.current.session
        let layerID = try #require(session.activeLayerID)
        let originalLayer = try #require(session.activeLayer?.transform)
        let beforeMissingMask = session.history.undoCount

        await #expect(throws: (any Error).self) {
            _ = try await api.call("transform_operation", arguments: [
                "layer_id": layerID.uuidString, "target": "mask", "x": originalLayer.origin.x + 5
            ])
        }
        #expect(session.activeLayer?.transform == originalLayer)
        #expect(session.history.undoCount == beforeMissingMask)
        #expect(!session.isMaskSelected)

        _ = try await api.call("mask_operation", arguments: [
            "action": "add", "layer_id": layerID.uuidString
        ])
        #expect(session.activeLayer?.mask?.isLinked == true)
        let beforeLinkedMask = session.history.undoCount
        await #expect(throws: (any Error).self) {
            _ = try await api.call("transform_operation", arguments: [
                "layer_id": layerID.uuidString, "target": "mask", "x": originalLayer.origin.x + 5
            ])
        }
        #expect(session.activeLayer?.transform == originalLayer)
        #expect(session.activeLayer?.mask?.placement == nil)
        #expect(session.history.undoCount == beforeLinkedMask)

        _ = try await api.call("mask_operation", arguments: [
            "action": "set_linked", "layer_id": layerID.uuidString, "linked": false
        ])
        #expect(session.activeLayer?.mask?.isLinked == false)
        #expect(session.history.undoCount == beforeLinkedMask + 1)

        let beforeTransform = session.history.undoCount
        let targetX = originalLayer.origin.x + 7
        _ = try await api.call("transform_operation", arguments: [
            "layer_id": layerID.uuidString, "target": "mask", "x": targetX
        ])
        #expect(session.activeLayer?.transform == originalLayer)
        #expect(session.activeLayer?.mask?.placement?.origin.x == targetX)
        #expect(session.history.undoCount == beforeTransform + 1)
        session.undo()
        #expect(session.activeLayer?.transform == originalLayer)
        #expect(session.activeLayer?.mask?.placement == nil)
        #expect(session.activeLayer?.mask?.isLinked == false)
    }

    @Test func effectsRejectTargetsThatNativeEffectsCannotModify() async throws {
        let workspace = ProjectWorkspace()
        let api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 40, "height": 30])
        let session = workspace.current.session

        _ = try await api.call("layer_operation", arguments: ["action": "add_group"])
        let groupID = try #require(session.activeLayerID)
        let beforeGroup = session.history.undoCount
        await #expect(throws: (any Error).self) {
            _ = try await api.call("effect_operation", arguments: [
                "action": "add", "kind": LayerEffectKind.stroke.rawValue, "layer_id": groupID.uuidString
            ])
        }
        #expect(session.document?.layers.first(where: { $0.id == groupID })?.effects == nil)
        #expect(session.history.undoCount == beforeGroup)

        _ = try await api.call("adjustment_operation", arguments: [
            "action": "add", "kind": AdjustmentKind.hsv.rawValue
        ])
        let adjustmentID = try #require(session.activeLayerID)
        let beforeAdjustment = session.history.undoCount
        await #expect(throws: (any Error).self) {
            _ = try await api.call("effect_operation", arguments: [
                "action": "add", "kind": LayerEffectKind.stroke.rawValue, "layer_id": adjustmentID.uuidString
            ])
        }
        #expect(session.document?.layers.first(where: { $0.id == adjustmentID })?.effects == nil)
        #expect(session.history.undoCount == beforeAdjustment)
    }

    @Test func deletingLiveMaskSourceRejectsBeforeMutation() async throws {
        let workspace = ProjectWorkspace()
        let api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 40, "height": 30])
        let session = workspace.current.session
        let sourceID = try #require(session.activeLayerID)
        _ = try await api.call("layer_operation", arguments: ["action": "add"])
        let dependentID = try #require(session.activeLayerID)
        _ = try await api.call("mask_operation", arguments: [
            "action": "link", "layer_id": dependentID.uuidString, "source_id": sourceID.uuidString
        ])
        #expect(session.activeLayer?.maskSourceID == sourceID)

        let idsBefore = session.document?.layers.map(\.id)
        let historyBefore = session.history.undoCount
        let selectionBefore = session.activeLayerID
        await #expect(throws: (any Error).self) {
            _ = try await api.call("layer_operation", arguments: [
                "action": "delete", "layer_id": sourceID.uuidString
            ])
        }
        #expect(session.document?.layers.map(\.id) == idsBefore)
        #expect(session.history.undoCount == historyBefore)
        #expect(session.activeLayerID == selectionBefore)

        _ = try await api.call("mask_operation", arguments: [
            "action": "unlink", "layer_id": dependentID.uuidString
        ])
        _ = try await api.call("layer_operation", arguments: [
            "action": "delete", "layer_id": sourceID.uuidString
        ])
        #expect(session.document?.layers.contains(where: { $0.id == sourceID }) == false)
        #expect(session.document?.layers.first(where: { $0.id == dependentID })?.maskSourceID == nil)
    }

    @Test func textGeometryValidationDoesNotLeaveAnActiveDraft() async throws {
        let workspace = ProjectWorkspace()
        let api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 80, "height": 60])
        let session = workspace.current.session
        let initialCount = session.document?.layers.count
        let initialHistory = session.history.undoCount
        await #expect(throws: (any Error).self) {
            _ = try await api.call("text_operation", arguments: [
                "action": "create", "content": "Incomplete", "width": 30
            ])
        }
        #expect(session.textDraft == nil)
        #expect(session.document?.layers.count == initialCount)
        #expect(session.history.undoCount == initialHistory)

        _ = try await api.call("text_operation", arguments: [
            "action": "create", "content": "Text", "x": 10, "y": 10
        ])
        let textID = try #require(session.activeLayerID)
        let beforeUpdate = session.history.undoCount
        await #expect(throws: (any Error).self) {
            _ = try await api.call("text_operation", arguments: [
                "action": "update", "layer_id": textID.uuidString, "content": "Moved", "x": 20
            ])
        }
        #expect(session.textDraft == nil)
        #expect(session.activeLayer?.liveText?.style.content == "Text")
        #expect(session.history.undoCount == beforeUpdate)
    }

    @Test func filtersUseTheExplicitLayerOrMaskTarget() async throws {
        let workspace = ProjectWorkspace()
        let api = EditorAutomation(workspace: workspace)
        _ = try await api.call("new_document", arguments: ["width": 80, "height": 60])
        _ = try await api.call("shape_operation", arguments: [
            "kind": ShapeKind.rectangle.rawValue, "x": 10, "y": 10, "width": 40, "height": 30
        ])
        let session = workspace.current.session
        let maskedID = try #require(session.activeLayerID)
        _ = try await api.call("mask_operation", arguments: [
            "action": "add", "layer_id": maskedID.uuidString
        ])
        let originalMask = try #require(session.activeLayer?.mask?.asset.image)
        let originalPixels = try #require(session.activeLayer?.asset?.image)
        #expect(session.isMaskSelected)

        _ = try await api.call("filter_operation", arguments: [
            "layer_id": maskedID.uuidString, "target": "layer",
            "kind": FilterKind.gaussianBlur.rawValue, "radius": 2
        ])
        let filteredMask = try #require(session.activeLayer?.mask?.asset.image)
        let filteredPixels = try #require(session.activeLayer?.asset?.image)
        #expect(filteredMask === originalMask)
        #expect(filteredPixels !== originalPixels)
        #expect(!session.isMaskSelected)

        _ = try await api.call("layer_operation", arguments: ["action": "add"])
        let noMaskID = try #require(session.activeLayerID)
        _ = try await api.call("mask_operation", arguments: [
            "action": "select", "layer_id": maskedID.uuidString, "target": "mask"
        ])
        let historyBefore = session.history.undoCount
        await #expect(throws: (any Error).self) {
            _ = try await api.call("filter_operation", arguments: [
                "layer_id": noMaskID.uuidString, "target": "mask",
                "kind": FilterKind.gaussianBlur.rawValue, "radius": 2
            ])
        }
        #expect(session.activeLayerID == maskedID)
        #expect(session.isMaskSelected)
        #expect(session.history.undoCount == historyBefore)
    }

    private func revision(_ response: [String: Any]) throws -> Int {
        let structured = try #require(response["structuredContent"] as? [String: Any])
        return try #require(structured["revision"] as? Int)
    }
}
