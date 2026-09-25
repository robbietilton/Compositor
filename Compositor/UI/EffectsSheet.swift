import SwiftUI

/// One effect's controls, bound to the layer that opened the panel. Changes preview on the canvas.
struct EffectsSheet: View {
    @Bindable var session: EditorSession
    let kind: LayerEffectKind

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch kind {
            case .stroke: stroke
            case .shadow: shadow
            case .colorOverlay: colorOverlay
            case .innerShadow: innerShadow
            case .outerGlow: outerGlow
            case .innerGlow: innerGlow
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { session.finishEffectsEditing(commit: false) }
                    .configuredNativeShortcut(.escape)
                Button("OK") { session.finishEffectsEditing(commit: true) }
                    .configuredNativeShortcut(.return)
            }
        }
        .padding(20).frame(width: 340).fixedSize()
        // The picker previews its working color on the layer while it is open.
        .onChange(of: session.colorPicker?.color) { _, _ in session.previewEffectColor() }
    }

    @ViewBuilder private var stroke: some View {
        let effect = session.editingEffects.stroke
        HStack {
            Text("Stroke").font(.headline)
            Spacer()
            if let effect {
                Picker("Position", selection: Binding(get: { effect.inside }, set: { inside in
                    session.changeEffects { $0.stroke?.inside = inside }
                })) {
                    Text("Outside").tag(false)
                    Text("Inside").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        if let effect {
            HStack {
                Text("Color").frame(width: 64, alignment: .leading)
                swatch(.stroke)
                Spacer()
            }
            slider("Size", value: Binding(get: { effect.size }, set: { size in
                session.changeEffects { $0.stroke?.size = size }
            }), range: 0...20, inputRange: 0...StrokeEffect.maxSize, unit: "px")
            slider("Opacity", value: Binding(get: { CGFloat(effect.opacity * 100) }, set: { value in
                session.changeEffects { $0.stroke?.opacity = Double(value) / 100 }
            }), range: 0...100, unit: "%")
        }
    }

    @ViewBuilder private var shadow: some View {
        let effect = session.editingEffects.shadow
        HStack {
            Text("Drop Shadow").font(.headline)
            Spacer()
            if effect != nil { swatch(.shadow) }
        }
        if let effect {
            slider("Opacity", value: Binding(get: { CGFloat(effect.opacity * 100) }, set: { value in
                session.changeEffects { $0.shadow?.opacity = Double(value) / 100 }
            }), range: 0...100, unit: "%")
            slider("Angle", value: Binding(get: { effect.angle }, set: { angle in
                session.changeEffects { $0.shadow?.angle = angle }
            }), range: -180...180, unit: "°")
            slider("Distance", value: Binding(get: { effect.distance }, set: { distance in
                session.changeEffects { $0.shadow?.distance = distance }
            }), range: 0...100, inputRange: 0...5000, unit: "px")
            slider("Blur", value: Binding(get: { effect.blur }, set: { blur in
                session.changeEffects { $0.shadow?.blur = blur }
            }), range: 0...100, inputRange: 0...500, unit: "px")
        }
    }

    @ViewBuilder private var colorOverlay: some View {
        let effect = session.editingEffects.colorOverlay
        HStack {
            Text("Color Overlay").font(.headline)
            Spacer()
            if effect != nil { swatch(.colorOverlay) }
        }
        if let effect {
            slider("Opacity", value: Binding(get: { CGFloat(effect.opacity * 100) }, set: { value in
                session.changeEffects { $0.colorOverlay?.opacity = Double(value) / 100 }
            }), range: 0...100, unit: "%")
        }
    }

    @ViewBuilder private var innerShadow: some View {
        let effect = session.editingEffects.innerShadow
        HStack {
            Text("Inner Shadow").font(.headline)
            Spacer()
            if effect != nil { swatch(.innerShadow) }
        }
        if let effect {
            slider("Opacity", value: Binding(get: { CGFloat(effect.opacity * 100) }, set: { value in
                session.changeEffects { $0.innerShadow?.opacity = Double(value) / 100 }
            }), range: 0...100, unit: "%")
            slider("Angle", value: Binding(get: { effect.angle }, set: { angle in
                session.changeEffects { $0.innerShadow?.angle = angle }
            }), range: -180...180, unit: "°")
            slider("Distance", value: Binding(get: { effect.distance }, set: { distance in
                session.changeEffects { $0.innerShadow?.distance = distance }
            }), range: 0...50, inputRange: 0...5000, unit: "px")
            slider("Blur", value: Binding(get: { effect.blur }, set: { blur in
                session.changeEffects { $0.innerShadow?.blur = blur }
            }), range: 0...100, inputRange: 0...500, unit: "px")
        }
    }

    @ViewBuilder private var outerGlow: some View {
        let effect = session.editingEffects.outerGlow
        HStack {
            Text("Outer Glow").font(.headline)
            Spacer()
            if effect != nil { swatch(.outerGlow) }
        }
        if let effect {
            slider("Size", value: Binding(get: { effect.size }, set: { size in
                session.changeEffects { $0.outerGlow?.size = size }
            }), range: 0...100, inputRange: 0...500, unit: "px")
            slider("Opacity", value: Binding(get: { CGFloat(effect.opacity * 100) }, set: { value in
                session.changeEffects { $0.outerGlow?.opacity = Double(value) / 100 }
            }), range: 0...100, unit: "%")
        }
    }

    @ViewBuilder private var innerGlow: some View {
        let effect = session.editingEffects.innerGlow
        HStack {
            Text("Inner Glow").font(.headline)
            Spacer()
            if effect != nil { swatch(.innerGlow) }
        }
        if let effect {
            slider("Size", value: Binding(get: { effect.size }, set: { size in
                session.changeEffects { $0.innerGlow?.size = size }
            }), range: 0...100, inputRange: 0...500, unit: "px")
            slider("Opacity", value: Binding(get: { CGFloat(effect.opacity * 100) }, set: { value in
                session.changeEffects { $0.innerGlow?.opacity = Double(value) / 100 }
            }), range: 0...100, unit: "%")
        }
    }

    /// The effect's color, opened in the app's own picker.
    private func swatch(_ kind: LayerEffectKind) -> some View {
        let color = session.editingEffects.color(kind)
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return Button { session.openEffectColorPicker(kind) } label: {
            shape.fill(Color(red: Double(color?.red ?? 0), green: Double(color?.green ?? 0), blue: Double(color?.blue ?? 0)))
                .overlay { shape.inset(by: 1).strokeBorder(.white, lineWidth: 1) }
                .overlay { shape.strokeBorder(.black, lineWidth: 1) }
                .frame(width: 36, height: 18)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(localized(kind.rawValue + " color"))
        .accessibilityLabel(localized(kind.rawValue + " color"))
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>,
                        inputRange: ClosedRange<CGFloat>? = nil, unit: String) -> some View {
        let limits = inputRange ?? range
        let setAmount: (Double) -> Void = { amount in
            guard amount.isFinite else { return }
            value.wrappedValue = min(limits.upperBound, max(limits.lowerBound, CGFloat(amount)))
        }
        return HStack(spacing: 10) {
            Text(localized(title)).frame(width: 64, alignment: .leading)
                .scrubbable(sensitivity: 1, value: value, range: limits)
            // A manually entered larger value stays intact; only the thumb is pinned
            // to the end of the slider until the user drags it again.
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value.wrappedValue)) },
                                  set: { value.wrappedValue = $0 }), in: range).frame(width: 130)
            TextField(localized(title), value: Binding(get: { Double(value.wrappedValue) },
                                            set: setAmount),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .arrowSteps(value: { Double(value.wrappedValue) },
                            change: setAmount)
                .unitSuffix(unit)
        }
    }
}
