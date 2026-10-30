import Foundation
import Testing
import UIKit
@testable import Compositor

/// A tab's project and its file on iPad.
@MainActor struct PadDocumentTests {
    /// A new canvas is written to its file as it's made, so the file is where the project starts, as an opened
    /// project's does: undo doesn't take the tab back to no canvas at all, and a file with nothing left to save.
    @Test func aNewCanvasStartsFromItsFile() async throws {
        let tab = EditorTab()
        tab.session.createNewProject(width: 64, height: 48)
        try await tab.createDocument(named: "PadDocumentTests \(UUID().uuidString)")
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!tab.session.canUndo)
        tab.session.undo()
        #expect(tab.session.document?.layers.count == 1)
        #expect(!tab.session.isModified)
        await tab.close()
    }

    /// An undo back to what the file had, made while a save was still writing the edit it undoes, leaves the file
    /// behind the project: the document still has it to save, so it's saved when the app goes to the background.
    @Test func anUndoDuringASaveIsStillSaved() async throws {
        let tab = EditorTab()
        tab.session.createNewProject(width: 64, height: 48)
        try await tab.createDocument(named: "PadDocumentTests \(UUID().uuidString)")
        let document = try #require(tab.document)
        defer { try? FileManager.default.removeItem(at: document.fileURL) }
        func settle() async { for _ in 0..<20 { await Task.yield() } }

        tab.session.addBlankLayer()
        await settle()
        #expect(document.hasUnsavedChanges, "the edit")
        // A save of the new layer begins; before it's written, undo takes the layer away again.
        let saving = document.changeCountToken(for: .forOverwriting)
        tab.session.undo()
        await settle()
        #expect(!document.hasUnsavedChanges, "back to the file")
        // The save writes the layer, which the project no longer has.
        document.updateChangeCount(withToken: saving, for: .forOverwriting)
        await settle()
        #expect(tab.session.isModified)
        #expect(document.hasUnsavedChanges, "the undo")
        await tab.close()
    }

    /// A rectangle with smooth corners, which format version 14 added, is saved through the document at the current
    /// version and opens from its file with them, redrawn with them at a new size, as on the Mac. A file saying it's version 13
    /// can't have them: it opens without them, and is refused as invalid with them.
    @Test func aSmoothRectangleSavesAndOpensAtVersion14() async throws {
        let tab = EditorTab()
        let session = tab.session
        session.createNewProject(width: 120, height: 90)
        try await tab.createDocument(named: "PadDocumentTests \(UUID().uuidString)")
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        session.selectTool(.shape)
        session.shapeKind = .rectangle
        session.shapeCornerRadius = 12
        session.shapeSmoothing = true
        session.beginShape(at: CGPoint(x: 10, y: 10))
        session.dragShape(to: CGPoint(x: 90, y: 70), square: false, fromCenter: false)
        session.finishShape()
        let made = try #require(session.activeLayer?.liveShape?.image)
        let smooth = try EditorSession.shapeImage(.rectangle, size: CGSize(width: 80, height: 60), color: session.foregroundColor,
                                                  cornerRadius: 12, smoothing: true)
        #expect(made.dataProvider?.data == smooth.dataProvider?.data)
        try await tab.document?.saveNow()
        await tab.close()

        let manifestURL = url.appending(path: "manifest.json")
        func manifest() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        }
        #expect(try manifest()["version"] as? Int == ProjectManifest.current)
        let opened = EditorSession()
        let document = CompositorDocument(fileURL: url, session: opened)
        try await document.openDocument()
        #expect(opened.activeLayer?.liveShape?.style.smoothing == true)
        opened.beginTransform()
        var transform = try #require(opened.transformEdit?.draft)
        transform.size = CGSize(width: 100, height: 50)
        opened.previewTransform(transform)
        opened.commitTransform()
        let redrawn = try #require(opened.activeLayer?.liveShape?.image)
        let reference = try EditorSession.shapeImage(.rectangle, size: transform.size, color: session.foregroundColor,
                                                     cornerRadius: 12, smoothing: true)
        #expect(redrawn.width == 100 && redrawn.height == 50)
        #expect(redrawn.dataProvider?.data == reference.dataProvider?.data)
        await document.closeDocument()

        var older = try manifest()
        #expect(older["version"] as? Int == ProjectManifest.current)
        older["version"] = 13
        var layers = try #require(older["layers"] as? [[String: Any]])
        let smoothed = try #require(layers.firstIndex { ($0["shape"] as? [String: Any])?["smoothing"] as? Bool == true })
        var shape = try #require(layers[smoothed]["shape"] as? [String: Any])
        shape["smoothing"] = nil
        layers[smoothed]["shape"] = shape
        var plain = older
        plain["layers"] = layers
        try JSONSerialization.data(withJSONObject: plain).write(to: manifestURL)
        let circular = EditorSession()
        let control = CompositorDocument(fileURL: url, session: circular)
        try await control.openDocument()
        #expect(circular.activeLayer?.liveShape?.style.smoothing == nil)
        await control.closeDocument()

        try JSONSerialization.data(withJSONObject: older).write(to: manifestURL)
        let refused = CompositorDocument(fileURL: url, session: EditorSession())
        let error = await #expect(throws: ProjectError.self) { try await refused.openDocument() }
        guard case .invalid = error else { Issue.record("refused as \(String(describing: error))"); return }
    }

    /// What the Mac's format added after version 14 saves through the document and opens from its file as it was, where
    /// the iPad has no editor for some of it yet: a GIF layer with an edited frame and its copy and a timing of its own
    /// (version 17), Vignette, Lens Effects and Tonal Contrast layers (18), a Sharpen layer (19), Lens Effects' prism
    /// fringe (20), and a dashed line (15). The GIF's frames go through the same reads and saves as the layers' images:
    /// read as they're drawn, and written again as the bytes they were read from.
    @Test func everyLayerKindTheMacAddedSavesAndOpens() async throws {
        let gif = try PadGIFFixture.url()
        defer { try? FileManager.default.removeItem(at: gif) }
        let tab = EditorTab()
        let session = tab.session
        session.createNewProject(width: 32, height: 24)
        try await tab.createDocument(named: "PadDocumentTests \(UUID().uuidString)")
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }

        await session.importImages([gif])
        let gifID = try #require(session.activeLayer?.gifAnimation != nil ? session.activeLayerID : nil)
        await session.selectGIFTimelineFrame(1)
        await session.invertPixels()
        await session.duplicateGIFFrame(at: 1, for: gifID)
        var timing = session.gifTimelineTiming
        timing.mode = .uniform
        timing.uniformDelay = 0.2
        session.setGIFFrameTiming(timing, for: gifID)

        var settings: [AdjustmentKind: LayerAdjustment] = [:]
        for kind in [AdjustmentKind.vignette, .lensEffects, .tonalContrast, .sharpen] {
            session.addAdjustment(kind)
            session.adjustmentEditingID = nil
            var adjustment = try #require(session.activeLayer?.adjustment)
            switch kind {
            case .vignette:
                adjustment.filterLayer.vignette = VignetteLayerSettings()
                adjustment.filterLayer.vignette?.amount = 80
            case .lensEffects:
                adjustment.filterLayer.lens = LensEffectSettings()
                adjustment.filterLayer.lens?.effect = .prism
                adjustment.filterLayer.lens?.prismFringe = 70
            case .tonalContrast:
                adjustment.filterLayer.tonal = TonalLayerSettings()
                adjustment.filterLayer.tonal?.amount = 100
            default:
                adjustment.filterLayer.sharpen = SharpenLayerSettings()
                adjustment.filterLayer.sharpen?.amount = 200
            }
            session.updateAdjustment(try #require(session.activeLayerID), value: adjustment)
            settings[kind] = adjustment
        }
        session.selectTool(.shape)
        session.shapeKind = .line
        session.shapeLineStyle = .dashed
        session.shapeLineCap = .square
        session.beginShape(at: CGPoint(x: 4, y: 12))
        session.dragShape(to: CGPoint(x: 28, y: 12), square: false, fromCenter: false)
        session.finishShape()
        try await tab.document?.saveNow()
        await tab.close()

        let manifestURL = url.appending(path: "manifest.json")
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        #expect(manifest["version"] as? Int == ProjectManifest.current)
        #expect(ProjectManifest.current == 20)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.appending(path: "images").path)
        #expect(files.contains("\(gifID.uuidString).gif"))
        #expect(files.filter { $0.hasPrefix("\(gifID.uuidString).frame-") }.count == 2, "the edited frame and its copy: \(files)")

        let opened = EditorSession()
        let document = CompositorDocument(fileURL: url, session: opened)
        try await document.openDocument()
        let layers = try #require(opened.document?.layers)
        let animation = try #require(layers.first { $0.id == gifID }?.gifAnimation)
        #expect(animation.frames.count == 5)
        #expect(animation.timing.mode == .uniform && animation.timing.uniformDelay == 0.2)
        #expect(animation.framePixels.count == 2)
        for (kind, adjustment) in settings {
            #expect(layers.first { $0.adjustment?.kind == kind }?.adjustment == adjustment, "\(kind)")
        }
        #expect(layers.first { $0.adjustment?.kind == .lensEffects }?.adjustment?.filterLayer.lens?.prismFringe == 70)
        let line = try #require(layers.first { $0.liveShape?.style.kind == .line }?.liveShape?.style)
        #expect(line.lineStyle == .dashed && line.lineCap == .square)

        // Nothing changed: the save writes every file as the bytes it was read from, the GIF's frames among them.
        let encoded = document.encoded.encoded
        let package = try ProjectStore.package(for: try #require(opened.projectSnapshot()), encoded: document.encoded)
        #expect(document.encoded.encoded == encoded, "nothing encoded again")
        let images = try #require(package.fileWrappers?["images"]?.fileWrappers)
        for name in files {
            #expect(images[name]?.regularFileContents == (try Data(contentsOf: url.appending(path: "images/\(name)"))), "\(name)")
        }
        await document.closeDocument()
    }
}
