import SwiftUI

/// Color and spacing shared by the dedicated finishing workspace.
enum FinishStyle {
    static let accent = Color(red: 0.88, green: 0.70, blue: 0.40)
    static let panel = Color(white: 0.105)
    static let background = Color(white: 0.075)
}

struct RenderFinishControls: View {
    @Binding var settings: RenderFinishSettings
    var selected: FinishEffect = .tonalContrast

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(selected.summary).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            VStack(spacing: 17) {
                slider("Strength", \.amount, range: 0...100)
                if selected == .tonalContrast {
                    Picker("Contrast Type", selection: Binding(get: { settings[selected].contrastType },
                        set: { settings[selected].contrastType = $0 })) {
                        ForEach(TonalContrastType.allCases) { Text($0.title).tag($0) }
                    }
                    Divider().padding(.vertical, 2)
                    slider("Highlights", \.highlights, range: -100...100)
                    slider("Midtones", \.midtones, range: -100...100)
                    slider("Shadows", \.shadows, range: -100...100)
                }
                if selected == .tonalContrast || selected == .detailExtractor || selected == .warmth {
                    slider("Saturation", \.saturation, range: -100...100)
                }
                if selected == .tonalContrast {
                    Divider().padding(.vertical, 2)
                    Text("TONE PROTECTION").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    slider("Protect shadows", \.protectShadows, range: 0...100)
                    slider("Protect highlights", \.protectHighlights, range: 0...100)
                }
                if selected == .highlightRolloff { slider("Halation", \.highlights, range: 0...100) }
                if let control = selected.radiusControl { slider(control.title, \.radius, range: control.range, unit: "px") }
                if selected == .ink {
                    Picker("Palette", selection: Binding(get: { settings[selected].palette }, set: { settings[selected].palette = $0 })) {
                        ForEach(Array(RenderFinishSettings.palettes.enumerated()), id: \.offset) { index, title in
                            Text(title).tag(index)
                        }
                    }
                }
                if selected == .warmth { slider("Warmth", \.shadows, range: -100...100) }
            }.disabled(!settings[selected].enabled)
            Button {
                let enabled = settings[selected].enabled
                settings[selected] = selected.defaults
                settings[selected].enabled = enabled
            } label: { Label("Reset this filter", systemImage: "arrow.counterclockwise") }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<FinishParameters, Double>,
                        range: ClosedRange<Double>, unit: String = "%") -> some View {
        // Small pixel ranges (grain size, fringe width) need half pixels.
        let step: Double = range.upperBound <= 12 ? 0.5 : 1
        let binding = Binding<Double>(get: { settings[selected][keyPath: key] },
                                      set: { settings[selected][keyPath: key] = $0 })
        return VStack(spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                TextField(title, value: binding, format: .number.precision(.fractionLength(step < 1 ? 1 : 0)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 42).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .padding(.vertical, 4).padding(.horizontal, 7)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                Text(unit).font(.caption2).foregroundStyle(.secondary).frame(width: 16, alignment: .leading)
            }
            Slider(value: binding, in: range, step: step).accessibilityLabel(title).controlSize(.small)
        }
    }
}

struct RenderFinishFilterList: View {
    @Binding var settings: RenderFinishSettings
    @Binding var selected: FinishEffect
    private func symbol(_ effect: FinishEffect) -> String {
        switch effect {
        case .tonalContrast: "circle.lefthalf.filled"
        case .ink: "drop.halffull"
        case .proContrast: "circle.righthalf.filled"
        case .detailExtractor: "square.3.layers.3d"
        case .bloom: "sun.max"
        case .warmth: "thermometer.sun"
        case .vignette: "camera.filters"
        case .sensorGrain: "circle.dotted"
        case .microTexture: "square.grid.3x3"
        case .highlightRolloff: "sun.haze"
        case .chromaticAberration: "rainbow"
        case .lensSoftness: "camera.macro"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(FinishEffect.allCases) { effect in
                if effect == .sensorGrain {
                    Text("PHOTO REALISM").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                        .foregroundStyle(.secondary).padding(.top, 10).padding(.leading, 4)
                }
                HStack(spacing: 10) {
                    Button { selected = effect } label: {
                        HStack(spacing: 11) {
                            Image(systemName: symbol(effect)).font(.system(size: 15)).frame(width: 18)
                                .foregroundStyle(selected == effect ? FinishStyle.accent : Color.secondary)
                            Text(effect.title).font(.system(size: 12, weight: selected == effect ? .semibold : .regular))
                                .foregroundStyle(selected == effect ? Color.white : Color(white: 0.7))
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Edit \(effect.title)")
                    Toggle(effect.title, isOn: Binding(get: { settings[effect].enabled }, set: { enabled in
                        settings[effect].enabled = enabled
                        if enabled { selected = effect }
                    }))
                    .labelsHidden().toggleStyle(.checkbox).accessibilityLabel("Enable \(effect.title)")
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected == effect ? FinishStyle.accent.opacity(0.11) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected == effect ? FinishStyle.accent.opacity(0.25) : Color.clear))
            }
        }
    }
}

/// Built-in looks and the user's own, applied to every filter at once.
struct RenderFinishPresetMenu: View {
    @Binding var settings: RenderFinishSettings
    @Binding var selected: FinishEffect
    @State private var naming = false
    @State private var name = ""
    private var presets: RenderFinishPresets { .shared }

    var body: some View {
        Menu {
            Section("Built-in") {
                ForEach(RenderFinishPresets.builtIn) { preset in Button(preset.name) { apply(preset) } }
            }
            if !presets.saved.isEmpty {
                Section("My Presets") {
                    ForEach(presets.saved) { preset in Button(preset.name) { apply(preset) } }
                }
            }
            Divider()
            Button("Save Current Settings as Preset…") { name = ""; naming = true }
            if !presets.saved.isEmpty {
                Menu("Delete Preset") {
                    ForEach(presets.saved) { preset in
                        Button(preset.name, role: .destructive) { presets.delete(preset) }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "square.stack.3d.up")
        }
        .help("Apply a saved look to every filter, or save the current one")
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { presets.save(settings, named: name) }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves every filter's settings, including which ones are enabled. A preset with the same name is replaced.")
        }
    }

    private func apply(_ preset: RenderFinishPreset) {
        settings = preset.settings
        if let first = preset.settings.activeEffects.first { selected = first }
    }
}
