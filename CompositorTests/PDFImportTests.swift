import Foundation
import CoreGraphics
import PDFKit
import Testing
@testable import Compositor

@MainActor
struct PDFImportTests {
    /// A two-page PDF: a 200 × 100 point page with a red square in its top-left corner, then a 100 × 50 page turned a
    /// quarter, so it stands 50 × 100.
    func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 50, width: 50, height: 50))
        context.endPDFPage()
        var small = CGRect(x: 0, y: 0, width: 100, height: 50)
        let page = [kCGPDFContextMediaBox: Data(bytes: &small, count: MemoryLayout<CGRect>.size)] as CFDictionary
        context.beginPDFPage(page)
        context.endPDFPage()
        context.closePDF()
        // Turn the second page a quarter, as a scanned page often is.
        let document = try #require(PDFDocument(url: url))
        document.page(at: 1)?.rotation = 90
        #expect(document.write(to: url))
        return url
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return try #require(context.data).load(fromByteOffset: 3, as: UInt8.self)
    }

    @Test func everyPageIsALayerOnANewCanvasAt300DPI() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        #expect(session.importError == nil)
        let document = try #require(session.document)
        #expect(document.size == CGSize(width: 833, height: 417))
        #expect(document.resolution == 300)
        #expect(document.layers.map(\.name) == ["Page 2", "Page 1"])
        let first = try #require(document.layers.last?.asset?.image)
        let second = try #require(document.layers.first?.asset?.image)
        #expect(first.width == 833 && first.height == 417)
        // The quarter turn stands the second page upright.
        #expect(second.width == 208 && second.height == 417)
        // The square is drawn top-left, and the rest of the page stays see-through.
        #expect(try alpha(first, x: 40, y: 40) == 255)
        #expect(try alpha(first, x: 600, y: 300) == 0)
        #expect(session.activeLayerID == document.layers.last?.id)
    }

    @Test func intoACanvasEachPageIsFittedToIt() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.createDocument(width: 1000, height: 1000)
        await session.importImages([url])
        let document = try #require(session.document)
        #expect(document.size == CGSize(width: 1000, height: 1000))
        let first = try #require(document.layers.last?.asset?.image)
        let second = try #require(document.layers.first?.asset?.image)
        #expect(first.width == 1000 && first.height == 500)
        #expect(second.width == 500 && second.height == 1000)
        #expect(try alpha(first, x: 50, y: 50) == 255)
        #expect(try alpha(first, x: 300, y: 50) == 0)
    }

    @Test func aDamagedPDFIsReported() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        try Data("not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        #expect(session.document == nil)
        #expect(session.importError != nil)
    }
}
