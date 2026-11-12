import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor @Suite(.serialized)
struct BrushPaletteTests {
    private func panelControls(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.bounds.width > 300, scroll.bounds.width < 500 { return scroll }
        return view.subviews.lazy.compactMap { panelControls(in: $0) }.first
    }

    @Test func previewBackgroundIsOpaqueWhiteOrBlackWithoutChangingPaint() throws {
        let preview = BrushDrawingView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        preview.reset()
        preview.beginStroke(at: CGPoint(x: 160, y: 120)); preview.endStroke()
        let document = preview.session.document
        let history = preview.session.history.undoCount
        for black in [false, true] {
            preview.blackBackground = black
            let context = try BrushRaster.context(width: 320, height: 240, mask: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            preview.draw(preview.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
            #expect(pixels[0] == (black ? 0 : 255) && pixels[1] == pixels[0] && pixels[2] == pixels[0] && pixels[3] == 255)
            #expect(preview.session.document == document && preview.session.history.undoCount == history)
        }
    }

    @Test func completedEditorTabsFitAndRenderTheirNativeControls() async throws {
        var brush = BrushPreset(name: "Editor Gaps")
        brush.roundDynamics.grain = BrushGrain(scale: 20)
        brush.roundDynamics.properties = BrushProperties(maximumSize: 200)
        brush.roundDynamics.stabilization = BrushStabilization(streamline: 0.2, pressure: 0.4)
        brush.roundDynamics.pressureTaper = BrushTaper(start: 0.2, end: 0.2)
        brush.roundDynamics.touchTaper = BrushTaper(start: 0.1, end: 0.3)
        brush.roundDynamics.wetMix = BrushWetMix(dilution: 0.2, pull: 0.5, grade: 0.4, blur: 0.3)
        brush.roundDynamics.colorDynamics = BrushColorDynamics(secondaryColor: PaletteColor(red: 0.15, green: 0.3, blue: 0.8), stroke: BrushColorResponse(hue: 0.5), stamp: BrushColorResponse(secondary: 0.3), pressure: BrushColorResponse(darkness: 0.4))
        for category in ["Grain", "Properties", "Taper", "Stabilization", "Shape", "Wet Mix", "Color Dynamics", "Pen / Tablet"] {
            let name = "completedEditor-" + category
            let panel = FloatingPanelController(name: name)
            panel.show(title: "Brush Editor", content: BrushEditorSheet(brush: brush, color: PaletteColor(red: 0.2, green: 0.3, blue: 0.7),
                finish: { _ in }, category: category).background(Color(nsColor: .windowBackgroundColor)).roundedControls().preferredColorScheme(.dark))
            defer { panel.close() }
            try await Task.sleep(for: .milliseconds(200))
            let view = try #require(NSApp.windows.first { $0.identifier?.rawValue == name }?.contentView)
            #expect(view.bounds.width == 850 && view.bounds.height <= 640)
            func drawing(in view: NSView) -> BrushDrawingView? {
                (view as? BrushDrawingView) ?? view.subviews.lazy.compactMap { drawing(in: $0) }.first
            }
            let preview = try #require(drawing(in: view))
            preview.beginStroke(at: CGPoint(x: 40, y: 100)); preview.continueStroke(at: CGPoint(x: 270, y: 140)); preview.endStroke()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "editor-gap-" + category + ".png")
            if ["Color Dynamics", "Pen / Tablet"].contains(category), let scroll = panelControls(in: view), let document = scroll.documentView {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(100))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "editor-" + category + "-bottom.png")
            }
        }
    }

    @Test func colorDynamicsPreviewRetainsBothPaintColorsWhenReplayed() async throws {
        let preview = BrushDrawingView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        preview.preset.roundDynamics.spacing = 0.25; preview.preset.roundDynamics.flow = 0.4
        preview.preset.roundDynamics.colorDynamics = BrushColorDynamics(secondaryColor: PaletteColor(red: 0.1, green: 0.2, blue: 0.9), stamp: BrushColorResponse(secondary: 0.8))
        preview.color = PaletteColor(red: 0.8, green: 0.2, blue: 0.1)
        preview.reset()
        preview.beginStroke(at: CGPoint(x: 40, y: 100)); preview.continueStroke(at: CGPoint(x: 270, y: 100)); preview.endStroke()
        preview.preset.roundDynamics.colorDynamics?.secondaryColor = PaletteColor(red: 0.1, green: 0.9, blue: 0.2)
        preview.color = PaletteColor(red: 0.6, green: 0.2, blue: 0.7)
        preview.beginStroke(at: CGPoint(x: 150, y: 50)); preview.continueStroke(at: CGPoint(x: 150, y: 180)); preview.endStroke()
        let before = try await ImageExporter.shared.render(try #require(preview.session.projectSnapshot())).image
        preview.preset.roundDynamics.colorDynamics?.secondaryColor = .black
        preview.blackBackground = true
        preview.reset(clearing: false)
        let after = try await ImageExporter.shared.render(try #require(preview.session.projectSnapshot())).image
        #expect(NSBitmapImageRep(cgImage: before).representation(using: .png, properties: [:]) == NSBitmapImageRep(cgImage: after).representation(using: .png, properties: [:]))
        #expect(preview.session.brushSettings.roundDynamics.colorDynamics?.secondaryColor == .black)
        Attachment.record(try #require(NSBitmapImageRep(cgImage: after).representation(using: .png, properties: [:])), named: "color-dynamics-preview-paint-colors.png")
    }

    @Test func renderingPreviewKeepsStrokeColorsDuringSettingsReplay() async throws {
        let preview = BrushDrawingView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        preview.preset.roundDynamics.rendering = BrushRenderingSettings(mode: .uniformBlending, wetEdges: 0.5, burntEdges: 0.4)
        preview.preset.roundDynamics.wetMix = BrushWetMix(dilution: 0.2, pull: 0.5, grade: 0.4, blur: 0.3)
        preview.preset.roundDynamics.flow = 0.3; preview.preset.roundDynamics.spacing = 0.2
        preview.color = PaletteColor(red: 0.1, green: 0.7, blue: 0.3); preview.reset()
        preview.beginStroke(at: CGPoint(x: 40, y: 100)); preview.continueStroke(at: CGPoint(x: 270, y: 100)); preview.endStroke()
        preview.color = PaletteColor(red: 0.8, green: 0.25, blue: 0.1)
        preview.beginStroke(at: CGPoint(x: 150, y: 50)); preview.continueStroke(at: CGPoint(x: 150, y: 180)); preview.endStroke()
        let before = try await ImageExporter.shared.render(try #require(preview.session.projectSnapshot())).image
        preview.reset(clearing: false)
        let after = try await ImageExporter.shared.render(try #require(preview.session.projectSnapshot())).image
        #expect(NSBitmapImageRep(cgImage: before).representation(using: .png, properties: [:])
            == NSBitmapImageRep(cgImage: after).representation(using: .png, properties: [:]))
        Attachment.record(try #require(NSBitmapImageRep(cgImage: after).representation(using: .png, properties: [:])), named: "rendering-preview-two-colors.png")
    }

    @Test func renderingEditorControlsFitNativePanel() async throws {
        for advanced in [false, true] {
            var brush = BrushPreset(name: "Rendering")
            brush.roundDynamics.flow = 0.3
            brush.roundDynamics.rendering = advanced ? BrushRenderingSettings(mode: .intenseBlending, wetEdges: 0.8, burntEdges: 0.6,
                edgeBlend: .colorBurn, strokeBlend: .overlay, luminanceBlending: true, alphaThreshold: 0.2,
                dualSource: .generated, secondary: .bristles, secondaryScale: 1.2, classicDualNormal: true) : BrushRenderingSettings(mode: .lightGlaze)
            let name = "renderingEditorTest-\(advanced)"
            let panel = FloatingPanelController(name: name)
            panel.show(title: "Rendering Editor", content: BrushEditorSheet(brush: brush,
                color: PaletteColor(red: 0.7, green: 0.3, blue: 0.1), finish: { _ in }, category: "Rendering")
                .background(Color(nsColor: .windowBackgroundColor)).roundedControls().preferredColorScheme(.dark))
            defer { panel.close() }
            try await Task.sleep(for: .milliseconds(200))
            let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == name })
            let view = try #require(window.contentView)
            #expect(view.bounds.width == 850 && view.bounds.height <= 640)
            func drawing(in view: NSView) -> BrushDrawingView? {
                (view as? BrushDrawingView) ?? view.subviews.lazy.compactMap { drawing(in: $0) }.first
            }
            let preview = try #require(drawing(in: view))
            preview.beginStroke(at: CGPoint(x: 40, y: 90)); preview.continueStroke(at: CGPoint(x: 270, y: 140)); preview.endStroke()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "rendering-editor-\(advanced)-top.png")
            if let scroll = panelControls(in: view), let document = scroll.documentView {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(100))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "rendering-editor-\(advanced)-bottom.png")
            }
        }
    }

    @Test func pressureEditorsShowCurveProfilesForRoundAndCustomTips() async throws {
        let cases: [(Bool, PressureCurve.Profile)] = [(false, .linear), (true, .linear), (false, .sCurve), (true, .sCurve)]
        for (custom, profile) in cases {
            var brush = BrushPreset(name: "Pressure test")
            if custom { brush.roundDynamics.shape = ShapeBrushSettings(source: .custom, customTip: asymmetricBrushShapeTip()) }
            brush.roundDynamics.pressureCurve = profile.curve
            let name = "pressureEditorTest-\(custom)-\(profile.rawValue)"
            let panel = FloatingPanelController(name: name)
            panel.show(title: "Pressure Editor", content: BrushEditorSheet(brush: brush,
                color: PaletteColor(red: 0, green: 0, blue: 0), finish: { _ in }, category: "Pen / Tablet")
                .background(Color(nsColor: .windowBackgroundColor)).roundedControls().preferredColorScheme(.dark))
            defer { panel.close() }
            try await Task.sleep(for: .milliseconds(200))
            let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == name })
            let view = try #require(window.contentView)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "pressure-\(custom ? "custom" : "round")-\(profile.rawValue).png")
        }
    }

    @Test func settingChangesCoalesceAndDrawingFlushesPendingReplay() async throws {
        let preview = BrushDrawingView(frame: NSRect(x: 0, y: 0, width: 240, height: 220))
        preview.reset()
        preview.beginStroke(at: CGPoint(x: 40, y: 60))
        preview.continueStroke(at: CGPoint(x: 180, y: 100))
        preview.endStroke()
        let original = preview.session.activeLayer?.id
        for step in 1...20 {
            preview.preset.roundDynamics.taperStart = CGFloat(step) / 100
            preview.scheduleReplay()
        }
        #expect(preview.session.activeLayer?.id == original, "Slider events must not synchronously rebuild the preview")
        try await Task.sleep(for: .milliseconds(350))
        let replayed = preview.session.activeLayer?.id
        #expect(replayed != original)
        #expect(preview.session.brushSettings.roundDynamics.taperStart == 0.2)
        preview.preset.roundDynamics.taperEnd = 0.3
        preview.scheduleReplay()
        preview.beginStroke(at: CGPoint(x: 80, y: 80))
        #expect(preview.session.brushSettings.roundDynamics.taperEnd == 0.3)
        preview.endStroke()
        let flushed = preview.session.activeLayer?.id
        try await Task.sleep(for: .milliseconds(350))
        #expect(preview.session.activeLayer?.id == flushed, "Drawing cancels the pending replay")
        preview.scheduleReplay()
        preview.reset()
        let cleared = preview.session.activeLayer?.id
        try await Task.sleep(for: .milliseconds(350))
        #expect(preview.session.activeLayer?.id == cleared && preview.session.activeLayer?.asset == nil)
    }

    @Test func previewReplayMatchesCanvasAndNeverTouchesTheCollection() async throws {
        let before = BrushLibrary.shared.brushes
        let preview = BrushDrawingView(frame: NSRect(x: 0, y: 0, width: 240, height: 220))
        var preset = BrushPreset(name: "Preview", hardness: 0.4)
        preset.diameter = 24; preset.opacity = 0.6; preset.pressureSize = true
        preview.preset = preset
        preview.color = PaletteColor(red: 0.2, green: 0.4, blue: 0.8)
        preview.reset()
        let clearHistory = preview.session.history.undoCount
        #expect(abs(preview.drawingRect.width / preview.drawingRect.height - 4 / 3) < 0.001)
        preview.beginStroke(at: CGPoint(x: 40, y: 60), pressure: 0.2)
        preview.continueStroke(at: CGPoint(x: 110, y: 90), pressure: 0.6)
        preview.continueStroke(at: CGPoint(x: 230, y: 140), pressure: 1)
        preview.endStroke()
        preview.continueStroke(at: CGPoint(x: 300, y: 10)) // A drag without a matching press must not enter replay.
        preset.diameter = 38; preset.opacity = 0.8
        preview.preset = preset
        preview.reset(clearing: false)

        let canvas = EditorSession()
        canvas.createDocument(width: 320, height: 240); canvas.addBlankLayer(); canvas.selectTool(.brush)
        canvas.brushSettings = preset.applying(to: canvas.brushSettings)
        canvas.foregroundColor = preview.color
        canvas.beginBrush(at: CGPoint(x: 40, y: 60), pressure: 0.2)
        canvas.continueBrush(at: CGPoint(x: 110, y: 90), pressure: 0.6)
        canvas.continueBrush(at: CGPoint(x: 230, y: 140), pressure: 1)
        canvas.finishBrushImmediately()
        let actual = try await ImageExporter.shared.render(try #require(preview.session.projectSnapshot())).image
        let expected = try await ImageExporter.shared.render(try #require(canvas.projectSnapshot())).image
        #expect(NSBitmapImageRep(cgImage: actual).representation(using: .png, properties: [:])
                == NSBitmapImageRep(cgImage: expected).representation(using: .png, properties: [:]))
        #expect(BrushLibrary.shared.brushes == before)
        preview.reset()
        #expect(preview.session.activeLayer?.asset == nil)
        #expect(preview.session.history.undoCount == clearHistory, "Clear releases the isolated preview history")
        var failure: String?
        preview.onError = { failure = $0 }
        preview.preset.diameter = .nan
        preview.reset()
        preview.beginStroke(at: CGPoint(x: 80, y: 80))
        #expect(failure != nil)
        preview.preset = preset
        preview.reset()
        preview.beginStroke(at: CGPoint(x: 80, y: 80))
        preview.endStroke()
        #expect(failure == nil, "A valid retry must clear the preview error")
    }

    @Test func nativeAndImportedEditorsFitAndRenderUsingTheExistingPanelKit() throws {
        let source = BrushSource(archiveDigest: String(repeating: "a", count: 64), filename: "Source.brushset", definitions: [
            .init(path: "Brush.archive", shapeReference: "Missing/Shape.png", grainReference: "Missing/Grain.png"),
            .init(path: "Sub01/Brush.archive", shapeReference: "Secondary.png", grainReference: nil)
        ], issues: Array(repeating: "Missing asset reference is retained. Rendering mapping is unavailable.", count: 10))
        for mode in 0...4 {
            let imported = mode == 1 || mode == 2
            var brush = BrushPreset(name: imported ? "Imported brush" : "Native brush")
            if imported { brush.source = source }
            if mode == 2 {
                brush.source?.definitions = [.init(path: "Brush.archive", shapeReference: BasicBrushShape.hard.rawValue,
                    grainReference: nil, shapeResolution: .procedural(.hard, revision: 1))]
                brush.usesRoundApproximation = true
            }
            if mode == 3 {
                brush.roundDynamics.shape = ShapeBrushSettings(source: .custom, customTip: asymmetricBrushShapeTip(), filtering: .improved)
            }
            if mode == 4 {
                brush.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles)
            }
            let name = "brushEditorLayoutTest-\(mode)"
            let panel = FloatingPanelController(name: name)
            panel.show(title: "Brush Editor", content: BrushEditorSheet(brush: brush, color: PaletteColor(red: 0, green: 0, blue: 0), finish: { _ in }, category: "Shape")
                .background(Color(nsColor: .windowBackgroundColor)).roundedControls().preferredColorScheme(.dark))
            defer { panel.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == name })
            let view = try #require(window.contentView)
            #expect(view.bounds.width == 850)
            #expect(view.bounds.height <= 640)
            if brush.isRenderable {
                func preview(in parent: NSView) -> BrushDrawingView? {
                    if let drawing = parent as? BrushDrawingView { return drawing }
                    return parent.subviews.lazy.compactMap { preview(in: $0) }.first
                }
                let drawing = try #require(preview(in: view))
                drawing.beginStroke(at: CGPoint(x: 45, y: 160))
                drawing.continueStroke(at: CGPoint(x: 110, y: 60))
                drawing.continueStroke(at: CGPoint(x: 230, y: 130))
                drawing.endStroke()
            }
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(data.count > 1000)
            Attachment.record(data, named: mode == 4 ? "shape-editor-generated-top.png" : mode == 3 ? "shape-editor-custom-top.png" : mode == 2 ? "brush-editor-approximation.png" : imported ? "brush-editor-imported.png" : "shape-editor-procedural-top.png")
            if !imported {
                func controlsScroll(in parent: NSView) -> NSScrollView? {
                    if let scroll = parent as? NSScrollView, scroll.bounds.width > 300, scroll.bounds.width < 500 { return scroll }
                    return parent.subviews.lazy.compactMap { controlsScroll(in: $0) }.first
                }
                if let scroll = controlsScroll(in: view), let document = scroll.documentView {
                    scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: mode == 4 ? "shape-editor-generated-bottom.png" : mode == 3 ? "shape-editor-custom-bottom.png" : "shape-editor-procedural-bottom.png")
                }
            }
        }
    }
}
