import SwiftUI
import UniformTypeIdentifiers

struct ImageLayer: Identifiable, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isVisible == rhs.isVisible && lhs.transform == rhs.transform
            && lhs.asset?.image === rhs.asset?.image && lhs.parentID == rhs.parentID && lhs.isGroup == rhs.isGroup && lhs.opacity == rhs.opacity && lhs.blendMode == rhs.blendMode && lhs.mask == rhs.mask && lhs.maskSourceID == rhs.maskSourceID && lhs.adjustment == rhs.adjustment && lhs.shape == rhs.shape && lhs.text == rhs.text && lhs.effects == rhs.effects
            && lhs.gifAnimation == rhs.gifAnimation
    }
    let id: UUID
    var asset: ImportedImage?
    var transform: LayerTransform
    var origin: CGPoint { transform.origin }
    var name: String
    var isVisible = true
    var parentID: UUID?
    var isGroup = false
    var opacity: Double = 1
    var blendMode: LayerBlendMode = .normal
    var maskSourceID: UUID?
    var mask: LayerMask?
    /// Masks scoped to frames in an imported GIF. The frames remain part of this one layer.
    var gifAnimation: GIFAnimation? = nil
    var adjustment: LayerAdjustment?
    /// Set on layers the Shape tool made; see `liveShape`.
    var shape: LayerShape?
    /// A stroke and drop shadow drawn around the layer, kept apart from its pixels.
    var effects: LayerEffects?
    var text: LayerText?
    nonisolated var size: CGSize { transform.size }

    init(asset: ImportedImage, origin: CGPoint) {
        self.id = UUID()
        self.asset = asset
        self.transform = LayerTransform(origin: origin, size: CGSize(width: asset.image.width, height: asset.image.height))
        self.name = asset.name
    }

    init(name: String, blankSize: CGSize) {
        self.id = UUID()
        self.asset = nil // Allocate pixels when painting begins, not when adding an empty layer.
        self.transform = LayerTransform(origin: .zero, size: blankSize)
        self.name = name
    }

    init(id: UUID, asset: ImportedImage?, name: String, isVisible: Bool, transform: LayerTransform, parentID: UUID? = nil, isGroup: Bool = false, opacity: Double = 1, blendMode: LayerBlendMode = .normal, mask: LayerMask? = nil, maskSourceID: UUID? = nil, adjustment: LayerAdjustment? = nil, shape: LayerShape? = nil, effects: LayerEffects? = nil, text: LayerText? = nil, gifAnimation: GIFAnimation? = nil) {
        self.id = id
        self.asset = asset
        self.name = name
        self.isVisible = isVisible
        self.transform = transform
        self.parentID = parentID
        self.isGroup = isGroup
        self.opacity = opacity
        self.blendMode = blendMode
        self.mask = mask
        self.gifAnimation = gifAnimation
        self.maskSourceID = maskSourceID
        self.adjustment = adjustment
        self.shape = shape
        self.effects = effects
        self.text = text
    }
}

struct CanvasDocument: Equatable {
    let id: UUID
    let width: Int
    let height: Int
    var resolution: Double = 72
    var layers: [ImageLayer] = [] // Bottom to top.
    /// User-placed alignment lines. Saved with the project; undo covers them.
    var guides: [CanvasGuide] = []
    /// Part of the document so undo/redo covers selection changes. Not saved to disk.
    var selection: DocumentSelection?
    var size: CGSize { CGSize(width: width, height: height) }
    init(id: UUID = UUID(), width: Int, height: Int, layers: [ImageLayer] = [], resolution: Double = 72, guides: [CanvasGuide] = []) {
        self.id = id
        self.width = width
        self.height = height
        self.layers = layers
        self.resolution = resolution
        self.guides = guides
    }

    // Geometry limit; raster memory limits will be established with image import.
    static func validDimension(_ value: String) -> Int? {
        guard let n = Int(value.trimmingCharacters(in: .whitespaces)),
              (1...DocumentLimits.maxSide).contains(n) else { return nil }
        return n
    }
}

enum NavigationTool: String, CaseIterable {
    case move, marquee, lasso, wand, crop, brush, spotHealing, cloneStamp, blur, gradient, shape, type, eyedropper, hand, zoom
    /// No tool (A): nothing in the tool rail is selected and canvas clicks do nothing.
    case idle
    /// Tools that paint with the brush tip, sharing its size, hardness, opacity, and keys.
    var isBrushTool: Bool { self == .brush || self == .spotHealing || self == .cloneStamp || self == .blur }
    /// Tools that draw and edit selections, sharing modifiers, moving, and nudging.
    var isSelectionTool: Bool { self == .marquee || self == .lasso || self == .wand }
    var symbol: String { self == .type ? "textformat" : self == .eyedropper ? "eyedropper" : self == .marquee ? "rectangle.dashed" : self == .lasso ? "lasso" : self == .wand ? "wand.and.stars" : self == .brush ? "paintbrush.pointed" : self == .spotHealing ? "bandage" : self == .cloneStamp ? "seal" : self == .blur ? "drop" : self == .gradient ? "square.bottomhalf.filled" : self == .shape ? "square.on.circle" : self == .crop ? "crop" : self == .move ? "arrow.up.left.and.arrow.down.right" : self == .hand ? "hand.raised" : "magnifyingglass" }
    var label: String { self == .type ? "Type (T)" : self == .eyedropper ? "Eyedropper (I)" : self == .marquee ? "Marquee (M)" : self == .lasso ? "Lasso (L)" : self == .wand ? "Magic (W) · Tab switches Wand and Object" : self == .brush ? "Brush (B) · Eraser (E)" : self == .spotHealing ? "Spot Healing Brush (J)" : self == .cloneStamp ? "Clone Stamp (S) · Option-click sets the source" : self == .blur ? "Smear (R)" : self == .gradient ? "Gradient (G)" : self == .shape ? "Shape (U) · Shift-U switches Rectangle/Ellipse" : self == .crop ? "Crop (C)" : self == .move ? "Move / Transform (V)" : self == .hand ? "Hand (H)" : "Zoom (Z)" }
}

private struct GIFLayerTimelineState {
    // History owns deleted animations until Undo expires; previews must not retain their source bytes forever.
    weak var source: GIFSource?
    let geometry: GIFFrameGeometry?
    var selectedFrameIndex: Int
    var sourceFrameIndex: Int
    var displayedAsset: ImportedImage?
    var isPlaying = false
}

@Observable
final class EditorSession {
    var skipsInitialClipboardCanvasSize = false
    var document: CanvasDocument?
    /// Runtime animation data keyed by the imported layer, so switching layers restores that GIF's timeline.
    private var gifTimelinesByLayerID: [UUID: GIFLayerTimelineState] = [:]
    private func gifTimeline(for layer: ImageLayer) -> GIFLayerTimelineState? {
        guard let animation = layer.gifAnimation else { return nil }
        if let state = gifTimelinesByLayerID[layer.id],
           state.source === animation.source, state.geometry == animation.geometry,
           animation.sourceFrameIndex(for: state.selectedFrameIndex) == state.sourceFrameIndex { return state }
        return GIFLayerTimelineState(source: animation.source, geometry: animation.geometry, selectedFrameIndex: animation.selectedFrameIndex,
                                    sourceFrameIndex: animation.sourceFrameIndex(for: animation.selectedFrameIndex) ?? animation.selectedFrameIndex,
                                    displayedAsset: layer.asset)
    }
    var gifTimelineLayerID: UUID? {
        guard let layer = activeLayer, layer.gifAnimation?.source.frames.isEmpty == false else { return nil }
        return layer.id
    }
    var gifTimelineFrames: [GIFTimelineFrame] {
        guard let animation = activeLayer?.gifAnimation else { return [] }
        return animation.frames.map { frame in
            GIFTimelineFrame(index: frame.index, thumbnail: animation.framePixels[frame.index]?.thumbnail ?? frame.thumbnail,
                             duration: frame.duration)
        }
    }
    var gifTimelineTiming: GIFFrameTiming { activeLayer?.gifAnimation?.timing ?? GIFFrameTiming() }
    var gifTimelineSelectedFrameIndex: Int {
        activeLayer.flatMap { gifTimeline(for: $0)?.selectedFrameIndex } ?? 0
    }
    var gifTimelineCanEditFrames: Bool { canEditLayers && !gifTimelineIsLoadingFrame }
    /// Timing belongs to the layer and does not depend on the frame being decoded.
    var gifTimelineCanEditTiming: Bool { canEditLayers }
    var gifTimelineIsPlaying: Bool {
        activeLayer.flatMap { gifTimeline(for: $0)?.isPlaying } ?? false
    }
    var gifTimelineCanPlay: Bool { gifTimelineFrames.count > 1 }
    private var isLoadingGIFFrame = false {
        didSet {
            if !isLoadingGIFFrame {
                let waiters = projectWaiters
                projectWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                resumeFileRequests()
            }
        }
    }
    /// Only timeline controls observe decoding, so they re-enable when it finishes without dimming shared controls.
    var gifTimelineIsLoadingFrame: Bool { isLoadingGIFFrame }
    @ObservationIgnored private var gifFrameSelectionRequestID: UUID?

    /// Frame navigation stays in runtime state; pixel edits are immutable assets stored on the animation.
    func displayedAsset(for layer: ImageLayer) -> ImportedImage? {
        guard let timeline = gifTimeline(for: layer) else { return layer.asset }
        return layer.gifAnimation?.framePixels[timeline.selectedFrameIndex] ?? timeline.displayedAsset ?? layer.asset
    }

    func displayedLayer(for layer: ImageLayer) -> ImageLayer {
        guard gifTimeline(for: layer) != nil, let asset = displayedAsset(for: layer) else { return layer }
        var displayed = layer
        displayed.asset = asset
        return displayed
    }

    func selectedGIFFrameIndex(for layerID: UUID) -> Int? {
        document?.layers.first(where: { $0.id == layerID }).flatMap { gifTimeline(for: $0)?.selectedFrameIndex }
    }

    /// The duplicate shares the clicked frame's raw preview, but owns a new pixel and mask edit target.
    func selectDuplicatedGIFFrame(_ index: Int, for layer: ImageLayer) {
        guard var timeline = gifTimeline(for: layer),
              let sourceIndex = layer.gifAnimation?.sourceFrameIndex(for: index) else { return }
        timeline.selectedFrameIndex = index
        timeline.sourceFrameIndex = sourceIndex
        gifTimelinesByLayerID[layer.id] = timeline
    }

    func currentGIFAnimation(for layer: ImageLayer) -> GIFAnimation? {
        guard var animation = layer.gifAnimation else { return nil }
        animation.selectedFrameIndex = gifTimeline(for: layer)?.selectedFrameIndex ?? animation.selectedFrameIndex
        return animation
    }

    var canvasFocusRequest = 0
    var showsSampleRing = true
    var adjustmentOriginal: LayerAdjustment?
    var adjustmentEditingID: UUID? { didSet { resumeFileRequests() } }
    /// The layer whose effects panel is open.
    var effectsEditing: LayerEffectSelection?
    var effectsEditingOriginal: LayerEffects?
    var effectSelection: LayerEffectSelection?
    @ObservationIgnored var effectsPreviews = EffectsPreviewCache()
    var projectURL: URL?
    /// The image file the document began as, opened or dropped into an empty window: until the document is saved as a
    /// project, Export offers that file's name, folder and format, so editing a PNG and writing it back is quick.
    @ObservationIgnored var sourceImageURL: URL?
    /// Blocks overlapping edits immediately. Not observed by the UI: controls only dim via
    /// `showsBusy`, after an operation has run long enough to be worth showing, so quick
    /// edits (invert, fills, stroke commits) never flash the interface.
    @ObservationIgnored var isProjectBusy = false {
        didSet {
            if !isProjectBusy {
                let waiters = projectWaiters
                projectWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            resumeFileRequests()
            updateBusyIndicator()
        }
    }
    /// True once `isProjectBusy` has lasted longer than `busyIndicatorDelay`. Reading it also watches for a quicker
    /// operation ending, which `isProjectBusy`, not observed, can't tell the UI: a menu drawn during a Magic Wand click
    /// that selected what was already selected kept Deselect dimmed, with nothing after it to redraw the menu.
    var showsBusy: Bool { _ = quickOperationsEnded; return busyShowing }
    private var busyShowing = false
    private var quickOperationsEnded = 0
    static let busyIndicatorDelay: Duration = .milliseconds(250)
    @ObservationIgnored private var busyIndicatorTask: Task<Void, Never>?
    private func updateBusyIndicator() {
        if isProjectBusy {
            guard busyIndicatorTask == nil, !busyShowing else { return }
            busyIndicatorTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.busyIndicatorDelay)
                guard let self, !Task.isCancelled, self.isProjectBusy else { return }
                self.busyShowing = true
                self.busyIndicatorTask = nil
            }
        } else {
            if busyIndicatorTask != nil { quickOperationsEnded += 1 }
            busyIndicatorTask?.cancel()
            busyIndicatorTask = nil
            if busyShowing { busyShowing = false }
        }
    }
    private var projectWaiters: [CheckedContinuation<Void, Never>] = []
    private var fileRequestWaiters: [CheckedContinuation<Void, Never>] = []
    var canStartProjectOperation: Bool {
        _ = showsBusy // Re-evaluate in the UI when a long operation starts or ends.
        return !isEditingBrushPreset && selectionAmountOperation == nil && colorRange == nil && textDraft == nil && !isProjectBusy && !isImporting && brushStroke == nil && warpStroke == nil && levels == nil && !showsNewDocument && !showsImporter && renamingLayerID == nil && importError == nil && adjustmentEditingID == nil && !showsConversionSheet
    }
    func waitForFileRequest() async {
        while !canStartProjectOperation {
            await withCheckedContinuation { fileRequestWaiters.append($0) }
        }
    }
    private func resumeFileRequests() {
        guard canStartProjectOperation else { return }
        let waiters = fileRequestWaiters
        fileRequestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func waitForProjectAccess() async {
        while isProjectBusy || isLoadingGIFFrame {
            await withCheckedContinuation { projectWaiters.append($0) }
        }
    }
    var viewport = CanvasViewport()
    var tool: NavigationTool = .move
    var collapsedGroupIDs: Set<UUID> = []
    /// The Layers panel's search text and type filter (see LayerType). Panel state, not saved with the project.
    var layerSearchText = ""
    var layerTypeFilter: Set<LayerType> = []
    var cropRect: CGRect?
    var cropRatioChoice = "Free"
    var cropError: String?
    var transformEdit: TransformEdit?
    @ObservationIgnored var distortPreviewCache: [UUID: DistortPreviewCache] = [:]
    @ObservationIgnored var distortEffectsCache: [UUID: DistortEffectsCache] = [:]
    /// Document positions a move has just snapped to, drawn as guides while it lasts.
    @ObservationIgnored var snapGuides: (xs: [CGFloat], ys: [CGFloat]) = ([], [])
    /// Pixel gaps the Move tool shows while a layer is dragged, or with Command held over another layer.
    @ObservationIgnored var distanceLines: [DistanceLine] = []
    /// A Move tool resize in progress: the layer's size, and where the pointer has the handle, in document pixels.
    @ObservationIgnored var resizeSize: (text: String, corner: CGPoint)?
    /// Crop, resize and selection moves follow View › Snap (⇧⌘;) too: they had a Snap item of their own, which left
    /// the View menu with two called Snap.
    var snappingEnabled: Bool {
        get { snapEnabled }
        set { snapEnabled = newValue }
    }
    /// Where the last brush stroke ended, so a Shift-click paints a straight line on from it.
    @ObservationIgnored var lastBrushPoint: (point: CGPoint, layerID: UUID, mask: Bool)?
    /// Where the brush is while Smoothing trails it behind the pointer (see `smoothed`).
    @ObservationIgnored var brushAnchor: CGPoint?
    /// The pointer itself, so a smoothed stroke can catch up to it when the button is released.
    @ObservationIgnored var brushPointer: CGPoint?
