import SwiftUI

struct ShapeControls: View {
    @Bindable var session: EditorSession

    /// A selected rectangle or ellipse takes the fill, stroke and radius, unless Line is chosen: that bar is the
    /// line being drawn, then the line just created.
    private var editsSelection: Bool { session.editingShapeLayer != nil && session.shapeKind != .line }
    private var editsLine: Bool { session.editingLineLayer != nil && (session.shapeKind == .line || session.editingShapeLayer == nil) }
    private var showsLine: Bool { session.shapeKind == .line || editsLine }
    private var showsStroke: Bool { !showsLine && (editsSelection || session.shapeKind != .line) }
    private var showsRadius: Bool {
        if showsLine { return false }
        if let kind = session.editingShapeLayer?.liveShape?.style.kind { return kind == .rectangle }
        return session.shapeKind == .rectangle
    }

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
            .help("Shift-U (or Tab) steps through Rectangle, Ellipse and Line")
            HStack(spacing: 6) {
                Text(showsStroke ? "Fill" : "Color")
                Button { session.openShapeFillPicker() } label: {
                    ColorSwatch(color: Color(nsColor: session.displayedShapeFill.nsColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fill color")
                .help(editsLine ? "Color of the selected line"
                      : session.shapeKind == .line ? "Color of the next line"
                      : editsSelection ? "Fill color of the selected shape"
                      : "Shapes fill with the foreground color; click to change it")
            }
            if showsStroke {
                HStack(spacing: 6) {
                    Text("Stroke")
                    Button { session.openShapeStrokePicker() } label: {
                        ColorSwatch(color: Color(nsColor: session.displayedShapeStroke.nsColor))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stroke color")
                    Text("Width").scrubbable(sensitivity: 1, value: strokeWidth, range: 0...5000,
                                             onStart: session.beginShapeStyleEdit, onEnd: session.finishShapeStyleEdit)
                    // The slider covers everyday widths; typing or scrubbing reaches up to 5000.
                    AppSlider(value: Binding(get: { min(50, strokeWidth.wrappedValue) },
                                          set: { strokeWidth.wrappedValue = $0.rounded() }), in: 0...50,
                              onEditingChanged: { if $0 { session.beginShapeStyleEdit() } else { session.finishShapeStyleEdit() } })
                        .frame(width: 100)
                    TextField("Width", value: strokeWidth, format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.roundedBorder)
                        .arrowSteps(value: { session.displayedStrokeWidth },
                                    change: { session.setDisplayedStrokeWidth($0) })
                }
                .help("Stroke drawn inside the shape, in pixels. 0 draws none")
            }
            if showsLine {
                HStack(spacing: 6) {
                    Text("Width").scrubbable(sensitivity: 1, value: lineWidth, range: 1...5000,
                                             onStart: session.beginShapeStyleEdit, onEnd: session.finishShapeStyleEdit)
                    // The slider covers everyday widths; typing or scrubbing reaches up to 5000.
                    AppSlider(value: Binding(get: { min(50, lineWidth.wrappedValue) },
                                          set: { lineWidth.wrappedValue = $0.rounded() }), in: 1...50,
                              onEditingChanged: { if $0 { session.beginShapeStyleEdit() } else { session.finishShapeStyleEdit() } })
                        .frame(width: 100)
                    TextField("Width", value: lineWidth, format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.roundedBorder)
                        .arrowSteps(value: { session.displayedLineWidth },
                                    change: { session.setDisplayedLineWidth($0) })
                }
                HStack(spacing: 6) {
                    Text("Style")
                    Picker("Style", selection: Binding(get: { session.displayedLineStyle },
                                                      set: { session.setDisplayedLineStyle($0) })) {
                        ForEach(ShapeLineStyle.allCases, id: \.self) { style in
                            Image(nsImage: LineSample.style(style)).accessibilityLabel(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                .help(editsLine ? "Dashes of the selected line; they grow with its width"
                      : "Solid, dashed or dotted; dashes grow with the line's width")
                HStack(spacing: 6) {
                    Text("Cap")
                    Picker("Cap", selection: Binding(get: { session.displayedLineCap },
                                                    set: { session.setDisplayedLineCap($0) })) {
                        ForEach(ShapeLineCap.allCases, id: \.self) { cap in
                            Label { Text(cap.rawValue) } icon: { Image(nsImage: LineSample.cap(cap)) }.tag(cap)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                .help(editsLine ? "How this line's ends are finished"
                      : "How the line's ends, and each of its dashes and dots, are finished")
            }
            if showsRadius {
                HStack(spacing: 6) {
                    Text("Radius").scrubbable(sensitivity: 1, value: cornerRadius, range: 0...5000,
                                              onStart: session.beginShapeStyleEdit, onEnd: session.finishShapeStyleEdit)
                    AppSlider(value: Binding(get: { min(200, cornerRadius.wrappedValue) },
                                          set: { cornerRadius.wrappedValue = $0.rounded() }), in: 0...200,
                              onEditingChanged: { if $0 { session.beginShapeStyleEdit() } else { session.finishShapeStyleEdit() } })
                        .frame(width: 100)
                    TextField("Radius", value: cornerRadius, format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.roundedBorder)
                        .arrowSteps(value: { session.displayedCornerRadius },
                                    change: { session.setDisplayedCornerRadius($0) })
                }
                .help(editsSelection
                      ? "Round this rectangle's corners by this many pixels; 0 keeps them square"
                      : "Round the rectangle's corners by this many pixels; 0 keeps them square")
                Toggle("Smooth Corners", isOn: Binding(get: { session.displayedShapeSmoothing },
                                                      set: { session.setDisplayedShapeSmoothing($0) }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .disabled(session.displayedCornerRadius <= 0)
                    .help(session.displayedCornerRadius <= 0
                          ? "Set a radius above 0 to use smooth corners."
                          : "Use smooth squircle corners at 60% smoothing, matching Figma's iOS setting")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
        .onChange(of: session.colorPicker?.color) { _, _ in session.previewShapeColor() }
    }

    private var strokeWidth: Binding<Double> {
        Binding(get: { session.displayedStrokeWidth }, set: { session.setDisplayedStrokeWidth($0) })
    }
    private var cornerRadius: Binding<Double> {
        Binding(get: { session.displayedCornerRadius }, set: { session.setDisplayedCornerRadius($0) })
    }
    private var lineWidth: Binding<Double> {
        Binding(get: { session.displayedLineWidth }, set: { session.setDisplayedLineWidth($0) })
    }
}

/// Small drawings for the Line shape's menus. Template images, so a menu tints them with its text and highlight.
@MainActor private enum LineSample {
    private static var images: [String: NSImage] = [:]

    /// A stretch of line in `style`, as it looks drawn.
    static func style(_ style: ShapeLineStyle) -> NSImage {
        image("style." + style.rawValue, size: NSSize(width: 84, height: 10)) { context in
            context.strokeShapeLine(from: CGPoint(x: 2, y: 5), to: CGPoint(x: 82, y: 5), width: 2, style: style, cap: .round)
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
