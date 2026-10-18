import Foundation
import Observation

nonisolated enum ApplicationLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: AppLocalization.string("Follow System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    var preferredLanguages: [String]? {
        switch self {
        case .system: nil
        case .english, .simplifiedChinese: [rawValue]
        }
    }
}

/// Only the app's persistent domain is changed. Bundle localization takes effect on the next launch.
@MainActor @Observable
final class LanguagePreferences {
    static let shared = LanguagePreferences()
    private(set) var selection: ApplicationLanguage
    private let launchSelection: ApplicationLanguage
    @ObservationIgnored private let defaults: UserDefaults
    private let domainName: String
    static let storageKey = "AppleLanguages"

    init(defaults: UserDefaults = .standard, domainName: String = Bundle.main.bundleIdentifier ?? "com.wonderassembly.compositor") {
        self.defaults = defaults
        self.domainName = domainName
        let languages = defaults.persistentDomain(forName: domainName)?[Self.storageKey] as? [String]
        let choice = languages?.first.flatMap(ApplicationLanguage.init(rawValue:)) ?? .system
        selection = choice
        launchSelection = choice
    }

    var requiresRestart: Bool { selection != launchSelection }

    func select(_ language: ApplicationLanguage) {
        var domain = defaults.persistentDomain(forName: domainName) ?? [:]
        if let languages = language.preferredLanguages {
            domain[Self.storageKey] = languages
        } else {
            domain.removeValue(forKey: Self.storageKey)
        }
        defaults.setPersistentDomain(domain, forName: domainName)
        selection = language
    }
}
