import AppKit
import SwiftUI

/// A language the app can show. The list is whatever shipped in the string catalog, not a case per language.
struct AppLanguage: Identifiable, Equatable, Hashable, Sendable {
    /// Apple language id, such as `en`, `zh-Hans`, or `ja`. Also the preference value.
    let id: String

    static let development = "en"
    static let defaultsKey = "compositor.language"

    /// The name of this language in its own words. Two languages that share a name are told apart by script.
    var nativeName: String {
        Self.displayName(for: id, among: Self.installedIDs)
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Language ids compiled into this app, without the Base region.
    static var installedIDs: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }
    }

    /// English first, then the rest by the name each language uses for itself.
    static var menu: [AppLanguage] {
        var ids = Set(installedIDs)
        ids.insert(development)
        return ids.map { AppLanguage(id: $0) }.sorted { lhs, rhs in
            if lhs.id == development { return rhs.id != development }
            if rhs.id == development { return false }
            return lhs.nativeName.localizedStandardCompare(rhs.nativeName) == .orderedAscending
        }
    }

    /// The language this process started in. Switching writes the preference and relaunches.
    private(set) static var applied = AppLanguage(id: development)

    private static var didApply = false

    /// Called from the app's initializer, before any window is built. Safe to call again.
    static func applyAtLaunch() {
        guard !didApply else { return }
        didApply = true
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        let choice = resolved(stored: stored, systemLanguages: systemLanguages(), available: installedIDs, isRunningTests: isRunningTests)
        applied = choice
        if isRunningTests {
            forceEnglishForTests()
            return
        }
        if stored != nil {
            UserDefaults.standard.set([choice.id], forKey: "AppleLanguages")
        }
    }

    /// `available` is the set of language ids in the catalog. A stored id wins; otherwise Apple's
    /// fallback picks among that set, so a newly shipped language needs no matcher of its own.
    static func resolved(stored: String?, systemLanguages: [String], available: [String], isRunningTests: Bool) -> AppLanguage {
        if isRunningTests { return AppLanguage(id: development) }
        let choices = available.filter { $0 != "Base" }
        let installed = choices.isEmpty ? [development] : choices
        if let stored, installed.contains(stored) { return AppLanguage(id: stored) }
        let match = Bundle.preferredLocalizations(from: installed, forPreferences: systemLanguages).first
        return AppLanguage(id: match ?? development)
    }

    /// The name `id` uses for itself. When two installed languages share that name, the script
    /// (`简体中文` against a bare `中文`) tells them apart.
    static func displayName(for id: String, among ids: [String]) -> String {
        let locale = Locale(identifier: id)
        let name = locale.localizedString(forIdentifier: id) ?? id
        let collides = ids.contains { other in
            other != id && (Locale(identifier: other).localizedString(forIdentifier: other) ?? other) == name
        }
        let script = Locale.Language(identifier: id).script?.identifier
        let qualified = script.flatMap { locale.localizedString(forScriptCode: $0) }
        return distinguished(name, scriptName: qualified, collides: collides)
    }

    /// A shared name such as `中文` becomes the script name (`简体中文`). A name that is already unique stays as it is.
    static func distinguished(_ name: String, scriptName: String?, collides: Bool) -> String {
        guard collides, let scriptName, scriptName != name else { return name }
        return scriptName
    }

    /// The user's language list, not this app's override.
    static func systemLanguages() -> [String] {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        if let global, !global.isEmpty { return global }
        return Locale.preferredLanguages
    }

    @MainActor
    static func choose(_ language: AppLanguage) {
        guard language != applied else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Relaunch to change language?")
        alert.informativeText = String(localized: "Compositor will reopen in the language you chose.")
        alert.addButton(withTitle: String(localized: "Relaunch"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(language.id, forKey: defaultsKey)
        UserDefaults.standard.set([language.id], forKey: "AppleLanguages")
        relaunch()
    }

    /// Opens a new instance after this one quits, so the new process reads `AppleLanguages` from the start.
    @MainActor
    private static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Tests always see English. The override is restored when the process exits so a test run
    /// doesn't leave the installed app stuck in English.
    private static func forceEnglishForTests() {
        testLanguageHadPrevious = true
        testLanguagePrevious = UserDefaults.standard.object(forKey: "AppleLanguages")
        UserDefaults.standard.set([development], forKey: "AppleLanguages")
        _ = Bundle.main.preferredLocalizations
        atexit(restoreTestAppleLanguages)
    }
}

private var testLanguagePrevious: Any?
private var testLanguageHadPrevious = false

private func restoreTestAppleLanguages() {
    guard testLanguageHadPrevious else { return }
    if let testLanguagePrevious {
        UserDefaults.standard.set(testLanguagePrevious, forKey: "AppleLanguages")
    } else {
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
    testLanguageHadPrevious = false
}

extension LocalizedStringResource {
    /// The development-language sentence. Shortcut ids stay this text when the interface is translated.
    var englishText: String {
        var copy = self
        copy.locale = Locale(identifier: "en")
        return String(localized: copy)
    }
}

private let appliedAppLanguageAtLoad: Void = {
    AppLanguage.applyAtLaunch()
}()
