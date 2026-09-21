import SwiftUI
import AppKit

struct BrushControls: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        HStack(spacing: 12) {
            Text(session.tool == .spotHealing ? "Spot Healing" : session.tool == .cloneStamp ? "Clone Stamp" : session.tool == .blur ? "Smear" : session.brushMode == .erase ? "Eraser" : "Brush").font(ToolHeaderStyle.titleFont)
            if session.tool == .brush {
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
            Text("Size")
            TextField("Size", value: Binding<Double>(get: { Double(session.brushSettings.diameter) },
                set: { session.brushSettings.diameter = $0.isFinite ? CGFloat(min(2000, max(1, $0))) : 40 }),
                format: .number.precision(.fractionLength(0)))
                .frame(width: 48).textFieldStyle(.roundedBorder)
                .arrowSteps(value: { Double(session.brushSettings.diameter) },
                            change: { session.brushSettings.diameter = CGFloat(min(2000, max(1, $0))) })
                .onValueChangeCompat(of: session.brushSettings.diameter) { _, value in
                    session.brushSettings.diameter = value.isFinite ? min(2000, max(1, value)) : 40
                }
                .unitSuffix("px")
            Text("Hardness")
            Slider(value: $session.brushSettings.hardness, in: 0...1).frame(width: 100)
            TextField("Hardness", value: Binding<Double>(get: { Double(session.brushSettings.hardness * 100) },
                set: { session.brushSettings.hardness = $0.isFinite ? CGFloat(min(1, max(0, $0 / 100))) : 1 }),
                format: .number.precision(.fractionLength(0)))
                .frame(width: 42).textFieldStyle(.roundedBorder)
                .arrowSteps(value: { Double(session.brushSettings.hardness * 100) },
                            change: { session.brushSettings.hardness = CGFloat(min(1, max(0, $0 / 100))) })
                .unitSuffix("%")
            Text(session.tool == .blur ? "Strength" : "Opacity")
            Slider(value: $session.brushSettings.opacity, in: 0.01...1).frame(width: 100)
            TextField("Opacity", value: Binding<Double>(get: { Double(session.brushSettings.opacity * 100) },
                set: { session.brushSettings.opacity = $0.isFinite ? CGFloat(min(100, max(1, $0)) / 100) : 1 }),
                format: .number.precision(.fractionLength(0)))
                .frame(width: 42).textFieldStyle(.roundedBorder)
                .arrowSteps(value: { Double(session.brushSettings.opacity * 100) },
                            change: { session.brushSettings.opacity = CGFloat(min(100, max(1, $0)) / 100) })
                .help("Press 1–9 for 10–90%, 0 for 100%")
                .unitSuffix("%")
            if session.isMaskSelected {
                Picker("Paint", selection: $session.maskPaintWhite) {
                    Text("Black · Hide").tag(false)
                    Text("White · Reveal").tag(true)
                }.frame(width: 180)
            } else if session.tool != .cloneStamp, session.tool != .blur {
                // Same foreground color and Color Picker as the tool-rail swatch.
                HStack(spacing: 6) {
                    Text("Color")
                    Button { session.openColorPicker(background: false) } label: {
                        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                        shape.fill(session.foregroundColor.swiftUI)
                            .overlay { shape.inset(by: 1).strokeBorder(.white, lineWidth: 1) }
                            .overlay { shape.strokeBorder(.black, lineWidth: 1) }
                            .frame(width: 34, height: 18)
                            .contentShape(shape)
                    }
                    .buttonStyle(.plain)
                    .disabled(!session.canEditPalette)
                    .help("Foreground color")
                    .accessibilityLabel("Foreground color")
                }
            }
            Spacer(minLength: 0)
            if session.tool == .cloneStamp, session.cloneSource == nil {
                Text("Option-click to set the source").foregroundStyle(.secondary)
            }
            if session.isMaskSelected { Text("Mask").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy)
    }
}

/// A rubber stamp for the tool rail (SF Symbols has none): round handle, neck, body, and pad.
struct CloneStampToolIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var stamp = Path()
            stamp.addEllipse(in: CGRect(x: w * 0.33, y: h * 0.02, width: w * 0.34, height: h * 0.30))
            stamp.addRect(CGRect(x: w * 0.43, y: h * 0.28, width: w * 0.14, height: h * 0.28))
            stamp.addRoundedRect(in: CGRect(x: w * 0.12, y: h * 0.54, width: w * 0.76, height: h * 0.22),
                                 cornerSize: CGSize(width: w * 0.08, height: w * 0.08))
            stamp.addRect(CGRect(x: w * 0.06, y: h * 0.82, width: w * 0.88, height: h * 0.12))
            context.fill(stamp, with: .foreground)
        }
        .accessibilityHidden(true)
    }
}
