import SwiftUI

struct LassoControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text((session.tool == .marquee ? "Marquee" : session.tool == .wand ? "Magic Wand" : "Lasso").localized).font(ToolHeaderStyle.titleFont)
            if session.tool == .marquee {
                Picker("Shape", selection: Binding(get: { session.marqueeKind }, set: { kind in
                    session.cancelLasso()
                    session.marqueeKind = kind
                })) {
                    ForEach(LassoKind.marqueeChoices, id: \.self) { Text($0.rawValue.localized).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Press M to switch between Rectangle and Ellipse")
            }
            if session.tool == .lasso {
                Picker("Lasso", selection: Binding(get: { session.lassoKind }, set: { kind in
                    session.cancelLasso()
                    session.lassoKind = kind
                })) {
                    ForEach(LassoKind.lassoChoices, id: \.self) { Text($0.rawValue.localized).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Press L to switch between Freehand and Polygonal")
            }
            // Shows held Shift/Option (or an outline's mode) live; clicking sets the choice.
            Picker("Mode", selection: Binding(get: { session.displayedSelectionMode },
                                              set: { session.selectionModeChoice = $0 })) {
                ForEach(SelectionMode.allCases, id: \.self) { Text($0.rawValue.localized).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Hold Shift to add or Option to subtract for one outline")
            if session.tool == .wand { wandControls }
            // Rectangles snap to whole pixels, so smoothing doesn't apply (as in Photoshop); ellipses curve.
            if session.tool == .lasso || session.tool == .wand || (session.tool == .marquee && session.marqueeKind == .ellipse) {
                Toggle("Anti-alias", isOn: $session.selectionAntialiased)
                    .help("Smooth selection edges; turn off for hard pixel edges")
            }
            Divider().frame(height: 18)
            modifyControl("Expand", amount: $session.selectionExpandAmount) {
                session.expandSelection(by: session.selectionExpandAmount)
            }
            modifyControl("Contract", amount: $session.selectionContractAmount) {
                session.contractSelection(by: session.selectionContractAmount)
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

    /// Tolerance, sample size, which pixels to read, and whether matches must connect.
    private var wandControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Tolerance")
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
                ForEach(WandSampleSize.allCases, id: \.self) { Text($0.title.localized).tag($0) }
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

    /// A button plus its pixel amount (1–500, default 1); both disabled without a selection.
    private func modifyControl(_ title: String, amount: Binding<Int>, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(title.localized, action: action)
            TextField(title.localized, value: Binding(get: { amount.wrappedValue },
                                            set: { amount.wrappedValue = min(500, max(1, $0)) }),
                      format: .number)
                .frame(width: 40).textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .arrowSteps(value: { Double(amount.wrappedValue) },
                            change: { amount.wrappedValue = Int(min(500, max(1, $0.rounded()))) })
                .unitSuffix("px")
        }
        .disabled(!session.canModifySelection)
        .help(String(localized: "\(title.localized) the selection by this many pixels"))
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
