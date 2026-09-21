import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// The Layers panel's width, remembered across launches.
    @AppStorage("layersPanelWidth") private var layersPanelWidth = 252.0
    @ObservedObject var session: EditorSession
    @Environment(\.locale) private var locale
    var applicationDelegate: CompositorApplicationDelegate? = nil
    @State private var canvasFrame: CGRect = .zero
    @State private var levelsPanel = FloatingPanelController(name: "levelsPanel")
    @State private var adjustmentPanel = FloatingPanelController(name: "adjustmentPanel")
    @State private var selectionAmountPanel = FloatingPanelController(name: "selectionAmountPanel")
    @State private var filterPanel = FloatingPanelController(name: "filterPanel")
    @State private var effectsPanel = FloatingPanelController(name: "effectsPanel")
    @State private var isDropTargeted = false
    /// The window's width, so the tab strip can use the toolbar's free space.
    @State private var windowWidth: CGFloat = 1180
    /// A layer dragged from this canvas's own tab has nowhere to go, so the canvas doesn't light up for it.
    private var acceptsDrop: Bool {
        guard let workspace = applicationDelegate?.workspace else { return true }
        return workspace.canReceiveDrag(into: workspace.current.id)
    }
    // Extracted from `body`: as one expression the type checker times out (Xcode 26.1).
    @ViewBuilder private var toolHeaders: some View {
        Group {
            if session.tool == .move {
                TransformInspector(session: session).id(session.activeLayerID)
                Divider()
            }
            if session.tool.isBrushTool {
                BrushControls(session: session)
                Divider()
            }
            if session.tool.isSelectionTool {
                LassoControls(session: session)
                Divider()
            }
            if session.tool == .gradient {
                GradientControls(session: session)
                Divider()
            }
            if session.tool == .type {
                TypeControls(session: session)
                Divider()
            }
            if session.tool == .shape {
                ShapeControls(session: session)
                Divider()
            }
            if session.tool == .eyedropper {
                HStack(spacing: 16) {
                    Text("Eyedropper").font(ToolHeaderStyle.titleFont)
                    Toggle("Sample Ring", isOn: $session.showsSampleRing).toggleStyle(.checkbox)
                    Spacer()
                }.padding(.horizontal, 18).toolHeaderBar()
                Divider()
            }
            if session.tool == .hand || session.tool == .zoom {
                NavigationToolHeader(session: session)
                Divider()
            }
            if session.tool == .crop {
                CropControls(session: session)
                Divider()
            }
            // No tool (A) keeps the header, so the canvas doesn't jump.
            if session.tool == .idle {
                HStack(spacing: 16) {
                    Text("Select a tool").font(ToolHeaderStyle.titleFont)
                    Spacer()
                }.padding(.horizontal, 18).toolHeaderBar()
                Divider()
            }
        }
    }

    @ViewBuilder private var editorStack: some View {
        VStack(spacing: 0) {
            toolHeaders
            HStack(spacing: 0) {
                toolRail
                Divider()
                VStack(spacing: 0) {
                    if session.showsRulers, session.document != nil {
                        HStack(spacing: 0) {
                            CanvasRulerCorner()
                            CanvasRulerView(session: session, axis: .horizontal)
                                .frame(height: CanvasRuler.thickness)
                        }
                    }
                    HStack(spacing: 0) {
                        if session.showsRulers, session.document != nil {
                            CanvasRulerView(session: session, axis: .vertical)
                                .frame(width: CanvasRuler.thickness)
                        }
                        ZStack {
                            EditorCanvas(session: session)
                            if session.document == nil { welcome }
                        }
                        .onGeometryChangeCompat(for: CGRect.self) { $0.frame(in: .named("editor")) } action: { canvasFrame = $0 }
                    }
                }
                PanelResizeEdge(width: $layersPanelWidth, range: LayersPanel.widths)
                LayersPanel(session: session, width: layersPanelWidth)
            }
            Divider()
            // Keeps its own height however short the window gets; the tools scroll instead.
            statusBar.fixedSize(horizontal: false, vertical: true)
                .modifier(WidthReader(width: $windowWidth))
        }
    }

    // Split again for 1.1: the chain outgrew the type checker once more.
    @ViewBuilder private var editorChrome: some View {
        editorStack
        .background(Color(white: 0.14))
        .background {
            if let applicationDelegate, applicationDelegate.projects.workspace == nil {
                ProjectWindowBridge(controller: applicationDelegate.projects).frame(width: 0, height: 0)
            }
        }
        .frame(minWidth: 800, minHeight: 520)
        .coordinateSpace(name: "editor")
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, ProjectWorkspace.layerType], isTargeted: $isDropTargeted) { providers, location in
            guard session.levels == nil, !session.isProjectBusy, !session.showsNewDocument, !session.showsImporter, session.renamingLayerID == nil else { return false }
            let point: CGPoint?
            if let document = session.document, canvasFrame.contains(location) {
                point = session.viewport.documentPoint(
                    from: CGPoint(x: location.x - canvasFrame.minX, y: location.y - canvasFrame.minY),
                    documentSize: document.size)
            } else { point = nil }
            if let workspace = applicationDelegate?.workspace {
                let destination = workspace.current.id
                guard workspace.canSwitch, workspace.canReceiveDrag(into: destination) else { return false }
                Task { await workspace.receiveProviders(providers, into: destination, at: point) }
            } else {
                Task { await ImageFileDrop.importProviders(providers, into: session, at: point) }
            }
            return true
        }
        .overlay {
            if isDropTargeted, acceptsDrop {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: max(0, canvasFrame.width - 6), height: max(0, canvasFrame.height - 6))
                    .position(x: canvasFrame.midX, y: canvasFrame.midY)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { applicationDelegate?.showEditor = { applicationDelegate?.showEditorWindow() } }
        .preferredColorScheme(.dark)
        .navigationTitle(session.projectURL?.deletingPathExtension().lastPathComponent ?? L10n.text("Untitled", locale: locale))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { requestNewCanvas() } label: { Label("New canvas", systemImage: "plus") }
                    .help("New canvas (⌘N)").accessibilityIdentifier("newCanvasToolbar")
                    .disabled(session.isImporting || session.showsBusy || session.levels != nil)
                    .modifier(NewProjectDropTarget(workspace: applicationDelegate?.workspace))
            }
            ToolbarItem(placement: .navigation) { Spacer().frame(width: 1) }
            ToolbarItem(placement: .navigation) {
                Group {
                    if let workspace = applicationDelegate?.workspace {
                        ProjectTabStrip(workspace: workspace)
                            // As wide as the toolbar allows: the window less the traffic lights and New button before it
                            // and the zoom controls after it. Bounded, so adding tabs never pushes those aside; the
                            // strip scrolls instead.
                            .frame(width: max(200, windowWidth - 352), height: 34, alignment: .center)
                    }
                }
            }
            // Absorb all remaining navigation-toolbar width before the zoom controls.
            // Without this spacer, the growing tab strip pushes the primary actions left.
            ToolbarItem(placement: .navigation) { Spacer() }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Fit") { session.fit() }.help("Fit canvas in window (⌘0)")
                    .accessibilityIdentifier("fitCanvas").disabled(session.document == nil)
                Button("100%") { session.zoom(to: 1) }.help("Actual pixels (⌘1)")
                    .accessibilityIdentifier("actualPixels").disabled(session.document == nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { session.zoomKeyboard(by: 1) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }.help("Zoom in (⌘+)").disabled(session.document == nil)
                Button { session.zoomKeyboard(by: -1) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }.help("Zoom out (⌘−)").disabled(session.document == nil)
            }
        }
    }

    var body: some View {
        let panels = editorChrome
        .onValueChangeCompat(of: session.levels == nil) { _, closed in
            if closed { levelsPanel.close() }
            else {
                levelsPanel.onClose = { session.cancelLevels() }
                levelsPanel.show(title: L10n.text("Levels", locale: locale), content: LevelsSheet(session: session))
            }
        }
        .onValueChangeCompat(of: session.hueSaturation == nil) { _, closed in
            if closed { adjustmentPanel.close() }
            else {
                adjustmentPanel.onClose = { session.cancelHueSaturation() }
                adjustmentPanel.show(title: L10n.text("Hue/Saturation", locale: locale), content: HueSaturationSheet(session: session))
            }
        }
        .onValueChangeCompat(of: session.effectsEditing) { _, selection in
            if let selection {
                effectsPanel.onClose = { session.finishEffectsEditing(commit: false) }
                effectsPanel.show(title: selection.kind.localizedName(locale: locale), content: EffectsSheet(session: session, kind: selection.kind))
            } else { effectsPanel.close() }
        }
        .onValueChangeCompat(of: session.document?.layers) { _, layers in
            if let editing = session.effectsEditing,
               layers?.first(where: { $0.id == editing.layerID })?.effects?.contains(editing.kind) != true {
                if let picker = session.colorPicker, case .effect = picker.target { session.closeColorPicker(commit: false) }
                session.effectsEditing = nil
                session.effectsEditingOriginal = nil
            }
        }
        .onValueChangeCompat(of: session.selectionAmountOperation) { _, operation in
            if let operation {
                selectionAmountPanel.onClose = { session.selectionAmountOperation = nil }
                selectionAmountPanel.show(title: L10n.text(operation.rawValue, locale: locale) + " " + L10n.text("Selection", locale: locale),
                    content: SelectionAmountSheet(session: session, operation: operation))
            } else { selectionAmountPanel.close() }
        }
        .onValueChangeCompat(of: session.filterEdit == nil) { _, closed in
            if closed { filterPanel.close() }
            else {
                filterPanel.onClose = { session.cancelFilter() }
                filterPanel.show(title: session.filterEdit?.kind.localizedName(locale: locale) ?? L10n.text("Filter", locale: locale), content: FilterSheet(session: session))
            }
        }
        .onValueChangeCompat(of: session.document == nil) { _, empty in
            if !empty { session.canvasFocusRequest += 1 }
        }
        let imported = panels
        .fileImporter(isPresented: $session.showsImporter,
                      allowedContentTypes: UTType.importableImages, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await session.importImages(urls) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { session.importError = error.localizedDescription }
            }
        }
        return imported
        .alert("Import couldn’t finish", isPresented: Binding(
            get: { session.importError != nil }, set: { if !$0 { session.importError = nil } })) {
                Button("OK", role: .cancel) { session.importError = nil }
            } message: { Text(session.importError ?? "") }
        .alert("Couldn’t paint", isPresented: Binding(get: { session.brushError != nil },
            set: { if !$0 { session.brushError = nil } })) {
                Button("OK") { session.brushError = nil }
            } message: { Text(session.brushError ?? "") }
        .alert("Couldn’t crop", isPresented: Binding(get: { session.cropError != nil },
            set: { if !$0 { session.cropError = nil } })) {
                Button("OK") { session.cropError = nil }
            } message: { Text(session.cropError ?? "") }
    }

    @ViewBuilder
    private var editorToolHeader: some View {
        if session.tool == .move {
            TransformInspector(session: session).id(session.activeLayerID)
            Divider()
        }
        if session.tool.isBrushTool {
            BrushControls(session: session)
            Divider()
        }
        if session.tool.isSelectionTool {
            LassoControls(session: session)
            Divider()
        }
        if session.tool == .gradient {
            GradientControls(session: session)
            Divider()
        }
        if session.tool == .type {
            TypeControls(session: session)
            Divider()
        }
        if session.tool == .shape {
            ShapeControls(session: session)
            Divider()
        }
        if session.tool == .eyedropper {
            HStack(spacing: 16) {
                Text("Eyedropper").font(ToolHeaderStyle.titleFont)
                Toggle("Sample Ring", isOn: $session.showsSampleRing).toggleStyle(.checkbox)
                Spacer()
            }.padding(.horizontal, 18).toolHeaderBar()
            Divider()
        }
        if session.tool == .hand || session.tool == .zoom {
            NavigationToolHeader(session: session)
            Divider()
        }
        if session.tool == .crop {
            CropControls(session: session)
            Divider()
        }
        // No tool (A) keeps the header, so the canvas doesn't jump.
        if session.tool == .idle {
            HStack(spacing: 16) {
                Text("Select a tool").font(ToolHeaderStyle.titleFont)
                Spacer()
            }.padding(.horizontal, 18).toolHeaderBar()
            Divider()
        }
    }

    private var editorCanvasArea: some View {
        HStack(spacing: 0) {
            toolRail
            Divider()
            VStack(spacing: 0) {
                if session.showsRulers, session.document != nil {
                    HStack(spacing: 0) {
                        CanvasRulerCorner()
                        CanvasRulerView(session: session, axis: .horizontal)
                            .frame(height: CanvasRuler.thickness)
                    }
                }
                HStack(spacing: 0) {
                    if session.showsRulers, session.document != nil {
                        CanvasRulerView(session: session, axis: .vertical)
                            .frame(width: CanvasRuler.thickness)
                    }
                    ZStack {
                        EditorCanvas(session: session)
                        if session.document == nil { welcome }
                    }
                    .onGeometryChangeCompat(for: CGRect.self) { $0.frame(in: .named("editor")) } action: { canvasFrame = $0 }
                }
            }
            PanelResizeEdge(width: $layersPanelWidth, range: LayersPanel.widths)
            LayersPanel(session: session, width: layersPanelWidth)
        }
    }

    private func requestNewCanvas() {
        if let applicationDelegate { Task { await applicationDelegate.projects.newCanvas() } }
        else { session.clearProject() }
    }
    private var toolRail: some View {
        // Scrolls when the window is too short for every tool, rather than pushing the bars above and below away.
        ScrollView(.vertical) {
        VStack(spacing: 10) {
            ForEach(NavigationTool.allCases.filter { $0 != .idle }, id: \.self) { tool in
                Button { session.selectTool(tool) } label: {
                    Group {
                        if tool == .gradient { GradientToolIcon().frame(width: 18, height: 18) }
                        else if tool == .cloneStamp { CloneStampToolIcon().frame(width: 18, height: 18) }
                        else if tool == .lasso, session.lassoKind == .polygonal { PolygonalLassoToolIcon().frame(width: 18, height: 18) }
                        else if tool == .wand, session.wandMode == .object { ObjectSelectionToolIcon().frame(width: 18, height: 18) }
                        // The Marquee's icon follows its shape: a dashed circle in Ellipse mode.
                        else { Image(systemName: tool == .marquee && session.marqueeKind == .ellipse ? "circle.dashed" : session.symbol(for: tool)).font(.system(size: 17)) }
                    }
                    .frame(width: 36, height: 36)
                        .background(session.tool == tool ? Color.white.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(session.tool == tool ? Color.white.opacity(0.14) : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(tool.localizedLabel(locale: locale)).accessibilityLabel(tool.localizedLabel(locale: locale))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
            }
            ColorPaletteControls(session: session).padding(.top, 8)
        }
        .padding(.top, 16).padding(.bottom, 12)
        }
        .legacyScrollIndicatorsHidden()
        // Only scrolls (and bounces) when the tools don't all fit.
        .legacyScrollBounceBasedOnSize()
        .frame(width: 56)
    }
    private var welcome: some View {
        NewCanvasSheet(session: session,
            onCreate: { session.createNewProject(width: $0, height: $1) },
            onOpen: { Task { await applicationDelegate?.projects.open() } })
    }
    private var statusBar: some View {
        HStack(spacing: 16) {
            if let document = session.document {
                Text(session.viewport.zoom, format: .percent.precision(.fractionLength(0...1)))
                    .frame(width: 62, alignment: .leading).accessibilityIdentifier("zoomStatus")
                Text(String(format: L10n.text("canvas.dimensions", locale: locale), document.width, document.height)).accessibilityIdentifier("canvasDimensions")
                Text("sRGB · Transparent")
            } else { Text("Ready when you are") }
            Spacer()
            if session.showsBusy {
                ProgressView().controlSize(.mini)
                Text("Working…")
            } else if session.isImporting {
                ProgressView().controlSize(.mini)
                Text("Importing images…")
            } else {
                Text(L10n.statusHint(for: session, locale: locale))
            }
        }
        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        .padding(.horizontal, 18).frame(height: 30)
        .accessibilityElement(children: .contain)
    }
}

/// A panel's divider that resizes the panel to its right: drag left to widen, right to narrow, within `range`.
private struct PanelResizeEdge: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Divider().overlay {
            Color.clear.frame(width: 8).contentShape(Rectangle())
                .legacyColumnResizePointer()
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(range.upperBound, max(range.lowerBound, (start - value.translation.width).rounded()))
                    }
                    .onEnded { _ in startWidth = nil })
                .help("Drag to resize the panel")
        }
    }
}

extension View {
    /// Bordered buttons and pop-up menus drawn as capsules throughout the app. Borderless and plain buttons (the tool
    /// rail, the Layers panel footer) have no border to shape, so they're unaffected.
    @ViewBuilder
    func roundedControls() -> some View {
        if #available(macOS 14.0, *) {
            buttonBorderShape(.capsule)
        } else {
            self
        }
    }

    @ViewBuilder
    func legacyColumnResizePointer() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.columnResize)
        } else {
            self
        }
    }
}

extension View {
    /// Return or Escape in a property field gives up its focus and hands it back to the canvas, so a tool's key
    /// works straight away instead of typing into the field.
    func releasesFocusOnCommit(_ session: EditorSession) -> some View {
        onSubmit { session.canvasFocusRequest += 1 }
            .onExitCommand { session.canvasFocusRequest += 1 }
    }
}

/// What a field's key monitor reads. The monitor outlives the view value that installed it, so reading the value
/// and applying the step go through here, refreshed on every redraw.
@MainActor final class ArrowStepper {
    var editing = false
    var value: () -> Double = { 0 }
    var change: (Double) -> Void = { _ in }
    private var monitor: Any?

    /// Takes Up and Down while the field holds focus: one step, or ten with Shift.
    func listen(step: Double) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only while a field really is being edited: a field left behind (its tool bar swapped out, say) must not
            // keep taking Up and Down from the canvas, where they nudge the layer.
            guard let self, self.editing, event.keyCode == 126 || event.keyCode == 125,
                  NSApp.keyWindow?.firstResponder is NSTextView else { return event }
            let amount = step * (event.modifierFlags.contains(.shift) ? 10 : 1)
            self.change(self.value() + (event.keyCode == 126 ? amount : -amount))
            return nil
        }
    }
    func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        editing = false
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// Up and Down nudge the value in a focused property field, Shift by ten times as much — a text field takes the
/// arrow keys for its insertion point, so they are caught while it holds focus.
private struct ArrowStepping: ViewModifier {
    let step: Double
    let value: () -> Double
    let change: (Double) -> Void
    @FocusState private var focused: Bool
    @State private var stepper = ArrowStepper()
    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onValueChangeCompat(of: focused) { _, editing in
                stepper.editing = editing
                editing ? stepper.listen(step: step) : stepper.stopListening()
            }
            .onDisappear { stepper.stopListening() }
            .onAppear { refresh() }
            .onValueChangeCompat(of: value()) { _, _ in refresh() }
    }
    private func refresh() {
        stepper.value = value
        stepper.change = change
    }
}

extension View {
    /// Up and Down step this field's value; each field's own binding keeps it in range.
    func arrowSteps(_ step: Double = 1, value: @escaping () -> Double, change: @escaping (Double) -> Void) -> some View {
        modifier(ArrowStepping(step: step, value: value, change: change))
    }
    /// The same, for a field that already owns its focus: it says when it is being edited.
    func arrowSteps(_ step: Double = 1, editing: Bool, stepper: ArrowStepper,
                    value: @escaping () -> Double, change: @escaping (Double) -> Void) -> some View {
        onAppear { stepper.value = value; stepper.change = change }
            .onValueChangeCompat(of: value()) { _, _ in stepper.value = value; stepper.change = change }
            .onValueChangeCompat(of: editing) { _, active in
                stepper.editing = active
                stepper.value = value
                stepper.change = change
                active ? stepper.listen(step: step) : stepper.stopListening()
            }
            .onDisappear { stepper.stopListening() }
    }
}

/// Reports the width it is laid out at. Kept out of the editor's body, whose type-checking is already near its limit.
private struct WidthReader: ViewModifier {
    @Binding var width: CGFloat
    func body(content: Content) -> some View {
        content.onGeometryChangeCompat(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
