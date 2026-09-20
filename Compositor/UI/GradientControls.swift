import SwiftUI

struct GradientControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text("Gradient").font(ToolHeaderStyle.titleFont)
            Picker("Shape", selection: $session.gradientSettings.shape) {
                ForEach(GradientShape.allCases, id: \.self) { Text($0.rawValue.localized).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Linear runs along the line; Radial spreads out from the start point")
            swatch
            Picker("Colors", selection: $session.gradientSettings.style) {
                ForEach(GradientStyle.allCases, id: \.self) { Text($0.rawValue.localized).tag($0) }
            }
            .labelsHidden().fixedSize()
            Toggle("Reverse", isOn: $session.gradientSettings.reversed)
            Text("Opacity")
            Slider(value: $session.gradientSettings.opacity, in: 0.01...1).frame(width: 100)
            TextField("Opacity", value: Binding<Double>(get: { Double(session.gradientSettings.opacity * 100) },
                set: { session.gradientSettings.opacity = $0.isFinite ? CGFloat(min(100, max(1, $0)) / 100) : 1 }),
                format: .number.precision(.fractionLength(0)))
                .frame(width: 42).textFieldStyle(.roundedBorder)
                .arrowSteps(value: { Double(session.gradientSettings.opacity * 100) },
                            change: { session.gradientSettings.opacity = CGFloat(min(100, max(1, $0)) / 100) })
                .help("Press 1–9 for 10–90%, 0 for 100%")
                .unitSuffix("%")
            Spacer(minLength: 0)
            if session.isMaskSelected { Text("Mask").foregroundStyle(.secondary) }
            if session.gradientEdit != nil {
                Button("Cancel") { session.cancelGradient() }
                Button("Apply") { Task { await session.commitGradient() } }
            }
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }

    /// Current colors, over a checkerboard so transparency reads as transparency.
    private var swatch: some View {
        let colors = session.gradientColors(mask: false).map { Color(cgColor: $0) }
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return Canvas { context, size in
            let tile: CGFloat = 4
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in 0..<Int(ceil(size.width / tile)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)),
                                 with: .color(.gray.opacity(0.45)))
                }
            }
        }
        .background(.white)
        .overlay { LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing) }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.black.opacity(0.5), lineWidth: 1) }
        .frame(width: 56, height: 18)
        .accessibilityHidden(true)
    }
}

/// One-color tool-rail icon: a Floyd–Steinberg dithered fade from empty to solid, so it
/// reads as a gradient in the same monochrome style as the SF Symbols beside it.
struct GradientToolIcon: View {
    /// 16×16 so each dot is exactly 1 pt inside the icon's 16 pt frame.
    private static let pattern: [[Bool]] = {
        let size = 16
        var ramp = (0..<size).map { _ in (0..<size).map { CGFloat($0) / CGFloat(size - 1) } }
        var result = Array(repeating: Array(repeating: false, count: size), count: size)
        for y in 0..<size {
            for x in 0..<size {
                let on = ramp[y][x] >= 0.5
                result[y][x] = on
                let error = ramp[y][x] - (on ? 1 : 0)
                if x + 1 < size { ramp[y][x + 1] += error * 7 / 16 }
                guard y + 1 < size else { continue }
                if x > 0 { ramp[y + 1][x - 1] += error * 3 / 16 }
                ramp[y + 1][x] += error * 5 / 16
                if x + 1 < size { ramp[y + 1][x + 1] += error / 16 }
            }
        }
        return result
    }()
    var body: some View {
        Canvas { context, size in
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let shape = Path(roundedRect: frame, cornerRadius: 3.5)
            let cell = frame.width / CGFloat(Self.pattern.count)
            var dots = Path()
            for (row, line) in Self.pattern.enumerated() {
                for (column, on) in line.enumerated() where on {
                    dots.addRect(CGRect(x: frame.minX + CGFloat(column) * cell, y: frame.minY + CGFloat(row) * cell,
                                        width: cell, height: cell))
                }
            }
            context.clip(to: shape)
            context.fill(dots, with: .foreground)
            context.stroke(shape, with: .foreground, lineWidth: 1.4)
        }
        .accessibilityHidden(true)
    }
}
