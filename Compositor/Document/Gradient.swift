import AppKit

nonisolated enum GradientStyle: String, CaseIterable, Sendable {
    case foregroundToBackground = "Foreground to Background"
    case foregroundToTransparent = "Foreground to Transparent"
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
}

/// Linear runs from start to end; radial is centered on the start with the end on its rim.
nonisolated enum GradientShape: String, CaseIterable, Sendable {
    case linear = "Linear"
    case radial = "Radial"
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
}

nonisolated struct GradientSettings: Equatable, Sendable {
    var shape = GradientShape.linear
    var style = GradientStyle.foregroundToTransparent
    var reversed = false
    var opacity: CGFloat = 1
}

/// An uncommitted gradient on one layer or mask. Endpoints are document pixels;
/// the raster preview lives in `raster` and never touches the document until commit.
final class GradientEdit {
    let raster: BrushStroke
    var start: CGPoint
    var end: CGPoint
    init(raster: BrushStroke, start: CGPoint) {
        self.raster = raster
        self.start = start
        end = start
    }
    var hasLine: Bool { hypot(end.x - start.x, end.y - start.y) >= 0.5 }
}

extension EditorSession {
    func beginGradient(at point: CGPoint) {
        guard tool == .gradient, canPaint || gradientEdit != nil, let layer = activeLayer else { return }
        // Dragging a new line replaces the pending one on the same target.
        if let edit = gradientEdit, edit.raster.layer.id == layer.id, edit.raster.isMask == isMaskSelected {
            edit.start = point
            edit.end = point
            refreshGradient()
            return
        }
        guard canPaint else { return }
        finishOpacityEdit()
        do {
            gradientEdit = GradientEdit(raster: try makeRasterEdit(for: layer), start: point)
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }

    func moveGradient(start: CGPoint? = nil, end: CGPoint? = nil) {
        guard let edit = gradientEdit else { return }
        if let start { edit.start = start }
        if let end { edit.end = end }
        refreshGradient()
    }

    /// Re-renders the pending gradient from the current endpoints, settings, and palette.
    func refreshGradient() {
        guard let edit = gradientEdit else { return }
        if edit.hasLine {
            do {
                try edit.raster.fillGradient(gradientSettings.shape, from: edit.start, to: edit.end,
                    colors: gradientColors(mask: edit.raster.isMask), opacity: gradientSettings.opacity)
            } catch { cancelGradient(); brushError = error.localizedDescription; return }
        }
        brushRevision += 1
    }

    func gradientColors(mask: Bool) -> [CGColor] {
        let space = mask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ value: PaletteColor, alpha: CGFloat) -> CGColor {
            CGColor(colorSpace: space, components: mask ? [value.red, alpha] : [value.red, value.green, value.blue, alpha])!
        }
        let foreground = paletteColor(background: false)
        let colors = gradientSettings.style == .foregroundToBackground
            ? [color(foreground, alpha: 1), color(paletteColor(background: true), alpha: 1)]
            : [color(foreground, alpha: 1), color(foreground, alpha: 0)]
        return gradientSettings.reversed ? colors.reversed() : colors
    }

    /// Ends a drag; a click without a line leaves nothing pending.
    func endGradientDrag() {
        if gradientEdit?.hasLine == false { cancelGradient() }
    }

    func cancelGradient() {
        guard gradientEdit != nil else { return }
        gradientEdit = nil
        brushRevision += 1
    }

    func commitGradient() async {
        guard let edit = gradientEdit, !isProjectBusy else { return }
        guard edit.hasLine else { cancelGradient(); return }
        do {
            try await commitRasterEdit(edit.raster, name: edit.raster.isMask ? "Gradient Mask" : "Gradient")
        } catch { brushError = error.localizedDescription }
        if gradientEdit === edit { cancelGradient() }
    }

    /// Switching tools, layers, or targets applies the pending gradient, as in Photoshop.
    func resolveGradient() {
        guard gradientEdit != nil else { return }
        Task { await commitGradient() }
    }
}
