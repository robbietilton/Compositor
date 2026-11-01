import SwiftUI

struct PressureCurveEditor: View {
    @Binding var curve: PressureCurve
    @State private var selectedPoint = 0
    private var selectedIndex: Int { min(selectedPoint, curve.points.count - 1) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pressure Curve").font(.subheadline.bold())
                Spacer()
                Button("Reset") { curve = PressureCurve() }
            }
            Picker("Profile", selection: Binding<PressureCurve.Profile?>(
                get: { PressureCurve.Profile.allCases.first { $0.curve == curve } },
                set: { if let profile = $0 { curve = profile.curve } })) {
                Text("Custom").tag(Optional<PressureCurve.Profile>.none).disabled(true)
                ForEach(PressureCurve.Profile.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            GeometryReader { geometry in
                Path { path in
                    for step in 0...4 {
                        let p = CGFloat(step) / 4
                        path.move(to: CGPoint(x: p * geometry.size.width, y: 0))
                        path.addLine(to: CGPoint(x: p * geometry.size.width, y: geometry.size.height))
                        path.move(to: CGPoint(x: 0, y: p * geometry.size.height))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: p * geometry.size.height))
                    }
                }.stroke(.secondary.opacity(0.2))
                Path { path in
                    for step in 0...256 {
                        let x = CGFloat(step) / 256
                        let location = CGPoint(x: x * geometry.size.width, y: (1 - curve.value(x)) * geometry.size.height)
                        if step == 0 { path.move(to: location) } else { path.addLine(to: location) }
                    }
                }.stroke(Color.accentColor, lineWidth: 2)
                ForEach(curve.points.indices, id: \.self) { index in
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                        .position(x: curve.points[index].x * geometry.size.width, y: (1 - curve.points[index].y) * geometry.size.height)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("pressureGraph")).onChanged { drag in
                            selectedPoint = index
                            if index > 0 && index < curve.points.count - 1 {
                                curve.points[index].x = min(curve.points[index + 1].x.nextDown,
                                    max(curve.points[index - 1].x.nextUp, drag.location.x / geometry.size.width))
                            }
                            curve.points[index].y = min(1, max(0, 1 - drag.location.y / geometry.size.height))
                        })
                }
            }.frame(height: 130).coordinateSpace(name: "pressureGraph").accessibilityHidden(true)
            HStack {
                Picker("Curve Point", selection: Binding(get: { selectedIndex }, set: { selectedPoint = $0 })) {
                    ForEach(curve.points.indices, id: \.self) { Text("Point \($0)").tag($0) }
                }.labelsHidden().frame(width: 100)
                Text("Easing")
                Slider(value: Binding(get: { curve.easing(at: selectedIndex) },
                    set: { curve.points[selectedIndex].easing = $0 }), in: 0...1)
                    .accessibilityLabel("Pressure curve point \(selectedIndex) easing")
                Text("\(Int(curve.easing(at: selectedIndex) * 100))%").monospacedDigit().frame(width: 38)
            }
            Text("Drag a point, then adjust its easing: 0% straight, 100% smooth.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(curve.points.indices), id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Point \(index)")
                        Spacer()
                        if index > 0 && index < curve.points.count - 1 {
                            Button("Remove") { curve.points.remove(at: index) }
                                .accessibilityLabel("Remove pressure curve point \(index)")
                        }
                    }
                    if index > 0 && index < curve.points.count - 1 {
                        Text("Input \(Int(curve.points[index].x * 100))%")
                        Slider(value: Binding(get: { curve.points[index].x }, set: { curve.points[index].x = $0 }),
                        in: curve.points[index - 1].x.nextUp...curve.points[index + 1].x.nextDown)
                        .accessibilityLabel("Pressure curve point \(index) input")
                    }
                    Text("Output \(Int(curve.points[index].y * 100))%")
                    Slider(value: Binding(get: { curve.points[index].y }, set: { curve.points[index].y = $0 }),
                        in: 0...1)
                        .accessibilityLabel("Pressure curve point \(index) output")
                }
            }
            Button("Add Point") {
                let index = curve.points.indices.dropLast().max {
                    curve.points[$0 + 1].x - curve.points[$0].x < curve.points[$1 + 1].x - curve.points[$1].x
                }!
                let x = (curve.points[index].x + curve.points[index + 1].x) / 2
                curve.points.insert(.init(x: x, y: curve.value(x)), at: index + 1)
            }.disabled(curve.points.count >= 16)
        }
    }
}
