import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// The Brush bar's Size and Opacity captions in Pressure Sensitivity: a tap sets the field to follow Apple Pencil's
/// pressure or not, in place of Photoshop's buttons beside them; while it does, the caption and the value are purple,
/// the value shows the live size or opacity under a stroke, and typing is locked.
@MainActor struct PadPressureCaptionTests {
    /// A 400 × 300 canvas with one layer on it and the Brush in hand, as a new tab's: Size following the pressure and
    /// Opacity not.
    private func session(_ tool: NavigationTool = .brush) throws -> EditorSession {
        let session = EditorTab().session
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        session.selectTool(tool)
        session.brushSettings.diameter = 40
        session.brushSettings.opacity = 0.8
        return session
    }

    /// A Pencil's state of the test's own: one that has touched, reporting its force or not, in `mode`.
    private func input(_ mode: DrawingInput.Mode, pressure: Bool = true) throws -> DrawingInput {
        let name = "PadPressureCaptionTests \(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let input = DrawingInput(defaults: defaults)
        input.pencilTurnedUp(pressure: pressure)
        input.mode = mode
        return input
    }

    /// `session`'s bar, wide enough for everything and laid out, following `input` and `pressure`, and what it flashed.
    private func bar(for session: EditorSession, input: DrawingInput, pressure: StrokePressure? = nil) -> (ToolOptionsBar, Flashes) {
        let bar = ToolOptionsBar(frame: CGRect(x: 0, y: 0, width: 2400, height: ToolOptionsBar.height))
        let flashes = Flashes()
        bar.input = input
        bar.strokePressure = pressure ?? StrokePressure()
        bar.onFlash = { flashes.messages.append($0) }
        bar.onWarn = { flashes.warnings.append($0) }
        bar.session = session
        bar.updatePropertiesIfNeeded()
        bar.layoutIfNeeded()
        return (bar, flashes)
    }

    private final class Flashes { var messages: [String] = []; var warnings: [String] = [] }
    private final class Counter: @unchecked Sendable { var count = 0 }

    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// The caption reading `text` in `bar`, and the text field beside it.
    private func field(_ text: String, in bar: ToolOptionsBar) throws -> (caption: FieldCaption, field: UITextField) {
        let caption = try #require(views(FieldCaption.self, in: bar).first { $0.text == text })
        let row = try #require(caption.superview)
        return (caption, try #require(views(UITextField.self, in: row).first))
    }

    private func update(_ bar: ToolOptionsBar) {
        bar.setNeedsUpdateProperties()
        bar.updatePropertiesIfNeeded()
    }

    // MARK: The default

    /// A new tab's brush has Size following the pressure and Opacity not, which the Mac's shared default leaves off.
    @Test func sizeFollowsThePressureInANewTab() throws {
        let session = EditorTab().session
        #expect(session.brushSettings.pressureSize && !session.brushSettings.pressureOpacity)
        let shared = BrushSettings()
        #expect(!shared.pressureSize && !shared.pressureOpacity)
        #expect(!EditorSession().brushSettings.pressureSize)
    }

    // MARK: A tap on the caption

    /// In Pressure Sensitivity, a tap on Size or Opacity sets it to follow the pressure or not, says so whole in the
    /// status line, and isn't a step to undo.
    @Test func aTapOnTheCaptionSetsItToFollowThePressure() throws {
        let session = try session()
        let (bar, flashes) = bar(for: session, input: try input(.pressure))
        let size = try field("Size", in: bar).caption, opacity = try field("Opacity", in: bar).caption
        let steps = session.history.undoCount

        #expect(size.accessibilityActivate())
        #expect(!session.brushSettings.pressureSize && !session.brushSettings.pressureOpacity)
        #expect(opacity.accessibilityActivate())
        #expect(session.brushSettings.pressureOpacity)
        #expect(size.accessibilityActivate())
        #expect(opacity.accessibilityActivate())
        #expect(session.brushSettings.pressureSize && !session.brushSettings.pressureOpacity)
        #expect(session.history.undoCount == steps)
        #expect(flashes.messages == [
            "The Size field sets the size: every stroke paints the same width",
            "Apple Pencil’s pressure sets the opacity: a light touch paints fainter, up to 100%",
            "Apple Pencil’s pressure sets the size: a light touch paints a thinner line",
            "The Opacity field sets the opacity: every stroke paints the same",
        ])
    }

    /// Turned to follow the pressure, Opacity starts again from 100%, the most the pressure reaches, whatever it was
    /// set to by hand; turned back, it stays there. Size keeps its value either way.
    @Test func followingThePressureSetsTheOpacityToFull() throws {
        let session = try session()
        session.brushSettings.pressureOpacity = false
        session.brushSettings.opacity = 0.5
        let (bar, _) = bar(for: session, input: try input(.pressure))
        let opacity = try field("Opacity", in: bar), size = try field("Size", in: bar)
        let diameter = session.brushSettings.diameter

        #expect(opacity.caption.accessibilityActivate())
        #expect(session.brushSettings.pressureOpacity && session.brushSettings.opacity == 1)
        update(bar)
        #expect(opacity.field.text == "100")
        #expect(opacity.caption.accessibilityActivate())
        #expect(!session.brushSettings.pressureOpacity && session.brushSettings.opacity == 1)
        #expect(size.caption.accessibilityActivate())
        #expect(size.caption.accessibilityActivate())
        #expect(session.brushSettings.diameter == diameter)
    }

    /// A value being typed into Opacity goes in before the tap on its caption turns the pressure on, so the reset to 100%
    /// wins over it, rather than the draft going in as the lock takes the keyboard.
    @Test func whatsBeingTypedDoesntUndoTheReset() async throws {
        let session = try session()
        session.brushSettings.pressureOpacity = false
        session.brushSettings.opacity = 0.8
        let (bar, _) = bar(for: session, input: try input(.pressure))
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        window.addSubview(bar)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let opacity = try field("Opacity", in: bar)
        for _ in 0..<250 where !(opacity.field.isFirstResponder || opacity.field.becomeFirstResponder()) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(opacity.field.isFirstResponder)
        opacity.field.text = "50"
        opacity.field.sendActions(for: .editingChanged)

        #expect(opacity.caption.accessibilityActivate())
        update(bar)
        #expect(!opacity.field.isFirstResponder)
        #expect(session.brushSettings.pressureOpacity && session.brushSettings.opacity == 1)
        #expect(opacity.field.text == "100")
    }

    /// The caption's tap is its own recognizer, waiting on no double tap, so it answers at once; Opacity's double tap
    /// does nothing on it then, its reset staying on the slider's thumb.
    @Test func theCaptionsTapWaitsForNothing() throws {
        let session = try session()
        let (bar, _) = bar(for: session, input: try input(.pressure))
        let opacity = try field("Opacity", in: bar).caption
        let taps = (opacity.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        let single = try #require(taps.first { $0.numberOfTapsRequired == 1 })
        #expect(single.isEnabled)
        let double = try #require(taps.first { $0.numberOfTapsRequired == 2 })
        let slider = try #require(views(SliderField.self, in: bar).first { $0.caption === opacity })
        slider.onReset = {}
        #expect(!slider.gestureRecognizerShouldBegin(double))
        #expect(!slider.resets(at: opacity.convert(CGPoint(x: 4, y: 4), to: slider)))
    }

    /// Outside Pressure Sensitivity, or with any other tool, a tap doesn't toggle: the captions are plain labels and
    /// the values can be typed, though Size be set to follow the pressure. (Another tool's tap warns instead, below.)
    @Test func elsewhereATapOnTheCaptionDoesNothing() throws {
        let cases: [(NavigationTool, DrawingInput.Mode, Bool)] = [
            (.brush, .pencil, true), (.brush, .finger, true), (.brush, .pencil, false), (.brush, .finger, false),
            (.spotHealing, .pressure, true), (.cloneStamp, .pressure, true), (.blur, .pressure, true),
        ]
        let warns: Set<NavigationTool> = [.spotHealing, .cloneStamp, .blur]
        for (tool, mode, pressure) in cases {
            let session = try session(tool)
            let (bar, flashes) = bar(for: session, input: try input(mode, pressure: pressure))
            for name in ["Size", tool == .blur ? "Strength" : "Opacity"] {
                let (caption, field) = try field(name, in: bar)
                #expect(!caption.accessibilityActivate(), "\(tool), \(mode), \(name)")
                #expect(caption.textColor == .secondaryLabel && field.textColor != OptionControls.pressureValueColor, "\(tool), \(mode), \(name)")
                #expect(!caption.accessibilityTraits.contains(.button) && caption.accessibilityValue == nil)
                #expect(field.delegate?.textFieldShouldBeginEditing?(field) == true, "\(tool), \(mode), \(name)")
                let taps = (caption.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
                if !warns.contains(tool) { #expect(taps.allSatisfy { $0.numberOfTapsRequired != 1 || !$0.isEnabled }) }
                caption.tapped()
            }
            #expect(session.brushSettings.pressureSize && !session.brushSettings.pressureOpacity)
            #expect(flashes.messages.isEmpty)
            #expect(flashes.warnings.count == (warns.contains(tool) ? 2 : 0), "\(tool), \(mode)")
        }
    }

    /// The Eraser is a mode of the Brush, and follows the pressure as it does.
    @Test func theEraserHasTheCaptionsToo() throws {
        let session = try session()
        session.brushMode = .erase
        let (bar, _) = bar(for: session, input: try input(.pressure))
        #expect(try field("Size", in: bar).caption.accessibilityActivate())
        #expect(!session.brushSettings.pressureSize)
    }

    /// Switching mode leaves the settings alone and doesn't build the bar again; the captions follow it.
    @Test func theCaptionsFollowTheMode() throws {
        let session = try session()
        let input = try input(.pressure)
        let (bar, _) = bar(for: session, input: input)
        let (size, field) = try field("Size", in: bar)
        #expect(size.textColor == .systemPurple)
        input.mode = .pencil
        bar.updatePropertiesIfNeeded()
        #expect(size.textColor == .secondaryLabel && field.textColor != OptionControls.pressureValueColor && !size.accessibilityActivate())
        #expect(session.brushSettings.pressureSize)
        input.mode = .pressure
        bar.updatePropertiesIfNeeded()
        #expect(try self.field("Size", in: bar).caption === size, "the same caption: the bar wasn't built again")
        #expect(size.textColor == .systemPurple && field.textColor == OptionControls.pressureValueColor)
    }

    // MARK: Following the pressure

    /// Following the pressure, the caption and its value are purple; set by hand, as usual.
    @Test func whatFollowsThePressureIsPurple() throws {
        let session = try session()
        let (bar, _) = bar(for: session, input: try input(.pressure))
        let size = try field("Size", in: bar), opacity = try field("Opacity", in: bar)
        #expect(size.caption.textColor == .systemPurple && size.field.textColor == OptionControls.pressureValueColor)
        #expect(opacity.caption.textColor == .secondaryLabel && opacity.field.textColor != OptionControls.pressureValueColor)
        session.brushSettings.pressureSize = false
        session.brushSettings.pressureOpacity = true
        bar.updatePropertiesIfNeeded()
        #expect(size.caption.textColor == .secondaryLabel && size.field.textColor != OptionControls.pressureValueColor)
        #expect(opacity.caption.textColor == .systemPurple && opacity.field.textColor == OptionControls.pressureValueColor)
    }

    /// Following the pressure, the value can't be typed: a tap on it says, whole, what sets it and how to set it by
    /// hand. One being typed when the caption's tapped gives the keyboard back.
    @Test func followingThePressureLocksTyping() throws {
        let session = try session()
        session.brushSettings.pressureOpacity = true
        let (bar, flashes) = bar(for: session, input: try input(.pressure))
        let size = try field("Size", in: bar), opacity = try field("Opacity", in: bar)
        #expect(size.field.delegate?.textFieldShouldBeginEditing?(size.field) == false)
        #expect(opacity.field.delegate?.textFieldShouldBeginEditing?(opacity.field) == false)
        #expect(flashes.messages == [
            "Apple Pencil’s pressure sets the size · Tap the Size label to set it yourself",
            "Apple Pencil’s pressure sets the opacity · Tap the Opacity label to set it yourself",
        ])
        session.brushSettings.pressureSize = false
        bar.updatePropertiesIfNeeded()
        #expect(size.field.delegate?.textFieldShouldBeginEditing?(size.field) == true)
        #expect(flashes.messages.count == 2)
    }

    /// Scrubbing the caption and the Opacity slider still set the setting, the most the pressure reaches.
    @Test func scrubbingStillSetsTheMost() throws {
        let session = try session()
        session.brushSettings.pressureOpacity = true
        let (bar, _) = bar(for: session, input: try input(.pressure))
        let size = try #require(views(NumberField.self, in: bar).first { $0.caption?.text == "Size" })
        size.onChange(60)
        #expect(session.brushSettings.diameter == 60 && session.brushSettings.pressureSize)
        let opacity = try #require(views(SliderField.self, in: bar).first { $0.caption.text == "Opacity" })
        opacity.onChange(0.5)
        #expect(session.brushSettings.opacity == 0.5 && session.brushSettings.pressureOpacity)
    }

    /// The slider of a value the pressure sets is locked with its field: no drag, a track in the field's muted purple
    /// and a gray thumb, so it looks as locked as it is; a tap on it says why, as one on the field does, and its double
    /// tap puts nothing back. Set by hand again, it's the slider it was.
    @Test func followingThePressureLocksTheSlider() throws {
        let session = try session()
        session.brushSettings.pressureOpacity = true
        let (bar, flashes) = bar(for: session, input: try input(.pressure))
        let opacity = try #require(views(SliderField.self, in: bar).first { $0.caption.text == "Opacity" })
        let slider = try #require(views(UISlider.self, in: opacity).first)
        #expect(!slider.isEnabled && opacity.isEnabled)
        #expect(slider.minimumTrackTintColor == OptionControls.pressureValueColor && slider.thumbTintColor == .systemGray)
        let taps = (slider.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        let single = try #require(taps.first { $0.numberOfTapsRequired == 1 })
        #expect(single.isEnabled)
        var reset = false
        opacity.onReset = { reset = true }
        let thumb = slider.convert(slider.thumbRect(forBounds: slider.bounds, trackRect: slider.trackRect(forBounds: slider.bounds),
                                                    value: slider.value), to: opacity)
        #expect(!opacity.resets(at: CGPoint(x: thumb.midX, y: thumb.midY)) && !reset)
        opacity.perform(Selector(("lockedTapped")))
        #expect(flashes.messages == ["Apple Pencil’s pressure sets the opacity · Tap the Opacity label to set it yourself"])

        session.brushSettings.pressureOpacity = false
        update(bar)
        #expect(slider.isEnabled && slider.minimumTrackTintColor == nil && slider.thumbTintColor == nil && !single.isEnabled)
        #expect(opacity.resets(at: CGPoint(x: thumb.midX, y: thumb.midY)) && reset, "set by hand, the thumb's double tap puts it back")
        // And out of Pressure Sensitivity, though set to follow it.
        session.brushSettings.pressureOpacity = true
        let pencil = try input(.pencil)
        bar.input = pencil
        update(bar)
        #expect(slider.isEnabled && slider.thumbTintColor == nil)
    }

    /// The value the pressure sets is purple, as its caption, but muted, so it doesn't catch the eye as much.
    @Test func theLockedValueIsAMutedPurple() throws {
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        var (h1, s1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (h2, s2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        UIColor.systemPurple.resolvedColor(with: traits).getHue(&h1, saturation: &s1, brightness: &b1, alpha: &a1)
        OptionControls.pressureValueColor.resolvedColor(with: traits).getHue(&h2, saturation: &s2, brightness: &b2, alpha: &a2)
        #expect(abs(h1 - h2) < 0.01 && abs(b1 - b2) < 0.01 && s2 < s1 * 0.6 && s2 > 0.1)
    }

    /// At rest the value is the setting, the most the pressure reaches; under a stroke, the size or opacity it paints at
    /// now, back to the setting as the Pencil lifts. The slider's thumb goes with the field.
    @Test func theValueShowsTheLiveSizeUnderAStroke() throws {
        let session = try session()
        session.brushSettings.pressureOpacity = true
        let pressure = StrokePressure()
        let (bar, _) = bar(for: session, input: try input(.pressure), pressure: pressure)
        let size = try field("Size", in: bar).field, opacity = try field("Opacity", in: bar).field
        let row = try #require(views(SliderField.self, in: bar).first { $0.caption.text == "Opacity" })
        let slider = try #require(views(UISlider.self, in: row).first)
        let sliderValue = slider.value
        #expect(size.text == "40" && opacity.text == "80")

        pressure.value = 0.5
        bar.updatePropertiesIfNeeded()
        #expect(size.text == "20" && opacity.text == "40")
        #expect(abs(slider.value - 0.4) < 1e-6)
        pressure.value = 0.25
        bar.updatePropertiesIfNeeded()
        #expect(size.text == "10" && opacity.text == "20")
        #expect(abs(slider.value - 0.2) < 1e-6)
        pressure.value = nil
        bar.updatePropertiesIfNeeded()
        #expect(size.text == "40" && opacity.text == "80")
        #expect(slider.value == sliderValue)
    }

    /// Set by hand, or outside Pressure Sensitivity, the value stays the setting under a stroke.
    @Test func setByHandTheValueStaysPut() throws {
        for mode in [DrawingInput.Mode.pressure, .pencil] {
            let session = try session()
            let pressure = StrokePressure()
            let (bar, _) = bar(for: session, input: try input(mode), pressure: pressure)
            pressure.value = 0.5
            bar.updatePropertiesIfNeeded()
            #expect(try field("Size", in: bar).field.text == (mode == .pressure ? "20" : "40"), "\(mode)")
            #expect(try field("Opacity", in: bar).field.text == "80", "\(mode)")
        }
    }

    /// The canvas hands the bar the stroke's pressure once a frame, as it draws it, not with each of Apple Pencil's
    /// samples: none while no stroke is down, and none again once it lifts.
    @Test func theCanvasHandsOnThePressureOnceAFrame() throws {
        let session = try session()
        let canvas = PadCanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        canvas.render()
        #expect(canvas.strokePressure.value == nil)
        let input = PadCanvasInput(session: session)
        input.began(at: CGPoint(x: 100, y: 150), pressure: 0.3)
        input.moved(to: CGPoint(x: 120, y: 150), pressure: 0.4)
        input.moved(to: CGPoint(x: 140, y: 150), pressure: 0.6)
        #expect(canvas.strokePressure.value == nil, "not before the frame")
        canvas.render()
        #expect(canvas.strokePressure.value == 0.6)
        input.ended(at: CGPoint(x: 140, y: 150))
        canvas.render()
        #expect(canvas.strokePressure.value == nil)
    }

    /// A pressure the same as the last one shown changes nothing, so the bar isn't updated for it.
    @Test func theSamePressureChangesNothing() throws {
        let pressure = StrokePressure()
        let changes = Counter()
        func watch() {
            withObservationTracking { _ = pressure.value } onChange: { changes.count += 1 }
        }
        watch()
        pressure.value = 0.5
        #expect(changes.count == 1)
        watch()
        pressure.value = 0.5
        #expect(changes.count == 1)
        pressure.value = nil
        #expect(changes.count == 2, "the observation still stands, so it fires now")
    }

    // MARK: VoiceOver

    /// In Pressure Sensitivity each caption is a button saying whether it follows the pressure, with the Mac's help as
    /// its hint, as tooltips don't show on iPad.
    @Test func voiceOverReadsTheCaptionsAsButtons() throws {
        let session = try session()
        let (bar, _) = bar(for: session, input: try input(.pressure))
        let size = try field("Size", in: bar).caption, opacity = try field("Opacity", in: bar).caption
        #expect(size.accessibilityTraits.contains(.button) && opacity.accessibilityTraits.contains(.button))
        #expect(size.accessibilityValue == "Follows Apple Pencil’s pressure")
        #expect(opacity.accessibilityValue == "Set by hand")
        #expect(size.accessibilityHint == "Pen pressure sets the size: a light touch paints a thinner line")
        #expect(opacity.accessibilityHint == "Pen pressure sets the opacity: a light touch paints fainter, up to the brush’s Opacity")
        #expect(size.accessibilityLabel == "Size")
    }

    // MARK: What doesn't follow the pressure

    /// In Pressure Sensitivity, a tap on the caption of a field that can't follow the pressure warns, whole, that it
    /// doesn't and what does: the Brush's Hardness and Smoothing, and every caption of the other brush tools, named by
    /// their bar's title. Nothing changes, and the double tap on the caption still puts the value back.
    @Test func aCaptionThatCantFollowThePressureWarns() throws {
        let only = "doesn’t follow Apple Pencil’s pressure · Only"
        let cases: [(NavigationTool, BrushToolMode, [String], [String])] = [
            (.brush, .paint, ["Hardness", "Smoothing"], [
                "Hardness \(only) Size and Opacity do", "Smoothing \(only) Size and Opacity do"]),
            (.brush, .erase, ["Hardness", "Smoothing"], [
                "Hardness \(only) Size and Opacity do", "Smoothing \(only) Size and Opacity do"]),
            (.spotHealing, .paint, ["Size", "Hardness", "Opacity"], [
                "Spot Healing’s Size \(only) the Brush’s Size and Opacity do",
                "Spot Healing’s Hardness \(only) the Brush’s Size and Opacity do",
                "Spot Healing’s Opacity \(only) the Brush’s Size and Opacity do"]),
            (.cloneStamp, .paint, ["Size", "Hardness", "Opacity"], [
                "Clone Stamp’s Size \(only) the Brush’s Size and Opacity do",
                "Clone Stamp’s Hardness \(only) the Brush’s Size and Opacity do",
                "Clone Stamp’s Opacity \(only) the Brush’s Size and Opacity do"]),
            (.blur, .paint, ["Size", "Hardness", "Strength"], [
                "Smear’s Size \(only) the Brush’s Size and Opacity do",
                "Smear’s Hardness \(only) the Brush’s Size and Opacity do",
                "Smear’s Strength \(only) the Brush’s Size and Opacity do"]),
        ]
        for (tool, mode, captions, warnings) in cases {
            let session = try session(tool)
            session.brushMode = mode
            func state(_ s: BrushSettings) -> [CGFloat] {
                [s.diameter, s.hardness, s.opacity, s.smoothing, s.pressureSize ? 1 : 0, s.pressureOpacity ? 1 : 0]
            }
            let settings = state(session.brushSettings)
            let (bar, flashes) = bar(for: session, input: try input(.pressure))
            for name in captions {
                let caption = try field(name, in: bar).caption
                let taps = (caption.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
                #expect(taps.contains { $0.numberOfTapsRequired == 1 && $0.isEnabled }, "\(tool), \(name)")
                caption.tapped()
                // VoiceOver reads it as the label it was: a word on the side, not a control.
                #expect(!caption.accessibilityActivate() && !caption.accessibilityTraits.contains(.button))
                #expect(caption.accessibilityValue == nil && caption.accessibilityHint == nil && caption.textColor == .secondaryLabel)
                if let slider = views(SliderField.self, in: bar).first(where: { $0.caption === caption }),
                   let double = taps.first(where: { $0.numberOfTapsRequired == 2 }) {
                    slider.onReset = {}
                    #expect(slider.gestureRecognizerShouldBegin(double), "\(tool), \(name)")
                }
            }
            #expect(flashes.warnings == warnings, "\(tool), \(mode)")
            #expect(flashes.messages.isEmpty && state(session.brushSettings) == settings)
        }
    }

    /// Smear's Blur mode has a Radius of its own, which warns too.
    @Test func smearsRadiusWarnsToo() throws {
        let session = try session(.blur)
        session.blurMode = .blur
        let (bar, flashes) = bar(for: session, input: try input(.pressure))
        try field("Radius", in: bar).caption.tapped()
        #expect(flashes.warnings == ["Smear’s Radius doesn’t follow Apple Pencil’s pressure · Only the Brush’s Size and Opacity do"])
    }

    /// Outside Pressure Sensitivity, those captions are plain labels: a tap says nothing.
    @Test func outsidePressureSensitivityNothingWarns() throws {
        for (mode, pressure) in [(DrawingInput.Mode.pencil, true), (.finger, true), (.pencil, false), (.finger, false)] {
            for tool in [NavigationTool.brush, .spotHealing, .cloneStamp, .blur] {
                let session = try session(tool)
                let (bar, flashes) = bar(for: session, input: try input(mode, pressure: pressure))
                for caption in views(FieldCaption.self, in: bar) {
                    caption.tapped()
                    let taps = (caption.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
                    #expect(taps.allSatisfy { $0.numberOfTapsRequired != 1 || !$0.isEnabled }, "\(tool), \(mode)")
                }
                #expect(flashes.warnings.isEmpty && flashes.messages.isEmpty, "\(tool), \(mode), \(pressure)")
            }
        }
    }

    /// Switching into Pressure Sensitivity and out again turns the warning on and off without building the bar again.
    @Test func theWarningFollowsTheMode() throws {
        let session = try session()
        let input = try input(.pencil)
        let (bar, flashes) = bar(for: session, input: input)
        let hardness = try field("Hardness", in: bar).caption
        hardness.tapped()
        input.mode = .pressure
        update(bar)
        #expect(try field("Hardness", in: bar).caption === hardness)
        hardness.tapped()
        input.mode = .finger
        update(bar)
        hardness.tapped()
        #expect(flashes.warnings == ["Hardness doesn’t follow Apple Pencil’s pressure · Only Size and Opacity do"])
    }

    // MARK: The status line

    /// A flash in the color it's given, purple for the pressure, as the captions are.
    @Test func theStatusLineFlashesInTheColorGiven() async throws {
        let session = try session()
        let status = StatusBarView(frame: CGRect(x: 0, y: 0, width: 1000, height: StatusBarView.height))
        status.session = session
        status.updatePropertiesIfNeeded()
        let hint = try #require(views(UILabel.self, in: status).last)
        let usual = try #require(hint.text)
        status.flash("Apple Pencil’s pressure sets the size", color: .systemPurple, for: .milliseconds(100))
        #expect(hint.text == "Apple Pencil’s pressure sets the size" && hint.textColor == .systemPurple)
        try await Task.sleep(for: .milliseconds(500))
        status.updatePropertiesIfNeeded()
        #expect(hint.text == usual && hint.textColor == .secondaryLabel)
        status.flash("Draw with fingers and Apple Pencil", for: .milliseconds(100))
        #expect(hint.textColor == .tintColor)
    }

    /// The window flashes the bar's words in purple.
    @Test func theWindowFlashesTheBarsWordsInPurple() throws {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let options = try #require(views(ToolOptionsBar.self, in: window.view).first)
        let status = try #require(views(StatusBarView.self, in: window.view).first)
        options.onFlash("Apple Pencil’s pressure sets the size · Tap the Size label to set it yourself")
        #expect(status.flashed == "Apple Pencil’s pressure sets the size · Tap the Size label to set it yourself")
        #expect(status.flashedColor == .systemPurple)
    }

    /// And warns in orange what can't follow the pressure.
    @Test func theWindowWarnsInOrange() throws {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let options = try #require(views(ToolOptionsBar.self, in: window.view).first)
        let status = try #require(views(StatusBarView.self, in: window.view).first)
        options.onWarn("Hardness doesn’t follow Apple Pencil’s pressure · Only Size and Opacity do")
        #expect(status.flashed == "Hardness doesn’t follow Apple Pencil’s pressure · Only Size and Opacity do")
        #expect(status.flashedColor == .systemOrange)
    }
}
