import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrushPalettePresenter: ViewModifier {
    let session: EditorSession
    @State private var panel = FloatingPanelController(name: "brushPalette")
    @State private var editing: BrushPreset?
    @State private var reopen = false

    func body(content: Content) -> some View {
        content
            .onChange(of: session.showsBrushPalette) { _, visible in
                if visible {
                    panel.onClose = { session.showsBrushPalette = false }
                    panel.show(title: "Brushes", content: BrushPalette(session: session) { brush in
                        var draft = brush
                        if brush.id == session.selectedBrushPresetID { draft.capture(session.brushSettings) }
                        session.showsBrushPalette = false
                        session.finishBrushImmediately()
                        session.isEditingBrushPreset = true
                        editing = draft
                    }.preferredColorScheme(.dark))
                } else { panel.close() }
            }
            .sheet(item: $editing, onDismiss: {
                session.isEditingBrushPreset = false
                if reopen { session.showsBrushPalette = true }
                else { session.canvasFocusRequest += 1 }
            }) { brush in
                BrushEditorSheet(brush: brush, color: session.foregroundColor) { saved in
                    if let saved {
                        if saved.isRenderable { try session.activateBrushPreset(saved) }
                        else { try BrushLibrary.shared.save(saved, select: false) }
                    }
                    reopen = saved == nil
                    editing = nil
                }.roundedControls().preferredColorScheme(.dark)
            }
            .onDisappear { panel.close() }
    }
}

private struct BrushPalette: View {
    @Bindable var session: EditorSession
    let edit: (BrushPreset) -> Void
    @State private var selectedIDs: Set<UUID> = []
    @State private var deleting: [BrushPreset] = []
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var activationError: String?
    @State private var errorTitle = "Couldn’t select brush"
    @State private var importing = false
    @State private var importStatus: String?
    @State private var importDiagnostics: [String] = []
    @State private var collection = "All Brushes"
    private var library: BrushLibrary { .shared }
    private var shown: [BrushPreset] {
        library.brushes.filter {
            (collection == "All Brushes" || ($0.source?.collectionName ?? ($0.source == nil ? "Compositor" : $0.source!.filename)) == collection)
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.source?.collectionName?.localizedCaseInsensitiveContains(search) == true)
        }
    }
    private var selectedBrushes: [BrushPreset] { shown.filter { selectedIDs.contains($0.id) } }
    private var selectedBrush: BrushPreset? { selectedBrushes.count == 1 ? selectedBrushes.first : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Brushes").font(.headline)
                Spacer()
                Button("Edit") {
                    if let selectedBrush { edit(selectedBrush) }
                }.disabled(selectedBrush == nil)
                Button("New Brush") { edit(BrushPreset(name: "Untitled Brush")) }
            }
            TextField("Search Brushes", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search Brushes").focused($searchFocused)
            HStack {
                Picker("Collection", selection: $collection) {
                    Text("All Brushes").tag("All Brushes")
                    Text("Compositor").tag("Compositor")
                    ForEach(Array(Set(library.brushes.compactMap { $0.source.map { $0.collectionName ?? $0.filename } })).sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
                }.labelsHidden().accessibilityLabel("Brush collection")
                Spacer()
                Button { deleting = selectedBrushes } label: { Image(systemName: "trash") }
                    .help("Delete selected brushes").accessibilityLabel("Delete selected brushes")
                    .disabled(selectedBrushes.isEmpty || library.error != nil)
                Button("Import…") { beginImport() }.disabled(importing || library.error != nil)
                if importing { ProgressView().controlSize(.small) }
            }
            Divider()
            if let error = library.error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let importStatus { Text(importStatus).font(.caption).foregroundStyle(.secondary) }
            if !importDiagnostics.isEmpty {
                DisclosureGroup("Import details (\(importDiagnostics.count))") {
                    ScrollView {
                        Text(importDiagnostics.joined(separator: "\n")).textSelection(.enabled)
                            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 110)
                }
            }
            List(selection: $selectedIDs) {
                ForEach(shown) { brush in
                    HStack(spacing: 12) {
                        if brush.source != nil {
                            Image(systemName: "doc").frame(width: 42, height: 42).accessibilityHidden(true)
                        } else {
                            Circle().fill(.primary.opacity(brush.opacity))
                                .blur(radius: (1 - brush.hardness) * 3)
                                .frame(width: 24, height: 24).frame(width: 42, height: 42)
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(brush.name).lineLimit(1)
                            Text(brush.source != nil ? (brush.isRenderable ? "Native shape approximation" : "Source preserved · Rendering unavailable") : brush.id == session.selectedBrushPresetID ? "Current brush" : "Compositor brush")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if brush.id == session.selectedBrushPresetID { Image(systemName: "checkmark") }
                    }.padding(4).contentShape(Rectangle()).tag(brush.id)
                        .help(brush.isRenderable ? "Use " + brush.name : "Rendering unavailable. Use Edit to inspect the retained source.")
                }
                if shown.isEmpty {
                    Text("No brushes match your search.").foregroundStyle(.secondary).padding(.vertical, 20)
                    Button("Clear Search") { search = "" }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .accessibilityLabel("Brushes")
            Divider()
            Text("⌘-click or Shift-click to select multiple brushes.").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 340, height: 420).font(ToolHeaderStyle.controlFont)
            .onAppear { selectedIDs = [session.selectedBrushPresetID]; searchFocused = true }
            .onChange(of: selectedIDs) { _, _ in
                guard let brush = selectedBrush, brush.isRenderable, brush.id != session.selectedBrushPresetID else { return }
                do { try session.activateBrushPreset(brush) }
                catch { errorTitle = "Couldn’t select brush"; activationError = error.localizedDescription }
            }
            .onChange(of: shown.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
            .confirmationDialog(deleting.count == 1 ? "Delete “\(deleting.first?.name ?? "")”?" : "Delete \(deleting.count) brushes?", isPresented: Binding(
                get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }), titleVisibility: .visible) {
                Button(deleting.count == 1 ? "Delete Brush" : "Delete \(deleting.count) Brushes", role: .destructive) {
                    do {
                        try session.deleteBrushPresets(Set(deleting.map(\.id)))
                        selectedIDs = []
                        if shown.isEmpty { collection = "All Brushes" }
                    } catch { errorTitle = "Couldn’t delete brushes"; activationError = error.localizedDescription }
                    deleting = []
                }
                Button("Cancel", role: .cancel) { deleting = [] }
            } message: {
                Text("These brushes will be removed from your library. Your original import files will not be changed.")
            }
            .alert(errorTitle, isPresented: Binding(get: { activationError != nil }, set: { if !$0 { activationError = nil } })) {
                Button("OK") { activationError = nil }
            } message: { Text(activationError ?? "") }
            .onExitCommand {
                if search.isEmpty { NSApp.keyWindow?.performClose(nil) }
                else { search = "" }
            }
    }
    private func beginImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["brush", "brushset", "brushlibrary", "zip"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        importStatus = "Importing brushes…"
        importDiagnostics = []
        Task { @MainActor in
            defer { importing = false }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let (original, result) = try await Task.detached(priority: .userInitiated) {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= 512 * 1024 * 1024 else { throw BrushImportError.invalid("Archive exceeds 512 MiB or is empty.") }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return (data, try ProcreateBrushImporter.read(data, filename: url.lastPathComponent))
                }.value
                let count = try library.importBrushes(result, original: original)
                importStatus = count == 0 ? "These brushes are already imported." : "Imported \(count) brushes. Use Edit to inspect source mappings and round approximations."
                importDiagnostics = result.diagnostics
                collection = "All Brushes"
            } catch {
                importStatus = "Import failed. Your collection is unchanged."
                errorTitle = "Couldn’t import brushes"
                activationError = error.localizedDescription
            }
        }
    }
}

struct BrushEditorSheet: View {
    @Bindable private var pen = PenInput.shared
    @State var brush: BrushPreset
    let color: PaletteColor
    let finish: (BrushPreset?) throws -> Void
    @State var category = "Properties"
    @State private var error: String?
    @State private var discard = false
    @State private var clear = UUID()
    @State private var original: BrushPreset?
    @State private var savedOriginal: BrushPreset?
    @State private var sourceComponent = 0
    @State private var showsSourceDetails = false
    @State private var previewBlack = false
    @State private var previewPaint: PaletteColor?
    @State private var inspectingTip = false
    @State private var inspectionImage: CGImage?
    @State private var previewError: String?
    @State private var resolving = false
    private let categories = ["Stroke Path", "Stabilization", "Taper", "Shape", "Grain", "Rendering", "Wet Mix", "Color Dynamics", "Dynamics", "Pen / Tablet", "Properties", "Dual Brush"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Brush Editor").font(.headline)
                TextField("Brush name", text: $brush.name).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260).accessibilityLabel("Brush name").disabled(brush.source != nil)
                if let source = brush.source, source.definitions.count > 1 {
                    Picker("Component", selection: $sourceComponent) {
                        ForEach(source.definitions.indices, id: \.self) { index in
                            Text(index == 0 ? "Primary" : "Secondary \(index)").tag(index)
                        }
                    }.frame(width: 160).accessibilityLabel("Source brush component")
                }
                Spacer()
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                List(categories, id: \.self, selection: $category) { Text($0).tag($0) }
                    .listStyle(.sidebar).frame(width: 150).accessibilityLabel("Brush settings categories")
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(category).font(.headline)
                        controls
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 340, idealWidth: 380)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(brush.isRenderable ? "Drawing Preview" : "Source Preview").font(.headline)
                            Spacer()
                            if brush.isRenderable { Button("Clear") { clear = UUID(); previewError = nil }.accessibilityLabel("Clear drawing preview") }
                        }
                        if let source = brush.source {
                            Text(brush.isRenderable ? "Native shape approximation only. Source dynamics and rendering are not reproduced." : "Rendering unavailable. Original source settings and assets are preserved.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            DisclosureGroup("Source Details", isExpanded: $showsSourceDetails) {
                                Text(source.filename)
                                if let member = source.memberPath { Text(member) }
                                if let issues = source.issues { Text(issues.joined(separator: "\n")) }
                                ForEach(source.definitions.indices, id: \.self) { index in
                                    let definition = source.definitions[index]
                                    Text(definition.path)
                                    if let shape = definition.shapeReference { Text("Shape: " + shape) }
                                    if let resolution = definition.shapeResolution { Text(resolution.summary) }
                                    if let grain = definition.grainReference { Text("Grain: " + grain) }
                                    if let resolution = definition.grainResolution { Text(resolution.summary) }
                                }
                            }.textSelection(.enabled)
                        }
                        if brush.isRenderable {
                            Picker("Preview Background", selection: $previewBlack) {
                                Text("White").tag(false)
                                Text("Black").tag(true)
                            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Preview background")
                            ColorPicker("Paint Color", selection: Binding(get: { (previewPaint ?? color).swiftUI }, set: {
                                if let picked = PaletteColor(NSColor($0)) { previewPaint = picked }
                            }), supportsOpacity: false)
                            BrushDrawingPreview(brush: brush, color: previewPaint ?? color, clear: clear, blackBackground: previewBlack) { previewError = $0 }
                                .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel("Brush drawing preview")
                        }
                        if brush.isRenderable {
                            Text("Draw here to try your settings.").foregroundStyle(.secondary)
                            Text("Mouse uses full pressure. Tablet pressure follows the enabled mappings.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let previewError { Text(previewError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Divider()
                        Text(brush.source == nil ? "Compositor brush" : (brush.isRenderable ? "Native shape approximation" : "Source brush")).font(.subheadline.bold())
                        Text(brush.source == nil ? "Native tip with shape dynamics. Remaining controls are marked Coming soon." : "Imported archive data is retained without claiming matching brush output. Other source settings are not applied.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }.frame(width: 250)
            }.frame(minHeight: 310, idealHeight: 440, maxHeight: 480)
            Divider()
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 12)
            }
            HStack(spacing: 10) {
                Button("Export Procreate…") {}.disabled(true)
                Text("Procreate export: Coming soon").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    error = nil
                    guard BrushLibrary.shared.brushes.first(where: { $0.id == brush.id }) == savedOriginal else {
                        error = "This brush was changed in another window. Cancel and reopen it to keep those changes."
                        return
                    }
                    do { try finish(brush) } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!brush.isValid || BrushLibrary.shared.error != nil || resolving)
            }.padding(20)
        }.font(ToolHeaderStyle.controlFont).frame(width: 850)
            .frame(maxHeight: max(380, min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 140)))
            .onChange(of: brush) { _, _ in previewError = nil }
            .onAppear {
                if brush.source != nil { category = "Shape" }
                original = brush
                savedOriginal = BrushLibrary.shared.brushes.first { $0.id == brush.id }
            }
            .interactiveDismissDisabled()
            .sheet(isPresented: $inspectingTip) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Mask Inspection").font(.headline)
                    if let inspectionImage {
                        Image(decorative: inspectionImage, scale: 1).resizable().interpolation(.none).scaledToFit()
                            .frame(width: 560, height: 460).background(Color.black)
                        Text("Derived mask: \(inspectionImage.width) × \(inspectionImage.height). Original bytes are retained; this view shows the mask actually sampled by the brush.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Done") { inspectingTip = false }.keyboardShortcut(.defaultAction)
                }.padding(20)
            }
            .confirmationDialog("Discard changes to “\(brush.name)” ?", isPresented: $discard) {
                Button("Discard Changes", role: .destructive) { try? finish(nil) }
                Button("Keep Editing", role: .cancel) {}
            }
    }
    private func cancel() {
        if original != brush { discard = true }
        else { try? finish(nil) }
    }
    @ViewBuilder private var controls: some View {
        switch category {
        case "Properties":
            if brush.isRenderable {
                slider("Size", value: $brush.diameter, range: 1...2000, unit: "px")
                slider("Opacity", value: $brush.opacity, range: 0.01...1, unit: "%", factor: 100)
            } else {
                Text("Imported values are retained in the source archive; no native settings mapping is available.")
                    .font(.caption).foregroundStyle(.secondary)
                pending(["Size", "Opacity"], title: "Source mapping: Coming soon")
            }
            Toggle("Orient to Screen", isOn: setting(\.properties, BrushProperties(), \.orientToScreen))
            slider("Minimum Size", value: setting(\.properties, BrushProperties(), \.minimumSize), range: 1...2000, unit: "px")
            slider("Maximum Size", value: setting(\.properties, BrushProperties(), \.maximumSize), range: 1...2000, unit: "px")
            slider("Minimum Opacity", value: setting(\.properties, BrushProperties(), \.minimumOpacity), range: 0...1, unit: "%", factor: 100)
            slider("Maximum Opacity", value: setting(\.properties, BrushProperties(), \.maximumOpacity), range: 0.01...1, unit: "%", factor: 100)
            slider("Smudge Pull", value: setting(\.properties, BrushProperties(), \.smudgePull), range: 0...1, unit: "%", factor: 100)
            Text("Bounds constrain native brush size and pressure response. Minimum must not exceed maximum. Screen orientation fixes the tip in canvas coordinates; off follows the layer rotation. Smudge Pull scales the Smudge tool's strength.")
                .font(.caption).foregroundStyle(.secondary)
            pending(["Preview Size", "Source Preview Settings"])
        case "Shape":
            if brush.source != nil {
                sourceReference("Original shape reference", reference: definition?.shapeReference)
                if let resolution = definition?.shapeResolution { Text(resolution.summary).foregroundStyle(.secondary) }
                Button(resolving ? "Resolving…" : "Refresh Mapping") { refreshMapping() }.disabled(resolving)
                Text("Native settings below apply to the primary component only. Original grain, dual components and source settings are retained.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .procedural(let basic, _) = brush.source?.definitions.first?.shapeResolution {
                Button("Use \(basic.generatedTip.rawValue) Tip") {
                    shapeValue(\.generator).wrappedValue = basic.generatedTip
                    shapeValue(\.source).wrappedValue = .generated
                }.disabled(sourceComponent != 0)
                Text("Native round-tip approximation. Flow and spacing control its buildup; original source settings stay preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Shape Source", selection: shapeValue(\.source)) {
                ForEach(ShapeBrushSettings.Source.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                        .disabled(source == .embedded && brush.source?.definitions.first?.tip == nil
                            || source == .custom && brush.roundDynamics.shapeSettings.customTip == nil)
                }
            }.disabled(sourceComponent != 0)
            HStack {
                Button("Import Shape…") { importShape() }.disabled(resolving || sourceComponent != 0)
                if brush.roundDynamics.shapeSettings.customTip != nil {
                    Button("Remove Custom") {
                        shapeValue(\.customTip).wrappedValue = nil
                        shapeValue(\.source).wrappedValue = brush.source?.definitions.first?.tip == nil ? .procedural : .embedded
                    }.disabled(sourceComponent != 0)
                }
            }
            if brush.roundDynamics.shapeSettings.source == .generated {
                Picker("Generated Style", selection: Binding(get: { brush.roundDynamics.shapeSettings.generatedKind },
                    set: { shapeValue(\.generator).wrappedValue = $0 })) {
                    ForEach(GeneratedBrushTip.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.disabled(sourceComponent != 0)
                Text("Independent Compositor substitute, not the original Procreate tip. Generated in memory; no source images are bundled or downloaded. Original references are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let tip = selectedTip, let image = tip.preview(brush.roundDynamics.shapeSettings.source == .generated ? .luminance : brush.roundDynamics.shapeSettings.mask) {
                Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFit()
                    .frame(width: 80, height: 80).accessibilityHidden(true)
                Button("Inspect Shape…") { inspectionImage = image; inspectingTip = true }
                Text(tip.name).font(.caption).foregroundStyle(.secondary)
                if brush.roundDynamics.shapeSettings.source != .generated {
                    Picker("Image Mask", selection: shapeValue(\.mask)) {
                        ForEach(ShapeBrushSettings.Mask.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.disabled(sourceComponent != 0)
                    Text("Derived mask is at most 256 × 256. Original bytes are retained. Hardness applies to procedural tips only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if brush.roundDynamics.shapeSettings.source != .procedural {
                Text("Selected shape image is unavailable. Refresh the original mapping or import a custom image.")
                    .foregroundStyle(.secondary)
            }
            if brush.source != nil {
                if brush.canApproximateShape {
                    Toggle("Use native shape approximation", isOn: Binding(get: {
                        brush.usesShapeApproximation || brush.usesRoundApproximation
                    }, set: {
                        brush.usesShapeApproximation = $0
                        brush.usesRoundApproximation = false
                    }))
                    Text("Uses the selected shape and native settings. This does not reproduce source dynamics or rendering.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Painting requires a supported primary shape, explicit grain setup for grain-backed brushes, and secondary-tip setup for dual brushes. Missing original assets remain unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if brush.isRenderable {
                Group {
                    if brush.roundDynamics.shapeSettings.source == .procedural {
                        slider("Hardness", value: $brush.hardness, range: 0...1, unit: "%", factor: 100)
                    }
                    slider("Roundness", value: dynamic(\.roundness), range: 0.05...1, unit: "%", factor: 100)
                    slider("Angle", value: dynamic(\.angle), range: -.pi...(.pi), unit: "°", factor: 180 / .pi)
                    Picker("Orientation Input", selection: shapeValue(\.inputStyle)) {
                        ForEach(ShapeBrushSettings.InputStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    slider("Stroke Rotation", value: shapeValue(\.rotationResponse), range: -1...1, unit: "%", factor: 100)
                    Toggle("Relative to Stroke", isOn: Binding(get: { brush.roundDynamics.shapeSettings.relativeToStroke ?? false },
                        set: { shapeValue(\.relativeToStroke).wrappedValue = $0 }))
                        .disabled(brush.roundDynamics.shapeSettings.inputStyle != .barrel)
                    Text("Stroke rotation: 0 fixes orientation; +100% follows direction; −100% follows inversely. Valid pen azimuth overrides this. Relative to Stroke adds path direction to azimuth/barrel orientation. Scatter 100% spans ±180°. Missing barrel rotation falls back to azimuth; missing tilt falls back to stroke rotation.")
                        .font(.caption).foregroundStyle(.secondary)
                    if brush.roundDynamics.shapeSettings.inputStyle != .touch && !pen.capabilities.tilt {
                        Text("Pen azimuth requires compatible tablet tilt; mapping is saved.").font(.caption).foregroundStyle(.secondary)
                    }
                    if brush.roundDynamics.shapeSettings.inputStyle == .barrel && !pen.capabilities.rotation {
                        Text("Barrel rotation is not reported; azimuth fallback remains available.").font(.caption).foregroundStyle(.secondary)
                    }
                    Stepper("Count: \(brush.roundDynamics.count)", value: dynamic(\.count), in: 1...16).accessibilityLabel("Dabs per stamp")
                    slider("Count Jitter", value: shapeValue(\.countJitter), range: 0...1, unit: "%", factor: 100)
                    slider("Angular Scatter", value: dynamic(\.scatter), range: 0...(.pi), unit: "%", factor: 100 / .pi)
                    Toggle("Randomize stroke orientation", isOn: shapeValue(\.randomized))
                    Toggle("Flip Horizontal", isOn: shapeValue(\.flipX))
                    Toggle("Flip Vertical", isOn: shapeValue(\.flipY))
                    slider("Horizontal Jitter", value: shapeValue(\.horizontalJitter), range: 0...1, unit: "%", factor: 100)
                    pathInput("Horizontal Jitter Input", value: shapeValue(\.horizontalInput), pressureOnly: true)
                    slider("Vertical Jitter", value: shapeValue(\.verticalJitter), range: 0...1, unit: "%", factor: 100)
                    pathInput("Vertical Jitter Input", value: shapeValue(\.verticalInput), pressureOnly: true)
                    slider("Pressure Roundness", value: shapeValue(\.pressureRoundness), range: 0...1, unit: "%", factor: 100)
                    slider("Tilt Roundness", value: shapeValue(\.tiltRoundness), range: 0...1, unit: "%", factor: 100)
                    if brush.roundDynamics.shapeSettings.pressureRoundness > 0 && !pen.capabilities.pressure {
                        Text("Pressure roundness requires compatible pressure input; mapping is saved.").font(.caption).foregroundStyle(.secondary)
                    }
                    if brush.roundDynamics.shapeSettings.tiltRoundness > 0 && !pen.capabilities.tilt {
                        Text("Tilt roundness requires compatible tilt input; mapping is saved.").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Filtering", selection: shapeValue(\.filtering)) {
                        ForEach(ShapeBrushSettings.Filtering.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Text("Jitter compresses each axis to at least 5%. Count jitter varies stamp count. None preserves mask pixels; Classic softens edges; Improved smooths rotated edges but costs more. Rotation and flips do not change a symmetric circle.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(sourceComponent != 0)
            } else { pending(["Roundness", "Angle", "Orientation Input", "Stroke Rotation", "Count", "Count Jitter", "Angular Scatter", "Randomize", "Flip Horizontal", "Flip Vertical", "Horizontal Jitter", "Vertical Jitter", "Pressure Roundness", "Tilt Roundness", "Filtering"], title: "Source rendering unavailable") }
        case "Stabilization":
            if brush.isRenderable { slider("Smoothing", value: $brush.smoothing, range: 0...100, unit: "") }
            else { pending(["Compositor Smoothing"], title: "Source mapping: Coming soon") }
            Text("Compositor Smoothing trails the pointer on a string. It is separate from source stabilization.")
                .font(.caption).foregroundStyle(.secondary)
            slider("StreamLine Amount", value: setting(\.stabilization, BrushStabilization(), \.streamline), range: 0...1, unit: "%", factor: 100)
            slider("StreamLine Pressure", value: setting(\.stabilization, BrushStabilization(), \.pressure), range: 0...1, unit: "%", factor: 100)
            slider("Stabilization", value: setting(\.stabilization, BrushStabilization(), \.stabilization), range: 0...1, unit: "%", factor: 100)
            slider("Motion Filtering", value: setting(\.stabilization, BrushStabilization(), \.motion), range: 0...1, unit: "%", factor: 100)
            slider("Expression", value: setting(\.stabilization, BrushStabilization(), \.expression), range: 0...1, unit: "%", factor: 100)
            Text("Native filters: StreamLine smooths positions/pressure; Stabilization adds position damping; Motion Filtering rejects small movements. Expression relaxes damping for larger movements. These are independent Compositor responses, not source algorithm mappings.")
                .font(.caption).foregroundStyle(.secondary)
        case "Pen / Tablet":
            if brush.isRenderable {
                Toggle("Pressure for size", isOn: $brush.pressureSize)
                Toggle("Pressure for opacity", isOn: $brush.pressureOpacity)
            } else { pending(["Pressure for size", "Pressure for opacity"], title: "Source mapping: Coming soon") }
            if brush.isRenderable { PressureCurveEditor(curve: dynamic(\.pressureCurve)) }
            else { pending(["Pressure Curve"], title: "Source mapping: Coming soon") }
            pending(["Pressure Flow", "Pressure Bleed", "Individual Property Response", "Tilt Response", "Barrel Rotation"])
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(pen.activeDeviceID == nil ? "Bring a tablet pen into range." : "Tablet device \(pen.activeDeviceID!)")
                Text("Pressure: " + (pen.capabilities.pressure ? "Available" : "Not reported"))
                Text("Tilt: " + (pen.capabilities.tilt ? "Driver reports both axes" : "Not reported"))
                Text("Barrel rotation: " + (pen.capabilities.rotation ? "Driver reports support" : "Not reported"))
                if let input = pen.lastInput {
                    if let tilt = input.tilt { Text(String(format: "Tilt X %.3f · Y %.3f", Double(tilt.x), Double(tilt.y))) }
                    if let angle = input.rotation { Text(String(format: "Rotation %.1f°", Double(angle * 180 / .pi))) }
                    if let time = input.timestamp { Text(String(format: "Sample time %.3f s", time)) }
                }
                Text("Mouse paints at full pressure. Saved mappings remain intact when a pen leaves range. Tilt/rotation mappings are available in Stroke Path and Shape. Other responses: Coming soon.")
            }.font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Tablet calibration") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sensor-space calibration applies to all tablets on this Mac. Hold the pen upright to zero tilt; hold its neutral barrel angle to zero rotation.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Zero Upright Tilt") { pen.zeroTilt() }.disabled(pen.rawInput?.tilt == nil)
                    Toggle("Reverse tilt X", isOn: $pen.reverseTiltX).disabled(!pen.capabilities.tilt)
                    Toggle("Reverse tilt Y", isOn: $pen.reverseTiltY).disabled(!pen.capabilities.tilt)
                    Button("Zero Barrel Rotation") { pen.zeroBarrelRotation() }.disabled(pen.rawInput?.rotation == nil)
                    Toggle("Reverse barrel rotation", isOn: $pen.reverseRotation).disabled(!pen.capabilities.rotation)
                    Button("Reset Calibration") { pen.resetCalibration() }
                }
            }
        case "Stroke Path":
            if brush.isRenderable {
                Toggle("Custom Spacing", isOn: Binding(get: { brush.roundDynamics.spacing != nil }, set: {
                    brush.roundDynamics.spacing = $0 ? BrushStroke.spacingFraction(brush.hardness) : nil
                }))
                if brush.roundDynamics.spacing != nil {
                    slider("Spacing", value: Binding(get: { brush.roundDynamics.spacing ?? 0.025 },
                        set: { brush.roundDynamics.spacing = $0 }), range: 0...4, unit: "%", factor: 100)
                }
                Text("Spacing is the distance between stamps as a percentage of brush size. Lower values overlap more; higher values separate the stamps. Off uses automatic spacing.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { pending(["Spacing"], title: "Source mapping: Coming soon") }
            if brush.isRenderable {
                slider("Spacing Jitter", value: pathValue(\.spacingJitter), range: 0...1, unit: "%", factor: 100)
                pathInput("Spacing Jitter Input", value: pathValue(\.spacingInput), pressureOnly: true)
                slider("Lateral Jitter", value: pathValue(\.lateralJitter), range: 0...1, unit: "%", factor: 100)
                pathInput("Lateral Jitter Input", value: pathValue(\.lateralInput))
                slider("Linear Jitter", value: pathValue(\.linearJitter), range: 0...1, unit: "%", factor: 100)
                pathInput("Linear Jitter Input", value: pathValue(\.linearInput))
                Text("Jitter distances are shares of full diameter. Spacing jitter adds up to one diameter; lateral and linear jitter shift stamps up to ±one diameter.")
                    .font(.caption).foregroundStyle(.secondary)
                slider("Falloff", value: pathValue(\.falloff), range: 0...1, unit: "%", factor: 100)
                Text("Zero keeps opacity constant. At 100%, opacity fades to zero over 20 brush diameters; smaller values fade more slowly.")
                    .font(.caption).foregroundStyle(.secondary)
                speedSpacingControls
            } else { pending(["Spacing Jitter", "Lateral Jitter", "Linear Jitter", "Falloff", "Speed Spacing"], title: "Source mapping: Coming soon") }
        case "Dynamics":
            if brush.isRenderable { speedSpacingControls }
            else { pending(["Speed Spacing"], title: "Source mapping: Coming soon") }
            pending((planned[category] ?? []).filter { $0 != "Speed Spacing" })
        case "Rendering":
            if brush.canConfigureRendering {
                Picker("Rendering Mode", selection: renderingValue(\.mode)) {
                    ForEach(BrushRenderingSettings.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                slider("Flow", value: dynamic(\.flow), range: 0...1, unit: "%", factor: 100)
                Text("Flow deposits each stamp. Opacity limits the completed stroke; alpha threshold can then make that coverage binary.")
                    .font(.caption).foregroundStyle(.secondary)
                slider("Wet Edges", value: renderingValue(\.wetEdges), range: 0...1, unit: "%", factor: 100)
                slider("Burnt Edges", value: renderingValue(\.burntEdges), range: 0...1, unit: "%", factor: 100)
                Picker("Edge Blend Mode", selection: renderingValue(\.edgeBlend)) {
                    ForEach(LayerBlendMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.disabled(brush.roundDynamics.renderingSettings.burntEdges == 0)
                Picker("Stroke Blend Mode", selection: renderingValue(\.strokeBlend)) {
                    ForEach(LayerBlendMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Luminance Blending", isOn: renderingValue(\.luminanceBlending))
                Toggle("Alpha Threshold", isOn: Binding(get: { brush.roundDynamics.renderingSettings.alphaThreshold != nil },
                    set: { renderingValue(\.alphaThreshold).wrappedValue = $0 ? 0.5 : nil }))
                if brush.roundDynamics.renderingSettings.alphaThreshold != nil {
                    slider("Threshold", value: Binding(get: { brush.roundDynamics.renderingSettings.alphaThreshold ?? 0.5 },
                        set: { renderingValue(\.alphaThreshold).wrappedValue = $0 }), range: 0...1, unit: "%", factor: 100)
                }
                Divider()
                Toggle("Secondary Tip", isOn: Binding(get: { brush.roundDynamics.renderingSettings.dualSource != nil },
                    set: { renderingValue(\.dualSource).wrappedValue = $0 ? .generated : nil }))
                if brush.roundDynamics.renderingSettings.dualSource != nil {
                    Picker("Secondary Source", selection: Binding(get: { brush.roundDynamics.renderingSettings.dualSource ?? .generated },
                        set: { renderingValue(\.dualSource).wrappedValue = $0 })) {
                        ForEach(BrushRenderingSettings.DualSource.allCases, id: \.self) { source in
                            Text(source.rawValue).tag(source).disabled(source == .original && brush.source?.definitions.dropFirst().first?.nativeTip == nil)
                        }
                    }
                    if brush.roundDynamics.renderingSettings.dualSource == .generated {
                        Picker("Secondary Shape", selection: renderingValue(\.secondary)) {
                            ForEach(GeneratedBrushTip.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                    slider("Tip Scale", value: renderingValue(\.secondaryScale), range: 0.1...2, unit: "%", factor: 100)
                    Toggle("Classic Normal Combine", isOn: renderingValue(\.classicDualNormal))
                    Text("Normal intersects the two tips; Classic overlays them. Both use the primary path and orientation. Independent dual-brush dynamics remain unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if brush.source != nil {
                    Toggle("Use native shape approximation", isOn: Binding(get: { brush.usesShapeApproximation || brush.usesRoundApproximation }, set: {
                        brush.usesShapeApproximation = $0; brush.usesRoundApproximation = false
                    })).disabled(!brush.canApproximateShape)
                }
                Text("Blending carries existing paint on the active layer. The white/black preview backdrop is display-only. These native behaviors do not reproduce source kernels or implement the separate Wet Mix category. Mask colors stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { pending(planned[category] ?? [], title: "Required shape, grain or component rendering unavailable") }
        case "Taper":
            if brush.isRenderable {
                slider("Start Size Taper", value: dynamic(\.taperStart), range: 0...1, unit: "%", factor: 100)
                slider("End Size Taper", value: dynamic(\.taperEnd), range: 0...1, unit: "%", factor: 100)
                Text("Lengths are fractions of the completed stroke. The live stroke is provisional; taper resolves on release.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { pending(["Start Size Taper", "End Size Taper"], title: "Source mapping: Coming soon") }
            forTaper("Pressure Taper")
            forTaper("Touch Taper")
            Toggle("Tip Animation", isOn: Binding(get: { brush.roundDynamics.tipAnimation ?? false }, set: { brush.roundDynamics.tipAnimation = $0 }))
            Toggle("Classic Taper", isOn: Binding(get: { brush.roundDynamics.classicTaper ?? false }, set: { brush.roundDynamics.classicTaper = $0 }))
            Text("Tip Animation shows provisional native taper while drawing; off resolves taper on release. Classic uses a straight ramp instead of Tip easing.").font(.caption).foregroundStyle(.secondary)
        case "Grain":
            if brush.source != nil {
                sourceReference("Grain source", reference: definition?.grainReference)
                if let resolution = definition?.grainResolution { Text(resolution.summary).foregroundStyle(.secondary) }
            }
            Toggle("Enable Grain", isOn: Binding(get: { brush.roundDynamics.grain != nil }, set: { brush.roundDynamics.grain = $0 ? BrushGrain() : nil }))
            if brush.roundDynamics.grain != nil {
                Picker("Grain Source", selection: setting(\.grain, BrushGrain(), \.source)) {
                    ForEach(BrushGrain.Source.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source).disabled(source == .original && brush.source?.definitions.first?.nativeGrainTip == nil
                            || source == .custom && brush.roundDynamics.grain?.custom == nil)
                    }
                }
                Button("Import Grain…") { importShape(grain: true) }.disabled(resolving)
                let grain = brush.roundDynamics.grain ?? BrushGrain()
                let tip = grain.source == .generated ? BrushGrain.texture() : grain.source == .custom ? grain.custom : brush.source?.definitions.first?.nativeGrainTip
                if let image = tip?.preview(.luminance) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none).frame(width: 100, height: 100)
                    Button("Inspect Grain…") { inspectionImage = image; inspectingTip = true }
                }
                Picker("Grain Behavior", selection: setting(\.grain, BrushGrain(), \.mode)) {
                    ForEach(BrushGrain.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                slider("Scale", value: setting(\.grain, BrushGrain(), \.scale), range: 1...2000, unit: "px")
                slider("Depth", value: setting(\.grain, BrushGrain(), \.depth), range: 0...1, unit: "%", factor: 100)
                slider("Movement", value: setting(\.grain, BrushGrain(), \.movement), range: 0...1, unit: "%", factor: 100).disabled(grain.mode != .moving)
                slider("Zoom", value: setting(\.grain, BrushGrain(), \.zoom), range: 0...1, unit: "%", factor: 100)
                slider("Rotation", value: setting(\.grain, BrushGrain(), \.rotation), range: -.pi...(.pi), unit: "°", factor: 180 / .pi)
                slider("Depth Jitter", value: setting(\.grain, BrushGrain(), \.depthJitter), range: 0...1, unit: "%", factor: 100)
                slider("Offset Jitter", value: setting(\.grain, BrushGrain(), \.offsetJitter), range: 0...1, unit: "%", factor: 100)
                Picker("Grain Blend", selection: setting(\.grain, BrushGrain(), \.blend)) {
                    ForEach(BrushGrain.Blend.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                slider("Brightness", value: setting(\.grain, BrushGrain(), \.brightness), range: -1...1, unit: "%", factor: 100)
                slider("Contrast", value: setting(\.grain, BrushGrain(), \.contrast), range: -1...1, unit: "%", factor: 100)
                Picker("Grain Filtering", selection: setting(\.grain, BrushGrain(), \.filtering)) {
                    ForEach(ShapeBrushSettings.Filtering.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Text("Grain repeats in canvas coordinates. Moving mode shifts its phase with each stamp; Texturized stays anchored. Zoom blends fixed scale with brush size. Custom images tile as supplied; edge discontinuities remain visible. Native texture is generated, not a Procreate asset. Secondary-component grain remains unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case "Color Dynamics":
            ForEach(["Stamp", "Stroke", "Pressure", "Tilt", "Rotation"], id: \.self) { group in
                pending(["Hue", "Saturation", "Lightness", "Darkness", "Secondary Color"].map { group + " " + $0 }, title: group + " · Coming soon")
            }
        default:
            pending(planned[category] ?? [])
        }
    }
    private var selectedTip: BrushShapeTip? {
        if sourceComponent != 0 { return definition?.tip }
        return switch brush.roundDynamics.shapeSettings.source {
        case .procedural: nil
        case .generated: brush.roundDynamics.shapeSettings.generatedKind.make()
        case .embedded: brush.source?.definitions.first?.tip
        case .custom: brush.roundDynamics.shapeSettings.customTip
        }
    }
    private func renderingValue<Value>(_ keyPath: WritableKeyPath<BrushRenderingSettings, Value>) -> Binding<Value> {
        Binding(get: { brush.roundDynamics.renderingSettings[keyPath: keyPath] }, set: {
            var rendering = brush.roundDynamics.renderingSettings
            rendering[keyPath: keyPath] = $0
            brush.roundDynamics.rendering = rendering
        })
    }
    private func shapeValue<Value>(_ keyPath: WritableKeyPath<ShapeBrushSettings, Value>) -> Binding<Value> {
        Binding(get: { brush.roundDynamics.shapeSettings[keyPath: keyPath] }, set: {
            var shape = brush.roundDynamics.shapeSettings
            shape[keyPath: keyPath] = $0
            brush.roundDynamics.shape = shape
        })
    }
    private func importShape(grain: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        resolving = true; error = nil
        Task { @MainActor in
            defer { resolving = false }
            do {
                let (data, decoded) = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 64 * 1024 * 1024 else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return (data, try BrushShapeTip.decode(data, name: url.lastPathComponent))
                }.value
                var tip = decoded
                tip.originalDigest = try BrushLibrary.shared.retainSource(data)
                if grain {
                    setting(\.grain, BrushGrain(), \.custom).wrappedValue = tip
                    setting(\.grain, BrushGrain(), \.source).wrappedValue = .custom
                } else {
                    shapeValue(\.customTip).wrappedValue = tip
                    shapeValue(\.source).wrappedValue = .custom
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func setting<Settings, Value>(_ group: WritableKeyPath<RoundBrushDynamics, Settings?>, _ defaults: Settings,
                                         _ field: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(get: { (brush.roundDynamics[keyPath: group] ?? defaults)[keyPath: field] }, set: {
            var settings = brush.roundDynamics[keyPath: group] ?? defaults
            settings[keyPath: field] = $0
            brush.roundDynamics[keyPath: group] = settings
        })
    }
    private func pathValue<Value>(_ keyPath: WritableKeyPath<StrokePathSettings, Value>) -> Binding<Value> {
        Binding(get: { brush.roundDynamics.path[keyPath: keyPath] }, set: {
            var path = brush.roundDynamics.path
            path[keyPath: keyPath] = $0
            brush.roundDynamics.strokePath = path
        })
    }
    private var speedSpacingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            slider("Speed Spacing", value: pathValue(\.speedSpacing), range: 0...1, unit: "%", factor: 100)
            slider("Reference Speed", value: pathValue(\.speedReference), range: 1...100000, unit: "px/s")
                .disabled(brush.roundDynamics.path.speedSpacing == 0)
            Text("Uses document pixels per second. At reference speed, 100% adds four times the base gap. Missing or repeated timestamps use the base gap. Shared with Dynamics.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func pathInput(_ title: String, value: Binding<StrokePathSettings.Input>, pressureOnly: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: value) {
                ForEach(pressureOnly ? [.none, .pressure] : StrokePathSettings.Input.allCases, id: \.self) { input in
                    Text(input.rawValue).tag(input)
                }
            }.accessibilityLabel(title)
            if value.wrappedValue != .none {
                Text(pressureOnly ? "Pressure modulates jitter through the brush pressure curve. Missing pressure keeps the fixed amount." : "Modulates jitter amount. Missing input keeps the fixed amount. Pressure uses the pressure curve; tilt uses calibrated magnitude; rotation uses a smooth one-turn cycle.")
                    .font(.caption).foregroundStyle(.secondary)
                if (value.wrappedValue == .pressure && !pen.capabilities.pressure)
                    || (value.wrappedValue == .tilt && !pen.capabilities.tilt)
                    || (value.wrappedValue == .rotation && !pen.capabilities.rotation) {
                    Text("Requires compatible tablet input; mapping is saved.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func dynamic<Value>(_ keyPath: WritableKeyPath<RoundBrushDynamics, Value>) -> Binding<Value> {
        Binding(get: { brush.roundDynamics[keyPath: keyPath] }, set: { brush.roundDynamics[keyPath: keyPath] = $0 })
    }
    private func refreshMapping() {
        let draft = brush
        guard let source = draft.source else { return }
        resolving = true
        error = nil
        Task { @MainActor in
            defer { resolving = false }
            do {
                let bytes = try BrushLibrary.shared.sourceData(for: source)
                let mapped = try await Task.detached(priority: .userInitiated) {
                    try ProcreateBrushImporter.remap(draft, original: bytes)
                }.value
                // Keep edits made while resolution was running.
                brush.source = mapped.source
            } catch { self.error = error.localizedDescription }
        }
    }
    private var definition: BrushSource.Definition? {
        guard let source = brush.source, source.definitions.indices.contains(sourceComponent) else { return nil }
        return source.definitions[sourceComponent]
    }
    private func sourceReference(_ title: String, reference: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(reference ?? "Not supplied").textSelection(.enabled).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
    private func taperLength(_ key: WritableKeyPath<RoundBrushDynamics, BrushTaper?>, start: Bool) -> Binding<CGFloat> {
        Binding(get: { let taper = brush.roundDynamics[keyPath: key] ?? BrushTaper(); return start ? taper.start : taper.end }, set: {
            var taper = brush.roundDynamics[keyPath: key] ?? BrushTaper()
            if start || taper.linked { taper.start = $0 }
            if !start || taper.linked { taper.end = $0 }
            brush.roundDynamics[keyPath: key] = taper
        })
    }
    private func forTaper(_ title: String) -> some View {
        let key: WritableKeyPath<RoundBrushDynamics, BrushTaper?> = title == "Pressure Taper" ? \.pressureTaper : \.touchTaper
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            BrushTaperGraph(taper: Binding(get: { brush.roundDynamics[keyPath: key] ?? BrushTaper() }, set: { brush.roundDynamics[keyPath: key] = $0 }))
            Toggle("Link Tip Sizes", isOn: Binding(get: { brush.roundDynamics[keyPath: key]?.linked ?? false }, set: {
                var taper = brush.roundDynamics[keyPath: key] ?? BrushTaper(); taper.linked = $0
                if $0 { taper.end = taper.start }; brush.roundDynamics[keyPath: key] = taper
            }))
            slider("Start Length", value: taperLength(key, start: true), range: 0...1, unit: "%", factor: 100)
            slider("End Length", value: taperLength(key, start: false), range: 0...1, unit: "%", factor: 100)
            slider("Size", value: setting(key, BrushTaper(), \.size), range: 0...1, unit: "%", factor: 100)
            slider("Opacity", value: setting(key, BrushTaper(), \.opacity), range: 0...1, unit: "%", factor: 100)
            slider("Pressure", value: setting(key, BrushTaper(), \.pressure), range: 0...1, unit: "%", factor: 100).disabled(title != "Pressure Taper")
            slider("Tip", value: setting(key, BrushTaper(), \.tip), range: 0...1, unit: "%", factor: 100)
            Text("Lengths are fractions of the completed stroke. Tip changes easing; pressure scales taper response only for pen input. Touch/Mouse has its own settings. Release resolves final size and opacity together.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func pending(_ names: [String], title: String = "Coming soon") -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            ForEach(names, id: \.self) { name in
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).fixedSize(horizontal: false, vertical: true)
                    TextField(name, text: .constant(brush.source == nil ? "Coming soon" : "Not mapped"))
                        .textFieldStyle(.roundedBorder).disabled(true)
                        .accessibilityLabel(name + ", Coming soon")
                    if brush.source != nil { Text("Source archive retained; this value has not been decoded.").font(.caption).foregroundStyle(.secondary) }
                }.accessibilityElement(children: .contain)
            }
        }
    }
    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, unit: String, factor: CGFloat = 1) -> some View {
        let set: (Double) -> Void = { number in
            guard number.isFinite else { return }
            value.wrappedValue = min(range.upperBound, max(range.lowerBound, CGFloat(number) / factor))
        }
        return HStack(spacing: 10) {
            Text(title).frame(width: 66, alignment: .leading)
                .scrubbable(sensitivity: 1 / factor, value: value, range: range)
            Slider(value: value, in: range).accessibilityLabel(title)
                .accessibilityValue((Double(value.wrappedValue * factor)).formatted(.number.precision(.fractionLength(0))) + " " + unit)
            TextField(title, value: Binding(get: { Double(value.wrappedValue * factor) }, set: set),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .accessibilityLabel(title + (unit.isEmpty ? "" : " in " + unit))
                .arrowSteps(value: { Double(value.wrappedValue * factor) }, change: set).unitSuffix(unit).fixedSize()
        }
    }
    private var planned: [String: [String]] { [
        "Stroke Path": ["Spacing", "Spacing Jitter", "Lateral Jitter", "Linear Jitter", "Falloff", "Speed Spacing"],
        "Grain": ["Custom Grain Source", "Moving Grain", "Texturized Grain", "Movement", "Scale", "Zoom", "Rotation", "Depth", "Depth Jitter", "Offset Jitter", "Blend Mode", "Brightness", "Contrast", "Filtering", "Source Tiling"],
        "Rendering": ["Light Glaze", "Uniform Glaze", "Intense Glaze", "Heavy Glaze", "Uniform Blending", "Intense Blending", "Flow", "Wet Edges", "Burnt Edges", "Edge Blend Mode", "Stroke Blend Mode", "Luminance Blending", "Alpha Threshold", "Classic Dual-Normal"],
        "Wet Mix": ["Dilution", "Charge", "Attack", "Pull", "Grade", "Blur", "Blur Jitter", "Wetness Jitter"],
        "Dynamics": ["Speed Size", "Speed Opacity", "Speed Spacing", "Size Jitter", "Opacity Jitter"],
        "Dual Brush": ["Primary Component", "Secondary Component", "Combination Settings"]
    ] }
}

private struct BrushDrawingPreview: NSViewRepresentable {
    let brush: BrushPreset
    let color: PaletteColor
    let clear: UUID
    let blackBackground: Bool
    let onError: (String?) -> Void
    func makeNSView(context: Context) -> BrushDrawingView { BrushDrawingView() }
    func updateNSView(_ view: BrushDrawingView, context: Context) {
        view.onError = onError
        view.blackBackground = blackBackground
        if view.preset != brush || view.clearID != clear || view.color != color {
            let clearing = view.clearID != clear
            view.preset = brush; view.clearID = clear; view.color = color
            if clearing { view.reset() }
            else { view.scheduleReplay() }
        }
    }
}

/// An isolated editor session keeps preview input, smoothing and rendering on the real painting path.
final class BrushDrawingView: NSView {
    var preset = BrushPreset(name: "Preview")
    var color = PaletteColor(red: 0, green: 0, blue: 0)
    var clearID = UUID()
    let session = EditorSession()
    var onError: (String?) -> Void = { _ in }
    var blackBackground = false { didSet { if blackBackground != oldValue { needsDisplay = true } } }
    var drawingRect: CGRect {
        let scale = max(0.001, min(bounds.width / 320, bounds.height / 240))
        let size = CGSize(width: 320 * scale, height: 240 * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    private var strokes: [(samples: [(point: CGPoint, input: BrushInput)], seed: UInt64, color: PaletteColor)] = []
    private var drawing = false
    private var pendingReplay: Task<Void, Never>?
    /// Settings can arrive at drag-event rate. Replay only the latest draft after a short idle period.
    func scheduleReplay() {
        pendingReplay?.cancel()
        pendingReplay = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            self?.reset(clearing: false)
        }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func reset(clearing: Bool = true) {
        pendingReplay?.cancel()
        pendingReplay = nil
        drawing = false
        if clearing { strokes = [] }
        session.cancelBrush()
        session.brushError = nil
        // Draft settings belong to this isolated preview, not the saved library record.
        session.selectedBrushPresetID = UUID()
        session.createDocument(width: 320, height: 240)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings = preset.applying(to: session.brushSettings)
        session.foregroundColor = color
        guard preset.isRenderable else { strokes = []; needsDisplay = true; return }
        for record in strokes {
            let samples = record.samples
            guard let first = samples.first else { continue }
            session.foregroundColor = record.color
            session.beginBrush(at: first.point, input: first.input, seed: record.seed, deferTaperRendering: true)
            for sample in samples.dropFirst() { session.continueBrush(at: sample.point, input: sample.input) }
            session.finishBrushImmediately()
        }
        session.history.reset()
        needsDisplay = true
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = drawingRect
        return CGPoint(x: (point.x - rect.minX) * 320 / rect.width, y: (point.y - rect.minY) * 240 / rect.height)
    }
    func beginStroke(at point: CGPoint, pressure: CGFloat? = nil, input: BrushInput? = nil) {
        guard preset.isRenderable else { return }
        // A new stroke must use the visible settings even if the idle replay has not fired yet.
        if pendingReplay != nil { reset(clearing: false) }
        if session.document == nil { reset() }
        drawing = true
        let input = input ?? BrushInput(pressure: pressure)
        let seed = UInt64.random(in: .min ... .max)
        strokes.append(([(point, input)], seed, color))
        session.foregroundColor = color
        session.beginBrush(at: point, input: input, seed: seed)
        onError(session.brushError); needsDisplay = true
    }
    func continueStroke(at point: CGPoint, pressure: CGFloat? = nil, input: BrushInput? = nil) {
        guard drawing else { return }
        let input = input ?? BrushInput(pressure: pressure)
        if !strokes.isEmpty { strokes[strokes.count - 1].samples.append((point, input)) }
        session.continueBrush(at: point, input: input)
        onError(session.brushError); needsDisplay = true
    }
    func endStroke() {
        guard drawing else { return }
        drawing = false
        session.finishBrushImmediately()
        session.history.reset()
        onError(session.brushError); needsDisplay = true
    }
    override func tabletPoint(with event: NSEvent) {
        guard drawing, PenInput.isTabletPoint(event), session.brushInput.deviceID == event.deviceID else { return }
        let location = event.window != nil && event.window === window ? point(event) : strokes.last?.samples.last?.point
        if let location { continueStroke(at: location, input: PenInput.shared.sample(event)) }
    }
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard drawingRect.contains(local) else { return }
        window?.makeFirstResponder(self)
        beginStroke(at: point(event), input: PenInput.shared.sample(event))
    }
    override func mouseDragged(with event: NSEvent) {
        continueStroke(at: point(event), input: PenInput.shared.sample(event))
    }
    override func mouseUp(with event: NSEvent) { endStroke() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        (blackBackground ? NSColor.black : NSColor.white).setFill(); drawingRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let rect = drawingRect
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 320, y: rect.height / 240)
        if let stroke = session.brushStroke {
            LayerRenderer.drawBrushPreview(stroke.layer.asset?.image, transform: stroke.paintTransform, center: stroke.paintTransform.center,
                scale: 1, opacity: stroke.layer.opacity, blendMode: stroke.layer.blendMode, mask: nil,
                patches: stroke.patches, pixelWidth: stroke.width, pixelHeight: stroke.height,
                paintingMask: false, sourceRect: stroke.sourceRect, in: context)
        } else if let layer = session.activeLayer, let image = layer.asset?.image {
            LayerRenderer.draw(image, transform: layer.transform, center: layer.transform.center, in: context)
        }
        context.restoreGState()
    }
}

private struct BrushTaperGraph: View {
    @Binding var taper: BrushTaper
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 30))
                    path.addLine(to: CGPoint(x: width * taper.start, y: 18))
                    path.addLine(to: CGPoint(x: width * (1 - taper.end), y: 18))
                    path.addLine(to: CGPoint(x: width, y: 30))
                    path.addLine(to: CGPoint(x: width * (1 - taper.end), y: 42))
                    path.addLine(to: CGPoint(x: width * taper.start, y: 42))
                    path.closeSubpath()
                }.fill(.secondary.opacity(0.4))
                ForEach([true, false], id: \.self) { start in
                    Circle().fill(Color.accentColor).frame(width: 16, height: 16)
                        .position(x: width * (start ? taper.start : 1 - taper.end), y: 30)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("taperGraph")).onChanged { value in
                            let amount = min(1, max(0, start ? value.location.x / width : 1 - value.location.x / width))
                            if start || taper.linked { taper.start = amount }
                            if !start || taper.linked { taper.end = amount }
                        })
                        .accessibilityLabel(start ? "Start taper length" : "End taper length")
                        .accessibilityValue("\(Int((start ? taper.start : taper.end) * 100)) percent")
                }
            }.coordinateSpace(name: "taperGraph")
        }.frame(height: 60)
    }
}
