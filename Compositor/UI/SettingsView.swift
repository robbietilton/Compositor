import SwiftUI

struct SettingsView: View {
    @ObservedObject var languageStore: AppLanguageStore

    var body: some View {
        Form {
            Section {
                Picker(L10n.key("settings.language"), selection: $languageStore.selection) {
                    Text(L10n.key("settings.language.system")).tag(AppLanguage.system)
                    Text(L10n.key("settings.language.english")).tag(AppLanguage.english)
                    Text(L10n.key("settings.language.russian")).tag(AppLanguage.russian)
                }
                .pickerStyle(.menu)
            } header: {
                Text(L10n.key("settings.language"))
            } footer: {
                Text(L10n.key("dialog.languageRestart"))
            }
        }
        .frame(width: 420)
        .padding()
    }
}

struct SettingsWindowRoot: View {
    @ObservedObject var languageStore: AppLanguageStore

    var body: some View {
        SettingsView(languageStore: languageStore)
            .environment(\.locale, languageStore.locale)
    }
}
