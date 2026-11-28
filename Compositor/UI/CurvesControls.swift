import SwiftUI

struct CurvesControls: View {
    @Binding var settings: CurvesSettings
    @State private var selected: Int?
    @State private var dragging: Int?
    private var points: [CurvePoint] { settings.channels[settings.channel.index] }
    /// Each channel's curve color: RGB in white, then red, green and blue.
    private static let colors: [Color] = [.white, Color(red: 1, green: 0.27, blue: 0.23), Color(red: 0.2, green: 0.85, blue: 0.3),
                                          Color(red: 0.3, green: 0.55, blue: 1)]
    /// The untouched diagonal, from black to white.
    private static func isStraight(_ points: [CurvePoint]) -> Bool {
        points.count == 2 && points[0].x == 0 && points[0].y == 0 && points[1].x == 255 && points[1].y == 255
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Channel", selection: $settings.channel) {
                ForEach(LevelsChannel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.onChange(of: settings.channel) { _, _ in selected = nil; dragging = nil }
            Canvas { context, size in
                func position(_ p: CurvePoint) -> CGPoint { CGPoint(x: p.x/255*size.width, y: (1-p.y/255)*size.height) }
                // A color channel's graph runs from its color, top left, to its opposite, bottom right, as in Photoshop:
                // raising the curve adds the color and lowering it adds the opposite (red and cyan, green and magenta,
                // blue and yellow). Dark, so the curve and grid stay clear.
                if settings.channel != .rgb {
                    let channel = settings.channel.index - 1
                    let color = (0..<3).map { $0 == channel ? 1.0 : 0.0 }
                    func tone(_ c: [Double]) -> Color { Color(red: c[0] * 0.32, green: c[1] * 0.27, blue: c[2] * 0.36) }
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                        Gradient(colors: [tone(color), tone(color.map { 1 - $0 })]),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                }
                var grid = Path()
                for i in 0...4 {
                    let f = CGFloat(i)/4
                    grid.move(to: CGPoint(x: f*size.width, y: 0)); grid.addLine(to: CGPoint(x: f*size.width, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: f*size.height)); grid.addLine(to: CGPoint(x: size.width, y: f*size.height))
                }
                context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
                func curve(_ channel: Int) -> Path {
                    var line = Path()
                    for x in 0...255 {
                        let p = position(CurvePoint(x: Double(x), y: settings.value(Double(x), channel: channel)))
                        if x == 0 { line.move(to: p) } else { line.addLine(to: p) }
                    }
                    return line
                }
                // On RGB, each color channel that's been changed shows behind it in its own color, as in Photoshop; a
                // channel left straight would only lie on the diagonal.
                let current = settings.channel.index
                if settings.channel == .rgb {
                    for channel in 1...3 where !Self.isStraight(settings.channels[channel]) {
                        context.stroke(curve(channel), with: .color(Self.colors[channel]), lineWidth: 1.5)
                    }
                }
                context.stroke(curve(current), with: .color(Self.colors[current]), lineWidth: 2)
                for (i, point) in points.enumerated() {
                    let p = position(point)
                    context.fill(Path(ellipseIn: CGRect(x: p.x-4, y: p.y-4, width: 8, height: 8)),
                                 with: .color(selected == i ? .accentColor : Self.colors[current]))
                }
            }
            .frame(height: 260).background(Color.black.opacity(0.35))
            .contentShape(Rectangle())
            .overlay { GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    let x = min(255, max(0, Double(event.location.x/geometry.size.width)*255))
                    let y = min(255, max(0, 255-Double(event.location.y/geometry.size.height)*255))
                    var p = points
                    if dragging == nil {
                        if let index = p.indices.min(by: { hypot(p[$0].x-x,p[$0].y-y) < hypot(p[$1].x-x,p[$1].y-y) }), hypot(p[index].x-x,p[index].y-y) < 14 {
                            dragging = index
                        } else if p.count < 32, x > 1, x < 254, p.allSatisfy({ abs($0.x-x) > 1 }) {
                            p.append(CurvePoint(x: x, y: y)); p.sort { $0.x < $1.x }
                            settings.channels[settings.channel.index] = p
                            dragging = p.firstIndex { $0.x == x }
                        }
                    }
                    guard let i = dragging, p.indices.contains(i) else { return }
                    selected = i
                    p[i].y = y
                    if i > 0, i < p.count-1 { p[i].x = min(p[i+1].x-1, max(p[i-1].x+1, x)) }
                    settings.channels[settings.channel.index] = p
                }.onEnded { _ in dragging = nil })
            } }
            Text("Click to add a point. Drag to adjust.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if let selected, points.indices.contains(selected) {
                    Text("Input \(Int(points[selected].x)) · Output \(Int(points[selected].y))").monospacedDigit()
                }
                Spacer()
                Button("Remove point") {
                    if let selected, selected > 0, selected < points.count-1 { settings.channels[settings.channel.index].remove(at: selected); self.selected = nil }
                }.disabled(selected == nil || selected == 0 || selected == points.count-1)
            }
            // On RGB, where the color channels show too, it resets them all; on a color channel, just that one.
            Button(settings.channel == .rgb ? "Reset all" : "Reset curve") {
                let straight = [CurvePoint(x: 0, y: 0), CurvePoint(x: 255, y: 255)]
                if settings.channel == .rgb {
                    for channel in settings.channels.indices { settings.channels[channel] = straight }
                } else {
                    settings.channels[settings.channel.index] = straight
                }
                selected = nil
            }
        }
    }
}
