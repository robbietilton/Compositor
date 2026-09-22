import SwiftUI
import AppKit

/// A dedicated finishing workspace within the editor window. Only this canvas is mounted,
/// so all comparison panes share one viewport and no hidden editor competes for its size.
struct RenderFinishWorkspace: View {
    @Bindable var session: EditorSession
    @State private var selected: FinishEffect = .tonalContrast
    private var edit: FilterEdit? { session.filterEdit }
    private var enlargeFactor: Int { edit?.enlargeFactor ?? 0 }
    private var settings: Binding<RenderFinishSettings> {
        Binding(get: { edit?.settings.renderFinish ?? RenderFinishSettings() }, set: { new in
            guard var value = edit?.settings else { return }
            value.renderFinish = new
            session.updateFilter(value, preview: edit?.preview ?? true)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "camera.aperture").font(.system(size: 23, weight: .light)).foregroundStyle(FinishStyle.accent)
                Text("Darkroom").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("/  PHOTO FINISHING").font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(.secondary)
                Divider().frame(height: 18).padding(.horizontal, 6)
                Picker("Source", selection: Binding(get: { edit?.finishSource ?? .layer }, set: { session.setFinishSource($0) })) {
                    ForEach(FinishSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210).controlSize(.small)
                .help("Finish the active layer, or everything visible merged into one image")
                Text(edit?.finishSource == .mergedVisible ? "All visible layers" : session.activeLayer?.name ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("Drag to pan · Pinch or Option-scroll to zoom · \(RenderCompareToolbar.beforeAfterKey) before/after")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            RenderCompareToolbar(session: session)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("FILTER LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1.8)
                        Spacer()
                        Text(String(format: "%02d", FinishEffect.allCases.count)).font(.system(size: 10, design: .monospaced))
                    }.foregroundStyle(.secondary)
                    if let image = edit?.original.thumbnail {
                        Image(decorative: image, scale: 1)
                            .resizable().aspectRatio(contentMode: .fill).frame(height: 80).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .bottomLeading) {
                                Text("YOUR ORIGINAL").font(.system(size: 8, weight: .semibold)).tracking(1.2)
                                    .padding(6).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4)).padding(8)
                            }
                    }
                    RenderFinishPresetMenu(settings: settings, selected: $selected)
                        .controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
                    ScrollView {
                        // Room for the scroller, so it never sits over (and takes clicks from) the checkboxes.
                        VStack(alignment: .leading, spacing: 6) {
                            RenderFinishFilterList(settings: settings, selected: $selected)
                            EnlargerStep(session: session)
                        }
                        .padding(.trailing, 12)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    Spacer(minLength: 0)
                    Button("Reset All Filters") { settings.wrappedValue = RenderFinishSettings() }
                        .controlSize(.small)
                }
                .padding(16).frame(width: 235).frame(maxHeight: .infinity, alignment: .top)
                .background(FinishStyle.panel)
                Divider()
                EditorCanvas(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("ADJUSTMENTS").font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(FinishStyle.accent)
                        Text(selected.title).font(.title2.weight(.semibold))
                        Toggle("Enable \(selected.title)", isOn: Binding(get: { settings.wrappedValue[selected].enabled },
                            set: { settings.wrappedValue[selected].enabled = $0 }))
                        Divider()
                        RenderFinishControls(settings: settings, selected: selected)
                        if edit?.comparisonMode == .split {
                            Divider()
                            Text("Before / After divider").font(.callout.weight(.medium))
                            Slider(value: Binding(get: { edit?.splitPosition ?? 0.5 }, set: {
                                edit?.splitPosition = $0
                                session.brushRevision += 1
                            }), in: 0...1)
                            .accessibilityLabel("Before and after divider")
                            Text("Drag the line on the image to compare.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(20)
                }
                .frame(width: 310).frame(maxHeight: .infinity)
                .background(FinishStyle.panel)
            }
            Divider()
            HStack(spacing: 16) {
                Toggle("Preview", isOn: Binding(get: { edit?.preview ?? true }, set: {
                    guard let settings = edit?.settings else { return }
                    session.updateFilter(settings, preview: $0)
                }))
                Label("Result on a new layer", systemImage: "square.3.layers")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(edit?.finishSource == .mergedVisible
                          ? "Apply adds the merged result on top and keeps the original layers hidden below it."
                          : "Apply creates a new layer and keeps the original hidden below it.")
                if session.selection != nil { Text("Selection only").font(.caption).foregroundStyle(.secondary) }
                if let error = edit?.previewError { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                if edit?.committing == true || edit?.preparing == true {
                    ProgressView().controlSize(.small)
                    Text(edit?.committing == true ? "Applying…" : "Updating preview…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { session.cancelFilter() }.configuredNativeShortcut(.escape)
                Button(enlargeFactor > 1 ? "Apply & Enlarge \(enlargeFactor)×" : "Apply") { Task { await session.applyDarkroom() } }
                    .configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
                    .disabled(edit?.previewError != nil || (enlargeFactor > 1 && !EnlargerStep.isReady(session: session, factor: enlargeFactor)))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .background(FinishStyle.background)
        .tint(FinishStyle.accent)
        .disabled(edit?.committing == true)
        .background(FinishWindowExpansion().frame(width: 0, height: 0))
        .onAppear { session.canvasFocusRequest += 1 }
    }
}

/// Fill the current display while finishing and restore the editor's previous frame on exit.
/// A window already in native macOS full screen is left in that state.
private struct FinishWindowExpansion: NSViewRepresentable {
    func makeNSView(context: Context) -> FinishWindowExpansionView { FinishWindowExpansionView() }
    func updateNSView(_ nsView: FinishWindowExpansionView, context: Context) {}
    static func dismantleNSView(_ nsView: FinishWindowExpansionView, coordinator: ()) { nsView.restore() }
}

private final class FinishWindowExpansionView: NSView {
    private weak var editorWindow: NSWindow?
    private var savedFrame: CGRect?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, savedFrame == nil, !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
        editorWindow = window
        savedFrame = window.frame
        DispatchQueue.main.async { [weak self, weak window] in
            guard self?.savedFrame != nil else { return }
            window?.setFrame(screen.visibleFrame, display: true)
        }
    }
    func restore() {
        guard let frame = savedFrame, let window = editorWindow else { return }
        savedFrame = nil
        DispatchQueue.main.async { [weak window] in
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            window.setFrame(frame, display: true)
        }
    }
}
