import SwiftUI
import AppKit

/// Makes a label or unit a drag target for the value shown in its adjacent field.
private struct NumericScrub<Value: BinaryFloatingPoint>: ViewModifier {
    @Binding var value: Value
    let sensitivity: Value
    let range: ClosedRange<Value>
    /// Dragged values snap to multiples of this (1 for whole numbers); typing can still give any value.
    let step: Value?
    let onStart: () -> Void
    let onEnd: () -> Void
    @State private var startValue: Value?
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(_):
                    isHovering = true
                    NSCursor.resizeLeftRight.set()
                case .ended:
                    isHovering = false
                    if startValue == nil { NSCursor.arrow.set() }
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let start = startValue ?? value
                    if startValue == nil { startValue = start; onStart() }
                    NSCursor.resizeLeftRight.set()
                    var proposed = start + Value(drag.translation.width) * sensitivity
                    if let step, step > 0 { proposed = (proposed / step).rounded() * step }
                    value = min(range.upperBound, max(range.lowerBound, proposed))
                }
                .onEnded { _ in
                    startValue = nil
                    (isHovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    onEnd()
                })
    }
}

extension View {
    func scrubbable<Value: BinaryFloatingPoint>(sensitivity: Value, value: Binding<Value>,
                                                range: ClosedRange<Value>, step: Value? = nil,
                                                onStart: @escaping () -> Void = {},
                                                onEnd: @escaping () -> Void = {}) -> some View {
        modifier(NumericScrub(value: value, sensitivity: sensitivity, range: range, step: step,
                              onStart: onStart, onEnd: onEnd))
    }

    func scrubbable(sensitivity: Double, value: Binding<Int>, range: ClosedRange<Int>,
                   onStart: @escaping () -> Void = {}, onEnd: @escaping () -> Void = {}) -> some View {
        scrubbable(sensitivity: sensitivity,
                   value: Binding<Double>(get: { Double(value.wrappedValue) },
                                          set: { value.wrappedValue = Int($0.rounded()) }),
                   range: Double(range.lowerBound)...Double(range.upperBound),
                   onStart: onStart, onEnd: onEnd)
    }
}
