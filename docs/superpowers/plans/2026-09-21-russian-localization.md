# Compositor Localization and Language Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Adobe-style English/Russian localization, a persistent live language selector, and a complete audited Russian UI without changing `.comp` serialization or existing keyboard behavior.

**Architecture:** Add a main-actor `AppLanguageStore` backed by versioned `UserDefaults`, inject its resolved `Locale` into the SwiftUI window and Settings scene, and use an Apple String Catalog as the only translation store. Migrate UI-facing enum labels and dynamic/error strings through a small `L10n` access layer while leaving every raw value, JSON key, UTI, and internal identifier stable.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Foundation `String(localized:)`, `Localizable.xcstrings`, Swift Testing, Xcode 26, macOS 12 deployment target, universal arm64/x86_64 build.

**Spec:** `docs/superpowers/specs/2026-09-21-russian-localization-design.md`

## Global Constraints

- Supported choices are exactly `system`, `english`, and `russian`; the persisted key is `app.language.v1`.
- English is the source language and fallback; Russian is complete for ordinary user-facing UI.
- All translations live in `Compositor/Resources/Localizable.xcstrings`; no runtime translation dictionary or language-specific `if` tree.
- `rawValue`, Codable representations, JSON keys, `.comp` manifests, UTIs, bundle IDs, filenames, debug logs, and test fixture names do not change.
- Preserve the current macOS 12 deployment target and universal arm64/x86_64 Release build.
- Every implementation task starts with a failing test, runs the smallest relevant test command, then commits its independently testable result.
- Use Adobe-compatible Russian terminology for Photoshop concepts, checked against the official Adobe Russian documentation linked in the design spec.
- Do not claim zero untranslated strings until the source audit and manual Russian UI checklist both pass.

---

### Task 1: Language model, persistence, Settings scene, and locale environment

**Files:**
- Create: `Compositor/Localization/AppLanguage.swift`
- Create: `Compositor/UI/SettingsView.swift`
- Test: `CompositorTests/LocalizationTests.swift`
- Modify: `Compositor/CompositorApp.swift`
- Modify: `README.md`

**Interfaces:**
- Produces `AppLanguage: String, CaseIterable, Codable, Identifiable` with cases `.system`, `.english`, `.russian` and stable raw values `system`, `english`, `russian`.
- Produces `@MainActor final class AppLanguageStore: ObservableObject` with `static let storageKey = "app.language.v1"`, `@Published var selection`, `var locale: Locale`, and dependency-injected `UserDefaults`/system locale for tests.
- Produces `SettingsView(languageStore:)` with a localized Language/Язык Picker and the three required choices.

- [ ] **Step 1: Write failing persistence and locale tests**

```swift
@Test @MainActor func appLanguageUsesStableRawValues() {
    #expect(AppLanguage.system.rawValue == "system")
    #expect(AppLanguage.english.rawValue == "english")
    #expect(AppLanguage.russian.rawValue == "russian")
}

@Test @MainActor func appLanguageStorePersistsAndRestoresSelection() {
    let suite = "LocalizationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let first = AppLanguageStore(defaults: defaults, systemLocale: Locale(identifier: "en_US"))
    first.selection = .russian
    let second = AppLanguageStore(defaults: defaults, systemLocale: Locale(identifier: "en_US"))
    #expect(second.selection == .russian)
    defaults.removePersistentDomain(forName: suite)
}

@Test @MainActor func appLanguageResolvesSupportedAndFallbackLocales() {
    #expect(AppLanguageStore(defaults: .standard, systemLocale: Locale(identifier: "ru_RU"), initial: .system).locale.identifier.hasPrefix("ru"))
    #expect(AppLanguageStore(defaults: .standard, systemLocale: Locale(identifier: "de_DE"), initial: .system).locale.identifier.hasPrefix("en"))
    #expect(AppLanguageStore(defaults: .standard, systemLocale: Locale(identifier: "en_US"), initial: .russian).locale.identifier.hasPrefix("ru"))
}
```

- [ ] **Step 2: Run the focused tests and verify the expected missing-type failure**

Run: `xcodebuild test -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' -only-testing:CompositorTests/LocalizationTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`

Expected: compile failure because `AppLanguage` and `AppLanguageStore` do not exist yet.

- [ ] **Step 3: Implement the minimal persistent language store**

```swift
@MainActor
final class AppLanguageStore: ObservableObject {
    static let storageKey = "app.language.v1"
    @Published var selection: AppLanguage { didSet { defaults.set(selection.rawValue, forKey: Self.storageKey) } }
    private let defaults: UserDefaults
    private let systemLocale: Locale

    init(defaults: UserDefaults = .standard, systemLocale: Locale = .current, initial: AppLanguage? = nil) {
        self.defaults = defaults
        self.systemLocale = systemLocale
        let saved = defaults.string(forKey: Self.storageKey).flatMap(AppLanguage.init(rawValue:))
        selection = initial ?? saved ?? .system
    }

    var locale: Locale {
        switch selection {
        case .english: Locale(identifier: "en")
        case .russian: Locale(identifier: "ru")
        case .system:
            systemLocale.language.languageCode?.identifier == "ru" ? Locale(identifier: "ru") : Locale(identifier: "en")
        }
    }
}
```

- [ ] **Step 4: Run `LocalizationTests` and verify persistence/locale behavior passes**

Run the focused command from Step 2. Expected: all language model tests pass.

- [ ] **Step 5: Add the Settings scene and live locale injection**

Use `@StateObject private var languageStore = AppLanguageStore()` in `CompositorApp`, pass it to `SettingsView`, and apply `.environment(\.locale, languageStore.locale)` to both `WindowGroup` content and Settings content. Add a standard `.settings { SettingsView(languageStore: languageStore) }` scene. Use `Text`/`Picker` localized keys in the view so the same UI changes between English and Russian.

- [ ] **Step 6: Add the README language instructions and run the focused tests again**

Document `Settings → Language` and the three choices under a new `Languages` section. Run `LocalizationTests` and `git diff --check`.

- [ ] **Step 7: Commit the independently testable infrastructure**

```bash
git add Compositor/Localization/AppLanguage.swift Compositor/UI/SettingsView.swift Compositor/CompositorApp.swift CompositorTests/LocalizationTests.swift README.md
git commit -m "feat: add persistent application language settings"
```

---

### Task 2: String Catalog, L10n access layer, and catalog integrity tests

**Files:**
- Create: `Compositor/Resources/Localizable.xcstrings`
- Create: `Compositor/Localization/L10n.swift`
- Create/modify: `CompositorTests/LocalizationTests.swift`
- Modify: `Compositor/CompositorApp.swift`

**Interfaces:**
- Produces named catalog keys grouped as `menu.*`, `tool.*`, `layer.*`, `mask.*`, `blend.*`, `adjustment.*`, `filter.*`, `dialog.*`, `error.*`, `history.*`, `status.*`, `accessibility.*`, and `settings.*`.
- Produces `L10n.string(_:locale:arguments:)`/equivalent helpers for AppKit and dynamic text, with English source defaults and explicit current locale.
- Produces catalog JSON integrity checks that compare the `en` and `ru` key sets and reject empty translations.

- [ ] **Step 1: Add a failing catalog integrity test**

```swift
@Test func englishAndRussianCatalogsHaveTheSameNonEmptyKeys() throws {
    let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Compositor/Resources/Localizable.xcstrings")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as! [String: Any]
    let strings = object["strings"] as! [String: Any]
    for (key, value) in strings {
        let localizations = (value as! [String: Any])["localizations"] as! [String: Any]
        #expect(localizations["en"] != nil, "Missing English localization for \(key)")
        #expect(localizations["ru"] != nil, "Missing Russian localization for \(key)")
    }
}
```

- [ ] **Step 2: Run the focused test and verify it fails because the catalog is absent**

Run: `xcodebuild test -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' -only-testing:CompositorTests/LocalizationTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`

Expected: file-not-found failure for `Localizable.xcstrings`.

- [ ] **Step 3: Add the String Catalog and its initial settings/menu entries**

Create valid Xcode String Catalog JSON with `sourceLanguage: "en"`, English `stringUnit` values, Russian `stringUnit` values, and comments for ambiguous terms. Start with all Task 1 Settings labels and the existing top-level menu/command keys; add every subsequent key in the same catalog rather than introducing a second translation store. Because the project uses a filesystem-synchronized root group, keep the resource under `Compositor/Resources` and verify Xcode includes it in the application target.

- [ ] **Step 4: Add the L10n access layer without a runtime dictionary**

Use named `LocalizedStringKey`/`String(localized:)` resources and interpolation helpers. A representative SwiftUI declaration is:

```swift
enum L10n {
    static let settingsLanguage = LocalizedStringKey("settings.language")
    static let settingsSystem = LocalizedStringKey("settings.language.system")

    static func text(_ key: String, locale: Locale) -> String {
        String(localized: String.LocalizationValue(key), locale: locale)
    }
}
```

Keep all actual English/Russian values in the catalog. Do not branch on `AppLanguage` to return translations.

- [ ] **Step 5: Extend tests for fallback and representative rendering keys**

Verify a missing/unsupported system locale resolves to English, known Russian keys return Russian values under `Locale(identifier: "ru")`, and unknown keys return their English source/default rather than the key itself.

- [ ] **Step 6: Run catalog tests and a debug build**

Run the focused tests, then: `xcodebuild build -project Compositor.xcodeproj -scheme Compositor -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.

- [ ] **Step 7: Commit the catalog infrastructure**

```bash
git add Compositor/Resources/Localizable.xcstrings Compositor/Localization/L10n.swift Compositor/CompositorApp.swift CompositorTests/LocalizationTests.swift
git commit -m "feat: add English and Russian localization catalog"
```

---

### Task 3: Stable enum display names and Adobe terminology

**Files:**
- Modify: `Compositor/Document/Filters.swift`
- Modify: `Compositor/Document/LayerAdjustment.swift`
- Modify: `Compositor/Document/LayerAppearance.swift`
- Modify: `Compositor/Document/Selection.swift`
- Modify: `Compositor/Document/ShapeTool.swift`
- Modify: `Compositor/Document/SmudgeLiquify.swift`
- Modify: `Compositor/Document/BrushStroke.swift`
- Modify: `Compositor/Document/LayerEffects.swift`
- Modify: `Compositor/Localization/L10n.swift`
- Modify: `Compositor/Resources/Localizable.xcstrings`
- Test: `CompositorTests/LocalizationTests.swift`

**Interfaces:**
- Every UI-facing enum keeps its existing raw value and gains `var localizedName: String` (or `displayName` for values used directly by SwiftUI).
- `LayerBlendMode` covers all current cases: Normal, Multiply, Screen, Overlay, Soft Light, Darken, Lighten, Difference, Color Dodge, Color Burn, Hue, Saturation, Color, Luminosity.
- Filter, adjustment, selection, shape, brush, blur, healing, and effect modes all have catalog entries in both locales.

- [ ] **Step 1: Write tests proving raw values remain stable and display names are localized**

```swift
@Test func enumDisplayNamesDoNotChangeSerializedValues() {
    #expect(LayerBlendMode.normal.rawValue == "Normal")
    #expect(LayerBlendMode.colorDodge.rawValue == "Color Dodge")
    #expect(FilterKind.contentAwareFill.rawValue == "Content-Aware Fill")
    #expect(AdjustmentKind.hsv.rawValue == "Hue/Saturation")
}

@Test func russianEnumDisplayNamesUseAdobeTerminology() {
    #expect(LayerBlendMode.normal.localizedName(locale: Locale(identifier: "ru")) == "Обычный")
    #expect(LayerBlendMode.multiply.localizedName(locale: Locale(identifier: "ru")) == "Умножение")
    #expect(FilterKind.contentAwareFill.localizedName(locale: Locale(identifier: "ru")) == "Заливка с учетом содержимого")
    #expect(AdjustmentKind.hsv.localizedName(locale: Locale(identifier: "ru")) == "Цветовой тон/Насыщенность")
}
```

- [ ] **Step 2: Run the tests and verify the new display-name API fails to compile**

Run the focused `LocalizationTests` command. Expected: missing `localizedName(locale:)` members.

- [ ] **Step 3: Add localized display-name properties and catalog entries**

Implement one switch per enum that returns a stable catalog key through `L10n.text`. Do not use `rawValue` as UI copy and do not change Codable declarations.

- [ ] **Step 4: Run enum localization tests and existing serialization tests**

Run: `xcodebuild test -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' -only-testing:CompositorTests/LocalizationTests -only-testing:CompositorTests/LayerAppearanceTests -only-testing:CompositorTests/ProjectTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.

- [ ] **Step 5: Commit the enum/display-name layer**

```bash
git add Compositor/Document Compositor/Localization/L10n.swift Compositor/Resources/Localizable.xcstrings CompositorTests/LocalizationTests.swift
git commit -m "feat: localize tool filter and blend mode names"
```

---

### Task 4: Menu bar, toolbar, tools, keyboard shortcuts, and accessibility

**Files:**
- Modify: `Compositor/CompositorApp.swift`
- Modify: `Compositor/ContentView.swift`
- Modify: `Compositor/UI/NavigationToolHeader.swift`
- Modify: `Compositor/UI/ToolHeaderStyle.swift`
- Modify: all tool control files in `Compositor/UI` (`BrushControls.swift`, `CloneStampToolIcon.swift` locations, `CropControls.swift`, `GradientControls.swift`, `LassoControls.swift`, `ShapeControls.swift`, `TypeControls.swift`, and related headers)
- Modify: `Compositor/UI/KeyboardShortcuts.swift`
- Modify: `Compositor/Resources/Localizable.xcstrings`
- Test: `CompositorTests/LocalizationTests.swift`

**Interfaces:**
- Menu titles and command labels use catalog keys; keyboard chord glyphs remain unchanged.
- Tools use `localizedName` and preserve shortcut letters/identifiers.
- `.help`, `.accessibilityLabel`, and `.accessibilityHint` use localized resources; `.accessibilityIdentifier` values remain unchanged.

- [ ] **Step 1: Add failing representative menu/tool/accessibility tests**

```swift
@Test func menuAndToolKeysHaveRussianValues() {
    let ru = Locale(identifier: "ru")
    #expect(L10n.text("menu.edit.undo", locale: ru) == "Отменить")
    #expect(L10n.text("menu.view.actualPixels", locale: ru) == "Реальный размер")
    #expect(L10n.text("tool.move", locale: ru) == "Перемещение")
    #expect(L10n.text("accessibility.tool.zoom", locale: ru) == "Инструмент масштаба")
}
```

- [ ] **Step 2: Run the test and verify missing catalog keys fail**

Run the focused localization test command and confirm the assertions fail before migration.

- [ ] **Step 3: Migrate `CompositorApp.swift` and `ContentView.swift`**

Replace literal command/menu/button labels and dynamic enum interpolations with localized keys or `localizedName`. Keep all shortcut modifiers and action closures unchanged. Ensure Settings and menu labels are rebuilt from the current `Locale`.

- [ ] **Step 4: Migrate tool headers, tooltips, and accessibility text**

Translate Move/Transform, Marquee, Lasso, Magic Wand, Object Selection, Crop, Brush, Spot Healing, Clone Stamp, Blur/Smudge/Liquify, Gradient, Shape, Type, Eyedropper, Zoom, and Hand. Keep system symbols and accessibility identifiers stable.

- [ ] **Step 5: Run localization tests and the existing UI shortcut suites**

Run `LocalizationTests`, `BlendShortcutTests`, `BrushTests`, `CanvasEntryTests`, and `CompositorTests` with serialized test execution. Expected: no shortcut behavior changes and all representative strings pass.

- [ ] **Step 6: Commit menus/tools/accessibility**

```bash
git add Compositor/CompositorApp.swift Compositor/ContentView.swift Compositor/UI Compositor/Resources/Localizable.xcstrings CompositorTests/LocalizationTests.swift
git commit -m "feat: localize menus tools and accessibility labels"
```

---

### Task 5: Layers, masks, blend modes, effects, defaults, and history

**Files:**
- Modify: `Compositor/UI/LayersPanel.swift`
- Modify: `Compositor/UI/LayerMaskMenu.swift`
- Modify: `Compositor/UI/LayerAppearanceControls.swift`
- Modify: `Compositor/UI/BlendModePicker.swift`
- Modify: `Compositor/UI/EffectsSheet.swift`
- Modify: `Compositor/Document/LayerGroups.swift`
- Modify: `Compositor/Document/LayerMask.swift`
- Modify: `Compositor/Document/LayerEffects.swift`
- Modify: `Compositor/Document/LayerAdjustment.swift`
- Modify: `Compositor/Document/EditorSession.swift` and extensions that create/edit names
- Modify: `Compositor/Resources/Localizable.xcstrings`
- Test: `CompositorTests/LocalizationTests.swift`, `CompositorTests/LayerTests.swift`, `CompositorTests/LayerMaskTests.swift`, `CompositorTests/GroupTests.swift`, `CompositorTests/HistoryTests.swift`

**Interfaces:**
- Display labels include Layers, New Layer, New Group, Duplicate, Delete, Rename, Merge, Opacity, Blend Mode, all mask operations, and all current effects.
- New displayed names use localized templates (`Слой 1`, `Группа 1`, `Фон`, `Без названия`) while saved project data stays compatible.
- Undo/history names are localized at display time or created from stable history identifiers; they do not alter history semantics.

- [ ] **Step 1: Add tests for localized defaults and stable project serialization**

```swift
@Test @MainActor func newLayerDisplayNameUsesCurrentLocaleWithoutChangingProjectSchema() {
    let session = EditorSession()
    session.createDocument(width: 100, height: 100)
    let before = try! JSONEncoder().encode(session.document)
    session.addBlankLayer()
    #expect(session.activeLayer?.name == "Layer 2" || session.activeLayer?.name == "Слой 2")
    let after = try! JSONEncoder().encode(session.document)
    #expect(!before.isEmpty && !after.isEmpty)
}
```

Add direct tests for every blend mode's Russian display name and mask operations while asserting JSON decoding still accepts the existing raw values.

- [ ] **Step 2: Run the new tests and confirm the current English/raw-value implementation fails the display-name assertions**

Run the affected test suites with `-parallel-testing-enabled NO` and record the expected failures.

- [ ] **Step 3: Introduce localized name templates and migrate the Layers UI**

Keep model `name` storage unchanged for opened projects. For newly generated names, use the selected UI locale only at creation time, and ensure an existing saved `Layer 1` is not silently rewritten to `Слой 1`.

- [ ] **Step 4: Migrate masks, blend modes, effects, context menus, and history labels**

Use Adobe terminology such as `Слой-маска`, `Обтравочная маска`, `Непрозрачность`, `Режим наложения`, `Обычный`, `Умножение`, `Экран`, `Перекрытие`, `Мягкий свет`, `Затемнение`, `Осветление`, `Разница`, `Осветление основы`, `Затемнение основы`, `Цветовой тон`, `Насыщенность`, `Цвет`, `Свечение`.

- [ ] **Step 5: Run layer/project/history regression tests and commit**

```bash
xcodebuild test -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' \
  -only-testing:CompositorTests/LocalizationTests \
  -only-testing:CompositorTests/LayerTests \
  -only-testing:CompositorTests/LayerMaskTests \
  -only-testing:CompositorTests/GroupTests \
  -only-testing:CompositorTests/HistoryTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
git add Compositor CompositorTests
git commit -m "feat: localize layers masks effects and history"
```

---

### Task 6: Adjustments, filters, sheets, dialogs, errors, dynamic text, and pluralization

**Files:**
- Modify: `Compositor/UI/LevelsSheet.swift`
- Modify: `Compositor/UI/CurvesControls.swift`
- Modify: `Compositor/UI/HueSaturationSheet.swift`
- Modify: `Compositor/UI/FilterSheet.swift`
- Modify: `Compositor/UI/CanvasSizeSheet.swift`
- Modify: `Compositor/UI/ImageSizeSheet.swift`
- Modify: `Compositor/UI/TransformInspector.swift`
- Modify: `Compositor/UI/ColorPickerSheet.swift`
- Modify: `Compositor/UI/JPEGExportSheet.swift`
- Modify: `Compositor/UI/NewCanvasSheet.swift`
- Modify: `Compositor/Document/Levels.swift`, `HueSaturation.swift`, `Filters.swift`, `ImageAdjustments.swift`, `CanvasSize.swift`, `LayerTransform.swift`, `SelectionEdits.swift`
- Modify: `Compositor/IO/ProjectStore.swift`, `ImageImporter.swift`, `ImageExporter.swift`, `CanvasResizer.swift`, `ProjectController.swift`
- Modify: every `LocalizedError` declaration found by `rg -n 'LocalizedError|errorDescription' Compositor`
- Modify: `Compositor/Localization/L10n.swift` and `Localizable.xcstrings`
- Test: `CompositorTests/LocalizationTests.swift` plus affected adjustment/filter/import/export/project suites

**Interfaces:**
- All visible labels and control values in Levels, Curves, Hue/Saturation, Exposure, Gradient Map, Grain, blur, motion blur, noise, lens correction, remove background, and content-aware fill use catalog keys.
- Errors use typed stable keys with interpolated values, never `error.localizedDescription` for an app-owned error whose text is currently English.
- Plural templates support English and Russian plural categories without concatenating translated fragments.

- [ ] **Step 1: Write failing tests for dynamic errors and Russian pluralization**

```swift
@Test func russianLayerSelectionUsesPluralCategories() {
    let ru = Locale(identifier: "ru")
    #expect(L10n.selectedLayers(1, locale: ru) == "Выбран 1 слой")
    #expect(L10n.selectedLayers(2, locale: ru) == "Выбрано 2 слоя")
    #expect(L10n.selectedLayers(5, locale: ru) == "Выбрано 5 слоёв")
}

@Test func projectErrorsUseLocalizedExplanationsAndKeepDynamicValues() {
    let message = ProjectError.invalid.localizedDescription(locale: Locale(identifier: "ru"))
    #expect(message == "Это невалидный проект Compositor или его метаданные повреждены.")
}
```

- [ ] **Step 2: Run the focused tests and verify the current English/nonexistent helper behavior fails**

Run `LocalizationTests`, `ProjectTests`, `ImageImportTests`, `ImageSizeTests`, `LevelsTests`, `HueSaturationTests`, `FilterTests`, `ExportTests`, and `JPEGExportTests` as a serialized subset.

- [ ] **Step 3: Add catalog interpolation/plural variations and typed error localization**

Represent the project error, unsupported format, damaged metadata, oversized canvas/image/file, invalid filter input, and export failures as stable localization keys. Preserve technical values such as format versions and dimensions as interpolated arguments.

- [ ] **Step 4: Migrate every adjustment/filter/sheet control**

Cover labels including Input Levels, Output Levels, Shadows, Midtones, Highlights, Gamma, Hue, Saturation, Lightness, Radius, Distance, Amount, Distribution, Monochromatic, Quality, Refine Edges, Matte Contrast, Shift Edge, Scale, Rotate, Position, Width, Height, Angle, Flip Horizontal/Vertical, Apply, Cancel, Preview, Quality, File Size, and all tooltips/empty states.

- [ ] **Step 5: Migrate native AppKit alerts, open/save panels, floating panel titles, and status messages**

Use `L10n.text` at creation time with the current locale. Keep system-provided file-type names and API-generated technical text unchanged when it is not owned by Compositor.

- [ ] **Step 6: Run affected suites and commit**

```bash
xcodebuild test -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' \
  -only-testing:CompositorTests/LocalizationTests \
  -only-testing:CompositorTests/ProjectTests \
  -only-testing:CompositorTests/ImageImportTests \
  -only-testing:CompositorTests/ImageSizeTests \
  -only-testing:CompositorTests/LevelsTests \
  -only-testing:CompositorTests/HueSaturationTests \
  -only-testing:CompositorTests/FilterTests \
  -only-testing:CompositorTests/ExportTests \
  -only-testing:CompositorTests/JPEGExportTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
git add Compositor CompositorTests
git commit -m "feat: localize adjustments filters dialogs and errors"
```

---

### Task 7: Source audit, layout pass, manual checklist, README, and release verification

**Files:**
- Create: `scripts/audit-localization.swift`
- Create: `docs/localization-audit.md`
- Modify: `README.md`
- Modify: any source file reported by the audit
- Test: `CompositorTests/LocalizationTests.swift`

**Interfaces:**
- `scripts/audit-localization.swift` runs from the repository root with `xcrun swift scripts/audit-localization.swift`, exits nonzero for missing locale keys or unclassified user-facing literals, and prints file/line/exception category.
- `docs/localization-audit.md` records the final manual pass across menu bar, toolbar, sidebar, layers, context menus, tools, headers, dialogs, settings, filters, adjustments, masks, selections, import/export, errors, shortcuts, tooltips, empty states, and layout clipping.

- [ ] **Step 1: Write the failing audit test/script**

Add a script test fixture that removes one Russian catalog entry and contains an unclassified `Text("Audit fixture")`; verify the audit reports both and exits with status 1. The production catalog and source scan must not depend on the fixture at runtime.

- [ ] **Step 2: Run the audit and verify it detects the fixture failures**

Run: `xcrun swift scripts/audit-localization.swift --fixture`.

Expected: nonzero exit with the missing Russian key and literal source location listed.

- [ ] **Step 3: Implement the real source/catalog audit**

Parse `Localizable.xcstrings` using Foundation JSON APIs, compare `en`/`ru` key sets and non-empty values, scan Swift call sites for `Text(`, `Button(`, `Label(`, `Menu(`, `Toggle(`, `Picker(`, `.help(`, `.accessibilityLabel(`, `.accessibilityHint(`, `NSAlert`, `NSMenuItem`, and app-owned `String(` values, and classify only explicit technical exceptions. Do not report `.accessibilityIdentifier` values.

- [ ] **Step 4: Run the audit, migrate every reported user-facing string, and record intentional exceptions**

Run: `xcrun swift scripts/audit-localization.swift`. The final output must state `Remaining untranslated user-facing strings: 0`; any technical English exception must be listed in `docs/localization-audit.md` with a reason.

- [ ] **Step 5: Perform the Russian layout/manual pass**

Launch the built app with Russian selected and inspect all areas from the spec. Check long labels in toolbar/sidebar/sheets, menu item clipping, Picker widths, alert text, context menus, accessibility descriptions, and live language changes back to English. Record each checked area and any intentional English technical term in `docs/localization-audit.md`.

- [ ] **Step 6: Run full unit tests and the localization audit**

```bash
xcodebuild test -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcrun swift scripts/audit-localization.swift
```

The unit command must report all unit suites passing. Existing unrelated UI-test failures must be reported separately rather than hidden.

- [ ] **Step 7: Build, sign, install, and verify the universal app**

```bash
xcodebuild build -project Compositor.xcodeproj -scheme Compositor -configuration Release -arch x86_64 -arch arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
codesign --force --deep --sign - <DerivedData>/Build/Products/Release/Compositor.app
codesign --verify --deep --strict <DerivedData>/Build/Products/Release/Compositor.app
lipo -archs <DerivedData>/Build/Products/Release/Compositor.app/Contents/MacOS/Compositor
./scripts/check-legacy-compatibility.sh <DerivedData>/Build/Products/Release/Compositor.app
```

Install only after all prior commands pass; move the currently installed app to a dated `/private/tmp` backup, copy the signed build to `/Applications/Compositor.app`, launch it, and verify the process starts.

- [ ] **Step 8: Commit audit, README, and release verification evidence**

```bash
git add scripts/audit-localization.swift docs/localization-audit.md README.md Compositor CompositorTests
git commit -m "feat: complete Russian localization audit"
git status --short
git log -1 --oneline
```

The final report must include changed files, catalog path, key count, supported languages, persistence key, restart behavior, menu/tool/filter/adjustment/context-menu/error/tooltip status, intentional English exceptions, audit output, unit-test result, Release build result, and installed app path.
