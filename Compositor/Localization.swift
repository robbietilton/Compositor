import Foundation

/// Runtime localization for dynamic labels such as enum-backed pickers and AppKit alerts.
/// English source strings are stable keys and the fallback value, matching String Catalog extraction.
nonisolated enum L10n {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let localized = text(key)
        let format = LocalizationFormatSignature.isCompatible(source: key, translation: localized) ? localized : key
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}

nonisolated struct LocalizationFormatSignature: Equatable {
    struct Argument: Equatable {
        let position: Int
        let conversion: String
    }
    let arguments: [Argument]
    let mixesPositionalAndImplicit: Bool

    static func parse(_ value: String) -> Self {
        let pattern = #"%(?!%)(?:(\d+)\$)?[-+0#]*(?:\d+|\*)?(?:\.(?:\d+|\*))?((?:hh|h|ll|l|q|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return Self(arguments: [], mixesPositionalAndImplicit: false)
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var implicitPosition = 0, sawExplicit = false, sawImplicit = false
        var arguments: [Argument] = []
        for match in expression.matches(in: value, range: range) {
            let position: Int
            if let explicitRange = Range(match.range(at: 1), in: value), let explicit = Int(value[explicitRange]) {
                position = explicit; sawExplicit = true
            } else {
                implicitPosition += 1; position = implicitPosition; sawImplicit = true
            }
            guard let conversionRange = Range(match.range(at: 2), in: value) else { continue }
            arguments.append(Argument(position: position, conversion: String(value[conversionRange])))
        }
        arguments.sort { $0.position == $1.position ? $0.conversion < $1.conversion : $0.position < $1.position }
        return Self(arguments: arguments, mixesPositionalAndImplicit: sawExplicit && sawImplicit)
    }

    static func isCompatible(source: String, translation: String) -> Bool {
        let source = parse(source), translation = parse(translation)
        return !source.mixesPositionalAndImplicit && !translation.mixesPositionalAndImplicit
            && source.arguments == translation.arguments
    }
}
