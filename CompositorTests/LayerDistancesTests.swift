import CoreGraphics
import Testing
@testable import Compositor

/// The Move tool's pixel gaps, to the canvas's edges and between layers.
struct LayerDistancesTests {
    private func gaps(_ lines: [DistanceLine]) -> [String] {
        lines.map { "\($0.horizontal ? "x" : "y") \(Int($0.from))–\(Int($0.to))" }.sorted()
    }

    @Test func aMovedLayerMeasuresToTheCanvasEdges() {
        let lines = LayerDistances.moving(CGRect(x: 100, y: 50, width: 300, height: 200), among: [], canvas: CGSize(width: 1000, height: 800))
        #expect(gaps(lines) == ["x 0–100", "x 400–1000", "y 0–50", "y 250–800"])
    }

    @Test func aMovedLayerMeasuresToTheNearestLayerLevelWithIt() {
        // One layer level with it on the right, one off below the canvas's right side that isn't level, and a full-canvas
        // background whose edges are the canvas's.
        let others = [CGRect(x: 700, y: 100, width: 100, height: 100), CGRect(x: 500, y: 600, width: 50, height: 50),
                      CGRect(x: 0, y: 0, width: 1000, height: 800)]
        let lines = LayerDistances.moving(CGRect(x: 100, y: 50, width: 300, height: 200), among: others, canvas: CGSize(width: 1000, height: 800))
        #expect(gaps(lines) == ["x 0–100", "x 400–700", "y 0–50", "y 250–800"])
        // At the middle of what the two share across: rows 100 to 200.
        #expect(lines.first { $0.horizontal && $0.from == 400 }?.across == 150)
    }

    @Test func twoLayersApartShowTheGapBetweenThem() {
        let lines = LayerDistances.between(CGRect(x: 100, y: 100, width: 300, height: 100), CGRect(x: 700, y: 150, width: 100, height: 100))
        #expect(gaps(lines) == ["x 400–700"])
    }

    @Test func aLayerInsideAnotherShowsEachSidesInset() {
        let lines = LayerDistances.between(CGRect(x: 100, y: 50, width: 300, height: 200), CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(gaps(lines) == ["x 0–100", "x 400–1000", "y 0–50", "y 250–800"])
    }
}
