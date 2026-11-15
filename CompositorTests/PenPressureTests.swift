import AppKit
import Testing
import IOKit.hidsystem
@testable import Compositor

@MainActor
struct PenPressureTests {
    private func session(hardness: CGFloat = 1) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 300, height: 100)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 40, hardness: hardness, red: 1, green: 0, blue: 0)
        return session
    }

    /// The canvas as exported, and one pixel's alpha from it.
    private func canvas(_ session: EditorSession) async throws -> NSBitmapImageRep {
        NSBitmapImageRep(cgImage: try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
    }
    private func alpha(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> Int {
        var pixel = [Int](repeating: 0, count: 4)
        bitmap.getPixel(&pixel, atX: x, y: y)
        return pixel[3]
    }
    /// How many rows of column `x` the stroke covers.
    private func thickness(_ bitmap: NSBitmapImageRep, _ x: Int) -> Int {
        (0..<bitmap.pixelsHigh).filter { alpha(bitmap, x, $0) > 127 }.count
    }

    /// A left-to-right stroke along y = 50, its pressure easing from `from` to `to`.
    private func stroke(_ session: EditorSession, from: CGFloat?, to: CGFloat?) {
        session.beginBrush(at: CGPoint(x: 30, y: 50), pressure: from)
        for step in 1...24 {
            let t = CGFloat(step) / 24
            session.continueBrush(at: CGPoint(x: 30 + 240 * t, y: 50), pressure: from.map { $0 + ((to ?? $0) - $0) * t })
        }
        session.finishBrushImmediately()
    }

    @Test func pressureSetsTheSizeWhenAsked() async throws {
        let session = session()
        session.brushSettings.pressureSize = true
        stroke(session, from: 1, to: 0.25)
        let bitmap = try await canvas(session)
        let start = thickness(bitmap, 40), end = thickness(bitmap, 260)
        #expect(abs(start - 40) <= 3, "full pressure paints the full size")
        #expect(end < 16 && end >= 8, "a quarter of the pressure, about a quarter of the size: \(end)")
        #expect(thickness(bitmap, 150) < start && thickness(bitmap, 150) > end)
    }

    @Test func pressureSetsTheOpacityAndTheStrokeNeverPassesItsFirmestPress() async throws {
        for hardness: CGFloat in [1, 0] {
            let session = session(hardness: hardness)
            session.brushSettings.pressureOpacity = true
            stroke(session, from: 0.5, to: 0.5)
            let bitmap = try await canvas(session)
            // The middle of the line, well inside a soft tip's full-strength center once dabs have built up.
            #expect(abs(alpha(bitmap, 150, 50) - 128) <= 4, "hardness \(hardness): \(alpha(bitmap, 150, 50))")
        }
    }

    @Test func aMouseOrTheButtonsOffPaintAsBefore() async throws {
        let plain = session()
        stroke(plain, from: nil, to: nil)
        let expected = try await canvas(plain)
        // Buttons on, but a mouse: no pressure to follow.
        let mouse = session()
        mouse.brushSettings.pressureSize = true
        mouse.brushSettings.pressureOpacity = true
        stroke(mouse, from: nil, to: nil)
        // A pen, with the buttons off: its pressure is ignored.
        let pen = session()
        stroke(pen, from: 0.2, to: 0.6)
        for other in [try await canvas(mouse), try await canvas(pen)] {
            #expect(other.representation(using: .png, properties: [:]) == expected.representation(using: .png, properties: [:]))
        }
    }

    /// The release carries no pressure: the stroke ends at the last pen pressure, not a full-size blot.
    @Test func theReleaseKeepsTheLastPressure() async throws {
        let session = session()
        session.brushSettings.pressureSize = true
        session.brushSettings.smoothing = 30
        stroke(session, from: 0.25, to: 0.25)
        let bitmap = try await canvas(session)
        #expect((0..<300).map { thickness(bitmap, $0) }.max()! < 16)
    }

    /// Only a tablet's events carry a pressure to follow; a mouse's, even pressed hard on a Force Touch trackpad, don't.
    @Test func theCanvasReadsPressureFromATabletOnly() throws {
        func event(tablet: Bool, pressure: Double) throws -> NSEvent {
            let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                              mouseCursorPosition: .zero, mouseButton: .left))
            event.setDoubleValueField(.mouseEventPressure, value: pressure)
            if tablet { event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue)) }
            return try #require(NSEvent(cgEvent: event))
        }
        #expect(abs(try #require(PenInput().sample(try event(tablet: true, pressure: 0.3)).pressure) - 0.3) < 0.01)
        #expect(PenInput().sample(try event(tablet: false, pressure: 0.3)).pressure == nil)
    }

    private func tabletEvent(device: Int = 71, pressure: Double = 0.4, tilt: CGPoint = .zero,
                             rotation: Double = 0, native: Bool = true, time: Double = 10) throws -> NSEvent {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
            mouseCursorPosition: .zero, mouseButton: .left))
        if native { event.type = .tabletPointer }
        else { event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue)) }
        event.setIntegerValueField(.tabletEventDeviceID, value: Int64(device))
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.setDoubleValueField(.tabletEventTiltX, value: Double(tilt.x))
        event.setDoubleValueField(.tabletEventTiltY, value: Double(tilt.y))
        event.setDoubleValueField(.tabletEventRotation, value: rotation)
        event.timestamp = UInt64(time * 1_000_000_000)
        return try #require(NSEvent(cgEvent: event))
    }

    @Test func tabletEraserEndIsReportedOnlyForTabletPoints() throws {
        let event = try tabletEvent()
        #expect(PenInput.isTabletPoint(event))
        #expect(event.pointingDeviceType == .unknown || event.pointingDeviceType == .pen)
        let mouse = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 11, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!PenInput.isTabletPoint(mouse))
    }

    @Test func tabletChannelsRequireValidEventsAndDeviceCapabilities() throws {
        let pen = PenInput()
        let mask = Int(NX_TABLET_CAPABILITY_PRESSUREMASK | NX_TABLET_CAPABILITY_TILTXMASK
            | NX_TABLET_CAPABILITY_TILTYMASK | NX_TABLET_CAPABILITY_ROTATIONMASK)
        pen.proximity(deviceID: 71, mask: mask, entering: true)
        for native in [true, false] {
            let sample = pen.sample(try tabletEvent(tilt: CGPoint(x: 0.2, y: -0.3), rotation: 90, native: native))
            #expect(abs(sample.effectivePressure - 0.4) < 0.01)
            #expect(abs(try #require(sample.tilt).x - 0.2) < 0.01)
            #expect(abs(try #require(sample.rotation) - .pi / 2) < 0.01)
            #expect(sample.timestamp == 10 && sample.deviceID == 71)
        }
        let upright = pen.sample(try tabletEvent())
        #expect(upright.tilt == .zero && upright.rotation == 0, "A reported zero is valid, not missing support")
        pen.proximity(deviceID: 72, mask: Int(NX_TABLET_CAPABILITY_PRESSUREMASK), entering: true)
        let limited = pen.sample(try tabletEvent(device: 72, tilt: CGPoint(x: 0.5, y: 0.5), rotation: 45))
        #expect(limited.tilt == nil && limited.rotation == nil)
        let mouse = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: .zero, modifierFlags: [],
            timestamp: 11, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0.8))
        let fallback = pen.sample(mouse)
        #expect(fallback.pressure == nil && fallback.effectivePressure == 1 && fallback.tilt == nil && fallback.rotation == nil)
        pen.proximity(deviceID: 72, mask: 0, entering: false)
        #expect(!pen.capabilities.pressure && pen.lastInput == nil)
        pen.proximity(deviceID: 71, mask: mask, entering: true)
        #expect(pen.capabilities.tilt && pen.capabilities.rotation)
        let noMask = PenInput()
        noMask.proximity(deviceID: 71, mask: 0, entering: true)
        let unknown = noMask.sample(try tabletEvent())
        #expect(unknown.pressure != nil && unknown.tilt == nil && unknown.rotation == nil)
        let invalid = BrushInput(pressure: .nan, tilt: CGPoint(x: CGFloat.infinity, y: 0), rotation: .nan, timestamp: -Double.infinity)
        #expect(invalid.pressure == nil && invalid.tilt == nil && invalid.rotation == nil && invalid.timestamp == nil)
    }

    @Test func pressurelessTiltAndRotationProfilesUseOnlyReportedChannels() throws {
        let pen = PenInput()
        // Pressureless/tilt-capable input (e.g. Pencil USB-C via a bridge) must not become a zero-pressure brush.
        pen.proximity(deviceID: 71, mask: Int(NX_TABLET_CAPABILITY_TILTXMASK | NX_TABLET_CAPABILITY_TILTYMASK), entering: true)
        let tiltOnly = pen.sample(try tabletEvent(pressure: 0, tilt: CGPoint(x: 0.2, y: -0.4), rotation: 30))
        #expect(tiltOnly.pressure == nil && tiltOnly.effectivePressure == 1)
        #expect(tiltOnly.tilt != nil && tiltOnly.rotation == nil)
        var mapping = BrushPreset(name: "Stored pressure mapping")
        mapping.pressureSize = true; mapping.pressureOpacity = true
        pen.proximity(deviceID: 71, mask: 0, entering: false)
        #expect(mapping.pressureSize && mapping.pressureOpacity)
        // Pro-style barrel input still requires the bridge to report support; branding is never consulted.
        pen.proximity(deviceID: 71, mask: Int(NX_TABLET_CAPABILITY_ROTATIONMASK), entering: true)
        let barrel = pen.sample(try tabletEvent(rotation: 180))
        #expect(barrel.rotation != nil && barrel.pressure == nil && barrel.tilt == nil)
    }

    @Test func interpolationAndCalibrationPreserveMissingChannelsAndUprightTilt() throws {
        let start = BrushInput(pressure: 0.2, tilt: CGPoint(x: -0.5, y: 0.5), rotation: 179 * .pi / 180, timestamp: 10, deviceID: 1)
        let end = BrushInput(pressure: 0.8, tilt: CGPoint(x: 0.5, y: -0.5), rotation: -179 * .pi / 180, timestamp: 12, deviceID: 1)
        #expect(start.interpolated(to: end, fraction: 0) == start)
        #expect(BrushInput(timestamp: 10, deviceID: 1).interpolated(to: end, fraction: 1) == end)
        let middle = start.interpolated(to: end, fraction: 0.5)
        #expect(abs(middle.effectivePressure - 0.5) < 0.001 && middle.tilt == .zero)
        #expect(abs(abs(try #require(middle.rotation)) - .pi) < 0.001 && middle.timestamp == 11)
        let absent = start.interpolated(to: BrushInput(timestamp: 9, deviceID: 1), fraction: 0.5)
        #expect(absent.tilt == nil && absent.rotation == nil && absent.timestamp == 10)
        let switched = start.interpolated(to: BrushInput(pressure: 0.8, deviceID: 2), fraction: 0.5)
        #expect(switched.pressure == nil && switched.tilt == nil && switched.rotation == nil)
        let pen = PenInput()
        pen.proximity(deviceID: 71, mask: Int(NX_TABLET_CAPABILITY_PRESSUREMASK | NX_TABLET_CAPABILITY_TILTXMASK
            | NX_TABLET_CAPABILITY_TILTYMASK | NX_TABLET_CAPABILITY_ROTATIONMASK), entering: true)
        let event = try tabletEvent(tilt: CGPoint(x: 0.1, y: -0.2), rotation: 25)
        _ = pen.sample(event)
        pen.zeroTilt(); pen.zeroBarrelRotation()
        let zeroed = pen.sample(event)
        let zeroTilt = try #require(zeroed.tilt)
        #expect(abs(zeroTilt.x) < 0.002 && abs(zeroTilt.y) < 0.002)
        #expect(abs(try #require(zeroed.rotation)) < 0.002)
        pen.reverseTiltX = true; pen.reverseRotation = true
        let reversed = pen.sample(try tabletEvent(tilt: CGPoint(x: 0.3, y: -0.2), rotation: 45))
        let reversedTilt = try #require(reversed.tilt)
        let reversedAngle = try #require(reversed.rotation)
        #expect(reversedTilt.x < -0.19 && reversedAngle < 0)
        pen.resetCalibration()
        #expect(!pen.reverseTiltX && !pen.reverseRotation)
    }

    @Test func stationaryPressureReachesBothRenderersAndKeepsMetadata() throws {
        for gpu in [false, true] {
            for hardness: CGFloat in [0, 1] {
                let document = CanvasDocument(width: 100, height: 100)
                var settings = BrushSettings(diameter: 40, hardness: hardness)
                settings.pressureSize = true; settings.pressureOpacity = true
                let stroke = try BrushStroke(layer: ImageLayer(name: "Blank", blankSize: document.size), mask: false,
                    settings: settings, canvas: document.size, useGPU: gpu)
                let point = CGPoint(x: 50, y: 50)
                try stroke.append(point, input: BrushInput(pressure: 0.2, timestamp: 10, deviceID: 71))
                try stroke.append(point, input: BrushInput(pressure: 1, tilt: .zero, rotation: 0.5, timestamp: 9, deviceID: 71))
                #expect(stroke.lastInput?.timestamp == 10 && stroke.lastInput?.tilt == .zero && stroke.lastInput?.rotation == 0.5)
                try stroke.append(point, input: BrushInput(pressure: 1, deviceID: 71))
                try stroke.append(point, input: BrushInput(pressure: 1, timestamp: 8, deviceID: 71))
                #expect(stroke.lastInput?.timestamp == 10, "Missing timestamps must not reset the monotonic clock")
                try stroke.flush()
                let snapshot = try stroke.paintSnapshot()
                #expect(snapshot.asset.image.width >= 38, "Stationary pressure must grow the tip, GPU requested: \(gpu)")
                let bitmap = NSBitmapImageRep(cgImage: snapshot.asset.image)
                #expect(alpha(bitmap, 50 - Int(snapshot.transform.origin.x), 50 - Int(snapshot.transform.origin.y)) > 230)
            }
        }
        let session = session()
        session.brushSettings.pressureSize = true; session.brushSettings.smoothing = 30
        session.beginBrush(at: CGPoint(x: 50, y: 50), input: BrushInput(pressure: 0.2, timestamp: 10, deviceID: 71))
        session.continueBrush(at: CGPoint(x: 50, y: 50), input: BrushInput(pressure: 1, tilt: .zero, timestamp: 11, deviceID: 71))
        #expect(session.brushStroke?.lastInput?.pressure == 1 && session.brushStroke?.lastInput?.timestamp == 11)
        session.continueBrush(at: CGPoint(x: 60, y: 50), input: BrushInput(pressure: 0.1, timestamp: 12, deviceID: 72))
        #expect(session.brushInput.deviceID == 71 && session.brushInput.pressure == 1)
        let view = CanvasView(session: session)
        view.tabletPoint(with: try tabletEvent(device: 72, pressure: 0.1))
        #expect(session.brushStroke?.lastInput?.pressure == 1, "A second pen must not change the active stroke")
        view.tabletPoint(with: try tabletEvent(pressure: 0.4))
        try session.flushQueuedBrushInputSamples()
        #expect(abs(try #require(session.brushStroke?.lastInput).effectivePressure - 0.4) < 0.01)
        #expect(session.brushPointer == CGPoint(x: 50, y: 50), "A windowless native event must retain the known cursor position")
        session.cancelBrush()
        let preview = BrushDrawingView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        preview.beginStroke(at: CGPoint(x: 50, y: 50), input: BrushInput(pressure: 0.2, tilt: CGPoint(x: 0.1, y: 0.2), timestamp: 1, deviceID: 71))
        preview.continueStroke(at: CGPoint(x: 60, y: 50), input: BrushInput(pressure: 1, tilt: .zero, timestamp: 2, deviceID: 71))
        #expect(preview.session.brushStroke?.lastInput?.tilt == .zero)
        preview.endStroke(); preview.reset(clearing: false)
        #expect(preview.session.activeLayer?.asset != nil)
    }

    /// Without Metal, the dabs follow the pressure the same way.
    @Test func theSoftwareBrushFollowsThePressureToo() throws {
        let document = CanvasDocument(width: 300, height: 100)
        var settings = BrushSettings(diameter: 40, hardness: 1, red: 1, green: 0, blue: 0)
        settings.pressureSize = true
        let layer = ImageLayer(name: "Blank", blankSize: document.size)
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: document.size, useGPU: false)
        for step in 0...24 {
            let t = CGFloat(step) / 24
            try stroke.append(CGPoint(x: 30 + 240 * t, y: 50), pressure: 1 - 0.75 * t)
        }
        try stroke.flush()
        let snapshot = try stroke.paintSnapshot()
        // Painted only where the line went: a stroke that thins as it goes is taller at its start than its end.
        let image = snapshot.asset.image, bitmap = NSBitmapImageRep(cgImage: image)
        let origin = snapshot.transform.origin
        func rows(_ x: Int) -> Int { (0..<image.height).filter { alpha(bitmap, x - Int(origin.x), $0) > 127 }.count }
        #expect(abs(rows(40) - 40) <= 3 && rows(260) < 16)
    }
}
