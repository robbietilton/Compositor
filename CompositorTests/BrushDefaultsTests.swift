import AppKit
import Testing
@testable import Compositor

/// The brush tips, mode and colors a document hands on to the next one.
@MainActor
struct BrushDefaultsTests {
    private typealias Tip = BrushDefaults.Tip

    @Test func aNewDocumentStartsFromTheCompiledDefaults() {
        #expect(EditorSession().brushDefaults == BrushDefaults())
    }

    /// Switching tools swaps the tip in `brushSettings` before the tool changes; each tip must still be
    /// recorded as its own family's, never the one being switched to.
    @Test func eachToolFamilyKeepsItsOwnTip() {
        let session = EditorSession()
        session.selectTool(.brush)
        session.brushSettings.diameter = 12
        session.brushSettings.opacity = 0.5
        session.selectTool(.cloneStamp)
        #expect(session.brushDefaults.tips == [Tip(diameter: 12, hardness: 1, opacity: 0.5),
                                               Tip(diameter: 40, hardness: 0, opacity: 1), Tip(diameter: 40, hardness: 0, opacity: 1)])
        session.brushSettings.diameter = 80
        session.brushSettings.hardness = 0.3
        session.selectTool(.blur)
        session.brushSettings.diameter = 5
        session.selectTool(.spotHealing)
        #expect(session.brushSettings.diameter == 12)
        #expect(session.brushDefaults.tips == [Tip(diameter: 12, hardness: 1, opacity: 0.5),
                                               Tip(diameter: 80, hardness: 0.3, opacity: 1), Tip(diameter: 5, hardness: 0, opacity: 1)])
    }

    @Test func modeSmoothingAndColorsAreRecorded() {
        let session = EditorSession()
        session.brushMode = .erase
        session.brushSettings.smoothing = 30
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.backgroundColor = PaletteColor(red: 0, green: 0, blue: 1)
        let defaults = session.brushDefaults
        #expect(defaults.mode == .erase && defaults.smoothing == 30)
        #expect(defaults.foreground == PaletteColor(red: 1, green: 0, blue: 0))
        #expect(defaults.background == PaletteColor(red: 0, green: 0, blue: 1))
    }

    @Test func aNewDocumentTakesOnWhatTheLastOneLeft() {
        var saved = BrushDefaults()
        saved.tips = [Tip(diameter: 3, hardness: 1, opacity: 0.8), Tip(diameter: 90, hardness: 0.2, opacity: 0.6),
                      Tip(diameter: 25, hardness: 0.5, opacity: 0.4)]
        saved.smoothing = 45
        saved.mode = .erase
        saved.foreground = PaletteColor(red: 0.2, green: 0.4, blue: 0.6)
        saved.background = PaletteColor(red: 1, green: 1, blue: 0)
        let session = EditorSession()
        session.apply(saved)
        #expect(session.brushDefaults == saved)
        #expect(session.brushSettings.diameter == 3 && session.brushSettings.opacity == 0.8 && session.brushSettings.smoothing == 45)
        #expect(session.brushMode == .erase && session.backgroundColor == saved.background)
        session.selectTool(.cloneStamp)
        #expect(session.brushSettings.diameter == 90 && session.brushSettings.hardness == 0.2 && session.brushSettings.opacity == 0.6)
        session.selectTool(.blur)
        #expect(session.brushSettings.diameter == 25 && session.brushSettings.hardness == 0.5)
    }
}
