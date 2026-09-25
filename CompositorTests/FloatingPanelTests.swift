import AppKit
import SwiftUI
import Testing
@testable import Compositor

/// Serialized: these show real panels and run a display pass.
@MainActor @Suite(.serialized)
struct FloatingPanelTests {
    private func sessionWithPixels() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        return session
    }
    /// Lets AppKit run its constraint/display pass, which is where hosting used to crash.
    private func activateTestHost() { NSApp.activate(ignoringOtherApps: true) }
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }

    /// Cmd+U used to crash here: `.preferredContentSize` sizing made AppKit measure the
    /// SwiftUI view during its constraint pass, and the measurement invalidated layout
    /// re-entrantly, which AppKit turns into a fatal exception.
    @Test func hueSaturationPanelSurvivesALayoutPass() async throws {
        activateTestHost()
        let session = try sessionWithPixels()
        session.beginHueSaturation()
        #expect(session.hueSaturation != nil)
        let panel = FloatingPanelController(name: "testHueSaturationPanel")
        panel.show(title: "Hue/Saturation", content: HueSaturationSheet(session: session))
        settle()
        #expect(panel.isVisible)
        // Previewing while the panel is hosted must also survive a display pass.
        session.updateHueSaturation(HueSaturationSettings(hue: 40), preview: true)
        await session.hueSaturationTask?.value
        settle()
        panel.close()
        session.cancelHueSaturation()
        #expect(!panel.isVisible && session.hueSaturation == nil)
    }

    @Test func colorPickerPanelSurvivesALayoutPass() throws {
        let session = try sessionWithPixels()
        session.openColorPicker(background: false)
        let controller = ColorPickerPanelController()
        controller.show(try #require(session.colorPicker), session: session)
        settle()
        let panel = try #require(NSApp.windows.first { $0.identifier == ColorPickerPanelController.identifier })
        #expect(panel.isVisible && panel.contentView != nil)
        controller.close()
        session.closeColorPicker(commit: false)
    }
    // Invert has no settings and so no editor; it is covered on its own.
    @Test(arguments: AdjustmentKind.allCases.filter(\.isEditable))
    func adjustmentEditorsUseMovableNonmodalPanels(_ kind: AdjustmentKind) async throws {
        activateTestHost()
        let session = try sessionWithPixels()
        session.addAdjustment(kind)
        await session.beginAdjustmentEditing(try #require(session.adjustmentEditingID))
        let controller = FloatingPanelController(name: "testDynamicAdjustmentPanel-\(kind.rawValue)")
        controller.onClose = { session.finishAdjustmentEditing(commit: false) }
        switch kind {
        case .levels: controller.show(title: "Levels", content: LevelsSheet(session: session))
        case .hsv: controller.show(title: "Hue/Saturation", content: HueSaturationSheet(session: session))
        case .curves, .exposure, .gradientMap, .grain, .blackWhite, .colorBalance, .gaussianBlur, .motionBlur, .addNoise:
            controller.show(title: kind.rawValue, content: FilterSheet(session: session))
        case .invert: return   // filtered out above: no editor, so no panel to test
        }
        settle()
        let panel = try #require(NSApp.windows.first { $0.identifier == controller.identifier })
        #expect(panel.isVisible && panel.isMovable && !panel.isSheet)
        #expect(panel.sheetParent == nil && !session.showsBusy)
        let origin = panel.frame.origin
        panel.setFrameOrigin(NSPoint(x: origin.x + 20, y: origin.y + 20))
        #expect(panel.frame.origin != origin)
        panel.performClose(nil)
        #expect(session.adjustmentEditingID == nil)
        #expect(session.levels == nil && session.hueSaturation == nil && session.filterEdit == nil)
    }

    /// Camera Raw docks to the document window. That frame must not become the place
    /// Gaussian Blur and the other filters reopen.
    @Test func dockedPlacementLeavesTheSavedFilterPosition() throws {
        let controller = FloatingPanelController(name: "testDockedFilterPosition")
        controller.show(title: "Gaussian Blur", content: Text("Blur"))
        settle()
        let panel = try #require(NSApp.windows.first { $0.identifier == controller.identifier })
        let parked = NSPoint(x: 40, y: 240)
        panel.setFrameOrigin(parked)
        let saved = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        controller.close()

        controller.show(title: "Camera Raw Filter", content: Text("Camera Raw").frame(maxWidth: .infinity, maxHeight: .infinity), placement: .dockedToMainWindowRight)
        settle()
        #expect(panel.isVisible)
        let document = try #require(NSApp.windows.first { $0 !== panel && $0.isVisible && !($0 is NSPanel) })
        #expect(abs(panel.frame.maxX - document.frame.maxX) < 2)
        controller.close()

        controller.show(title: "Gaussian Blur", content: Text("Blur"))
        settle()
        let restored = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        #expect(abs(restored.x - saved.x) < 2 && abs(restored.y - saved.y) < 2,
                "the filter panel reopens where it was left, not on the right edge: \(restored)")
        controller.close()
    }

    /// The docked panel has to be wide enough for the widest thing it holds. Camera Raw's three
    /// grading wheels sit side by side and overflowed a 440pt panel, which showed as controls
    /// running past its edge — nothing warns about that, so the sizes are compared here instead.
    @Test func theDockedPanelFitsTheGradingWheels() throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64)
        let grading = NSHostingView(rootView: AnyView(CameraRawGradingControls(session: session).roundedControls()))
        // The sheet pads 24 on each side, and the colour section is inset another 18.
        let available = FloatingPanelController.dockedWidth - 48 - 18
        #expect(grading.fittingSize.width <= available,
                "grading needs \(grading.fittingSize.width), the panel leaves \(available)")
    }

    /// Camera Raw docks to the document window's right edge, at its full height, and follows it.
    ///
    /// The window it docks to is whichever one the app has, not one this test makes: the test host
    /// is Compositor itself, so its own editor window is main throughout. An earlier version of
    /// this test built its own window, which the panel quite correctly ignored — and the two
    /// windows together took the test host down.
    @Test func cameraRawDocksToTheDocumentWindow() throws {
        let controller = FloatingPanelController(name: "testCameraRawOpensRight")
        controller.show(title: "Camera Raw Filter", content: Text("Camera Raw").frame(maxWidth: .infinity, maxHeight: .infinity),
                        placement: .dockedToMainWindowRight)
        settle()
        let panel = try #require(NSApp.windows.first { $0.identifier == controller.identifier })
        let document = try #require(NSApp.windows.first { $0 !== panel && $0.isVisible && !($0 is NSPanel) })
        #expect(abs(panel.frame.maxX - document.frame.maxX) < 2, "on the right edge: \(panel.frame) vs \(document.frame)")
        #expect(abs(panel.frame.height - document.frame.height) < 2, "full height: \(panel.frame) vs \(document.frame)")

        // A drag posts a move rather than a resize; the panel has to follow both.
        document.setFrameOrigin(NSPoint(x: document.frame.origin.x + 40, y: document.frame.origin.y + 30))
        settle()
        #expect(abs(panel.frame.maxX - document.frame.maxX) < 2, "follows a move: \(panel.frame) vs \(document.frame)")
        document.setFrame(NSRect(x: document.frame.minX, y: document.frame.minY,
                                 width: document.frame.width, height: document.frame.height - 60), display: true)
        settle()
        #expect(abs(panel.frame.height - document.frame.height) < 2, "follows a resize: \(panel.frame) vs \(document.frame)")
        controller.close()
    }

}
