import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// A stroke's head in Pressure Sensitivity, while Apple Pencil's force is still UIKit's placeholder: an iPad Pro (12.9-inch,
/// 6th generation) with the second Apple Pencil reports 0.333, estimated, for every stroke's first 12–21 ms, which stamped
/// a blob at the head of a light line. The head starts light and grows into its line; a tap waits for its real force.
/// The forces below are from that iPad's log; tests can't make a UITouch, so they hand the input what a touch would have.
@MainActor struct PadStrokeHeadTests {
    /// A 400 × 300 canvas fitted to a view its size, with one gray layer, and a large hard red brush whose Size follows
    /// the pressure.
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        session.selectTool(.brush)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.brushSettings.diameter = 40
        session.brushSettings.hardness = 1
        session.brushSettings.pressureSize = true
        return session
    }

    /// How many rows of each column red paint covers on the gray layer.
    private func thickness(_ session: EditorSession) throws -> [Int] {
        let context = try BrushRaster.copy(try #require(session.activeLayer?.asset?.image))
        let start = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let bytes = UnsafeBufferPointer(start: start, count: context.bytesPerRow * context.height)
        return (0..<400).map { x in (0..<300).filter { y in Int(bytes[(y * 400 + x) * 4 + 1]) < 64 }.count }
    }

    private func point(_ x: CGFloat, _ y: CGFloat, in session: EditorSession) -> CGPoint {
        session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: CGSize(width: 400, height: 300))
    }

    private static let maximum: CGFloat = 4.167
    /// The placeholder force the iPad Pro reported at every stroke's touch-down.
    private static let placeholder: CGFloat = 0.333

    /// A sample as the canvas reads a touch: its force, and whether UIKit still marks it estimated.
    private struct Sample { var force: CGFloat; var estimated = true }

    /// What the canvas hands the input for `sample`, in Pressure Sensitivity unless `follows` is false: the pressure,
    /// and whether it's from the placeholder.
    private func handed(_ sample: Sample, follows: Bool = true, refined: Bool = false) -> (pressure: CGFloat?, placeholder: Bool) {
        let placeholder = PadCanvasView.isPlaceholder(force: sample.force, estimated: sample.estimated,
                                                      touchDownForce: Self.placeholder, refined: refined)
        let pressure = PadCanvasView.pressure(type: .pencil, force: sample.force, maximumPossibleForce: Self.maximum,
                                              followsPressure: follows, placeholder: placeholder)
        return (pressure, follows && placeholder)
    }

    /// A left-to-right stroke along y = 150 from x = 40, a sample every `step` pixels, with `forces`, lifting on the
    /// last: as the canvas hands it on, UIKit's first refinement coming before sample `refinedFrom`, or, `capped`
    /// false, as it did before the head was capped and held.
    private func stroke(_ session: EditorSession, _ forces: [CGFloat], step: CGFloat = 4, refinedFrom: Int = .max,
                        capped: Bool = true) {
        let input = PadCanvasInput(session: session)
        func at(_ index: Int) -> CGPoint { point(40 + step * CGFloat(index), 150, in: session) }
        func pressure(_ index: Int) -> (CGFloat?, Bool) {
            capped ? handed(Sample(force: forces[index]), refined: index >= refinedFrom)
                : (PadCanvasInput.pressure(type: .pencil, force: forces[index], maximumPossibleForce: Self.maximum), false)
        }
        let (first, held) = pressure(0)
        input.began(at: at(0), pressure: first, placeholder: held)
        for index in forces.indices.dropFirst() {
            let (pressure, placeholder) = pressure(index)
            input.moved(to: at(index), pressure: pressure, placeholder: placeholder)
        }
        input.ended(at: at(forces.count - 1))
    }

    /// A light stroke as logged (stroke 7): the placeholder for five samples, then real estimates of 0.05–0.2.
    private static let light: [CGFloat] = [0.333, 0.333, 0.333, 0.333, 0.333, 0.198, 0.135, 0.109, 0.082, 0.051, 0.057,
                                           0.061, 0.065, 0.074, 0.078, 0.082, 0.088, 0.087, 0.091, 0.095, 0.099, 0.103]
    /// A firm one (stroke 4): the placeholder for five samples, then 0.4 rising to 0.8.
    private static let firm: [CGFloat] = [0.333, 0.333, 0.333, 0.333, 0.333, 0.396, 0.459, 0.493, 0.526, 0.574, 0.619,
                                          0.653, 0.663, 0.697, 0.730, 0.772, 0.764, 0.757, 0.790, 0.824, 0.795, 0.803]

    // MARK: The head

    /// A light stroke's head is no heavier than the line that follows it; before, the placeholder stamped a blob there.
    @Test func aLightStrokesHeadIsNoHeavierThanItsLine() throws {
        let session = try session()
        stroke(session, Self.light)
        let columns = try thickness(session)
        // The head, round the touch-down at x = 40, against the line where its real force comes in, x = 60–80.
        let head = columns[30...50].max()!, line = columns[60...80].max()!
        #expect(head <= line, "head \(head), line \(line)")
        #expect(head >= 4, "the head still shows: \(head)")

        let before = try self.session()
        stroke(before, Self.light, capped: false)
        let blob = try thickness(before)[30...50].max()!
        #expect(blob > line && blob > head + 4, "the placeholder's blob, for the record: \(blob) against \(head) and \(line)")
    }

    /// A light stroke as logged after the placeholder was capped (stroke 1 of the second pass): its first estimates,
    /// 0.29–0.33, settle down from the placeholder toward a line of about 0.2–0.25, and UIKit's first refinement comes
    /// at 40 ms, sample 10. Until then they paint no heavier than the head, so the head is no heavier than its line.
    @Test func settlingEstimatesWaitForTheFirstRefinement() throws {
        let forces: [CGFloat] = [0.333, 0.333, 0.333, 0.333, 0.333, 0.292, 0.296, 0.292, 0.326, 0.266, 0.244, 0.222, 0.240,
                                 0.219, 0.221, 0.210, 0.220, 0.230, 0.202, 0.210, 0.218, 0.193, 0.199, 0.205, 0.200, 0.198,
                                 0.201, 0.199, 0.200, 0.202]
        let session = try session()
        stroke(session, forces, refinedFrom: 10)
        let columns = try thickness(session)
        let head = columns[36...76].max()!, line = columns[80...150].max()!
        #expect(head <= line, "head \(head), line \(line)")

        let before = try self.session()
        stroke(before, forces, refinedFrom: 0)
        #expect(try thickness(before)[36...76].max()! > line, "the bump this removes, for the record")
    }

    /// A firm stroke grows from its light head into its line as its real force comes, with no step back.
    @Test func aFirmStrokeGrowsFromItsHeadIntoItsLine() throws {
        let session = try session()
        stroke(session, Self.firm)
        let columns = try thickness(session)
        let head = columns[40], line = columns[110]
        #expect(head < line && head <= Int(40 * PadCanvasInput.placeholderPressure) + 2, "head \(head), line \(line)")
        let rising = columns[40...100]
        #expect(zip(rising, rising.dropFirst()).allSatisfy { $1 >= $0 - 1 }, "\(Array(rising))")
        #expect(abs(line - Int((40 * PadCanvasInput.pressure(type: .pencil, force: 0.76, maximumPossibleForce: Self.maximum)!).rounded())) <= 3)
    }

    /// A placeholder sample later in the stroke never paints heavier than the head either, while a real force does.
    @Test func thePlaceholderHandsOnNoMoreThanTheHeadsPressure() throws {
        let capped = handed(Sample(force: Self.placeholder))
        #expect(capped.pressure == PadCanvasInput.placeholderPressure && capped.placeholder)
        let real = handed(Sample(force: Self.placeholder, estimated: false))
        #expect(real.pressure == PadCanvasInput.pressure(type: .pencil, force: Self.placeholder, maximumPossibleForce: Self.maximum))
        #expect(!real.placeholder)
        let changed = handed(Sample(force: 0.198), refined: true)
        #expect(!changed.placeholder && changed.pressure! > PadCanvasInput.placeholderPressure)
        // Before UIKit's first refinement, an estimate under the placeholder is still settling down from it; one over it
        // is a firm press coming in.
        let settling = handed(Sample(force: 0.198))
        #expect(settling.placeholder && settling.pressure == PadCanvasInput.placeholderPressure)
        let firm = handed(Sample(force: 0.882))
        #expect(!firm.placeholder && firm.pressure! > 0.5)
        // A placeholder lighter than the head's pressure, as another Pencil's might be, stays as it is.
        let lighter = PadCanvasView.pressure(type: .pencil, force: 0.02, maximumPossibleForce: Self.maximum,
                                             followsPressure: true, placeholder: true)
        #expect(lighter == PadCanvasInput.pressure(type: .pencil, force: 0.02, maximumPossibleForce: Self.maximum))
    }

    // MARK: When it begins

    /// A stroke held for its real force begins with its first move, light, at once: the tip moving doesn't wait.
    @Test func aMovingStrokeBeginsAtOnce() throws {
        let session = try session()
        let input = PadCanvasInput(session: session)
        let (pressure, placeholder) = handed(Sample(force: Self.placeholder))
        input.began(at: point(100, 150, in: session), pressure: pressure, placeholder: placeholder)
        #expect(input.isHoldingStroke && input.isPainting && session.brushStroke == nil)
        // Still where it came down, still the placeholder: it waits.
        input.moved(to: point(100, 150, in: session), pressure: pressure, placeholder: placeholder)
        #expect(input.isHoldingStroke && session.brushStroke == nil)
        input.moved(to: point(104, 150, in: session), pressure: pressure, placeholder: placeholder)
        #expect(!input.isHoldingStroke && session.brushStroke != nil)
        input.ended(at: point(104, 150, in: session))
        #expect(try thickness(session)[100] == Int(40 * PadCanvasInput.placeholderPressure))
    }

    /// The move that begins a held stroke is painted too, with its own force: the line grows toward it from the head.
    @Test func theMoveThatBeginsAStrokeCounts() throws {
        let session = try session()
        let input = PadCanvasInput(session: session)
        let (held, placeholder) = handed(Sample(force: Self.placeholder))
        input.began(at: point(100, 150, in: session), pressure: held, placeholder: placeholder)
        let (real, _) = handed(Sample(force: 0.8))
        input.moved(to: point(160, 150, in: session), pressure: real, placeholder: false)
        input.ended(at: point(160, 150, in: session))
        let columns = try thickness(session)
        #expect(columns[100] <= Int(40 * PadCanvasInput.placeholderPressure) + 1, "\(columns[100])")
        #expect(abs(CGFloat(columns[158]) - 40 * real!) <= 3, "\(columns[158])")
    }

    /// A tap that gets its real force before it lifts stamps at that force, however hard.
    @Test func aTapStampsAtItsRealForce() throws {
        for force: CGFloat in [0.05, 0.8, 2.5] {
            let session = try session()
            let input = PadCanvasInput(session: session)
            let tap = point(200, 150, in: session)
            let (held, placeholder) = handed(Sample(force: Self.placeholder))
            input.began(at: tap, pressure: held, placeholder: placeholder)
            let (real, stillPlaceholder) = handed(Sample(force: force))
            input.moved(to: tap, pressure: real, placeholder: stillPlaceholder)
            input.ended(at: tap)
            let size = try thickness(session)[200]
            let expected = 40 * PadCanvasInput.pressure(type: .pencil, force: force, maximumPossibleForce: Self.maximum)!
            #expect(abs(CGFloat(size) - expected) <= 2, "at \(force): \(size), expected about \(expected)")
        }
    }

    /// A tap lifted before any real force stamps at the head's light pressure; so does one held the longest it waits.
    @Test func aTapWithoutARealForceStampsLight() throws {
        for timesOut in [false, true] {
            let session = try session()
            let input = PadCanvasInput(session: session)
            let tap = point(200, 150, in: session)
            let steps = session.history.undoCount
            let (pressure, placeholder) = handed(Sample(force: Self.placeholder))
            input.began(at: tap, pressure: pressure, placeholder: placeholder)
            if timesOut {
                input.beginHeldStroke()
                #expect(session.brushStroke != nil && !input.isHoldingStroke)
            }
            input.ended(at: tap)
            #expect(try thickness(session)[200] == Int(40 * PadCanvasInput.placeholderPressure), "\(timesOut)")
            #expect(session.history.undoCount == steps + 1)
        }
    }

    /// A held stroke taken away, as by a second finger, paints nothing and leaves nothing to undo.
    @Test func aHeldStrokeCancelledLeavesNothing() throws {
        let session = try session()
        let input = PadCanvasInput(session: session)
        let steps = session.history.undoCount
        let (pressure, placeholder) = handed(Sample(force: Self.placeholder))
        input.began(at: point(200, 150, in: session), pressure: pressure, placeholder: placeholder)
        input.cancelled()
        #expect(session.brushStroke == nil && !input.isPainting && session.history.undoCount == steps)
        #expect(try thickness(session).allSatisfy { $0 == 0 })
    }

    /// Shift's straight line from the last stroke, held too, takes the pressure the held stroke begins with.
    @Test func shiftsLineTakesTheHeadsPressure() throws {
        let session = try session()
        let input = PadCanvasInput(session: session)
        let start = point(50, 150, in: session), tap = point(300, 150, in: session)
        input.began(at: start, pressure: 1)
        input.ended(at: start)
        let (held, placeholder) = handed(Sample(force: Self.placeholder))
        input.began(at: tap, keys: .shift, pressure: held, placeholder: placeholder)
        let (real, _) = handed(Sample(force: 0.8))
        input.moved(to: tap, keys: .shift, pressure: real, placeholder: false)
        input.ended(at: tap, keys: .shift)
        let middle = try thickness(session)[175]
        #expect(abs(CGFloat(middle) - 40 * real!) <= 3, "\(middle)")
    }

    // MARK: Nothing else changes

    /// Fingers, Pencil and Finger Touch, and a Pencil that reports no placeholder, begin at once as before: nothing is
    /// held without a placeholder's pressure to hold.
    @Test func withoutAPlaceholderNothingWaits() throws {
        #expect(handed(Sample(force: Self.placeholder), follows: false) == (nil, false))
        #expect(PadCanvasView.pressure(type: .direct, force: Self.placeholder, maximumPossibleForce: Self.maximum,
                                       followsPressure: true, placeholder: true) == nil)
        #expect(!PadCanvasView.isPlaceholder(force: Self.placeholder, estimated: false, touchDownForce: Self.placeholder))
        #expect(!PadCanvasView.isPlaceholder(force: 0.3, estimated: true, touchDownForce: Self.placeholder, refined: true))
        #expect(!PadCanvasView.isPlaceholder(force: 0.4, estimated: true, touchDownForce: Self.placeholder))
        #expect(!PadCanvasView.isPlaceholder(force: 0.2, estimated: false, touchDownForce: Self.placeholder))
        for (pressure, placeholder) in [(CGFloat?.none, true), (nil, false), (0.5, false)] {
            let session = try session()
            let input = PadCanvasInput(session: session)
            input.began(at: point(200, 150, in: session), pressure: pressure, placeholder: placeholder)
            #expect(!input.isHoldingStroke && session.brushStroke != nil, "\(String(describing: pressure)), \(placeholder)")
            input.ended(at: point(200, 150, in: session))
        }
    }
}
