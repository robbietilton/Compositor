import CoreGraphics
import Foundation
import Testing
@testable import Compositor

struct GenerativePlanTests {
    private let canvas = CGRect(x: 0, y: 0, width: 6000, height: 4000)

    @Test func theRegionHoldsTheTargetWithContextInAShapeTheModelAccepts() throws {
        let target = CGRect(x: 2000, y: 1500, width: 400, height: 300)
        let plan = try #require(GenerativePlan.make(target: target, bounds: canvas))
        #expect(plan.region.contains(target.insetBy(dx: -200, dy: -200)) && canvas.contains(plan.region))
        #expect(plan.region == plan.region.integral)
        #expect(abs(plan.region.width / plan.region.height - plan.ratio.value) < 0.01)
        #expect(GenerativeAspectRatio.standard.contains(plan.ratio))
        // 800 × 700 of target and context: small enough to send as it is.
        #expect(plan.size == .k1 && plan.sendSize == plan.region.size && plan.detail == 1)
    }

    @Test func aTargetInTheCornerSlidesTheRegionInsideTheCanvas() throws {
        let target = CGRect(x: 0, y: 0, width: 300, height: 900)
        let plan = try #require(GenerativePlan.make(target: target, bounds: canvas))
        #expect(plan.region.minX == 0 && plan.region.minY == 0 && plan.region.contains(target))
        #expect(abs(plan.region.width / plan.region.height - plan.ratio.value) < 0.01)
    }

    @Test func aRegionTheCanvasCannotHoldIsCentredPastItsEdges() throws {
        // A 1000 × 100 strip is wider than any ratio on offer: the region has to overhang top and bottom.
        let strip = CGRect(x: 0, y: 0, width: 1000, height: 100)
        let plan = try #require(GenerativePlan.make(target: strip, bounds: strip))
        #expect(plan.ratio == GenerativeAspectRatio(width: 21, height: 9))
        #expect(plan.region.minX == 0 && plan.region.width == 1000)
        #expect(plan.region.minY < 0 && plan.region.maxY > 100 && abs(plan.region.midY - 50) <= 1)
    }

    @Test func largeRegionsStepUpInSizeAndAreSentNoLargerThanTheModelAnswers() throws {
        let plan = try #require(GenerativePlan.make(target: canvas, bounds: canvas))
        #expect(plan.size == .k4 && plan.ratio == GenerativeAspectRatio(width: 3, height: 2))
        #expect(max(plan.sendSize.width, plan.sendSize.height) == 4096 && plan.detail < 1)
        let capped = try #require(GenerativePlan.make(target: canvas, bounds: canvas, largest: .k1))
        #expect(capped.size == .k1 && max(capped.sendSize.width, capped.sendSize.height) == 1024)
        let chosen = try #require(GenerativePlan.make(target: CGRect(x: 10, y: 10, width: 50, height: 50), bounds: canvas, fixed: .k2))
        #expect(chosen.size == .k2 && chosen.sendSize == chosen.region.size) // Never enlarged before sending.
    }

    @Test func expandRegionsMayStartLeftOfAndAboveTheOldCanvas() throws {
        let grown = CGRect(x: -500, y: -200, width: 7000, height: 4400)
        let band = CGRect(x: -500, y: -200, width: 532, height: 4400) // The new strip on the left, with its overlap.
        let plan = try #require(GenerativePlan.make(target: band, bounds: grown))
        #expect(plan.region.minX == -500 && plan.region.contains(band) && grown.contains(plan.region))
    }

    @Test func nothingToChangeMakesNoPlan() {
        #expect(GenerativePlan.make(target: CGRect(x: 7000, y: 0, width: 10, height: 10), bounds: canvas) == nil)
        #expect(GenerativePlan.make(target: .zero, bounds: canvas) == nil)
    }

    @Test func anAnswerInAnotherShapeIsReadFromItsMiddle() throws {
        let plan = try #require(GenerativePlan.make(target: CGRect(x: 100, y: 100, width: 800, height: 800), bounds: canvas))
        #expect(plan.ratio == GenerativeAspectRatio(width: 1, height: 1))
        #expect(plan.source(in: CGSize(width: 1024, height: 1024)) == CGRect(x: 0, y: 0, width: 1024, height: 1024))
        #expect(plan.source(in: CGSize(width: 1536, height: 1024)) == CGRect(x: 256, y: 0, width: 1024, height: 1024))
        #expect(plan.source(in: CGSize(width: 1024, height: 1280)) == CGRect(x: 0, y: 128, width: 1024, height: 1024))
    }
}

struct GenerativePlacementTests {
    private func layer(_ id: UUID, parent: UUID? = nil, group: Bool = false, opacity: Double? = nil,
                       clippedTo source: UUID? = nil, adjustment: LayerAdjustment? = nil) -> ProjectLayerRecord {
        ProjectLayerRecord(id: id, name: "Layer", isVisible: true,
                           transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)),
                           imageFile: nil, parentID: parent, isGroup: group, opacity: opacity, maskSourceID: source, adjustment: adjustment)
    }
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), folder = UUID()

    @Test func withNoActiveLayerEverythingIsSampledAndTheLayerGoesOnTop() {
        let plan = GenerativePlacement.plan([layer(a), layer(b)], activeID: nil)
        #expect(plan == GenerativePlacement(hiddenIDs: [], insertIndex: 2, parentID: nil))
    }

    @Test func layersAboveTheActiveOneAreLeftOutOfTheSample() {
        let plan = GenerativePlacement.plan([layer(a), layer(b), layer(c)], activeID: b)
        #expect(plan == GenerativePlacement(hiddenIDs: [c], insertIndex: 2, parentID: nil))
    }

    @Test func drawingOrderFollowsFoldersNotTheFlatList() {
        // Grouping appends a folder's children to the end of the list: this draws as A, C, D, B.
        let layers = [layer(a), layer(folder, group: true), layer(b), layer(c, parent: folder), layer(d, parent: folder)]
        let inside = GenerativePlacement.plan(layers, activeID: c)
        #expect(inside == GenerativePlacement(hiddenIDs: [d, b], insertIndex: 4, parentID: folder))
        // An active folder counts with all it holds, and the new layer goes above it, not into it.
        let whole = GenerativePlacement.plan(layers, activeID: folder)
        #expect(whole == GenerativePlacement(hiddenIDs: [b], insertIndex: 2, parentID: nil))
    }

    @Test func aClippingStackStaysInOnePiece() {
        let layers = [layer(a), layer(b, clippedTo: a), layer(c, clippedTo: a), layer(d)]
        for active in [a, b, c] {
            #expect(GenerativePlacement.plan(layers, activeID: active) == GenerativePlacement(hiddenIDs: [d], insertIndex: 3, parentID: nil))
        }
    }

    @Test func aFadedFolderLiftsTheLayerOutOfIt() {
        let layers = [layer(folder, group: true, opacity: 0.5), layer(a, parent: folder), layer(b, parent: folder), layer(c)]
        let plan = GenerativePlacement.plan(layers, activeID: a)
        #expect(plan == GenerativePlacement(hiddenIDs: [c], insertIndex: 1, parentID: nil))
    }
}
