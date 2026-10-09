import SwiftUI
import AppKit

/// Resolves a runtime English string to its localized form by looking it up as a key
/// in the app's string catalog. Strings that have no translation are returned unchanged.
///
/// Use this where display text travels through `String`-typed plumbing (slider rows,
/// undo names, shortcut titles, AppKit tooltips) instead of `LocalizedStringKey`,
/// so the literal at the call site stays a plain catalog key.
/// nonisolated: a pure string lookup, safe to call from the model and IO layers too.
nonisolated func localized(_ key: String) -> String {
    String(localized: String.LocalizationValue(key))
}

/// The interface-language override from the Compositor menu. It writes AppleLanguages,
/// which macOS reads at launch, so a change takes effect on the next launch.
enum LanguagePreference {
    private static let key = "AppleLanguages"

    /// The persisted override, or nil when following the system. A `-AppleLanguages` launch
    /// argument lives in the volatile domain and is deliberately not read back here.
    static var override: String? {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        return (domain?[key] as? [String])?.first
    }

    static func set(_ language: String?) {
        guard save(language) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Language change saved")
        alert.informativeText = String(localized: "Save your work, quit Compositor, then open it again to apply the new language.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// Only changes this app's preferences; following the system removes the override.
    @discardableResult
    static func save(_ language: String?, defaults: UserDefaults = .standard) -> Bool {
        guard language == nil || language == "en" || language == "zh-Hans" else { return false }
        if let language { defaults.set([language], forKey: key) }
        else { defaults.removeObject(forKey: key) }
        return true
    }
}
