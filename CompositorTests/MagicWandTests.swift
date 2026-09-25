import AppKit
import Testing
@testable import Compositor

@MainActor
struct MagicWandTests {
    private let red: [UInt8] = [255, 0, 0, 255]
    private let blue: [UInt8] = [0, 0, 255, 255]

    /// Premultiplied RGBA pixels, top row first.
    private func image(width: Int, height: Int, _ color: (Int, Int) -> [UInt8]) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = color(x, y)
                for channel in 0..<4 { bytes[y * context.bytesPerRow + x * 4 + channel] = pixel[channel] }
            }
        }
        return try #require(context.makeImage())
    }
    /// Pixel indices (y × width + x) an outline covers.
    private func pixels(_ path: CGPath?, width: Int, height: Int) throws -> Set<Int> {
        guard let path else { return [] }
        let coverage = try DocumentSelection(path: path, antialiased: false).coverage(width: width, height: height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(coverage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Set((0..<(width * height)).filter { bytes[$0] >= 128 })
    }
    private func settings(tolerance: Int = 32, size: WandSampleSize = .point, contiguous: Bool = true) -> WandSettings {
        var settings = WandSettings()
        settings.tolerance = tolerance
        settings.sampleSize = size
        settings.contiguous = contiguous
        return settings
    }
    private func block(columns: Range<Int>, rows: Range<Int>, width: Int) -> Set<Int> {
        Set(rows.flatMap { y in columns.map { y * width + $0 } })
    }

    @Test func contiguousStopsAtOtherColorsWhileNonContiguousFindsEveryMatch() throws {
        let stripes = try image(width: 10, height: 4) { x, _ in x < 3 || x >= 6 ? red : blue }
        let left = block(columns: 0..<3, rows: 0..<4, width: 10)
        let right = block(columns: 6..<10, rows: 0..<4, width: 10)
        let connected = try MagicWand.select(in: stripes, at: CGPoint(x: 1.5, y: 2.5), settings: settings())
        #expect(try pixels(connected, width: 10, height: 4) == left)
        let everywhere = try MagicWand.select(in: stripes, at: CGPoint(x: 1.5, y: 2.5), settings: settings(contiguous: false))
        #expect(try pixels(everywhere, width: 10, height: 4) == left.union(right))
        // Rows stay the right way up: clicking the top row selects the top row.
        let banded = try image(width: 4, height: 3) { _, y in y == 0 ? red : blue }
        let top = try MagicWand.select(in: banded, at: CGPoint(x: 1, y: 0), settings: settings())
        #expect(try pixels(top, width: 4, height: 3) == [0, 1, 2, 3])
        #expect(try MagicWand.select(in: banded, at: CGPoint(x: 9, y: 0), settings: settings()) == nil)
    }

    @Test func toleranceAppliesToEveryChannelIncludingAlpha() throws {
        let columns: [[UInt8]] = [[100, 100, 100, 255], [132, 100, 100, 255], [133, 100, 100, 255], [100, 100, 100, 222]]
        let row = try image(width: 4, height: 1) { x, _ in columns[x] }
        func run(_ tolerance: Int) throws -> Set<Int> {
            try pixels(MagicWand.select(in: row, at: CGPoint(x: 0.5, y: 0.5),
                                        settings: settings(tolerance: tolerance, contiguous: false)), width: 4, height: 1)
        }
        #expect(try run(0) == [0])
        #expect(try run(32) == [0, 1])
        #expect(try run(33) == [0, 1, 2, 3])
    }

    @Test func sampleSizeAveragesThePixelsAroundTheClick() throws {
        let dot = try image(width: 5, height: 5) { x, y in x == 2 && y == 2 ? [255, 255, 255, 255] : [0, 0, 0, 255] }
        let center = CGPoint(x: 2.5, y: 2.5)
        let point = try MagicWand.select(in: dot, at: center, settings: settings(tolerance: 10, contiguous: false))
        #expect(try pixels(point, width: 5, height: 5) == [12])
        // A 3 × 3 average is gray 28: black is within 30 of it, the white center is not.
        let averaged = try MagicWand.select(in: dot, at: center, settings: settings(tolerance: 30, size: .threeByThree, contiguous: false))
        #expect(try pixels(averaged, width: 5, height: 5) == Set(0..<25).subtracting([12]))
    }

    @Test func outlinesReproduceTheirPixelsWithHolesAndCornerTouches() throws {
        let width = 8, height = 6
        var mask = [UInt8](repeating: 0, count: width * height)
        // A 3 × 3 ring around a hole, against the image's corner, and two pixels touching only diagonally.
        for y in 0..<3 { for x in 0..<3 where !(x == 1 && y == 1) { mask[y * width + x] = 255 } }
        mask[4 * width + 5] = 255
        mask[5 * width + 6] = 255
        let expected = Set(mask.indices.filter { mask[$0] != 0 })
        #expect(try pixels(MagicWand.outline(of: mask, width: width, height: height), width: width, height: height) == expected)
        #expect(try MagicWand.outline(of: [UInt8](repeating: 0, count: 4), width: 2, height: 2) == nil)
    }

    @Test func displayOutlineSimplifiesDetailedMasksInsteadOfUsingABoundingRectangle() throws {
        let width = 768, height = 768
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in 80..<688 {
            for x in 80..<688 {
                let dx = CGFloat(x - 384) / 304
                let dy = CGFloat(y - 384) / 260
                if dx * dx + dy * dy <= 1 && ((x + y) % 23 != 0 || x % 7 < 5) {
                    mask[y * width + x] = 255
                }
            }
        }

        let outline = try #require(try MagicWand.displayOutline(of: mask, width: width, height: height, maxDimension: 512))
        var elements = 0
        outline.applyWithBlock { _ in elements += 1 }
        #expect(elements > 5)
    }

    @Test func theWandReadsTheActiveLayerOrEveryVisibleLayerAndCombinesModes() async throws {
        let session = EditorSession()
        session.createDocument(width: 20, height: 10)
        let halves = try image(width: 20, height: 10) { x, _ in x < 10 ? red : blue }
        session.insert(ImportedImage(image: halves, thumbnail: halves, name: "Halves"))
        session.addBlankLayer()
        session.selectTool(.wand)
        let left = block(columns: 0..<10, rows: 0..<10, width: 20)
        func selected() throws -> Set<Int> { try pixels(session.selection?.path, width: 20, height: 10) }
        // The blank active layer is transparent everywhere, so the whole canvas matches.
        await session.magicWand(at: CGPoint(x: 2, y: 2), mode: .replace)
        #expect(try selected().count == 200)
        session.wandSettings.sampleAllLayers = true
        await session.magicWand(at: CGPoint(x: 2, y: 2), mode: .replace)
        #expect(try selected() == left)
        let count = session.history.undoCount
        await session.magicWand(at: CGPoint(x: 15, y: 5), mode: .add)
        #expect(try selected().count == 200)
        #expect(session.history.undoCount == count + 1)
        await session.magicWand(at: CGPoint(x: 2, y: 2), mode: .subtract)
        #expect(try selected() == Set(0..<200).subtracting(left))
        session.undo()
        #expect(try selected().count == 200)
    }

    @Test func clickingInsideASelectionMakesANewWandSelectionRatherThanDeselecting() async throws {
        let size = CGSize(width: 20, height: 10)
        let session = EditorSession()
        session.createDocument(width: 20, height: 10)
        let halves = try image(width: 20, height: 10) { x, _ in x < 10 ? red : blue }
        session.insert(ImportedImage(image: halves, thumbnail: halves, name: "Halves"))
        session.selectTool(.wand)
        session.wandSettings.sampleAllLayers = true
        session.selectAll()
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: size)
        let spot = session.viewport.viewPoint(from: CGPoint(x: 3.5, y: 5.5), documentSize: size)
        let location = NSPoint(x: spot.x, y: view.bounds.height - spot.y)
        func click(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try click(.leftMouseDown))
        view.mouseUp(with: try click(.leftMouseUp))
        let left = block(columns: 0..<10, rows: 0..<10, width: 20)
        for _ in 0..<100 {
            if try pixels(session.selection?.path, width: 20, height: 10) == left { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(session.selection != nil)
        #expect(try pixels(session.selection?.path, width: 20, height: 10) == left)
    }
}
