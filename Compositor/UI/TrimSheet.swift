import SwiftUI

struct TrimSheet: View {
    let finish: (TrimOptions?) -> Void
    @State private var basedOn: TrimBasedOn = .transparentPixels
    @State private var trimTop: Bool = true
    @State private var trimBottom: Bool = true
    @State private var trimLeft: Bool = true
    @State private var trimRight: Bool = true

    var body: some View { sheet.roundedControls() }

    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Trim").font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Based On").font(.headline)
                Picker("", selection: $basedOn) {
                    ForEach(TrimBasedOn.allCases) { option in
                        Text(localized(option.rawValue)).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Trim Away").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Toggle("Top", isOn: $trimTop)
                        Toggle("Bottom", isOn: $trimBottom)
                    }
                    GridRow {
                        Toggle("Left", isOn: $trimLeft)
                        Toggle("Right", isOn: $trimRight)
                    }
                }
            }

            Divider()

            HStack {
                Button("Cancel") { finish(nil) }
                    .configuredNativeShortcut(.escape)
                Spacer()
                Button("OK") {
                    let options = TrimOptions(
                        basedOn: basedOn,
                        top: trimTop,
                        bottom: trimBottom,
                        left: trimLeft,
                        right: trimRight
                    )
                    finish(options)
                }
                .configuredNativeShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(!trimTop && !trimBottom && !trimLeft && !trimRight)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}
