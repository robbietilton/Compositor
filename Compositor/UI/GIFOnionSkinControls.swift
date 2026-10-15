import SwiftUI

struct GIFOnionSkinControls: View {
    @Bindable var preview: GIFOnionSkinPreview
    let canPreview: Bool
    let isPlaying: Bool
    @State private var showsSettings = false

    var body: some View {
        HStack(spacing: 0) {
            Button { preview.isEnabled.toggle() } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(preview.isEnabled && !isPlaying ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .help(preview.isEnabled ? "Hide the onion skin preview." : "Show a neighboring frame as a faint overlay.")
            .accessibilityLabel("Onion skin preview")
            .accessibilityValue(preview.isEnabled ? "On" : "Off")
            .accessibilityIdentifier("gifOnionSkin")
            Button { showsSettings = true } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 22)
                    .contentShape(Rectangle())
            }
            .disabled(!preview.isEnabled)
            .help("Choose a neighboring frame and adjust its opacity.")
            .accessibilityLabel("Onion skin settings")
            .accessibilityIdentifier("gifOnionSkinSettings")
            .popover(isPresented: $showsSettings) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Onion Skin").font(.headline)
                    Picker("Preview", selection: $preview.direction) {
                        ForEach(GIFOnionSkinPreview.Direction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .font(ToolHeaderStyle.controlFont)
                    .roundedControls()
                    .accessibilityIdentifier("gifOnionSkinDirection")
                    HStack(spacing: 8) {
                        Text("Opacity").font(ToolHeaderStyle.controlFont)
                        Slider(value: $preview.opacity, in: 0.05...1)
                            .accessibilityLabel("Onion skin opacity")
                            .accessibilityIdentifier("gifOnionSkinOpacity")
                        Text(preview.opacity, format: .percent.precision(.fractionLength(0)))
                            .font(ToolHeaderStyle.controlFont).monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                .padding(16).frame(width: 280)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canPreview || isPlaying)
        .onChange(of: isPlaying) { _, playing in if playing { showsSettings = false } }
    }
}
