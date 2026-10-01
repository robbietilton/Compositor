import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// The tool rail's icons, as the Mac's rail has them.
@MainActor struct PadToolRailTests {
    /// Every tool has its icon, and so does each mode the Mac's rail shows its own icon for: the Marquee's Ellipse, the
    /// Eraser, the Polygonal Lasso and the Magic tool's Object mode. Where SF Symbols has nothing to match, it's the
    /// Mac's own.
    @Test func everyToolAndModeHasItsIcon() throws {
        let session = EditorSession()
        var icons: [NavigationTool: UIImage] = [:]
        for tool in NavigationTool.allCases where tool != .idle {
            icons[tool] = ToolRailView.image(for: tool, in: session)
            #expect(icons[tool] != nil, "\(tool)")
        }
        session.marqueeKind = .ellipse
        session.lassoKind = .polygonal
        session.wandMode = .object
        session.brushMode = .erase
        for tool in [NavigationTool.marquee, .lasso, .wand, .brush] {
            let mode = try #require(ToolRailView.image(for: tool, in: session), "\(tool)")
            #expect(mode.pngData() != icons[tool]?.pngData(), "\(tool)")
        }
        #expect(icons[.cloneStamp]?.isSymbolImage == false && icons[.gradient]?.isSymbolImage == false)
        #expect(ToolRailView.image(for: .lasso, in: session)?.isSymbolImage == false)
        #expect(ToolRailView.image(for: .wand, in: session)?.isSymbolImage == false)
        #expect(icons[.brush]?.isSymbolImage == true)
    }

    /// The stamp is the Mac's: a round handle over a wide pad, with nothing beside the handle.
    @Test func theStampIsTheMacs() throws {
        let image = try #require(ToolRailView.image(for: .cloneStamp, in: EditorSession()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 4
        let drawn = try #require(UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.withTintColor(.black).draw(at: .zero)
        }.cgImage)
        let context = try BrushRaster.copy(drawn)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Where in the stamp's square, as the Mac draws it.
        let side = image.size.width
        func ink(_ x: Double, _ y: Double) -> UInt8 {
            let px = Int(x * side * 4), py = Int(y * side * 4)
            return bytes[py * context.bytesPerRow + px * 4 + 3]
        }
        #expect(ink(0.5, 0.17) > 200, "handle")
        #expect(ink(0.5, 0.42) > 200, "neck")
        #expect(ink(0.15, 0.88) > 200 && ink(0.85, 0.88) > 200, "pad")
        #expect(ink(0.1, 0.1) < 30 && ink(0.9, 0.1) < 30, "beside the handle")
    }
}
