import Testing
import AppKit
@testable import Compositor

/// Feather softens the selection itself, so everything clipped by it fades at the edge.
@MainActor struct SelectionFeatherTests {
    @Test func featherAddsUpEachTimeItIsApplied() throws {
        let session = EditorSession()
        session.createDocument(width: 60, height: 20)
        session.selectAll()
        for _ in 0..<3 { session.modifySelection(.feather, by: 2) }
        #expect(try #require(session.selection).feather == 6)
        session.modifySelection(.feather, by: 500)
        #expect(try #require(session.selection).feather == 250, "feather has a limit of 250 pixels")
    }

    @Test func theStatusBarsFeatherFollowsTheSelection() throws {
        let session = EditorSession()
        session.createDocument(width: 60, height: 20)
        #expect(session.selectionFeather == nil)
        session.selectAll()
        #expect(session.selectionFeather == nil, "a hard edge has no feather to show")
        for _ in 0..<2 { session.modifySelection(.feather, by: 3) }
        #expect(session.selectionFeather == 6)
        session.undo()
        #expect(session.selectionFeather == 3)
        session.deselect()
        #expect(session.selectionFeather == nil)
    }

    @Test func featherSoftensTheSelectionAndWhatItClips() async throws {
        let session = EditorSession()
        session.createDocument(width: 60, height: 20)
        session.addBlankLayer()
        session.selectAll()
        session.featherSelection(by: 6)
        let selection = try #require(session.selection)
        #expect(session.canModifySelection, "the selection cannot be modified")
        #expect(selection.feather > 0, "featherSelection left the selection hard-edged")
        // Coverage across a vertical edge of the selection, to see whether it fades.
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 20, y: 0, width: 20, height: 20), transform: nil),
                                               antialiased: true, feather: 6), name: "probe")
        let clip = try #require(try session.selection?.clip(canvas: CGSize(width: 60, height: 20)))
        let coverage = try #require(clip.coverage)
        let context = try #require(CGContext(data: nil, width: coverage.width, height: coverage.height, bitsPerComponent: 8,
                                             bytesPerRow: coverage.width, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(coverage, in: CGRect(x: 0, y: 0, width: coverage.width, height: coverage.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let row = coverage.height / 2
        let values = (0..<coverage.width).map { Int(bytes[row * coverage.width + $0]) }
        let fading = values.filter { $0 > 8 && $0 < 247 }
        #expect(fading.count >= 4, "the clip has no soft edge: \(values)")

        // End to end: fill the feathered selection and look across its edge on the layer itself.
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        await session.fillSelection(with: .foreground)
        let layer = try #require(session.activeLayer)
        let filled = try #require(layer.asset?.image)
        let pixels = try #require(CGContext(data: nil, width: filled.width, height: filled.height, bitsPerComponent: 8,
                                            bytesPerRow: filled.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        pixels.draw(filled, in: CGRect(x: 0, y: 0, width: filled.width, height: filled.height))
        let bytes2 = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        let middle = filled.height / 2
        let alphas = (0..<filled.width).map { Int(bytes2[(middle * filled.width + $0) * 4 + 3]) }
        let soft = alphas.filter { $0 > 8 && $0 < 247 }
        #expect(soft.count >= 4, "the fill has a hard edge: \(alphas)")
    }
}
