import SwiftUI
import Combine

struct ImageLayer: Identifiable, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isVisible == rhs.isVisible && lhs.transform == rhs.transform
            && lhs.asset?.image === rhs.asset?.image && lhs.parentID == rhs.parentID && lhs.isGroup == rhs.isGroup && lhs.opacity == rhs.opacity && lhs.blendMode == rhs.blendMode && lhs.mask == rhs.mask && lhs.maskSourceID == rhs.maskSourceID && lhs.adjustment == rhs.adjustment && lhs.shape == rhs.shape && lhs.text == rhs.text && lhs.effects == rhs.effects
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
    var adjustment: LayerAdjustment?
    /// Set on layers the Shape tool made; see `liveShape`.
    var shape: LayerShape?
    /// A stroke and drop shadow drawn around the layer, kept apart from its pixels.
    var effects: LayerEffects?
    var text: LayerText?
    var size: CGSize { transform.size }

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

    init(id: UUID, asset: ImportedImage?, name: String, isVisible: Bool, transform: LayerTransform, parentID: UUID? = nil, isGroup: Bool = false, opacity: Double = 1, blendMode: LayerBlendMode = .normal, mask: LayerMask? = nil, maskSourceID: UUID? = nil, adjustment: LayerAdjustment? = nil, shape: LayerShape? = nil, effects: LayerEffects? = nil, text: LayerText? = nil) {
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
              (1...30_000).contains(n) else { return nil }
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
    var symbol: String { self == .type ? "textformat" : self == .eyedropper ? "eyedropper" : self == .marquee ? "rectangle.dashed" : self == .lasso ? "lasso" : self == .wand ? "wand.and.stars" : self == .brush ? "paintbrush.pointed" : self == .spotHealing ? "bandage" : self == .cloneStamp ? "seal" : self == .blur ? "drop" : self == .gradient ? "square.bottomhalf.filled" : self == .shape ? "square.on.circle" : self == .crop ? "crop" : self == .move ? "arrow.up.left.and.arrow.down.right" : self == .hand ? "hand.draw" : "magnifyingglass" }
    var label: String { self == .type ? "Type (T)" : self == .eyedropper ? "Eyedropper (I)" : self == .marquee ? "Marquee (M)" : self == .lasso ? "Lasso (L)" : self == .wand ? "Magic (W) · Tab switches Wand and Object" : self == .brush ? "Brush (B) · Eraser (E)" : self == .spotHealing ? "Spot Healing Brush (J)" : self == .cloneStamp ? "Clone Stamp (S) · Option-click sets the source" : self == .blur ? "Smear (R)" : self == .gradient ? "Gradient (G)" : self == .shape ? "Shape (U) · Shift-U switches Rectangle/Ellipse" : self == .crop ? "Crop (C)" : self == .move ? "Move / Transform (V)" : self == .hand ? "Hand (H)" : "Zoom (Z)" }
}

final class EditorSession: ObservableObject {
    var skipsInitialClipboardCanvasSize = false
    @Published var document: CanvasDocument?
    @Published var canvasFocusRequest = 0
    @Published var showsSampleRing = true
    @Published var adjustmentOriginal: LayerAdjustment?
    @Published var adjustmentEditingID: UUID? { didSet { resumeFileRequests() } }
    /// The layer whose effects panel is open.
    @Published var effectsEditing: LayerEffectSelection?
    @Published var effectsEditingOriginal: LayerEffects?
    @Published var effectSelection: LayerEffectSelection?
    var effectsPreviews = EffectsPreviewCache()
    @Published var projectURL: URL?
    /// Blocks overlapping edits immediately. Not observed by the UI: controls only dim via
    /// `showsBusy`, after an operation has run long enough to be worth showing, so quick
    /// edits (invert, fills, stroke commits) never flash the interface.
    var isProjectBusy = false {
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
    /// True once `isProjectBusy` has lasted longer than `busyIndicatorDelay`.
    @Published private(set) var showsBusy = false
    static let busyIndicatorDelay = LegacyDelay.milliseconds(250)
    private var busyIndicatorTask: Task<Void, Never>?
    private func updateBusyIndicator() {
        if isProjectBusy {
            guard busyIndicatorTask == nil, !showsBusy else { return }
            busyIndicatorTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.busyIndicatorDelay)
                guard let self, !Task.isCancelled, self.isProjectBusy else { return }
                self.showsBusy = true
                self.busyIndicatorTask = nil
            }
        } else {
            busyIndicatorTask?.cancel()
            busyIndicatorTask = nil
            if showsBusy { showsBusy = false }
        }
    }
    private var projectWaiters: [CheckedContinuation<Void, Never>] = []
    private var fileRequestWaiters: [CheckedContinuation<Void, Never>] = []
    var canStartProjectOperation: Bool {
        _ = showsBusy // Re-evaluate in the UI when a long operation starts or ends.
        return selectionAmountOperation == nil && textDraft == nil && !isProjectBusy && !isImporting && brushStroke == nil && warpStroke == nil && levels == nil && !showsNewDocument && !showsImporter && renamingLayerID == nil && importError == nil && adjustmentEditingID == nil
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
        while isProjectBusy {
            await withCheckedContinuation { projectWaiters.append($0) }
        }
    }
    @Published var viewport = CanvasViewport()
    @Published var tool: NavigationTool = .move
    @Published var collapsedGroupIDs: Set<UUID> = []
    @Published var cropRect: CGRect?
    @Published var cropRatioChoice = "Free"
    @Published var cropError: String?
    @Published var transformEdit: TransformEdit?
    var distortPreviewCache: [UUID: DistortPreviewCache] = [:]
    var distortEffectsCache: [UUID: DistortEffectsCache] = [:]
    /// Document positions a move has just snapped to, drawn as guides while it lasts.
    var snapGuides: (xs: [CGFloat], ys: [CGFloat]) = ([], [])
    @Published var snappingEnabled = true {
        didSet {
            if !snappingEnabled { snapGuides = ([], []) }
            refreshCanvasPreview?()
        }
    }
    /// Where the last brush stroke ended, so a Shift-click paints a straight line on from it.
    var lastBrushPoint: (point: CGPoint, layerID: UUID, mask: Bool)?
    var maskDistortPreviewCache: MaskDistortPreviewCache?
    /// The last rounded rectangle drawn for a transform in progress, by layer, with the size it was drawn at.
    var shapeTransformPreviewCache: [UUID: (size: CGSize, image: CGImage)] = [:]
    @Published var locksTransformRatio = true
    /// Off by default: a Move-tool press drags the active layer; hold Cmd (or turn this on) to pick the layer under the pointer.
    @Published var transformAutoSelect = false
    /// The Move tool's transform box and handles (⌘H). Hidden, a drag anywhere just moves the layer;
    /// a pending ⌘T transform still shows its box.
    @Published var showsTransformControls = true
    /// The copies an Option-drag made, and what was selected before it, so Escape can take them away again.
    var transformDuplicate: (copies: [UUID], source: Set<UUID>, primary: UUID?)?
    @Published var brushSettings = BrushSettings() { didSet { refreshGradient() } }
    @Published var spotHealingMode: SpotHealingMode = .contentAware
    @Published var blurMode: BlurToolMode = .liquify
    /// The Brush's two modes: Paint lays down the foreground color, Erase clears pixels away (B and E).
    @Published var brushMode: BrushToolMode = .paint
    /// The tool rail's icon, which follows the mode a tool is in.
    func symbol(for tool: NavigationTool) -> String {
        tool == .brush && brushMode == .erase ? "eraser" : tool.symbol
    }
    /// The Magic tool's two modes: Wand selects by color, Object traces the object under the pointer (Tab).
    @Published var wandMode: WandMode = .wand
    /// Clone Stamp: the source Option-click set (document pixels), its options, and — once a
    /// stroke has started — the offset from brush to source that aligned strokes keep.
    @Published var cloneSource: CGPoint?
    @Published var cloneSettings = CloneSettings()
    /// The brush tip (size, hardness, opacity) of the side not in use: Clone Stamp keeps its own,
    /// soft by default, while Brush and Spot Healing share theirs.
    /// The tips of the brush families not in use: Clone Stamp and Smear each keep their own size, hardness and
    /// opacity (both starting soft); the other brushes share one.
    var parkedBrushTips: [Int: (diameter: CGFloat, hardness: CGFloat, opacity: CGFloat)] = [1: (40, 0, 1), 2: (40, 0, 1)]
    private static func tipFamily(_ tool: NavigationTool) -> Int { tool == .cloneStamp ? 1 : tool == .blur ? 2 : 0 }
    var cloneOffset: CGSize?
    @Published var maskPaintWhite = false { didSet { refreshGradient() } }
    @Published var backgroundColor = PaletteColor.white { didSet { refreshGradient() } }
    @Published var gradientSettings = GradientSettings() { didSet { refreshGradient() } }
    @Published var gradientEdit: GradientEdit?
    @Published var lassoDraft: LassoDraft?
    @Published var lassoKind = LassoKind.freehand
    @Published var marqueeKind = LassoKind.rectangle
    @Published var textDraft: TextDraft? { didSet { if oldValue != nil && textDraft == nil { resumeFileRequests() } } }
    @Published var textDefaults = LayerTextStyle()
    @Published var shapeKind = ShapeKind.rectangle
    /// Corner radius in pixels for rectangles the Shape tool draws; 0 keeps the corners square.
    @Published var shapeCornerRadius: Double = 0
    /// A Line shape's thickness in document pixels.
    @Published var shapeLineWidth: Double = 4
    /// The shape being dragged out with the Shape tool, before it becomes a layer.
    @Published var shapeDraft: ShapeDraft?
    @Published var selectionModeChoice = SelectionMode.replace
    /// Mode implied by the Shift/Option keys currently held, nil when neither is.
    @Published var heldSelectionMode: SelectionMode?
    /// The selection as it was when a drag-move began; the drag is one undo step.
    var selectionMoveOrigin: DocumentSelection?
    @Published var pixelMove: PixelMove?
    var pixelClipboard: PixelClipboard?
    @Published var levels: LevelsEdit? { didSet { resumeFileRequests() } }
    @Published var hueSaturation: HueSaturationEdit?
    /// The open filter (Filter menu), and the settings the next one starts from.
    @Published var filterEdit: FilterEdit?
    @Published var filterSettings = FilterSettings()
    var hueSaturationTask: Task<Void, Never>?
    /// The newest preview request while one is already rendering.
    var hueSaturationPending: HueSaturationJob?
    /// The armed eyedropper and the targeted-adjustment tool, while the panel is open.
    @Published var hueSampleMode: HueSampleMode?
    @Published var hueTargeting = false
    var hueTargetDrag: HueTargetDrag?
    @Published var selectionAntialiased = true
    /// How far Feather softens the selection's edge each time it is applied, in document pixels.
    @Published var selectionAmountOperation: SelectionAmountOperation? { didSet { resumeFileRequests() } }
    @Published var selectionFeatherAmount = 2
    @Published var wandSettings = WandSettings()
    @Published var objectSelectionSettings = ObjectSelectionSettings()
    @Published var showsPixelGrid = true
    /// Layout grid (View > Show > Grid). Off until turned on; independent of the 800% pixel grid.
    @Published var showsGrid = false
    /// User guides. Hidden extras do not snap.
    @Published var showsGuides = true
    @Published var showsRulers = false
    /// Master snap switch (View > Snap). On so today's layer/canvas snap keeps working.
    @Published var snapEnabled = true
    @Published var snapToGuides = true
    @Published var snapToGrid = false
    @Published var snapToLayers = true
    @Published var snapToDocumentBounds = true
    @Published var locksGuides = false
    @Published var guideDrag: GuideDrag?
    /// Pixels the Expand / Contract buttons grow or shrink the selection by.
    @Published var selectionExpandAmount = 1
    @Published var selectionContractAmount = 1
    var pendingOpacityDigit: (digit: Int, time: TimeInterval)?
    @Published var colorPicker: ColorPickerState?
    @Published var brushError: String?
    @Published var brushRevision = 0
    /// Not observed by the UI, so controls don't dim for the length of every stroke;
    /// a stroke keeps the settings it started with, so edits made mid-stroke are harmless.
    var brushStroke: BrushStroke? { didSet { resumeFileRequests() } }
    /// A Smudge or Liquify stroke in progress.
    var warpStroke: WarpStroke? { didSet { resumeFileRequests() } }

    var canTransform: Bool {
        guard canEditLayers else { return false }
        // Several selected layers, or a folder's contents, transform together.
        if transformsAsGroup { return !groupTransformMembers.isEmpty }
        return activeLayer?.asset != nil && activeLayer?.isGroup == false && activeLayerID.map { document?.effectiveVisibleIDs.contains($0) == true } == true
    }
    /// Several layers selected, or a folder: the transform moves them (a folder, everything in it) together in one box.
    var transformsAsGroup: Bool { selectedLayerIDs.count > 1 || (selectedLayerIDs.count == 1 && activeLayer?.isGroup == true) }
    /// What a group transform moves: the visible pixel layers selected and inside selected folders.
    var groupTransformMembers: [ImageLayer] {
        guard transformsAsGroup, let document else { return [] }
        let parents = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0.parentID) })
        let visible = document.effectiveVisibleIDs
        return document.layers.filter { layer in
            guard layer.asset != nil, !layer.isGroup, visible.contains(layer.id) else { return false }
            var current: UUID? = layer.id
            for _ in 0..<64 {
                guard let id = current else { return false }
                if selectedLayerIDs.contains(id) { return true }
                current = parents[id] ?? nil
            }
            return false
        }
    }
    /// The upright box around `groupTransformMembers`.
    var groupTransformBox: LayerTransform? {
        let points = groupTransformMembers.flatMap { DistortWarp.corners(of: $0.transform) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return LayerTransform(origin: CGPoint(x: minX, y: minY), size: CGSize(width: max(1, maxX - minX), height: max(1, maxY - minY)))
    }
    func selectLayer(_ id: UUID?) {
        effectSelection = nil
        if id != activeLayerID, !finishText() { return }
        guard brushStroke == nil, warpStroke == nil, levels == nil else { return }
        if id != activeLayerID { commitTransform(); resolveGradient() }
        activeLayerID = id
    }
    func selectTool(_ value: NavigationTool) {
        if tool != value, !finishText() { return }
        guard !isProjectBusy, brushStroke == nil, warpStroke == nil, levels == nil else { return }
        if tool != value { commitTransform(); cancelCrop(); resolveGradient(); cancelLasso(); cancelShape() }
        let from = Self.tipFamily(tool), to = Self.tipFamily(value)
        if from != to, let parked = parkedBrushTips[to] {
            parkedBrushTips[from] = (brushSettings.diameter, brushSettings.hardness, brushSettings.opacity)
            var settings = brushSettings
            settings.diameter = parked.diameter
            settings.hardness = parked.hardness
            settings.opacity = parked.opacity
            brushSettings = settings
        }
        tool = value
        if value.isBrushTool { _ = MetalBrushCoverage.shared }
        if value == .crop, cropRect == nil, let document {
            cropRatioChoice = "Free"
            cropRect = CGRect(origin: .zero, size: document.size)
        }
    }
    /// Tab steps the current tool through its own modes — the setting sitting at the left of its tool bar. Tools
    /// without modes (Move, Crop, Type, Eyedropper, Hand, Zoom) ignore it.
    func cycleToolMode() {
        guard !isProjectBusy, brushStroke == nil, warpStroke == nil else { return }
        func next<T: CaseIterable & Equatable>(_ value: T) -> T where T.AllCases.Index == Int {
            let all = Array(T.allCases)
            let index = all.firstIndex(of: value) ?? 0
            return all[(index + 1) % all.count]
        }
        switch tool {
        case .marquee: toggleMarqueeKind()
        case .wand: wandMode = next(wandMode)
        case .lasso: toggleLassoKind()
        case .shape: toggleShapeKind()
        case .brush: brushMode = next(brushMode)
        case .blur: blurMode = next(blurMode)
        case .spotHealing: spotHealingMode = next(spotHealingMode)
        case .cloneStamp: cloneSettings.sampleAllLayers.toggle()
        case .gradient: gradientSettings.shape = next(gradientSettings.shape)
        default: break
        }
    }

    func beginTransform(persistent: Bool = true) {
        cancelCrop()
        guard transformEdit == nil, canTransform, let layer = activeLayer else { return }
        tool = .move
        if transformsAsGroup {
            let members = groupTransformMembers
            guard let box = groupTransformBox else { return }
            transformEdit = TransformEdit(layerID: layer.id, draft: box, persistent: persistent,
                group: TransformGroup(box: box, originals: Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.transform) })))
            return
        }
        // An unlinked mask, when selected, transforms on its own; linked, layer and mask move together.
        let maskAlone = isMaskSelected && layer.mask?.isLinked == false
        transformEdit = TransformEdit(layerID: layer.id, draft: maskAlone ? layer.maskTransform : layer.transform,
                                      persistent: persistent, mask: maskAlone)
    }
    func previewTransform(_ value: LayerTransform) {
        guard value.isValid, transformEdit != nil else { return }
        transformEdit?.draft = value
    }
    /// Option-drag duplicates selected roots with their descendants and drags the copies.
    func beginDuplicateTransform() {
        guard transformDuplicate == nil, let primary = activeLayerID else { return }
        commitTransform()
        guard canTransform else { return }
        let selection = selectedLayerIDs
        // Bottom to top, so the copies keep the order they had.
        let carried = selection.reduce(into: Set<UUID>()) { $0.formUnion(descendantIDs(of: $1)) }
        let targets = (document?.layers ?? []).filter { selection.contains($0.id) && !carried.contains($0.id) }.map(\.id)
        guard !targets.isEmpty else { return }
        beginEdit(targets.count > 1 ? "Duplicate Layers" : "Duplicate Layer")
        var copies: [UUID] = []
        for id in targets {
            selectLayer(id)
            duplicateActiveLayer()
            if let copy = activeLayerID, copy != id { copies.append(copy) }
        }
        guard !copies.isEmpty else { endEdit(); selectLayers(selection, primary: primary); return }
        transformDuplicate = (copies, selection, primary)
        selectLayers(Set(copies), primary: copies.last)
        beginTransform(persistent: false)
    }
    func commitTransform() {
        snapGuides = ([], [])
        blendPreview = nil
        finishOpacityEdit()
        guard let edit = transformEdit else { return }
        defer {
            if transformDuplicate != nil { transformDuplicate = nil; endEdit() }
        }
        transformEdit = nil
        if let floating = edit.floating {
            // Unchanged: restore exactly, so soft selection edges never pick up a seam.
            if edit.draft == floating.original && edit.corners == nil { cancelFloatingTransform(floating) }
            else { mergeFloatingTransform(edit, floating) }
            return
        }
        if edit.mask { commitMaskTransform(edit); return }
        if let corners = edit.corners { commitDistort(edit, corners: corners); return }
        if let group = edit.group {
            guard edit.draft.isValid else { return }
            beginEdit("Transform Layers")
            for (id, original) in group.originals {
                guard let index = document?.layers.firstIndex(where: { $0.id == id }) else { continue }
                let moved = original.following(from: group.box, to: edit.draft)
                guard moved.isValid else { continue }
                if let mask = document?.layers[index].mask {
                    document?.layers[index].mask?.placement = mask.placement(movingLayer: original, to: moved)
                }
                document?.layers[index].transform = moved
                redrawShape(at: index)
            }
            endEdit()
            return
        }
        guard edit.draft.isValid, let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }) else { return }
        beginEdit("Transform Layer")
        if let mask = document?.layers[index].mask, let old = document?.layers[index].transform {
            document?.layers[index].mask?.placement = mask.placement(movingLayer: old, to: edit.draft)
        }
        document?.layers[index].transform = edit.draft
        redrawShape(at: index)
        endEdit()
    }
    func cancelTransform() {
        snapGuides = ([], [])
        guard let edit = transformEdit else { return }
        transformEdit = nil
        if let duplicate = transformDuplicate {
            let removed = duplicate.copies.reduce(into: Set(duplicate.copies)) { $0.formUnion(descendantIDs(of: $1)) }
            document?.layers.removeAll { removed.contains($0.id) }
            collapsedGroupIDs.subtract(removed)
            selectLayers(duplicate.source, primary: duplicate.primary)
            transformDuplicate = nil
            endEdit()
        }
        if let floating = edit.floating { cancelFloatingTransform(floating) }
    }
    /// Pixels the transform places — what 100% scale draws 1:1. Nil for a layer without pixels.
    var transformPixelSize: CGSize? {
        if let group = transformEdit?.group { return group.box.size }
        if transformEdit == nil, transformsAsGroup { return groupTransformBox?.size }
        if transformTargetsMask { return nil }
        if let floating = transformEdit?.floating { return floating.pixelSize }
        guard let image = activeLayer?.asset?.image else { return nil }
        return CGSize(width: image.width, height: image.height)
    }
    func displayedTransform(for layer: ImageLayer) -> LayerTransform {
        if let pending = pendingTransform(for: layer) { return pending }
        // Content-Aware Fill past the layer's edge previews on the grown layer.
        if let edit = filterEdit, let grown = edit.grownTransform, edit.previewImage(for: layer.id) != nil { return grown }
        return layer.transform
    }
    /// Whether transforming places only the active layer's mask (an unlinked mask selected in the Layers panel).
    var transformTargetsMask: Bool { transformEdit.map(\.mask) ?? (isMaskSelected && activeLayer?.mask?.isLinked == false) }
    /// Where `layer`'s transform handles sit: the pending edit's draft — the layer's or its mask's — else the layer.
    func editedTransform(for layer: ImageLayer) -> LayerTransform {
        if transformEdit?.layerID == layer.id { return transformEdit!.draft }
        if transformEdit == nil, layer.id == activeLayerID, transformsAsGroup, let box = groupTransformBox { return box }
        return layer.id == activeLayerID && transformTargetsMask ? layer.maskTransform : layer.transform
    }
    /// A layer's transform under the pending edit: the draft for the edited layer, carried along with the box for
    /// each layer of a group; nil when the edit doesn't move it.
    func pendingTransform(for layer: ImageLayer) -> LayerTransform? {
        guard let edit = transformEdit, !edit.mask else { return nil }
        if let group = edit.group { return group.originals[layer.id].map { $0.following(from: group.box, to: edit.draft) } }
        return edit.layerID == layer.id ? edit.draft : nil
    }
    func nudgeLayer(dx: CGFloat, dy: CGFloat) {
        let alreadyEditing = transformEdit != nil
        if !alreadyEditing { beginTransform(persistent: false) }
        guard var value = transformEdit?.draft else { return }
        value.origin.x += dx
        value.origin.y += dy
        previewTransform(value)
        if let corners = transformEdit?.corners { previewCorners(corners.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }) }
        if !alreadyEditing { commitTransform() }
    }
    @Published var showsNewDocument = false { didSet { resumeFileRequests() } }
    @Published var showsImporter = false { didSet { resumeFileRequests() } }
    @Published var isImporting = false { didSet { resumeFileRequests() } }
    @Published var importError: String? { didSet { resumeFileRequests() } }
    @Published var opacityEditLayerID: UUID?
    @Published var blendPreview: (layerID: UUID, mode: LayerBlendMode)?
    var refreshCanvasPreview: (() -> Void)?
    @Published var isMaskSelected = false
    @Published var selectedLayerIDs: Set<UUID> = []
    @Published var activeLayerID: UUID? {
        didSet {
            if activeLayerID != oldValue { isMaskSelected = false }
            selectedLayerIDs = activeLayerID.map { [$0] } ?? []
        }
    }
    @Published var renamingLayerID: UUID? { didSet { resumeFileRequests() } }
    let history = DocumentHistory()
    private var childCancellables = Set<AnyCancellable>()

    init() {
        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childCancellables)
        forward($colorPicker)
        forward($levels)
        forward($hueSaturation)
        forward($filterEdit)
    }

    private func forward<Object: ObservableObject>(_ publisher: Published<Object?>.Publisher) {
        publisher
            .compactMap { $0 }
            .flatMap { $0.objectWillChange }
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childCancellables)
    }

    var isModified: Bool { history.isModified }
    var canUseHistory: Bool {
        _ = showsBusy
        return selectionAmountOperation == nil && textDraft == nil && !isProjectBusy && !isImporting && brushStroke == nil && warpStroke == nil && levels == nil && !showsNewDocument && !showsImporter && renamingLayerID == nil && importError == nil && transformEdit == nil
    }
    var canUndo: Bool { canUseHistory && (history.canUndo || gradientEdit != nil) }
    var canRedo: Bool { canUseHistory && history.canRedo }

    func undo() {
        // Like Photoshop, the first Undo discards a pending gradient.
        if gradientEdit != nil { cancelGradient(); return }
        guard canUndo, let snapshot = history.undo() else { return }
        restore(snapshot)
    }

    func redo() {
        guard canRedo, let snapshot = history.redo() else { return }
        restore(snapshot)
    }

    private func restore(_ snapshot: DocumentHistory.Snapshot) {
        cancelCrop()
        cancelGradient()
        let changedCanvas = document?.id != snapshot.document?.id
        let keepMaskTarget = isMaskSelected && activeLayerID == snapshot.activeLayerID
        document = snapshot.document
        activeLayerID = snapshot.activeLayerID
        isMaskSelected = keepMaskTarget && activeLayer?.mask != nil
        if changedCanvas, let document { viewport.fit(documentSize: document.size) }
    }

    /// Nestable transaction boundary; future tools can group a complete gesture.
    func beginEdit(_ name: String) {
        history.begin(name, document: document, selection: activeLayerID)
    }

    func endEdit() { history.end(document: document, selection: activeLayerID) }
    var activeLayer: ImageLayer? { document?.layers.first { $0.id == activeLayerID } }
    var canEditLayers: Bool {
        _ = showsBusy
        return selectionAmountOperation == nil && textDraft == nil && document != nil && brushStroke == nil && warpStroke == nil && !isProjectBusy && !isImporting && !showsNewDocument && !showsImporter && renamingLayerID == nil && transformEdit == nil && cropRect == nil && gradientEdit == nil && pixelMove == nil && hueSaturation == nil && levels == nil && filterEdit == nil && adjustmentEditingID == nil
    }

    func addBlankLayer() {
        guard canEditLayers, let document else { return }
        let names = Set(document.layers.map(\.name))
        var number = 1
        while names.contains("Layer \(number)") { number += 1 }
        var layer = ImageLayer(name: "Layer \(number)", blankSize: document.size)
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        var insertion = document.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? document.layers.count
        // With a folder selected the layer goes to the top of the folder: just above its last (topmost) contents.
        if activeLayer?.isGroup == true, let folder = activeLayerID {
            let parents = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0.parentID) })
            func isInside(_ id: UUID) -> Bool {
                var parent = parents[id] ?? nil
                var steps = 0
                while let current = parent, steps < 64 {
                    if current == folder { return true }
                    parent = parents[current] ?? nil
                    steps += 1
                }
                return false
            }
            if let topmost = document.layers.lastIndex(where: { isInside($0.id) }) { insertion = max(insertion, topmost + 1) }
        }
        beginEdit("New Blank Layer")
        defer { endEdit() }
        self.document?.layers.insert(layer, at: insertion)
        activeLayerID = layer.id
    }

    func deleteLayer(_ id: UUID) {
        guard canEditLayers, document?.layers.contains(where: { $0.id == id }) == true else { return }
        guard !deleteWithLiveMaskChoice(id) else { return }
        finishDeletingLayer(id, baked: [:])
    }

    func deleteActiveLayer() {
        if let activeLayerID { deleteLayer(activeLayerID) }
    }

    /// Deletes every selected layer as one undo step (a selected folder takes its contents); with one
    /// layer selected, just that one.
    func deleteSelectedLayers() {
        guard canEditLayers, let document else { return }
        // Captured first: deleting moves the active layer, which resets the selection.
        let ids = document.layers.map(\.id).filter(selectedLayerIDs.contains)
        guard ids.count > 1 else { deleteActiveLayer(); return }
        guard !deleteWithLiveMaskChoice(ids) else { return }
        finishDeletingLayers(ids, baked: [:])
    }

    func renameLayer(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isProjectBusy, !isImporting, !name.isEmpty, let index = document?.layers.firstIndex(where: { $0.id == id }) else { return }
        beginEdit("Rename Layer")
        defer { endEdit() }
        document?.layers[index].name = name
    }

    func toggleLayerVisibility(_ id: UUID) {
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }) else { return }
        beginEdit(document?.layers[index].isVisible == true ? "Hide Layer" : "Show Layer")
        defer { endEdit() }
        document?.layers[index].isVisible.toggle()
    }

    /// Photoshop's eye swipe: pressing an eye shows or hides that layer, and dragging over other eyes gives them the
    /// same state, all as one undo step (`beginEdit` at the press, `endEdit` when the button comes up).
    func beginVisibilitySwipe(_ id: UUID) -> Bool? {
        guard canEditLayers, let layer = document?.layers.first(where: { $0.id == id }) else { return nil }
        let visible = !layer.isVisible
        beginEdit(visible ? "Show Layer" : "Hide Layer")
        setVisibilityInSwipe(id, visible: visible)
        return visible
    }
    func setVisibilityInSwipe(_ id: UUID, visible: Bool) {
        guard let index = document?.layers.firstIndex(where: { $0.id == id }),
              document?.layers[index].isVisible != visible else { return }
        document?.layers[index].isVisible = visible
    }
    func endVisibilitySwipe() { endEdit() }

    func reorderLayers(from offsets: IndexSet, to destination: Int) {
        guard canEditLayers, var layers = document?.layers.reversed().map({ $0 }),
              offsets.allSatisfy({ layers.indices.contains($0) }), (0...layers.count).contains(destination) else { return }
        // List order is top-to-bottom; the compositor stores bottom-to-top.
        layers.move(fromOffsets: offsets, toOffset: destination)
        beginEdit("Reorder Layers")
        defer { endEdit() }
        document?.layers = layers.reversed()
    }

    func canMoveActiveLayer(by offset: Int) -> Bool {
        guard canEditLayers, let activeLayer else { return false }
        let siblings = document?.layers.filter { $0.parentID == activeLayer.parentID } ?? []
        guard let index = siblings.firstIndex(where: { $0.id == activeLayer.id }) else { return false }
        return siblings.indices.contains(index + offset)
    }
    func moveActiveLayer(by offset: Int) {
        guard canMoveActiveLayer(by: offset), let activeLayer, let layers = document?.layers else { return }
        let siblings = layers.filter { $0.parentID == activeLayer.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == activeLayer.id }),
              let a = layers.firstIndex(where: { $0.id == activeLayer.id }),
              let b = layers.firstIndex(where: { $0.id == siblings[index + offset].id }) else { return }
        beginEdit("Reorder Layers")
        document?.layers.swapAt(a, b)
        endEdit()
    }
    private struct ImportRequest {
        let files: [(url: URL, scoped: Bool)]
        let point: CGPoint?
        let completion: CheckedContinuation<Void, Never>
    }
    private var pendingImports: [ImportRequest] = []

    func importImages(_ urls: [URL], at point: CGPoint? = nil) async {
        guard !urls.isEmpty else { return }
        if brushStroke != nil { await finishBrush() }
        cancelCrop()
        commitTransform()
        // Hold sandbox grants while requests wait behind an in-progress decode.
        let files = urls.map { (url: $0, scoped: $0.startAccessingSecurityScopedResource()) }
        await waitForProjectAccess()
        await withCheckedContinuation { completion in
            pendingImports.append(ImportRequest(files: files, point: point, completion: completion))
            if !isImporting {
                isImporting = true
                Task { await drainImports() }
            }
        }
    }

    private func drainImports() async {
        var failures: [String] = []
        while !pendingImports.isEmpty {
          let request = pendingImports.removeFirst()
          beginEdit("Import Images")
          // No document: the first successful image determines the canvas, regardless of drop point.
          let point = document == nil ? nil : request.point
          for (url, scoped) in request.files {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard url.isFileURL else { throw ImageImportError.unsupported }
                let usedPixels = document?.layers.reduce(0) { total, layer in
                    guard let image = layer.asset?.image else { return total }
                    return total + image.width * image.height
                } ?? 0
                let asset = try await ImageImporter.shared.decode(url, remainingPixels: 100_000_000 - usedPixels)
                insert(asset, centeredAt: point)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
          }
          endEdit()
          request.completion.resume()
        }
        isImporting = false
        if !failures.isEmpty { importError = failures.joined(separator: "\n\n") }
    }

    func insert(_ asset: ImportedImage, centeredAt point: CGPoint? = nil) {
        beginEdit("Import Image")
        defer { endEdit() }
        if document == nil {
            document = CanvasDocument(width: asset.image.width, height: asset.image.height)
            viewport.fit(documentSize: document!.size)
        }
        guard let document else { return }
        let center = point ?? CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        var layer = ImageLayer(asset: asset, origin: CGPoint(
            x: floor(center.x - CGFloat(asset.image.width) / 2),
            y: floor(center.y - CGFloat(asset.image.height) / 2)))
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        self.document?.layers.append(layer)
        activeLayerID = layer.id
    }

    /// `emptyLayer` starts the canvas with a selected blank "Layer 1", as File > New does.
    func createDocument(width: Int, height: Int, emptyLayer: Bool = false) {
        guard !isProjectBusy, !isImporting, (1...30_000).contains(width), (1...30_000).contains(height) else { return }
        commitTransform()
        beginEdit("New Canvas")
        defer { endEdit() }
        var document = CanvasDocument(width: width, height: height)
        let layer = emptyLayer ? ImageLayer(name: "Layer 1", blankSize: document.size) : nil
        if let layer { document.layers = [layer] }
        self.document = document
        activeLayerID = layer?.id
        renamingLayerID = nil
        viewport.fit(documentSize: document.size)
        showsNewDocument = false
    }

    func fit() {
        guard let document else { return }
        viewport.fit(documentSize: document.size)
    }

    func zoom(to value: CGFloat, anchor: CGPoint? = nil) {
        guard let document else { return }
        viewport.setZoom(value, anchoredAt: anchor ?? viewport.center, documentSize: document.size)
    }

    /// Photoshop-style keyboard zoom: move one stable zoom stop while keeping the current viewport center fixed.
    func zoomKeyboard(by step: Int) {
        guard let document, step != 0 else { return }
        let target = viewport.keyboardZoomTarget(by: step)
        guard target != viewport.zoom else { return }
        viewport.setZoom(target, anchoredAt: viewport.center, documentSize: document.size)
    }
}
