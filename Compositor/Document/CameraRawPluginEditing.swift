import AppKit
import CameraRawHostContract

@MainActor
enum CameraRawPluginLoader {
    static func makePanel(host: any CameraRawEditingHost) throws -> NSWindowController {
        guard let root = Bundle.main.privateFrameworksURL,
              let bundle = Bundle(url: root.appendingPathComponent("CameraRawPlugin.framework")) else {
            throw CameraRawPluginError.missingPlugin
        }
        // Only the embedded, app-signed bundle is eligible. Library validation remains enabled.
        try bundle.loadAndReturnError()
        guard let principal = bundle.principalClass as? any CameraRawPluginPrincipal.Type else {
            throw CameraRawPluginError.missingPlugin
        }
        return principal.init().makePanel(host: host)
    }
}

nonisolated enum CameraRawPluginError: LocalizedError {
    case missingPlugin, invalidSettings, sourceChanged, closed
    var errorDescription: String? {
        switch self {
        case .missingPlugin: AppLocalization.string("The embedded Camera Raw panel could not be loaded. Existing adjustments are kept.")
        case .invalidSettings: AppLocalization.string("These Camera Raw settings are invalid or need a newer version. The original adjustment has been kept.")
        case .sourceChanged: AppLocalization.string("The source layer changed while the Camera Raw panel was open. Reopen the panel to edit it.")
        case .closed: AppLocalization.string("This Camera Raw editing session has ended.")
        }
    }
}

/// A serial worker prevents cancelled slider requests from running several full-image kernels at once.
actor CameraRawPluginPreviewRenderer {
    static let shared = CameraRawPluginPreviewRenderer()

    func render(_ image: CGImage, settings: CameraRawSettings, seed: UInt32) throws -> CGImage {
        try Task.checkCancellation()
        return try settings.apply(image, seed: seed, usesGPU: true)
    }
}

@MainActor
final class CameraRawPluginEdit: CameraRawEditingHost {
    private weak var session: EditorSession?
    let documentID: UUID
    let layerID: UUID
    let original: ImportedImage
    let originalOperation: CameraRawOperation?
    let transform: LayerTransform
    let initialPayload: Data
    let seed: UInt32
    let controls = CameraRawPluginControls.all
    var sourceImage: CGImage { original.image }
    private var applying = false
    private let renderReference: @Sendable (ImportedImage, CameraRawOperation) throws -> ImportedImage
    private var previewGeneration = 0

    init(session: EditorSession, layer: ImageLayer, documentID: UUID,
         renderReference: @escaping @Sendable (ImportedImage, CameraRawOperation) throws -> ImportedImage = {
             try CameraRawOperationRenderer.shared.render($0, operation: $1)
         }) throws {
        guard let asset = layer.asset else { throw CameraRawPluginError.sourceChanged }
        self.session = session
        self.renderReference = renderReference
        self.documentID = documentID
        layerID = layer.id
        original = asset
        originalOperation = layer.cameraRawOperation
        transform = layer.transform
        seed = layer.cameraRawOperation?.seed ?? UInt32.random(in: .min ... .max)
        if let operation = layer.cameraRawOperation {
            guard operation.settings != nil else { throw CameraRawPluginError.invalidSettings }
            initialPayload = operation.payload
        } else {
            initialPayload = try JSONEncoder().encode(CameraRawSettings())
        }
    }

    private func checkedSession() throws -> EditorSession {
        guard let session, session.cameraRawPluginEdit === self else { throw CameraRawPluginError.closed }
        guard session.document?.id == documentID,
              let layer = session.document?.layers.first(where: { $0.id == layerID }),
              layer.asset?.image === original.image, layer.transform == transform,
              layer.cameraRawOperation == originalOperation else { throw CameraRawPluginError.sourceChanged }
        return session
    }

    func preview(payload: Data) async throws -> CGImage {
        _ = try checkedSession()
        guard !applying else { throw CameraRawPluginError.closed }
        let operation = CameraRawOperation(payload: payload, seed: seed)
        guard let settings = operation.settings else { throw CameraRawPluginError.invalidSettings }
        previewGeneration += 1
        let generation = previewGeneration
        let image = sourceImage
        let seed = seed
        let rendered = try await CameraRawPluginPreviewRenderer.shared.render(image, settings: settings, seed: seed)
        try Task.checkCancellation()
        _ = try checkedSession()
        guard generation == previewGeneration else { throw CancellationError() }
        return rendered
    }

    func apply(payload: Data) async throws {
        _ = try checkedSession()
        guard !applying else { return }
        let operation = CameraRawOperation(payload: payload, seed: seed)
        guard operation.isValid, let settings = operation.settings else { throw CameraRawPluginError.invalidSettings }
        applying = true
        previewGeneration += 1
        defer { applying = false }
        // Validate and warm the CPU reference result before committing a document change.
        let source = original
        let render = renderReference
        if !settings.isIdentity {
            _ = try await Task.detached(priority: .userInitiated) {
                try render(source, operation)
            }.value
        }
        try Task.checkCancellation()
        let session = try checkedSession()
        guard let index = session.document?.layers.firstIndex(where: { $0.id == layerID }) else {
            throw CameraRawPluginError.sourceChanged
        }
        var committed = settings.isIdentity ? nil : operation
        if let originalOperation, let left = try? JSONSerialization.jsonObject(with: originalOperation.payload) as? [String: Any],
           let right = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           NSDictionary(dictionary: left).isEqual(to: right) {
            committed = originalOperation
        }
        if committed != originalOperation {
            session.beginEdit("Camera Raw Adjustment")
            session.document?.layers[index].cameraRawOperation = committed
            session.endEdit()
        }
        session.cameraRawPluginEdit = nil
        // The plugin closes its own window after this callback returns.
        self.session = nil
    }

    func cancel() {
        guard !applying else { return }
        previewGeneration += 1
        if let session, session.cameraRawPluginEdit === self { session.cameraRawPluginEdit = nil }
        session = nil
    }
}

extension EditorSession {
    var canEditCameraRawPlugin: Bool {
        guard canEditLayers, hueSaturation == nil, levels == nil, filterEdit == nil,
              selectedLayerIDs.count == 1, !isMaskSelected, let layer = activeLayer else { return false }
        return layer.asset != nil && !layer.isGroup && layer.adjustment == nil && layer.text == nil && layer.shape == nil
    }

    func beginCameraRawPlugin(makePanel: @MainActor (any CameraRawEditingHost) throws -> NSWindowController = CameraRawPluginLoader.makePanel) {
        if cameraRawPluginEdit != nil { cameraRawPluginWindow?.showWindow(nil); return }
        guard canEditCameraRawPlugin, let layer = activeLayer, let document else { return }
        do {
            let edit = try CameraRawPluginEdit(session: self, layer: layer, documentID: document.id)
            let panel = try makePanel(edit)
            cameraRawPluginEdit = edit
            cameraRawPluginWindow = panel
            panel.showWindow(nil)
        } catch { cameraRawPluginError = error.localizedDescription }
    }

    func requestRemoveCameraRawOperation() {
        guard canEditLayers, let layer = activeLayer, layer.cameraRawOperation != nil else { return }
        let alert = NSAlert()
        alert.messageText = AppLocalization.string("Remove Camera Raw Adjustment?")
        alert.informativeText = AppLocalization.format("The saved settings on “%1$@” will be removed. Source pixels are kept. You can undo this change.", layer.name)
        alert.addButton(withTitle: AppLocalization.string("Remove Adjustment"))
        alert.addButton(withTitle: AppLocalization.string("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, canEditLayers,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        beginEdit("Remove Camera Raw Adjustment")
        document?.layers[index].cameraRawOperation = nil
        endEdit()
    }

    var cameraRawLimitation: String? {
        if document?.layers.contains(where: { $0.cameraRawOperation != nil && $0.cameraRawOperation?.settings == nil }) == true {
            return AppLocalization.string("A Camera Raw adjustment needs a newer plugin. Its settings are kept; the canvas shows source pixels and export is unavailable.")
        }
        return nil
    }
}

@MainActor
private enum CameraRawPluginControls {
    static let all: [CameraRawControl] = {
        var controls: [CameraRawControl] = []
        func add(_ id: String, _ title: String, _ group: String, _ range: ClosedRange<Double> = -100...100, _ value: Double = 0) {
            controls.append(CameraRawControl(id: id, title: AppLocalization.string(title), group: AppLocalization.string(group), lowerBound: range.lowerBound,
                                             upperBound: range.upperBound, defaultValue: value))
        }
        add("temperature", "Temperature (relative)", "White Balance")
        add("tint", "Tint", "White Balance")
        add("exposure", "Exposure", "Light", -5...5)
        add("contrast", "Contrast", "Light")
        add("highlights", "Highlights", "Light")
        add("shadows", "Shadows", "Light")
        add("whites", "Whites", "Light")
        add("blacks", "Blacks", "Light")
        add("vibrance", "Vibrance", "Color")
        add("saturation", "Saturation", "Color")
        add("curve.shadows", "Shadows", "Parametric Curve")
        add("curve.darks", "Darks", "Parametric Curve")
        add("curve.lights", "Lights", "Parametric Curve")
        add("curve.highlights", "Highlights", "Parametric Curve")
        add("curve.refineSaturation", "Refine Saturation", "Parametric Curve")
        add("grading.shadows.hue", "Shadows Hue", "Color Grading", 0...360)
        add("grading.shadows.saturation", "Shadows Saturation", "Color Grading", 0...100)
        add("grading.shadows.luminance", "Shadows Luminance", "Color Grading")
        add("grading.midtones.hue", "Midtones Hue", "Color Grading", 0...360)
        add("grading.midtones.saturation", "Midtones Saturation", "Color Grading", 0...100)
        add("grading.midtones.luminance", "Midtones Luminance", "Color Grading")
        add("grading.highlights.hue", "Highlights Hue", "Color Grading", 0...360)
        add("grading.highlights.saturation", "Highlights Saturation", "Color Grading", 0...100)
        add("grading.highlights.luminance", "Highlights Luminance", "Color Grading")
        add("grading.global.hue", "Global Hue", "Color Grading", 0...360)
        add("grading.global.saturation", "Global Saturation", "Color Grading", 0...100)
        add("grading.global.luminance", "Global Luminance", "Color Grading")
        add("grading.blending", "Blending", "Color Grading", 0...100, 50)
        add("grading.balance", "Balance", "Color Grading")
        add("texture", "Texture", "Effects")
        add("clarity", "Clarity", "Effects")
        add("dehaze", "Dehaze", "Effects")
        add("glow", "Glow", "Effects", 0...100)
        add("glowRange", "Glow Range", "Effects")
        add("glowSpread", "Glow Spread", "Effects")
        add("glowWarmth", "Glow Warmth", "Effects")
        add("vignetteAmount", "Vignette", "Effects")
        add("vignetteMidpoint", "Midpoint", "Effects", 0...100, 50)
        add("vignetteRoundness", "Roundness", "Effects")
        add("vignetteFeather", "Feather", "Effects", 0...100, 50)
        add("vignetteHighlights", "Highlights", "Effects", 0...100)
        add("grainAmount", "Amount", "Grain", 0...100)
        add("grainSize", "Size", "Grain", 0...100, 25)
        add("grainRoughness", "Roughness", "Grain", 0...100, 50)
        add("detail.sharpenAmount", "Sharpening", "Detail", 0...150)
        add("detail.sharpenRadius", "Radius", "Detail", 0...100, 10)
        add("detail.sharpenDetail", "Detail", "Detail", 0...100, 25)
        add("detail.sharpenMasking", "Masking", "Detail", 0...100)
        add("detail.noiseLuminance", "Luminance Noise", "Detail", 0...100)
        add("detail.noiseColor", "Color Noise", "Detail", 0...100)
        add("optics.distortion", "Manual Distortion", "Optics")
        add("optics.vignetteAmount", "Lens Vignette", "Optics")
        add("geometry.vertical", "Vertical", "Geometry")
        add("geometry.horizontal", "Horizontal", "Geometry")
        add("geometry.aspect", "Aspect", "Geometry")
        add("geometry.scale", "Scale", "Geometry")
        add("geometry.offsetX", "Offset X", "Geometry")
        add("geometry.offsetY", "Offset Y", "Geometry")
        add("geometry.rotate", "Rotation", "Geometry", -45...45)
        add("calibration.shadowTint", "Shadow Tint", "Calibration")
        add("calibration.redHue", "Red Hue", "Calibration")
        add("calibration.redSaturation", "Red Saturation", "Calibration")
        add("calibration.greenHue", "Green Hue", "Calibration")
        add("calibration.greenSaturation", "Green Saturation", "Calibration")
        add("calibration.blueHue", "Blue Hue", "Calibration")
        add("calibration.blueSaturation", "Blue Saturation", "Calibration")
        return controls
    }()
}
