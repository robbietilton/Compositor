import SwiftUI
import AppKit
import ImageIO

struct NewCanvasSheet: View {
    let session: EditorSession
    var onCreate: ((Int, Int) -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    var onClipboard: (() -> Void)? = nil
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
            Text(valid ? "Transparent canvas · sRGB" : "Enter whole numbers from 1 to 30,000 pixels.")
                .font(.callout).foregroundStyle(valid ? Color.secondary : Color.orange)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button("Open project") { onOpen?() }.buttonStyle(.bordered)
                    Button("Import image") { session.showsImporter = true }.buttonStyle(.bordered)
                    Spacer()
                }
                HStack(spacing: 10) {
                    Button("Open from clipboard") {
                        if let onClipboard {
                            onClipboard()
                        } else if let image = session.clipboardImage() ?? EditorSession.clipboardImage() {
                            session.createDocument(with: image)
                        } else {
                            NSSound.beep()
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("openFromClipboard")
                    Spacer()
                    Button("Create canvas") {
                        guard let w = CanvasDocument.validDimension(width),
                              let h = CanvasDocument.validDimension(height) else { return }
                        if let onCreate { onCreate(w, h) }
                        else { session.createDocument(width: w, height: h, emptyLayer: true) }
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!valid).accessibilityIdentifier("createCanvas")
                }
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
        guard let image = EditorSession.clipboardImage(pasteboard) else { return nil }
        guard CanvasDocument.validDimension(String(image.width)) != nil,
              CanvasDocument.validDimension(String(image.height)) != nil else { return nil }
        return (image.width, image.height)
    }
    private func dimension(_ title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium))
            HStack {
                TextField(title, text: text).textFieldStyle(.plain)
                    .focused($focusedField, equals: field)
                    .accessibilityIdentifier(title.lowercased() + "Input")
                Text("px").foregroundStyle(.secondary)
            }
            .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
