import AppKit
import Testing
@testable import Compositor

/// Photoshop files with artboards open as one document per artboard, each in a tab of its own.
@MainActor
struct PSDArtboardTests {
    private func colorImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// An `artb` block as Photoshop writes it: a versioned descriptor holding the artboard's rectangle.
    private func artboardBlock(_ rect: CGRect) -> Data {
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        func key(_ text: String) {
            if text.count == 4 { u32(0) } else { u32(UInt32(text.count)) }
            data.append(contentsOf: Array(text.utf8))
        }
        func double(_ value: Double) { withUnsafeBytes(of: value.bitPattern.bigEndian) { data.append(contentsOf: $0) } }
        u32(16)
        u32(0); key("null"); u32(1)
        key("artboardRect"); data.append(contentsOf: Array("Objc".utf8))
        u32(0); key("classFloatRect"); u32(4)
        for (name, value) in [("Top ", rect.minY), ("Left", rect.minX), ("Btom", rect.maxY), ("Rght", rect.maxX)] {
            key(name); data.append(contentsOf: Array("doub".utf8)); double(Double(value))
        }
        return data
    }

    /// Two artboards side by side on a 200 × 100 canvas, a layer in each, and one on the canvas outside both.
    private func file() throws -> URL {
        let left = UUID(), right = UUID()
        var leftBoard = PSDRecord(id: left, name: "Phone")
        leftBoard.isGroup = true
        var rightBoard = PSDRecord(id: right, name: "Tablet")
        rightBoard.isGroup = true
        var red = PSDRecord(id: UUID(), parentID: left, name: "Red")
        red.bounds = CGRect(x: 10, y: 20, width: 30, height: 40)
        red.image = try colorImage(width: 30, height: 40, red: 1, green: 0, blue: 0)
        var blue = PSDRecord(id: UUID(), parentID: right, name: "Blue")
        blue.bounds = CGRect(x: 130, y: 10, width: 20, height: 20)
        blue.image = try colorImage(width: 20, height: 20, red: 0, green: 0, blue: 1)
        var loose = PSDRecord(id: UUID(), name: "Loose")
        loose.bounds = CGRect(x: 0, y: 90, width: 10, height: 10)
        loose.image = try colorImage(width: 10, height: 10, red: 0, green: 1, blue: 0)
        let document = PSDDocument(width: 200, height: 100, resolution: 72, layers: [loose, leftBoard, red, rightBoard, blue])
        let data = try PSDFixture.data(document, composite: try colorImage(width: 200, height: 100, red: 1, green: 1, blue: 1),
                                       extras: [left: ["artb": artboardBlock(CGRect(x: 0, y: 0, width: 80, height: 60))],
                                                right: ["artb": artboardBlock(CGRect(x: 120, y: 0, width: 60, height: 50))]])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Artboards-\(UUID()).psd")
        try data.write(to: url)
        return url
    }

    @Test func eachArtboardOpensAsADocumentInATabOfItsOwn() async throws {
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try PSDReader.read(from: url)
        let boards = try #require(parsed.artboards())
        // In the file's order: Phone, then Tablet above it.
        #expect(boards.map(\.name) == ["Phone", "Tablet"])

        let workspace = ProjectWorkspace()
        await workspace.current.session.importImages([url])
        #expect(workspace.tabs.count == 2)
        let phone = try #require(workspace.tabs.first?.session.document)
        let tablet = try #require(workspace.tabs.last?.session.document)
        #expect(workspace.tabs.map(\.title) == ["Phone", "Tablet"])
        #expect(tablet.size == CGSize(width: 60, height: 50) && phone.size == CGSize(width: 80, height: 60))
        // Each layer where it sat on its artboard, with no artboard folder around it, and the loose layer in neither.
        #expect(phone.layers.map(\.name) == ["Red"] && phone.layers[0].origin == CGPoint(x: 10, y: 20))
        #expect(tablet.layers.map(\.name) == ["Blue"] && tablet.layers[0].origin == CGPoint(x: 10, y: 10))
    }

    @Test func aFileWithoutArtboardsStillOpensAsOneCanvas() async throws {
        var layer = PSDRecord(id: UUID(), name: "Only")
        layer.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        layer.image = try colorImage(width: 4, height: 4, red: 1, green: 0, blue: 0)
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 4, resolution: 72, layers: [layer]),
                                       composite: try colorImage(width: 4, height: 4, red: 1, green: 0, blue: 0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Plain-\(UUID()).psd")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try PSDReader.read(from: url).artboards() == nil)
        let workspace = ProjectWorkspace()
        await workspace.current.session.importImages([url])
        #expect(workspace.tabs.count == 1 && workspace.current.session.document?.layers.map(\.name) == ["Only"])
    }
}
