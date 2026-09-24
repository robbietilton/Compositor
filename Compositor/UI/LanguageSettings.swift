import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chinese
    var id: String { rawValue }

    /// The actual locale identifier; nil means "follow the system language".
    var appleLanguage: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .chinese: "zh-Hans"
        }
    }

    var displayName: String {
        switch self {
        case .system: String(localized: "Follow System", defaultValue: "Follow System")
        case .english: "English"
        case .chinese: "简体中文"
        }
    }
}

@Observable
final class LanguageSettings {
    static let shared = LanguageSettings()
    private static let storageKey = "preferredLanguage.v1"

    var selection: AppLanguage {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: Self.storageKey)
            apply(selection)
        }
    }

    @ObservationIgnored private let panel = FloatingPanelController(name: "language")

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        let value = AppLanguage(rawValue: raw) ?? .system
        selection = value
        // Apply persisted choice at launch (no restart needed for this pass).
        apply(value)
    }

    /// Push the choice into the classic AppleLanguages preference. A value of nil
    /// removes the override so the app falls back to the system language.
    private func apply(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        if let code = language.appleLanguage {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    func show() {
        panel.show(
            title: String(localized: "Language", defaultValue: "Language"),
            content: LanguageSheet(settings: self))
    }

    func close() { panel.close() }
}

private struct LanguageSheet: View {
    @Bindable var settings: LanguageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose the language for menus and panels.",
                 comment: "Language picker explanation")
                .font(.callout).foregroundStyle(.secondary)
            Picker("", selection: $settings.selection) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text("The new language takes effect after restarting Compositor.",
                 comment: "Language restart notice")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(String(localized: "Done", defaultValue: "Done")) {
                    settings.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
