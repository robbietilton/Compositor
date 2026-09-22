import AppKit
import Testing
@testable import Compositor

@MainActor
struct RenderFinishTests {
    private func image() throws -> CGImage {
        let context = try BrushRaster.context(width: 48, height: 32, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.5, blue: 0.7, alpha: 0.5))
        context.fill(CGRect(x: 4, y: 4, width: 40, height: 24))
        return try #require(context.makeImage())
    }

    @Test func neutralStackPreservesSourceAndNormalizesInvalidInputs() throws {
        let source = try image()
        var settings = RenderFinishSettings()
        for effect in FinishEffect.allCases { settings[effect].enabled = false }
        #expect(settings.isIdentity)
        #expect(try settings.apply(source, scale: 1) === source)
        settings[.tonalContrast].amount = .nan
        settings[.tonalContrast].radius = .infinity
        settings[.tonalContrast].shadows = -200
        settings[.tonalContrast].protectHighlights = 200
        settings[.ink].palette = 99
        settings[.sensorGrain].radius = 100
        settings[.chromaticAberration].radius = 100
        let normalized = settings.normalized
        #expect(normalized[.tonalContrast].amount.isFinite)
        #expect(normalized[.tonalContrast].radius.isFinite)
        #expect(normalized[.tonalContrast].shadows == -100)
        #expect(normalized[.tonalContrast].protectHighlights == 100)
        #expect(normalized[.ink].palette == 5)
        #expect(normalized[.sensorGrain].radius == 6)
        #expect(normalized[.chromaticAberration].radius == 12)
    }

    @Test func cancelKeepsPixelsAndCommitAddsLayerInOneUndoStep() async throws {
        let source = try image()
        let session = EditorSession()
        session.createDocument(width: 48, height: 32)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Render"))
        let layerIndex = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        let originalID = try #require(session.activeLayerID)
        let effects = LayerEffects(stroke: StrokeEffect(size: 2), shadow: ShadowEffect())
        session.document?.layers[layerIndex].effects = effects
        let original = try #require(session.activeLayer)
        let clipped = ImageLayer(id: UUID(), asset: original.asset, name: "Clipped detail", isVisible: true,
            transform: original.transform, maskSourceID: originalID)
        session.document?.layers.insert(clipped, at: layerIndex + 1)
        let layersBefore = try #require(session.document?.layers.count)
        let count = session.history.undoCount
        session.beginFilter(.renderFinish)
        var settings = try #require(session.filterEdit).settings
        settings.renderFinish[.ink].enabled = true
        settings.renderFinish[.bloom].enabled = true
        session.updateFilter(settings, preview: false)
        #expect(session.activeLayer?.asset?.image === source)
        session.cancelFilter()
        #expect(session.activeLayer?.asset?.image === source)
        #expect(session.history.undoCount == count)
        #expect(session.document?.layers.count == layersBefore)
        session.beginFilter(.renderFinish)
        session.updateFilter(settings, preview: false)
        await session.commitFilter()
        #expect(session.filterEdit == nil)
        #expect(session.history.undoCount == count + 1)
        #expect(session.activeLayer?.asset?.image.width == source.width)
        #expect(session.activeLayer?.effects == effects)
        #expect(session.document?.layers.count == layersBefore + 1)
        #expect(session.activeLayerID != originalID)
        #expect(session.activeLayer?.name == "Render · Darkroom")
        #expect(session.activeLayer?.isVisible == true)
        #expect(session.document?.layers[layerIndex].asset?.image === source)
        #expect(session.document?.layers[layerIndex].isVisible == false)
        let resultID = session.activeLayerID
        #expect(session.document?.layers.first { $0.id == clipped.id }?.maskSourceID == resultID)
        session.undo()
        #expect(session.document?.layers.count == layersBefore)
        #expect(session.activeLayerID == originalID)
        #expect(session.activeLayer == original)
        #expect(session.document?.layers.first { $0.id == clipped.id }?.maskSourceID == originalID)
        #expect(session.activeLayer?.asset?.image === source)
        session.redo()
        #expect(session.document?.layers.count == layersBefore + 1)
        #expect(session.activeLayerID == resultID)
        #expect(session.document?.layers[layerIndex].isVisible == false)
    }

    @Test func disabledEffectsCommitWithoutAnUndoStep() async throws {
        let source = try image()
        let session = EditorSession()
        session.createDocument(width: 48, height: 32)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Render"))
        let layersBefore = session.document?.layers.count
        let count = session.history.undoCount
        session.beginFilter(.renderFinish)
        var settings = try #require(session.filterEdit).settings
        for effect in FinishEffect.allCases { settings.renderFinish[effect].enabled = false }
        session.updateFilter(settings, preview: false)
        await session.commitFilter()
        #expect(session.filterEdit == nil)
        #expect(session.history.undoCount == count)
        #expect(session.document?.layers.count == layersBefore)
    }

    @Test func zeroToneSlidersAreNeutralAndUndoWaitsForTheEdit() async throws {
        let source = try image()
        let session = EditorSession()
        session.createDocument(width: 48, height: 32)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Render"))
        let layersBefore = session.document?.layers.count
        session.beginFilter(.renderFinish)
        #expect(!session.canUndo)
        var settings = try #require(session.filterEdit).settings
        for effect in FinishEffect.allCases { settings.renderFinish[effect].enabled = false }
        settings.renderFinish[.tonalContrast].enabled = true
        settings.renderFinish[.tonalContrast].shadows = 0
        settings.renderFinish[.tonalContrast].midtones = 0
        settings.renderFinish[.tonalContrast].highlights = 0
        #expect(settings.renderFinish.isIdentity)
        session.updateFilter(settings, preview: false)
        await session.commitFilter()
        #expect(session.document?.layers.count == layersBefore)
    }

    @Test func presetsRoundTripAndLoadOlderVersions() throws {
        var settings = RenderFinishSettings()
        settings[.ink].enabled = true
        settings[.ink].palette = 3
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(RenderFinishSettings.self, from: data) == settings.normalized)
        var older = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        older.removeValue(forKey: "vignette")
        let decoded = try JSONDecoder().decode(RenderFinishSettings.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(!decoded[.vignette].enabled && decoded[.ink].palette == 3)
        for preset in RenderFinishPresets.builtIn { #expect(!preset.settings.isIdentity) }
    }

    @Test func mergedVisibleAddsAStampOnTopInOneUndoStep() async throws {
        let source = try image()
        let session = EditorSession()
        session.createDocument(width: 48, height: 32)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Render"))
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Top"))
        let before = try #require(session.document?.layers)
        let count = session.history.undoCount
        session.beginRenderFinish(source: .mergedVisible)
        #expect(session.filterEdit?.finishSource == .mergedVisible)
        await session.commitFilter()
        let after = try #require(session.document?.layers)
        #expect(after.count == before.count + 1)
        for (backup, original) in zip(after.dropLast(), before) {
            var expected = original
            if expected.parentID == nil { expected.isVisible = false }
            #expect(backup == expected)
        }
        #expect(session.activeLayerID == after.last?.id)
        #expect(session.history.undoCount == count + 1)
        session.undo()
        #expect(session.document?.layers == before)
    }

    @Test func mergedVisibleKeepsTransparencyAndHidesGroupsWithoutChangingTheirChildren() async throws {
        let source = try image()
        let session = EditorSession()
        session.createDocument(width: 48, height: 32)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Render"))
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        var group = ImageLayer(name: "Source group", blankSize: CGSize(width: 48, height: 32))
        group.isGroup = true
        group.opacity = 0.7
        session.document?.layers[index].parentID = group.id
        session.document?.layers[index].effects = LayerEffects(shadow: ShadowEffect())
        session.document?.layers.insert(group, at: index)
        let before = try #require(session.document?.layers)
        session.beginRenderFinish(source: .mergedVisible)
        let edit = try #require(session.filterEdit)
        let expected = try edit.settings.renderFinish.apply(edit.original.image, scale: 1, seed: edit.seed)
        await session.commitFilter()
        let document = try #require(session.document)
        #expect(document.layers.first { $0.id == group.id }?.isVisible == false)
        for original in before where original.parentID != nil {
            #expect(document.layers.first { $0.id == original.id } == original)
        }
        let context = try BrushRaster.context(width: 48, height: 32, mask: false)
        session.drawLiveComposite(document, in: context)
        let actual = try #require(context.makeImage())
        let actualBytes = try #require(actual.dataProvider?.data) as Data
        let expectedBytes = try #require(expected.dataProvider?.data) as Data
        #expect(actualBytes.count == expectedBytes.count)
        #expect(zip(actualBytes, expectedBytes).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        session.undo()
        #expect(session.document?.layers == before)
        session.redo()
        #expect(session.document?.layers == document.layers)
    }

    @Test func longPresetNamesReplaceAndPersistWithoutDuplicates() throws {
        let suite = "RenderFinishTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let presets = RenderFinishPresets(defaults: defaults)
        let name = String(repeating: "Photographic ", count: 8)
        var settings = RenderFinishSettings()
        presets.save(settings, named: "  \(name)  ")
        let id = try #require(presets.saved.first).id
        settings[.ink].enabled = true
        presets.save(settings, named: name.uppercased())
        #expect(presets.saved.count == 1)
        #expect(presets.saved.first?.id == id)
        #expect(presets.saved.first?.name.count == 60)
        let loaded = RenderFinishPresets(defaults: defaults)
        #expect(loaded.saved == presets.saved)
        #expect(loaded.saved.first?.settings == settings.normalized)
        loaded.delete(try #require(loaded.saved.first))
        #expect(RenderFinishPresets(defaults: defaults).saved.isEmpty)
    }

    @Test func photoRealismEffectsChangePixelsAndGrainFollowsItsSeed() throws {
        let context = try BrushRaster.context(width: 96, height: 64, mask: false)
        // Dark and near-white stripes: Highlight Rolloff only acts above the upper midtones.
        for x in stride(from: 0, to: 96, by: 4) {
            let bright = x.isMultiple(of: 8)
            context.setFillColor(CGColor(srgbRed: bright ? 0.97 : 0.25, green: bright ? 0.95 : 0.5, blue: bright ? 0.9 : 0.4, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 4, height: 64))
        }
        let source = try #require(context.makeImage())
        for effect in FinishEffect.allCases where effect.isPhotoRealism {
            var settings = RenderFinishSettings()
            for other in FinishEffect.allCases { settings[other].enabled = false }
            settings[effect].enabled = true
            #expect(!settings.isIdentity && settings.activeEffects == [effect])
            #expect(try settings.apply(source, scale: 1, seed: 3).dataProvider?.data != source.dataProvider?.data)
        }
        var grain = RenderFinishSettings()
        for other in FinishEffect.allCases { grain[other].enabled = false }
        grain[.sensorGrain].enabled = true
        let first = try grain.apply(source, scale: 1, seed: 3).dataProvider?.data
        #expect(try grain.apply(source, scale: 1, seed: 3).dataProvider?.data == first)
        #expect(try grain.apply(source, scale: 1, seed: 4).dataProvider?.data != first)
    }

    @Test func stageCacheMatchesAFullRender() throws {
        let source = try image()
        var settings = RenderFinishSettings()
        settings[.bloom].enabled = true
        settings[.vignette].enabled = true
        let cache = FinishStageCache()
        _ = try settings.apply(source, scale: 1, cache: cache)
        settings[.vignette].amount = 70
        let cached = try settings.apply(source, scale: 1, cache: cache)
        let full = try settings.apply(source, scale: 1)
        #expect(cached.dataProvider?.data == full.dataProvider?.data)
    }

    @Test func stageCacheIncludesGrainSeedAndCropPlacement() throws {
        let source = try image()
        let cache = FinishStageCache()
        var settings = RenderFinishSettings()
        settings[.sensorGrain].enabled = true
        settings[.vignette].enabled = true
        _ = try settings.apply(source, scale: 1, cache: cache, seed: 3)
        let reseeded = try settings.apply(source, scale: 1, cache: cache, seed: 4)
        let reseededFull = try settings.apply(source, scale: 1, seed: 4)
        #expect(reseeded.dataProvider?.data == reseededFull.dataProvider?.data)
        let region = FinishRegion(x: 0, y: 0, fullWidth: 96, fullHeight: 64)
        let cropped = try settings.apply(source, scale: 1, region: region, cache: cache, seed: 4)
        let croppedFull = try settings.apply(source, scale: 1, region: region, seed: 4)
        #expect(cropped.dataProvider?.data == croppedFull.dataProvider?.data)
    }

    @Test func stageCacheSnapshotsRemainConsistentWhenRendersOverlap() throws {
        let source = try image()
        let cache = FinishStageCache()
        let first = FinishStageCache.Stage(effect: .ink, parameters: FinishEffect.ink.defaults)
        let second = FinishStageCache.Stage(effect: .vignette, parameters: FinishEffect.vignette.defaults)
        var changed = first.parameters
        changed.amount = 100
        let other = FinishStageCache.Stage(effect: .ink, parameters: changed)
        cache.store([(first, source)], from: source, scale: 1, region: nil, seed: 0)
        let reused = cache.prefix(of: [first, second], from: source, scale: 1, region: nil, seed: 0)
        // A newer render finishes between the older render reading and publishing its prefix.
        cache.store([(other, source)], from: source, scale: 1, region: nil, seed: 0)
        cache.store(reused + [(second, source)], from: source, scale: 1, region: nil, seed: 0)
        #expect(cache.prefix(of: [first, second], from: source, scale: 1, region: nil, seed: 0).count == 2)
        #expect(cache.prefix(of: [other, second], from: source, scale: 1, region: nil, seed: 0).isEmpty)
    }
}
