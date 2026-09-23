import SwiftUI
import AppKit

struct ColorPaletteControls: View {
    let session: EditorSession
    @State private var choosingMaskBackground: Bool?
    @State private var pickerPanel = ColorPickerPanelController()
    private let swatchSize: CGFloat = 24
    private let swatchOffset: CGFloat = 12
    var body: some View {
        ZStack(alignment: .topLeading) {
            swatch(background: true).offset(x: swatchOffset, y: swatchOffset)
            swatch(background: false)
            Button { session.swapPaletteColors() } label: {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9, weight: .medium))
                    .rotationEffect(.degrees(45))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .offset(x: swatchSize + 3, y: -3)
            .help("Swap foreground and background (X)")
            .accessibilityLabel("Swap colors")
            Button { session.resetPaletteColors() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 7.5, weight: .medium))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .offset(x: -1, y: swatchSize + 3)
            .help("Default colors (D)")
            .accessibilityLabel("Default colors")
        }
        .frame(width: swatchSize + swatchOffset, height: swatchSize + swatchOffset, alignment: .topLeading)
        .disabled(!session.canEditPalette)
        .popover(isPresented: Binding(get: { choosingMaskBackground != nil }, set: { if !$0 { choosingMaskBackground = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text(choosingMaskBackground == true ? "Mask background" : "Mask foreground").font(.headline)
                HStack {
                    Button("Black · Hide") { chooseMask(.black) }
                    Button("White · Reveal") { chooseMask(.white) }
                }
            }.padding(16)
        }
        .onChange(of: session.colorPicker.map(ObjectIdentifier.init)) { _, _ in
            if let picker = session.colorPicker { pickerPanel.show(picker, session: session) }
            else { pickerPanel.close() }
        }
        .onChange(of: session.isMaskSelected) { _, masked in
            choosingMaskBackground = nil
            if masked { session.closeColorPicker(commit: false) }
        }
    }
    private func swatch(background: Bool) -> some View {
        let label = L10n.text(background ? "Background color" : "Foreground color")
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button {
            if session.isMaskSelected { choosingMaskBackground = background }
            else { session.openColorPicker(background: background) }
        } label: {
            shape
                .fill(Color(nsColor: session.paletteColor(background: background).nsColor))
                .overlay { shape.inset(by: 1).strokeBorder(.white, lineWidth: 1.5) }
                .overlay { shape.strokeBorder(.black, lineWidth: 1) }
                .frame(width: swatchSize, height: swatchSize)
                .contentShape(shape)
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    private func chooseMask(_ color: PaletteColor) {
        guard let background = choosingMaskBackground else { return }
        session.setPaletteColor(color, background: background)
        choosingMaskBackground = nil
    }
}
