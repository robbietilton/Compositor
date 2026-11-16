import AppKit
import Testing
@testable import Compositor

@MainActor
struct ColorPickerTests {
    /// A hex value being typed sets the color with each digit, the missing ones read as zeros.
    @Test func aHexValueBeingTypedReadsAsItStands() {
        #expect(PaletteColor(typedHex: "F") == PaletteColor(hex: "F00000"))
        #expect(PaletteColor(typedHex: "#FF8") == PaletteColor(hex: "FF8000"))
        #expect(PaletteColor(typedHex: "FF800") == PaletteColor(hex: "FF8000"))
        #expect(PaletteColor(typedHex: "12AB34") == PaletteColor(hex: "12AB34"))
        #expect(PaletteColor(typedHex: "") == nil)
        #expect(PaletteColor(typedHex: "FG") == nil)
        #expect(PaletteColor(typedHex: "1234567") == nil)
    }

    /// With a picker open, a click on the foreground or background swatch samples its color, as the canvas does.
    @Test func thePalettesSwatchesSampleIntoAnOpenPicker() throws {
        let session = EditorSession()
        session.createDocument(width: 20, height: 20)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.backgroundColor = PaletteColor(red: 0, green: 0, blue: 1)
        session.openColorPicker(background: true)
        let picker = try #require(session.colorPicker)
        session.sampleSwatchIntoColorPicker(background: false)
        #expect(picker.color == PaletteColor(red: 1, green: 0, blue: 0))
        session.sampleSwatchIntoColorPicker(background: true)
        #expect(picker.color == PaletteColor(red: 0, green: 0, blue: 1))
        // Only the picker's working color moved: the palette is as it was until OK.
        #expect(session.backgroundColor == PaletteColor(red: 0, green: 0, blue: 1))
        #expect(session.foregroundColor == PaletteColor(red: 1, green: 0, blue: 0))
    }

    @Test func hexParsesFullShorthandAndRejectsInvalid() {
        #expect(PaletteColor(hex: "#FF8000") == PaletteColor(red: 1, green: 128.0 / 255, blue: 0))
        #expect(PaletteColor(hex: "0f0") == PaletteColor(red: 0, green: 1, blue: 0))
        #expect(PaletteColor(hex: " 00ff00 ") == PaletteColor(red: 0, green: 1, blue: 0))
        #expect(PaletteColor(hex: "12345") == nil)
        #expect(PaletteColor(hex: "GGGGGG") == nil)
        #expect(PaletteColor(red: 1, green: 128.0 / 255, blue: 0).hex == "FF8000")
    }

    @Test func hsbRoundTripsEightBitColors() {
        for hex in ["000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FF8000", "7F3FA2", "123456"] {
            let color = PaletteColor(hex: hex)!
            #expect(PickerHSB(color).rgb.quantized.hex == hex)
        }
    }

    @Test func graysAndBlackKeepPreviousHueAndSaturation() {
        var hsb = PickerHSB(PaletteColor(hex: "FF8000")!)
        let hue = hsb.hue
        hsb.setRGB(PaletteColor(hex: "808080")!)
        #expect(hsb.hue == hue && hsb.saturation == 0)
        hsb.saturation = 0.5
        hsb.setRGB(.black)
        #expect(hsb.hue == hue && hsb.saturation == 0.5 && hsb.brightness == 0)
    }

    @Test func canvasSamplingReadsCompositeAndCommitsOnlyOnOK() throws {
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 2, width: 4, height: 2))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Split"))

        #expect(session.sampleCompositeColor(at: CGPoint(x: 1.5, y: 0.5))?.hex == "FF0000")
        #expect(session.sampleCompositeColor(at: CGPoint(x: 1.5, y: 3.5))?.hex == "0000FF")
        #expect(session.sampleCompositeColor(at: CGPoint(x: -1, y: 1)) == nil)

        session.openColorPicker(background: false)
        session.sampleIntoColorPicker(at: CGPoint(x: 2, y: 3))
        #expect(session.colorPicker?.color.hex == "0000FF")
        #expect(session.foregroundColor == .black)
        session.closeColorPicker(commit: false)
        #expect(session.foregroundColor == .black && session.colorPicker == nil)

        session.openColorPicker(background: true)
        session.sampleIntoColorPicker(at: CGPoint(x: 2, y: 0))
        session.closeColorPicker(commit: true)
        #expect(session.backgroundColor.hex == "FF0000" && session.foregroundColor == .black)
    }

    @Test func pickerReopensWhereItWasLastLeft() throws {
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        let controller = ColorPickerPanelController()
        session.openColorPicker(background: false)
        controller.show(try #require(session.colorPicker), session: session)
        let panel = try #require(NSApp.windows.first { $0.identifier == ColorPickerPanelController.identifier && $0.isVisible })
        let screen = try #require(panel.screen ?? NSScreen.main).visibleFrame
        let spot = NSPoint(x: screen.minX + 40, y: screen.maxY - 40)
        panel.setFrameTopLeftPoint(spot)
        session.closeColorPicker(commit: false)
        controller.close()
        #expect(!panel.isVisible)
        session.openColorPicker(background: true)
        controller.show(try #require(session.colorPicker), session: session)
        #expect(NSPoint(x: panel.frame.minX, y: panel.frame.maxY) == spot)
        // Switching swatches while it is open keeps it in place too.
        session.openColorPicker(background: false)
        controller.show(try #require(session.colorPicker), session: session)
        #expect(NSPoint(x: panel.frame.minX, y: panel.frame.maxY) == spot)
        session.closeColorPicker(commit: false)
        controller.close()
    }
}
