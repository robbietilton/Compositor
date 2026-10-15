import SwiftUI

/// The Layers panel's type filter: the kinds of layer the list narrows to while their toggles are on.
enum LayerType: String, CaseIterable {
    case image, shape, text, folder, adjustment
}

extension LayerType {
    var titleKey: LocalizedStringKey {
        switch self {
        case .image: "Images"
        case .shape: "Shapes"
        case .text: "Text"
        case .folder: "Folders"
        case .adjustment: "Adjustments"
        }
    }
    var systemImageName: String {
        switch self {
        case .image: "photo"
        case .shape: "square.on.circle"
        case .text: "character"
        case .folder: "folder"
        case .adjustment: "circle.righthalf.filled"
        }
    }
    /// VoiceOver's description of the type's toggle.
    var filterLabel: LocalizedStringKey {
        switch self {
        case .image: "Filter to image layers"
        case .shape: "Filter to shape layers"
        case .text: "Filter to text layers"
        case .folder: "Filter to folder layers"
        case .adjustment: "Filter to adjustment layers"
        }
    }
    /// The toggle's stable identifier, cased to match "layerFilterAll".
    var accessibilityID: String {
        "layerFilter" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

extension ImageLayer {
    /// Which of the panel's type filters the layer belongs to. Text means editable text; rasterized
    /// text counts as an image, as it does everywhere else in the app.
    var layerType: LayerType {
        if isGroup { return .folder }
        if adjustment != nil { return .adjustment }
        if liveText != nil { return .text }
        if shape != nil { return .shape }
        return .image
    }
}

extension EditorSession {
    /// Whether the panel's search text or type filter is on.
    var isFilteringLayers: Bool { !layerSearchText.isEmpty || !layerTypeFilter.isEmpty }
    /// The rows the panel shows: `layerRows` narrowed by the search text and type filter. While a filter
    /// is on, folders list themselves opened, so layers inside collapsed folders can be found too.
    var filteredLayerRows: [LayerHierarchy.Entry] {
        let entries = LayerHierarchy.entries(document?.layers.map(\.hierarchyRecord) ?? [], topFirst: true,
                                             collapsed: isFilteringLayers ? [] : collapsedGroupIDs)
        guard isFilteringLayers else { return entries }
        let query = layerSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        let byID = Dictionary(uniqueKeysWithValues: (document?.layers ?? []).map { ($0.id, $0) })
        return entries.filter { entry in
            guard let layer = byID[entry.layer.id] else { return false }
            return (query.isEmpty || layer.name.lowercased().contains(query))
                && (layerTypeFilter.isEmpty || layerTypeFilter.contains(layer.layerType))
        }
    }
    /// Clears the panel's search text.
    func clearLayerSearch() {
        layerSearchText = ""
    }
    /// Clears the panel's every type toggle.
    func clearLayerTypeFilter() {
        layerTypeFilter = []
    }
}

/// The Layers panel's search by name, and the funnel that opens the type-filter panel. The funnel
/// reads as pressed while a filter is on. Its binding ignores the value the toggle passes (it flips
/// its own on state, which is the filter's): clicking always opens or closes the panel.
struct LayerSearchControls: View {
    @Bindable var session: EditorSession
    /// Whether the funnel's type-filter panel is open.
    @State private var isPresentingFilter = false

    var body: some View {
        HStack {
            LayerSearchField(text: $session.layerSearchText)
                .help("Type a layer name.")
            Toggle(isOn: Binding(
                get: { !session.layerTypeFilter.isEmpty },
                set: { _ in isPresentingFilter.toggle() }
            )) {
                Image(systemName: "line.3.horizontal.decrease")
                    .padding(4)
            }
            .toggleStyle(.button)
            .buttonBorderShape(.circle)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Filter the layer list.")
            .help("Filter the layer list.")
            .popover(isPresented: $isPresentingFilter) {
                typeFilterPopover
            }
        }
        .padding(6)
    }

    /// The funnel's contents. All Layers and Clear All concern the type toggles alone — the search
    /// field brings its own clear button — so All Layers reads as on while no toggle is on, and
    /// Clear All is enabled only while one is.
    private var typeFilterPopover: some View {
        VStack(alignment: .leading) {
            Toggle("All Layers", systemImage: "square.3.layers.3d", isOn: Binding(
                get: { session.layerTypeFilter.isEmpty },
                set: { on in if on { session.clearLayerTypeFilter() } }
            ))
            .labelReservedIconWidth(16)
            .accessibilityIdentifier("layerFilterAll")
            Divider()
            ForEach(LayerType.allCases, id: \.self) { typeToggle($0) }
            Divider()
            Button("Clear All") { session.clearLayerTypeFilter() }
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(session.layerTypeFilter.isEmpty)
        }
        .padding()
    }

    private func typeToggle(_ kind: LayerType) -> some View {
        Toggle(kind.titleKey, systemImage: kind.systemImageName, isOn: Binding(
            get: { session.layerTypeFilter.contains(kind) },
            set: { on in if on { session.layerTypeFilter.insert(kind) } else { session.layerTypeFilter.remove(kind) } }
        ))
        .labelReservedIconWidth(16)
        .accessibilityLabel(kind.filterLabel)
        .accessibilityIdentifier(kind.accessibilityID)
    }
}

/// The Layers panel's search field: AppKit's search field, which brings its own cancel and clear
/// buttons and clears on Escape, so SwiftUI only supplies the text binding.
private struct LayerSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("layerSearch")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        // Only when they differ: writing the string back mid-edit would move the insertion point.
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
