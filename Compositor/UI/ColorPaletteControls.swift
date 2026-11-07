import SwiftUI
import AppKit

/// A color to click on, drawn the same everywhere. The thin outline keeps a color that matches what's behind it, such
/// as black, visible.
struct ColorSwatch: View {
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        shape.fill(color)
            .overlay { shape.strokeBorder(.white.opacity(0.26), lineWidth: 1) }
            .frame(width: size, height: size)
            .contentShape(shape)
    }
}

/// A square split into black and white, the colors that Reset goes back to.
private struct DefaultColorsIcon: View {
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .white, location: 0.5)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(0.5), lineWidth: 0.75) }
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct ColorPaletteControls: View {
    let session: EditorSession
    @State private var choosingMaskBackground: Bool?
    private var pickerPanel: ColorPickerPanelController { .shared }
    private let swatchSize = CGSize(width: 24, height: 24)
    private let swatchOffset = CGSize(width: 12, height: 12)
    var body: some View {
        // The buttons' click areas reach well past their small icons, so the gaps here are tight to make up for it.
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                swatch(background: true).offset(swatchOffset)
                swatch(background: false)
                    // A gap in the color behind, so the foreground reads as sitting on top of it.
                    .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black).padding(-2).blendMode(.destinationOut) }
            }
            .compositingGroup()
            .frame(width: swatchSize.width + swatchOffset.width, height: swatchSize.height + swatchOffset.height, alignment: .topLeading)
            HStack(spacing: 2) {
                Button { session.resetPaletteColors() } label: {
                    DefaultColorsIcon()
                        .frame(width: 8, height: 8)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reset colors to black and white (D)")
                .accessibilityLabel("Reset colors")
                Button { session.swapPaletteColors() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .regular))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Swap foreground and background (X)")
                .accessibilityLabel("Swap colors")
            }
        }
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
        let label = background ? "Background color" : "Foreground color"
        return Button {
            if session.isMaskSelected { choosingMaskBackground = background }
            else { session.openColorPicker(background: background) }
        } label: {
            ColorSwatch(color: Color(nsColor: session.paletteColor(background: background).nsColor), size: 24)
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    private func chooseMask(_ color: PaletteColor) {
        guard let background = choosingMaskBackground else { return }
        session.setPaletteColor(color, background: background)
        choosingMaskBackground = nil
    }
}
