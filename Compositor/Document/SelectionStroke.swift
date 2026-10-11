import AppKit

/// Where Edit › Stroke draws against the selection's outline, as in Photoshop.
nonisolated enum StrokeLocation: String, CaseIterable, Sendable {
    case inside = "Inside", center = "Center", outside = "Outside"
}

/// Edit › Stroke's settings.
nonisolated struct StrokeOptions: Equatable, Sendable {
    static let widthRange: ClosedRange<Double> = 1...250
    /// Document pixels.
    var width: Double = 1
    var location: StrokeLocation = .center
    var source: EditorSession.FillSource = .foreground
    /// 0…1.
    var opacity: Double = 1

    /// The area the stroke covers: a band `width` wide centered on `outline`, or twice that for Inside and Outside,
    /// which keep one half of it. Outside rounds its corners and Inside and Center keep them sharp, as Photoshop's do.
    func region(around outline: CGPath) -> CGPath {
        let band = location == .center ? width : width * 2
        return outline.copy(strokingWithWidth: band, lineCap: .butt,
                            lineJoin: location == .outside ? .round : .miter, miterLimit: 10)
    }
}

extension EditorSession {
    /// Edit › Stroke needs an outline to follow and a layer (or mask) to paint.
    var canStrokeSelection: Bool { selection != nil && canEditPixels }

    /// Paints a line along the selection's outline, on the active layer or its mask, as one undo step. The line
    /// isn't limited to the selection: Outside and Center paint past it. On a mask the palette is black and white.
    func strokeSelection(_ options: StrokeOptions) async {
        guard canStrokeSelection, let layer = activeLayer, let outline = selection?.path,
              StrokeOptions.widthRange.contains(options.width), (0...1).contains(options.opacity) else { return }
        let value = paletteColor(background: options.source == .background)
        let color = isMaskSelected
            ? CGColor(gray: value.red, alpha: 1)
            : CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [value.red, value.green, value.blue, 1])!
        finishOpacityEdit()
        do {
            // The stroke follows the outline rather than filling it, so the selection mustn't clip it.
            let edit = try makeRasterEdit(for: layer, growsMask: true, clipsToSelection: false)
            try edit.stroke(options.region(around: outline), keeping: options.location, of: outline,
                            color: color, opacity: options.opacity)
            guard !edit.patches.isEmpty else { return }
            try await commitRasterEdit(edit, name: isMaskSelected ? "Stroke Mask" : "Stroke")
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }
}