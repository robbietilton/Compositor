import SwiftUI

struct PSDConversionSheet: View {
    let request: PSDConversionRequest
    let finish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.title2.bold())
            Text(request.isReading ? "Reading the file to see what needs converting."
                 : "Compositor will convert these Photoshop features. Nothing is applied until you continue.")
                .foregroundStyle(.secondary)
            if request.isReading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading the Photoshop file…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List(request.conversions) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.layerName).font(.headline)
                        Text(item.message)
                    }.padding(.vertical, 4)
                }
                .frame(minHeight: 180)
            }
            HStack {
                Spacer()
                Button("Cancel") { finish(false) }.keyboardShortcut(.cancelAction)
                Button(request.confirmTitle) { finish(true) }.keyboardShortcut(.defaultAction)
                    .disabled(request.isReading)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .roundedControls()
    }
}

extension View {
    func psdConversionSheet(_ session: EditorSession) -> some View {
        sheet(isPresented: Binding(
            get: { session.showsConversionSheet },
            set: { if !$0 { session.finishConversion(false) } }
        )) {
            if let request = session.conversionRequest {
                PSDConversionSheet(request: request, finish: session.finishConversion)
            }
        }
    }
}
