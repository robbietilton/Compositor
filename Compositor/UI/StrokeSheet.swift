import SwiftUI

/// Edit › Stroke…: a line along the selection's outline, in the foreground or background color.
struct StrokeSheet: View {
    let finish: (StrokeOptions?) -> Void
    @State private var options: StrokeOptions
    @State private var input: String
    @FocusState private var focused: Bool

    init(options: StrokeOptions, finish: @escaping (StrokeOptions?) -> Void) {
        self.finish = finish
        _options = State(initialValue: options)
        _input = State(initialValue: String(Int(options.width)))
    }

    private var maximum: Int { Int(StrokeOptions.widthRange.upperBound) }
    private var width: Int? {
        guard let value = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...maximum).contains(value) else { return nil }
        return value
    }

    var body: some View { sheet.roundedControls() }

    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stroke").font(.title2.bold())
            HStack(spacing: 10) {
                Text("Width").frame(minWidth: 60, alignment: .leading)
                    .scrubbable(sensitivity: 1, value: Binding<Int>(get: { width ?? 1 }, set: { input = String($0) }),
                                range: 1...maximum)
                Slider(value: Binding(get: { Double(width ?? 1) }, set: { input = String(Int($0.rounded())) }),
                       in: 1...Double(maximum), step: 1)
                TextField("Width", text: $input)
                    .frame(width: 56).textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing).focused($focused)
                    .unitSuffix("px")
            }
            HStack(spacing: 10) {
                Text("Color").frame(minWidth: 60, alignment: .leading)
                Picker("", selection: $options.source) {
                    Text("Foreground").tag(EditorSession.FillSource.foreground)
                    Text("Background").tag(EditorSession.FillSource.background)
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            HStack(spacing: 10) {
                Text("Location").frame(minWidth: 60, alignment: .leading)
                Picker("", selection: $options.location) {
                    ForEach(StrokeLocation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            HStack(spacing: 10) {
                Text("Opacity").frame(minWidth: 60, alignment: .leading)
                    .scrubbable(sensitivity: 1, value: Binding<Int>(get: { Int((options.opacity * 100).rounded()) },
                                                                    set: { options.opacity = Double($0) / 100 }),
                                range: 1...100)
                Slider(value: $options.opacity, in: 0.01...1)
                Text("\(Int((options.opacity * 100).rounded()))%")
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            Text("Enter a whole number from 1 to \(maximum) px.")
                .font(.callout).foregroundStyle(.secondary)
                .opacity(width == nil ? 1 : 0)
            Divider()
            HStack {
                Button("Cancel") { finish(nil) }
                    .configuredNativeShortcut(.escape)
                Spacer()
                Button("OK") {
                    guard let width else { return }
                    var result = options
                    result.width = Double(width)
                    finish(result)
                }
                .configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
                .disabled(width == nil)
            }
        }
        .padding(24).frame(width: 400).fixedSize()
        .onAppear { focused = true }
    }
}