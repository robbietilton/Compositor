import SwiftUI
import AppKit
import ImageIO

struct NewCanvasSheet: View {
    let session: EditorSession
    var onCreate: ((Int, Int) -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    @State private var width = "1920"
    @State private var height = "1080"
    @State private var suggestedClipboardSize = false
    @FocusState private var focusedField: Field?
    private enum Field { case width, height }
    private var valid: Bool {
        CanvasDocument.validDimension(width) != nil && CanvasDocument.validDimension(height) != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New canvas").font(.title2.weight(.semibold))
                Text("A blank space for your next composition.").foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                dimension("Width", text: $width, field: .width)
                Image(systemName: "multiply").foregroundStyle(.tertiary).padding(.top, 20)
                dimension("Height", text: $height, field: .height)
            }
            Group {
                if valid {
                    Text("Transparent canvas · sRGB")
                        .foregroundStyle(Color.secondary)
                } else {
                    Text("Enter whole numbers from 1 to \(DocumentLimits.maxSide) pixels.")
                        .foregroundStyle(Color.orange)
                }
            }
            .font(.callout)
            HStack(spacing: 10) {
                Button("Open project") { onOpen?() }.buttonStyle(.bordered)
                Button("Import image") { session.showsImporter = true }.buttonStyle(.bordered)
                Spacer()
                Button("Create canvas") {
                    guard let w = CanvasDocument.validDimension(width),
                          let h = CanvasDocument.validDimension(height) else { return }
                    if let onCreate { onCreate(w, h) }
                    else { session.createDocument(width: w, height: h, emptyLayer: true) }
                }
                .configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
                .disabled(!valid).accessibilityIdentifier("createCanvas")
            }
        }
        .padding(28).frame(maxWidth: 500)
        .disabled(session.isImporting || session.showsBusy)
        .onAppear {
            if !suggestedClipboardSize {
                suggestedClipboardSize = true
                if session.skipsInitialClipboardCanvasSize {
                    session.skipsInitialClipboardCanvasSize = false
                } else if let size = Self.clipboardDimensions() {
                    width = String(size.width)
                    height = String(size.height)
                }
            }
            focusedField = .width
        }
    }
    static func clipboardDimensions(_ pasteboard: NSPasteboard = .general) -> (width: Int, height: Int)? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  var width = properties[kCGImagePropertyPixelWidth] as? Int,
                  var height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
                swap(&width, &height)
            }
            guard CanvasDocument.validDimension(String(width)) != nil,
                  CanvasDocument.validDimension(String(height)) != nil else { continue }
            return (width, height)
        }
        return nil
    }
    private func dimension(_ title: LocalizedStringKey, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium))
            HStack {
                TextField(title, text: text).textFieldStyle(.plain)
                    .focused($focusedField, equals: field)
                    .accessibilityIdentifier(field == .width ? "widthInput" : "heightInput")
                Text("px").foregroundStyle(.secondary)
            }
            .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
