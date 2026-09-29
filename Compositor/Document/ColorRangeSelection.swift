import AppKit
import Observation

/// Select > Color Range: every pixel near the colors clicked on the canvas, anywhere in the image. The panel shows
/// the selection live; OK keeps it as one undo step, Cancel puts back the one there was.
@MainActor @Observable
final class ColorRangeEdit {
    static let fuzzinessRange: ClosedRange<Double> = 0...200
    /// The panel's preview fits in this, in points.
    nonisolated static let previewSize = CGSize(width: 292, height: 200)
    var fuzziness: Double = 40
    var invert = false
    /// What the next click on the canvas does: start over from that color, add it, or take it away.
    var sampleMode: HueSampleMode = .replace
    /// Shift (add) or Option (take away) held right now, which a click uses over `sampleMode`.
    var held: HueSampleMode?
    var effectiveMode: HueSampleMode { held ?? sampleMode }
    /// The selection in black and white, small enough for the panel. Nil until a color is picked.
    var preview: CGImage?
    var include: [UInt8] = []
    var exclude: [UInt8] = []
    var error: String?
    /// The image as shown, at document size: what the colors are matched against.
    @ObservationIgnored let image: CGImage
    @ObservationIgnored let original: DocumentSelection?
    @ObservationIgnored var generation = 0
    init(image: CGImage, original: DocumentSelection?) { self.image = image; self.original = original }
    var hasColors: Bool { !include.isEmpty }
}

private nonisolated struct ColorRangeJob: @unchecked Sendable {
    let image: CGImage
    let include: [UInt8], exclude: [UInt8]
    let fuzziness: Int32, invert: Bool
}

private nonisolated struct ColorRangeResult: @unchecked Sendable {
    var path: CGPath?
    var preview: CGImage?
    var error: Error?
}

extension EditorSession {
    var canSelectColorRange: Bool { document != nil && colorRange == nil && canEditSelection }

    func beginColorRange() {
        guard canSelectColorRange, let document, let image = selectionSample(document, sampleAllLayers: true) else { return }
        colorRange = ColorRangeEdit(image: image, original: selection)
    }

    /// A click on the canvas while the panel is open. Shift adds the color and Option takes it away, whichever
    /// eyedropper is chosen.
    func sampleColorRange(at point: CGPoint, shift: Bool, option: Bool) {
        guard let edit = colorRange, let color = Self.color(in: edit.image, at: point) else { return }
        switch option ? .remove : shift ? .add : edit.sampleMode {
        case .replace: edit.include = color; edit.exclude = []
        case .add: edit.include += color
        case .remove: edit.exclude += color
        }
        updateColorRange()
    }

    /// Matches the image against the picked colors off the main thread and shows the result as the selection, without
    /// an undo step. A newer change supersedes one still being worked out.
    func updateColorRange() {
        guard let edit = colorRange, let document else { return }
        edit.generation += 1
        let generation = edit.generation
        guard edit.hasColors else { self.document?.selection = edit.original; edit.preview = nil; return }
        let job = ColorRangeJob(image: edit.image, include: edit.include, exclude: edit.exclude,
                                fuzziness: Int32(edit.fuzziness.rounded()), invert: edit.invert)
        Task {
            let result = await Task.detached(priority: .userInitiated) { Self.colorRangeResult(job) }.value
            guard colorRange === edit, edit.generation == generation, self.document?.id == document.id else { return }
            edit.error = result.error?.localizedDescription
            edit.preview = result.preview
            if result.error != nil { return }
            self.document?.selection = result.path.map { DocumentSelection(path: $0, antialiased: selectionAntialiased) }
        }
    }

    func commitColorRange() {
        guard let edit = colorRange else { return }
        let result = selection
        document?.selection = edit.original
        colorRange = nil
        guard edit.hasColors, edit.error == nil else { return }
        if let result { setSelection(result, name: "Color Range") } else { deselect() }
    }

    func cancelColorRange() {
        guard let edit = colorRange else { return }
        document?.selection = edit.original
        colorRange = nil
    }

    /// The straight color under `point` (document pixels), averaged over the 3 × 3 pixels around it.
    private static func color(in image: CGImage, at point: CGPoint) -> [UInt8]? {
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard point.x.isFinite, point.y.isFinite, (0..<image.width).contains(x), (0..<image.height).contains(y),
              let context = try? BrushRaster.context(width: 3, height: 3, mask: false) else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 1 - x, y: 1 - y, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var sums = [0, 0, 0, 0]
        for row in 0..<3 {
            for column in 0..<3 {
                for channel in 0..<4 { sums[channel] += Int(data[row * context.bytesPerRow + column * 4 + channel]) }
            }
        }
        guard sums[3] > 0 else { return nil }
        return (0..<3).map { UInt8(min(255, (sums[$0] * 255 + sums[3] / 2) / sums[3])) }
    }

    private nonisolated static func colorRangeResult(_ job: ColorRangeJob) -> ColorRangeResult {
        var result = ColorRangeResult()
        do {
            let mask = try colorRangeMask(job)
            result.preview = preview(of: mask, width: job.image.width, height: job.image.height)
            if mask.contains(where: { $0 != 0 }) { result.path = try MagicWand.outline(of: mask, width: job.image.width, height: job.image.height) }
        } catch { result.error = error }
        return result
    }

    /// The mask shrunk to the panel's preview, white where selected, at twice its size for a sharp Retina picture.
    private nonisolated static func preview(of mask: [UInt8], width: Int, height: Int) -> CGImage? {
        let scale = min(ColorRangeEdit.previewSize.width / CGFloat(width), ColorRangeEdit.previewSize.height / CGFloat(height)) * 2
        let w = max(1, Int(CGFloat(width) * scale)), h = max(1, Int(CGFloat(height) * scale))
        var bytes = mask
        guard let provider = CGDataProvider(data: Data(bytes: &bytes, count: bytes.count) as CFData),
              let full = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    private nonisolated static func colorRangeMask(_ job: ColorRangeJob) throws -> [UInt8] {
        let width = job.image.width, height = job.image.height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(job.image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        var mask = [UInt8](repeating: 0, count: width * height)
        _ = mask.withUnsafeMutableBufferPointer { out in
            job.include.withUnsafeBufferPointer { include in
                job.exclude.withUnsafeBufferPointer { exclude in
                    color_range_mask(data.assumingMemoryBound(to: UInt8.self), width, height, context.bytesPerRow,
                                     include.baseAddress, Int32(include.count / 3), exclude.baseAddress, Int32(exclude.count / 3),
                                     job.fuzziness, job.invert ? 1 : 0, out.baseAddress)
                }
            }
        }
        return mask
    }
}
