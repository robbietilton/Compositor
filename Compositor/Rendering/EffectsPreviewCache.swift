import AppKit

/// Canvas-only previews. Full-resolution export continues to use LayerEffectsRenderer.render on its worker.
/// A single worker, superseded-request cancellation and a fixed pixel budget keep slider drags off the UI thread.
@MainActor
final class EffectsPreviewCache {
    nonisolated private final class Request: @unchecked Sendable {
        let id = UUID()
        let image: CGImage
        let mask: CGImage?
        let maskSource: CGImage?
        let placement: LayerTransform?
        let transform: LayerTransform
        let effects: LayerEffects
        let sideLimit: Int
        private let lock = NSLock()
        private var cancelled = false
        init(image: CGImage, mask: CGImage?, maskSource: CGImage?, placement: LayerTransform?, transform: LayerTransform, effects: LayerEffects, sideLimit: Int) {
            self.image = image; self.mask = mask; self.maskSource = maskSource
            self.placement = placement; self.transform = transform; self.effects = effects; self.sideLimit = sideLimit
        }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func matches(_ other: Request) -> Bool {
            // Effects are rendered in layer pixels; moving, scaling or rotating the layer
            // only changes where the cached image is drawn. An independently placed mask
            // is the exception: its coverage must be resampled when either transform changes.
            let sameMaskGeometry = maskSource == nil && other.maskSource == nil
                || (placement == nil && other.placement == nil)
                || (placement == other.placement && transform == other.transform)
            return image === other.image && maskSource === other.maskSource && sameMaskGeometry
                && effects == other.effects && sideLimit == other.sideLimit
        }
    }
    nonisolated private struct Result: @unchecked Sendable {
        let image: CGImage
        let inset: CGFloat
        /// Set only on a seeded result: where that image belongs on the document, which an inset can't express
        /// when the layer's own box was cropped as well as warped.
        var placement: LayerTransform? = nil
    }
    private struct Entry {
        let request: Request
        var result: Result?
    }
    nonisolated private static let worker = DispatchQueue(label: "com.compositor.effects-preview", qos: .userInitiated)
    private var entries: [UUID: Entry] = [:]
    /// A result handed in from elsewhere — the effects warped with a distortion as it is applied — shown until the
    /// worker has rendered the layer's new pixels, so the effects don't blink off for a frame.
    private var seeds: [UUID: Result] = [:]
    private var sideLimit = 1536

    /// Shows `image` at `placement` for a layer until a fresh preview is ready.
    func seed(_ id: UUID, image: CGImage, placement: LayerTransform) {
        // Whatever is being rendered is for the pixels this replaces, and landing later would drop the seed.
        entries.removeValue(forKey: id)?.request.cancel()
        seeds[id] = Result(image: image, inset: 0, placement: placement)
    }

    /// Effects for a layer being painted, from the pixels the stroke has so far. Keyed by the stroke's revision:
    /// the last result stays on screen while the next one renders, so the effects never blink off mid-stroke.
    /// What is already rendered for a layer, without asking for anything new.
    func rendered(_ id: UUID) -> (image: CGImage, inset: CGFloat, placement: LayerTransform?)? {
        (entries[id]?.result ?? seeds[id]).map { ($0.image, $0.inset, $0.placement) }
    }

    func prepare(layers: [ImageLayer]) {
        let ids = Set(layers.filter { $0.effects?.visible.isEmpty == false }.map(\.id))
        for id in Array(entries.keys) where !ids.contains(id) { entries.removeValue(forKey: id)?.request.cancel() }
        for id in Array(seeds.keys) where !ids.contains(id) { seeds.removeValue(forKey: id) }
        // Share a ~64 MiB output budget across all effect layers. Do not evict visible layers in a
        // redraw cycle: that would repeatedly rebuild evicted previews when more layers are visible.
        sideLimit = min(1536, max(32, Int(sqrt(Double(16_777_216) / Double(max(1, ids.count))))))
    }

    func preview(for layer: ImageLayer, mask: CGImage?, transform: LayerTransform, maskPlacement: LayerTransform?,
                 completion: @escaping @MainActor @Sendable () -> Void) -> (image: CGImage, inset: CGFloat, placement: LayerTransform?)? {
        guard let image = layer.asset?.image, let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid else {
            entries.removeValue(forKey: layer.id)?.request.cancel()
            return nil
        }
        let request = Request(image: image, mask: mask, maskSource: layer.mask?.enabledImage,
                              placement: maskPlacement, transform: transform, effects: effects, sideLimit: sideLimit)
        if let entry = entries[layer.id], entry.request.matches(request) {
            return entry.result.map { ($0.image, $0.inset, $0.placement) }
        }
        let old = entries[layer.id]
        old?.request.cancel()
        // Keep effects visible during transforms and setting changes on the same pixels.
        // For an independently placed mask, retain the last preview until its updated
        // coverage finishes rendering on the worker.
        let previous = old.flatMap { entry in
            entry.request.image === image && entry.request.maskSource === request.maskSource
                && entry.request.effects.kinds == effects.kinds ? entry.result : nil
        } ?? seeds[layer.id]
        entries[layer.id] = Entry(request: request, result: previous)
        let layerID = layer.id
        Self.worker.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard !request.isCancelled else { return }
            let result = autoreleasepool { try? Self.render(request) }
            guard !request.isCancelled else { return }
            Task { @MainActor [weak self] in
                guard let self, self.entries[layerID]?.request.id == request.id else { return }
                self.entries[layerID]?.result = result
                if result != nil { self.seeds.removeValue(forKey: layerID) }
                completion()
            }
        }
        return previous.map { ($0.image, $0.inset, $0.placement) }
    }

    nonisolated private static func render(_ request: Request) throws -> Result {
        let image = request.image
        let margin = LayerEffectsRenderer.margin(for: request.effects)
        // Include stroke/shadow margins in the budget; even a 500px stroke stays bounded.
        let factor = min(1, CGFloat(request.sideLimit - 8) / (CGFloat(max(image.width, image.height)) + 2 * margin))
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        func resized(_ source: CGImage, mask: Bool) throws -> CGImage {
            let context = try BrushRaster.context(width: width, height: height, mask: mask)
            context.interpolationQuality = .high
            // For a grayscale mask, draw its stored coverage values directly.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let result = context.makeImage() else { throw ExportError.render }
            return result
        }
        let pixels = factor == 1 ? image : try resized(image, mask: false)
        let mask = try request.mask.map { factor == 1 ? $0 : try resized($0, mask: true) }
        var effects = request.effects
        effects.stroke?.size *= factor
        effects.shadow?.distance *= factor
        effects.shadow?.blur *= factor
        let rendered = try LayerEffectsRenderer.render(pixels, mask: mask, effects: effects)
        return Result(image: rendered.image, inset: rendered.inset)
    }
}
