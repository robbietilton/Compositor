import SwiftUI

struct SettingsView: View {
    @State private var preferences = LanguagePreferences.shared

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: Binding(get: { preferences.selection }, set: { preferences.select($0) })) {
                    ForEach(ApplicationLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language)
                    }
                }
                .accessibilityIdentifier("settings.language")
                Text("Choose the language for Compositor and the Camera Raw plugin.")
                    .foregroundStyle(.secondary)
                Text("Language changes take effect the next time Compositor opens. Your current documents stay open.")
                    .font(.callout).foregroundStyle(.secondary)
                if preferences.requiresRestart {
                    Label("Language saved. Quit and reopen Compositor when you are ready.", systemImage: "info.circle")
                        .font(.callout)
                        .accessibilityIdentifier("settings.language.restart")
                }
            } header: {
                Text("Interface")
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 480, height: 270)
        .navigationTitle("Settings")
        .preferredColorScheme(.dark)
    }
}
