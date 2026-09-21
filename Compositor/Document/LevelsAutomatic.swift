import AppKit

nonisolated enum LevelsSample: String, CaseIterable {
    case black = "Black", gray = "Gray", white = "White"
    /// The localized menu/picker title. The raw value stays English (it doubles as a stable identifier).
    var displayName: String {
        switch self {
        case .black: String(localized: "Black")
        case .gray: String(localized: "Gray")
        case .white: String(localized: "White")
        }
    }
}
nonisolated enum LevelsAuto: String, CaseIterable {
    case contrast = "Contrast", color = "Color", neutral = "Color + neutral midtones"

    /// The localized menu/picker title. The raw value stays English (it doubles as a stable identifier).
    var displayName: String {
        switch self {
        case .contrast: String(localized: "Contrast")
        case .color: String(localized: "Color")
        case .neutral: String(localized: "Color + neutral midtones")
        }
    }
    func settings(histogram: [[Double]]) -> LevelsSettings {
        var result = LevelsSettings()
        func endpoints(_ bins: [Double]) -> (Double, Double)? {
            let total = bins.reduce(0, +)
            guard total > 0 else { return nil }
            var sum = 0.0, low = 0, high = 255
            for i in 0..<256 { sum += bins[i]; if sum > total * 0.001 { low = i; break } }
            sum = 0
            for i in (0..<256).reversed() { sum += bins[i]; if sum > total * 0.001 { high = i; break } }
            return low < high ? (Double(low), Double(high)) : nil
        }
        if self == .contrast {
            // A shared interval preserves channel relationships.
            let limits = histogram.dropFirst().compactMap(endpoints)
            if let low = limits.map({ $0.0 }).min(), let high = limits.map({ $0.1 }).max(), low < high {
                result.ranges[0] = LevelRange(black: low, white: high)
            }
        } else {
            for c in 1...3 {
                guard let (low, high) = endpoints(histogram[c]) else { continue }
                var range = LevelRange(black: low, white: high)
                if self == .neutral {
                    let total = histogram[c].reduce(0, +)
                    let mean = histogram[c].enumerated().reduce(0.0) { $0 + range.apply(Double($1.offset)/255) * $1.element } / total
                    if mean > 0 && mean < 1 { range.gamma = min(9.99, max(0.1, log(mean) / log(0.5))) }
                }
                result.ranges[c] = range
            }
        }
        return result
    }
}

extension LevelsSettings {
    /// Samples are unpremultiplied original RGB. All three channels are calibrated together.
    func sampling(_ rgb: [Double], mode: LevelsSample) -> Self {
        var result = self
        result.ranges[0] = LevelRange()
        for c in 1...3 {
            var range = result.ranges[c]
            let v = rgb[c-1] * 255
            switch mode {
            case .black: range.black = min(range.white - 1, max(0, v))
            case .white: range.white = max(range.black + 1, min(255, v))
            case .gray:
                let fraction = (v - range.black) / (range.white - range.black)
                guard fraction > 0 && fraction < 1 else { continue }
                range.gamma = log(fraction) / log(0.5)
            }
            range.outputBlack = 0; range.outputWhite = 255
            result.ranges[c] = range.normalized
        }
        return result
    }
}

extension EditorSession {
    func autoLevels(_ mode: LevelsAuto) {
        guard let edit = levels, edit.histogramReady, !edit.committing else { return }
        edit.sampleMode = nil
        updateLevels(mode.settings(histogram: edit.histogram), preview: edit.preview)
    }
    func sampleLevels(at point: CGPoint) {
        guard let edit = levels, let mode = edit.sampleMode, !edit.committing,
              let document, CGRect(origin: .zero, size: document.size).contains(point) else { return }
        let pixel = point.applying(edit.mapping.inverted())
        let rect = CGRect(x: floor(pixel.x), y: floor(pixel.y), width: 1, height: 1)
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(edit.original.image.width),
              pixel.y < CGFloat(edit.original.image.height), let sample = edit.original.image.cropping(to: rect) else { return }
        do {
            let context = try BrushRaster.context(width: 1, height: 1, mask: false)
            BrushRaster.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: context)
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            guard bytes[3] > 0 else { return }
            let rgb = (0..<3).map { min(1, Double(bytes[$0]) / Double(bytes[3])) }
            updateLevels(edit.settings.sampling(rgb, mode: mode), preview: edit.preview)
        } catch { brushError = error.localizedDescription }
    }
}
