import CoreGraphics
import Foundation

/// What the on-canvas text editor works out apart from the text system that shows it: where it stands, how a handle
/// resizes its box, and what a change to the text does to its colors and faces.
extension TextDraft {
    /// Where the editor shows the text on the canvas, `logicalSize` across in the text's own units: the draft's own
    /// transform, or one at its origin. Point text already on a layer, whose pixels are `layerWidth` across, grows as it
    /// is typed, keeping whatever scale the layer was given.
    func shownTransform(logicalSize: CGSize, layerWidth: Int?) -> LayerTransform {
        var transform = self.transform ?? LayerTransform(origin: origin, size: logicalSize)
        if style.boxSize == nil, self.transform != nil, let layerWidth, layerWidth > 0 {
            let factor = transform.size.width / CGFloat(layerWidth)
            // A rotated layer turns about its center, so growing it swings its corner away and the text drifts as it
            // is typed. The top-left corner is put back where it was, which is where the commit leaves it too.
            let anchor = transform.point(.zero)
            transform.size = CGSize(width: logicalSize.width * factor, height: logicalSize.height * factor)
            let moved = transform.point(.zero)
            transform.origin.x += anchor.x - moved.x
            transform.origin.y += anchor.y - moved.y
        }
        return transform
    }

    /// Ready for a handle to resize it: point text becomes a box of the size it shows at, `logicalSize` at `transform`,
    /// which then holds the text and wraps it rather than scaling it. Its scale and rotation are whatever the layer
    /// already had. A box stays as it is.
    func boxed(logicalSize: CGSize, shown transform: LayerTransform) -> TextDraft {
        guard style.boxSize == nil else { return self }
        var draft = self
        draft.style.boxSize = logicalSize
        draft.transform = transform
        draft.origin = transform.origin
        return draft
    }

    /// The box resized by dragging `handle`, in `LayerTransform.handles` order, from `start` to `point` in document
    /// pixels, `old` being the transform shown when the drag began. The opposite edges stay put. Nil when the box
    /// would be too small or unusable.
    func resized(handle: Int, from old: LayerTransform, start: CGPoint, to point: CGPoint) -> TextDraft? {
        guard let source = style.boxSize else { return nil }
        let dx = point.x - start.x, dy = point.y - start.y
        let localX = dx * cos(old.radians) + dy * sin(old.radians)
        let localY = -dx * sin(old.radians) + dy * cos(old.radians)
        let unit = LayerTransform.handles[handle]
        var left: CGFloat = 0, top: CGFloat = 0, right = old.size.width, bottom = old.size.height
        let minW = 16 * old.size.width / source.width, minH = 16 * old.size.height / source.height
        if unit.x == 0 { left = min(localX, right - minW) }
        if unit.x == 1 { right = max(left + minW, right + localX) }
        if unit.y == 0 { top = min(localY, bottom - minH) }
        if unit.y == 1 { bottom = max(top + minH, bottom + localY) }
        var draft = self
        draft.style.boxSize = CGSize(width: ((right - left) * source.width / old.size.width).rounded(),
                                     height: ((bottom - top) * source.height / old.size.height).rounded())
        guard let size = draft.style.boxSize, draft.style.boxIsValid else { return nil }
        var transform = old
        transform.size = CGSize(width: size.width * old.size.width / source.width, height: size.height * old.size.height / source.height)
        let anchor = old.point(CGPoint(x: left / old.size.width, y: top / old.size.height))
        let current = transform.point(.zero)
        transform.origin.x += anchor.x - current.x
        transform.origin.y += anchor.y - current.y
        guard transform.isValid else { return nil }
        draft.origin = transform.origin
        draft.transform = transform
        return draft
    }
}

extension EditorSession {
    /// The style once the editor has replaced `range` of the text with `replacement`, its color and face runs moved to
    /// fit, building on `pending`: changes the text system has taken but not yet made. Nil when there are no runs to
    /// move; `pending` when the range isn't in the text.
    func textStyle(replacing range: NSRange, with replacement: String?, after pending: LayerTextStyle?) -> LayerTextStyle? {
        guard let draft = textDraft, draft.style.colorRuns != nil || draft.style.fontRuns != nil else { return nil }
        var style = pending ?? draft.style
        guard NSMaxRange(range) <= style.content.utf16.count else { return pending }
        style.replaceCharacters(in: range, withLength: replacement?.utf16.count ?? 0)
        style.content = (style.content as NSString).replacingCharacters(in: range, with: replacement ?? "")
        return style
    }

    /// The draft once the editor's text has become `content`, with `selection`: with the runs `pending` moved, when it
    /// was this change they were moved for. Text changed without saying how can't keep its colors and faces letter
    /// for letter.
    func textDraft(changedTo content: String, selection: NSRange, pending: LayerTextStyle?) -> TextDraft? {
        guard var draft = textDraft else { return nil }
        if let pending, pending.content == content {
            draft.style.colorRuns = pending.colorRuns
            draft.style.fontRuns = pending.fontRuns
        }
        draft.style.content = content
        if !draft.style.isValid { draft.style.colorRuns = nil; draft.style.fontRuns = nil }
        draft.selection = selection
        return draft
    }
}
