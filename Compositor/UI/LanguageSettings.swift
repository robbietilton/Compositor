import AppKit

/// The app's interface language. macOS resolves an app's localization once at launch, so switching writes the
/// `AppleLanguages` override (or clears it to follow the system's language list) and asks for a restart.
enum UILanguage: String, CaseIterable {
    /// Follows the user's macOS language list; no `AppleLanguages` override is written.
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// Where the menu's choice is remembered, separate from `AppleLanguages` so "follow the system" stays
    /// distinguishable from an override that happens to match the system language.
    static let preferenceKey = "preferredUILanguage"

    /// The `AppleLanguages` value a choice maps to: an override list pinning the app to one language,
    /// or `nil` to clear the override and follow the system's language list again.
    static func appleLanguagesValue(for language: UILanguage) -> [String]? {
        language == .system ? nil : [language.rawValue]
    }

    /// The menu's current selection.
    static var stored: UILanguage {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(UILanguage.init(rawValue:)) ?? .system
    }

    /// Writes the choice to `defaults`: the `AppleLanguages` override (or its removal) plus the
    /// remembered menu selection. Split out of `select(_:)` so the write/remove mapping is testable
    /// without the restart alert.
    static func apply(_ language: UILanguage, to defaults: UserDefaults) {
        if let appleLanguages = appleLanguagesValue(for: language) {
            defaults.set(appleLanguages, forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
        defaults.set(language.rawValue, forKey: preferenceKey)
    }

    /// Applies the choice and explains that it takes effect at the next launch.
    static func select(_ language: UILanguage) {
        apply(language, to: UserDefaults.standard)
        confirmRestart()
    }

    // MARK: Testing

    /// Marks that the test host's English pin is ours, so a later normal launch can undo it.
    private static let testHostPinKey = "pinnedEnglishForTestHost"

    /// The tests assert source-language strings — undo names, menu titles — that the catalog now
    /// translates, so on a Mac whose system language is Chinese the hosted app would report Chinese
    /// names and fail them. While tests run hosted inside the app, pin it to English instead.
    /// Called from the app's first stored property: macOS resolves a bundle's localization lazily,
    /// at the first localized lookup, so writing the override before anything displays decides it.
    static func stabilizeLanguageDuringTesting() -> Bool {
        let defaults = UserDefaults.standard
        if isTestHost {
            defaults.set(true, forKey: testHostPinKey)
            defaults.set(["en"], forKey: "AppleLanguages")
            return true
        }
        // A force-killed test run can leave its pin in the persistent domain; restore the menu's choice.
        if defaults.object(forKey: testHostPinKey) != nil {
            defaults.removeObject(forKey: testHostPinKey)
            apply(stored, to: defaults)
        }
        return false
    }

    /// Unit tests run hosted in the app, which the test runner flags through its environment.
    private static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionFilePath"] != nil
    }

    private static func confirmRestart() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Language settings apply on restart")
        alert.informativeText = String(localized: "Compositor will use the new interface language the next time it opens.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    /// Quits — through the normal terminate flow, so unsaved work is still asked about — and starts a new
    /// instance once this one is gone. If the helper can't start, the user simply restarts by hand.
    private static func relaunch() {
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The pid and bundle path travel as positional parameters, never inside the command
        // string, so no path character can break out of the quoting.
        watcher.arguments = ["-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
            "watch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        do { try watcher.run() } catch { return }
        NSApp.terminate(nil)
        // Terminate only returns when it was refused — an unsaved-changes dialog said Cancel —
        // and this instance lives on, so the watcher must not outlive that decision.
        watcher.terminate()
    }
}
