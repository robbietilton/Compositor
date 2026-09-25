import SwiftUI

struct ShapeControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text("Shape").font(ToolHeaderStyle.titleFont)
            Picker("Shape", selection: Binding(get: { session.shapeKind }, set: { kind in
                session.cancelShape()
                session.shapeKind = kind
            })) {
                ForEach(ShapeKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Shift-U (or Tab) steps through Rectangle, Ellipse, Star, Polygon and Line")
            if session.shapeKind == .star {
                count("Points", value: $session.shapeStarPoints, range: ShapeKind.starPoints)
                    .help("How many points the star has")
            }
            if session.shapeKind == .polygon {
                count("Sides", value: $session.shapePolygonSides, range: ShapeKind.polygonSides)
                    .help("How many sides the polygon has")
            }
            if session.shapeKind == .line {
                HStack(spacing: 6) {
                    Text("Width").scrubbable(sensitivity: 1, value: $session.shapeLineWidth, range: 1...5000)
                    Slider(value: Binding(get: { min(100, session.shapeLineWidth) },
                                          set: { session.shapeLineWidth = $0.rounded() }), in: 1...100)
                        .frame(width: 100)
                    TextField("Width", value: Binding(get: { session.shapeLineWidth },
                                                      set: { session.shapeLineWidth = $0.isFinite ? min(5000, max(1, $0)) : 4 }),
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .arrowSteps(value: { session.shapeLineWidth },
                                    change: { session.shapeLineWidth = min(5000, max(1, $0)) })
                        .unitSuffix("px")
                }
            }
            if session.shapeKind == .rectangle {
                HStack(spacing: 6) {
                    Text("Radius").scrubbable(sensitivity: 1, value: $session.shapeCornerRadius, range: 0...5000)
                    Slider(value: Binding(get: { min(200, session.shapeCornerRadius) },
                                          set: { session.shapeCornerRadius = $0.rounded() }), in: 0...200)
                        .frame(width: 100)
                    TextField("Radius", value: Binding(get: { session.shapeCornerRadius },
                                                       set: { session.shapeCornerRadius = $0.isFinite ? min(5000, max(0, $0)) : 0 }),
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .arrowSteps(value: { Double(session.shapeCornerRadius) },
                                    change: { session.shapeCornerRadius = min(5000, max(0, CGFloat($0))) })
                        .unitSuffix("px")
                }
                .help("Round the rectangle's corners by this many pixels; 0 keeps them square")
            }
            HStack(spacing: 6) {
                Text("Fill")
                Button { session.openColorPicker(background: false) } label: {
                    let swatch = RoundedRectangle(cornerRadius: 3, style: .continuous)
                    swatch.fill(Color(nsColor: session.foregroundColor.nsColor))
                        .overlay { swatch.strokeBorder(.black.opacity(0.5), lineWidth: 1) }
                        .frame(width: 36, height: 18)
                }
                .buttonStyle(.plain)
                .help("Shapes fill with the foreground color; click to change it")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }

    /// A whole-number setting: a slider stepping one at a time across its whole range, and a field to type it.
    private func count(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        let clamp: (Double) -> Int = { $0.isFinite ? min(range.upperBound, max(range.lowerBound, Int($0.rounded()))) : range.lowerBound }
        let amount = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = clamp($0) })
        return HStack(spacing: 6) {
            Text(title).scrubbable(sensitivity: 1, value: value, range: range)
            Slider(value: amount, in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .frame(width: 100)
            TextField(title, value: amount, format: .number.precision(.fractionLength(0)))
                .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .arrowSteps(value: { amount.wrappedValue }, change: { amount.wrappedValue = $0 })
        }
    }
}
