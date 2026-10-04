import AppKit
import Testing
@testable import Compositor

@MainActor struct SmartEditTests {
    @Test func fillContinuesRepeatingTexture() async throws {
        let s = EditorSession(); s.createDocument(width: 80, height: 64)
        let ctx = try BrushRaster.context(width: 80, height: 64, mask: false)
        for x in 0..<80 {
            let value: CGFloat = (x/4)%2 == 0 ? 0.2 : 0.8
            ctx.setFillColor(CGColor(srgbRed: value, green: value, blue: value, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 64))
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 32, y: 26, width: 12, height: 10))
        let image = try #require(ctx.makeImage())
        s.insert(ImportedImage(image: image, thumbnail: image, name: "Stripes"))
        s.applySelection(CGPath(rect: CGRect(x: 32, y: 26, width: 12, height: 10), transform: nil), mode: .replace, name: "Select")
        s.beginFilter(.contentAwareFill); await s.commitFilter()
        let result = try #require(s.activeLayer?.asset?.image)
        BrushRaster.draw(result, in: CGRect(x: 0, y: 0, width: 80, height: 64), mask: false, context: ctx)
        let p=ctx.data!.assumingMemoryBound(to: UInt8.self)
        var matching=0
        for y in 26..<36 { for x in 32..<44 {
            if abs(Int(p[y*ctx.bytesPerRow+x*4])-((x/4)%2 == 0 ? 51 : 204)) <= 1 { matching += 1 }
        } }
        #expect(matching >= 114, "Matched \(matching) of 120 texture pixels")
    }

    func fixture() throws -> EditorSession {
        let s = EditorSession(); s.createDocument(width: 64, height: 48)
        let ctx = try BrushRaster.context(width: 64, height: 48, mask: false)
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 16, width: 12, height: 10))
        let image = try #require(ctx.makeImage())
        s.insert(ImportedImage(image: image, thumbnail: image, name: "Object"))
        s.applySelection(CGPath(rect: CGRect(x: 20, y: 16, width: 12, height: 10), transform: nil), mode: .replace, name: "Select")
        return s
    }
    @Test func fillReconstructsBackgroundInsideSelectionAndUndoes() async throws {
        let s = try fixture()
        let original = try #require(s.activeLayer?.asset?.image)
        let count = s.history.undoCount
        #expect(s.canContentAwareFill)
        s.beginFilter(.contentAwareFill)
        await s.commitFilter()
        #expect(s.filterEdit == nil && s.history.undoCount == count + 1)
        let image = try #require(s.activeLayer?.asset?.image)
        let ctx = try BrushRaster.context(width: 64, height: 48, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 48), mask: false, context: ctx)
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<48 { for x in 0..<64 {
            let i = y * ctx.bytesPerRow + x*4
            #expect(abs(Int(p[i])-51)<=1 && abs(Int(p[i+1])-153)<=1 && abs(Int(p[i+2])-204)<=1 && p[i+3]==255)
        } }
        s.undo(); #expect(s.activeLayer?.asset?.image === original)
    }
    @Test func cancelAndNoSourceLeaveOriginalUntouched() async throws {
        let s = try fixture(), original = s.activeLayer?.asset?.image
        s.beginFilter(.contentAwareFill); s.cancelFilter()
        #expect(s.activeLayer?.asset?.image === original)
        s.selectAll(); s.beginFilter(.contentAwareFill)
        await s.filterEdit?.previewTask?.value
        #expect(s.filterEdit?.previewError != nil)
        await s.commitFilter()
        #expect(s.activeLayer?.asset?.image === original)
        s.cancelFilter(); s.deselect()
        #expect(!s.canContentAwareFill)
    }
    @Test func visionRequestRunsOnAnImage() async throws {
        let image = try #require(fixture().activeLayer?.asset?.image)
        do {
            let result = try await Task.detached { try SubjectRemoval.run(image, settings: FilterSettings()) }.value
            #expect(result.width == image.width && result.height == image.height)
        } catch SubjectRemoval.Failure.noSubject {
            // A flat synthetic fixture may correctly contain no recognizable subject.
        }
    }
    @Test func removeBackgroundAppliesAfterASettingChangesWithPreviewOff() async throws {
        let s = EditorSession(); s.createDocument(width: 256, height: 256)
        let ctx = try BrushRaster.context(width: 256, height: 256, mask: false)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 64, y: 64, width: 128, height: 128))
        let image = try #require(ctx.makeImage())
        s.insert(ImportedImage(image: image, thumbnail: image, name: "Disc"))
        let count = s.history.undoCount
        s.beginFilter(.removeBackground)
        let edit = try #require(s.filterEdit)
        await edit.previewTask?.value
        #expect(edit.preparedPreview != nil && edit.previewError == nil)
        // Preview off, then Quality to Advanced, as the panel's toggle and picker do. Refine moves while that is
        // worked out, and its slider sends the new value again as it's dragged and when it's let go.
        s.updateFilter(edit.settings, preview: false)
        var advanced = edit.settings
        advanced.backgroundQuality = .advanced
        s.updateFilter(advanced, preview: false)
        advanced.refineEdges += 4
        s.updateFilter(advanced, preview: false)
        s.updateFilter(advanced, preview: false)
        await edit.previewTask?.value
        s.updateFilter(advanced, preview: false)
        await edit.previewTask?.value
        // OK is enabled: nothing is being worked out and there is no error.
        #expect(!edit.preparing && edit.previewError == nil)
        await s.commitFilter()
        #expect(s.filterEdit == nil && s.history.undoCount == count + 1)
        #expect(s.activeLayer?.mask != nil)
    }
    @Test func fillIsPreparedOnceWhenPreviewTurnsOffMeanwhile() async throws {
        let s = try fixture()
        s.beginFilter(.contentAwareFill)
        let edit = try #require(s.filterEdit)
        #expect(edit.preparing)
        // Preview off while the fill is still being worked out, as the panel's toggle does.
        s.updateFilter(edit.settings, preview: false)
        await edit.previewTask?.value
        // That fill is ready and is the one OK applies: it isn't worked out a second time.
        let prepared = try #require(edit.preparedPreview)
        #expect(!edit.preparing && edit.previewTask == nil)
        await s.commitFilter()
        #expect(s.filterEdit == nil && s.activeLayer?.asset?.image === prepared)
    }
}
