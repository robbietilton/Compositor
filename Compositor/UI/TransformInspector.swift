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
          // Command flips Auto Select while it's held, and the box shows it flipped (see HeldModifiers).
          Toggle("Auto Select", isOn: Binding(get: { session.transformAutoSelect != held.contains(.command) },
                                              set: { session.transformAutoSelect = $0 != held.contains(.command) }))
              .help("Select layers by clicking the canvas. Hold Command to turn it the other way while you click.")
              .accessibilityIdentifier("transformAutoSelect")
          Toggle("Show Controls", isOn: $session.showsTransformControls)
              .help("Show the transform box and handles (⌘H). When hidden, drag anywhere to move the layer.")
          ScrollView(.horizontal) {
            HStack(spacing: 12) {
            HStack(spacing: 12) {
                field("X", value: value.origin.x) { $0.origin.x = $1 }.fixedSize()
                field("Y", value: value.origin.y) { $0.origin.y = $1 }.fixedSize()
                TransformValueField(label: "W", fieldWidth: Self.longField, value: value.size.width, range: 1...30_000, finish: finish) { resize($0, width: true) }.fixedSize()
                TransformValueField(label: "H", fieldWidth: Self.longField, value: value.size.height, range: 1...30_000, finish: finish) { resize($0, width: false) }.fixedSize()
                // Shift flips the lock while dragging a handle, and the button shows it flipped.
                Toggle(isOn: Binding(get: { session.locksTransformRatio != held.contains(.shift) },
                                     set: { session.locksTransformRatio = $0 != held.contains(.shift) })) { Image(systemName: "link") }
                    .toggleStyle(.button).help("Lock aspect ratio. Hold Shift while dragging a handle to turn it the other way.")
                TransformValueField(label: "Scale", suffix: "%", fieldWidth: Self.shortField, value: value.scalePercent(pixelSize: pixelSize), range: 0.1...30_000, finish: finish) { number in
                    change { value in
                        guard number > 0 else { return }
                        value = value.scaled(toPercent: number, pixelSize: pixelSize)
                    }
                }.fixedSize().help("Scale width and height together, about the center")
                TransformValueField(label: "°", fieldWidth: Self.shortField, value: value.rotation, range: -360...360, finish: finish) { number in
                    change { $0.rotation = number.truncatingRemainder(dividingBy: 360) }
                }.fixedSize()
                Picker("Sampling", selection: Binding(get: { value.sampling }, set: { sampling in
                    change { $0.sampling = sampling }
                })) {
                    ForEach(LayerSampling.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 170)
                Button { change { $0.flipX.toggle() } } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip Horizontal").accessibilityLabel("Flip Horizontal")
                Button { change { $0.flipY.toggle() } } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .help("Flip Vertical").accessibilityLabel("Flip Vertical")
                Divider().frame(height: 16)

            // Numbers describe an ordinary transform; while distorted, the handles are the controls.
            }.disabled((!session.canTransform && session.transformEdit == nil) || session.transformEdit?.corners != nil)
            // Outside the group the numbers are disabled with, so a move in progress leaves it alone.
            AlignButton(session: session)
            }
                .padding(.horizontal, 18)
          }.scrollIndicators(.never)
          // Only an edit that waits for them — typed values, ⌘T, a distortion — has anything to cancel or apply. A
          // handle drag applies itself on release, and ghosted buttons after it read as the pixels being resampled,
          // which they never are. Left in place unseen, so Escape and Return still reach a drag in progress.
          let pending = session.transformEdit?.persistent == true
          HStack(spacing: 12) {
              Button("Cancel") { session.cancelTransform() }.configuredNativeShortcut(.escape)
                  .disabled(session.transformEdit == nil)
              Button("Apply") { session.commitTransform() }.configuredNativeShortcut(.return)
                  .disabled(session.transformEdit == nil).accessibilityIdentifier("applyTransform")
          }
          .opacity(pending ? 1 : 0).allowsHitTesting(pending).accessibilityHidden(!pending)
          .animation(.easeOut(duration: 0.12), value: pending)
        }.padding(.trailing, 18).toolHeaderBar().releasesFocusOnCommit(session)
    }

    /// 100% scale: the layer's pixels (a blank layer's size before this edit, so typing doesn't compound).
    private var held: NSEvent.ModifierFlags { HeldModifiers.shared.flags }
    private var pixelSize: CGSize { session.transformPixelSize ?? session.activeLayer?.size ?? value.size }
    /// Room for four digits, for Scale and rotation, and six and a half for position and size, which run to five and a
    /// sign or a decimal: 7.6 points a digit at the bar's 12-point text, and 8 for a field border's padding.
    static let shortField: CGFloat = 38
    static let longField: CGFloat = 57

    private func field(_ label: String, value: CGFloat, range: ClosedRange<CGFloat> = -30_000...30_000,
                       set: @escaping (inout LayerTransform, CGFloat) -> Void) -> some View {
        TransformValueField(label: label, fieldWidth: Self.longField, value: value, range: range, finish: finish) { number in change { set(&$0, number) } }
    }
    /// A value typed, stepped or dragged shows on the canvas as it changes, and is applied without Cancel or Apply —
    /// a transform never resamples the layer's pixels, so there is nothing to confirm — as one undo step once the
    /// field is done with it (see `finish`), as a handle drag is when it's let go. An edit already waiting for Apply —
    /// ⌘T, a distortion, selected pixels being transformed — takes it as part of that edit.
    private func change(_ update: (inout LayerTransform) -> Void) {
        if session.transformEdit == nil {
            session.beginTransform(persistent: false)
            session.transformEdit?.fromFields = true
        }
        guard var value = session.transformEdit?.draft else { return }
        update(&value)
        session.previewTransform(value)
    }
    /// A field done with its value — a drag on its label let go, or the field left (Return, Tab, a click elsewhere):
    /// what the fields changed is applied, one undo step.
    private func finish() {
        if session.transformEdit?.fromFields == true { session.commitTransform() }
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

struct TransformValueField: View {
    let label: String
    var suffix: String? = nil
    /// The text box's own width, when it's narrower than the space it's given: Scale and rotation take four digits.
    var fieldWidth: CGFloat? = nil
    let value: CGFloat
    let range: ClosedRange<CGFloat>
    /// The field is done with its value: a drag on its label let go, or the field left.
    let finish: () -> Void
    let change: (CGFloat) -> Void
    @State private var text = ""
    @State private var stepper = ArrowStepper()
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .scrubbable(sensitivity: 1, value: Binding(get: { value }, set: { newValue in
                    change(newValue)
                    text = Self.formatted(Double(newValue))
                }), range: range, step: 1, onEnd: finish)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder).focused($focused)
                .frame(width: fieldWidth)
                .accessibilityIdentifier("transform\(label)")
                .onAppear { sync() }
                .onChange(of: value) { if !focused { sync() } }
                .onChange(of: focused) { if !focused { finish(); sync() } }
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

/// The Move bar's Align button: a small panel of icons, horizontal on one row and vertical on the next, each aligning
/// three ways and distributing two. Layers line up with
/// the selection, with the canvas when one layer is selected, or else with each other; distributing takes three or more.
private struct AlignButton: View {
    @Bindable var session: EditorSession
    @State private var showing = false

    var body: some View {
        Button("Align") { showing.toggle() }
            .disabled(!session.canAlignLayers)
            .help("Line layers up with each other, the selection, or the canvas when one is selected")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                // Horizontal on the top row, vertical below: align three ways, then distribute two.
                VStack(alignment: .leading, spacing: 6) {
                    row([.left, .horizontalCenter, .right], [.horizontalCenters, .horizontalSpacing])
                    row([.top, .verticalCenter, .bottom], [.verticalCenters, .verticalSpacing])
                    Divider()
                    Button("Auto-Align") {
                        showing = false
                        Task { await session.autoAlignLayers() }
                    }
                    .disabled(!session.canAutoAlignLayers)
                    .help("Match the selected photos to the active layer by what's in them (two or more pixel layers)")
                }
                .padding(8)
            }
    }

    private func row(_ alignments: [LayerAlignment], _ distributions: [LayerDistribution]) -> some View {
        HStack(spacing: 2) {
            ForEach(alignments, id: \.self) { alignment in
                icon(alignment.symbol, "Align " + alignment.rawValue) { session.alignLayers(alignment) }
            }
            ForEach(distributions, id: \.self) { distribution in
                icon(distribution.symbol, "Distribute " + distribution.rawValue + " (three or more layers)") {
                    session.distributeLayers(distribution)
                }
                .disabled(!session.canDistributeLayers)
            }
        }
    }

    private func icon(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}
