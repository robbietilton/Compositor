# Compositor 1.2.0 Compatibility Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate upstream Compositor `v1.2.0` into `legacy-macos-support` while preserving macOS 12 compatibility, English/Russian localization, the stable custom Settings command, browser-image paste, and existing project-file compatibility.

**Architecture:** Treat upstream `v1.2.0` commit `28855e6` as a source update from the existing `v1.1.8` ancestor. Bring in the new PSD reader/conversion flow, Outer Glow, effect persistence, brush smoothing, and upstream fixes first; then resolve conflicts in the fork-owned compatibility, localization, and Settings layers explicitly. Keep all user-visible language strings in the existing String Catalog and keep persisted/raw project identifiers unchanged.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Combine, Core Image, Core Graphics, ImageIO, Metal with CPU fallback, Sparkle 2.10.0, Xcode 26, `xcodebuild`, Swift Testing, and XCTest UI tests.

**Spec:** `docs/superpowers/specs/2026-09-21-legacy-macos-support-design.md` and `docs/superpowers/specs/2026-09-21-russian-localization-design.md`

## Global Constraints

- Preserve the macOS 12.0 deployment target and universal `x86_64`/`arm64` release configuration.
- Preserve Sparkle 2.10.0, HTTPS update feed behavior, signing requirements, App Sandbox, and existing entitlements.
- Keep `AppLanguage` raw values, `app.language.v1`, JSON keys, `.comp` manifests, UTIs, bundle identifiers, and saved project identifiers unchanged.
- Keep English as the source language and Russian as the complete supported translation in `Compositor/Resources/Localizable.xcstrings`.
- Keep the custom single Settings command and direct settings window; do not restore SwiftUI’s system-locale `Settings` scene.
- Preserve browser clipboard-image paste and new-canvas size inference.
- Do not claim PSD support is complete until real PSD fixtures and round-trip tests pass.

## File and interface map

### Upstream files to add or retain

- `Compositor/IO/PSD/PSDChannelCoder.swift` — PSD channel decompression and decoding.
- `Compositor/IO/PSD/PSDDocumentBuilder.swift` — editable Compositor document construction.
- `Compositor/IO/PSD/PSDReader.swift` — PSD parsing and conversion report data.
- `Compositor/IO/PSD/PSDTypes.swift` — PSD model types.
- `Compositor/IO/PSD/PSDVector.swift` — vector/fill shape conversion.
- `Compositor/UI/PSDConversionSheet.swift` — conversion report UI.
- `CompositorTests/OuterGlowTests.swift`, `PSDFixture.swift`, `PSDRoundTripTests.swift`, and `PSDVectorFixtures.swift` — upstream regression coverage.

### Fork-owned files requiring conflict review

- `Compositor.xcodeproj/project.pbxproj` — merge upstream source references without losing compatibility files or String Catalog membership.
- `Compositor/CompositorApp.swift` — merge upstream commands while preserving the custom `.appSettings` command and no SwiftUI `Settings` scene.
- `Compositor/ContentView.swift`, `Document/EditorSession.swift`, `Document/LayerEffects.swift`, `Rendering/MetalLayerEffects.swift`, and related files — merge behavior, then reapply localization and macOS 12-safe APIs.
- `Compositor/IO/ImageImporter.swift`, `IO/ImageFileDrop.swift`, and `IO/ProjectStore.swift` — preserve clipboard paste and project compatibility while taking upstream importer/effect changes.
- `Compositor/Localization/*`, `Compositor/Resources/Localizable.xcstrings`, and `Compositor/UI/SettingsView.swift` — add translations for new UI without introducing a second localization system.
- `Compositor/IO/CompositorApplicationDelegate.swift` — preserve the direct settings window implementation and updater lifecycle.
- `CompositorTests/*` and `CompositorUITests/CompositorUITests.swift` — combine upstream tests with localization, Settings, paste, and compatibility coverage.
- `Config/Info.plist`, `README.md`, `appcast.xml`, and `docs/project-format.md` — update version/release documentation only after verifying fork feed and security constraints.

### Task 1: Capture a clean integration baseline

**Files:**
- Create: `docs/superpowers/plans/2026-09-21-compositor-1.2.0-compatibility.md`
- Inspect: current `git diff`, `git status`, `v1.1.8`, `v1.2.0`, and `HEAD`

- [ ] **Step 1: Preserve the existing uncommitted work before integration.**

Run:

```sh
git status --short
git diff --check
git diff -- Compositor/CompositorApp.swift Compositor/IO/CompositorApplicationDelegate.swift \
  Compositor/UI/SettingsView.swift Compositor/Resources/Localizable.xcstrings \
  CompositorUITests/CompositorUITests.swift
```

Expected: only the already-known fork changes are present; no unrelated user edits are overwritten.

- [ ] **Step 2: Record the upstream release boundary.**

Run:

```sh
git merge-base --is-ancestor v1.1.8 v1.2.0
git diff --name-status v1.1.8..v1.2.0
git show -s --format='%H%n%s%n%ad' v1.2.0
```

Expected: `v1.2.0` resolves to commit `28855e684d0b99dd23f6505af718a342cb3af3d2`, with the upstream PSD/effects/import changes listed in this plan.

### Task 2: Bring in PSD import and conversion reporting

**Files:**
- Add: `Compositor/IO/PSD/*.swift`
- Add: `Compositor/UI/PSDConversionSheet.swift`
- Add: `CompositorTests/PSDFixture.swift`, `CompositorTests/PSDRoundTripTests.swift`, `CompositorTests/PSDVectorFixtures.swift`
- Modify: `Compositor.xcodeproj/project.pbxproj`, `Compositor/IO/ImageImporter.swift`, `Compositor/IO/ImageFileDrop.swift`, `Compositor/UI/ProjectTabs.swift`

- [ ] **Step 1: Add the upstream PSD sources and fixture tests without resolving unrelated UI conflicts.**

Use the exact files from `v1.2.0`, add them to the Xcode target, and run the smallest PSD test command:

```sh
xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS' -only-testing:CompositorTests/PSDRoundTripTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: the tests either pass or fail only on missing target references; do not mask parser failures.

- [ ] **Step 2: Connect PSD files to image/project import paths.**

Preserve existing raster import and browser clipboard behavior. PSD files must open through the conversion report sheet, while PNG/JPEG/clipboard paths retain their current `ImageImporter` behavior.

- [ ] **Step 3: Run PSD and existing clipboard/project tests.**

```sh
xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS' -only-testing:CompositorTests/PSDRoundTripTests \
  -only-testing:CompositorTests/ProjectTests \
  -only-testing:CompositorTests/SelectionClipboardTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: PSD conversion, `.comp` persistence, and browser-image clipboard behavior all pass.

### Task 3: Merge Outer Glow and effect persistence

**Files:**
- Modify: `Compositor/Document/LayerEffects.swift`, `Document/ImageAdjustments.swift`, `Document/EditorSession.swift`
- Modify: `Compositor/Rendering/LayerEffectsSurface.swift`, `Rendering/MetalLayerEffects.swift`, `Rendering/EffectsPreviewCache.swift`, `Rendering/SeparableBlend.swift`
- Modify: `Compositor/UI/EffectsSheet.swift`, `UI/NativeLayerList.swift`
- Add/modify: `CompositorTests/OuterGlowTests.swift`, effect-related tests

- [ ] **Step 1: Port upstream model and render changes while preserving fork observation types.**

Take the upstream effect fields, encoding, preview, and render math. Keep the fork’s Combine/`ObservableObject` model shape and CPU fallback for macOS 12; do not reintroduce `Observation`-only APIs.

- [ ] **Step 2: Add localized names and labels for new effect controls.**

Add English/Russian catalog keys for Outer Glow, its controls, and any new history/error strings. Keep all saved effect identifiers and Codable keys equal to upstream values.

- [ ] **Step 3: Run focused effect and serialization tests.**

```sh
xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS' -only-testing:CompositorTests/OuterGlowTests \
  -only-testing:CompositorTests/LayerTests -only-testing:CompositorTests/ProjectTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: Outer Glow renders, saves, and reopens without losing effect data.

### Task 4: Merge upstream brush, Levels, blending, and project fixes

**Files:**
- Modify: `Compositor/Document/BrushStroke.swift`, `Document/EditorSession+Brush.swift`, `Document/Levels.swift`, `Document/ShapeTool.swift`
- Modify: `Compositor/Rendering/EditorCanvas.swift`, `Rendering/SeparableBlend.swift`
- Modify: `Compositor/ContentView.swift`, `Compositor/UI/BrushControls.swift`, `UI/EffectsSheet.swift`
- Modify: corresponding unit tests

- [ ] **Step 1: Port brush smoothing and the upstream rendering fixes.**

Keep existing shortcut routing, tool identifiers, selection semantics, Metal optionality, and legacy CPU fallback. Add focused tests for smoothing and preserve current paste/new-canvas paths.

- [ ] **Step 2: Port Levels/color-space/project-save fixes.**

Verify that soft-edge Levels behavior, Color Dodge/Color Burn blending, and dimmed-folder saves preserve existing `.comp` serialization.

- [ ] **Step 3: Run the focused regression set.**

```sh
xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS' -only-testing:CompositorTests/BrushTests \
  -only-testing:CompositorTests/LevelsTests -only-testing:CompositorTests/FilterTests \
  -only-testing:CompositorTests/ProjectTests -only-testing:CompositorTests/SelectionClipboardTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

### Task 5: Reconcile app commands, localization, and Settings

**Files:**
- Modify: `Compositor/CompositorApp.swift`, `Compositor/ContentView.swift`
- Modify: `Compositor/IO/CompositorApplicationDelegate.swift`, `Compositor/UI/SettingsView.swift`
- Modify: `Compositor/Resources/Localizable.xcstrings`, `CompositorTests/LocalizationTests.swift`, `CompositorUITests/CompositorUITests.swift`

- [ ] **Step 1: Write failing localization/UI assertions for v1.2.0 additions.**

Add tests for the new PSD conversion labels, Outer Glow labels, and the existing invariant:

```swift
XCTAssertTrue(app.menuItems["Settings…"].waitForExistence(timeout: 2))
XCTAssertTrue(app.popUpButtons.firstMatch.waitForExistence(timeout: 2))
```

Run the focused UI/localization tests and verify missing new keys or command conflicts fail before implementation.

- [ ] **Step 2: Resolve `CompositorApp` command-builder conflicts.**

Keep exactly one `.appSettings` command that calls `showSettings(languageStore:)`, keeps `⌘,`, and opens the direct settings window. Merge upstream command additions without restoring `Settings { ... }` or the old AppKit menu-normalization race.

- [ ] **Step 3: Add all new user-facing strings to the String Catalog.**

Use English source text and Adobe-compatible Russian terminology. Keep accessibility identifiers, raw values, project keys, and test fixture names unchanged.

- [ ] **Step 4: Run focused localization and four Settings UI scenarios.**

```sh
xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS' \
  -only-testing:CompositorTests/LocalizationTests \
  -only-testing:CompositorUITests/CompositorUITests/testEnglishSettingsMenuAppearsImmediatelyAfterLaunch \
  -only-testing:CompositorUITests/CompositorUITests/testEnglishAppMenuContainsSettings \
  -only-testing:CompositorUITests/CompositorUITests/testRussianAppMenuContainsOnlyRussianSettings \
  -only-testing:CompositorUITests/CompositorUITests/testLanguageChangeAppliesAfterRestart \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: English and Russian each show exactly one working Settings item; language selection persists after a full restart.

### Task 6: Update metadata and compatibility configuration

**Files:**
- Modify: `Config/Info.plist`, `README.md`, `appcast.xml`, `docs/project-format.md`, `Compositor.xcodeproj/project.pbxproj`

- [ ] **Step 1: Update the app version to upstream `1.2.0` while preserving fork release behavior.**

Set the application version/build fields to the intended fork release values, keep the existing Sparkle feed URL/public key unless a separate signed fork feed exists, and document that this is a compatibility build based on upstream `v1.2.0`.

- [ ] **Step 2: Run static compatibility and resource checks.**

```sh
git diff --check
jq empty Compositor/Resources/Localizable.xcstrings
xcrun xcstringstool compile Compositor/Resources/Localizable.xcstrings \
  --output-directory /private/tmp/compositor-1.2.0-xcstrings --dry-run
zsh scripts/check-legacy-compatibility.sh
```

Expected: no whitespace/catalog errors and no unsupported macOS 12 API or security-entitlement violations.

### Task 7: Full verification, release build, and installation

**Files:**
- Modify only if verification exposes a regression.
- Build output: `.build/` (ignored)

- [ ] **Step 1: Run the complete unit suite.**

```sh
xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
  -destination 'platform=macOS' -only-testing:CompositorTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: zero failed tests.

- [ ] **Step 2: Build Debug and Release, then verify the binary.**

```sh
xcodebuild build -project Compositor.xcodeproj -scheme Compositor -configuration Release \
  -derivedDataPath .build/ReleaseDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
lipo -archs .build/ReleaseDerivedData/Build/Products/Release/Compositor.app/Contents/MacOS/Compositor
```

Expected: build succeeds, and the binary reports `x86_64 arm64`.

- [ ] **Step 3: Verify a real PSD import, effect persistence, clipboard paste, and Settings after restart.**

Use the existing PSD fixture plus a browser-copied raster image. Confirm PSD layers/folders/masks/clipping convert, Outer Glow survives save/reopen, Cmd-N/Cmd-V creates/imports the clipboard image, and English/Russian Settings remains a single working menu item after quitting and reopening.

- [ ] **Step 4: Install only after all verification passes.**

Move the currently installed app to a timestamped recoverable backup, copy the verified app to `/Applications/Compositor.app`, ad-hoc sign for local launch, verify with `codesign --verify --deep --strict`, and launch with `open -a /Applications/Compositor.app`.

- [ ] **Step 5: Report exact scope and limitations.**

Report the upstream base commit, installed version/build, unit/UI test counts, architecture output, and any host limitations. Do not claim Monterey/Intel runtime validation unless it was actually run.
