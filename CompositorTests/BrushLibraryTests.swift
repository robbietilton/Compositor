import AppKit
import Testing
@testable import Compositor

@MainActor
struct BrushLibraryTests {
    @Test func bundledStarterBrushesArePortableAndStoredSeparatelyFromUserPresets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("brushes.json")
        let library = BrushLibrary(url: url)
        #expect(library.error == nil)
        #expect(library.brushes.map(\.name) == ["Flat Marker", "Default Painting Brush", "Pencil", "Watercolor Wash"])
        #expect(library.current.name == "Default Painting Brush")
        #expect(library.brushes.allSatisfy { $0.isValid && $0.isRenderable && $0.source == nil
            && $0.roundDynamics.shapeSettings.customTip == nil && $0.roundDynamics.grain?.custom == nil })
        #expect(library.brushes[0].roundDynamics.shapeSettings.generatedKind == .ink)
        let watercolor = try #require(library.brushes.first { $0.name == "Watercolor Wash" })
        #expect(watercolor.roundDynamics.shapeSettings.generatedKind == .softRound)
        #expect(watercolor.roundDynamics.grain?.mode == .texturized)
        #expect(watercolor.roundDynamics.grain?.filtering == .improved)
        #expect(watercolor.roundDynamics.renderingSettings.mode == .uniformGlaze)
        #expect(watercolor.roundDynamics.renderingSettings.wetEdges == 0.32)
        #expect(watercolor.roundDynamics.renderingSettings.burntEdges > 0)
        #expect(watercolor.roundDynamics.flow == 0.8)
        #expect(watercolor.roundDynamics.renderingSettings.backruns == 0.24)
        #expect(watercolor.roundDynamics.path.lateralJitter == 0.035 && watercolor.roundDynamics.path.spacingJitter == 0.04)
        #expect(watercolor.roundDynamics.renderingSettings.burntEdges == 1)
        #expect(watercolor.roundDynamics.grain?.scale == 36 && watercolor.roundDynamics.grain?.depth == 0.34)
        #expect(watercolor.applying(to: BrushSettings()).usesStampDynamics)
        for brush in library.brushes {
            let session = EditorSession(); session.createDocument(width: 160, height: 80); session.addBlankLayer(); session.selectTool(.brush)
            try session.activateBrushPreset(brush, library: library)
            session.beginBrush(at: CGPoint(x: 30, y: 40)); session.continueBrush(at: CGPoint(x: 130, y: 40))
            #expect(session.finishBrushImmediately() && session.brushError == nil)
            #expect(session.activeLayer?.asset != nil, "Starter preset must paint without external source files")
        }
        var edited = library.brushes[0]; edited.name = "My Marker"
        try library.save(edited)
        try library.delete([library.brushes[2].id])
        let reopened = BrushLibrary(url: url)
        #expect(reopened.error == nil && reopened.brushes.count == 3)
        #expect(reopened.brushes[0].name == "My Marker" && !reopened.brushes.contains { $0.name == "Pencil" })
        #expect(reopened.brushes.contains { $0.name == "Watercolor Wash" })
    }

    @Test func watercolorWashProducesASettledTexturedEdgeAgainstPaper() throws {
        let library = BrushLibrary(url: nil)
        let preset = try #require(library.brushes.first { $0.name == "Watercolor Wash" })
        func paint(flow: CGFloat, burntEdges: CGFloat, backruns: CGFloat) throws -> CGImage {
            var brush = preset.applying(to: BrushSettings(red: 0.12, green: 0.34, blue: 0.55))
            brush.roundDynamics.flow = flow
            var rendering = brush.roundDynamics.renderingSettings
            rendering.burntEdges = burntEdges
            rendering.backruns = backruns
            brush.roundDynamics.rendering = rendering
            let size = CGSize(width: 512, height: 512)
            let layer = ImageLayer(name: "Paper", blankSize: size)
            let stroke = try BrushStroke(layer: layer, mask: false, settings: brush, canvas: size, seed: 4004)
            for index in 0...40 {
                let t = CGFloat(index) / 40
                try stroke.append(CGPoint(x: 56 + 400 * t, y: 256 + sin(t * .pi * 2) * 4),
                    input: BrushInput(pressure: 0.78, timestamp: Double(index) / 60))
            }
            try stroke.flush()
            print("WATERCOLOR STROKE flow=\(flow) burnt=\(burntEdges) diameter=\(stroke.settings.diameter) patches=\(stroke.patches.count) edgeCPU=\(stroke.edgePoolingMilliseconds)ms")
            let paper = try BrushRaster.context(width: 512, height: 512, mask: false)
            paper.setFillColor(NSColor.white.cgColor); paper.fill(CGRect(origin: .zero, size: size))
            LayerRenderer.drawBrushPreview(layer.asset?.image, transform: stroke.paintTransform,
                center: stroke.paintTransform.center, scale: 1, opacity: 1, blendMode: .normal,
                mask: nil, patches: stroke.patches, pixelWidth: stroke.width, pixelHeight: stroke.height,
                paintingMask: false, in: paper)
            return try #require(paper.makeImage())
        }
        let wash = try paint(flow: preset.roundDynamics.flow, burntEdges: preset.roundDynamics.renderingSettings.burntEdges,
            backruns: preset.roundDynamics.renderingSettings.backruns)
        let plain = try paint(flow: preset.roundDynamics.flow, burntEdges: 0, backruns: preset.roundDynamics.renderingSettings.backruns)
        let noFlow = try paint(flow: preset.roundDynamics.flow, burntEdges: 0, backruns: 0)
        let flowData = try #require(plain.dataProvider?.data) as Data
        let noFlowData = try #require(noFlow.dataProvider?.data) as Data
        let flowDifference = zip(flowData, noFlowData).reduce(into: 0) { if abs(Int($1.0) - Int($1.1)) > 8 { $0 += 1 } }
        print("WATERCOLOR FLOW changedChannels=\(flowDifference)")
        #expect(flowDifference > 20, "Settled flow should move a pale wash beyond the generated stroke silhouette")
        let washData = try #require(wash.dataProvider?.data) as Data
        let plainData = try #require(plain.dataProvider?.data) as Data
        let difference = zip(washData, plainData).reduce(into: 0) { if abs(Int($1.0) - Int($1.1)) > 8 { $0 += 1 } }
        let maxDifference = zip(washData, plainData).reduce(into: 0) { $0 = max($0, abs(Int($1.0) - Int($1.1))) }
        print("WATERCOLOR PRESET diameter=\(preset.diameter) hardness=\(preset.hardness) flow=\(preset.roundDynamics.flow) burnt=\(preset.roundDynamics.renderingSettings.burntEdges) changedChannels=\(difference)")
        print("WATERCOLOR PRESET maxChannelDifference=\(maxDifference)")
        #expect(difference > 20, "The settled edge must visibly darken the prototype-style paper wash")
        Attachment.record(try #require(NSBitmapImageRep(cgImage: plain).representation(using: .png, properties: [:])),
            named: "watercolor-wash-no-pooled-edge.png")
        Attachment.record(try #require(NSBitmapImageRep(cgImage: noFlow).representation(using: .png, properties: [:])),
            named: "watercolor-wash-no-flow.png")
        Attachment.record(try #require(NSBitmapImageRep(cgImage: wash).representation(using: .png, properties: [:])),
            named: "watercolor-wash-settled-edge.png")
    }

    @Test func legacyCollectionKeepsUserBrushesAndLoadsNewBundledPresets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("brushes.json")
        let legacy = BrushPreset(name: "My Saved Brush")
        let collection: [String: Any] = [
            "version": 1,
            "brushes": [["id": legacy.id.uuidString, "name": legacy.name]],
            "selectedID": legacy.id.uuidString
        ]
        try JSONSerialization.data(withJSONObject: collection).write(to: url)

        let library = BrushLibrary(url: url)
        #expect(library.error == nil)
        #expect(library.current.name == "My Saved Brush")
        #expect(library.brushes.contains { $0.name == "Watercolor Wash" })
        #expect(!library.brushes.contains { $0.name == "Pencil" }, "Deleted legacy bundled presets stay hidden during migration")
        try library.save(library.current)
        let reopened = BrushLibrary(url: url)
        #expect(reopened.error == nil && reopened.current.name == "My Saved Brush")
        #expect(reopened.brushes.contains { $0.name == "Watercolor Wash" })
        #expect(!reopened.brushes.contains { $0.name == "Pencil" })
    }

    @Test func presetsRoundTripWithoutChangingToolContextAndProtectUnknownData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("brushes.json")
        let library = BrushLibrary(url: url)
        var brush = library.current
        brush.name = "My Round"; brush.diameter = 123; brush.opacity = 0.4; brush.pressureSize = true
        try library.save(brush)
        let restored = BrushLibrary(url: url)
        #expect(restored.current == brush)
        var settings = BrushSettings(red: 0.7, green: 0.2, blue: 0.1)
        settings.erasing = true; settings.blurRadius = 19
        let applied = brush.applying(to: settings)
        #expect(applied.diameter == 123 && applied.opacity == 0.4 && applied.pressureSize)
        #expect(applied.red == 0.7 && applied.erasing && applied.blurRadius == 19)
        var invalid = brush; invalid.diameter = .nan
        #expect(throws: (any Error).self) { try restored.save(invalid) }
        #expect(BrushLibrary(url: url).current == brush)
        let unknown = Data("{\"version\":999,\"brushes\":[],\"selectedID\":null}".utf8)
        try unknown.write(to: url)
        let unsupported = BrushLibrary(url: url)
        #expect(unsupported.error != nil)
        #expect(throws: (any Error).self) { try unsupported.save(brush) }
        #expect(try Data(contentsOf: url) == unknown)
    }

    @Test func activationSelectsWithoutOpeningEditorAndPreservesToolContext() throws {
        let library = BrushLibrary(url: nil)
        let session = EditorSession()
        session.showsBrushPalette = true
        session.brushSettings.red = 0.7
        session.brushMode = .erase
        let preset = library.brushes[1]
        try session.activateBrushPreset(preset, library: library)
        #expect(session.selectedBrushPresetID == preset.id && library.current == preset)
        #expect(session.brushSettings.hardness == 0 && session.brushSettings.red == 0.7)
        #expect(session.brushMode == .erase && session.showsBrushPalette && !session.isEditingBrushPreset)
        var invalid = preset; invalid.diameter = .nan
        #expect(throws: (any Error).self) { try session.activateBrushPreset(invalid, library: library) }
        #expect(session.selectedBrushPresetID == preset.id && session.brushSettings.hardness == 0)
    }

    @Test func legacyDefaultsAndSourceDataSurviveNativeEditsAndRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("brushes.json")
        let id = UUID()
        try Data("{\"version\":1,\"brushes\":[{\"id\":\"\(id)\",\"name\":\"Legacy\"}]}".utf8).write(to: url)
        let library = BrushLibrary(url: url)
        #expect(library.error == nil)
        let defaults = BrushSettings()
        #expect(library.current.id == id && library.current.diameter == defaults.diameter)
        #expect(library.current.hardness == defaults.hardness && library.current.opacity == defaults.opacity)
        #expect(!library.current.pressureSize && !library.current.pressureOpacity)
        // Opaque bytes stand in for a future importer's complete original container, including unknown data.
        let original = try PropertyListSerialization.data(fromPropertyList: [
            "Brush.archive": ["unknownSetting": 0.123, "shape": "Odd/Shape.png"],
            "Sub01/Brush.archive": ["unknownDualSetting": [1, 2, 3]],
            "Reset/Brush.archive": Data([0, 255, 17]), "embedded.png": Data([1, 2, 3])
        ], format: .binary, options: 0)
        let digest = try library.retainSource(original)
        #expect(try library.retainSource(original) == digest)
        let source = BrushSource(archiveDigest: digest, filename: "Original.brushset", definitions: [
            .init(path: "Brush.archive", shapeReference: "Odd/Shape.png", grainReference: "Missing-Grain.png"),
            .init(path: "Sub01/Brush.archive", shapeReference: "Other.png", grainReference: nil)
        ])
        var brush = library.current
        brush.source = source
        try library.save(brush)
        brush.name = "Edited native name"; brush.diameter = 71
        try library.save(brush)
        let reopened = BrushLibrary(url: url)
        #expect(reopened.current == brush)
        #expect(try reopened.sourceData(for: source) == original)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingPathExtension().appendingPathExtension("sources").path)
        #expect(files == [digest])
        let settings = brush.applying(to: BrushSettings())
        #expect(settings.diameter == defaults.diameter, "Unmapped source data must not silently become a round brush")
        let session = EditorSession()
        #expect(throws: (any Error).self) { try session.activateBrushPreset(brush, library: reopened) }
        let saved = try Data(contentsOf: url)
        var invalid = brush; invalid.source?.archiveDigest = "../../outside"
        #expect(throws: (any Error).self) { try reopened.save(invalid) }
        #expect(try Data(contentsOf: url) == saved)
        try FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("sources").appendingPathComponent(digest))
        #expect(throws: (any Error).self) { try reopened.save(brush) }
        #expect(try Data(contentsOf: url) == saved)
    }

    @Test func activeSettingsPersistWithoutChangingOtherToolsOrTheProject() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("brushes.json")
        let library = BrushLibrary(url: url)
        let session = EditorSession()
        session.createDocument(width: 64, height: 64)
        session.addBlankLayer(); session.selectTool(.brush)
        try session.activateBrushPreset(library.current, library: library)
        let document = session.document
        let revision = session.history.currentRevision
        let undoCount = session.history.undoCount
        session.brushSettings.diameter = 97
        session.brushSettings.opacity = 0.42
        session.brushSettings.pressureSize = true
        try session.persistActiveBrushSettings(library: library)
        let reopened = BrushLibrary(url: url)
        #expect(reopened.current.diameter == 97 && reopened.current.opacity == 0.42 && reopened.current.pressureSize)
        session.selectTool(.cloneStamp)
        session.brushSettings.diameter = 18
        try session.persistActiveBrushSettings(library: library)
        #expect(library.current.diameter == 97)
        session.selectTool(.brush)
        #expect(session.brushSettings.diameter == 97)
        #expect(session.document == document && session.history.currentRevision == revision && session.history.undoCount == undoCount)
        let project = directory.appendingPathComponent("Unchanged.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: project)
        let loaded = try await ProjectStore.shared.load(from: project)
        let restored = EditorSession()
        restored.installProject(loaded, from: project)
        #expect(restored.document?.layers.map(\.id) == document?.layers.map(\.id))
        #expect(ProjectManifest.current == 20)
        // An unwritable destination must not publish a changed collection in memory.
        let obstruction = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: obstruction)
        let failing = BrushLibrary(url: obstruction.appendingPathComponent("brushes.json"))
        let before = failing.brushes
        #expect(throws: (any Error).self) { try failing.save(BrushPreset(name: "Can’t write")) }
        #expect(failing.brushes == before)
    }

    @Test func deletingBrushesPersistsAndKeepsAUsableSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("brushes.json")
        let library = BrushLibrary(url: url)
        let session = EditorSession()
        try session.activateBrushPreset(library.current, library: library)
        let active = session.selectedBrushPresetID
        let original = Data([1, 2, 3])
        let digest = try library.retainSource(original)
        var imported = BrushPreset(name: "Unsupported")
        imported.source = BrushSource(archiveDigest: digest, filename: "Source.brush", definitions: [
            .init(path: "Brush.archive", shapeReference: nil, grainReference: nil)
        ])
        try library.save(imported)
        var second = imported
        second.id = UUID(); second.name = "Another unsupported brush"
        try library.save(second)
        try session.deleteBrushPresets([imported.id, second.id], library: library)
        #expect(session.selectedBrushPresetID == active)
        #expect(!BrushLibrary(url: url).brushes.contains { $0.id == imported.id || $0.id == second.id })
        #expect(try library.sourceData(for: imported.source!) == original)
        let bundledIDs = Set(library.brushes.filter { $0.source == nil }.map(\.id))
        try session.deleteBrushPresets(bundledIDs, library: library)
        #expect(session.selectedBrushPresetID != active)
        #expect(session.selectedBrushPresetID == library.current.id)
        #expect(session.brushSettings.diameter == library.current.diameter)
        let reopened = BrushLibrary(url: url)
        #expect(reopened.error == nil && reopened.brushes.count == 1)
        #expect(reopened.current.source == nil && reopened.current.id == session.selectedBrushPresetID)

        let obstruction = directory.appendingPathComponent("not-a-directory")
        try original.write(to: obstruction)
        let failing = BrushLibrary(url: obstruction.appendingPathComponent("brushes.json"))
        let before = failing.brushes
        let selected = session.selectedBrushPresetID
        #expect(throws: (any Error).self) { try session.deleteBrushPresets(Set(failing.brushes.map(\.id)), library: failing) }
        #expect(failing.brushes == before && session.selectedBrushPresetID == selected)
    }

    @Test func changingSmoothingDuringAStrokeUsesTheStrokeSnapshot() {
        let session = EditorSession()
        session.createDocument(width: 320, height: 240)
        session.addBlankLayer(); session.selectTool(.brush)
        session.brushSettings.smoothing = 0
        session.beginBrush(at: CGPoint(x: 30, y: 30))
        session.brushSettings.smoothing = 100
        session.continueBrush(at: CGPoint(x: 50, y: 30))
        #expect(session.lastBrushPoint?.point == CGPoint(x: 50, y: 30))
        session.cancelBrush()
    }
}
