# Compositor Localization and Language Selection Design

**Date:** 2026-09-21  
**Status:** Approved direction; implementation pending  
**Scope:** English and Russian UI localization with a persistent language selector

## Goal

When the user chooses `Settings → Language → Русский`, all ordinary Compositor UI is displayed in Russian: menus, tools, layers, masks, adjustments, filters, dialogs, errors, tooltips, accessibility labels, empty states, dynamic messages, and default names. English remains the source language and fallback. The `.comp` project format and all serialized identifiers remain unchanged.

## Current project constraints

- The project has no existing String Catalog, `.strings` resources, or Settings/Preferences scene.
- The SwiftUI/AppKit UI is distributed across `CompositorApp.swift`, `ContentView.swift`, `Compositor/UI`, `Compositor/Document`, `Compositor/IO`, and `Compositor/Rendering`.
- User-facing strings currently exist in SwiftUI labels, tool headers, panel titles, AppKit alerts, error descriptions, tooltips, enum `rawValue` uses, and undo/history names.
- Existing `rawValue` values and Codable types are part of project compatibility and must not be translated in place.
- The application continues to support its current macOS deployment target and universal arm64/x86_64 build.

## Chosen architecture

### Language model and persistence

Create `Compositor/Localization/AppLanguage.swift` with:

```swift
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case english
    case russian
}
```

Create a main-actor `AppLanguageStore` that publishes the selected language and persists the stable raw value under a versioned UserDefaults key such as `app.language.v1`. The default is `.system`. Its resolved locale is:

- `.system`: the system locale when it has an English or Russian translation; otherwise English fallback;
- `.english`: `en`;
- `.russian`: `ru`.

The store is owned by `CompositorApp`, shared with the Settings scene, and injected into SwiftUI views. The root window and Settings scene receive `\.locale` from the store so changing the Picker causes SwiftUI to rebuild localized labels immediately. Native menus and already-open AppKit panels are recreated or refreshed when possible; if macOS keeps an existing native object unchanged, the persisted selection is applied on the next launch and the Settings screen explains that requirement only for that case.

### Apple localization resources

Add `Compositor/Resources/Localizable.xcstrings` to the application target with `en` and `ru` localizations. English is the source/base value. Russian translations use professional Adobe-compatible terminology, including:

- `Слои`, `Непрозрачность`, `Режим наложения`, `Растушёвка`, `Обтравочная маска`, `Корректирующий слой`;
- `Точечная восстанавливающая кисть`, `Заливка с учетом содержимого`, `Цветовой тон/Насыщенность`, `Уровни`, `Кривые`;
- `Размер холста`, `Размер изображения`, `Реальный размер`, `По размеру экрана`, `Отменить`, `Повторить`.

Terminology will be checked against Adobe's Russian Photoshop documentation rather than machine-translated literally. Relevant references include Adobe's pages for [opacity and blend modes](https://helpx.adobe.com/ru/photoshop/using/layer-opacity-blending.html), [spot healing brush](https://helpx.adobe.com/ru/photoshop/using/tool-techniques/spot-healing-brush.html), and [adjustment layers](https://helpx.adobe.com/ru/photoshop/desktop/create-manage-layers/color-adjustment-fill-layers/adjustment-and-fill-layers-overview.html).

### Localization access layer

Add `Compositor/Localization/L10n.swift` containing named localization resources/keys and helpers for dynamic values. SwiftUI labels use localized keys, while strings needed by AppKit, errors, history, tooltips, and accessibility use the helper with the current locale. The access layer is not a translation dictionary: translations live only in `Localizable.xcstrings`.

Key namespaces are stable and descriptive, for example:

```text
menu.file.save
tool.move
blend.normal
adjustment.hueSaturation
filter.gaussianBlur
dialog.canvasSize.width
error.project.invalid
history.layer.add
status.layers.selected
```

### Enum display names

For UI-facing enums such as `FilterKind`, `AdjustmentKind`, `LayerBlendMode`, `ShapeKind`, `SelectionMode`, `LassoKind`, and tool modes, add `localizedName`/`displayName` computed properties or protocol conformances. They resolve a catalog key but do not alter `rawValue`, Codable behavior, project files, filter execution, undo semantics, or internal comparisons.

### Dynamic text and pluralization

Dynamic strings use catalog interpolation and String Catalog plural variations. The selected locale is passed explicitly when the string is created outside SwiftUI. At minimum, layer-selection status covers `one`, `few`, and `many` Russian forms (`1 слой выбран`, `2 слоя выбрано`, `5 слоёв выбрано`) and the equivalent English forms. No user-facing string is assembled by concatenating translated fragments in code.

### Settings UI

Add a standard macOS `Settings` scene and a focused `SettingsView` with a `Language`/`Язык` section and Picker values:

- `System Default` / `Системный`;
- `English`;
- `Русский`.

The app name remains `Compositor`. Settings labels, Picker labels, window titles, restart guidance, and accessibility text are localized. The language choice is not written into project files.

## Migration scope

Migration is performed in independently testable batches:

1. Localization infrastructure, Settings scene, locale environment, catalog wiring, and persistence.
2. App menu bar, commands, toolbar, tools, keyboard-shortcut descriptions, and accessibility labels.
3. Layers, groups, masks, blend modes, effects, default names, context menus, and undo/history titles.
4. Adjustments, filters, tool headers, controls, canvas/image/transform sheets, color picker, export/import UI, and empty states.
5. Project/image/import/export errors, alerts, status messages, pluralization, tooltips, native panel titles, README, and final audit.

Technical identifiers, filenames, file formats, UTIs, bundle IDs, debug logs, test fixture names, serialization keys, and the application name are excluded from translation.

## Error and fallback behavior

Every user-facing `ProjectError`, `ImageImportError`, export error, filter error, and alert receives a stable catalog key. Unknown/missing Russian translations resolve to the English source value; a localization key must never be shown to the user. Technical details may remain technical, but surrounding explanatory text is localized.

## Testing and audit

Add `CompositorTests/LocalizationTests.swift` to verify:

- `AppLanguage` persistence and stable raw values;
- resolved locales for system/English/Russian and unsupported system locales;
- every catalog key has both English and Russian entries with non-empty values;
- enum display names use localized keys while Codable raw values remain unchanged;
- Russian plural forms and English fallback;
- representative menu, tool, layer, dialog, tooltip, accessibility, error, and default-name strings.

Add a dependency-free `scripts/audit-localization.swift` that parses the String Catalog, compares locale key sets, scans Swift source for user-facing literal call sites, and reports remaining exceptions with file/line numbers. The audit explicitly ignores IDs, file names, UTIs, bundle identifiers, serialization keys, debug logs, and test fixtures. The final report must include the complete exception list and may claim zero untranslated user-facing strings only after the source audit and manual UI pass both confirm it.

## Layout and compatibility requirements

Russian text must use flexible controls and sensible minimum widths. Toolbars, sidebars, Pickers, menus, sheets, and alerts must be checked for clipping and truncation. Existing project serialization tests remain mandatory; localization changes must not change `.comp` bytes, JSON keys, enum raw values, or loaded document semantics.

## Acceptance criteria

- Selecting Russian in Settings changes the ordinary interface to Russian without a normal app restart.
- English and System Default remain available and persist across launches.
- All ordinary user-facing UI categories in the request are represented in the catalog and source audit.
- Technical identifiers and project compatibility remain unchanged.
- Unit/localization tests pass; the universal Release build passes; the manual Russian UI checklist records every intentional English exception.
