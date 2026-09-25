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
        if let language { UserDefaults.standard.set([language], forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        offerRestart()
    }

    private static func offerRestart() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart Compositor to apply the language change?")
        alert.informativeText = String(localized: "The interface language takes effect on the next launch.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // A fresh instance picks up the new AppleLanguages; `open` returns before this process exits.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
