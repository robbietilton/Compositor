import SwiftUI

/// The Crop tool's header. A view of its own because dragging the crop frame changes `cropRect` on
/// every mouse move: read here, only this bar re-renders, not the whole editor and its Layers panel.
struct CropControls: View {
    @Bindable var session: EditorSession
    @State private var showsCustomRatio = false
    @State private var customRatio = "9:20"
    private let ratios = ["Free", "Original", "1:1", "4:3", "3:4", "16:9", "9:16", "9:20"]

    var body: some View {
        HStack(spacing: 14) {
            Text("Crop").font(ToolHeaderStyle.titleFont)
            Picker("Ratio", selection: ratioSelection) {
                ForEach(ratios, id: \.self) { Text($0) }
                if !ratios.contains(session.cropRatioChoice) {
                    Text(session.cropRatioChoice).tag(session.cropRatioChoice)
                }
                Divider()
                Text("Custom…").tag("Custom")
            }.frame(width: 170)
                .popover(isPresented: $showsCustomRatio) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Custom ratio").font(.headline)
                        TextField("Width:Height", text: $customRatio)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { applyCustomRatio() }
                        Text("Width:height, such as 9:20 or 2.5:1")
                            .font(.caption).foregroundStyle(.secondary)
                        if CropGeometry.ratio(customRatio) == nil {
                            Text("Enter a positive ratio within the document size limits.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button("Cancel") { showsCustomRatio = false }
                            Spacer()
                            Button("Apply") { applyCustomRatio() }
                                .disabled(CropGeometry.ratio(customRatio) == nil)
                        }
                    }.padding(16).frame(width: 280)
                }
            if let rect = session.cropRect {
                Text("\(Int(rect.width)) × \(Int(rect.height)) px").monospacedDigit()
            }
            Spacer()
            Button("Cancel") { session.cancelCrop() }.disabled(session.cropRect == nil)
            Button("Apply Crop") { Task { await session.commitCrop() } }
                .disabled(session.cropRect == nil)
        }.padding(.horizontal, 18).toolHeaderBar().disabled(session.showsBusy || session.document == nil)
    }

    private var ratioSelection: Binding<String> {
        Binding(get: { session.cropRatioChoice }, set: { choice in
            if choice == "Custom" {
                if CropGeometry.ratio(session.cropRatioChoice) != nil { customRatio = session.cropRatioChoice }
                showsCustomRatio = true
            } else {
                session.cropRatioChoice = choice
                session.changeCropRatio()
            }
        })
    }

    private func applyCustomRatio() {
        guard CropGeometry.ratio(customRatio) != nil else { return }
        session.cropRatioChoice = customRatio.split(separator: ":").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        }.joined(separator: ":")
        session.changeCropRatio()
        showsCustomRatio = false
    }
}
