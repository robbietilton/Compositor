import AppKit
import Testing
@testable import Compositor

struct MagneticLassoTests {
    private func makeVerticalEdgeImage(width: Int, height: Int, edgeX: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: edgeX, height: height))
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: edgeX, y: 0, width: width - edgeX, height: height))
        return try #require(context.makeImage())
    }

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func snapsTowardTheStrongestNearbyEdge() throws {
        let image = try makeVerticalEdgeImage(width: 60, height: 40, edgeX: 30)
        let point = try #require(MagneticLasso.snap(in: image,
                                                    from: CGPoint(x: 10, y: 20),
                                                    to: CGPoint(x: 28, y: 20),
                                                    settings: .init(searchRadius: 8, edgeSensitivity: 1)))
        #expect(abs(point.x - 30) <= 1 && abs(point.y - 20) <= 1)
    }

    @Test func uniformOrInvalidInputDoesNotInventAnEdge() throws {
        let image = try makeSolidImage(width: 30, height: 30)
        #expect(MagneticLasso.snap(in: image, from: CGPoint(x: 4, y: 4), to: CGPoint(x: 20, y: 20), settings: .init()) == nil)
        #expect(MagneticLasso.snap(in: image, from: CGPoint(x: -1, y: 4), to: CGPoint(x: 20, y: 20), settings: .init()) == nil)
    }
}
