import SwiftUI
import AppKit

/// Photoshop-style picker: saturation/brightness field, vertical hue strip,
/// new/current preview, RGB and hex entry, with Cancel and OK below as in the app's other panels. Lives in a movable floating panel so
/// the canvas stays visible and can be clicked to sample a color.
struct ColorPickerSheet: View {
    let state: ColorPickerState
    let finish: (Bool) -> Void
    @FocusState private var hexFocused: Bool
    @FocusState private var focusedChannel: ColorPickerState.Channel?
    private let fieldSize: CGFloat = 245

    private var hsb: PickerHSB { state.hsb }
    private var color: PaletteColor { state.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                saturationBrightnessField
                hueStrip
                VStack(alignment: .leading, spacing: 0) {
                    preview
                    Spacer(minLength: 12)
                    fields
                }
                .frame(width: 84, height: fieldSize, alignment: .topLeading)
            }
            Divider()
            // The hint fills the footer's left, so Cancel and OK sit together on the right rather than at opposite
            // ends as in the other panels: spread out across an otherwise empty row, they left the picker looking unfinished.
            HStack(spacing: 8) {
                // A dialog covers the canvas, so there's nothing to sample.
                if case .dialog = state.target {} else {
                    Text("Click the canvas to sample").font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                Spacer(minLength: 12)
                Button("Cancel") { finish(false) }.configuredNativeShortcut(.escape)
                Button("OK") { finish(true) }.configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .fixedSize()
        .onChange(of: hexFocused) { _, focused in if !focused { state.finishEditingHex() } }
        .onChange(of: focusedChannel) { previous, _ in
            if let previous { state.finishEditingChannel(previous) }
        }
    }

    private var saturationBrightnessField: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return ZStack {
            LinearGradient(colors: [.white, PickerHSB(hue: hsb.hue, saturation: 1, brightness: 1).rgb.swiftUI],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: fieldSize, height: fieldSize)
        // Flattened before the corners are cut: clipped one by one, each gradient's own soft edge let the white and
        // hue beneath show through the black at the bottom corners.
        .compositingGroup()
        .clipShape(shape)
        // The pointer is filled with the color it picks, ringed in white so it shows on any of them.
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(color.swiftUI)
                .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                .shadow(color: .black.opacity(0.45), radius: 1)
                .frame(width: 14, height: 14)
                .position(x: hsb.saturation * fieldSize, y: (1 - hsb.brightness) * fieldSize)
        }
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            var updated = hsb
            updated.saturation = min(1, max(0, value.location.x / fieldSize))
            updated.brightness = 1 - min(1, max(0, value.location.y / fieldSize))
            state.hsb = updated
        })
        .accessibilityLabel("Saturation and brightness")
    }

    /// The hue strip, marked by an arrow on each side rather than a knob across it, so the hue being chosen stays
    /// in view, as in Photoshop. It answers presses a little past its ends, where the arrows reach at red, so the very
    /// end is easy to hit.
    private var hueStrip: some View {
        let stripWidth: CGFloat = 14, arrow = CGSize(width: 9, height: 7), gap: CGFloat = 2, overhang: CGFloat = 6
        // Kept a little in from the strip's very ends, so at red the arrows stay alongside the color rather than
        // hanging past it.
        let markerY = min(fieldSize - 1, max(1, (1 - hsb.hue / 360) * fieldSize))
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: stride(from: 360.0, through: 0, by: -60).map {
                PickerHSB(hue: $0, saturation: 1, brightness: 1).rgb.swiftUI
            }, startPoint: .top, endPoint: .bottom)
                .frame(width: stripWidth, height: fieldSize)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(.horizontal, arrow.width + gap)
                .padding(.vertical, overhang)
            HStack(spacing: stripWidth + gap * 2) {
                HueArrow().fill(Color(white: 0.92)).frame(width: arrow.width, height: arrow.height)
                HueArrow().fill(Color(white: 0.92)).frame(width: arrow.width, height: arrow.height).scaleEffect(x: -1)
            }
            .shadow(color: .black.opacity(0.5), radius: 0.75, y: 0.5)
            .offset(y: overhang + markerY - arrow.height / 2)
        }
        .frame(width: stripWidth + (arrow.width + gap) * 2, height: fieldSize + overhang * 2)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            var updated = hsb
            updated.hue = (1 - min(1, max(0, (value.location.y - overhang) / fieldSize))) * 360
            state.hsb = updated
        })
        .padding(.vertical, -overhang)
        .accessibilityLabel("Hue")
        .accessibilityValue("\(Int(hsb.hue.rounded())) degrees")
    }

    /// The new color over the one the picker opened with; clicking the old one goes back to it, as in Photoshop.
    private var preview: some View {
        VStack(spacing: 0) {
            color.swiftUI.accessibilityLabel("New color")
            state.original.swiftUI
                .contentShape(Rectangle())
                .onTapGesture { state.pick(state.original) }
                .help("The color before: click to go back to it")
                .accessibilityLabel("Current color")
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1) }
    }

    private var fields: some View {
        _ = state.hexDraft // Observe changes even when a sample picks the same color.
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            channelRow("R", .red, accessibilityLabel: "Red")
            channelRow("G", .green, accessibilityLabel: "Green")
            channelRow("B", .blue, accessibilityLabel: "Blue")
            GridRow {
                Text("#").frame(width: 12, alignment: .leading)
                TextField("Hex", text: Binding(get: { state.hexDraft }, set: state.editHex))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 62)
                    .focused($hexFocused)
                    // A field's own submit swallows Return, so it confirms the picker itself, as OK does.
                    .onSubmit { state.finishEditingHex(); finish(true) }
                    .accessibilityLabel("Hex color")
            }
        }
    }

    private func channelRow(_ label: String, _ channel: ColorPickerState.Channel, accessibilityLabel: String) -> some View {
        _ = state.channelDraft(channel)
        let channelValue = Binding(get: { state.channelValue(channel) }, set: { state.setChannel(channel, to: $0) })
        let draft = Binding(get: { state.channelDraft(channel) }, set: { state.editChannel(channel, draft: $0) })
        return GridRow {
            Text(label).frame(width: 12, alignment: .leading)
                .scrubbable(sensitivity: 1, value: channelValue, range: 0...255)
            TextField(label, text: draft)
                .frame(width: 52)
                .focused($focusedChannel, equals: channel)
                .onSubmit { finish(true) }
                .arrowSteps(value: { Double(channelValue.wrappedValue) }, change: { state.setChannel(channel, to: Int($0.rounded())) })
                .accessibilityLabel(accessibilityLabel)
        }
    }
}

/// A small pointer aiming right: a round back tapering to a sharp tip, like a pin.
private struct HueArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.height / 2
        let center = CGPoint(x: rect.minX + radius, y: rect.midY)
        let tip = CGPoint(x: rect.maxX, y: rect.midY)
        let reach = tip.x - center.x
        guard reach > radius else { return Path(ellipseIn: rect) }
        // Where the straight sides meet the round back: tangent to it from the tip.
        let angle = acos(radius / reach)
        return Path { path in
            path.move(to: tip)
            path.addArc(center: center, radius: radius, startAngle: .radians(Double(angle)),
                        endAngle: .radians(-Double(angle)), clockwise: false)
            path.closeSubpath()
        }
    }
}

extension PaletteColor {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

/// Hosts the picker in the shared floating panel: first opened centered on the canvas,
/// afterwards wherever it was last left. Closing it with the title-bar button cancels.
///
/// One for the app, not one per view showing the palette: the tool rail can rebuild its palette (switching between one
/// column and two), and a picker opened by the old one would then be left open with nothing to close it, its OK and
/// Cancel doing nothing visible.
final class ColorPickerPanelController: NSObject {
    static let shared = ColorPickerPanelController()

    static let identifier = NSUserInterfaceItemIdentifier("colorPickerPanel")
    private let panel = FloatingPanelController(name: "colorPickerPanel")
    private weak var session: EditorSession?

    func show(_ state: ColorPickerState, session: EditorSession) {
        self.session = session
        panel.onClose = { [weak session] in
            if session?.colorPicker != nil { session?.closeColorPicker(commit: false) }
        }
        panel.show(title: state.target.title,
                   content: ColorPickerSheet(state: state) { [weak self, weak session] commit in
                       session?.closeColorPicker(commit: commit)
                       // Put away here too, not only when the palette notices the picker has gone.
                       if session?.colorPicker == nil { self?.close() }
                   })
    }

    func close() { panel.close() }

    /// Returns keyboard focus to the picker after a click on the canvas sampled a color.
    static func refocus() { FloatingPanelController.refocus(identifier) }
}

/// A dialog's color swatch: clicking it opens the app's picker on `color`, which follows the
/// working color as it moves and keeps the one chosen. `closePicker()` puts the picker away with the dialog.
struct DialogColorSwatch: View {
    let title: String
    @Binding var color: PaletteColor
    let session: EditorSession
    var body: some View {
        Button {
            session.openDialogColorPicker(title: title, color: color) { color = $0 }
        } label: {
            ColorSwatch(color: color.swiftUI)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .onChange(of: session.colorPicker?.color) { _, _ in
            if session.colorPicker?.target == .dialog(title: title) { session.previewDialogColor() }
        }
        .onDisappear { Self.closePicker(session, title: title) }
    }
    static func closePicker(_ session: EditorSession, title: String? = nil) {
        if let title, session.colorPicker?.target != .dialog(title: title) { return }
        if session.pickingForDialog { session.closeColorPicker(commit: true) }
    }
}

