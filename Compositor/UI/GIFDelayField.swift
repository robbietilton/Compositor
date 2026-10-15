import SwiftUI

/// Typed text stays separate from timing until Return or leaving the field. Invalid text restores its value.
struct GIFDelayField: View {
    @Binding var milliseconds: Double
    @Binding var draft: String?
    let focus: FocusState<Int?>.Binding
    let index: Int
    var step = 10.0
    var alignment: SwiftUI.TextAlignment = .trailing
    var scrubsUnit = false
    var unitSpacing: CGFloat = 2
    @State private var stepper = ArrowStepper()

    var body: some View {
        if scrubsUnit {
            field.unitSuffix("ms", scrubValue: $milliseconds, sensitivity: step, range: 20...655_350, step: step,
                             spacing: unitSpacing)
        } else {
            field.unitSuffix("ms", spacing: unitSpacing)
        }
    }

    private var field: some View {
        TextField("Delay", text: Binding(get: { draft ?? TransformValueField.formatted(milliseconds) }, set: { draft = $0 }))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(alignment)
            .focused(focus, equals: index)
            .onSubmit { confirm(); focus.wrappedValue = nil }
            .onChange(of: focus.wrappedValue) { previous, current in
                if previous == index, current != index { confirm() }
            }
            .onChange(of: milliseconds) { draft = nil }
            .arrowSteps(step, editing: focus.wrappedValue == index, stepper: stepper,
                        value: { Self.confirmedMilliseconds(draft, previous: milliseconds) }, change: { value in
                draft = TransformValueField.formatted(min(655_350, max(20, value)))
            })
    }

    private func confirm() {
        let value = Self.confirmedMilliseconds(draft, previous: milliseconds)
        draft = nil
        if value != milliseconds { milliseconds = value }
    }

    static func confirmedMilliseconds(_ draft: String?, previous: Double) -> Double {
        guard let draft, let value = Double(draft.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, GIFFrameTiming.delayRange.contains(value / 1000) else { return previous }
        return value
    }
}
