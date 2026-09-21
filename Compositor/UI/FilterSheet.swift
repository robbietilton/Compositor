import SwiftUI

/// The open filter's panel: its settings, Preview, and Cancel / OK.
struct FilterSheet: View {
    @Bindable var session: EditorSession
    private var edit: FilterEdit? { session.filterEdit }
    private var settings: FilterSettings { edit?.settings ?? FilterSettings() }
    private func update(_ change: (inout FilterSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateFilter(value, preview: edit?.preview ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch edit?.kind ?? .gaussianBlur {
            case .curves:
                CurvesControls(settings: Binding(get: { settings.curves }, set: { new in update { $0.curves = new } }))
            case .exposure:
                control("Exposure", \.exposure.exposure, range: ExposureSettings.exposureRange, unit: "", decimals: 2, logarithmic: false)
                control("Offset", \.exposure.offset, range: ExposureSettings.offsetRange, unit: "", decimals: 4, logarithmic: false)
                control("Gamma", \.exposure.gamma, range: ExposureSettings.gammaRange, unit: "", decimals: 2, logarithmic: true)
            case .gradientMap:
                GradientMapControls(settings: Binding(get: { settings.gradientMap }, set: { new in update { $0.gradientMap = new } }),
                                    pick: { session.openGradientMapColorPicker(highlights: $0) })
            case .grain:
                control("Amount", \.grain.amount, range: GrainSettings.amountRange, unit: "", decimals: 0, logarithmic: false)
                control("Size", \.grain.size, range: GrainSettings.sizeRange, unit: "px", decimals: 1, logarithmic: true)
                control("Roughness", \.grain.roughness, range: GrainSettings.roughnessRange, unit: "", decimals: 0, logarithmic: false)
            case .removeBackground:
                Text("Hide the background behind a layer mask, keeping the foreground subjects. The pixels stay, so the background can be painted back at any time.")
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Quality", selection: Binding(get: { settings.backgroundQuality },
                                                     set: { new in update { $0.backgroundQuality = new } })) {
                    ForEach(BackgroundQuality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("Basic is quick; Advanced refines the mask against the layer's own detail, for hair and fur")
                if settings.backgroundQuality == .advanced {
                    control("Refine", \.refineEdges, range: 0...40, unit: "px", decimals: 0, logarithmic: false)
                        .help("Pull the mask onto the image's own edges, which recovers hair and fur")
                    control("Contrast", \.matteContrast, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                        .help("Clear the haze that leaves background showing through thin areas")
                    control("Shift Edge", \.shiftEdge, range: -10...10, unit: "px", decimals: 0, logarithmic: false)
                        .help("Shrink the mask to drop the rim of background color around the subject, or grow it")
                }
            case .contentAwareFill:
                Text("Fill the selection using surrounding pixels from this layer.")
                    .fixedSize(horizontal: false, vertical: true)
            case .gaussianBlur:
                control("Radius", \.radius, range: 0.1...250, unit: "px", decimals: 1, logarithmic: true)
            case .motionBlur:
                control("Angle", \.angle, range: -90...90, unit: "°", decimals: 0, logarithmic: false)
                control("Distance", \.distance, range: 1...2000, unit: "px", decimals: 0, logarithmic: true)
            case .addNoise:
                control("Amount", \.amount, range: 0.1...400, unit: "%", decimals: 1, logarithmic: true)
                Picker("Distribution", selection: flag(\.gaussian)) {
                    Text("Uniform").tag(false)
                    Text("Gaussian").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Monochromatic", isOn: flag(\.monochromatic))
            case .lensCorrection:
                control("Remove Distortion", \.distortion, range: -100...100, unit: "", decimals: 0, logarithmic: false)
                Text("Positive straightens lines that bow outward (barrel); negative, lines that bow inward (pincushion).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Preview", isOn: Binding(get: { edit?.preview ?? true },
                                            set: { session.updateFilter(settings, preview: $0) }))
            if let error = edit?.previewError {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if session.adjustmentOriginal == nil && session.selection != nil {
                Text("Limited to the selection").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Cancel") { session.cancelFilter() }.configuredNativeShortcut(.escape)
                Spacer()
                // While the preview is being worked out (Remove Background's mask, Content-Aware Fill) OK waits, so
                // the panel says what it is waiting for rather than showing a disabled button and nothing else.
                if edit?.committing == true || edit?.preparing == true {
                    ProgressView().controlSize(.small)
                    Text(edit?.committing == true ? "Applying…" : "Working…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("OK") { Task { await session.commitFilter() } }
                    .configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
                    .disabled(edit?.kind.isAutomatic == true && (edit?.preparing == true || edit?.previewError != nil))
            }
        }
        .padding(24).frame(width: 380).fixedSize()

        .disabled(edit?.committing == true)
        // The app's color picker, open on a Gradient Map end, previews its working color live.
        .onChange(of: session.colorPicker?.color) { _, _ in session.previewGradientMapColor() }
    }

    private func flag(_ key: WritableKeyPath<FilterSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }

    /// A slider plus an exact field. Logarithmic sliders give the small values used most most of the travel.
    private func control(_ title: String, _ key: WritableKeyPath<FilterSettings, Double>, range: ClosedRange<Double>,
                         unit: String, decimals: Int, logarithmic: Bool) -> some View {
        let step = pow(10, Double(decimals))
        return HStack(spacing: 10) {
            Text(title).frame(minWidth: 60, alignment: .leading).fixedSize()
            Slider(value: Binding(get: { logarithmic ? log(settings[keyPath: key]) : settings[keyPath: key] },
                                  set: { value in update { $0[keyPath: key] = ((logarithmic ? exp(value) : value) * step).rounded() / step } }),
                   in: logarithmic ? log(range.lowerBound)...log(range.upperBound) : range)
            TextField(title, value: Binding(get: { settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } }),
                      format: .number.precision(.fractionLength(0...decimals)))
                .frame(width: 56).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .unitSuffix(unit)
        }
    }
}

/// Gradient Map's two colors, the gradient they make, and Reverse. The colors are swatches like the
/// tool rail's, and open the app's own color picker.
struct GradientMapControls: View {
    @Binding var settings: GradientMapSettings
    /// Opens the color picker on an end: false for Shadows, true for Highlights.
    let pick: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let ends = settings.ends
            LinearGradient(colors: [color(ends.dark), color(ends.light)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.35)) }
                .accessibilityHidden(true)
            HStack(spacing: 20) {
                swatch("Shadows", settings.shadows) { pick(false) }
                swatch("Highlights", settings.highlights) { pick(true) }
                Spacer()
            }
            Toggle("Reverse", isOn: $settings.reversed)
        }
    }

    private func color(_ value: AdjustmentColor) -> Color { Color(.sRGB, red: value.red, green: value.green, blue: value.blue) }

    private func swatch(_ title: String, _ value: AdjustmentColor, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return HStack(spacing: 8) {
            Button(action: action) {
                shape
                    .fill(color(value))
                    .overlay { shape.inset(by: 1).strokeBorder(.white, lineWidth: 1.5) }
                    .overlay { shape.strokeBorder(.black, lineWidth: 1) }
                    .frame(width: 24, height: 24)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .help("Choose the \(title.lowercased()) color")
            .accessibilityLabel("\(title) color")
            Text(title)
        }
    }
}
