import Foundation

/// Display-only localization. The original strings remain model and file-format identifiers.
nonisolated enum L10n {
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: Bundle.main.localizedString(forKey: key, value: key, table: nil), arguments: arguments)
    }

    static func text(_ source: String) -> String {
        let translated = Bundle.main.localizedString(forKey: source, value: source, table: nil)
        guard translated == source else { return translated }
        let capitalized = source.capitalized
        if capitalized != source {
            let label = Bundle.main.localizedString(forKey: capitalized, value: capitalized, table: nil)
            if label != capitalized { return label }
        }
        // Composite labels use the same localized names as their controls and history entries.
        for separator in [" › ", " · "] where source.contains(separator) {
            return source.components(separatedBy: separator).map(text).joined(separator: separator)
        }
        for prefix in ["Undo ", "Redo ", "Last Filter: ", "Hide ", "Show ", "Add ", "Cancel ", "Edit ", "Copy ", "Remove ", "Delete ", "Tool › "] where source.hasPrefix(prefix) {
            let key = prefix.trimmingCharacters(in: .whitespaces)
            let label = Bundle.main.localizedString(forKey: key, value: key, table: nil)
            return label + " " + text(String(source.dropFirst(prefix.count)))
        }
        if source.hasSuffix("…") { return text(String(source.dropLast())) + "…" }
        return source
    }
}
