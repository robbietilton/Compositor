import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import Compositor

/// Filter › Volumetric Light, on a dark room with a bright window crossed by a bar.
struct VolumetricLightTests {
    private let width = 600, height = 400

    /// The window's top-left corner and size, rows top-down, and the bar down its middle.
    private let window = CGRect(x: 260, y: 40, width: 80, height: 80)

    private func room() throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // These contexts draw rows top-down, as the image's.
        context.setFillColor(CGColor(red: 1, green: 0.97, blue: 0.9, alpha: 1))
        context.fill(window)
        context.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1))
        context.fill(CGRect(x: window.midX - 4, y: window.minY, width: 8, height: window.height))
        return try #require(context.makeImage())
    }

    /// Brightness at a pixel, rows top-down.
    private func gray(_ image: CGImage, _ x: Int, _ y: Int) throws -> Int {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let at = y * context.bytesPerRow + x * 4
        return (Int(bytes[at]) + Int(bytes[at + 1]) + Int(bytes[at + 2])) / 3
    }

    @Test func theLightStartsOnTheBrightestSpot() throws {
        let point = VolumetricLighting.brightestPoint(in: try room())
        #expect(window.insetBy(dx: -10, dy: -10).contains(point), "on the window: \(point)")
    }

    /// A wide opening wins over a smaller, hotter patch of light: the biggest bright area, not the brightest pixel.
    @Test func theLightStartsInTheBiggestBrightArea() throws {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A wide opening at the top, a little less bright, and a small hot patch near the foot.
        context.setFillColor(CGColor(red: 0.9, green: 0.88, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 220, y: 20, width: 160, height: 120))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 330, width: 30, height: 30))
        let point = VolumetricLighting.brightestPoint(in: try #require(context.makeImage()))
        #expect(CGRect(x: 220, y: 20, width: 160, height: 120).contains(point), "in the opening: \(point)")
    }

    @Test func beamsLightTheRoomAndTheBarCastsAShaftOfShadow() throws {
        let original = try room()
        var settings = FilterSettings()
        settings.volumetric.center = CGPoint(x: window.midX, y: window.midY)
        settings.volumetric.haze = 0
        settings.volumetric.shafts = 0
        settings.volumetric.length = 100
        settings.volumetric.intensity = 80
        let lit = try PixelFilter.run(FilterJob(kind: .volumetricLight, image: original, settings: settings, scale: 1, selection: nil,
                                                mapping: .identity))
        // Below the window, straight down from it: behind the bar, and to one side where its light comes through.
        let below = Int(window.maxY) + 60
        let shadowed = try gray(lit, Int(window.midX), below), open = try gray(lit, Int(window.minX) + 18, below)
        let before = try gray(original, Int(window.minX) + 18, below)
        #expect(open > before + 20, "the beams light the room below the window: \(before) → \(open)")
        #expect(shadowed < open - 6, "the bar's shadow runs through them: \(shadowed) against \(open)")
        let corner = try gray(lit, 5, height - 5)
        #expect(corner < open - 10, "the far corner gets less than near the window: \(corner) against \(open)")
    }

    /// Depth reaches the haze: everything near (1) leaves less haze than no depth at all, which guesses most of the frame
    /// is far.
    @Test func depthThinsTheHazeWhereThingsAreNear() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let depthImage = DepthModel.image(DepthMap(values: [Float](repeating: 1, count: 16 * 16), width: 16, height: 16), over: extent)
        #expect(depthImage.extent == extent, "the depth image covers the layer: \(depthImage.extent)")
        let photo = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: extent)
        let clear = CIImage.black.cropped(to: extent)
        var settings = VolumetricLightSettings()
        settings.intensity = 0
        settings.haze = 100
        let context = CIContext()
        func top(_ depth: CIImage?) throws -> Float {
            let lit = try MetalVolumetricLight.combined(photo, beams: clear, near: clear, glows: clear, ambient: photo, depth: depth,
                                                        ramp: (0, 0.5), light: CGPoint(x: 32, y: 32), side: 64, settings: settings)
            var pixel = [Float](repeating: 0, count: 4)
            context.render(lit, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 32, y: 60, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return pixel[0]
        }
        let guessed = try top(nil), near = try top(depthImage)
        #expect(abs(near - guessed) > 0.01, "near: \(near), guessed far: \(guessed)")
    }

    /// Depth Contrast spreads bunched depths apart and keeps their order; 0 leaves them.
    @Test func depthContrastSpreadsBunchedDepths() {
        let bunched = DepthMap(values: [0, 0.01, 0.02, 0.03, 1], width: 5, height: 1)
        #expect(bunched.equalized(0).values == bunched.values)
        let spread = bunched.equalized(1).values
        #expect(spread == [0, 0.25, 0.5, 0.75, 1], "evenly by rank: \(spread)")
        let half = bunched.equalized(0.5).values
        #expect(half == half.sorted() && half[2] > 0.2, "half way, in the same order: \(half)")
    }

    /// Times the filter at preview size as Haze moves, for `VOLUMETRIC_TIMING` (an image path). Skipped when unset.
    @Test func timeHazeChanges() async throws {
        guard let path = ProcessInfo.processInfo.environment["VOLUMETRIC_TIMING"],
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        if let folder = ProcessInfo.processInfo.environment["VOLUMETRIC_DEPTH"] {
            DepthModel.source = URL(fileURLWithPath: folder, isDirectory: true)
            _ = await DepthModel.prepare()
        }
        // At the preview's size, 2048 on the long side.
        let scale = 2048 / Double(max(full.width, full.height))
        let context = try BrushRaster.context(width: Int(Double(full.width) * scale), height: Int(Double(full.height) * scale), mask: false)
        BrushRaster.draw(full, in: CGRect(x: 0, y: 0, width: context.width, height: context.height), mask: false, context: context)
        let image = try #require(context.makeImage())
        var settings = FilterSettings()
        settings.volumetric.center = CGPoint(x: Double(image.width) / 2, y: Double(image.height) * 0.1)
        var times: [Double] = []
        for haze in stride(from: 40.0, through: 80, by: 5) {
            settings.volumetric.haze = haze
            let start = Date()
            _ = try PixelFilter.run(FilterJob(kind: .volumetricLight, image: image, settings: settings, scale: 1, selection: nil, mapping: .identity))
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        Attachment.record("\(image.width)x\(image.height) ms per Haze step: \(times.map { Int($0) }) depth \(DepthModel.isReady)", named: "timing.txt")
    }

    @Test func zeroIntensityAndHazeLeaveTheImage() throws {
        var settings = VolumetricLightSettings()
        settings.intensity = 0
        settings.haze = 0
        #expect(settings.isIdentity)
    }

    /// Renders the photos in `VOLUMETRIC_IMAGES` ("path,x,y" separated by ";", the light as fractions of the width and
    /// height from the top left) as attachments, to look at. Skipped when it's unset.
    /// With `VOLUMETRIC_DEPTH` set to a folder laid out as the release is, each is rendered twice: guessing depth, then
    /// with the depth model downloaded from there ("-a" and "-b").
    @Test func renderSamples() async throws {
        guard let list = ProcessInfo.processInfo.environment["VOLUMETRIC_IMAGES"] else { return }
        try render(list, suffix: "")
        if let folder = ProcessInfo.processInfo.environment["VOLUMETRIC_DEPTH"] {
            DepthModel.source = URL(fileURLWithPath: folder, isDirectory: true)
            #expect(await DepthModel.prepare(), "the model downloads, checks out and loads")
            try render(list, suffix: "-b")
            for (index, entry) in list.split(separator: ";").enumerated() {
                let path = String(entry.split(separator: ",")[0])
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                let map = try #require(VolumetricLighting.depthMap(for: image, settings: VolumetricLightSettings()))
                #expect(map.width == image.width && map.height == image.height)
                let data = NSMutableData()
                let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, map, nil)
                CGImageDestinationFinalize(destination)
                Attachment.record(data as Data, named: "sample-\(index)-depth-lit.png")
            }
        }
    }

    private func render(_ list: String, suffix: String) throws {
        for (index, entry) in list.split(separator: ";").enumerated() {
            let parts = entry.split(separator: ",").map(String.init)
            guard parts.count >= 3, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: parts[0]) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let x = Double(parts[1]), let y = Double(parts[2]) else { continue }
            var settings = FilterSettings()
            settings.volumetric.center = CGPoint(x: x * Double(image.width), y: y * Double(image.height))
            let names = ["intensity", "length", "haze", "size", "shafts"]
            for (index, name) in names.enumerated() where parts.count > 3 + index {
                guard let value = Double(parts[3 + index]) else { continue }
                switch name {
                case "intensity": settings.volumetric.intensity = value
                case "length": settings.volumetric.length = value
                case "haze": settings.volumetric.haze = value
                case "size": settings.volumetric.size = value
                default: settings.volumetric.shafts = value
                }
            }
            if parts.count >= 11, let r = Double(parts[8]), let g = Double(parts[9]), let b = Double(parts[10]) {
                settings.volumetric.color = AdjustmentColor(red: r, green: g, blue: b)
            }
            if parts.count >= 12, let distance = Double(parts[11]) { settings.volumetric.distance = distance }
            let lit = try PixelFilter.run(FilterJob(kind: .volumetricLight, image: image, settings: settings, scale: 1, selection: nil,
                                                    mapping: .identity))
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, lit, nil)
            CGImageDestinationFinalize(destination)
            Attachment.record(data as Data, named: "sample-\(index)\(suffix)-lit.png")
        }
    }
}
