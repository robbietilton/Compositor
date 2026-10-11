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
                starInset
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
                HStack(spacing: 6) {
                    Text("Style")
                    Picker("Style", selection: $session.shapeLineStyle) {
                        ForEach(ShapeLineStyle.allCases, id: \.self) { style in
                            Image(nsImage: LineSample.style(style)).accessibilityLabel(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                .help("Solid, dashed or dotted; dashes grow with the line's width")
                HStack(spacing: 6) {
                    Text("Cap")
                    Picker("Cap", selection: $session.shapeLineCap) {
                        ForEach(ShapeLineCap.allCases, id: \.self) { cap in
                            Label { Text(cap.rawValue) } icon: { Image(nsImage: LineSample.cap(cap)) }.tag(cap)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                .help("How the line's ends, and each of its dashes and dots, are finished")
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

    /// How deep a star's points are cut, as a percentage of their reach. It follows the point count, keeping the
    /// sides even, until it is moved; Even goes back to that.
    private var starInset: some View {
        let range = Double(ShapeKind.starInsets.lowerBound * 100)...Double(ShapeKind.starInsets.upperBound * 100)
        let even = Double(ShapeKind.evenInset(points: session.shapeStarPoints)) * 100
        let percent = Binding(get: { (session.shapeStarInset.map { $0 * 100 } ?? even).rounded() },
                              set: { value in
                                  guard value.isFinite else { return }
                                  session.shapeStarInset = min(range.upperBound, max(range.lowerBound, value.rounded())) / 100
                              })
        return HStack(spacing: 6) {
            Text("Inset").scrubbable(sensitivity: 1, value: percent, range: range)
            Slider(value: percent, in: range).frame(width: 100)
            TextField("Inset", value: percent, format: .number.precision(.fractionLength(0)))
                .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .arrowSteps(value: { percent.wrappedValue }, change: { percent.wrappedValue = $0 })
                .unitSuffix("%")
            if session.shapeStarInset != nil {
                Button("Even") { session.shapeStarInset = nil }
                    .controlSize(.small)
                    .help("Go back to the inset that keeps the star's sides even for its number of points")
            }
        }
        .help("How far the star's inner corners are pulled in toward its center")
    }

    /// A whole-number setting: a slider stepping one at a time across its whole range, and a field to type it.
    private func count(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        let clamp: (Double) -> Int = { $0.isFinite ? min(range.upperBound, max(range.lowerBound, Int($0.rounded()))) : range.lowerBound }
        let amount = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = clamp($0) })
        return HStack(spacing: 6) {
            Text(title).scrubbable(sensitivity: 1, value: value, range: range)
            Slider(value: amount, in: Double(range.lowerBound)...Double(range.upperBound))
                .frame(width: 100)
            TextField(title, value: amount, format: .number.precision(.fractionLength(0)))
                .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .arrowSteps(value: { amount.wrappedValue }, change: { amount.wrappedValue = $0 })
        }
    }
}

/// Small drawings for the Line shape's menus. Template images, so a menu tints them with its text and highlight.
@MainActor private enum LineSample {
    private static var images: [String: NSImage] = [:]

    /// A stretch of line in `style`, as it looks drawn.
    static func style(_ style: ShapeLineStyle) -> NSImage {
        image("style." + style.rawValue, size: NSSize(width: 84, height: 10)) { context in
            context.setShapeLine(width: 2, style: style, cap: .round)
            context.move(to: CGPoint(x: 2, y: 5))
            context.addLine(to: CGPoint(x: 82, y: 5))
            context.strokePath()
        }
    }

    /// The end of a thick line in outline, with its center line running into the cap.
    static func cap(_ cap: ShapeLineCap) -> NSImage {
        image("cap." + cap.rawValue, size: NSSize(width: 18, height: 14)) { context in
            let center = CGMutablePath()
            center.move(to: CGPoint(x: 0, y: 7))
            center.addLine(to: CGPoint(x: 10, y: 7))
            context.addPath(center.copy(strokingWithWidth: 11, lineCap: cap.cgLineCap, lineJoin: .miter, miterLimit: 10))
            context.setLineWidth(1.5)
            context.strokePath()
            context.addPath(center)
            context.setLineWidth(1.5)
            context.strokePath()
            context.fillEllipse(in: CGRect(x: 8, y: 5, width: 4, height: 4))
        }
    }

    private static func image(_ key: String, size: NSSize, draw: @escaping (CGContext) -> Void) -> NSImage {
        if let image = images[key] { return image }
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(.black)
            context.setFillColor(.black)
            draw(context)
            return true
        }
        image.isTemplate = true
        images[key] = image
        return image
    }
}
