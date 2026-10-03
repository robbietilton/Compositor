import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// Exporting on iPad: the Mac's Export JPEG dialog, and the project while it's open.
@MainActor struct PadExportTests {
    /// A 64 × 48 image, clear but for an opaque red quarter.
    private func raster() throws -> ExportRaster {
        let context = try BrushRaster.context(width: 64, height: 48, mask: false)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        return ExportRaster(image: try #require(context.makeImage()))
    }

    /// The color of `image` at (`x`, `y`) from its top left, in 0...255.
    private func color(of image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// The dialog starts at the quality last exported, in hundredths as the Mac's slider steps; Export hands over the JPEG
    /// encoded at the quality chosen, which the next export starts from.
    @Test func theDialogStartsAtTheQualityLastExported() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: JPEGExportController.qualityKey)
        defer { defaults.set(saved, forKey: JPEGExportController.qualityKey) }
        defaults.set(0.6, forKey: JPEGExportController.qualityKey)
        var exported: Data?
        let dialog = JPEGExportController(raster: try raster()) { exported = $0 }
        dialog.loadViewIfNeeded()
        #expect(dialog.options.quality == 0.6)

        dialog.chooseQuality(0.734)
        #expect(dialog.options.quality == 0.73)
        await dialog.encoding?.value
        dialog.export()
        let data = try #require(exported)
        #expect(data.starts(with: [0xFF, 0xD8]))
        #expect(defaults.double(forKey: JPEGExportController.qualityKey) == 0.73)
    }

    /// Nothing is exported before the preview is up to date with the settings, and Cancel hands over nothing.
    @Test func exportWaitsForThePreview() async throws {
        var finished: [Data?] = []
        let dialog = JPEGExportController(raster: try raster()) { finished.append($0) }
        dialog.loadViewIfNeeded()
        dialog.export()
        #expect(finished.isEmpty)
        await dialog.encoding?.value
        dialog.cancel()
        #expect(finished.count == 1 && finished[0] == nil)
    }

    /// The image's transparent areas take the color chosen for them.
    @Test func transparentAreasTakeTheColorChosen() async throws {
        let dialog = JPEGExportController(raster: try raster()) { _ in }
        dialog.loadViewIfNeeded()
        dialog.chooseMatte(UIColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        await dialog.encoding?.value

        let preview = try #require(dialog.result?.preview)
        let clear = color(of: preview, x: 48, y: 36)
        #expect(clear.blue > 240 && clear.red < 16 && clear.green < 16)
    }

    /// Export JPEG holds the project while its dialog is open, as on the Mac, so another export waits.
    @Test func theProjectWaitsForTheDialog() throws {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let session = try #require(window.activeTab?.session)
        session.createNewProject(width: 100, height: 100)
        #expect(window.canPerformAction(#selector(EditorWindowController.exportJPEG(_:)), withSender: nil))

        window.exportJPEG(nil)
        #expect(session.isProjectBusy)
        #expect(!window.canPerformAction(#selector(EditorWindowController.exportPNG(_:)), withSender: nil))
    }
}
