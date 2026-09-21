import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case english
    case russian

    var id: String { rawValue }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    static let storageKey = "app.language.v1"

    @Published var selection: AppLanguage {
        didSet {
            defaults.set(selection.rawValue, forKey: Self.storageKey)
        }
    }

    private let defaults: UserDefaults
    private let systemLocale: Locale

    init(
        defaults: UserDefaults = .standard,
        systemLocale: Locale = .current,
        initial: AppLanguage? = nil
    ) {
        self.defaults = defaults
        self.systemLocale = systemLocale
        let saved = defaults.string(forKey: Self.storageKey).flatMap(AppLanguage.init(rawValue:))
        selection = initial ?? saved ?? .system
    }

    var locale: Locale {
        switch selection {
        case .english:
            return Locale(identifier: "en")
        case .russian:
            return Locale(identifier: "ru")
        case .system:
            return systemLocale.languageCode?.lowercased() == "ru"
                ? Locale(identifier: "ru")
                : Locale(identifier: "en")
        }
    }
}
