import AppKit

nonisolated enum WandSampleSize: Int, CaseIterable, Sendable {
    case point, threeByThree, fiveByFive
    var title: String { ["Point Sample", "3 by 3 Average", "5 by 5 Average"][rawValue] }
    /// Pixels either side of the click that are averaged into the color to match.
    var radius: Int { rawValue }
}

/// The Magic Wand's options-bar settings.
nonisolated struct WandSettings: Equatable, Sendable {
    /// How far (0–255) each channel may differ from the sampled color and still be selected.
    var tolerance = 32
    var sampleSize = WandSampleSize.point
    /// Only similar pixels connected to the clicked one, rather than every similar pixel.
    var contiguous = true
    /// Read the visible composite rather than just the active layer.
    var sampleAllLayers = false
}

/// Selects pixels similar to a clicked one. Matching and tracing run in C (`WandPixels.c`):
/// in Swift they would crawl on a large canvas in an unoptimized build.
nonisolated enum MagicWand {
    enum Failure: LocalizedError {
        case tooDetailed, memory
        var errorDescription: String? {
            switch self {
            case .tooDetailed: "That selection is too detailed to outline. Try a different Tolerance, or turn on Contiguous."
            case .memory: "There isn’t enough memory to make that selection."
            }
        }
    }

    /// The outline, in the image's top-left pixel coordinates, of the pixels matching the one
    /// at `point`. Nil when nothing matches or the point is outside the image.
    static func select(in image: CGImage, at point: CGPoint, settings: WandSettings) throws -> CGPath? {
        let width = image.width, height = image.height
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard point.x.isFinite, point.y.isFinite, (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        var selected = [UInt8](repeating: 0, count: width * height)
        let count = selected.withUnsafeMutableBufferPointer { mask in
            wand_mask(data.assumingMemoryBound(to: UInt8.self), width, height, context.bytesPerRow, x, y,
                      settings.sampleSize.radius, Int32(min(255, max(0, settings.tolerance))),
                      settings.contiguous ? 1 : 0, mask.baseAddress)
        }
        guard count >= 0 else { throw Failure.memory }
        guard count > 0 else { return nil }
        return try outline(of: selected, width: width, height: height)
    }

    /// Outline of a mask's nonzero pixels along exact pixel edges (winding rule); nil when empty.
    static func outline(of mask: [UInt8], width: Int, height: Int) throws -> CGPath? {
        guard width > 0, height > 0, mask.count == width * height else { return nil }
        var points: UnsafeMutablePointer<Int32>?, loops: UnsafeMutablePointer<Int32>?
        var pointCount = 0, loopCount = 0
        let status = mask.withUnsafeBufferPointer {
            wand_trace($0.baseAddress, width, height, &points, &pointCount, &loops, &loopCount)
        }
        defer { free(points); free(loops) }
        if status == -2 { throw Failure.tooDetailed }
        guard status == 0 else { throw Failure.memory }
        guard loopCount > 0, let points, let loops else { return nil }
        let path = CGMutablePath()
        var corners: [CGPoint] = []
        var index = 0
        for loop in 0..<loopCount {
            let length = Int(loops[loop])
            corners.removeAll(keepingCapacity: true)
            for corner in index..<(index + length) {
                corners.append(CGPoint(x: CGFloat(points[corner * 2]), y: CGFloat(points[corner * 2 + 1])))
            }
            path.addLines(between: corners)
            path.closeSubpath()
            index += length
        }
        return path
    }
}

private nonisolated struct WandJob: @unchecked Sendable {
    let image: CGImage
    let point: CGPoint
    let settings: WandSettings
}

private nonisolated struct WandResult: @unchecked Sendable {
    let path: CGPath?
    let error: Error?
}

extension EditorSession {
    /// The Magic Wand: selects pixels similar to the one at `point` (document pixels), read from
    /// the active layer or every visible layer, combined with the current selection by `mode`.
    /// Matching and tracing run off the main thread; the result is one undo step.
    func magicWand(at point: CGPoint, mode: SelectionMode) async {
        guard canEditSelection, !isProjectBusy, selectionMoveOrigin == nil, let document,
              point.x >= 0, point.y >= 0, point.x < document.size.width, point.y < document.size.height,
              let sample = selectionSample(document, sampleAllLayers: wandSettings.sampleAllLayers) else { return }
        let job = WandJob(image: sample, point: point, settings: wandSettings)
        isProjectBusy = true
        defer { isProjectBusy = false }
        let result = await Task.detached(priority: .userInitiated) { () -> WandResult in
            do { return WandResult(path: try MagicWand.select(in: job.image, at: job.point, settings: job.settings), error: nil) }
            catch { return WandResult(path: nil, error: error) }
        }.value
        guard !Task.isCancelled else { return }
        if let error = result.error { brushError = error.localizedDescription; return }
        guard self.document?.id == document.id else { return }
        guard let path = result.path else {
            // Nothing matched: New clears the selection, as a lasso click enclosing nothing does.
            if mode == .replace { deselect() }
            return
        }
        // A traced outline already lies on the canvas, so a new selection skips the clip to
        // the canvas, which is costly for a detailed outline.
        if mode == .replace {
            setSelection(DocumentSelection(path: path, antialiased: selectionAntialiased), name: "Magic Wand")
        } else {
            applySelection(path, mode: mode, name: "Magic Wand")
        }
    }

    /// What selection-from-image tools read, at document size: every visible layer as shown on the canvas,
    /// or just the active layer's own pixels (without its mask, as Cmd-click selection reads them).
    /// A folder or blank layer reads as transparent.
    func selectionSample(_ document: CanvasDocument, sampleAllLayers: Bool) -> CGImage? {
        guard let context = try? BrushRaster.context(width: document.width, height: document.height, mask: false) else { return nil }
        if sampleAllLayers {
            drawLiveComposite(document, in: context)
        } else if let layer = activeLayer, !layer.isGroup, let image = layer.asset?.image {
            let transform = displayedTransform(for: layer)
            LayerRenderer.draw(image, transform: transform, center: transform.center, in: context)
        }
        return context.makeImage()
    }
}
