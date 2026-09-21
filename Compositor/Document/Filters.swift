import AppKit
import CoreImage
import Combine

/// Filters from the Filter menu. Each runs on the active image layer, inside the selection if
/// there is one, with a live preview and one undo step on OK.
nonisolated enum FilterKind: String, CaseIterable, Sendable {
    case gaussianBlur = "Gaussian Blur"
    case motionBlur = "Motion Blur"
    case addNoise = "Add Noise"
    case lensCorrection = "Lens Correction"
    case removeBackground = "Remove Background"
    case contentAwareFill = "Content-Aware Fill"
    case curves = "Curves"
    case exposure = "Exposure"
    case gradientMap = "Gradient Map"
    case grain = "Grain"
    var isAutomatic: Bool { self == .contentAwareFill || self == .removeBackground }
    /// Color adjustments: in the Image menu (and editable as adjustment layers), not under Filter.
    var isImageAdjustment: Bool { self == .curves || self == .exposure || self == .gradientMap || self == .grain }
}

/// Remove Background's two ways of working: Apple's own subject mask on its own, or that mask refined against the
/// layer's detail, which recovers hair and fur but takes longer.
nonisolated enum BackgroundQuality: String, CaseIterable, Sendable {
    case basic = "Basic"
    case advanced = "Advanced"
}

/// Every filter's settings; each filter reads only its own.
nonisolated struct FilterSettings: Equatable, Sendable {
    /// Gaussian Blur radius in layer pixels (the blur's standard deviation), 0.1–250.
    var radius: Double = 1
    /// Motion Blur direction in degrees, counterclockwise from horizontal as in Photoshop, −90–90.
    var angle: Double = 0
    /// Motion Blur streak length in layer pixels, 1–2000.
    var distance: Double = 10
    /// Add Noise strength as Photoshop's percentage, 0.1–400.
    var amount: Double = 10
    /// Add Noise distribution: Gaussian (more speckled) instead of Uniform.
    var gaussian = false
    /// Add Noise changes brightness only, the same amount on every channel.
    var monochromatic = false
    /// Lens Correction's Remove Distortion, −100–100: positive straightens barrel distortion
    /// (lines bowing outward), negative straightens pincushion (lines bowing inward).
    var distortion: Double = 0
    var curves = CurvesSettings()
    var exposure = ExposureSettings()
    var gradientMap = GradientMapSettings()
    var grain = GrainSettings()
    /// Remove Background: Basic is the quick subject mask; Advanced refines it (see the three settings below).
    var backgroundQuality: BackgroundQuality = .basic
    /// Remove Background: how far the mask is pulled onto the image's own edges (0 off, in layer pixels).
    var refineEdges: Double = 12
    /// Remove Background: pushes the mask's grays toward black and white, 0–100, clearing haze in thin areas.
    var matteContrast: Double = 25
    /// Remove Background: contracts (negative) or expands (positive) the mask edge, in layer pixels.
    var shiftEdge: Double = 0
    var normalized: Self {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        var result = self
        result.radius = clamp(radius, 0.1...250, 1)
        result.angle = clamp(angle, -90...90, 0)
        result.distance = clamp(distance, 1...2000, 10)
        result.amount = clamp(amount, 0.1...400, 10)
        result.distortion = clamp(distortion, -100...100, 0)
        result.refineEdges = clamp(refineEdges, 0...40, 12)
        result.matteContrast = clamp(matteContrast, 0...100, 25)
        result.shiftEdge = clamp(shiftEdge, -10...10, 0)
        result.exposure = exposure.normalized
        result.gradientMap = gradientMap.normalized
        result.grain = grain.normalized
        return result
    }
}

nonisolated struct FilterJob: @unchecked Sendable {
    let kind: FilterKind
    let image: CGImage
    let settings: FilterSettings
    /// Pixels in `image` per original layer pixel, so a downscaled preview blurs proportionally less.
    let scale: CGFloat
    let selection: SelectionClip?
    let mapping: CGAffineTransform
    /// Add Noise's random pattern: the same seed gives the same grain.
    var seed: UInt32 = 0
}

nonisolated enum PixelFilter {
    /// `image` cropped to the pixels that are actually there, with the transform that keeps them in place: a blur
    /// is given generous room to spread, and whatever it leaves empty is cut away again.
    static func trimmed(_ image: CGImage, placed: LayerTransform) throws -> (image: CGImage, transform: LayerTransform) {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: full, mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        var edges = [Int](repeating: 0, count: 4)
        brush_alpha_bounds(data.assumingMemoryBound(to: UInt8.self), image.width, image.height, context.bytesPerRow, &edges)
        let crop = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
        guard crop.width >= 1, crop.height >= 1, crop != full, let cropped = image.cropping(to: crop) else {
            return (image, placed)
        }
        var result = placed
        result.size = CGSize(width: crop.width * placed.size.width / full.width,
                             height: crop.height * placed.size.height / full.height)
        let toDocument = BrushRaster.pixelToDocument(placed, width: image.width, height: image.height)
        let middle = CGPoint(x: crop.midX, y: crop.midY).applying(toDocument)
        result.origin = CGPoint(x: middle.x - result.size.width / 2, y: middle.y - result.size.height / 2)
        return (cropped, result)
    }

    /// `CIMotionBlur`'s radius per pixel of streak length. Photoshop smears evenly along the whole
    /// distance; Core Image tapers like a Gaussian whose spread is about its radius (measured on a
    /// single dot). An even streak of length d spreads d / √12, so this radius matches its spread.
    static let motionRadiusPerPixel = 1 / 12.0.squareRoot()
    /// Remove Distortion at ±100 moves the image's corners by this share of their distance from the center.
    static let lensStrength = 0.35

    static func run(_ job: FilterJob) throws -> CGImage {
        let settings = job.settings.normalized
        let width = job.image.width, height = job.image.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // Not clamped: a blur softens the layer's edges and spreads into the room made for it, rather than
        // smearing the border outwards and stopping at it.
        let edges = CIImage(cgImage: job.image)
        let image: CGImage
        switch job.kind {
        case .curves: image = try settings.curves.apply(job.image)
        case .exposure: image = try settings.exposure.apply(job.image)
        case .gradientMap: image = try settings.gradientMap.apply(job.image)
        // Grain sits in layer pixels; the job's seed gives each application its own pattern.
        case .grain: image = try settings.grain.apply(job.image, unitsPerPixel: 1 / job.scale, seed: job.seed)
        case .removeBackground:
            image = try SubjectRemoval.run(job.image, settings: settings)
        case .contentAwareFill:
            image = try ContentFill.run(job)
        case .gaussianBlur:
            let blurred = edges.applyingGaussianBlur(sigma: settings.radius * job.scale)
            image = try PixelAdjust.render(blurred.cropped(to: extent), width: width, height: height, isMask: false)
        case .motionBlur:
            // Core Image's y axis points up, so its counterclockwise angle matches Photoshop's.
            let streaked = edges.applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: settings.distance * job.scale * motionRadiusPerPixel,
                kCIInputAngleKey: settings.angle * .pi / 180,
            ])
            image = try PixelAdjust.render(streaked.cropped(to: extent), width: width, height: height, isMask: false)
        case .addNoise:
            // C, not Core Image: its random generator is uniform only, and Gaussian noise is needed too.
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            BrushRaster.draw(job.image, in: extent, mask: false, context: context)
            guard let data = context.data else { throw ExportError.render }
            noise_add(data.assumingMemoryBound(to: UInt8.self), width, height, context.bytesPerRow,
                      Float(settings.amount), settings.gaussian ? 1 : 0, settings.monochromatic ? 1 : 0, job.seed)
            guard let noisy = context.makeImage() else { throw ExportError.render }
            image = noisy
        case .lensCorrection:
            // The warp is relative to the image's own size, so a downscaled preview bends the same way.
            let source = try BrushRaster.context(width: width, height: height, mask: false)
            BrushRaster.draw(job.image, in: extent, mask: false, context: source)
            let destination = try BrushRaster.context(width: width, height: height, mask: false)
            guard let from = source.data, let into = destination.data else { throw ExportError.render }
            lens_distort(from.assumingMemoryBound(to: UInt8.self), into.assumingMemoryBound(to: UInt8.self),
                         width, height, source.bytesPerRow, settings.distortion / 100 * lensStrength)
            guard let corrected = destination.makeImage() else { throw ExportError.render }
            image = corrected
        }
        guard let selection = job.selection else { return image }
        return try PixelAdjust.blend(image, over: job.image, through: selection, pixelToDocument: job.mapping, isMask: false)
    }
}

final class FilterEdit: ObservableObject {
    let kind: FilterKind
    let layerID: UUID
    let original: ImportedImage
    let transform: LayerTransform
    let selection: SelectionClip?
    @Published var mapping: CGAffineTransform
    var previewSource: CGImage
    var previewScale: CGFloat
    var previewMapping: CGAffineTransform
    /// A filter reaching past the layer's edge — Content-Aware Fill over a selection, a blur spreading outwards —
    /// works on the layer's pixels padded out, and on the transform placing that larger grid.
    @Published var grownImage: CGImage? = nil
    @Published var grownTransform: LayerTransform? = nil
    /// How far the padding reaches beyond the layer on every side, in layer pixels.
    @Published var grownMargin: CGFloat = 0
    @Published var settings: FilterSettings
    @Published var preview = true
    @Published var committing = false
    @Published var previewError: String?
    @Published var preparing = false
    /// Add Noise's grain, fixed while the panel is open so changing Amount doesn't reshuffle it.
    let seed = UInt32.random(in: .min ... .max)
    var preparedPreview: CGImage?
    /// The settings `preparedPreview` was made with, for the automatic filters that have settings of their own.
    var preparedSettings: FilterSettings?
    var pending: FilterJob?
    var previewTask: Task<Void, Never>?
    /// Previews render from a copy no larger than this on its longest side.
    static let previewLimit: CGFloat = 2048

    /// `growingTo`: a document area the layer's grid should cover (Content-Aware Fill's selection on the canvas).
    /// A blur grows the grid by its own reach instead, and again if its amount is raised.
    init(kind: FilterKind, layer: ImageLayer, selection: SelectionClip?, settings: FilterSettings, growingTo area: CGRect? = nil) throws {
        guard let asset = layer.asset else { throw ProjectError.invalid }
        self.kind = kind
        self.settings = settings.normalized
        layerID = layer.id; original = asset; transform = layer.transform; self.selection = selection
        let ready = try Self.prepared(kind: kind, from: asset.image, placed: layer.transform)
        mapping = ready.mapping
        previewSource = ready.previewSource
        previewScale = ready.previewScale
        previewMapping = ready.previewMapping
        if let area {
            let toPixels = BrushRaster.pixelToDocument(layer.transform, width: asset.image.width, height: asset.image.height).inverted()
            try grow(to: area.applying(toPixels).integral)
        }
        try growForBlur()
    }

    /// The room a blur needs around the layer: about three standard deviations, or half a streak.
    static func blurMargin(_ kind: FilterKind, _ settings: FilterSettings) -> CGFloat {
        switch kind {
        case .gaussianBlur: return CGFloat(settings.radius * 3 + 2)
        case .motionBlur: return CGFloat(settings.distance / 2 + 2)
        default: return 0
        }
    }

    /// Pads the layer out so the blur has somewhere to spread; only ever grows, so easing the amount back off
    /// doesn't rebuild anything.
    func growForBlur() throws {
        let margin = Self.blurMargin(kind, settings)
        guard margin > grownMargin else { return }
        let bounds = CGRect(x: 0, y: 0, width: original.image.width, height: original.image.height)
        try grow(to: bounds.insetBy(dx: -margin.rounded(.up), dy: -margin.rounded(.up)))
    }

    /// The layer's pixels drawn into a grid covering `extent` (layer pixels), with the transform that places it.
    private func grow(to extent: CGRect) throws {
        let bounds = CGRect(x: 0, y: 0, width: original.image.width, height: original.image.height)
        let target = bounds.union(extent).integral
        guard target != bounds else { return }
        guard target.width <= 30_000, target.height <= 30_000, target.width * target.height <= 100_000_000 else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: Int(target.width), height: Int(target.height), mask: false)
        let inside = bounds.offsetBy(dx: -target.minX, dy: -target.minY)
        if let raster = original.raster { raster.draw(in: inside, context: context) }
        else { BrushRaster.draw(original.image, in: inside, mask: false, context: context) }
        guard let image = context.makeImage() else { throw ExportError.render }
        let toDocument = BrushRaster.pixelToDocument(transform, width: original.image.width, height: original.image.height)
        var expanded = transform
        expanded.size = CGSize(width: target.width * transform.size.width / bounds.width,
                               height: target.height * transform.size.height / bounds.height)
        let middle = CGPoint(x: target.midX, y: target.midY).applying(toDocument)
        expanded.origin = CGPoint(x: middle.x - expanded.size.width / 2, y: middle.y - expanded.size.height / 2)
        grownImage = image
        grownTransform = expanded
        grownMargin = min(bounds.minX - target.minX, bounds.minY - target.minY,
                          target.maxX - bounds.maxX, target.maxY - bounds.maxY)
        try prepare(from: image, placed: expanded)
    }

    /// What the filter and its preview read: the full-size grid, and a copy no larger than `previewLimit` for
    /// everything but the filters that must be made at full size.
    private static func prepared(kind: FilterKind, from source: CGImage, placed: LayerTransform) throws
        -> (mapping: CGAffineTransform, previewSource: CGImage, previewScale: CGFloat, previewMapping: CGAffineTransform) {
        let mapping = BrushRaster.pixelToDocument(placed, width: source.width, height: source.height)
        // Noise and grain preview at full size: grain made on a smaller copy would look coarser once enlarged.
        let factor = [.addNoise, .grain, .contentAwareFill, .removeBackground].contains(kind)
            ? 1 : min(1, previewLimit / CGFloat(max(source.width, source.height)))
        guard factor < 1 else { return (mapping, source, 1, mapping) }
        let w = max(1, Int(CGFloat(source.width) * factor)), h = max(1, Int(CGFloat(source.height) * factor))
        let context = try BrushRaster.context(width: w, height: h, mask: false)
        BrushRaster.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h), mask: false, context: context)
        guard let small = context.makeImage() else { throw ExportError.render }
        return (mapping, small, CGFloat(w) / CGFloat(source.width),
                BrushRaster.pixelToDocument(placed, width: w, height: h))
    }
    private func prepare(from source: CGImage, placed: LayerTransform) throws {
        let ready = try Self.prepared(kind: kind, from: source, placed: placed)
        mapping = ready.mapping
        previewSource = ready.previewSource
        previewScale = ready.previewScale
        previewMapping = ready.previewMapping
    }

    func previewImage(for id: UUID) -> CGImage? { preview && id == layerID ? preparedPreview : nil }
    var previewJob: FilterJob {
        FilterJob(kind: kind, image: previewSource, settings: settings, scale: previewScale, selection: selection,
                  mapping: previewMapping, seed: seed)
    }
}

extension EditorSession {
    var canContentAwareFill: Bool {
        canAdjustColors && !isMaskSelected && selection?.isEmpty == false && filterEdit == nil && hueSaturation == nil
    }
    func beginFilter(_ kind: FilterKind) {
        if kind == .contentAwareFill && !canContentAwareFill { return }
        guard filterEdit == nil, hueSaturation == nil, canAdjustColors else { NSSound.beep(); return }
        if gradientEdit != nil {
            Task { await commitGradient(); beginFilter(kind) }
            return
        }
        commitTransform(); cancelCrop(); cancelLasso()
        guard let layer = activeLayer, let document else { return }
        do {
            var settings = filterSettings
            // Gradient Map starts from the foreground and background colors, as in Photoshop.
            if kind == .gradientMap {
                settings.gradientMap = GradientMapSettings(shadows: AdjustmentColor(foregroundColor), highlights: AdjustmentColor(backgroundColor))
            }
            // Content-Aware Fill extends the layer over any of the selection on the canvas past its edge.
            let area = kind == .contentAwareFill
                ? selection.map { $0.path.boundingBoxOfPath.intersection(CGRect(origin: .zero, size: document.size)) }.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
                : nil
            let edit = try FilterEdit(kind: kind, layer: layer, selection: selection?.clip(canvas: document.size), settings: settings, growingTo: area)
            filterEdit = edit
            updateFilter(edit.settings, preview: true)
        } catch { brushError = error.localizedDescription }
    }

    func updateFilter(_ settings: FilterSettings, preview: Bool) {
        guard let edit = filterEdit, !edit.committing else { return }
        edit.settings = settings.normalized
        edit.preview = preview
        // A bigger blur needs more room around the layer than it was given.
        if FilterEdit.blurMargin(edit.kind, edit.settings) > edit.grownMargin {
            do { try edit.growForBlur(); edit.preparedPreview = nil }
            catch { brushError = error.localizedDescription }
        }
        if previewAdjustmentEditing(preview: preview) { return }
        if edit.kind.isAutomatic, edit.preparedPreview != nil, edit.preparedSettings == edit.settings { brushRevision += 1; return }
        guard preview else {
            edit.pending = nil; edit.preparedPreview = nil; brushRevision += 1
            return
        }
        edit.pending = edit.previewJob
        renderFilterPreview(edit)
    }

    /// Renders the newest settings; changes that arrive mid-render wait for it rather than
    /// cancelling it, so dragging a slider keeps the canvas updating.
    private func renderFilterPreview(_ edit: FilterEdit) {
        guard filterEdit === edit, edit.previewTask == nil, let job = edit.pending else { return }
        edit.pending = nil
        edit.preparing = true
        edit.previewError = nil
        edit.previewTask = Task { @MainActor [weak self, weak edit] in
            let result = await Task.detached(priority: .userInitiated) {
                do { return (Optional(try PixelFilter.run(job)), Optional<String>.none) }
                catch { return (Optional<CGImage>.none, Optional(error.localizedDescription)) }
            }.value
            guard let self, let edit, self.filterEdit === edit, !Task.isCancelled else { return }
            edit.previewTask = nil
            edit.preparing = false
            edit.previewError = result.1
            if edit.preview || edit.kind.isAutomatic { edit.preparedPreview = result.0; edit.preparedSettings = job.settings; self.brushRevision += 1 }
            self.renderFilterPreview(edit)
        }
    }

    func cancelFilter() {
        // A Gradient Map color still being picked goes with the panel.
        if case .gradientMap = colorPicker?.target { closeColorPicker(commit: false) }
        if finishAdjustmentEditing(commit: false) { return }
        guard let edit = filterEdit, !edit.committing else { return }
        edit.previewTask?.cancel()
        filterEdit = nil
        brushRevision += 1
    }

    func commitFilter() async {
        if case .gradientMap = colorPicker?.target { closeColorPicker(commit: true) }
        if finishAdjustmentEditing(commit: true) { return }
        guard let edit = filterEdit, !edit.committing else { return }
        if edit.kind.isAutomatic {
            await edit.previewTask?.value
            guard filterEdit === edit, !edit.committing, edit.preparedPreview != nil, edit.previewError == nil else { return }
            // Remove Background masks from the full-size image, so a preview made at preview size is fine to discard.
        }
        // No distortion to remove: close as Cancel does, without an undo step.
        if (edit.kind == .lensCorrection && edit.settings.distortion == 0)
            || (edit.kind == .exposure && edit.settings.exposure == ExposureSettings())
            || (edit.kind == .grain && edit.settings.grain.amount == 0) { cancelFilter(); return }
        edit.committing = true
        edit.previewTask?.cancel()
        filterSettings = edit.settings
        isProjectBusy = true
        // The preview stays up until the result is on the layer, so the canvas never flashes the original.
        defer { filterEdit = nil; isProjectBusy = false; brushRevision += 1 }
        // Remove Background masks the background out rather than erasing it, so it can be brought back at any time
        // by painting the mask, disabling it, or deleting it.
        if edit.kind == .removeBackground { await commitBackgroundMask(edit); return }
        let job = FilterJob(kind: edit.kind, image: edit.grownImage ?? edit.original.image, settings: edit.settings, scale: 1,
                            selection: edit.selection, mapping: edit.mapping, seed: edit.seed)
        let cached = edit.kind.isAutomatic && edit.preparedSettings == edit.settings ? edit.preparedPreview : nil
        do {
            let grown = edit.grownTransform
            let spreads = edit.kind == .gaussianBlur || edit.kind == .motionBlur
            let made = try await Task.detached(priority: .userInitiated) { () -> (asset: ImportedImage, transform: LayerTransform?) in
                var image = try cached ?? PixelFilter.run(job)
                var placed = grown
                if spreads, let grown {
                    let trimmed = try PixelFilter.trimmed(image, placed: grown)
                    image = trimmed.image
                    placed = trimmed.transform
                }
                return (ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: job.kind.rawValue), placed)
            }.value
            let asset = made.asset
            guard let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
                  let current = document?.layers[index], current.asset?.image === edit.original.image,
                  current.transform == edit.transform else { return }
            // A grown layer's mask (covering the old grid) is carried onto the new one, its edge tone past the old edge.
            var mask = current.mask
            if let grown = edit.grownTransform, let owned = current.mask, owned.placement == nil,
               owned.asset.image.width > 1 || owned.asset.image.height > 1 {
                var enabled = owned
                enabled.isEnabled = true
                guard let carried = enabled.clipImage(placement: current.transform, over: grown,
                                                      width: asset.image.width, height: asset.image.height) else { throw ExportError.render }
                mask = owned.replacing(try LayerMask.asset(from: carried))
            }
            beginEdit(edit.kind.rawValue)
            document?.layers[index] = ImageLayer(id: current.id, asset: asset, name: current.name, isVisible: current.isVisible,
                transform: made.transform ?? current.transform, parentID: current.parentID, isGroup: false,
                opacity: current.opacity, blendMode: current.blendMode, mask: mask, maskSourceID: current.maskSourceID)
            endEdit()
        } catch { brushError = error.localizedDescription }
    }

    /// Remove Background as a layer mask: the subject stays white, the background black. A mask already on the layer
    /// (in the layer's own grid) is kept, hiding whatever either one hides; with a selection, only the selected part
    /// of the mask changes.
    private func commitBackgroundMask(_ edit: FilterEdit) async {
        let source = edit.original.image
        let current = document?.layers.first(where: { $0.id == edit.layerID })
        let existing = current?.mask.flatMap { owned in
            owned.placement == nil && owned.asset.image.width == source.width && owned.asset.image.height == source.height
                ? owned.asset.image : nil
        }
        let selection = edit.selection, mapping = edit.mapping, settings = edit.settings.normalized
        do {
            let made = try await Task.detached(priority: .userInitiated) { () -> CGImage in
                var mask = try SubjectRemoval.subjectMask(source, under: existing, settings: settings)
                if let selection, let base = existing {
                    mask = try PixelAdjust.blend(mask, over: base, through: selection, pixelToDocument: mapping, isMask: true)
                } else if let selection {
                    let white = try BrushRaster.context(width: source.width, height: source.height, mask: true)
                    white.setFillColor(gray: 1, alpha: 1)
                    white.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
                    guard let opaque = white.makeImage() else { throw ExportError.render }
                    mask = try PixelAdjust.blend(mask, over: opaque, through: selection, pixelToDocument: mapping, isMask: true)
                }
                return mask
            }.value
            guard let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
                  let layer = document?.layers[index], layer.asset?.image === edit.original.image,
                  layer.transform == edit.transform else { return }
            let asset = try LayerMask.asset(from: made)
            beginEdit(edit.kind.rawValue)
            document?.layers[index].mask = layer.mask.map { $0.replacing(asset) } ?? LayerMask(asset: asset)
            document?.layers[index].mask?.isEnabled = true
            isMaskSelected = true
            endEdit()
        } catch { brushError = error.localizedDescription }
    }
}
