import CoreGraphics
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Compositor

/// Images coming into a project on iPad: from Photos, from other apps by drag and drop, and through the pasteboard.
@MainActor struct PadImportTests {
    /// A photo as a camera writes it: `width` × `height` pixels, the left half red and the right half blue, with EXIF
    /// saying how to turn it to show it upright.
    private func photo(width: Int, height: Int, orientation: CGImagePropertyOrientation) throws -> Data {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                                   [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// An item as Photos or another app hands one over: PNG data, under the name it suggests.
    private func photoItem(width: Int, height: Int, named name: String) throws -> NSItemProvider {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let png = data as Data
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(png, nil)
            return nil
        }
        provider.suggestedName = name
        return provider
    }

    /// A window with one tab holding a `width` × `height` project with a file, fitted to a canvas its size.
    private func window(width: Int, height: Int) async throws -> (EditorWindowController, EditorTab) {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let tab = try #require(window.activeTab)
        tab.session.viewport.resize(to: CGSize(width: width, height: height), backingScale: 1, documentSize: nil)
        tab.session.createNewProject(width: width, height: height)
        try await tab.createDocument(named: "PadImportTests \(UUID().uuidString)")
        return (window, tab)
    }

    private func close(_ tab: EditorTab) async {
        let url = tab.document?.fileURL
        await tab.close()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// The color at (`x`, `y`), counted from the image's top left. Read through a context that isn't flipped, as the
    /// editor's are, so its first row in memory is the image's top.
    private func color(of image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = y * context.bytesPerRow + x * 4
        return (data[index], data[index + 1], data[index + 2])
    }

    /// A portrait photo copied in Photos is stored sideways, with EXIF to turn it; pasted, it stands upright, as it
    /// shows everywhere else.
    @Test func aPhotoCopiedInAnotherAppPastesUpright() throws {
        // Turned a quarter clockwise to show: 40 × 20 stored, 20 × 40 seen, its left half on top.
        UIPasteboard.general.setData(try photo(width: 40, height: 20, orientation: .right), forPasteboardType: UTType.jpeg.identifier)
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        #expect(session.canPaste)
        session.paste()

        let image = try #require(session.activeLayer?.asset?.image)
        #expect(image.width == 20)
        #expect(image.height == 40)
        let top = try color(of: image, x: image.width / 2, y: image.height / 4)
        let bottom = try color(of: image, x: image.width / 2, y: image.height * 3 / 4)
        #expect(top.red > 200 && top.blue < 60)
        #expect(bottom.blue > 200 && bottom.red < 60)
    }

    /// Photos and other apps hand over image data under a name of the photo's own; the copy made for the importer
    /// keeps that name, without an extension doubled, and an item with no image in it is reported.
    @Test func itemsAreCopiedUnderTheNamesTheySuggest() async throws {
        let photo = try photoItem(width: 8, height: 6, named: "IMG_0042.PNG")
        let text = NSItemProvider(object: "Not an image" as NSString)
        let (urls, unreadable) = await ItemProviderFiles.urls(from: [photo, text], suggestedNames: true)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }

        #expect(urls.map { $0.deletingPathExtension().lastPathComponent } == ["IMG_0042"])
        #expect(urls.first?.pathExtension.lowercased() == "png")
        #expect(unreadable)
    }

    /// An image dropped on the canvas is centered where it lands, as on the Mac, and named as the dragged photo is.
    @Test func anImageDroppedOnTheCanvasIsCenteredWhereItLands() async throws {
        let (window, tab) = try await window(width: 400, height: 300)
        let dropped = CGPoint(x: 100, y: 80)
        let center = tab.session.viewport.documentPoint(from: dropped, documentSize: CGSize(width: 400, height: 300))
        await window.receive([try photoItem(width: 8, height: 6, named: "IMG_0042")], at: dropped)

        let layer = try #require(tab.session.activeLayer)
        #expect(layer.name == "IMG_0042")
        #expect(layer.origin == CGPoint(x: floor(center.x - 4), y: floor(center.y - 3)))
        #expect(layer.origin != CGPoint(x: 196, y: 147))
        #expect(tab.session.document?.layers.count == 2)
        await close(tab)
    }

    /// Into an empty tab, the first photo sets the canvas and the project gets a file named after it.
    @Test func anEmptyTabTakesItsCanvasFromThePhoto() async throws {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let tab = try #require(window.activeTab)
        #expect(tab.isEmpty)
        await window.receive([try photoItem(width: 8, height: 6, named: "PadImportTests \(UUID().uuidString)")])

        #expect(tab.session.document?.size == CGSize(width: 8, height: 6))
        #expect(tab.document != nil)
        #expect(tab.title.hasPrefix("PadImportTests"))
        await close(tab)
    }

    /// Copy with no selection takes the layer whole, and Paste brings back a copy of it above it, as on the Mac.
    @Test func aLayerCopiedWholePastesAsACopy() async throws {
        let (window, tab) = try await window(width: 40, height: 30)
        window.copy(nil)
        #expect(window.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        window.paste(nil)

        #expect(tab.session.document?.layers.map(\.name) == ["Layer 1", "Layer 1 copy"])
        #expect(tab.session.history.undoName == "Paste")
        await close(tab)
    }
}
