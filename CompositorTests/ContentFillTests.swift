import AppKit
import Testing
@testable import Compositor

/// Content-Aware Fill on made-up layers whose hidden content is known, run as the app runs it: begin, the preview
/// (where the fill is made), then OK. Each layer is drawn from a seeded hash, so the tests read the same everywhere.
@MainActor struct ContentFillTests {
    /// A layer's pixels, top row first, 4 bytes each. Opaque, so premultiplied and plain are the same.
    struct Raster {
        let width: Int, height: Int
        var bytes: [UInt8]

        init(width: Int, height: Int, color: (Int, Int) -> (Double, Double, Double)) {
            self.width = width; self.height = height
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
            for y in 0..<height { for x in 0..<width {
                let (r, g, b) = color(x, y), i = (y * width + x) * 4
                bytes[i] = byte(r); bytes[i + 1] = byte(g); bytes[i + 2] = byte(b)
            } }
            self.bytes = bytes
        }
        init(_ image: CGImage) throws {
            let width = image.width, height = image.height
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
            let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            self.width = width; self.height = height
            bytes = (0..<height).flatMap { y in Array(UnsafeBufferPointer(start: data + y * context.bytesPerRow, count: width * 4)) }
        }
        func image() throws -> CGImage {
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            bytes.withUnsafeBufferPointer { source in
                for y in 0..<height { (data + y * context.bytesPerRow).update(from: source.baseAddress! + y * width * 4, count: width * 4) }
            }
            return try #require(context.makeImage())
        }
        func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let i = (y * width + x) * 4
            return (Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2]))
        }
        func luma(_ x: Int, _ y: Int) -> Double {
            let p = pixel(x, y)
            return 0.299 * p.r + 0.587 * p.g + 0.114 * p.b
        }
    }

    /// The selection: an ellipse turned `degrees` about its center (clockwise, the y axis pointing down).
    struct Ellipse {
        let cx: Double, cy: Double, a: Double, b: Double, degrees: Double
        var path: CGPath {
            var turn = CGAffineTransform(translationX: cx, y: cy).rotated(by: degrees * .pi / 180).translatedBy(x: -cx, y: -cy)
            return CGPath(ellipseIn: CGRect(x: cx - a, y: cy - b, width: 2 * a, height: 2 * b), transform: &turn)
        }
        /// Pixels whose centers lie inside: the hole as the tests measure it. The fill covers a little more, its
        /// antialiased edge blended with what was there.
        func contains(_ x: Int, _ y: Int) -> Bool {
            let t = degrees * .pi / 180, dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
            let u = (dx * cos(t) + dy * sin(t)) / a, v = (-dx * sin(t) + dy * cos(t)) / b
            return u * u + v * v <= 1
        }
    }

    static func hash(_ x: Int, _ y: Int, _ seed: UInt32) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: x) &* 374_761_393 &+ UInt32(truncatingIfNeeded: y) &* 668_265_263 &+ seed &* 2_246_822_519
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return h ^ (h >> 16)
    }
    static func unit(_ x: Int, _ y: Int, _ seed: UInt32) -> Double { Double(hash(x, y, seed) >> 8) / 8_388_607.5 - 1 }
    /// Grain in about −1...1: half white noise, half value noise on a 3-pixel grid.
    static func grain(_ x: Int, _ y: Int, _ seed: UInt32) -> Double {
        let gx = x / 3, gy = y / 3, fx = Double(x % 3) / 3, fy = Double(y % 3) / 3
        let a = unit(gx, gy, seed + 1), b = unit(gx + 1, gy, seed + 1), c = unit(gx, gy + 1, seed + 1), d = unit(gx + 1, gy + 1, seed + 1)
        return 0.5 * unit(x, y, seed) + 0.5 * ((a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy)
    }

    /// What a test measured, kept with its result.
    func report(_ text: String) {
        Attachment.record(text, named: "measured.txt")
    }

    /// A session holding `image` as its one layer, with `selection` selected.
    func session(_ image: CGImage, selecting selection: CGPath) -> EditorSession {
        let s = EditorSession()
        s.createDocument(width: image.width, height: image.height)
        s.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        s.applySelection(selection, mode: .replace, name: "Select")
        return s
    }

    /// Content-Aware Fill as the menu item runs it, and the layer's pixels after OK.
    func fill(_ s: EditorSession) async throws -> Raster {
        let count = s.history.undoCount
        s.beginFilter(.contentAwareFill)
        await s.filterEdit?.previewTask?.value
        #expect(s.filterEdit?.previewError == nil)
        await s.commitFilter()
        #expect(s.filterEdit == nil && s.history.undoCount == count + 1)
        return try Raster(try #require(s.activeLayer?.asset?.image))
    }

    /// How far each pixel of the hole lies from the nearest pixel outside it: a chamfer, a pass down and a pass up.
    static func depth(of hole: [Bool], width: Int, height: Int) -> [Double] {
        var d = hole.map { $0 ? Double.infinity : 0 }
        let diagonal = 2.0.squareRoot()
        for y in 0..<height { for x in 0..<width where hole[y * width + x] {
            let i = y * width + x
            if x > 0 { d[i] = min(d[i], d[i - 1] + 1) }
            if y > 0 { d[i] = min(d[i], d[i - width] + 1) }
            if x > 0, y > 0 { d[i] = min(d[i], d[i - width - 1] + diagonal) }
            if x + 1 < width, y > 0 { d[i] = min(d[i], d[i - width + 1] + diagonal) }
        } }
        for y in stride(from: height - 1, through: 0, by: -1) { for x in stride(from: width - 1, through: 0, by: -1) where hole[y * width + x] {
            let i = y * width + x
            if x + 1 < width { d[i] = min(d[i], d[i + 1] + 1) }
            if y + 1 < height { d[i] = min(d[i], d[i + width] + 1) }
            if x + 1 < width, y + 1 < height { d[i] = min(d[i], d[i + width + 1] + diagonal) }
            if x > 0, y + 1 < height { d[i] = min(d[i], d[i + width - 1] + diagonal) }
        } }
        return d
    }

    /// A 12-megapixel layer of striped grain, drawn with Core Graphics: per pixel, it would take longer to make than
    /// the fill takes to run.
    static func largeLayer() throws -> CGImage {
        let width = 4000, height = 3000
        let tile = Raster(width: 256, height: 256) { x, y in
            let v = 120 + 30 * grain(x, y, 3)
            return (v, v * 0.98, v * 0.95)
        }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.draw(try tile.image(), in: CGRect(x: 0, y: 0, width: 256, height: 256), byTiling: true)
        context.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.84, blue: 0.8, alpha: 0.5))
        context.setLineWidth(8)
        for k in stride(from: -height, to: width + height, by: 48) {
            context.move(to: CGPoint(x: k, y: 0))
            context.addLine(to: CGPoint(x: k + height, y: height))
        }
        context.strokePath()
        return try #require(context.makeImage())
    }
    static let largeHole = Ellipse(cx: 2000, cy: 1500, a: 700, b: 550, degrees: 20)

    /// The fill used to go pixel by pixel on one thread, every pixel trying candidates from the whole layer: about
    /// 9 s for this hole of 1.2 million pixels on an M1 Max, and 20 s or more as tests run there, with code coverage
    /// on. Matched coarse to fine on all cores, the fill takes about 0.3 s there (2 s on one core), the preview's work
    /// about 0.5 s as tests run. The bound leaves room for a CI machine with three cores and other tests running
    /// beside, and is still a fraction of the old fill's time on any machine.
    @Test func fillsTwelveMegapixelsQuickly() async throws {
        let image = try Self.largeLayer()
        let s = session(image, selecting: Self.largeHole.path)
        s.beginFilter(.contentAwareFill)
        let job = try #require(s.filterEdit?.previewJob)
        await s.filterEdit?.previewTask?.value
        #expect(s.filterEdit?.previewError == nil)
        await s.commitFilter()
        #expect(s.activeLayer?.asset?.image !== image)
        // The preview's work again, timed where the preview runs it: off the main actor, which other tests running
        // at the same time can hold for many seconds.
        let elapsed = try await Task.detached(priority: .userInitiated) {
            let start = ContinuousClock.now
            _ = try PixelFilter.run(job)
            return ContinuousClock.now - start
        }.value
        report("12 MP layer, 1.2 MP hole: \(elapsed)")
        #expect(elapsed < .seconds(5), "Took \(elapsed)")
    }

    /// Light falling off across the layer: the fill's tone near its edge matches what it hides, all the way round,
    /// and keeps changing across the hole as the light does, to within a few levels where the light spans 150.
    @Test func fillKeepsTheLightAcrossTheHole() async throws {
        let width = 640, height = 480
        let truth = Raster(width: width, height: height) { x, y in
            let light = 50 + 150 * Double(x) / Double(width - 1), v = light * (1 + 0.3 * Self.grain(x, y, 7))
            return (v, v * 0.97, v * 0.92)
        }
        let hole = Ellipse(cx: 320, cy: 240, a: 190, b: 130, degrees: 0)
        let result = try await fill(session(try truth.image(), selecting: hole.path))
        let inside = (0..<width * height).map { hole.contains($0 % width, $0 / width) }
        let depth = Self.depth(of: inside, width: width, height: height)
        // Within 24 px of the edge, in eight sectors around the center; deeper, in columns 40 px wide.
        var sectors = [(fill: Double, truth: Double, count: Double)](repeating: (0, 0, 0), count: 8)
        var columns = [(fill: Double, truth: Double, count: Double)](repeating: (0, 0, 0), count: width / 40)
        for y in 0..<height { for x in 0..<width where inside[y * width + x] {
            let f = result.luma(x, y), t = truth.luma(x, y)
            if depth[y * width + x] <= 24 {
                let angle = atan2(Double(y) + 0.5 - hole.cy, Double(x) + 0.5 - hole.cx)
                let k = Int((angle + .pi) / (2 * .pi) * 8) % 8
                sectors[k].fill += f; sectors[k].truth += t; sectors[k].count += 1
            } else {
                columns[x / 40].fill += f; columns[x / 40].truth += t; columns[x / 40].count += 1
            }
        } }
        let edge = sectors.map { ($0.fill - $0.truth) / $0.count }
        let across = columns.filter { $0.count >= 1000 }.map { ($0.fill - $0.truth) / $0.count }
        let format = { (values: [Double]) in values.map { String(format: "%+.1f", $0) }.joined(separator: " ") }
        report("Fill less hidden truth: edge \(format(edge)); across \(format(across))")
        #expect(edge.allSatisfy { abs($0) <= 2.5 }, "Edge sectors off by \(format(edge))")
        #expect(across.allSatisfy { abs($0) <= 4 }, "Columns across the hole off by \(format(across))")
    }

    /// Noisy stripes 40 px apart at 30°, the hole across many of them: the fill carries them on where they were, so
    /// it correlates with the hidden stripes as the layer itself does, deep inside the hole as well as at its edge.
    @Test func fillContinuesStripes() async throws {
        let width = 800, height = 600, period = 40.0, thickness = 7.0, angle = 30 * Double.pi / 180
        func stripe(_ x: Int, _ y: Int) -> Double {
            let u = (Double(x) + 0.5) * cos(angle) + (Double(y) + 0.5) * sin(angle)
            let phase = u - (u / period).rounded(.down) * period
            if phase < thickness { return 1 }
            if phase < thickness + 1 { return thickness + 1 - phase }
            return phase >= period - 1 ? phase - (period - 1) : 0
        }
        let truth = Raster(width: width, height: height) { x, y in
            let v = 95 + 95 * stripe(x, y) + 22 * Self.grain(x, y, 11)
            return (v, v, v * 0.96)
        }
        let hole = Ellipse(cx: 400, cy: 300, a: 250, b: 120, degrees: -35)
        let result = try await fill(session(try truth.image(), selecting: hole.path))
        let inside = (0..<width * height).map { hole.contains($0 % width, $0 / width) }
        let depth = Self.depth(of: inside, width: width, height: height)
        func correlation(_ image: Raster, deeperThan limit: Double) -> Double {
            var pairs: [(Double, Double)] = []
            for y in 0..<height { for x in 0..<width where inside[y * width + x] && depth[y * width + x] > limit {
                pairs.append((image.luma(x, y), stripe(x, y)))
            } }
            let n = Double(pairs.count), ma = pairs.map(\.0).reduce(0, +) / n, mb = pairs.map(\.1).reduce(0, +) / n
            var ab = 0.0, aa = 0.0, bb = 0.0
            for (a, b) in pairs { ab += (a - ma) * (b - mb); aa += (a - ma) * (a - ma); bb += (b - mb) * (b - mb) }
            return ab / (aa * bb).squareRoot()
        }
        let whole = correlation(result, deeperThan: 0), core = correlation(result, deeperThan: 24)
        let own = correlation(truth, deeperThan: 0)
        report(String(format: "Correlation %.3f, %.3f deeper than 24 px; the layer's own %.3f", whole, core, own))
        #expect(whole >= 0.85 && core >= 0.85, "Correlation \(whole), \(core) deep inside, against the layer's own \(own)")
    }

    /// Gray grain, with an orange disc a few pixels beside the hole and an orange band along the layer's foot, as a
    /// dog lies elsewhere in a photo: none of either comes into the fill, nor does the disc tint the gray next to it.
    @Test func fillTakesNothingFromObjectsAround() async throws {
        let width = 640, height = 480, gap = 6.0, radius = 70.0
        let hole = Ellipse(cx: 300, cy: 240, a: 150, b: 100, degrees: 0)
        let ox = hole.cx + hole.a + gap + radius, oy = hole.cy
        func isOrange(_ x: Int, _ y: Int) -> Bool {
            let dx = Double(x) + 0.5 - ox, dy = Double(y) + 0.5 - oy
            return dx * dx + dy * dy <= radius * radius || y >= height - 60
        }
        let truth = Raster(width: width, height: height) { x, y in
            let g = Self.grain(x, y, 5)
            if isOrange(x, y) { return (225 + 20 * g, 120 + 20 * g, 45 + 15 * g) }
            return (128 + 40 * g, 128 + 40 * g, 128 + 40 * g)
        }
        let result = try await fill(session(try truth.image(), selecting: hole.path))
        var orange = 0, warmth = 0.0, near = 0
        for y in 0..<height { for x in 0..<width where hole.contains(x, y) {
            let p = result.pixel(x, y)
            if p.r - p.b > 40 { orange += 1 }
            let dx = Double(x) + 0.5 - ox, dy = Double(y) + 0.5 - oy
            if (dx * dx + dy * dy).squareRoot() <= radius + 40 { warmth += p.r - p.b; near += 1 }
        } }
        report("\(orange) orange pixels; red less blue near the disc \(warmth / Double(near))")
        #expect(orange == 0, "\(orange) orange pixels in the fill")
        #expect(abs(warmth / Double(near)) <= 3, "Red less blue \(warmth / Double(near)) near the disc, where the layer is gray")
    }
}
