import SwiftUI

struct BrushControls: View {
    @Bindable var session: EditorSession
    var body: some View {
        HStack(spacing: 12) {
            Text(session.tool == .spotHealing ? "Spot Healing" : session.tool == .cloneStamp ? "Clone Stamp" : session.tool == .blur ? "Smear" : session.brushMode == .erase ? "Eraser" : "Brush").font(ToolHeaderStyle.titleFont)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    if session.tool == .brush {
                        Button { session.showsBrushPalette.toggle() } label: {
                            Label("Brushes", systemImage: "paintbrush.pointed")
                        }
                        .help("Browse and edit brushes").accessibilityLabel("Browse brushes")
                        .accessibilityIdentifier("brushPaletteButton")
                        Picker("Mode", selection: $session.brushMode) {
                            ForEach(BrushToolMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("Paint with the foreground color (B), or erase pixels away (E)")
                    }
                    if session.tool == .blur {
                        Picker("Mode", selection: $session.blurMode) {
                            ForEach(BlurToolMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("Liquify pushes pixels · Blur softens · Smudge drags color along")
                    }
                    if session.tool == .spotHealing {
                        Picker("Type", selection: $session.spotHealingMode) {
                            ForEach(SpotHealingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .accessibilityIdentifier("spotHealingType")
                    }
                    if session.tool == .cloneStamp {
                        Toggle("Aligned", isOn: $session.cloneSettings.aligned)
                            .help("Keep the source moving with the brush between strokes; off starts every stroke at the source point")
                        Picker("Sample", selection: $session.cloneSettings.sampleAllLayers) {
                            Text("This Layer").tag(false)
                            Text("All Layers").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("Copy from the active layer only, or from every visible layer as shown")
                    }
                    HStack(spacing: 6) {
                        Text("Size").scrubbable(sensitivity: 1.0, value: $session.brushSettings.diameter, range: 1...2000)
                        TextField("Size", value: Binding<Double>(get: { Double(session.brushSettings.diameter) },
                                                                 set: { session.brushSettings.diameter = $0.isFinite ? CGFloat(min(2000, max(1, $0))) : 40 }),
                                  format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.roundedBorder)
                        .arrowSteps(value: { Double(session.brushSettings.diameter) },
                                    change: { session.brushSettings.diameter = CGFloat(min(2000, max(1, $0))) })
                        .onChange(of: session.brushSettings.diameter) { _, value in
                            session.brushSettings.diameter = value.isFinite ? min(2000, max(1, value)) : 40
                        }
                    }
