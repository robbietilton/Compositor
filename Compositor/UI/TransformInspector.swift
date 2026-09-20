import SwiftUI

struct TransformInspector: View {
    @Bindable var session: EditorSession
    private var value: LayerTransform {
        session.transformEdit?.draft ?? session.activeLayer.map { session.editedTransform(for: $0) }
            ?? LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1))
    }
    var body: some View {
        HStack(spacing: 12) {
          Text(session.transformTargetsMask ? "Transform Mask" : "Transform").font(ToolHeaderStyle.titleFont)
              .padding(.leading, 18)
          Toggle("Auto Select", isOn: $session.transformAutoSelect)
              .help("Select layers by clicking the canvas. When off, hold Command to select a layer.")
              .accessibilityIdentifier("transformAutoSelect")
          Toggle("Show Controls", isOn: $session.showsTransformControls)
              .help("Show the transform box and handles (⌘H). When hidden, drag anywhere to move the layer.")
          ScrollView(.horizontal) {
            HStack(spacing: 12) {
                field("X", value: value.origin.x) { $0.origin.x = $1 }.frame(width: 85)
                field("Y", value: value.origin.y) { $0.origin.y = $1 }.frame(width: 85)
                TransformValueField(label: "W", value: value.size.width) { resize($0, width: true) }.frame(width: 85)
                TransformValueField(label: "H", value: value.size.height) { resize($0, width: false) }.frame(width: 85)
                Toggle(isOn: $session.locksTransformRatio) { Image(systemName: "link") }
                    .toggleStyle(.button).help("Lock aspect ratio")
                TransformValueField(label: "Scale", suffix: "%", value: value.scalePercent(pixelSize: pixelSize)) { number in
                    change { value in
                        guard number > 0 else { return }
                        value = value.scaled(toPercent: number, pixelSize: pixelSize)
                    }
                }.frame(width: 110).help("Scale width and height together, about the center")
                field("°", value: value.rotation) { $0.rotation = $1.truncatingRemainder(dividingBy: 360) }.frame(width: 75)
                Picker("Sampling", selection: Binding(get: { value.sampling }, set: { sampling in
                    change { $0.sampling = sampling }
                })) {
                    ForEach(LayerSampling.allCases, id: \.self) { Text(verbatim: $0.localizedName).tag($0) }
                }.frame(width: 170)
                Button("Flip H") { change { $0.flipX.toggle() } }
                Button("Flip V") { change { $0.flipY.toggle() } }

            // Numbers describe an ordinary transform; while distorted, the handles are the controls.
            }.disabled((!session.canTransform && session.transformEdit == nil) || session.transformEdit?.corners != nil)
                .padding(.horizontal, 18)
          }.scrollIndicators(.hidden)
          Button("Cancel") { session.cancelTransform() }.configuredNativeShortcut(.escape)
              .disabled(session.transformEdit == nil)
          Button("Apply") { session.commitTransform() }.configuredNativeShortcut(.return)
              .disabled(session.transformEdit == nil).accessibilityIdentifier("applyTransform")
        }.padding(.trailing, 18).toolHeaderBar().releasesFocusOnCommit(session)
    }

    /// 100% scale: the layer's pixels (a blank layer's size before this edit, so typing doesn't compound).
    private var pixelSize: CGSize { session.transformPixelSize ?? session.activeLayer?.size ?? value.size }
    private func field(_ label: String, value: CGFloat, set: @escaping (inout LayerTransform, CGFloat) -> Void) -> some View {
        TransformValueField(label: label, value: value) { number in change { set(&$0, number) } }
    }
    private func change(_ update: (inout LayerTransform) -> Void) {
        if session.transformEdit == nil { session.beginTransform() }
        guard var value = session.transformEdit?.draft else { return }
        update(&value)
        session.previewTransform(value)
    }
    private func resize(_ number: CGFloat, width: Bool) {
        change { value in
            guard number >= 1 else { return }
            if width {
                if session.locksTransformRatio { value.size.height *= number / value.size.width }
                value.size.width = number
            } else {
                if session.locksTransformRatio { value.size.width *= number / value.size.height }
                value.size.height = number
            }
        }
    }
}

private struct TransformValueField: View {
    let label: String
    var suffix: String? = nil
    let value: CGFloat
    let change: (CGFloat) -> Void
    @State private var text = ""
    @State private var stepper = ArrowStepper()
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("transform\(label)")
                .onAppear { sync() }
                .onChange(of: value) { if !focused { sync() } }
                .onChange(of: focused) { if !focused { sync() } }
                .onChange(of: text) {
                    if focused, let number = Double(text), number.isFinite { change(CGFloat(number)) }
                }
                // The field holds off syncing while it has focus, so as not to fight what is being typed; a step
                // is not typing, so it writes the number it applied.
                .arrowSteps(editing: focused, stepper: stepper, value: { Double(value) },
                            change: { stepped in
                                change(CGFloat(stepped))
                                text = Self.formatted(stepped)
                            })
            if let suffix { Text(suffix).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func sync() { text = Self.formatted(Double(value)) }
    /// No trailing zeros on a whole number, two decimals otherwise.
    static func formatted(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.005 ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }
}
