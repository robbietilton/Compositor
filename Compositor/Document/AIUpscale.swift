import AppKit
import CryptoKit

/// A model Enlarger downloads when the user asks: only its official release, checked against a pinned size and digest.
nonisolated struct AIModel: Sendable {
    let name: String
    let file: String
    let url: URL
    let size: Int
    let sha256: String
    let credit: String

    static let realESRGAN = AIModel(name: "Real-ESRGAN x4plus", file: "RealESRGAN_x4plus.pth",
        url: URL(string: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth")!,
        size: 67_040_989, sha256: "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1",
        credit: "Real-ESRGAN by Xintao Wang et al. · BSD 3-Clause License")

    func verifiedData(at url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue == size else { throw AIModelError.mismatch }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == size, digest == sha256 else { throw AIModelError.mismatch }
        return data
    }
}

nonisolated enum AIModelError: LocalizedError {
    case mismatch, documentChanged
    var errorDescription: String? {
        switch self {
        case .mismatch: "The model doesn't match the official release. Remove it and download it again."
        case .documentChanged: "The document changed while Enlarger was working. The result wasn't applied; try again."
        }
    }
}

/// Whether the model is on disk, and its download. Kept in the app's Application Support folder, outside documents.
@MainActor @Observable
final class AIModelStore {
    enum State: Equatable { case missing, downloading(Double), ready, failed(String) }
    static let shared = AIModelStore(model: .realESRGAN)
    let model: AIModel
    private(set) var state: State = .missing
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private var directory: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Models", isDirectory: true)
    }
    var fileURL: URL { directory.appendingPathComponent(model.file) }

    init(model: AIModel) {
        self.model = model
        state = FileManager.default.fileExists(atPath: fileURL.path) ? .ready : .missing
    }

    func download() {
        if case .downloading = state { return }
        state = .downloading(0)
        let model = model, destination = fileURL, directory = directory
        let task = URLSession.shared.downloadTask(with: model.url) { [weak self] location, response, error in
            // The temporary file goes away when this handler returns: check it and move it into place now.
            let result = Result<Void, Error> {
                if let error { throw error }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                _ = try model.verifiedData(at: location)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            }
            let store = self
            Task { @MainActor in store?.finish(result) }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted, store = self
            Task { @MainActor in
                if case .downloading = store?.state { store?.state = .downloading(fraction) }
            }
        }
        self.task = task
        task.resume()
    }

    func cancelDownload() { task?.cancel() }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
        AIUpscaleEngine.shared.forget()
        state = .missing
    }

    private func finish(_ result: Result<Void, Error>) {
        observation = nil
        task = nil
        switch result {
        case .success: state = .ready
        case .failure(let error as URLError) where error.code == .cancelled: state = .missing
        case .failure(let error): state = .failed(error.localizedDescription)
        }
    }
}

/// The loaded network, kept while the app runs so another upscale doesn't read and rebuild it.
nonisolated final class AIUpscaleEngine: @unchecked Sendable {
    static let shared = AIUpscaleEngine()
    private let lock = NSLock()
    private var upscaler: ESRGANUpscaler?
    private var loadedURL: URL?

    func upscaler(for url: URL) throws -> ESRGANUpscaler {
        try lock.withLock {
            let url = url.standardizedFileURL
            if let upscaler, loadedURL == url { return upscaler }
            let data = try AIModel.realESRGAN.verifiedData(at: url)
            let made = try ESRGANUpscaler(checkpoint: TorchCheckpoint(data: data))
            upscaler = made
            loadedURL = url
            return made
        }
    }
    func forget() { lock.withLock { upscaler = nil; loadedURL = nil } }
}

/// Stops an Enlarger run between tiles.
nonisolated final class UpscaleCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

extension EditorSession {
    /// The image layers Enlarger rebuilds with the network: visible pixel layers. Hidden ones (such as a Darkroom
    /// source kept under its result) and text or shape layers are only resampled, as Image Size does.
    var aiUpscaleTargets: [ImageLayer] {
        guard let document else { return [] }
        let visible = document.effectiveVisibleIDs
        return document.layers.filter { $0.asset != nil && !$0.isGroup && $0.liveText == nil && $0.liveShape == nil
            && visible.contains($0.id) }
    }
    var canAIUpscale: Bool { !aiUpscaleTargets.isEmpty }

    /// Check both the canvas and all intermediate AI images before an expensive GPU run.
    func validateAIUpscale(factor: Int) throws {
        guard let document else { return }
        _ = try ESRGANUpscaler.outputSize(width: document.width, height: document.height, factor: factor)
        var pixels = 0
        for layer in aiUpscaleTargets {
            guard let image = layer.asset?.image else { continue }
            let size = try ESRGANUpscaler.outputSize(width: image.width, height: image.height, factor: factor)
            let count = size.width * size.height
            guard count <= 100_000_000 - pixels else { throw ESRGANError.tooLarge }
            pixels += count
        }
    }

    /// The canvas enlarged `factor` (2 or 4) times. Every image layer's pixels are rebuilt by Real-ESRGAN first, then the
    /// Image Size resampler places them on the larger canvas, so the enlargement adds detail rather than interpolating it.
    /// Text, shape and adjustment layers and masks are resampled as Image Size does; layer effects are scaled to match.
    /// One undo step.
    func aiUpscale(factor: Int, model: URL, cancellation: UpscaleCancellation,
                   progress: @escaping @MainActor (Double, String) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await performAIUpscale(factor: factor, model: model, cancellation: cancellation, progress: progress)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func performAIUpscale(factor: Int, model: URL, cancellation: UpscaleCancellation,
                                 progress: @escaping @MainActor (Double, String) -> Void) async throws {
        guard let document, let snapshot = projectSnapshot() else { return }
        try validateAIUpscale(factor: factor)
        if cancellation.isCancelled { throw CancellationError() }
        let (width, height) = try ESRGANUpscaler.outputSize(width: document.width, height: document.height, factor: factor)
        let targets = aiUpscaleTargets
        guard !targets.isEmpty else { return }
        progress(0, "Loading the model…")
        let engine = try await Task.detached(priority: .userInitiated) { try AIUpscaleEngine.shared.upscaler(for: model) }.value
        if cancellation.isCancelled { throw CancellationError() }
        var images = snapshot.images
        let count = Double(targets.count)
        for (index, layer) in targets.enumerated() {
            if cancellation.isCancelled { throw CancellationError() }
            guard let asset = layer.asset else { continue }
            let label = targets.count == 1 ? "Enlarging \(layer.name)…" : "Enlarging \(layer.name) (\(index + 1) of \(targets.count))…"
            progress(Double(index) / count, label)
            let source = asset.image
            let upscaled = try await Task.detached(priority: .userInitiated) {
                try engine.upscale(source, factor: factor, progress: { share in
                    Task { @MainActor in
                        if !cancellation.isCancelled { progress((Double(index) + share) / count, label) }
                    }
                }, cancelled: { cancellation.isCancelled })
            }.value
            images[layer.id] = ImportedImage(image: upscaled, thumbnail: asset.thumbnail, name: asset.name)
        }
        if cancellation.isCancelled { throw CancellationError() }
        progress(1, "Enlarging the canvas…")
        let options = ImageSizeOptions(width: width, height: height, resolution: document.resolution, sampling: .high)
        let resized = try await ImageResizer.shared.resize(ProjectSnapshot(manifest: snapshot.manifest, images: images,
                                                                           masks: snapshot.masks), to: options)
        if cancellation.isCancelled { throw CancellationError() }
        guard self.document == document else { throw AIModelError.documentChanged }
        let effects = Dictionary(uniqueKeysWithValues: document.layers.compactMap { layer in
            layer.effects.map { (layer.id, $0.scaled(by: CGFloat(factor))) }
        })
        beginEdit("Enlarger")
        let m = resized.manifest
        self.document = CanvasDocument(id: m.documentID, width: m.width, height: m.height,
            layers: m.layers.map { ImageLayer(id: $0.id, asset: resized.images[$0.id], name: $0.name,
                isVisible: $0.isVisible, transform: $0.transform, parentID: $0.parentID, isGroup: $0.isGroup == true,
                opacity: $0.opacity ?? 1, blendMode: $0.blendMode ?? .normal, mask: resized.mask(for: $0),
                maskSourceID: $0.maskSourceID, adjustment: $0.adjustment, effects: effects[$0.id]) },
            resolution: m.resolution ?? 72, guides: m.guides ?? [])
        endEdit()
        viewport.fit(documentSize: self.document!.size)
    }
}
