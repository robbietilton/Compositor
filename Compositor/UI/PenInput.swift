import AppKit
import Observation
import IOKit.hidsystem

/// Driver-reported channels for the pen currently in range. Saved brush mappings never depend on this state.
@MainActor @Observable final class PenInput {
    struct Capabilities: Equatable {
        var pressure = false
        var tilt = false
        var rotation = false
        init(mask: Int = 0) {
            pressure = mask & Int(NX_TABLET_CAPABILITY_PRESSUREMASK) != 0
            tilt = mask & Int(NX_TABLET_CAPABILITY_TILTXMASK) != 0 && mask & Int(NX_TABLET_CAPABILITY_TILTYMASK) != 0
            rotation = mask & Int(NX_TABLET_CAPABILITY_ROTATIONMASK) != 0
        }
    }
    static let shared = PenInput(monitorEvents: true)
    private(set) var devices: [Int: Capabilities] = [:]
    private(set) var activeDeviceID: Int?
    private(set) var lastInput: BrushInput?
    private(set) var rawInput: BrushInput?
    var capabilities: Capabilities { activeDeviceID.flatMap { devices[$0] } ?? Capabilities() }
    @ObservationIgnored private var monitor: Any?

    // App-wide calibration; sensor-space tilt stays a vector, including near upright (no invented azimuth).
    private var zeroX = ToolDefaults.int("pen.zeroX", 0) { didSet { ToolDefaults.set(zeroX, "pen.zeroX") } }
    private var zeroY = ToolDefaults.int("pen.zeroY", 0) { didSet { ToolDefaults.set(zeroY, "pen.zeroY") } }
    private var zeroRotation = ToolDefaults.int("pen.zeroRotation", 0) { didSet { ToolDefaults.set(zeroRotation, "pen.zeroRotation") } }
    var reverseTiltX = ToolDefaults.bool("pen.reverseTiltX", false) { didSet { ToolDefaults.set(reverseTiltX, "pen.reverseTiltX") } }
    var reverseTiltY = ToolDefaults.bool("pen.reverseTiltY", false) { didSet { ToolDefaults.set(reverseTiltY, "pen.reverseTiltY") } }
    var reverseRotation = ToolDefaults.bool("pen.reverseRotation", false) { didSet { ToolDefaults.set(reverseRotation, "pen.reverseRotation") } }

    init(monitorEvents: Bool = false) {
        if monitorEvents {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.tabletProximity, .tabletPoint, .mouseMoved,
                .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                .otherMouseDown, .otherMouseDragged, .otherMouseUp]) { event in
                MainActor.assumeIsolated { self.observe(event) }
                return event
            }
        }
    }
    static func install() { _ = shared }

    static func isTabletPoint(_ event: NSEvent) -> Bool {
        event.type == .tabletPoint || (isMouse(event) && event.subtype == .tabletPoint)
    }
    private static func isMouse(_ event: NSEvent) -> Bool {
        [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged,
         .rightMouseUp, .otherMouseDown, .otherMouseDragged, .otherMouseUp].contains(event.type)
    }
    func observe(_ event: NSEvent) {
        if event.type == .tabletProximity || (Self.isMouse(event) && event.subtype == .tabletProximity) {
            proximity(deviceID: event.deviceID, mask: event.capabilityMask, entering: event.isEnteringProximity)
        } else if Self.isTabletPoint(event) { _ = sample(event) }
    }
    func proximity(deviceID: Int, mask: Int, entering: Bool) {
        if entering {
            if mask == 0 { devices.removeValue(forKey: deviceID) }
            else { devices[deviceID] = Capabilities(mask: mask) }
            activeDeviceID = deviceID
            rawInput = nil; lastInput = nil
        } else if activeDeviceID == deviceID {
            activeDeviceID = nil
            rawInput = nil; lastInput = nil
        }
    }
    func sample(_ event: NSEvent) -> BrushInput {
        guard Self.isTabletPoint(event) else { return BrushInput(timestamp: event.timestamp) }
        let id = event.deviceID
        // A driver may omit proximity. Accept pressure on a valid tablet event, but never infer tilt/rotation from zeros.
        if devices[id] == nil {
            var observed = Capabilities()
            observed.pressure = event.pressure.isFinite
            devices[id] = observed
        }
        activeDeviceID = id
        let available = devices[id]!
        let raw = BrushInput(pressure: available.pressure ? CGFloat(event.pressure) : nil,
            tilt: available.tilt ? event.tilt : nil,
            rotation: available.rotation ? CGFloat(event.rotation) * .pi / 180 : nil,
            timestamp: event.timestamp, deviceID: id)
        rawInput = raw
        let tilt = raw.tilt.map { CGPoint(
            x: min(1, max(-1, ($0.x - CGFloat(zeroX) / 1000) * (reverseTiltX ? -1 : 1))),
            y: min(1, max(-1, ($0.y - CGFloat(zeroY) / 1000) * (reverseTiltY ? -1 : 1)))) }
        let input = BrushInput(pressure: raw.pressure, tilt: tilt,
            rotation: raw.rotation.map { ($0 - CGFloat(zeroRotation) * .pi / 180_000) * (reverseRotation ? -1 : 1) },
            timestamp: raw.timestamp, deviceID: id)
        lastInput = input
        return input
    }
    func zeroTilt() {
        guard let tilt = rawInput?.tilt else { return }
        zeroX = Int((tilt.x * 1000).rounded()); zeroY = Int((tilt.y * 1000).rounded())
    }
    func zeroBarrelRotation() {
        guard let angle = rawInput?.rotation else { return }
        zeroRotation = Int((angle * 180_000 / .pi).rounded())
    }
    func resetCalibration() {
        zeroX = 0; zeroY = 0; zeroRotation = 0
        reverseTiltX = false; reverseTiltY = false; reverseRotation = false
    }
}
