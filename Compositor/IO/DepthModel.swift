import CoreGraphics
import CoreImage
import CoreML
import CryptoKit
import Foundation
import Vision

/// How far away each part of a photo is, from DepthMini: a 2.6 MB model distilled from Depth Anything V2 Small
/// (Apache-2.0), for Volumetric Light's fog. It isn't in the app: the first time it's needed it's downloaded (three
/// files, checked against the fingerprints below), compiled and kept in Application Support. Until then, or without a
/// connection, `depth` is nil and the fog falls back to its own guess.
nonisolated enum DepthModel {
    /// Where the files are published, and what each must be. A new model gets a new release.
    static var source = URL(string: "https://github.com/robbietilton/Compositor/releases/download/depth-model-1/")!
    private static let files: [(name: String, path: String, sha256: String)] = [
        ("Manifest.json", "Manifest.json", "cfaa07eae081a343ff0e011c2875206d832335e55073252c29c79f73fd938929"),
        ("model.mlmodel", "Data/com.apple.CoreML/model.mlmodel", "c9e2f4f1e44409a2b9f5fb0b072ba41fb42d03a555c333f635f5162676feb744"),
        ("weight.bin", "Data/com.apple.CoreML/weights/weight.bin", "63d066f1aefc362f2cc0805a624e08df13b6cff3be45dc4307b20a531a2a9f86"),
    ]
    /// The sizes the model takes, width × height: square, 4:3 and 16:9 either way up.
    static let shapes = [(512, 512), (512, 384), (512, 288), (384, 512), (288, 512)]

    /// The shape nearest `image`'s proportions, so it's scaled to fit rather than squashed square.
    static func shape(for image: CGImage) -> (width: Int, height: Int) {
        let aspect = log(Double(image.width) / Double(max(1, image.height)))
        return shapes.min { abs(log(Double($0.0) / Double($0.1)) - aspect) < abs(log(Double($1.0) / Double($1.1)) - aspect) }!
    }

    /// The compiled model, kept between launches, in a folder named for its weights, so a copy of another model (one
    /// kept while it was being made) is never mistaken for it.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Compositor/Depth Model \(files[2].sha256.prefix(12))", isDirectory: true)
    }
    private static var compiled: URL { folder.appendingPathComponent("DepthMini.mlmodelc", isDirectory: true) }

    private static let state = State()
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var model: MLModel?
        var loading: Task<Bool, Never>?
        /// The last image worked out, held so another can't take its place in memory and be mistaken for it.
        var cached: (image: CGImage, depth: DepthMap)?
    }

    /// Whether the model is loaded and `depth` works.
    static var isReady: Bool { state.lock.withLock { state.model != nil } }

    /// Loads the model, downloading and compiling it the first time. True once it's ready; false if it couldn't be
    /// had (no connection, a file that doesn't match), to be tried again next time.
    @discardableResult static func prepare() async -> Bool {
        let task: Task<Bool, Never> = state.lock.withLock {
            if state.model != nil { return Task { true } }
            if let loading = state.loading { return loading }
            let loading = Task.detached(priority: .userInitiated) { await load() }
            state.loading = loading
            return loading
        }
        let ready = await task.value
        state.lock.withLock { state.loading = nil }
        return ready
    }

    private static func load() async -> Bool {
        do {
            if !FileManager.default.fileExists(atPath: compiled.path) { try await download() }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: compiled, configuration: configuration)
            state.lock.withLock { state.model = model }
            return true
        } catch {
            // A broken copy goes, so the next try downloads afresh.
            try? FileManager.default.removeItem(at: compiled)
            return false
        }
    }

    /// The three files into a package, fetched together and each checked, then compiled into place.
    private static func download() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("DepthMini-\(UUID().uuidString).mlpackage")
        defer { try? FileManager.default.removeItem(at: package) }
        let source = source
        try await withThrowingTaskGroup(of: Void.self) { group in
            for file in files {
                group.addTask {
                    let (data, response) = try await URLSession.shared.data(from: source.appendingPathComponent(file.name))
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard digest == file.sha256 else { throw URLError(.cannotDecodeContentData) }
                    let destination = package.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destination)
                }
            }
            try await group.waitForAll()
        }
        let built = try await MLModel.compileModel(at: package)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: compiled)
        try FileManager.default.moveItem(at: built, to: compiled)
    }

    /// The longer side of the depth as it's kept, after it's been pulled onto the photo's edges.
    static let refinedSide = 640

    /// `image`'s depth, 1 nearest and 0 farthest: the model's map, which is soft and a little off the photo's edges,
    /// enlarged to `refinedSide` and pulled onto those edges with a guided filter (as Remove Background pulls its mask),
    /// so its near and far meet where the photo's own outlines are, not in a halo around them. Nil until the model is
    /// ready.
    static func depth(for image: CGImage) -> DepthMap? {
        let (model, cached) = state.lock.withLock { (state.model, state.cached) }
        guard let model else { return nil }
        if let cached, cached.image === image { return cached.depth }
        // Scaled to the nearest of the model's shapes at 8 bits first: Core ML takes a 16-bit or HDR layer's pixels no
        // other way.
        let (columns, rows) = shape(for: image)
        guard let small = pixels(of: image, width: columns, height: rows),
              let input = try? MLFeatureValue(cgImage: small.image, pixelsWide: columns, pixelsHigh: rows, pixelFormatType: kCVPixelFormatType_32BGRA,
                                              options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]),
              let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let array = output.featureValue(for: "depth")?.multiArrayValue, array.count == columns * rows else { return nil }
        let values = MLShapedArray<Float>(converting: array).scalars
        guard let low = values.min(), let high = values.max(), high > low else { return nil }
        // Enlarged to the photo's shape, then onto its edges, its brightness the guide.
        let scale = Double(refinedSide) / Double(max(image.width, image.height))
        let width = max(8, Int((Double(image.width) * scale).rounded())), height = max(8, Int((Double(image.height) * scale).rounded()))
        guard let guide = pixels(of: image, width: width, height: height) else { return nil }
        var enlarged = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let fy = min(Float(rows - 1), max(0, (Float(y) + 0.5) * Float(rows) / Float(height) - 0.5))
            let y0 = Int(fy), y1 = min(rows - 1, y0 + 1), ty = fy - Float(y0)
            for x in 0..<width {
                let fx = min(Float(columns - 1), max(0, (Float(x) + 0.5) * Float(columns) / Float(width) - 0.5))
                let x0 = Int(fx), x1 = min(columns - 1, x0 + 1), tx = fx - Float(x0)
                let top = values[y0 * columns + x0] * (1 - tx) + values[y0 * columns + x1] * tx
                let bottom = values[y1 * columns + x0] * (1 - tx) + values[y1 * columns + x1] * tx
                enlarged[y * width + x] = ((top * (1 - ty) + bottom * ty) - low) / (high - low)
            }
        }
        let refined = GuidedMatte.filter(mask: enlarged, guide: guide.gray, width: width, height: height,
                                         radius: max(2, refinedSide / 48), epsilon: 1e-3).map { max(0, min(1, $0)) }
        let depth = DepthMap(values: refined, width: width, height: height)
        state.lock.withLock { state.cached = (image, depth) }
        return depth
    }

    /// `image` at `width` × `height`, 8 bits, and its brightness 0–1, rows top-down.
    private static func pixels(of image: CGImage, width: Int, height: Int) -> (image: CGImage, gray: [Float])? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let made = context.makeImage(), let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var gray = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = bytes + y * context.bytesPerRow + x * 4
                gray[y * width + x] = (0.2126 * Float(p[0]) + 0.7152 * Float(p[1]) + 0.0722 * Float(p[2])) / 255
            }
        }
        return (made, gray)
    }

    /// `depth` as an image over `extent` (Core Image's coordinates), smoothly enlarged: 16-bit gray, read as it is
    /// (Core Image makes nothing of float pixels handed to it directly).
    static func image(_ depth: DepthMap, over extent: CGRect) -> CIImage {
        let levels = depth.values.map { UInt16(max(0, min(1, $0)) * 65535) }
        guard let provider = CGDataProvider(data: levels.withUnsafeBytes { Data($0) } as CFData),
              let gray = CGImage(width: depth.width, height: depth.height, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: depth.width * 2,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return CIImage.black.cropped(to: extent)
        }
        return CIImage(cgImage: gray, options: [.colorSpace: NSNull()]).samplingLinear()
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)
                .scaledBy(x: extent.width / CGFloat(depth.width), y: extent.height / CGFloat(depth.height)))
            .cropped(to: extent)
    }
}

/// A photo's depth from `DepthModel`: `width` × `height` values, rows top-down, 1 nearest and 0 farthest.
nonisolated struct DepthMap: Sendable {
    let values: [Float]
    let width: Int
    let height: Int

    /// The map with its depths spread out, `amount` of the way (0–1) to equalized, as Equalize spreads a photo's tones:
    /// each value moves toward its rank among them all, so depths the model bunched together (a distant city, everything
    /// past a near subject) come apart into steps, while their order stays the same.
    func equalized(_ amount: Float) -> DepthMap {
        guard amount > 0, values.count > 1 else { return self }
        let order = values.indices.sorted { values[$0] < values[$1] }
        var spread = values
        let last = Float(values.count - 1)
        for (rank, index) in order.enumerated() { spread[index] += (Float(rank) / last - values[index]) * amount }
        return DepthMap(values: spread, width: width, height: height)
    }
}
