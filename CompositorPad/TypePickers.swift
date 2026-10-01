import UIKit

/// The Type bar's font and text color, chosen with the system's pickers and applied as the Mac's Type bar applies its
/// font menu and color picker: to the letters selected while text is typed, or to all of it.
final class TypePickers: NSObject, UIFontPickerViewControllerDelegate, UIColorPickerViewControllerDelegate {
    /// The session in front, which a choice applies to.
    var session: () -> EditorSession? = { nil }
    /// Gives the keys back to the text being typed once a picker is done.
    var returnFocus: () -> Void = {}

    func chooseFont(from source: UIView, presenter: UIViewController) {
        guard let session = session() else { return }
        let configuration = UIFontPickerViewController.Configuration()
        // Each family's faces too, bold, italic and the rest, as the Mac's font menu lists them.
        configuration.includeFaces = true
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = self
        if let font = UIFont(name: session.currentTextStyle.fontName, size: 17) { picker.selectedFontDescriptor = font.fontDescriptor }
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = source
        presenter.present(picker, animated: true)
    }

    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        defer {
            viewController.dismiss(animated: true)
            returnFocus()
        }
        guard let session = session(), let descriptor = viewController.selectedFontDescriptor else { return }
        let name = UIFont(descriptor: descriptor, size: 17).fontName
        let selection = session.textDraft?.selection ?? NSRange()
        session.changeTextStyle { $0.setFont(name, in: selection) }
    }

    func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) { returnFocus() }

    func chooseTextColor(from source: UIView, presenter: UIViewController) {
        guard let session = session() else { return }
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        let color = session.typeColor
        picker.selectedColor = UIColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        picker.delegate = self
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = source
        presenter.present(picker, animated: true)
    }

    /// The letters selected take the color as it's picked, or all of them; with no text being typed, the next text
    /// will. The foreground color follows, as on the Mac.
    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard let session = session(),
              let sRGB = color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = sRGB.components, c.count >= 3 else { return }
        let picked = PaletteColor(red: min(1, max(0, c[0])), green: min(1, max(0, c[1])), blue: min(1, max(0, c[2])))
        if session.textDraft != nil {
            session.setDraftTextColor(picked)
        } else {
            session.textDefaults.red = picked.red
            session.textDefaults.green = picked.green
            session.textDefaults.blue = picked.blue
        }
        if !session.isMaskSelected { session.foregroundColor = picked }
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) { returnFocus() }
}
