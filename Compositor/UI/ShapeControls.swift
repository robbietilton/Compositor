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
            .help("Shift-U (or Tab) steps through Rectangle, Ellipse and Line")
            Button { session.openColorPicker(background: false) } label: {
                let swatch = RoundedRectangle(cornerRadius: 3, style: .continuous)
                swatch.fill(Color(nsColor: session.foregroundColor.nsColor))
                    .overlay { swatch.strokeBorder(.black.opacity(0.5), lineWidth: 1) }
                    .frame(width: 36, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fill color")
            .help("Shapes fill with the foreground color; click to change it")
            if session.shapeKind == .line {
                HStack(spacing: 6) {
                    Text("Width").scrubbable(sensitivity: 1, value: $session.shapeLineWidth, range: 1...5000)
                    // The slider covers everyday widths; typing or scrubbing reaches up to 5000.
                    Slider(value: Binding(get: { min(50, session.shapeLineWidth) },
                                          set: { session.shapeLineWidth = $0.rounded() }), in: 1...50)
                        .frame(width: 100)
                    TextField("Width", value: Binding(get: { session.shapeLineWidth },
                                                      set: { session.shapeLineWidth = $0.isFinite ? min(5000, max(1, $0)) : 4 }),
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.roundedBorder)
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
                        .frame(width: 48).textFieldStyle(.roundedBorder)
                        .arrowSteps(value: { Double(session.shapeCornerRadius) },
                                    change: { session.shapeCornerRadius = min(5000, max(0, CGFloat($0))) })
                        .unitSuffix("px")
                }
                .help("Round the rectangle's corners by this many pixels; 0 keeps them square")
                Toggle("Smooth Corners", isOn: $session.shapeSmoothing)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .disabled(session.shapeCornerRadius <= 0)
                    .help(session.shapeCornerRadius <= 0
                          ? "Set a radius above 0 to use smooth corners."
                          : "Use smooth squircle corners at 60% smoothing, matching Figma's iOS setting")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
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
