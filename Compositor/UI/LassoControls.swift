import SwiftUI

struct LassoControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text(session.tool == .marquee ? "Marquee" : session.tool == .wand ? "Magic" : session.tool == .quickSelection ? "Quick Selection" : session.tool == .magneticLasso ? "Magnetic Lasso" : "Lasso").font(ToolHeaderStyle.titleFont)
            if session.tool == .marquee {
                Picker("Shape", selection: Binding(get: { session.marqueeKind }, set: { kind in
                    session.cancelLasso()
                    session.marqueeKind = kind
                })) {
                    ForEach(LassoKind.marqueeChoices, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Press M to switch between Rectangle and Ellipse")
            }
            if session.tool == .wand {
                Picker("Mode", selection: Binding(get: { session.wandMode }, set: { mode in
                    session.cancelLasso()
                    session.wandMode = mode
                })) {
                    ForEach(WandMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Press Tab to switch between Wand and Object")
            }
            if session.tool == .lasso {
                Picker("Lasso", selection: Binding(get: { session.lassoKind }, set: { kind in
                    session.cancelLasso()
                    session.lassoKind = kind
                })) {
                    ForEach(LassoKind.lassoChoices, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Press L to switch between Freehand and Polygonal")
            }
            // Shows held Shift/Option (or an outline's mode) live; clicking sets the choice.
            Picker("Mode", selection: Binding(get: { session.displayedSelectionMode },
                                              set: { session.selectionModeChoice = $0 })) {
                ForEach(SelectionMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Hold Shift to add or Option to subtract for one outline")
            if session.tool == .wand, session.wandMode == .wand { wandControls }
            if session.tool == .wand, session.wandMode == .object { objectSelectionControls }
            if session.tool == .quickSelection { quickSelectionControls }
            if session.tool == .magneticLasso { magneticLassoControls }
            // Rectangles snap to whole pixels, so smoothing doesn't apply (as in Photoshop); ellipses curve.
            if session.tool == .lasso || session.tool == .wand || session.tool == .quickSelection || session.tool == .magneticLasso || (session.tool == .marquee && session.marqueeKind == .ellipse) {
                Toggle("Anti-alias", isOn: $session.selectionAntialiased)
                    .help(session.tool == .wand && session.wandMode == .object ? "Smooth the detected object outline; turn off for the raw pixel mask" : "Smooth selection edges; turn off for hard pixel edges")
            }
            Divider().frame(height: 18)
            modifyControl("Expand", amount: $session.selectionExpandAmount) {
                session.expandSelection(by: session.selectionExpandAmount)
            }
            modifyControl("Contract", amount: $session.selectionContractAmount) {
                session.contractSelection(by: session.selectionContractAmount)
            }
            // Softens the selection's edge, as Select → Feather does.
            HStack(spacing: 5) {
                Button("Feather") { session.featherSelection(by: session.selectionFeatherAmount) }
                    .disabled(!session.canModifySelection)
                    .help("Fade the edge of the selection by this many pixels")
                TextField("Feather", value: Binding(get: { Double(session.selectionFeatherAmount) },
                                                    set: { session.selectionFeatherAmount = $0.isFinite ? Int(min(250, max(1, $0))) : 2 }),
                          format: .number.precision(.fractionLength(0)))
                    .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .arrowSteps(value: { Double(session.selectionFeatherAmount) },
                                change: { session.selectionFeatherAmount = Int(min(250, max(1, $0))) })
                    .unitSuffix("px", scrubValue: $session.selectionFeatherAmount,
                                sensitivity: 1, range: 1...250)
            }
            Spacer(minLength: 0)
            if let selection = session.selection {
                if selection.isEmpty { Text("Empty selection").foregroundStyle(.secondary) }
                Button("Deselect") { session.deselect() }.disabled(!session.canEditSelection)
            }
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }

    private var quickSelectionDiameter: Binding<Double> {
        Binding(
            get: { Double(min(500, max(1, session.quickSelectionSettings.diameter))) },
            set: { session.quickSelectionSettings.diameter = CGFloat(min(500, max(1, $0))) }
        )
    }

    private var quickSelectionControls: some View {
        HStack(spacing: 10) {
            Text("Diameter").scrubbable(sensitivity: 1.0, value: quickSelectionDiameter, range: 1...500, step: 1)
            TextField("Diameter", value: quickSelectionDiameter,
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 44).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .unitSuffix("px", scrubValue: quickSelectionDiameter, sensitivity: 1.0, range: 1...500, step: 1)
                .accessibilityIdentifier("quickSelectionDiameter")
            Slider(value: quickSelectionDiameter, in: 1...500, step: 1)
                .frame(width: 120)
                .accessibilityIdentifier("quickSelectionDiameterSlider")
                .help("Brush diameter for Quick Selection")
            HStack(spacing: 6) {
                Text("Tolerance").scrubbable(sensitivity: 1, value: $session.quickSelectionSettings.tolerance, range: 0...255)
                TextField("Tolerance", value: $session.quickSelectionSettings.tolerance, format: .number)
                    .frame(width: 44).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .arrowSteps(value: { Double(session.quickSelectionSettings.tolerance) },
                                change: { session.quickSelectionSettings.tolerance = Int(min(255, max(0, $0.rounded()))) })
            }
            .help("How far colors may vary while the brush grows the selection")
            HStack(spacing: 6) {
                Text("Edge").scrubbable(sensitivity: 1, value: $session.quickSelectionSettings.edgeSensitivity, range: 0...255)
                TextField("Edge", value: $session.quickSelectionSettings.edgeSensitivity, format: .number)
                    .frame(width: 44).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .arrowSteps(value: { Double(session.quickSelectionSettings.edgeSensitivity) },
                                change: { session.quickSelectionSettings.edgeSensitivity = Int(min(255, max(0, $0.rounded()))) })
            }
            .help("How strongly high-contrast edges stop the selection")
            Picker("Sample", selection: $session.wandSettings.sampleAllLayers) {
                Text("This Layer").tag(false)
                Text("All Layers").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Read colors from the active layer only, or from every visible layer as shown")
        }
    }

    /// Tolerance, sample size, which pixels to read, and whether matches must connect.
    private var wandControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Tolerance").scrubbable(sensitivity: 1, value: $session.wandSettings.tolerance, range: 0...255)
                TextField("Tolerance", value: Binding(get: { session.wandSettings.tolerance },
                                                      set: { session.wandSettings.tolerance = min(255, max(0, $0)) }),
                          format: .number)
                    .frame(width: 44).textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .arrowSteps(value: { Double(session.wandSettings.tolerance) },
                                change: { session.wandSettings.tolerance = Int(min(255, max(0, $0.rounded()))) })
            }
            .help("How far each color channel (0–255) can differ from the clicked color and still be selected")
            Picker("Sample Size", selection: $session.wandSettings.sampleSize) {
                ForEach(WandSampleSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("Match the clicked pixel, or the average of the pixels around it")
            Picker("Sample", selection: $session.wandSettings.sampleAllLayers) {
                Text("This Layer").tag(false)
                Text("All Layers").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Read colors from the active layer only, or from every visible layer as shown")
            Toggle("Contiguous", isOn: $session.wandSettings.contiguous)
                .help("Select only similar pixels connected to the one you click; off selects them everywhere")
        }
    }

    private var magneticLassoControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Search").scrubbable(sensitivity: 1, value: Binding(
                    get: { Double(session.magneticLassoSettings.searchRadius) },
                    set: { session.magneticLassoSettings.searchRadius = min(64, max(1, Int($0.rounded()))) }),
                    range: 1...64)
                TextField("Search", value: Binding(
                    get: { session.magneticLassoSettings.searchRadius },
                    set: { session.magneticLassoSettings.searchRadius = min(64, max(1, $0)) }),
                    format: .number)
                    .frame(width: 44).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .arrowSteps(value: { Double(session.magneticLassoSettings.searchRadius) },
                                change: { session.magneticLassoSettings.searchRadius = min(64, max(1, Int($0.rounded()))) })
                    .unitSuffix("px")
            }
            .help("Distance around the pointer in which the Magnetic Lasso searches for an edge")
            HStack(spacing: 6) {
                Text("Edge").scrubbable(sensitivity: 1, value: Binding(
                    get: { Double(session.magneticLassoSettings.edgeSensitivity) },
                    set: { session.magneticLassoSettings.edgeSensitivity = min(255, max(0, Int($0.rounded()))) }),
                    range: 0...255)
                TextField("Edge", value: Binding(
                    get: { session.magneticLassoSettings.edgeSensitivity },
                    set: { session.magneticLassoSettings.edgeSensitivity = min(255, max(0, $0)) }),
                    format: .number)
                    .frame(width: 44).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .arrowSteps(value: { Double(session.magneticLassoSettings.edgeSensitivity) },
                                change: { session.magneticLassoSettings.edgeSensitivity = min(255, max(0, Int($0.rounded()))) })
                    .unitSuffix("px")
            }
            .help("Minimum contrast required for an edge to attract the lasso")
            Picker("Sample", selection: $session.wandSettings.sampleAllLayers) {
                Text("This Layer").tag(false)
                Text("All Layers").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Read edges from the active layer only, or from every visible layer as shown")
        }
    }

    private var objectSelectionControls: some View {
        HStack(spacing: 12) {
            Picker("Sample", selection: $session.objectSelectionSettings.sampleAllLayers) {
                Text("This Layer").tag(false)
                Text("All Layers").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Analyze the active layer only, or every visible layer as shown")
            HStack(spacing: 6) {
                Text("Edge").scrubbable(sensitivity: 1, value: $session.objectSelectionSettings.edgeOffset, range: -10...10)
                TextField("Edge", value: Binding(get: { session.objectSelectionSettings.edgeOffset },
                                                 set: { session.objectSelectionSettings.edgeOffset = min(10, max(-10, $0)) }),
                          format: .number)
                    .frame(width: 40).textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .arrowSteps(value: { Double(session.objectSelectionSettings.edgeOffset) },
                                change: { session.objectSelectionSettings.edgeOffset = Int(min(10, max(-10, $0.rounded()))) })
                    .unitSuffix("px")
            }
            // The bar squeezes text before controls, so without this the label and unit collapse to
            // nothing the moment a selection adds its own buttons, leaving an unlabelled number box.
            .fixedSize()
            .help("Positive values tighten the detected mask inward; negative values expand it outward")
        }
    }

    /// A button plus its pixel amount (1–500, default 1); both disabled without a selection.
    private func modifyControl(_ title: String, amount: Binding<Int>, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Button(title, action: action)
            TextField(title, value: Binding(get: { amount.wrappedValue },
                                            set: { amount.wrappedValue = min(500, max(1, $0)) }),
                      format: .number)
                .frame(width: 40).textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .arrowSteps(value: { Double(amount.wrappedValue) },
                            change: { amount.wrappedValue = Int(min(500, max(1, $0.rounded()))) })
                .unitSuffix("px", scrubValue: amount, sensitivity: 1, range: 1...500)
        }
        .disabled(!session.canModifySelection)
        .help("\(title) the selection by this many pixels")
    }
}

/// Tool-rail icon for the Polygonal Lasso: the lasso's loop and rope drawn as straight segments, in the
/// line weight of the SF Symbols beside it.
struct PolygonalLassoToolIcon: View {
    var body: some View {
        Canvas { context, size in
            let unit = size.width / 18
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            // Laid out like the SF Symbol lasso: a wide loop, a knot below its right side, a short rope.
            var loop = Path()
            loop.addLines([point(1.2, 7.0), point(4.0, 2.4), point(11.8, 1.8), point(16.8, 5.2), point(15.6, 10.4), point(7.0, 11.6)])
            loop.closeSubpath()
            var knot = Path()
            knot.addLines([point(8.9, 10.9), point(13.3, 10.5), point(11.6, 14.5)])
            knot.closeSubpath()
            var rope = Path()
            rope.addLines([point(11.6, 14.5), point(12.9, 17.3)])
            let style = StrokeStyle(lineWidth: 1.4 * unit, lineCap: .round, lineJoin: .round)
            for part in [loop, knot, rope] { context.stroke(part, with: .foreground, style: style) }
        }
        .accessibilityHidden(true)
    }
}

/// Selection modifiers share the filter panels' floating window and control layout.
struct SelectionAmountSheet: View {
    let session: EditorSession
    let operation: EditorSession.SelectionAmountOperation
    @State private var input: String
    @FocusState private var focused: Bool

    init(session: EditorSession, operation: EditorSession.SelectionAmountOperation) {
        self.session = session
        self.operation = operation
        let amount: Int
        switch operation {
        case .expand: amount = session.selectionExpandAmount
        case .contract: amount = session.selectionContractAmount
        case .feather: amount = session.selectionFeatherAmount
        }
        _input = State(initialValue: String(amount))
    }

    private var maximum: Int { operation == .feather ? 250 : 500 }
    private var amount: Int? {
        guard let value = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...maximum).contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("Amount").frame(minWidth: 60, alignment: .leading)
                    .scrubbable(sensitivity: 1,
                                value: Binding<Int>(get: { amount ?? 1 }, set: { input = String($0) }),
                                range: 1...maximum)
                Slider(value: Binding(get: { Double(amount ?? 1) },
                                      set: { input = String(Int($0.rounded())) }),
                       in: 1...Double(maximum), step: 1)
                TextField("Amount", text: $input)
                    .frame(width: 56).textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing).focused($focused)
                    .unitSuffix("px")
            }
            Text("Enter a whole number from 1 to \(maximum) px.")
                .font(.callout).foregroundStyle(.secondary)
                .opacity(amount == nil ? 1 : 0)
            Divider()
            HStack {
                Button("Cancel") { session.selectionAmountOperation = nil }
                    .configuredNativeShortcut(.escape)
                Spacer()
                Button("OK") {
                    if let amount { session.confirmSelectionAmount(amount) }
                }
                .configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
                .disabled(amount == nil)
            }
        }
        .padding(24).frame(width: 380).fixedSize()
        .onAppear { focused = true }
    }
}

struct ObjectSelectionToolIcon: View {
    var body: some View {
        Canvas { context, size in
            let unit = size.width / 18
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            let style = StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round, lineJoin: .round)
            for corners in [
                [point(2, 6), point(2, 2), point(6, 2)],
                [point(12, 2), point(16, 2), point(16, 6)],
                [point(16, 12), point(16, 16), point(12, 16)],
                [point(6, 16), point(2, 16), point(2, 12)]
            ] {
                var corner = Path()
                corner.addLines(corners)
                context.stroke(corner, with: .foreground, style: style)
            }
            var cursor = Path()
            cursor.addLines([point(7, 5), point(7, 14), point(9.6, 11.7), point(11.3, 15.3),
                             point(13.2, 14.4), point(11.5, 10.9), point(14.5, 10.9)])
            cursor.closeSubpath()
            context.fill(cursor, with: .foreground)
        }
        .accessibilityHidden(true)
    }
}
