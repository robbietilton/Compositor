import AppKit

/// Physical histogram regions, independent of the bins and the interface language.
enum CameraRawHistogramZone: Int, CaseIterable, Identifiable {
    case blacks, shadows, exposure, highlights, whites

    var id: Int { rawValue }
    var key: WritableKeyPath<CameraRawSettings, Double> {
        switch self {
        case .blacks: \.blacks
        case .shadows: \.shadows
        case .exposure: \.exposure
        case .highlights: \.highlights
        case .whites: \.whites
        }
    }
    var title: String {
        switch self {
        case .blacks: AppLocalization.string("Blacks")
        case .shadows: AppLocalization.string("Shadows")
        case .exposure: AppLocalization.string("Exposure")
        case .highlights: AppLocalization.string("Highlights")
        case .whites: AppLocalization.string("Whites")
        }
    }
    var identifier: String {
        switch self {
        case .blacks: "blacks"
        case .shadows: "shadows"
        case .exposure: "exposure"
        case .highlights: "highlights"
        case .whites: "whites"
        }
    }
    var range: ClosedRange<Double> { self == .exposure ? CameraRawSettings.exposureRange : CameraRawSettings.toneRange }
    var decimals: Int { self == .exposure ? 2 : 0 }
    var sensitivity: Double { self == .exposure ? 0.01 : 1 }
    var clipping: CameraRawClipping { self == .blacks || self == .shadows ? .shadows : .highlights }

    static func at(x: CGFloat, width: CGFloat) -> Self? {
        guard width.isFinite, width > 0, x.isFinite, x >= 0, x <= width else { return nil }
        return Self(rawValue: min(allCases.count - 1, Int(x / width * CGFloat(allCases.count))))
    }

    func value(from start: Double, translation: CGFloat) -> Double? {
        guard start.isFinite, translation.isFinite else { return nil }
        let proposed = start + Double(translation) * sensitivity
        guard proposed.isFinite else { return nil }
        let bounded = min(range.upperBound, max(range.lowerBound, proposed))
        let scale = pow(10, Double(decimals))
        return (bounded * scale).rounded() / scale
    }

    func readout(_ settings: CameraRawSettings) -> String {
        let number = settings[keyPath: key].formatted(.number.precision(.fractionLength(decimals)))
        return self == .exposure ? AppLocalization.format("%1$@ EV", number) : number
    }
}

/// One gesture owns one edit and one baseline. A stale callback never starts editing a replacement draft.
struct CameraRawHistogramDrag {
    let edit: FilterEdit
    let zone: CameraRawHistogramZone
    let startValue: Double
    private(set) var finished = false
    private var ownsClipping = false
    private var previousClipping: CameraRawClipping?

    init?(edit: FilterEdit, zone: CameraRawHistogramZone) {
        guard edit.kind == .cameraRaw, edit.cameraRawScopeMode == .histogram, !edit.committing,
              edit.settings.cameraRaw[keyPath: zone.key].isFinite else { return nil }
        self.edit = edit
        self.zone = zone
        startValue = edit.settings.cameraRaw[keyPath: zone.key]
    }

    @discardableResult
    mutating func update(translation: CGFloat, option: Bool = false, in session: EditorSession) -> Bool {
        guard !finished else { return false }
        guard session.filterEdit === edit, !edit.committing, edit.cameraRawScopeMode == .histogram else {
            finish(in: session)
            return false
        }
        guard let value = zone.value(from: startValue, translation: translation) else { return false }
        let oldClipping = edit.cameraRawClipping
        if option {
            if !ownsClipping { previousClipping = oldClipping }
            ownsClipping = true
            edit.cameraRawClipping = zone.clipping
        } else {
            restoreClipping()
        }
        // Read the current settings, not a snapshot: other controls may have changed during the gesture.
        var settings = edit.settings
        settings.cameraRaw[keyPath: zone.key] = value
        if settings != edit.settings || oldClipping != edit.cameraRawClipping {
            session.updateFilter(settings, preview: edit.preview)
        }
        return true
    }

    mutating func finish(in session: EditorSession) {
        guard !finished else { return }
        finished = true
        guard session.filterEdit === edit, !edit.committing else { return }
        let oldClipping = edit.cameraRawClipping
        restoreClipping()
        if oldClipping != edit.cameraRawClipping { session.updateFilter(edit.settings, preview: edit.preview) }
    }

    private mutating func restoreClipping() {
        guard ownsClipping else { return }
        if edit.cameraRawClipping == zone.clipping { edit.cameraRawClipping = previousClipping }
        ownsClipping = false
        previousClipping = nil
    }

    static func adjust(_ zone: CameraRawHistogramZone, increment: Bool, edit: FilterEdit, in session: EditorSession) {
        guard var drag = Self(edit: edit, zone: zone) else { return }
        drag.update(translation: increment ? 1 : -1, in: session)
        drag.finish(in: session)
    }
}
