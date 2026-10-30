import AppKit
import Testing
@testable import Compositor

@MainActor
struct AutoAlignTests {
    /// A busy, photo-like scene: a gradient under a few hundred overlapping soft shapes, the same every run.
    private func scene(width: Int = 640, height: Int = 480) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [CGColor(srgbRed: 0.2, green: 0.3, blue: 0.5, alpha: 1), CGColor(srgbRed: 0.9, green: 0.7, blue: 0.3, alpha: 1)] as CFArray,
            locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        var seed: UInt64 = 42
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt64(1) << 31)
        }
        for _ in 0..<500 {
            context.setFillColor(CGColor(srgbRed: random(), green: random(), blue: random(), alpha: 0.4 + random() * 0.6))
            let rect = CGRect(x: random() * CGFloat(width), y: random() * CGFloat(height), width: 6 + random() * 50, height: 6 + random() * 50)
            if random() < 0.5 { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        return try #require(context.makeImage())
    }

    private func insert(_ image: CGImage, _ name: String, into session: EditorSession, transform: LayerTransform) throws -> UUID {
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform = transform
        return id
    }

    @Test func aMatchThatOnlyShiftsIsAMoveAndAnyOtherIsNot() {
        let transform = LayerTransform(origin: CGPoint(x: 10, y: 20), size: CGSize(width: 100, height: 50))
        let shifted = DistortWarp.corners(of: transform).map { CGPoint(x: $0.x - 37.2, y: $0.y + 20.9) }
        let offset = AutoAlign.offset(from: transform, to: shifted)
        #expect(abs((offset?.width ?? 0) + 37.2) < 1e-9 && abs((offset?.height ?? 0) - 20.9) < 1e-9)
        var tilted = shifted
        tilted[2].x += 3
        #expect(AutoAlign.offset(from: transform, to: tilted) == nil)
    }

    @Test func aShiftedCopyMovesBackOverTheActiveLayerWithoutResampling() async throws {
        let session = EditorSession()
        session.createDocument(width: 640, height: 480)
        let image = try scene()
        let size = CGSize(width: 640, height: 480)
        let shiftedID = try insert(image, "Shifted", into: session, transform: LayerTransform(origin: CGPoint(x: 37, y: -21), size: size))
        let referenceID = try insert(image, "Reference", into: session, transform: LayerTransform(origin: .zero, size: size))
        // Making a layer active selects it alone, so the selection comes after.
        session.activeLayerID = referenceID
        session.selectedLayerIDs = [shiftedID, referenceID]
        #expect(session.canAutoAlignLayers)
        let count = session.history.undoCount
        await session.autoAlignLayers()
        #expect(session.alignError == nil)
        let shifted = try #require(session.document?.layers.first { $0.id == shiftedID })
        #expect(shifted.transform.origin == .zero, "\(shifted.transform.origin)")
        #expect(shifted.asset?.image === image)
        #expect(session.document?.layers.first { $0.id == referenceID }?.transform.origin == .zero)
        #expect(session.history.undoCount == count + 1)
    }

    @Test func overlappingFramesOfOneSceneLineUpLikeAPanorama() async throws {
        let session = EditorSession()
        session.createDocument(width: 640, height: 480)
        let image = try scene(width: 720)
        // Two 400-wide frames of the scene sharing a quarter of their width, both dropped at the canvas's left edge.
        let left = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 480)))
        let right = try #require(image.cropping(to: CGRect(x: 300, y: 0, width: 400, height: 480)))
        let size = CGSize(width: 400, height: 480)
        let rightID = try insert(right, "Right", into: session, transform: LayerTransform(origin: .zero, size: size))
        let leftID = try insert(left, "Left", into: session, transform: LayerTransform(origin: .zero, size: size))
        session.activeLayerID = leftID
        session.selectedLayerIDs = [rightID, leftID]
        await session.autoAlignLayers()
        #expect(session.alignError == nil)
        let moved = try #require(session.document?.layers.first { $0.id == rightID })
        #expect(moved.transform.origin == CGPoint(x: 300, y: 0), "\(moved.transform)")
        #expect(moved.asset?.image === right)
    }

    @Test func aCopySeenFromAnotherAngleIsDistortedBackIntoPlace() async throws {
        let session = EditorSession()
        session.createDocument(width: 640, height: 480)
        let image = try scene()
        let size = CGSize(width: 640, height: 480)
        let tilted = try DistortWarp.warp(image, transform: LayerTransform(origin: .zero, size: size),
            corners: [CGPoint(x: 30, y: 10), CGPoint(x: 600, y: 40), CGPoint(x: 620, y: 470), CGPoint(x: 5, y: 440)], isMask: false)
        let tiltedID = try insert(tilted.image, "Tilted", into: session, transform: tilted.transform)
        let referenceID = try insert(image, "Reference", into: session, transform: LayerTransform(origin: .zero, size: size))
        // Making a layer active selects it alone, so the selection comes after.
        session.activeLayerID = referenceID
        session.selectedLayerIDs = [tiltedID, referenceID]
        await session.autoAlignLayers()
        #expect(session.alignError == nil)
        // The warped copy's pixels now sit back over the original's: its bounds are the canvas again, to a pixel or two.
        let aligned = try #require(session.document?.layers.first { $0.id == tiltedID })
        #expect(aligned.asset?.image !== tilted.image)
        let box = aligned.transform
        #expect(abs(box.origin.x) <= 2 && abs(box.origin.y) <= 2, "\(box)")
        #expect(abs(box.size.width - 640) <= 3 && abs(box.size.height - 480) <= 3, "\(box)")
    }

    @Test func unrelatedPicturesAreReportedRatherThanMoved() async throws {
        let session = EditorSession()
        session.createDocument(width: 640, height: 480)
        let size = CGSize(width: 640, height: 480)
        let flat = try BrushRaster.context(width: 640, height: 480, mask: false)
        flat.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        flat.fill(CGRect(origin: .zero, size: size))
        let gray = try #require(flat.makeImage())
        let grayID = try insert(gray, "Gray", into: session, transform: LayerTransform(origin: CGPoint(x: 5, y: 5), size: size))
        let referenceID = try insert(try scene(), "Reference", into: session, transform: LayerTransform(origin: .zero, size: size))
        // Making a layer active selects it alone, so the selection comes after.
        session.activeLayerID = referenceID
        session.selectedLayerIDs = [grayID, referenceID]
        await session.autoAlignLayers()
        let after = try #require(session.document?.layers.first { $0.id == grayID })
        // Vision answers even here (an identity, at full confidence), so this is the pixel check at work.
        #expect(session.alignError != nil)
        #expect(after.transform.origin == CGPoint(x: 5, y: 5), "\(after.transform)")
    }

    @Test func onlyPlainPixelLayersTakePart() throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 48)
        let image = try scene(width: 64, height: 48)
        let a = try insert(image, "A", into: session, transform: LayerTransform(origin: .zero, size: CGSize(width: 64, height: 48)))
        session.addBlankLayer()
        let blank = try #require(session.activeLayerID)
        session.selectedLayerIDs = [a, blank]
        #expect(!session.canAutoAlignLayers)
        let b = try insert(image, "B", into: session, transform: LayerTransform(origin: .zero, size: CGSize(width: 64, height: 48)))
        session.selectedLayerIDs = [a, b, blank]
        let candidates = Set(session.autoAlignCandidates.map(\.id))
        #expect(candidates == [a, b])
    }
}
