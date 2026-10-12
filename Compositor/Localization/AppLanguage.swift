import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let storageKey = "application.language"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    /// Language names stay in their own language, so they remain recognizable after the UI changes.
    var displayName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    static func resolved(_ code: String?) -> AppLanguage {
        code.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    static var current: AppLanguage {
        resolved(UserDefaults.standard.string(forKey: storageKey))
    }
}

/// Localizes strings that AppKit and dynamic SwiftUI labels cannot infer from string literals.
enum L10n {
    static func string(_ key: String, language: AppLanguage = .current, bundle: Bundle = .main) -> String {
        guard language != .english,
              let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else { return key }
        return languageBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let language = AppLanguage.current
        return String(format: string(key, language: language), locale: language.locale, arguments: arguments)
    }
}
