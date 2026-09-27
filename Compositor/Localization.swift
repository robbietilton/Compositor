import Foundation

extension String {
    /// The name to show for a string that doubles as a stored value.
    ///
    /// Values such as `FilterKind.gaussianBlur.rawValue` are written into project files, so they have
    /// to stay in English. Their raw value is also the key that `Localizable.strings` translates, and
    /// when the table has no entry the English original comes back unchanged.
    nonisolated var localizedName: String { String(localized: String.LocalizationValue(self)) }

    /// The localized sentence for text assembled at runtime, such as a menu title picked by a condition.
    nonisolated func localizedSentence(_ arguments: CVarArg...) -> String {
        let format = Bundle.main.localizedString(forKey: self, value: nil, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments)
    }
}
