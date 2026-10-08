import AppKit
import UniformTypeIdentifiers

/// A layer out for editing in another app, waiting for that app's result.
struct ExternalEditJob: Identifiable {
    let id = UUID()
    let documentID: UUID
    let layerID: UUID
    let app: ExternalEditorApp
    /// The file the layer was written to; the app saves its result beside it.
    let source: URL
    let folder: URL
    /// Holds the folder's sandbox grant for as long as the edit is out.
    let scoped: Bool
    let startedAt: Date
    /// The pixels and placement sent out. A layer still holding both takes the result in place; one changed in the
    /// meantime keeps its changes, and the result arrives as a new layer instead.
    let original: CGImage
    let transform: LayerTransform
    /// How the result comes back, as chosen when the layer was sent.
    var options = ExternalEditOptions()
    var isImporting = false
}

/// How an external edit's result is put into the document.
struct ExternalEditOptions: Equatable {
    /// Add the result as a new layer above the original, which is hidden rather than replaced.
    var keepsOriginal = true
    /// Scale the document so the result shows at 100%: an upscale then grows the canvas instead of shrinking the
    /// result to the layer's old size. Only transforms change, so every other layer keeps its pixels.
    var enlargesCanvas = true
}

/// Edit in External App: sends the active layer to another app (Topaz Gigapixel, say, to upscale it) and brings
/// the app's result back into the document, as one undo step: as a new layer over the original (hidden, kept) or in
/// its place, with the document scaled so an upscaled result shows at its full size, or at the layer's old size.
extension EditorSession {
    var canEditExternally: Bool { externalEdit == nil && canAdjustColors }

    func editExternally(in app: ExternalEditorApp) async {
        guard canEditExternally else { NSSound.beep(); return }
        commitTransform()
        if gradientEdit != nil { resolveGradient() }
        guard let documentID = document?.id, let layer = activeLayer, let image = layer.asset?.image else { return }
        var chosen = ExternalEditFolder.saved()
        if chosen == nil { chosen = await ExternalEditFolder.choose(current: nil) }
        guard let folder = chosen else { return }
        // The folder panel may have been up a while: only go on with the same layer, untouched.
        guard externalEdit == nil, document?.id == documentID, activeLayer?.asset?.image === image else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        let source = folder.appendingPathComponent(ExternalEditMatch.sourceName(for: layer.name))
        do {
            try await Task.detached(priority: .userInitiated) { try ExternalEditBridge.write(image, to: source) }.value
        } catch {
            if scoped { folder.stopAccessingSecurityScopedResource() }
            externalEditError = error.localizedDescription
            return
        }
        let job = ExternalEditJob(documentID: documentID, layerID: layer.id, app: app, source: source, folder: folder,
                                  scoped: scoped, startedAt: Date(), original: image, transform: layer.transform,
                                  options: ExternalEditSettings.shared.options)
        externalEdit = job
        do { try await ExternalEditBridge.open(source, in: app) } catch {
            finishExternalEdit(job)
            externalEditError = error.localizedDescription
            return
        }
        watchForExternalResult(job)
    }

    /// Picks an app that isn't one of the presets, remembers it, and sends the layer to it.
    func editExternallyInOtherApp() async {
        guard canEditExternally else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "Choose an App to Edit the Layer In"
        panel.prompt = "Choose"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let app = ExternalEditorApp(url: url)
        ExternalEditorApp.remember(app)
        await editExternally(in: app)
    }

    func chooseExternalEditFolder() async {
        _ = await ExternalEditFolder.choose(current: ExternalEditFolder.saved())
    }

    func cancelExternalEdit() {
        guard let job = externalEdit, !job.isImporting else { return }
        finishExternalEdit(job)
    }

    /// For a result saved somewhere other than the folder: asks for the file and takes it as the result.
    func importExternalResultManually() async {
        guard let job = externalEdit, !job.isImporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.directoryURL = job.folder
        panel.title = "Choose \(job.app.name)’s Result"
        panel.prompt = "Import"
        guard await panel.begin() == .OK, let url = panel.url, externalEdit?.id == job.id else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await importExternalResult(from: url)
    }

    private func watchForExternalResult(_ job: ExternalEditJob) {
        externalEditTask?.cancel()
        let id = job.id, documentID = job.documentID
        // Still wanted while this edit is the one out and its project is still open.
        let wanted: @MainActor @Sendable () -> Bool = { [weak self] in
            self?.externalEdit?.id == id && self?.document?.id == documentID
        }
        externalEditTask = Task { [weak self] in
            let found = await ExternalEditBridge.waitForResult(in: job.folder, for: job.source, startedAt: job.startedAt) {
                await wanted()
            }
            guard let self, self.externalEdit?.id == id else { return }
            if let found { await self.importExternalResult(from: found) }
            // Closed or replaced while the app had it: nothing to bring back.
            else if !Task.isCancelled { self.finishExternalEdit(job) }
        }
    }

    func importExternalResult(from url: URL) async {
        guard var job = externalEdit, !job.isImporting else { return }
        job.isImporting = true
        externalEdit = job
        defer { finishExternalEdit(job) }
        // A result replacing the layer's own pixels frees those; one added beside them doesn't.
        let used = document?.layers.reduce(0) { total, layer in
            guard layer.id != job.layerID || job.options.keepsOriginal, let image = layer.asset?.image else { return total }
            return total + image.width * image.height
        } ?? 0
        do {
            let decoded = try await ImageImporter.shared.decode(url, remainingPixels: DocumentLimits.documentPixelBudget - used)
            let original = job.original
            let asset = try await Task.detached(priority: .userInitiated) { () -> ImportedImage in
                let image = try ExternalEditPixels.keepingTransparency(of: original, in: decoded.image)
                return image === decoded.image ? decoded
                    : ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: decoded.name)
            }.value
            try applyExternalResult(asset, for: job)
            // The result is in: bring Compositor forward from the other app to show it.
            NSApp.activate()
        } catch { externalEditError = error.localizedDescription }
    }

    /// Puts the app's result into the document as `job.options` say, as one undo step. When the layer still holds
    /// what was sent, the result either replaces its pixels or goes in a new layer just above it that takes over its
    /// opacity, blend mode, mask, effects and clipping, the original hidden beneath it. When the layer changed in the
    /// meantime (or went), the result is a plain new layer where the original was, and the changes are kept.
    func applyExternalResult(_ asset: ImportedImage, for job: ExternalEditJob) throws {
        guard let document, document.id == job.documentID else { return }
        let index = document.layers.firstIndex { $0.id == job.layerID }
        let unchanged = index.map { document.layers[$0].asset?.image === job.original && document.layers[$0].transform == job.transform } ?? false
        // How much the document grows for the result to show at 100%: its width over the width the layer had.
        var scale: CGFloat = 1
        var next = document
        if job.options.enlargesCanvas, job.transform.size.width > 0 {
            let factor = CGFloat(asset.image.width) / job.transform.size.width
            if factor > 1.001 {
                if let grown = document.scaled(by: factor) {
                    next = grown
                    scale = factor
                } else {
                    externalEditError = "The result was placed at the layer’s size: showing it at 100% would take the canvas past \(DocumentLimits.maxSide.formatted()) pixels."
                }
            }
        }
        // Where the result goes: where the layer was sent from, scaled with the document; at 100%, exactly its size.
        var placed = job.transform
        placed.origin = CGPoint(x: placed.origin.x * scale, y: placed.origin.y * scale)
        placed.size = scale == 1 ? placed.size : CGSize(width: asset.image.width, height: asset.image.height)
        // Effects are sized in the layer's own pixels, so they grow with its resolution to look the same.
        let pixelRatio = CGFloat(asset.image.width) / CGFloat(max(1, job.original.width))
        var resultID: UUID
        if let index, unchanged {
            let current = next.layers[index]
            let mask = try current.mask.map { try ExternalEditPixels.mask($0, fitting: asset.image) }
            let effects = current.effects.map { $0.scaled(by: pixelRatio) }
            if job.options.keepsOriginal {
                let layer = ImageLayer(id: UUID(), asset: asset, name: "\(current.name) (\(job.app.name))", isVisible: current.isVisible,
                    transform: placed, parentID: current.parentID, isGroup: false, opacity: current.opacity,
                    blendMode: current.blendMode, mask: mask, maskSourceID: current.maskSourceID, effects: effects)
                next.layers[index].isVisible = false
                // Layers clipped to the original now clip to the result that stands in for it.
                for other in next.layers.indices where next.layers[other].maskSourceID == current.id { next.layers[other].maskSourceID = layer.id }
                next.layers.insert(layer, at: index + 1)
                resultID = layer.id
            } else {
                next.layers[index] = ImageLayer(id: current.id, asset: asset, name: current.name, isVisible: current.isVisible,
                    transform: placed, parentID: current.parentID, isGroup: false, opacity: current.opacity,
                    blendMode: current.blendMode, mask: mask, maskSourceID: current.maskSourceID, effects: effects)
                resultID = current.id
            }
        } else {
            let original = index.map { next.layers[$0] }
            let layer = ImageLayer(id: UUID(), asset: asset, name: "\(original?.name ?? asset.name) (\(job.app.name))",
                                   isVisible: true, transform: placed, parentID: original?.parentID)
            next.layers.insert(layer, at: index.map { $0 + 1 } ?? next.layers.count)
            resultID = layer.id
        }
        beginEdit("Edit in \(job.app.name)")
        self.document = next
        selectLayers([resultID], primary: resultID)
        endEdit()
        if scale != 1 { viewport.fit(documentSize: next.size) }
    }

    private func finishExternalEdit(_ job: ExternalEditJob) {
        guard externalEdit?.id == job.id else { return }
        externalEditTask?.cancel()
        externalEditTask = nil
        externalEdit = nil
        // The file sent out was Compositor's own; the app's result is the person's and stays.
        try? FileManager.default.removeItem(at: job.source)
        if job.scoped { job.folder.stopAccessingSecurityScopedResource() }
    }
}

/// Pixel work for bringing a result back.
nonisolated enum ExternalEditPixels {
    /// Apps that can't write transparency hand back a flattened image. When `original` had transparent pixels and
    /// `result` has none, its alpha is put back, scaled up to the result's size.
    static func keepingTransparency(of original: CGImage, in result: CGImage) throws -> CGImage {
        guard try !isOpaque(original), try isOpaque(result) else { return result }
        let width = result.width, height = result.height, bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ExportError.render }
        context.interpolationQuality = .high
        context.draw(result, in: bounds)
        context.setBlendMode(.destinationIn)
        context.draw(original, in: bounds)
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    static func isOpaque(_ image: CGImage) throws -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst: return true
        default: break
        }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            let data = context.data else { throw ExportError.render }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let line = bytes + row * context.bytesPerRow
            for column in 0..<width where line[column * 4 + 3] != 255 { return false }
        }
        return true
    }

    /// `mask` resampled onto the result's pixel grid when it covers the layer's own grid, so painting it lines up
    /// with the new pixels. Uniform masks and masks placed apart from the layer are resolution independent.
    static func mask(_ mask: LayerMask, fitting image: CGImage) throws -> LayerMask {
        let pixels = mask.asset.image
        guard mask.placement == nil, pixels.width > 1 || pixels.height > 1,
              pixels.width != image.width || pixels.height != image.height else { return mask }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ExportError.render }
        context.interpolationQuality = .high
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let resampled = context.makeImage() else { throw ExportError.render }
        return mask.replacing(try LayerMask.asset(from: resampled))
    }
}

extension CanvasDocument {
    /// This document `factor` times larger: the canvas, and every layer's placement, mask placement, guide and the
    /// selection with it. Layers keep their pixels (they are drawn larger), and blurs measured in document pixels
    /// grow to match. Nil when the canvas would pass the size limit.
    func scaled(by factor: CGFloat) -> CanvasDocument? {
        let newWidth = Int((CGFloat(width) * factor).rounded()), newHeight = Int((CGFloat(height) * factor).rounded())
        guard factor.isFinite, factor > 0, (1...DocumentLimits.maxSide).contains(newWidth),
              (1...DocumentLimits.maxSide).contains(newHeight) else { return nil }
        func scaled(_ transform: LayerTransform) -> LayerTransform {
            var result = transform
            result.origin = CGPoint(x: transform.origin.x * factor, y: transform.origin.y * factor)
            result.size = CGSize(width: transform.size.width * factor, height: transform.size.height * factor)
            return result
        }
        // A copy, so whatever else the document carries comes along unchanged.
        var result = self
        result.width = newWidth
        result.height = newHeight
        result.layers = layers.map { layer in
            var scaledLayer = layer
            scaledLayer.transform = scaled(layer.transform)
            if let placement = layer.mask?.placement { scaledLayer.mask?.placement = scaled(placement) }
            if var adjustment = layer.adjustment {
                if let radius = adjustment.blurRadius { adjustment.blurRadius = min(250, radius * factor) }
                if let distance = adjustment.motionDistance { adjustment.motionDistance = min(2000, distance * factor) }
                scaledLayer.adjustment = adjustment
            }
            return scaledLayer
        }
        guard result.layers.allSatisfy({ $0.transform.isValid }) else { return nil }
        result.guides = guides.map { $0.scaled(x: factor, y: factor) }
        result.selection = selection.map { selection in
            var transform = CGAffineTransform(scaleX: factor, y: factor)
            let path = selection.path.copy(using: &transform) ?? selection.path
            return DocumentSelection(path: path, antialiased: selection.antialiased, feather: selection.feather * factor)
        }
        return result
    }
}

extension LayerEffects {
    /// These effects for a layer with `factor` times the pixels: sizes, distances and blurs grow with it, so they
    /// look the same where the layer shows. Unchanged when that would pass an effect's limits.
    func scaled(by factor: CGFloat) -> LayerEffects {
        guard factor.isFinite, factor > 0, abs(factor - 1) > 0.001 else { return self }
        var result = self
        result.stroke?.size *= factor
        result.shadow?.distance *= factor
        result.shadow?.blur *= factor
        result.innerShadow?.distance *= factor
        result.innerShadow?.blur *= factor
        result.outerGlow?.size *= factor
        result.innerGlow?.size *= factor
        return result.isValid ? result : self
    }
}
