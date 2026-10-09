import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// The iPad's checkboxes, in the tool options bars and the dialogs: a square checkbox before the title, on a rounded
/// rectangle in the tint while on, whose corners share a center with the box's; the same size on or off, so nothing
/// moves. The Transform bar's lock, a symbol alone, stays as it was.
@MainActor struct PadCheckboxTests {
    /// What the checkboxes are drawn over, as dark as a bar.
    private static let background = UIColor(white: 0.14, alpha: 1)

    /// A window on the app's screen, dark as the app's are unless asked otherwise, to draw in; at `scale` pixels to the
    /// point when one is given, so a checkbox draws its box that finely.
    private func window(_ style: UIUserInterfaceStyle = .dark, scale: CGFloat? = nil) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1200, height: 200)
        window.overrideUserInterfaceStyle = style
        if let scale { window.traitOverrides.displayScale = scale }
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = Self.background
        window.makeKeyAndVisible()
        return window
    }

    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// A checkbox titled `title` in `window`, alone there, on or off and as enabled as asked, at its own size.
    private func checkbox(_ title: String = "Auto Select", on: Bool, enabled: Bool = true, in window: UIWindow) -> UIButton {
        let box = OptionControls.checkbox(title) { _ in }
        box.isSelected = on
        box.isEnabled = enabled
        window.rootViewController?.view.subviews.forEach { $0.removeFromSuperview() }
        window.rootViewController?.view.addSubview(box)
        box.frame = CGRect(origin: CGPoint(x: 20, y: 20), size: box.intrinsicContentSize)
        box.layoutIfNeeded()
        return box
    }

    /// An image's pixels, as 8-bit sRGB, premultiplied.
    private struct Pixels {
        let bytes: [UInt8]
        let width: Int, height: Int
        /// Pixels to a point.
        let scale: CGFloat

        init(_ image: CGImage, scale: CGFloat) {
            width = image.width
            height = image.height
            self.scale = scale
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytes = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        }

        /// Red, green, blue and alpha of the pixel at `x`, `y`, counted in pixels from the top left.
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let index = (y * width + x) * 4
            return bytes[index..<index + 4].map(Int.init)
        }

        /// The pixel at `point`, in points.
        func color(at point: CGPoint) -> [Int] { pixel(Int(point.x * scale), Int(point.y * scale)) }

        /// The bounds, in points, of the pixels at least half covered.
        var ink: CGRect {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where pixel(x, y)[3] > 127 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale,
                          height: CGFloat(maxY - minY + 1) / scale)
        }

        /// How much of what `coverage` reads from a pixel is at `point`, in points, blended from the four nearest
        /// pixels; none past the image's edges.
        func sample(_ point: CGPoint, _ coverage: ([Int]) -> CGFloat) -> CGFloat {
            let x = point.x * scale - 0.5, y = point.y * scale - 0.5
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let ax = x - CGFloat(x0), ay = y - CGFloat(y0)
            func at(_ x: Int, _ y: Int) -> CGFloat {
                (0..<width).contains(x) && (0..<height).contains(y) ? coverage(pixel(x, y)) : 0
            }
            return at(x0, y0) * (1 - ax) * (1 - ay) + at(x0 + 1, y0) * ax * (1 - ay) + at(x0, y0 + 1) * (1 - ax) * ay
                + at(x0 + 1, y0 + 1) * ax * ay
        }

        /// Where, going from `start` to `end` in points, `coverage` first reaches a half: the edge of what it reads.
        func edge(from start: CGPoint, to end: CGPoint, _ coverage: ([Int]) -> CGFloat) -> CGPoint? {
            let steps = Int(hypot(end.x - start.x, end.y - start.y) * scale * 16)
            func point(_ t: CGFloat) -> CGPoint { CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t) }
            var previous = sample(start, coverage)
            for step in 1...max(steps, 1) {
                let t = CGFloat(step) / CGFloat(steps), value = sample(point(t), coverage)
                if previous < 0.5, value >= 0.5 {
                    return point(t - (value - 0.5) / (value - previous) / CGFloat(steps))
                }
                previous = value
            }
            return nil
        }
    }

    /// `view` as it's drawn in its window, over what's behind it, at `scale` pixels to the point.
    private func pixels(of view: UIView, scale: CGFloat = 2) throws -> Pixels {
        let root = try #require(view.window?.rootViewController?.view)
        let frame = view.convert(view.bounds, to: root)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { _ in
            root.drawHierarchy(in: CGRect(origin: CGPoint(x: -frame.minX, y: -frame.minY), size: root.bounds.size), afterScreenUpdates: true)
        }
        return Pixels(try #require(image.cgImage), scale: scale)
    }

    /// `image`'s pixels, at its own scale.
    private func pixels(of image: UIImage?) throws -> Pixels {
        let image = try #require(image)
        return Pixels(try #require(image.cgImage), scale: image.scale)
    }

    /// Red, green, blue and alpha of `color` as `view` shows it, 0 to 255.
    private func components(_ color: UIColor, in view: UIView) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: view.traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map { $0 * 255 }
    }

    /// `components` as a premultiplied pixel holds them: red, green and blue times alpha.
    private func premultiplied(_ components: [CGFloat]) -> [CGFloat] {
        components.prefix(3).map { $0 * components[3] / 255 } + [components[3]]
    }

    /// Whether `pixel`'s red, green and blue are each within `tolerance` of `expected`'s.
    private func matches(_ pixel: [Int], _ expected: [CGFloat], within tolerance: CGFloat = 3) -> Bool {
        zip(pixel.prefix(3), expected.prefix(3)).allSatisfy { abs(CGFloat($0) - $1) <= tolerance }
    }

    /// The pixels of `drawn` that aren't one color, `color`, as far as each covers: premultiplied, a pixel's red, green
    /// and blue are the color's times its alpha. Those barely covered are left out, rounded too far to tell.
    private func offColor(_ drawn: Pixels, _ color: [CGFloat]) -> [[Int]] {
        (0..<drawn.height).flatMap { y in (0..<drawn.width).map { drawn.pixel($0, y) } }.filter { pixel in
            pixel[3] >= 32 && !matches(pixel, color.prefix(3).map { $0 * CGFloat(pixel[3]) / 255 })
        }
    }

    /// How much of the middle of a drawn box, 4 to 16 points in, is clear: the check cut out of a filled box, or all of
    /// an outline's inside.
    private func cutOut(of drawn: Pixels) -> Double {
        let inside = (0..<drawn.height).flatMap { y in (0..<drawn.width).map { x in (x, y) } }.filter { x, y in
            let point = CGPoint(x: (CGFloat(x) + 0.5) / drawn.scale, y: (CGFloat(y) + 0.5) / drawn.scale)
            return (4..<16).contains(point.x) && (4..<16).contains(point.y)
        }
        return Double(inside.filter { drawn.pixel($0.0, $0.1)[3] < 8 }.count) / Double(inside.count)
    }

    /// How far into a pixel blended from `behind` toward `ahead` it has gone, read in the channel where they differ
    /// most.
    private func coverage(from behind: [CGFloat], to ahead: [CGFloat]) -> ([Int]) -> CGFloat {
        let channel = (0..<3).max { abs(ahead[$0] - behind[$0]) < abs(ahead[$1] - behind[$1]) }!
        return { (CGFloat($0[channel]) - behind[channel]) / (ahead[channel] - behind[channel]) }
    }

    /// A drawn rounded corner, measured: its radius, as the circle through where it crosses the diagonal from the
    /// corner of its straight edges, and the center that circle would have. `corner` is the outside corner of the
    /// straight edges' lines, in points, `across` how far along them to look.
    private struct Corner {
        let radius: CGFloat
        let center: CGPoint

        init?(in pixels: Pixels, corner: CGPoint, across: CGFloat, _ coverage: @escaping ([Int]) -> CGFloat) {
            // The straight edges, halfway along, from outside.
            guard let left = pixels.edge(from: CGPoint(x: corner.x - 1, y: corner.y + across), to: CGPoint(x: corner.x + across, y: corner.y + across), coverage),
                  let top = pixels.edge(from: CGPoint(x: corner.x + across, y: corner.y - 1), to: CGPoint(x: corner.x + across, y: corner.y + across), coverage),
                  let diagonal = pixels.edge(from: CGPoint(x: left.x, y: top.y), to: CGPoint(x: left.x + across, y: top.y + across), coverage)
            else { return nil }
            radius = (diagonal.x - left.x + diagonal.y - top.y) / 2 / (1 - 1 / 2.0.squareRoot())
            center = CGPoint(x: left.x + radius, y: top.y + radius)
        }
    }

    /// How far the edge `coverage` reads lies from `center`, every 5° round the top-left quarter, coming in from
    /// `reach` away.
    private func distances(in pixels: Pixels, from center: CGPoint, reach: CGFloat, _ coverage: @escaping ([Int]) -> CGFloat) -> [CGFloat?] {
        stride(from: 0.0, through: 90.0, by: 5.0).map { degrees in
            let angle = degrees * .pi / 180
            let outside = CGPoint(x: center.x - cos(angle) * reach, y: center.y - sin(angle) * reach)
            return pixels.edge(from: outside, to: center, coverage).map { hypot($0.x - center.x, $0.y - center.y) }
        }
    }

    /// A checked checkbox stands on a rounded rectangle in the tint at a quarter over what's behind, its corners rounded
    /// by the box's and the box's distance in from its top and left; an unchecked one has none, and nor does a checked
    /// one that can't be changed.
    @Test func aCheckedCheckboxStandsOnARoundedRectInTheTint() throws {
        let window = try window(scale: 8)
        defer { window.isHidden = true }
        let behind = components(Self.background, in: window)
        let on = checkbox(on: true, in: window)
        let tint = components(on.tintColor, in: on)
        let highlight = zip(behind, tint).map { $0 * 0.75 + $1 * 0.25 }
        // Past the title, at the highlight's end.
        let end = CGPoint(x: on.bounds.maxX - 5, y: on.bounds.midY)
        let drawn = try pixels(of: on, scale: 8)
        #expect(matches(drawn.color(at: end), highlight), "\(drawn.color(at: end)) for \(highlight)")
        let box = try #require(on.imageView)
        let symbol = try pixels(of: on.configuration?.image)
        let inner = try #require(Corner(in: symbol, corner: .zero, across: box.bounds.width / 2) { CGFloat($0[3]) / 255 })
        let outer = try #require(Corner(in: drawn, corner: .zero, across: on.bounds.height / 2, coverage(from: behind, to: highlight)))
        #expect(abs(outer.radius - (inner.radius + box.frame.minY)) < 0.25, "R \(outer.radius), r \(inner.radius), p \(box.frame.minY)")

        for (checked, enabled) in [(false, true), (true, false)] {
            let box = checkbox(on: checked, enabled: enabled, in: window)
            let plain = try pixels(of: box)
            #expect(matches(plain.color(at: CGPoint(x: box.bounds.maxX - 5, y: box.bounds.midY)), behind), "on \(checked)")
            #expect(matches(plain.color(at: CGPoint(x: 12, y: 1)), behind), "on \(checked)")
        }
    }

    /// The box, 20 square, is as far in from the highlight's top and left as the highlight's corners are rounder than
    /// its own, so the two share a center; the title starts 9 after it and ends 12 before the highlight does.
    @Test func theBoxIsConcentricWithItsHighlight() throws {
        let window = try window()
        defer { window.isHidden = true }
        for on in [true, false] {
            let box = checkbox(on: on, in: window)
            let square = try #require(box.imageView).frame
            #expect(box.bounds.height == 32)
            #expect(square == CGRect(x: 6, y: 6, width: 20, height: 20), "\(square)")
            let title = try #require(box.titleLabel).frame
            #expect(abs(title.minX - square.maxX - 9) < 0.5 && abs(box.bounds.maxX - title.maxX - 12) < 0.5, "\(title)")
            // The box drawn fills its frame, as a symbol's own image, with room around its outline, wouldn't.
            let ink = try pixels(of: box.configuration?.image).ink
            #expect(abs(ink.minX) <= 0.5 && abs(ink.minY) <= 0.5 && abs(ink.width - 20) <= 0.5 && abs(ink.height - 20) <= 0.5, "\(ink)")
        }

        // Drawn finely, the highlight's corner, less the box's distance in, is the box's: round the whole quarter, from
        // the center of the box's corner, the highlight's edge runs that distance outside the box's.
        let fine = try self.window(scale: 8)
        defer { fine.isHidden = true }
        let on = checkbox(on: true, in: fine)
        let square = try #require(on.imageView).frame
        let symbol = try pixels(of: on.configuration?.image)
        #expect(symbol.scale == 8)
        let alpha: ([Int]) -> CGFloat = { CGFloat($0[3]) / 255 }
        let corner = try #require(Corner(in: symbol, corner: .zero, across: square.width / 2, alpha))
        let box = distances(in: symbol, from: corner.center, reach: corner.radius + 1.5, alpha)
        let behind = components(Self.background, in: fine), tint = components(on.tintColor, in: on)
        let highlight = zip(behind, tint).map { $0 * 0.75 + $1 * 0.25 }
        let center = CGPoint(x: square.minX + corner.center.x, y: square.minY + corner.center.y)
        let edge = distances(in: try pixels(of: on, scale: 8), from: center, reach: corner.radius + square.minY + 2,
                             coverage(from: behind, to: highlight))
        let inner = box.compactMap { $0 }, outer = edge.compactMap { $0 }
        #expect(inner.count == box.count && outer.count == edge.count)
        let r = inner.reduce(0, +) / CGFloat(inner.count), R = outer.reduce(0, +) / CGFloat(outer.count), p = square.minY
        #expect(abs(R - p - r) < 0.15, "R \(R), p \(p), r \(r)")
        // UIKit's corners are continuous and the symbol's not quite, which parts them by a little, nowhere a pixel.
        let gaps = zip(outer, inner).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - p) < 0.35 }, "\(gaps)")
    }

    /// Checking or unchecking moves nothing, nor does dimming: the checkbox, its box and its title keep their frames.
    @Test func checkingMovesNothing() throws {
        let window = try window()
        defer { window.isHidden = true }
        let box = checkbox(on: false, in: window)
        func frames() throws -> [CGRect] {
            box.frame.size = box.intrinsicContentSize
            box.layoutIfNeeded()
            return [box.frame, try #require(box.imageView).frame, try #require(box.titleLabel).frame]
        }
        let off = try frames()
        box.isSelected = true
        #expect(try frames() == off)
        box.isEnabled = false
        #expect(try frames() == off)
    }

    /// Squeezed for a moment in its row, as an editor's are while it comes up as a sheet in a narrow window, a
    /// checkbox keeps its title on one line, so it's whole again once the row has the room.
    @Test func aSqueezedCheckboxComesBackWhole() throws {
        let window = try window()
        defer { window.isHidden = true }
        let view = try #require(window.rootViewController?.view)
        for squeezed in [150, 230] as [CGFloat] {
            let boxes = ["Colorize", "Preview"].map { OptionControls.checkbox($0) { _ in } }
            let whole = boxes.map(\.intrinsicContentSize)
            let row = OptionControls.row(boxes + [UIView()], spacing: 18)
            row.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(row)
            let width = row.widthAnchor.constraint(equalToConstant: squeezed)
            NSLayoutConstraint.activate([width, row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                                         row.topAnchor.constraint(equalTo: view.topAnchor, constant: 20)])
            view.layoutIfNeeded()
            width.constant = 400
            view.layoutIfNeeded()
            #expect(boxes.map(\.bounds.size) == whole, "squeezed to \(squeezed)")
            row.removeFromSuperview()
        }
    }

    /// The box is the system's square: checked, filled in white with the check cut out of it, so the tint shows
    /// through, in either appearance; unchecked, an outline in the secondary label color; and in the tertiary one,
    /// checked or not, title and all, while it can't be changed. Each is its color all over, edges and all.
    @Test func theBoxIsWhiteWhenChecked() throws {
        for style in [UIUserInterfaceStyle.dark, .light] {
            let window = try window(style)
            defer { window.isHidden = true }
            let on = try pixels(of: checkbox(on: true, in: window).configuration?.image)
            #expect(on.color(at: CGPoint(x: 10, y: 2)) == [255, 255, 255, 255], "\(style.rawValue)")
            #expect(on.pixel(0, 0)[3] < 8, "\(style.rawValue)")
            let cut = cutOut(of: on)
            #expect(cut > 0.08 && cut < 0.5, "\(style.rawValue): \(cut)")
            // White to its edges, not darker along some of them.
            let gray = offColor(on, [255, 255, 255])
            #expect(gray.isEmpty, "\(style.rawValue): \(gray.count) pixels, as \(gray.prefix(3))")
        }

        let window = try window()
        defer { window.isHidden = true }
        let behind = components(Self.background, in: window)
        let box = checkbox(on: false, in: window)
        let off = try pixels(of: box.configuration?.image)
        // In the colors as the dark window shows them: resolved for the light appearance, the outline's alpha would be
        // the same but its red, green and blue far darker. Pixels are premultiplied, so each is the color's times its
        // alpha.
        let outline = premultiplied(components(.secondaryLabel, in: box))
        let top = off.color(at: CGPoint(x: 10, y: 0.75))
        #expect(off.color(at: CGPoint(x: 10, y: 10))[3] < 8 && off.pixel(0, 0)[3] < 8)
        #expect(abs(CGFloat(top[3]) - outline[3]) < 12 && matches(top, outline), "\(top) for \(outline)")
        let stray = offColor(off, components(.secondaryLabel, in: box))
        #expect(stray.isEmpty, "\(stray.count) pixels, as \(stray.prefix(3))")

        for on in [true, false] {
            let disabled = checkbox(on: on, enabled: false, in: window)
            let drawn = try pixels(of: disabled.configuration?.image)
            let dim = premultiplied(components(.tertiaryLabel, in: disabled))
            // Filled with the check cut out while on, as Image Size's Lock aspect ratio is with Resample off, so it
            // still says it's on; an outline, clear inside, while off.
            let cut = cutOut(of: drawn)
            #expect(on ? cut > 0.08 && cut < 0.5 : cut == 1, "on \(on): \(cut)")
            let all = (0..<drawn.height).flatMap { y in (0..<drawn.width).map { drawn.pixel($0, y) } }
            let most = try #require(all.max { $0[3] < $1[3] })
            #expect(abs(CGFloat(most[3]) - dim[3]) < 12 && matches(most, dim), "on \(on): \(most) for \(dim)")
            let top = drawn.color(at: CGPoint(x: 10, y: 0.75))
            #expect(abs(CGFloat(top[3]) - dim[3]) < 12 && matches(top, dim), "on \(on): \(top) for \(dim)")
            let stray = offColor(drawn, components(.tertiaryLabel, in: disabled))
            #expect(stray.isEmpty, "on \(on): \(stray.count) pixels, as \(stray.prefix(3))")
            // The title too: the brightest pixels of its strokes are the color over what's behind.
            let shown = try pixels(of: disabled), title = try #require(disabled.titleLabel).frame
            let strokes = (Int(title.minY * 2)..<Int(title.maxY * 2)).flatMap { y in
                (Int(title.minX * 2)..<Int(title.maxX * 2)).map { shown.pixel($0, y) }
            }
            let brightest = try #require(strokes.max { $0[1] < $1[1] })
            let color = components(.tertiaryLabel, in: disabled)
            let over = zip(behind, color).map { $0 + ($1 - $0) * color[3] / 255 }
            #expect(matches(brightest, over, within: 6), "on \(on): \(brightest) for \(over)")
        }
    }

    /// With Bold Text, turned on while the checkbox shows, the box is as heavy as the system then draws its symbols and
    /// still 20 across, not cut off where it runs past: unchecked, its outline is thicker on every side, as thick for
    /// its width as the symbol's own; checked, its check is cut out wider. Turned off, it's as it was.
    @Test func boldTextMakesTheBoxHeavier() throws {
        let window = try window(scale: 8)
        defer { window.isHidden = true }
        // How thick the symbol's own outline is with Bold Text, drawn at 400 points, for its width, halfway down its
        // left side: as thick as the box's should be at 20.
        let symbol = try #require(UIImage(systemName: "square", withConfiguration: UIImage.SymbolConfiguration(pointSize: 400)
            .withTraitCollection(UITraitCollection(legibilityWeight: .bold))))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let own = try pixels(of: UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(at: .zero)
        })
        let row = Int(own.ink.midY)
        let expected = (0..<own.width / 2).reduce(0) { $0 + CGFloat(own.pixel($1, row)[3]) / 255 } / own.ink.width * 20
        // How thick the box's outline is, in points, halfway along each side: from where it's half on, coming in from
        // outside, to where it's half off again.
        func strokes(_ drawn: Pixels) throws -> [CGFloat] {
            let most = CGFloat(stride(from: 3, to: drawn.bytes.count, by: 4).map { drawn.bytes[$0] }.max() ?? 255)
            let coverage: ([Int]) -> CGFloat = { CGFloat($0[3]) / most }
            let middle = CGPoint(x: 10, y: 10)
            return try [CGPoint(x: -1, y: 10), CGPoint(x: 21, y: 10), CGPoint(x: 10, y: -1), CGPoint(x: 10, y: 21)].map { outside in
                let edge = try #require(drawn.edge(from: outside, to: middle, coverage))
                let inside = try #require(drawn.edge(from: middle, to: outside, coverage))
                return hypot(inside.x - edge.x, inside.y - edge.y)
            }
        }

        for on in [false, true] {
            let box = checkbox(on: on, in: window)
            func drawn(_ weight: UILegibilityWeight) throws -> Pixels {
                window.traitOverrides.legibilityWeight = weight
                window.layoutIfNeeded()
                return try pixels(of: box.configuration?.image)
            }
            let regular = try drawn(.regular), bold = try drawn(.bold)
            let ink = bold.ink
            #expect(abs(ink.minX) <= 0.25 && abs(ink.minY) <= 0.25 && abs(ink.width - 20) <= 0.25 && abs(ink.height - 20) <= 0.25,
                    "on \(on): \(ink)")
            if on {
                #expect(cutOut(of: bold) > cutOut(of: regular) + 0.02, "\(cutOut(of: bold)) for \(cutOut(of: regular))")
            } else {
                let heavier = try strokes(bold), was = try strokes(regular)
                #expect(zip(heavier, was).allSatisfy { $0 > $1 * 1.2 && abs($0 - expected) < 0.2 }, "\(heavier) for \(expected), from \(was)")
            }
            #expect(try drawn(.regular).bytes == regular.bytes, "on \(on)")
        }
    }

    /// The Transform bar's lock, a symbol alone, is drawn as it was, on and off: a plain button's link at its insets,
    /// in the tint on a faint tint of it while on.
    @Test func theTransformLockIsUnchanged() throws {
        let window = try window()
        defer { window.isHidden = true }
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        session.selectTool(.move)
        let bar = ToolOptionsBar(frame: CGRect(x: 0, y: 100, width: 1200, height: ToolOptionsBar.height))
        bar.backgroundColor = Self.background
        window.rootViewController?.view.addSubview(bar)
        bar.session = session

        // The lock as it was built before the checkboxes were redrawn.
        var configuration = UIButton.Configuration.plain()
        configuration.title = ""
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        let was = UIButton(configuration: configuration)
        was.configurationUpdateHandler = { button in
            button.configuration?.image = UIImage(systemName: "link")
            button.configuration?.baseForegroundColor = button.isSelected ? .tintColor : .secondaryLabel
            button.configuration?.background.backgroundColor = button.isSelected ? UIColor.tintColor.withAlphaComponent(0.18) : .clear
        }
        window.rootViewController?.view.addSubview(was)

        for on in [false, true] {
            session.locksTransformRatio = on
            bar.updatePropertiesIfNeeded()
            bar.layoutIfNeeded()
            let lock = try #require(views(UIButton.self, in: bar).first { $0.accessibilityLabel == "Lock aspect ratio" })
            #expect(lock.isSelected == on && lock.isEnabled)
            was.isSelected = on
            was.frame = CGRect(origin: CGPoint(x: 20, y: 20), size: was.intrinsicContentSize)
            was.layoutIfNeeded()
            #expect(lock.bounds.size == was.bounds.size && lock.bounds.size == CGSize(width: 36, height: 32), "\(lock.bounds)")
            #expect(lock.imageView?.frame == was.imageView?.frame, "\(String(describing: lock.imageView?.frame))")
            let drawn = try pixels(of: lock), before = try pixels(of: was)
            #expect(zip(drawn.bytes, before.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "on \(on)")
        }
    }
}
