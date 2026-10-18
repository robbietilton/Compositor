import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct CameraRawHistogramTests {
    private func session() throws -> EditorSession {
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Histogram fixture"))
        session.beginFilter(.cameraRaw)
        return session
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height)
    }

    @Test func equalRegionsIncludeExactBoundariesAndRightEdge() {
        let zones = CameraRawHistogramZone.allCases
        #expect(zones == [.blacks, .shadows, .exposure, .highlights, .whites])
        #expect(zones.map(\.identifier) == ["blacks", "shadows", "exposure", "highlights", "whites"])
        for (index, zone) in zones.enumerated() {
            #expect(CameraRawHistogramZone.at(x: CGFloat(index * 60), width: 300) == zone)
            #expect(CameraRawHistogramZone.at(x: CGFloat(index * 60) + 59.9, width: 300) == zone)
        }
        #expect(CameraRawHistogramZone.at(x: 300, width: 300) == .whites)
        #expect(CameraRawHistogramZone.at(x: 150, width: 300) == .exposure)
        #expect(CameraRawHistogramZone.at(x: 0.5, width: 1) == .exposure)
    }

    @Test func invalidGeometryAndNonfiniteValuesAreRejected() {
        for width: CGFloat in [0, -1, .nan, .infinity] {
            #expect(CameraRawHistogramZone.at(x: 0, width: width) == nil)
        }
        for x: CGFloat in [-1, 301, .nan, .infinity] {
            #expect(CameraRawHistogramZone.at(x: x, width: 300) == nil)
        }
        for zone in CameraRawHistogramZone.allCases {
            #expect(zone.value(from: .nan, translation: 1) == nil)
            #expect(zone.value(from: 0, translation: .infinity) == nil)
            #expect(zone.value(from: 0, translation: .nan) == nil)
        }
    }

    @Test func sensitivityPrecisionAndClampingMatchLightSliders() {
        for zone in CameraRawHistogramZone.allCases {
            #expect(zone.value(from: 0, translation: 10) == (zone == .exposure ? 0.1 : 10))
            #expect(zone.value(from: 0, translation: -10) == (zone == .exposure ? -0.1 : -10))
            #expect(zone.value(from: 0, translation: 100_000) == zone.range.upperBound)
            #expect(zone.value(from: 0, translation: -100_000) == zone.range.lowerBound)
        }
        #expect(CameraRawHistogramZone.exposure.value(from: 0.12, translation: 1.6) == 0.14)
        #expect(CameraRawHistogramZone.blacks.value(from: 0.2, translation: 1.4) == 2)
        #expect(CameraRawHistogramZone.exposure.value(from: 4.99, translation: 4) == 5)
    }

    @Test func eachRegionChangesOnlyItsOwnScalarAndKeepsPreviewOff() throws {
        for zone in CameraRawHistogramZone.allCases {
            let session = try session()
            defer { session.cancelFilter() }
            let edit = try #require(session.filterEdit)
            var settings = edit.settings
            settings.cameraRaw.temperature = 12
            settings.cameraRaw.contrast = -14
            session.updateFilter(settings, preview: false)
            edit.showsCameraRawLight = false
            edit.showsShadowClipping = true
            edit.showsHighlightClipping = true
            let undoCount = session.history.undoCount
            var drag = try #require(CameraRawHistogramDrag(edit: edit, zone: zone))
            let updated = drag.update(translation: 25, in: session)
            #expect(updated)
            settings.cameraRaw[keyPath: zone.key] = zone == .exposure ? 0.25 : 25
            #expect(edit.settings == settings)
            #expect(!edit.preview && !edit.showsCameraRawLight)
            #expect(edit.showsShadowClipping && edit.showsHighlightClipping)
            #expect(session.history.undoCount == undoCount)
            drag.finish(in: session)
        }
    }

    @Test func cumulativeTranslationKeepsTheOriginalBaselineAndRegion() throws {
        let session = try session()
        defer { session.cancelFilter() }
        let edit = try #require(session.filterEdit)
        var drag = try #require(CameraRawHistogramDrag(edit: edit, zone: .blacks))
        drag.update(translation: 20, in: session)
        var settings = edit.settings
        settings.cameraRaw.contrast = 27
        session.updateFilter(settings, preview: false)
        drag.update(translation: 130, in: session)
        #expect(edit.settings.cameraRaw.blacks == 100)
        drag.update(translation: 15, in: session)
        #expect(edit.settings.cameraRaw.blacks == 15, "returning from a clamp uses the original baseline")
        drag.update(translation: -5, in: session)
        #expect(edit.settings.cameraRaw.blacks == -5)
        #expect(drag.zone == .blacks)
        #expect(edit.settings.cameraRaw.contrast == 27)
        #expect(edit.settings.cameraRaw.whites == 0 && edit.settings.cameraRaw.exposure == 0)
        drag.finish(in: session)
        let updatedAfterFinish = drag.update(translation: 40, in: session)
        #expect(!updatedAfterFinish)
        #expect(edit.settings.cameraRaw.blacks == -5)
    }

    @Test func cancelledAndReopenedDraftOnSameLayerRejectsLateCallbacks() throws {
        let session = try session()
        let original = try #require(session.filterEdit)
        var drag = try #require(CameraRawHistogramDrag(edit: original, zone: .exposure))
        session.cancelFilter()
        session.beginFilter(.cameraRaw)
        defer { session.cancelFilter() }
        let replacement = try #require(session.filterEdit)
        #expect(original !== replacement && original.layerID == replacement.layerID)
        let settings = replacement.settings
        let staleUpdate = drag.update(translation: 80, option: true, in: session)
        #expect(!staleUpdate)
        #expect(drag.finished)
        #expect(replacement.settings == settings && replacement.cameraRawClipping == nil)
    }

    @Test func vectorscopeAndCommittingInvalidateGesturesPermanently() throws {
        let session = try session()
        defer { session.cancelFilter() }
        let edit = try #require(session.filterEdit)
        var drag = try #require(CameraRawHistogramDrag(edit: edit, zone: .shadows))
        edit.cameraRawScopeMode = .vectorscope
        #expect(CameraRawHistogramDrag(edit: edit, zone: .shadows) == nil)
        let updatedAfterFinish = drag.update(translation: 40, in: session)
        #expect(!updatedAfterFinish)
        edit.cameraRawScopeMode = .histogram
        let resumedUpdate = drag.update(translation: 50, in: session)
        #expect(!resumedUpdate)
        var committing = try #require(CameraRawHistogramDrag(edit: edit, zone: .whites))
        edit.committing = true
        let updateDuringCommit = committing.update(translation: 30, in: session)
        #expect(!updateDuringCommit)
        #expect(CameraRawHistogramDrag(edit: edit, zone: .whites) == nil)
        edit.committing = false
        let updateAfterCommit = committing.update(translation: 40, in: session)
        #expect(!updateAfterCommit)
        #expect(edit.settings.cameraRaw.shadows == 0 && edit.settings.cameraRaw.whites == 0)
    }

    @Test func wrongFilterAndNonfiniteDragDoNotWriteSettings() throws {
        let session = try session()
        let edit = try #require(session.filterEdit)
        var drag = try #require(CameraRawHistogramDrag(edit: edit, zone: .highlights))
        let settings = edit.settings
        let invalidUpdate = drag.update(translation: .nan, option: true, in: session)
        #expect(!invalidUpdate)
        #expect(edit.settings == settings && edit.cameraRawClipping == nil)
        session.cancelFilter()
        session.beginFilter(.gaussianBlur)
        defer { session.cancelFilter() }
        let blur = try #require(session.filterEdit)
        #expect(CameraRawHistogramDrag(edit: blur, zone: .blacks) == nil)
        let wrongFilterUpdate = drag.update(translation: 25, in: session)
        #expect(!wrongFilterUpdate)
    }

    @Test func optionClippingIsTemporaryAndPersistentIndicatorsArePreserved() throws {
        for zone in CameraRawHistogramZone.allCases {
            let session = try session()
            defer { session.cancelFilter() }
            let edit = try #require(session.filterEdit)
            edit.showsShadowClipping = true
            edit.showsHighlightClipping = true
            var drag = try #require(CameraRawHistogramDrag(edit: edit, zone: zone))
            drag.update(translation: 10, option: true, in: session)
            #expect(edit.cameraRawClipping == zone.clipping)
            drag.update(translation: 11, in: session)
            #expect(edit.cameraRawClipping == nil)
            drag.update(translation: 12, option: true, in: session)
            drag.finish(in: session)
            #expect(edit.cameraRawClipping == nil)
            #expect(edit.showsShadowClipping && edit.showsHighlightClipping)
        }
    }

    @Test func finishRestoresOnlyClippingOwnedByThisGesture() throws {
        let session = try session()
        defer { session.cancelFilter() }
        let edit = try #require(session.filterEdit)
        edit.cameraRawClipping = .shadows
        var drag = try #require(CameraRawHistogramDrag(edit: edit, zone: .exposure))
        drag.update(translation: 20, in: session)
        #expect(edit.cameraRawClipping == .shadows)
        drag.update(translation: 21, option: true, in: session)
        #expect(edit.cameraRawClipping == .highlights)
        drag.finish(in: session)
        #expect(edit.cameraRawClipping == .shadows)
        var other = try #require(CameraRawHistogramDrag(edit: edit, zone: .exposure))
        other.update(translation: 1, option: true, in: session)
        edit.cameraRawClipping = nil // The existing Option-release monitor already removed it.
        other.finish(in: session)
        #expect(edit.cameraRawClipping == nil)
    }

    @Test func accessibleIncrementsUseTheSameBoundedEditPath() throws {
        let session = try session()
        defer { session.cancelFilter() }
        let edit = try #require(session.filterEdit)
        session.updateFilter(edit.settings, preview: false)
        for zone in CameraRawHistogramZone.allCases {
            CameraRawHistogramDrag.adjust(zone, increment: true, edit: edit, in: session)
            #expect(edit.settings.cameraRaw[keyPath: zone.key] == zone.sensitivity)
            CameraRawHistogramDrag.adjust(zone, increment: false, edit: edit, in: session)
            #expect(edit.settings.cameraRaw[keyPath: zone.key] == 0)
            var settings = edit.settings
            settings.cameraRaw[keyPath: zone.key] = zone.range.upperBound
            session.updateFilter(settings, preview: false)
            CameraRawHistogramDrag.adjust(zone, increment: true, edit: edit, in: session)
            #expect(edit.settings.cameraRaw[keyPath: zone.key] == zone.range.upperBound)
        }
        let settings = edit.settings
        edit.cameraRawScopeMode = .vectorscope
        CameraRawHistogramDrag.adjust(.exposure, increment: false, edit: edit, in: session)
        #expect(edit.settings == settings && !edit.preview)
    }

    @Test func newestPreviewAndScopeConvergeAfterRapidDragUpdates() async throws {
        let session = try session()
        defer { session.cancelFilter() }
        let edit = try #require(session.filterEdit)
        var drag = try #require(CameraRawHistogramDrag(edit: edit, zone: .exposure))
        for translation: CGFloat in [20, -40, 100] { drag.update(translation: translation, in: session) }
        drag.finish(in: session)
        while let task = edit.previewTask { await task.value }
        let reference = try CameraRawScope.preview(edit.previewJob)
        #expect(edit.settings.cameraRaw.exposure == 1)
        #expect(edit.preparedSettings == edit.settings && edit.pending == nil)
        #expect(try pixels(try #require(edit.preparedPreview)) == pixels(reference.image))
        #expect(edit.cameraRawScope?.red == reference.scope.red)
        #expect(edit.cameraRawScope?.green == reference.scope.green)
        #expect(edit.cameraRawScope?.blue == reference.scope.blue)
    }

    @Test func cancelPreservesPixelsAndCommitCreatesOneUndoWithRedo() async throws {
        let session = try session()
        let original = try pixels(try #require(session.activeLayer?.asset?.image))
        let count = session.history.undoCount
        let cancelledEdit = try #require(session.filterEdit)
        var cancelled = try #require(CameraRawHistogramDrag(edit: cancelledEdit, zone: .exposure))
        cancelled.update(translation: 100, in: session)
        session.cancelFilter()
        #expect(session.history.undoCount == count)
        #expect(try pixels(try #require(session.activeLayer?.asset?.image)) == original)
        session.beginFilter(.cameraRaw)
        let committedEdit = try #require(session.filterEdit)
        var committed = try #require(CameraRawHistogramDrag(edit: committedEdit, zone: .exposure))
        for translation: CGFloat in [20, 40, 100] { committed.update(translation: translation, in: session) }
        committed.finish(in: session)
        await session.commitFilter()
        #expect(session.filterEdit == nil && session.history.undoCount == count + 1)
        let result = try pixels(try #require(session.activeLayer?.asset?.image))
        #expect(result != original)
        session.undo()
        #expect(try pixels(try #require(session.activeLayer?.asset?.image)) == original)
        session.redo()
        #expect(try pixels(try #require(session.activeLayer?.asset?.image)) == result)
    }

    private func nativeSliders(_ view: NSView) -> [CameraRawSliderView] {
        (view as? CameraRawSliderView).map { [$0] } ?? view.subviews.flatMap(nativeSliders)
    }

    @Test func hostedControlsRenderAndSynchronizeWithTheNativeExposureSlider() throws {
        let session = try session()
        let edit = try #require(session.filterEdit)
        session.updateFilter(edit.settings, preview: false)
        let host = NSHostingView(rootView: CameraRawControls(session: session).frame(width: 360, height: 800))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close(); session.cancelFilter() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        let slider = try #require(nativeSliders(host).first { $0.minValue == -5 && $0.maxValue == 5 })
        #expect(slider.doubleValue == edit.settings.cameraRaw.exposure)
        var drag = try #require(CameraRawHistogramDrag(edit: edit, zone: .exposure))
        drag.update(translation: 125, in: session)
        drag.finish(in: session)
        host.rootView = CameraRawControls(session: session).frame(width: 360, height: 800)
        host.layoutSubtreeIfNeeded()
        let updatedSlider = try #require(nativeSliders(host).first { $0.minValue == -5 && $0.maxValue == 5 })
        #expect(updatedSlider.doubleValue == 1.25, "histogram changes reach the actual AppKit slider")
        updatedSlider.doubleValue = -0.5
        let sent = updatedSlider.sendAction(updatedSlider.action, to: updatedSlider.target)
        #expect(sent)
        #expect(edit.settings.cameraRaw.exposure == -0.5, "the native slider writes back to the same draft")
        #expect(!edit.preview)
        edit.cameraRawScopeMode = .vectorscope
        host.rootView = CameraRawControls(session: session).frame(width: 360, height: 800)
        host.layoutSubtreeIfNeeded()
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(edit.settings.cameraRaw.exposure == -0.5)
    }

    @Test func feedbackUsesCurrentLanguageAndExposurePrecision() throws {
        let language = try #require(Bundle.main.preferredLocalizations.first)
        let chinese = language == "zh-Hans"
        #expect(CameraRawHistogramZone.allCases.map(\.title) == (chinese
            ? ["黑色", "阴影", "曝光", "高光", "白色"]
            : ["Blacks", "Shadows", "Exposure", "Highlights", "Whites"]))
        var raw = CameraRawSettings()
        raw.exposure = 1.25
        raw.blacks = -12
        #expect(CameraRawHistogramZone.exposure.readout(raw) == "1.25 EV")
        #expect(CameraRawHistogramZone.blacks.readout(raw) == "-12")
        #expect(AppLocalization.string("Drag left or right to adjust tones.") == (chinese ? "左右拖动以调整色调。" : "Drag left or right to adjust tones."))
    }
}
