import SwiftUI

/// Destination choices belong to this picker, apart from the canvas and layer selection.
struct GIFFrameMaskCopyPopover: View {
    let request: GIFFrameMaskCopyRequest
    let frames: [GIFTimelineFrame]
    let frameMaskIndices: Set<Int>
    let canEdit: Bool
    let onCopy: (Set<Int>) -> Bool
    let onCancel: () -> Void
    @State private var selectedIndices: Set<Int> = []

    private var destinations: [(offset: Int, element: GIFTimelineFrame)] {
        Array(frames.enumerated()).filter { $0.element.index != request.sourceFrameIndex }
    }
    private var targetIndices: Set<Int> { Set(destinations.map { $0.element.index }) }
    private var replacements: Int { selectedIndices.intersection(frameMaskIndices).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy frame mask").font(.headline)
            HStack(spacing: 12) {
                if let position = frames.firstIndex(where: { $0.index == request.sourceFrameIndex }) {
                    VStack(spacing: 4) {
                        preview(frames[position].thumbnail)
                        Text("Frame \(position + 1)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 4) {
                    preview(request.mask.asset.thumbnail)
                    Text("Mask").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source mask")
                    Text(request.mask.isEnabled ? "Enabled" : "Disabled")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Divider()
            HStack {
                Text("Copy to").foregroundStyle(.secondary)
                Spacer()
                Button("Select All") { selectedIndices = targetIndices }
                    .disabled(selectedIndices == targetIndices)
                    .accessibilityIdentifier("gifMaskCopySelectAll")
                Button("Clear") { selectedIndices = [] }
                    .disabled(selectedIndices.isEmpty)
                    .accessibilityIdentifier("gifMaskCopyClear")
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 12) {
                    ForEach(destinations, id: \.element.index) { position, frame in
                        Toggle(isOn: selection(for: frame.index)) {
                            VStack(spacing: 4) {
                                preview(frame.thumbnail, selected: selectedIndices.contains(frame.index))
                                    .overlay(alignment: .topTrailing) {
                                        if frameMaskIndices.contains(frame.index) {
                                            Image(systemName: "rectangle.inset.filled")
                                                .font(.system(size: 8, weight: .medium)).foregroundStyle(.white)
                                                .padding(3).background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 3))
                                                .padding(4)
                                        }
                                    }
                                Text("Frame \(position + 1)").font(.caption).monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Copy mask to frame \(position + 1)")
                        .accessibilityIdentifier("gifMaskCopyFrame\(position + 1)")
                    }
                }.padding(.vertical, 2)
            }
            .frame(height: min(280, CGFloat((destinations.count + 2) / 3) * 82))
            Text(replacements == 0 ? "Choose the frames that will receive this mask."
                 : "\(replacements) existing \(replacements == 1 ? "mask will" : "masks will") be replaced.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("gifMaskCopyReplacementSummary")
            Divider()
            HStack {
                Button("Cancel", action: onCancel).configuredNativeShortcut(.escape)
                    .accessibilityIdentifier("gifMaskCopyCancel")
                Spacer()
                Button("Copy to \(selectedIndices.count) \(selectedIndices.count == 1 ? "Frame" : "Frames")") {
                    if onCopy(selectedIndices) { onCancel() }
                }
                .configuredNativeShortcut(.return)
                .disabled(!canEdit || selectedIndices.isEmpty)
                .accessibilityIdentifier("gifMaskCopyApply")
            }
        }
        .padding(16).frame(width: 400).roundedControls()
        .onChange(of: targetIndices) { _, indices in selectedIndices.formIntersection(indices) }
    }

    private func selection(for index: Int) -> Binding<Bool> {
        Binding(get: { selectedIndices.contains(index) }, set: { selected in
            if selected { selectedIndices.insert(index) } else { selectedIndices.remove(index) }
        })
    }

    private func preview(_ image: CGImage, selected: Bool = false) -> some View {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            .frame(width: 76, height: 48).padding(3)
            .background(Color(white: 0.22), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1)
            }
    }
}
