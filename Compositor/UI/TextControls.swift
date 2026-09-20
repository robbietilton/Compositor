import SwiftUI
import UniformTypeIdentifiers

struct TextControls: View {
    @Bindable var session: EditorSession
    @State private var importsFont = false

    var body: some View {
        HStack(spacing: 10) {
            Text("Text").font(ToolHeaderStyle.titleFont)
            Picker("Font", selection: Binding(get: { session.textStyle.fontPostScriptName }, set: { name in
                session.updateTextStyle { $0.fontPostScriptName = name }
            })) {
                ForEach(FontLibrary.shared.availableFaces) { face in
                    Text(face.displayName).tag(face.postScriptName)
                }
            }
            .frame(width: 190).accessibilityLabel("Font")
            Button { importsFont = true } label: { Image(systemName: "plus") }
                .help("Import an OTF, TTF, or TTC font")
                .accessibilityLabel("Import font")
            numberField("Size", value: Double(session.textStyle.fontSizePoints), range: 1...2000, suffix: "pt") { value in
                session.updateTextStyle { $0.fontSizePoints = CGFloat(safe(value, fallback: 36)) }
            }
            Picker("Alignment", selection: Binding(get: { session.textStyle.alignment }, set: { value in
                session.updateTextStyle { $0.alignment = value }
            })) {
                Image(systemName: "text.alignleft").tag(LayerTextAlignment.left)
                Image(systemName: "text.aligncenter").tag(LayerTextAlignment.center)
                Image(systemName: "text.alignright").tag(LayerTextAlignment.right)
            }.pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityLabel("Alignment")
            numberField("Line", value: Double(session.textStyle.lineSpacingPoints), range: -2000...2000, suffix: "pt") { value in
                session.updateTextStyle { $0.lineSpacingPoints = CGFloat(safe(value, fallback: 0)) }
            }
            numberField("Tracking", value: Double(session.textStyle.trackingPoints), range: -2000...2000, suffix: "pt") { value in
                session.updateTextStyle { $0.trackingPoints = CGFloat(safe(value, fallback: 0)) }
            }
            ColorPicker("Color", selection: Binding(get: {
                Color(red: session.textStyle.red, green: session.textStyle.green, blue: session.textStyle.blue,
                      opacity: session.textStyle.alpha)
            }, set: { color in
                guard let value = NSColor(color).usingColorSpace(.sRGB) else { return }
                session.updateTextStyle {
                    $0.red = value.redComponent; $0.green = value.greenComponent
                    $0.blue = value.blueComponent; $0.alpha = value.alphaComponent
                }
            })).labelsHidden().accessibilityLabel("Color")
            if session.textDraft?.layout.fontIsAvailable == false {
                Label("Missing font — using Source Han Sans", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.yellow)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar()
        .disabled(session.showsBusy || session.document == nil)
        .fileImporter(isPresented: $importsFont,
            allowedContentTypes: [UTType(filenameExtension: "otf")!, UTType(filenameExtension: "ttf")!, UTType(filenameExtension: "ttc")!],
            allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let faces = try FontLibrary.shared.importFont(from: url)
                    if let face = faces.first { session.updateTextStyle { $0.fontPostScriptName = face.postScriptName } }
                } catch { session.importError = error.localizedDescription }
            }
    }

    private func numberField(_ label: String, value: Double, range: ClosedRange<Double>, suffix: String,
                             apply: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
            TextField(label, value: Binding<Double>(get: { value }, set: { apply(min(range.upperBound, max(range.lowerBound, $0))) }),
                      format: .number.precision(.fractionLength(0...2)))
                .frame(width: 52).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
            Text(suffix).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private func safe(_ value: Double, fallback: Double) -> Double { value.isFinite ? value : fallback }
}
