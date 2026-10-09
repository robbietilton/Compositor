import SwiftUI

/// Add a language here once its Localizable.xcstrings translations are ready.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    static func selected(in defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "appLanguage")
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Lookup for display-only strings such as enum raw values. Never translate persisted identifiers.
nonisolated enum L10n {
    static func string(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

struct LanguageSettings: View {
    @State private var language = AppLanguage.selected()
    @State private var launchLanguage = AppLanguage.selected()

    var body: some View {
        Form {
            Picker("Language", selection: $language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.title).tag(language)
                }
            }
            Text("Language changes take effect the next time you open Compositor.")
                .font(.callout).foregroundStyle(.secondary)
            if language != launchLanguage {
                Text("Save your projects before quitting and reopening the app.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 200)
        .onChange(of: language) { _, value in value.save() }
    }
}
