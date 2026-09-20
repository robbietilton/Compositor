import Foundation

/// Shared lookup for AppKit, model-generated messages and dynamic SwiftUI labels.
/// English keys remain independent of enum raw values and accessibility identifiers.
nonisolated enum L10n {
    static func string(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// Positional arguments allow each language to reorder a complete phrase.
    static func format(_ key: String, _ arguments: String..., bundle: Bundle = .main) -> String {
        String(format: string(key, bundle: bundle), locale: Locale.current, arguments: arguments)
    }
}
