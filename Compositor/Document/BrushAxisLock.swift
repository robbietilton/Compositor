import CoreGraphics

/// Shift keeping a brush stroke straight, horizontal or vertical, as in Photoshop: from where Shift was pressed in the
/// stroke, or where the stroke started if it was held then. The axis is settled by the first few pixels of movement, so
/// it doesn't flip mid-line; letting go carries on freehand.
nonisolated struct BrushAxisLock {
    /// Where Shift was last pressed in the stroke (or where the stroke started, if it was held then): the line the
    /// stroke is kept on while Shift stays down.
    private var anchor: CGPoint?
    /// The axis that line runs along, chosen by which way the stroke first moves once Shift is down.
    private var horizontal: Bool?
    /// Where the stroke last went, so pressing Shift mid-stroke locks from there rather than from its start.
    private var last: CGPoint?

    init() {}

    /// A stroke starting at `pixel`, with Shift held or not.
    init(start pixel: CGPoint, shift: Bool) {
        anchor = shift ? pixel : nil
        last = pixel
    }

    /// Where the stroke goes with the pointer at `pixel`, with Shift held or not.
    mutating func point(for pixel: CGPoint, shift: Bool) -> CGPoint {
        var pixel = pixel
        if shift {
            let anchor = self.anchor ?? last ?? pixel
            if self.anchor == nil { self.anchor = anchor; horizontal = nil }
            if horizontal == nil, hypot(pixel.x - anchor.x, pixel.y - anchor.y) >= 3 {
                horizontal = abs(pixel.x - anchor.x) >= abs(pixel.y - anchor.y)
            }
            if let horizontal {
                pixel = horizontal ? CGPoint(x: pixel.x, y: anchor.y) : CGPoint(x: anchor.x, y: pixel.y)
            } else {
                pixel = anchor
            }
        } else {
            anchor = nil
            horizontal = nil
        }
        last = pixel
        return pixel
    }
}
