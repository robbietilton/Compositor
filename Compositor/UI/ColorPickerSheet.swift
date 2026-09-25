import SwiftUI
import AppKit

/// Photoshop-style picker: saturation/brightness field, vertical hue strip,
/// new/current preview, RGB and hex entry. Lives in a movable floating panel so
/// the canvas stays visible and can be clicked to sample a color.
struct ColorPickerSheet: View {
    @Bindable var state: ColorPickerState
    let finish: (Bool) -> Void
    @State private var hexDraft = ""
    @FocusState private var hexFocused: Bool
    private let fieldSize: CGFloat = 256

    private var hsb: PickerHSB {
        get { state.hsb }
        nonmutating set { state.hsb = newValue }
    }
    private var color: PaletteColor { state.color }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            saturationBrightnessField
            hueStrip
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    preview
                    VStack(spacing: 8) {
                        Button { finish(true) } label: { Text("OK").frame(maxWidth: .infinity) }
                            .configuredNativeShortcut(.return)
                        Button { finish(false) } label: { Text("Cancel").frame(maxWidth: .infinity) }
                            .configuredNativeShortcut(.escape)
                    }
                    .controlSize(.large).frame(width: 90)
                }
                Spacer(minLength: 12)
                fields
                Text("Click the canvas to sample")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            .frame(width: 180, height: fieldSize, alignment: .topLeading)
        }
        .padding(20)
        .fixedSize()
        .onAppear { hexDraft = color.hex }
        .onChange(of: color) { _, new in if !hexFocused { hexDraft = new.hex } }
        .onChange(of: hexFocused) { _, focused in if !focused { commitHex() } }
    }

    private var saturationBrightnessField: some View {
        ZStack {
            LinearGradient(colors: [.white, PickerHSB(hue: hsb.hue, saturation: 1, brightness: 1).rgb.swiftUI],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            Circle()
                .strokeBorder(.white, lineWidth: 1.5)
                .background(Circle().strokeBorder(.black, lineWidth: 0.75).padding(-0.75))
                .frame(width: 12, height: 12)
                .position(x: hsb.saturation * fieldSize, y: (1 - hsb.brightness) * fieldSize)
        }
        .frame(width: fieldSize, height: fieldSize)
        .clipShape(Rectangle())
        .overlay { Rectangle().strokeBorder(.black.opacity(0.6), lineWidth: 1) }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            hsb.saturation = min(1, max(0, value.location.x / fieldSize))
            hsb.brightness = 1 - min(1, max(0, value.location.y / fieldSize))
        })
        .accessibilityLabel(localized("Saturation and brightness"))
    }

    private var hueStrip: some View {
        let stripWidth: CGFloat = 20
        let markerY = (1 - hsb.hue / 360) * fieldSize
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: stride(from: 360.0, through: 0, by: -60).map {
                PickerHSB(hue: $0, saturation: 1, brightness: 1).rgb.swiftUI
            }, startPoint: .top, endPoint: .bottom)
                .frame(width: stripWidth, height: fieldSize)
                .overlay { Rectangle().strokeBorder(.black.opacity(0.6), lineWidth: 1) }
                .padding(.horizontal, 7)
            HStack(spacing: stripWidth) {
                HueArrow().fill(.primary).frame(width: 7, height: 10)
                HueArrow().fill(.primary).frame(width: 7, height: 10).scaleEffect(x: -1)
            }
            .offset(y: markerY - 5)
        }
        .frame(width: stripWidth + 14, height: fieldSize)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            hsb.hue = (1 - min(1, max(0, value.location.y / fieldSize))) * 360
        })
        .accessibilityLabel(localized("Hue"))
        .accessibilityValue("\(Int(hsb.hue.rounded())) degrees")
    }

    private var preview: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color.swiftUI)
            .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.6), lineWidth: 1) }
            .frame(width: 64, height: 64)
            .accessibilityLabel(localized("New color"))
    }

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            channelRow("R", \.red)
            channelRow("G", \.green)
            channelRow("B", \.blue)
            GridRow {
                Text("#").frame(width: 14, alignment: .leading)
                TextField("Hex", text: $hexDraft)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 84)
                    .focused($hexFocused)
                    .onSubmit(commitHex)
                    .accessibilityLabel(localized("Hex color"))
            }
        }
    }

    private func channelRow(_ label: String, _ channel: WritableKeyPath<PaletteColor, CGFloat>) -> some View {
        let channelValue = Binding<Int>(
            get: { Int((color[keyPath: channel] * 255).rounded()) },
            set: { newValue in
                var rgb = color
                rgb[keyPath: channel] = CGFloat(min(255, max(0, newValue))) / 255
                hsb.setRGB(rgb)
            })
        return GridRow {
            Text(localized(label)).frame(width: 14, alignment: .leading)
                .scrubbable(sensitivity: 1, value: channelValue, range: 0...255)
            TextField(localized(label), value: channelValue, format: .number)
                .frame(width: 52)
                .arrowSteps(value: { Double(Int((color[keyPath: channel] * 255).rounded())) },
                            change: { newValue in
                                var rgb = color
                                rgb[keyPath: channel] = CGFloat(min(255, max(0, newValue.rounded()))) / 255
                                hsb.setRGB(rgb)
                            })
                .accessibilityLabel(localized(label == "R" ? "Red" : label == "G" ? "Green" : "Blue"))
        }
    }

    private func commitHex() {
        if let parsed = PaletteColor(hex: hexDraft) { hsb.setRGB(parsed) }
        hexDraft = color.hex
    }
}

private struct HueArrow: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

extension PaletteColor {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

/// Hosts the picker in the shared floating panel: first opened centered on the canvas,
/// afterwards wherever it was last left. Closing it with the title-bar button cancels.
final class ColorPickerPanelController: NSObject {
    static let identifier = NSUserInterfaceItemIdentifier("colorPickerPanel")
    private let panel = FloatingPanelController(name: "colorPickerPanel")
    private weak var session: EditorSession?

    func show(_ state: ColorPickerState, session: EditorSession) {
        self.session = session
        panel.onClose = { [weak session] in
            if session?.colorPicker != nil { session?.closeColorPicker(commit: false) }
        }
        panel.show(title: state.target.title,
                   content: ColorPickerSheet(state: state) { [weak session] commit in
                       session?.closeColorPicker(commit: commit)
                   })
    }

    func close() { panel.close() }

    /// Returns keyboard focus to the picker after a click on the canvas sampled a color.
    static func refocus() { FloatingPanelController.refocus(identifier) }
}
