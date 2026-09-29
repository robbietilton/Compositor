import AppKit
import SwiftUI
import Testing
@testable import Compositor

/// Option-click on a mask thumbnail shows the mask by itself on the canvas, as Photoshop does.
@MainActor
struct MaskAloneTests {
    /// A 200×100 red layer whose mask hides its right half.
    private func maskedSession() throws -> (EditorSession, UUID) {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        let pixels = try BrushRaster.context(width: 200, height: 100, mask: false)
        pixels.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        pixels.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(pixels.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform = LayerTransform(origin: .zero, size: CGSize(width: 200, height: 100))
        let mask = try BrushRaster.context(width: 200, height: 100, mask: true)
        mask.setFillColor(gray: 1, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        session.document?.layers[index].mask = LayerMask(asset: try LayerMask.asset(from: try #require(mask.makeImage())))
        return (session, id)
    }

    @Test func optionClickTogglesTheMaskViewAndTargetingPixelsEndsIt() throws {
        let (session, id) = try maskedSession()
        session.toggleMaskAlone(id)
        #expect(session.maskAloneLayer?.id == id && session.isMaskSelected)
        session.toggleMaskAlone(id)
        #expect(session.maskAloneLayer == nil && session.isMaskSelected)
        session.toggleMaskAlone(id)
        session.selectLayerTarget(id, mask: false)
        #expect(session.maskAloneLayer == nil && !session.viewsMaskAlone)
        session.toggleMaskAlone(id)
        session.deleteLayerMask()
        #expect(session.maskAloneLayer == nil)
        session.undo()
        #expect(session.maskAloneLayer == nil)
    }

    @Test func aLayerWithoutAMaskHasNothingToShow() throws {
        let (session, id) = try maskedSession()
        session.deleteLayerMask()
        session.toggleMaskAlone(id)
        #expect(session.maskAloneLayer == nil && !session.isMaskSelected)
    }

    @Test func theCanvasShowsTheMaskInGrayInsteadOfTheImage() throws {
        let (session, id) = try maskedSession()
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let size = CGSize(width: 200, height: 100)
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: size)
        session.viewport.setZoom(1, anchoredAt: session.viewport.center, documentSize: size)
        func color(at point: CGPoint) throws -> NSColor {
            view.synchronizeDisplay()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let perPoint = CGFloat(rep.pixelsWide) / view.bounds.width
            let at = session.viewport.viewPoint(from: point, documentSize: size)
            return try #require(rep.colorAt(x: Int(at.x * perPoint), y: Int(at.y * perPoint))?.usingColorSpace(.sRGB))
        }
        func red(_ color: NSColor) -> Bool { color.redComponent > 0.8 && color.blueComponent < 0.4 }
        #expect(red(try color(at: CGPoint(x: 50, y: 50))))   // The image.
        session.toggleMaskAlone(id)
        let revealed = try color(at: CGPoint(x: 50, y: 50)), hidden = try color(at: CGPoint(x: 150, y: 50))
        #expect(revealed.redComponent > 0.95 && revealed.greenComponent > 0.95 && revealed.blueComponent > 0.95)
        #expect(hidden.redComponent < 0.05 && hidden.greenComponent < 0.05 && hidden.blueComponent < 0.05)
        session.toggleMaskAlone(id)
        #expect(red(try color(at: CGPoint(x: 50, y: 50))))
    }
}

/// The badge over the canvas takes its own clicks: the canvas is an AppKit view, and SwiftUI drawn over it doesn't.
@MainActor
struct MaskAloneBadgeHitTests {
    @Test func clicksOnTheBadgeReachItNotTheCanvas() throws {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        session.addBlankLayer()
        session.addLayerMask()
        let id = try #require(session.activeLayerID)
        session.toggleMaskAlone(id)
        let layer = try #require(session.maskAloneLayer)
        let root = ZStack {
            EditorCanvas(session: session)
            MaskAloneBadge(session: session, layer: layer).fixedSize()
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let badge = try #require(all(host).first { $0 is MaskAloneBadgeView })
        let center = badge.convert(CGPoint(x: badge.bounds.midX, y: badge.bounds.midY), to: nil)
        let hit = try #require(window.contentView?.hitTest(center))
        #expect(hit.isDescendant(of: badge), "hit \(type(of: hit)); order \(host.subviews.map { "\(type(of: $0))" }); badge \(badge.frame)")
    }
}
