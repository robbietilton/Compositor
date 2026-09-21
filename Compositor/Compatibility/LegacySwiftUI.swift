import SwiftUI

struct LegacyChangeState<Value: Equatable> {
    private(set) var value: Value

    init(_ value: Value) {
        self.value = value
    }

    mutating func update(_ newValue: Value) -> (old: Value, new: Value)? {
        guard value != newValue else { return nil }
        let old = value
        value = newValue
        return (old, newValue)
    }
}

private struct LegacyValueChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value, Value) -> Void
    @State private var state: LegacyChangeState<Value>

    init(value: Value, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.action = action
        _state = State(initialValue: LegacyChangeState(value))
    }

    func body(content: Content) -> some View {
        content.onChange(of: value) { newValue in
            guard let change = state.update(newValue) else { return }
            action(change.old, change.new)
        }
    }
}

private struct LegacyGeometryPreference<Value: Equatable>: PreferenceKey {
    static var defaultValue: Value? { nil }

    static func reduce(value: inout Value?, nextValue: () -> Value?) {
        value = nextValue() ?? value
    }
}

private struct LegacyGeometryChangeModifier<Value: Equatable>: ViewModifier {
    let transform: (GeometryProxy) -> Value
    let action: (Value) -> Void
    @State private var lastValue: Value?

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: LegacyGeometryPreference<Value>.self,
                        value: transform(geometry)
                    )
                }
            }
            .onPreferenceChange(LegacyGeometryPreference<Value>.self) { value in
                guard let value, lastValue != value else { return }
                lastValue = value
                action(value)
            }
    }
}

extension View {
    func onValueChangeCompat<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value, Value) -> Void
    ) -> some View {
        modifier(LegacyValueChangeModifier(value: value, action: action))
    }

    func onGeometryChangeCompat<Value: Equatable>(
        for valueType: Value.Type,
        of transform: @escaping (GeometryProxy) -> Value,
        action: @escaping (Value) -> Void
    ) -> some View {
        modifier(LegacyGeometryChangeModifier(transform: transform, action: action))
    }

    @ViewBuilder
    func legacyScrollIndicatorsHidden() -> some View {
        if #available(macOS 13.0, *) {
            scrollIndicators(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func legacyScrollBounceBasedOnSize() -> some View {
        if #available(macOS 16.0, *) {
            scrollBounceBehavior(.basedOnSize, axes: .vertical)
        } else {
            self
        }
    }

}
