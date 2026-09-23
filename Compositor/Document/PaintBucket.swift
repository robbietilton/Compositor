import AppKit

nonisolated enum FillToolMode: String, CaseIterable {
    case gradient = "Gradient"
    case bucket = "Paint Bucket"
}

nonisolated enum PaintBucket {
    /// A tight raster mask avoids tracing complex regions into enormous selection paths.
    static func region(in image: CGImage, at point: CGPoint, settings: WandSettings) throws -> SelectionClip? {
        guard let pixels = try MagicWand.matchingPixels(in: image, at: point, settings: settings) else { return nil }
        var bounds = [Int](repeating: 0, count: 4)
        pixels.withUnsafeBufferPointer {
            heal_coverage_bounds($0.baseAddress, image.width, image.height, image.width, &bounds)
        }
        let rect = CGRect(x: bounds[0], y: bounds[1], width: bounds[2] - bounds[0], height: bounds[3] - bounds[1])
        guard !rect.isEmpty else { return nil }
        let context = try BrushRaster.context(width: Int(rect.width), height: Int(rect.height), mask: true)
        guard let data = context.data else { throw ExportError.render }
        pixels.withUnsafeBytes { bytes in
            for y in 0..<Int(rect.height) {
                data.advanced(by: y * context.bytesPerRow).copyMemory(
                    from: bytes.baseAddress!.advanced(by: (bounds[1] + y) * image.width + bounds[0]),
                    byteCount: Int(rect.width))
            }
        }
        guard let coverage = context.makeImage() else { throw ExportError.render }
        return SelectionClip(rect: rect, coverage: coverage)
    }
}

private nonisolated struct BucketJob: @unchecked Sendable {
    let image: CGImage
    let point: CGPoint
    let settings: WandSettings
    func run() throws -> SelectionClip? { try PaintBucket.region(in: image, at: point, settings: settings) }
}

extension EditorSession {
    /// Start with raster and blank layers. Editable text, shapes, and masks keep their existing tools.
    var canPaintBucket: Bool {
        canPaint && !isMaskSelected && activeLayer?.text == nil && activeLayer?.shape == nil
    }

    func changeFillToolMode(_ mode: FillToolMode) {
        guard !isProjectBusy, gradientEdit == nil else { return }
        fillToolMode = mode
    }

    func paintBucket(at point: CGPoint) async {
        guard canPaintBucket, let document, let layer = activeLayer,
              point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < document.size.width, point.y < document.size.height else { return }
        if let selection, !selection.path.contains(point, using: .winding) { return }
        guard document.width <= 100_000_000 / max(1, document.height) else {
            brushError = ProjectError.tooLarge.localizedDescription
            return
        }
        guard let sample = selectionSample(document, sampleAllLayers: bucketSettings.sampleAllLayers) else {
            brushError = ExportError.render.localizedDescription
            return
        }
        let job = BucketJob(image: sample, point: point, settings: bucketSettings)
        let color = paletteColor(background: false)
        let opacity = gradientSettings.opacity
        finishOpacityEdit()
        isProjectBusy = true
        defer { isProjectBusy = false }
        do {
            guard let region = try await Task.detached(priority: .userInitiated, operation: { try job.run() }).value,
                  self.document == document, activeLayerID == layer.id, !isMaskSelected else { return }
            let edit = try makeRasterEdit(for: layer)
            try edit.fill(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: opacity), clip: region)
            guard !edit.patches.isEmpty else { return }
            try await commitRasterEdit(edit, name: "Paint Bucket")
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }
}
