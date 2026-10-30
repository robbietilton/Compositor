import Accelerate
import CoreGraphics
import CoreImage
import Vision

/// Auto-Align Layers: overlapping photos of one scene (frames for a panorama, a bracketed or focus-stacked series, a
/// shot taken twice) are matched by their content, and each is moved, or distorted in perspective, to sit over the
/// active layer, which stays where it is.
///
/// Phase correlation finds how far apart they are, however little they overlap; Vision then refines the match over
/// just the part they share. Vision alone can't find frames that overlap by half, and answers with full confidence
/// even when nothing matches, so every answer is checked against the pixels and the best one kept.
nonisolated enum AutoAlign {
    /// A map from one image's pixels to another's, both measured from the top-left.
    typealias Map = (CGPoint) -> CGPoint

    /// The longest side the layers are compared at: a match is found on far fewer pixels than a photo has.
    static let workingSide: CGFloat = 2048
    /// How well a match must line the pixels up (see `agreement`) to be used. A right match of one scene scores near 1,
    /// even between exposures; a wrong one, or a picture with nothing to match, far lower.
    static let minimumAgreement = 0.5

    /// Where `floating`'s corners (document points, handle order) belong over `reference`. Each layer's own pixels
    /// are compared, not the layers drawn onto the canvas, whose empty surroundings would read as an edge to match;
    /// the match is then carried through both placements. Nil when nothing matches.
    static func corners(of floating: (image: CGImage, transform: LayerTransform),
                        over reference: (image: CGImage, transform: LayerTransform)) throws -> [CGPoint]? {
        // Both at one scale, so a shift between them is a shift between their pixels.
        let scale = min(1, workingSide / CGFloat(max(floating.image.width, floating.image.height, reference.image.width, reference.image.height)))
        let source = try resized(floating.image, scale: scale), target = try resized(reference.image, scale: scale)
        let found = try candidates(source, target)
        let shifts = found.shifts.map { ($0, agreement(source, over: target, through: $0) ?? -1) }
        guard var (map, score) = shifts.max(by: { $0.1 < $1.1 }) else { return nil }
        // A perspective fitted to a narrow overlap matches there and goes astray beyond it, so it has to share a third
        // of the layer and line the pixels up clearly better than a shift does.
        if let perspective = found.perspective, found.shared >= 1.0 / 3,
           let better = agreement(source, over: target, through: perspective), better > score + 0.03 {
            (map, score) = (perspective, better)
        }
        guard score >= minimumAgreement else { return nil }
        // The layers' own corners are the unit square, mirrored for a flipped layer, whose pixels show the other way round.
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { unit -> CGPoint in
            let from = CGPoint(x: (floating.transform.flipX ? 1 - unit.x : unit.x) * CGFloat(source.width),
                               y: (floating.transform.flipY ? 1 - unit.y : unit.y) * CGFloat(source.height))
            let mapped = map(from)
            var landed = CGPoint(x: mapped.x / CGFloat(target.width), y: mapped.y / CGFloat(target.height))
            if reference.transform.flipX { landed.x = 1 - landed.x }
            if reference.transform.flipY { landed.y = 1 - landed.y }
            return reference.transform.point(landed)
        }
        return DistortWarp.isConvex(corners) ? corners : nil
    }

    /// Maps from `source` to `target` worth trying: the shift phase correlation finds, then Vision's shift and
    /// perspective over just the part that shift says they share, where Vision is at its best. `shared` is that
    /// part's share of `source`.
    static func candidates(_ source: CGImage, _ target: CGImage) throws -> (shifts: [Map], perspective: Map?, shared: CGFloat) {
        guard let shift = shift(of: source, in: target) else { return ([], nil, 0) }
        let dx = shift.width.rounded(), dy = shift.height.rounded()
        var maps: [Map] = [{ CGPoint(x: $0.x + dx, y: $0.y + dy) }]
        let overlap = CGRect(x: 0, y: 0, width: target.width, height: target.height)
            .intersection(CGRect(x: dx, y: dy, width: CGFloat(source.width), height: CGFloat(source.height)))
        guard overlap.width >= 64, overlap.height >= 64, let near = target.cropping(to: overlap),
              let far = source.cropping(to: overlap.offsetBy(dx: -dx, dy: -dy)),
              near.width == far.width, near.height == far.height else { return (maps, nil, 0) }
        let shared = overlap.width * overlap.height / CGFloat(source.width * source.height)
        let homography = VNHomographicImageRegistrationRequest(targetedCGImage: far, options: [:])
        let translation = VNTranslationalImageRegistrationRequest(targetedCGImage: far, options: [:])
        try VNImageRequestHandler(cgImage: near, options: [:]).perform([homography, translation])
        // Vision measures from the crops' bottom-left.
        let height = CGFloat(near.height)
        if let t = (translation.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform {
            maps.append { CGPoint(x: $0.x + dx + t.tx, y: $0.y + dy - t.ty) }
        }
        let perspective = ((homography.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform).map { matrix -> Map in
            { point in
                let mapped = matrix * SIMD3<Float>(Float(point.x + dx - overlap.minX), Float(height - (point.y + dy - overlap.minY)), 1)
                return CGPoint(x: CGFloat(mapped.x / mapped.z) + overlap.minX, y: height - CGFloat(mapped.y / mapped.z) + overlap.minY)
            }
        }
        return (maps, perspective, shared)
    }

    /// How far `source`'s content sits inside `target` (target pixels, top-left), by phase correlation: the peak of
    /// the inverse of their normalized cross-power spectrum. Nil when it can't be worked out.
    static func shift(of source: CGImage, in target: CGImage) -> CGSize? {
        let scale = min(1, 512 / CGFloat(max(source.width, source.height, target.width, target.height)))
        guard let a = tapered(target, scale: scale), let b = tapered(source, scale: scale) else { return nil }
        // Padded to twice the larger image, so a shift either way doesn't wrap round onto another.
        var n = 1
        while n < 2 * max(a.width, a.height, b.width, b.height) { n *= 2 }
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        func transform(_ real: inout [Float], _ imaginary: inout [Float], _ direction: Int32) {
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft2d_zip(setup, &split, 1, 0, log2n, log2n, FFTDirection(direction))
                }
            }
        }
        func spectrum(_ image: (pixels: [Float], width: Int, height: Int)) -> (real: [Float], imaginary: [Float]) {
            var real = [Float](repeating: 0, count: n * n), imaginary = [Float](repeating: 0, count: n * n)
            for y in 0..<image.height { for x in 0..<image.width { real[y * n + x] = image.pixels[y * image.width + x] } }
            transform(&real, &imaginary, Int32(kFFTDirection_Forward))
            return (real, imaginary)
        }
        let fa = spectrum(a), fb = spectrum(b)
        var real = [Float](repeating: 0, count: n * n), imaginary = [Float](repeating: 0, count: n * n)
        for index in 0..<(n * n) {
            let re = fa.real[index] * fb.real[index] + fa.imaginary[index] * fb.imaginary[index]
            let im = fa.imaginary[index] * fb.real[index] - fa.real[index] * fb.imaginary[index]
            let magnitude = max((re * re + im * im).squareRoot(), 1e-12)
            real[index] = re / magnitude
            imaginary[index] = im / magnitude
        }
        transform(&real, &imaginary, Int32(kFFTDirection_Inverse))
        var best = 0
        for index in 1..<(n * n) where real[index] > real[best] { best = index }
        var dx = best % n, dy = best / n
        if dx > n / 2 { dx -= n }
        if dy > n / 2 { dy -= n }
        return CGSize(width: CGFloat(dx) / scale, height: CGFloat(dy) / scale)
    }

    /// `image`'s brightness at `scale`, over mid gray where it's transparent, less its mean, and faded to nothing at
    /// its edges so they don't read as a match. Only the outer tenth fades: frames for a panorama overlap at their
    /// edges, which a full window would fade out.
    private static func tapered(_ image: CGImage, scale: CGFloat) -> (pixels: [Float], width: Int, height: Int)? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The bitmap's first row is the image's top.
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = Float(bytes[y * context.bytesPerRow + x]) } }
        let mean = pixels.reduce(0, +) / Float(pixels.count)
        func fade(_ index: Int, _ count: Int) -> Float {
            let edge = max(1, Float(count) * 0.1), distance = Float(min(index, count - 1 - index))
            return distance >= edge ? 1 : 0.5 - 0.5 * cos(Float.pi * distance / edge)
        }
        let across = (0..<width).map { fade($0, width) }, down = (0..<height).map { fade($0, height) }
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = (pixels[y * width + x] - mean) * across[x] * down[y] } }
        return (pixels, width, height)
    }

    /// How closely `source`, taken through `map`, lines up with `target` where both have pixels: the correlation of
    /// their brightness, so a darker or brighter exposure of the same scene still scores near 1. Nil when they
    /// hardly overlap or either is flat there.
    static func agreement(_ source: CGImage, over target: CGImage, through map: Map) -> Double? {
        let width = CGFloat(target.width), height = CGFloat(target.height)
        // Core Image measures y upward from the bottom of the target.
        func vector(_ x: CGFloat, _ y: CGFloat) -> CIVector {
            let point = map(CGPoint(x: x, y: y))
            return CIVector(x: point.x, y: height - point.y)
        }
        let w = CGFloat(source.width), h = CGFloat(source.height)
        let warped = CIImage(cgImage: source).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": vector(0, 0), "inputTopRight": vector(w, 0), "inputBottomRight": vector(w, h), "inputBottomLeft": vector(0, h),
        ])
        // A small copy is plenty to tell a match from a miss.
        let scale = min(1, 256 / max(width, height))
        let pw = max(1, Int(width * scale)), ph = max(1, Int(height * scale))
        func pixels(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: pw * ph * 4)
            context.render(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), toBitmap: &bytes, rowBytes: pw * 4,
                           bounds: CGRect(x: 0, y: 0, width: pw, height: ph), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return bytes
        }
        let a = pixels(warped), b = pixels(CIImage(cgImage: target))
        var n = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        for index in stride(from: 0, to: a.count, by: 4) where a[index + 3] > 250 && b[index + 3] > 250 {
            let x = 0.299 * Double(a[index]) + 0.587 * Double(a[index + 1]) + 0.114 * Double(a[index + 2])
            let y = 0.299 * Double(b[index]) + 0.587 * Double(b[index + 1]) + 0.114 * Double(b[index + 2])
            n += 1; sa += x; sb += y; saa += x * x; sbb += y * y; sab += x * y
        }
        guard n >= 400 else { return nil }
        let va = saa / n - (sa / n) * (sa / n), vb = sbb / n - (sb / n) * (sb / n)
        guard va > 4, vb > 4 else { return nil }
        return (sab / n - (sa / n) * (sb / n)) / (va * vb).squareRoot()
    }
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// When the match only moves the layer (within half a pixel at every corner), how far: a tilt-shift series or a
    /// tripod shot shifted in the frame needs no resampling at all.
    static func offset(from transform: LayerTransform, to corners: [CGPoint]) -> CGSize? {
        let original = DistortWarp.corners(of: transform)
        let dx = zip(corners, original).map { $0.x - $1.x }.reduce(0, +) / 4
        let dy = zip(corners, original).map { $0.y - $1.y }.reduce(0, +) / 4
        let moved = original.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return zip(moved, corners).allSatisfy({ abs($0.x - $1.x) < 0.5 && abs($0.y - $1.y) < 0.5 }) ? CGSize(width: dx, height: dy) : nil
    }

    private static func resized(_ image: CGImage, scale: CGFloat) throws -> CGImage {
        guard scale < 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }
}

extension EditorSession {
    /// The selected layers Auto-Align can match: plain pixel layers, not folders, adjustments, live text or shapes.
    var autoAlignCandidates: [ImageLayer] {
        document?.layers.filter {
            selectedLayerIDs.contains($0.id) && $0.asset != nil && !$0.isGroup && $0.adjustment == nil
                && $0.text == nil && $0.shape == nil && $0.gifAnimation == nil
        } ?? []
    }
    var canAutoAlignLayers: Bool { canAlignLayers && autoAlignCandidates.count > 1 }

    /// Matches each selected pixel layer to the active one (or the lowest, when the active one isn't among them),
    /// as one undo step. A layer that only shifted is moved by whole pixels, as Align moves; any other is distorted
    /// into place, as a Cmd-drag distortion is.
    func autoAlignLayers() async {
        commitTransform()
        let layers = autoAlignCandidates
        guard layers.count > 1, canStartProjectOperation else { return }
        let reference = layers.first { $0.id == activeLayerID } ?? layers[0]
        guard let referenceImage = reference.asset?.image else { return }
        let floating = layers.filter { $0.id != reference.id }.compactMap { layer in
            layer.asset.map { (id: layer.id, image: $0.image, transform: layer.transform) }
        }
        let anchor = (image: referenceImage, transform: reference.transform)
        isProjectBusy = true
        let matches = await Task.detached(priority: .userInitiated) {
            floating.map { layer in
                (layer.id, layer.image, (try? AutoAlign.corners(of: (layer.image, layer.transform), over: anchor)) ?? nil)
            }
        }.value
        isProjectBusy = false
        var unmatched: [String] = []
        var began = false
        for (id, image, corners) in matches {
            guard let index = self.document?.layers.firstIndex(where: { $0.id == id }), let layer = self.document?.layers[index],
                  layer.asset?.image === image else { continue }
            guard let corners else { unmatched.append(layer.name); continue }
            if !began { finishOpacityEdit(); beginEdit("Auto-Align Layers"); began = true }
            if let offset = AutoAlign.offset(from: layer.transform, to: corners) {
                var moved = layer.transform
                moved.origin.x += offset.width.rounded()
                moved.origin.y += offset.height.rounded()
                if let mask = layer.mask {
                    self.document?.layers[index].mask?.placement = mask.placement(movingLayer: layer.transform, to: moved)
                }
                self.document?.layers[index].transform = moved
            } else {
                do { try distort(at: index, transform: layer.transform, corners: corners) }
                catch { unmatched.append(layer.name) }
            }
        }
        if began { endEdit() }
        if !unmatched.isEmpty {
            alignError = "Nothing in " + unmatched.map { "“\($0)”" }.joined(separator: ", ")
                + " matched “\(reference.name)” closely enough to align it. Auto-Align needs photos that overlap."
        }
    }
}
