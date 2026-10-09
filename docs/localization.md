# Localization

Compositor ships English and Simplified Chinese. Choose **Compositor → Settings… → Language** to follow the Mac's language or select English or 简体中文. Save open projects and reopen the app to apply a change. The setting uses an app-specific `AppleLanguages` override so SwiftUI, AppKit menus, and native file dialogs use the same language. Following the system removes that override.

## Adding a language

1. Add translations for the new locale to `Compositor/Localizable.xcstrings`. English is the source language and must remain complete. Keep format placeholders (`%@`, `%lld`, `%%`) intact; translate complete phrases rather than assembling word fragments.
2. Add the locale identifier and its native display name to `AppLanguage` in `Compositor/UI/LanguageSettings.swift`.
3. Add the locale to `knownRegions` in `Compositor.xcodeproj/project.pbxproj`.
4. Build and run `LocalizationTests`, then reopen the app in that language and check menus, settings, tools, panels, alerts, and command search. Check long labels and tooltips at the smallest supported window size.

SwiftUI literal labels use the catalog directly. Use `String(localized:)` for native AppKit labels and interpolated messages. Use `L10n.string` at the display boundary for existing string labels such as enum raw values. Missing entries fall back to the English key. Catalog symbol generation is disabled for the app because English keys include punctuation-only labels and names that collide after Swift symbol normalization.

Do not translate enum raw values, shortcuts, accessibility identifiers, preference keys, filenames, font names, or user-created project/layer/text content. Those values carry identity or are saved in projects. Native menus must store a stable model value in `representedObject` rather than recover it from a translated title. The project format is unchanged.
