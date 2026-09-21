import AppKit
import UniformTypeIdentifiers

/// An open Generative Fill, Remove or Generative Expand: what was selected when it began, what has been
/// generated so far, and which result shows on the canvas. Nothing reaches the document until it is kept.
@Observable
final class GenerativeEdit {
    struct Reference: Identifiable {
        let id = UUID()
        let thumbnail: CGImage
        let attachment: GenerativeAttachment
    }
    /// A generated result, already in the form it would join the document in.
    struct Variation: Identifiable {
        let layer: ImageLayer
        var id: UUID { layer.id }
    }

    let mode: GenerativeMode
    let documentID: UUID
    let canvasSize: CGSize
    /// What is to change, in document pixels. For Expand, the new area plus a strip of the old canvas to blend over.
    let selection: DocumentSelection
    /// Where pixels may be sampled and the layer may reach: the canvas, or for Expand the enlarged canvas.
    let bounds: CGRect
    let mask: GenerativeMask
    let layerMask: LayerMask
    let placement: GenerativePlacement

    var prompt = ""
    var references: [Reference] = []
    var count = 1
    var model: GenerativeModel
    /// Nil picks the smallest size that holds the region's detail.
    var size: GenerativeSize?
    var variations: [Variation] = []
    var selectedID: UUID?
    var isGenerating = false
    /// The first request waits here until the user has read what is sent, and at whose cost.
    var needsDisclosure = false
    var needsKey = false
    var error: String?
    @ObservationIgnored var task: Task<Void, Never>?

    init(mode: GenerativeMode, document: CanvasDocument, selection: DocumentSelection, bounds: CGRect, mask: GenerativeMask,
         placement: GenerativePlacement, model: GenerativeModel) throws {
        self.mode = mode
        documentID = document.id
        canvasSize = document.size
        self.selection = selection
        self.bounds = bounds
        self.mask = mask
        layerMask = LayerMask(asset: try LayerMask.asset(from: mask.coverage))
        self.placement = placement
        self.model = model
    }

    var plan: GenerativePlan? {
        GenerativePlan.make(target: mask.rect, bounds: bounds, largest: model.largestSize, fixed: size.map { min($0, model.largestSize) })
    }
    var selected: Variation? { variations.first { $0.id == selectedID } }

    func layer(for image: ImportedImage, name: String) -> ImageLayer {
        ImageLayer(id: UUID(), asset: image, name: name, isVisible: true,
                   transform: LayerTransform(origin: mask.rect.origin, size: mask.rect.size), parentID: placement.parentID, mask: layerMask)
    }

    /// The document with `layer` where a kept result goes. The canvas shows this while the panel is open, and
    /// keeping a result stores it, so what is previewed is what is kept.
    func inserting(_ layer: ImageLayer, into document: CanvasDocument) -> CanvasDocument {
        var next = document
        next.layers.insert(layer, at: min(placement.insertIndex, next.layers.count))
        return next
    }
    func previewDocument(from document: CanvasDocument) -> CanvasDocument? {
        guard document.id == documentID, document.size == canvasSize, let layer = selected?.layer else { return nil }
        return inserting(layer, into: document)
    }
}

/// One round of generating, carried off the main actor: everything in it is a value or an immutable image.
nonisolated struct GenerativeJob: @unchecked Sendable {
    let mode: GenerativeMode
    let sample: CGImage
    let plan: GenerativePlan
    let selection: DocumentSelection
    let rect: CGRect
    let prompt: String
    let references: [GenerativeAttachment]
    let count: Int
    let model: GenerativeModel
    let key: String
    let provider: any GenerativeImageProvider

    enum Outcome: @unchecked Sendable {
        case image(ImportedImage)
        case failure(String)
        case cancelled
    }

    func run() async -> [Outcome] {
        let request: GenerativeRequest
        do {
            let picture = try GenerativeRaster.encoded(GenerativeRaster.resized(sample, to: plan.sendSize))
            let hint = try GenerativeRaster.encode(GenerativeRaster.hint(for: selection, plan: plan), as: .png)
            let target = CGRect(x: (rect.minX - plan.region.minX) / plan.region.width, y: (rect.minY - plan.region.minY) / plan.region.height,
                                width: rect.width / plan.region.width, height: rect.height / plan.region.height)
            request = GenerativeRequest(model: model,
                prompt: GenerativePrompt.make(mode, request: prompt, target: target, hasHint: true, references: references.count),
                image: GenerativeAttachment(data: picture.data, mimeType: picture.mimeType),
                hint: GenerativeAttachment(data: hint, mimeType: "image/png"),
                references: references, ratio: plan.ratio, size: plan.size)
        } catch { return [.failure(error.localizedDescription)] }
        // The models answer with one image a request; variations are requests side by side.
        return await withTaskGroup(of: Outcome.self) { group in
            for _ in 0..<max(1, count) { group.addTask { await one(request) } }
            var outcomes: [Outcome] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
    }

    private func one(_ request: GenerativeRequest) async -> Outcome {
        do {
            let data = try await provider.generate(request, key: key)
            try Task.checkCancellation()
            let answer = try await ImageImporter.shared.decode(data, name: mode.title)
            let image = try GenerativeRaster.layerImage(from: answer.image, plan: plan, rect: rect)
            return .image(ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: mode.title))
        } catch is CancellationError { return .cancelled }
        catch { return .failure(error.localizedDescription) }
    }
}

extension CanvasDocument {
    /// The document with `rect` of it as the canvas: layers, their moved-apart masks and the guides keep their
    /// place in the picture, no pixel is touched, and `rect` may reach past the old canvas.
    func recanvased(to rect: CGRect) -> CanvasDocument? {
        let rect = rect.integral
        guard (1...30_000).contains(Int(rect.width)), (1...30_000).contains(Int(rect.height)) else { return nil }
        var moved = layers
        for index in moved.indices {
            moved[index].transform.origin.x -= rect.minX
            moved[index].transform.origin.y -= rect.minY
            moved[index].mask?.placement?.origin.x -= rect.minX
            moved[index].mask?.placement?.origin.y -= rect.minY
            guard moved[index].transform.isValid else { return nil }
        }
        return CanvasDocument(id: id, width: Int(rect.width), height: Int(rect.height), layers: moved, resolution: resolution,
                              guides: guides.map { $0.offset(x: -rect.minX, y: -rect.minY) })
    }
}

extension EditorSession {
    func canBeginGenerative(_ mode: GenerativeMode) -> Bool {
        guard let document else { return false }
        let canvas = CGRect(origin: .zero, size: document.size)
        switch mode {
        case .fill, .remove:
            return canEditLayers && selection.map { !$0.isEmpty && $0.path.boundingBoxOfPath.intersects(canvas) } == true
        case .expand:
            guard canEditLayersIgnoringCrop, tool == .crop, let crop = cropRect, CropGeometry.valid(crop) else { return false }
            return !canvas.contains(crop)
        }
    }

    func beginGenerative(_ mode: GenerativeMode) {
        guard canBeginGenerative(mode), let document else { return }
        cancelLasso()
        let canvas = CGRect(origin: .zero, size: document.size)
        let target: DocumentSelection, bounds: CGRect, grow: CGFloat, feather: CGFloat
        if mode == .expand, let crop = cropRect?.integral {
            // The new area, and a strip of the old canvas beside it for the generated pixels to fade out over.
            let blend = min(48, max(8, (min(canvas.width, canvas.height) * 0.02).rounded()))
            var kept = canvas.intersection(crop)
            if kept.isNull { kept = .zero } else {
                let left = crop.minX < canvas.minX ? blend * 1.5 : 0, right = crop.maxX > canvas.maxX ? blend * 1.5 : 0
                let top = crop.minY < canvas.minY ? blend * 1.5 : 0, bottom = crop.maxY > canvas.maxY ? blend * 1.5 : 0
                kept = CGRect(x: kept.minX + left, y: kept.minY + top, width: kept.width - left - right, height: kept.height - top - bottom)
            }
            let area = CGPath(rect: crop, transform: nil)
            let path = kept.width > 0 && kept.height > 0 ? area.subtracting(CGPath(rect: kept, transform: nil), using: .winding) : area
            (target, bounds, grow, feather) = (DocumentSelection(path: path, antialiased: false), crop, 0, blend)
        } else {
            guard let selection else { return }
            let inside = selection.path.intersection(CGPath(rect: canvas, transform: nil), using: .winding)
            let box = inside.boundingBoxOfPath
            // A hard-edged selection gets a soft seam, and reaches a little past the outline so that an object's
            // fringe goes with it. A feathered one is taken as the user drew it.
            let soft = selection.feather > 0 ? selection.feather : min(24, max(2, (min(box.width, box.height) * 0.02).rounded()))
            (target, bounds, grow, feather) = (DocumentSelection(path: inside, antialiased: selection.antialiased), canvas,
                                               selection.feather > 0 ? 0 : soft, soft)
        }
        do {
            guard let mask = try GenerativeMask.make(target, grow: grow, feather: feather, limit: bounds) else { NSSound.beep(); return }
            let edit = try GenerativeEdit(mode: mode, document: document, selection: target, bounds: bounds, mask: mask,
                placement: GenerativePlacement.plan(document.layers.map(\.hierarchyRecord), activeID: activeLayerID),
                model: generativeSettings.model)
            generativeEdit = edit
            if mode == .remove { generate() }
        } catch { brushError = error.localizedDescription }
    }

    /// The picture the model is sent: the region as it looks from the new layer's place in the stack.
    private func generativeSample(_ document: CanvasDocument, _ edit: GenerativeEdit, _ plan: GenerativePlan) throws -> CGImage {
        var visible = document
        for index in visible.layers.indices where edit.placement.hiddenIDs.contains(visible.layers[index].id) {
            visible.layers[index].isVisible = false
        }
        let context = try BrushRaster.context(width: Int(plan.region.width), height: Int(plan.region.height), mask: false)
        context.translateBy(x: -plan.region.minX, y: -plan.region.minY)
        drawLiveComposite(visible, in: context)
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    func generate() {
        guard let edit = generativeEdit, !edit.isGenerating, let document, document.id == edit.documentID, let plan = edit.plan else { return }
        edit.error = nil
        edit.needsKey = false
        guard let key = generativeSettings.key, !key.isEmpty else {
            edit.needsKey = true
            edit.error = GenerativeError.missingKey.localizedDescription
            return
        }
        guard generativeSettings.hasAcceptedDisclosure else { edit.needsDisclosure = true; return }
        let job: GenerativeJob
        do {
            job = GenerativeJob(mode: edit.mode, sample: try generativeSample(document, edit, plan), plan: plan, selection: edit.selection,
                                rect: edit.mask.rect, prompt: edit.prompt, references: edit.references.map(\.attachment),
                                count: min(3, max(1, edit.count)), model: edit.model, key: key, provider: generativeSettings.provider)
        } catch { edit.error = error.localizedDescription; return }
        edit.isGenerating = true
        edit.task = Task { @MainActor [weak self, weak edit] in
            let work = Task.detached(priority: .userInitiated) { await job.run() }
            let outcomes = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, let edit, self.generativeEdit === edit, !Task.isCancelled else { return }
            edit.task = nil
            edit.isGenerating = false
            // Nothing can resize or swap the document while the panel is open; were it to happen, the results are for another picture.
            guard self.document?.id == edit.documentID, self.document?.size == edit.canvasSize else { self.cancelGenerative(); return }
            let name = edit.mode == .fill && !edit.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(edit.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) : edit.mode.title
            var failures: [String] = []
            for outcome in outcomes {
                switch outcome {
                case .image(let image): edit.variations.append(GenerativeEdit.Variation(layer: edit.layer(for: image, name: name)))
                case .failure(let reason): failures.append(reason)
                case .cancelled: break
                }
            }
            let made = outcomes.count - failures.count
            if made > 0 { edit.selectedID = edit.variations[edit.variations.count - made].id }
            if let reason = failures.first {
                edit.error = made > 0 ? "\(failures.count) of \(outcomes.count) did not finish. \(reason)" : reason
            }
            self.brushRevision += 1
        }
    }

    func acceptGenerativeDisclosure() {
        generativeSettings.hasAcceptedDisclosure = true
        generativeEdit?.needsDisclosure = false
        generate()
    }

    func selectVariation(_ id: UUID) {
        guard let edit = generativeEdit, edit.variations.contains(where: { $0.id == id }) else { return }
        edit.selectedID = id
        brushRevision += 1
    }

    /// Stops a request under way and keeps the panel open; the results so far stay.
    func stopGenerating() {
        guard let edit = generativeEdit, edit.isGenerating else { return }
        edit.task?.cancel()
        edit.task = nil
        edit.isGenerating = false
    }

    func cancelGenerative() {
        guard let edit = generativeEdit else { return }
        edit.task?.cancel()
        generativeEdit = nil
        brushRevision += 1
    }

    func keepGenerative() {
        guard let edit = generativeEdit, !edit.isGenerating, let layer = edit.selected?.layer, let document,
              document.id == edit.documentID, document.size == edit.canvasSize else { return }
        let pixels = { (images: [CGImage?]) in images.reduce(0) { $0 + ($1.map { $0.width * $0.height } ?? 0) } }
        let added = Int(edit.mask.rect.width * edit.mask.rect.height)
        guard pixels(document.layers.map { $0.asset?.image }) + added <= 100_000_000,
              pixels(document.layers.map { $0.mask?.asset.image }) + added <= 100_000_000, document.layers.count < 10_000,
              let canvas = edit.mode == .expand ? document.recanvased(to: edit.bounds) : document else {
            edit.error = ProjectError.tooLarge.localizedDescription
            return
        }
        var placed = layer
        if edit.mode == .expand {
            placed.transform.origin.x -= edit.bounds.minX
            placed.transform.origin.y -= edit.bounds.minY
        }
        finishOpacityEdit()
        beginEdit(edit.mode.title)
        var next = edit.inserting(placed, into: canvas)
        next.selection = nil
        self.document = next
        activeLayerID = placed.id
        endEdit()
        if edit.mode == .expand {
            cropRect = nil
            viewport.fit(documentSize: next.size)
        }
        generativeEdit = nil
        brushRevision += 1
    }

    /// Adds a picture to steer what is generated, reduced to a size worth sending.
    func addGenerativeReference(_ url: URL) async {
        guard let edit = generativeEdit, edit.references.count < GenerativeModel.referenceLimit else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let result: Result<GenerativeEdit.Reference, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let image = try await ImageImporter.shared.decode(url)
                let scale = min(1, 1024 / CGFloat(max(image.image.width, image.image.height)))
                let small = try GenerativeRaster.resized(image.image, to: CGSize(width: CGFloat(image.image.width) * scale, height: CGFloat(image.image.height) * scale))
                let encoded = try GenerativeRaster.encoded(small)
                return .success(GenerativeEdit.Reference(thumbnail: image.thumbnail, attachment: GenerativeAttachment(data: encoded.data, mimeType: encoded.mimeType)))
            } catch { return .failure(error) }
        }.value
        guard generativeEdit === edit else { return }
        switch result {
        case .success(let reference): if edit.references.count < GenerativeModel.referenceLimit { edit.references.append(reference) }
        case .failure(let error): edit.error = error.localizedDescription
        }
    }
}
