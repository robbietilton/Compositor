# Legacy macOS Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Compositor fork on `legacy-macos-support` build and run from macOS 12 onward as a Universal `x86_64`/`arm64` application without weakening security or redesigning the UI.

**Architecture:** Keep the current AppKit renderer, panels, file-provider flow, and editing model. Replace the macOS 14+ Observation dependency with Combine observation, isolate SwiftUI availability differences behind compatibility modifiers, and use AppKit for the remaining window lifecycle behavior that the current SwiftUI scene API cannot provide on macOS 12.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Combine, Core Image, Core Graphics, ImageIO, UniformTypeIdentifiers, Metal, Sparkle 2.10.0, Xcode 26.3, `xcodebuild`, `lipo`, `codesign`, and Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-21-legacy-macos-support-design.md`

## Global Constraints

- Preferred minimum deployment target: macOS 12.0.
- Required systems: macOS 12 Monterey, 13 Ventura, 14 Sonoma, 15 Sequoia, and newer releases.
- Required architectures: Intel `x86_64` and Apple Silicon `arm64`.
- No broad feature removal. A feature may be guarded or disabled only when its platform API has no safe equivalent.
- Keep Sparkle 2.10.0, EdDSA verification, HTTPS, App Sandbox, user-selected read/write, Hardened Runtime, and normal signing/notarization compatibility.
- Do not add `com.apple.security.cs.disable-library-validation`, JIT, unsigned executable memory, `get-task-allow` to Release, or any sandbox bypass.
- Do not add `Transferable`, `dropDestination`, `draggable`, `inspector`, `navigationSplitView`, or Apple-Silicon-only Metal APIs.
- Preserve the current visual hierarchy and behavior; compatibility fallbacks may only approximate unavailable cosmetic modifiers.
- Release validation must prove `lipo -archs Compositor.app/Contents/MacOS/Compositor` reports `x86_64 arm64`.

---

## File and interface map

### New files

- `Compositor/Compatibility/LegacySwiftUI.swift` — macOS 12-safe `onValueChangeCompat`, `onGeometryChangeCompat`, and guarded scroll modifiers.
- `Compositor/Compatibility/LegacyConcurrency.swift` — macOS 12-safe nanosecond sleep constants/helpers used by busy indicators and JPEG preview debounce.
- `CompositorTests/CompatibilityTests.swift` — focused tests for compatibility state transitions and observable change propagation.
- `scripts/check-legacy-compatibility.sh` — static configuration/security/API scan plus optional Universal binary checks.

### Modified files

- `Compositor.xcodeproj/project.pbxproj` — macOS 12 deployment target, Universal Release settings, and new source/test file references.
- `Compositor/CompositorApp.swift` — older main scene and AppKit show/reopen callback.
- `Compositor/ContentView.swift` — compatibility modifiers and AppKit-backed editor showing.
- `Compositor/UI/ProjectTabs.swift`, `Compositor/UI/ProjectWindowBridge.swift`, `Compositor/UI/FloatingPanel.swift`, `Compositor/UI/NativeLayerList.swift`, `Compositor/UI/KeyboardShortcuts.swift` — observation/window/toolbar compatibility and first-launch placement.
- `Compositor/UI/BrushControls.swift`, `CanvasSizeSheet.swift`, `ColorPaletteControls.swift`, `ColorPickerSheet.swift`, `CropControls.swift`, `CurvesControls.swift`, `EffectsSheet.swift`, `FilterSheet.swift`, `HueSaturationSheet.swift`, `ImageSizeSheet.swift`, `JPEGExportSheet.swift`, `LayerAppearanceControls.swift`, `NavigationToolHeader.swift`, `TransformInspector.swift`, `TypeControls.swift`, `LevelsSheet.swift`, `GradientControls.swift`, `LassoControls.swift`, `ShapeControls.swift`, `LayersPanel.swift` — migrate two-parameter change handlers and `@Bindable` properties.
- `Compositor/Document/ColorPalette.swift`, `DocumentHistory.swift`, `EditorSession.swift`, `Filters.swift`, `HueSaturation.swift`, `Levels.swift`, `ProjectWorkspace.swift` — Combine-backed model observation.
- `Compositor/Document/ProjectWorkspace.swift`, `Compositor/IO/ProjectController.swift`, `Compositor/UI/JPEGExportSheet.swift` — replace newer sleep conveniences and keep AppKit panel/security-scoped behavior.
- `Config/Info.plist`, `README.md`, and release documentation only if required by final Sparkle/feed validation; do not invent a new feed URL or signature.

---

### Task 1: Establish a reproducible baseline and compatibility guard

**Files:**
- Create: `scripts/check-legacy-compatibility.sh`
- Test: `Compositor.xcodeproj/project.pbxproj` through `xcodebuild -showBuildSettings`

**Interfaces:**
- Produces an executable script accepting an optional app bundle path: `scripts/check-legacy-compatibility.sh [path/to/Compositor.app]`.
- Returns exit 0 only when deployment settings, Sparkle pin, security entitlements, forbidden symbol scan, and any supplied binary checks pass.

- [ ] **Step 1: Capture the current baseline without changing source.**

  Run:

  ```sh
  xcodebuild -project Compositor.xcodeproj -scheme Compositor -configuration Debug \
    -sdk macosx -derivedDataPath /private/tmp/compositor-legacy-baseline \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages \
    build CODE_SIGNING_ALLOWED=NO
  ```

  Record the first failure and whether it is package-resolution, SDK, permission, or Swift compilation. Also run:

  ```sh
  xcodebuild -project Compositor.xcodeproj -scheme Compositor -configuration Debug \
    -showBuildSettings -derivedDataPath /private/tmp/compositor-legacy-settings \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages
  ```

- [ ] **Step 2: Write the failing guard checks before changing settings.**

  Create the script with these exact checks:

  ```sh
  #!/bin/zsh
  set -euo pipefail
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  PROJECT="$ROOT/Compositor.xcodeproj/project.pbxproj"
  ENTITLEMENTS="$ROOT/Config/Compositor.entitlements"
  RESOLVED="$ROOT/Compositor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

  if rg -n 'MACOSX_DEPLOYMENT_TARGET = ' "$PROJECT" | rg -v 'MACOSX_DEPLOYMENT_TARGET = 12\.0;' >/dev/null; then
      print -u2 "deployment target is not uniformly 12.0"
      exit 1
  fi
  rg -q '"version" : "2\.10\.0"' "$RESOLVED" || { print -u2 "Sparkle 2.10.0 is not pinned"; exit 1; }
  if rg -n 'disable-library-validation|allow-jit|allow-unsigned-executable-memory|get-task-allow' "$ENTITLEMENTS" >/dev/null; then
      print -u2 "forbidden security entitlement found"
      exit 1
  fi
  if rg -n 'Transferable|dropDestination|\.draggable\(|\.inspector\(|navigationSplitView|windowResizability' "$ROOT/Compositor" >/dev/null; then
      print -u2 "newer unsupported API found"
      exit 1
  fi
  if [[ $# -gt 0 ]]; then
      executable="$1/Contents/MacOS/Compositor"
      [[ -x "$executable" ]] || { print -u2 "missing app executable: $executable"; exit 1; }
      [[ "$(lipo -archs "$executable")" == *x86_64* ]] || exit 1
      [[ "$(lipo -archs "$executable")" == *arm64* ]] || exit 1
  fi
  print "legacy compatibility checks passed"
  ```

- [ ] **Step 3: Run the guard and confirm it fails for the expected upstream target.**

  Run `zsh scripts/check-legacy-compatibility.sh`.

  Expected: FAIL with `deployment target is not uniformly 12.0`, proving the guard catches the current configuration.

- [ ] **Step 4: Commit the baseline guard.**

  ```sh
  chmod +x scripts/check-legacy-compatibility.sh
  git add scripts/check-legacy-compatibility.sh
  git commit -m "test: add legacy compatibility guard"
  ```

### Task 2: Add macOS 12-safe SwiftUI and concurrency helpers

**Files:**
- Create: `Compositor/Compatibility/LegacySwiftUI.swift`
- Create: `Compositor/Compatibility/LegacyConcurrency.swift`
- Create: `CompositorTests/CompatibilityTests.swift`
- Modify: `Compositor.xcodeproj/project.pbxproj`

**Interfaces:**
- `View.onValueChangeCompat(of:perform:)` accepts an `Equatable` value and `(oldValue, newValue) -> Void` action.
- `View.onGeometryChangeCompat(for:of:action:)` accepts a result type, `GeometryProxy -> Value` transform, and `Value -> Void` action.
- `View.legacyScrollIndicatorsHidden()` and `View.legacyScrollBounceBasedOnSize()` preserve the current behavior on newer systems and are no-ops on macOS 12.
- `LegacyDelay.milliseconds(_:) -> UInt64` returns nanoseconds for `Task.sleep(nanoseconds:)`.

- [ ] **Step 1: Write the failing pure helper tests.**

  Add tests that assert the state-transition behavior needed by the view modifier and the delay conversion:

  ```swift
  import Testing

  @Test("legacy delay converts milliseconds to nanoseconds")
  func delayConversion() {
      #expect(LegacyDelay.milliseconds(30) == 30_000_000)
      #expect(LegacyDelay.milliseconds(250) == 250_000_000)
  }

  @Test("legacy change state reports the previous and new values")
  func changeState() {
      var state = LegacyChangeState(10)
      #expect(state.update(10) == nil)
      #expect(state.update(12)?.old == 10)
      #expect(state.update(12)?.new == 12)
  }
  ```

- [ ] **Step 2: Run the focused test target and verify it fails for missing helpers.**

  ```sh
  xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
    -destination 'platform=macOS' -derivedDataPath /private/tmp/compositor-legacy-tests \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages \
    -only-testing:CompositorTests/CompatibilityTests CODE_SIGNING_ALLOWED=NO
  ```

  Expected: compile failure because `LegacyDelay` and `LegacyChangeState` do not exist.

- [ ] **Step 3: Implement the helpers using only macOS 12-safe unconditional APIs.**

  The state helper must have this shape:

  ```swift
  struct LegacyChangeState<Value: Equatable> {
      private(set) var value: Value
      init(_ value: Value) { self.value = value }
      mutating func update(_ newValue: Value) -> (old: Value, new: Value)? {
          guard value != newValue else { return nil }
          let old = value
          value = newValue
          return (old, newValue)
      }
  }
  ```

  Implement `onValueChangeCompat` with the old one-parameter `.onChange(of:perform:)`, storing `LegacyChangeState` in `@State`. Implement geometry delivery with `GeometryReader`, a typed `PreferenceKey`, and the old `.onPreferenceChange`. Put newer `.scrollIndicators` and `.scrollBounceBehavior` calls only inside `if #available` branches. `LegacyDelay.milliseconds` must multiply a nonnegative `UInt64` by `1_000_000`.

- [ ] **Step 4: Run the focused tests and then the existing model tests.**

  ```sh
  xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
    -destination 'platform=macOS' -derivedDataPath /private/tmp/compositor-legacy-tests \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages \
    -only-testing:CompositorTests/CompatibilityTests CODE_SIGNING_ALLOWED=NO
  ```

  Expected: the two compatibility tests pass. Keep the full test invocation for Task 3 after the model compiles.

- [ ] **Step 5: Commit the compatibility helper layer.**

  ```sh
  git add Compositor/Compatibility CompositorTests/CompatibilityTests.swift Compositor.xcodeproj/project.pbxproj
  git commit -m "feat: add macOS 12 SwiftUI compatibility helpers"
  ```

### Task 3: Replace Observation with Combine-backed model observation

**Files:**
- Modify: `Compositor/Document/ColorPalette.swift`
- Modify: `Compositor/Document/DocumentHistory.swift`
- Modify: `Compositor/Document/EditorSession.swift`
- Modify: `Compositor/Document/Filters.swift`
- Modify: `Compositor/Document/HueSaturation.swift`
- Modify: `Compositor/Document/Levels.swift`
- Modify: `Compositor/Document/ProjectWorkspace.swift`
- Modify: `Compositor/UI/KeyboardShortcuts.swift`
- Modify: `CompositorTests/CompatibilityTests.swift`

**Interfaces:**
- `EditorSession`, `ProjectWorkspace`, `DocumentHistory`, `ColorPalette`, `FilterEdit`, `HueSaturationEdit`, `LevelsEdit`, and `ShortcutSettings` conform to `ObservableObject`.
- UI-visible mutable properties use `@Published`; caches, continuations, tasks, weak windows, and renderer-only state remain non-published.
- Nested models that are read through `EditorSession` forward `objectWillChange` to the owning session so menu and panel state updates remain equivalent to Observation.

- [ ] **Step 1: Add failing propagation tests.**

  Extend `CompatibilityTests.swift` with real Combine subscribers:

  ```swift
  import Combine

  @Test("session publishes a document change")
  @MainActor
  func sessionPublishesDocumentChange() {
      let session = EditorSession()
      var count = 0
      let cancellable = session.objectWillChange.sink { _ in count += 1 }
      session.canvasFocusRequest += 1
      #expect(count > 0)
      _ = cancellable
  }

  @Test("workspace publishes selected tab changes")
  @MainActor
  func workspacePublishesSelectionChange() {
      let workspace = ProjectWorkspace()
      let tab = workspace.addTab(reuseEmpty: false)
      var selected = false
      let cancellable = workspace.objectWillChange.sink { _ in selected = true }
      workspace.select(tab.id)
      #expect(selected)
      _ = cancellable
  }
  ```

- [ ] **Step 2: Run the tests and confirm the expected Observation-to-Combine compile failure.**

  ```sh
  xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
    -destination 'platform=macOS' -derivedDataPath /private/tmp/compositor-legacy-tests \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages \
    -only-testing:CompositorTests/CompatibilityTests CODE_SIGNING_ALLOWED=NO
  ```

  Expected: either the `Observation` module or `@Observable`/`@Bindable` declarations fail under `MACOSX_DEPLOYMENT_TARGET=12.0`, and the new Combine tests cannot find `objectWillChange`.

- [ ] **Step 3: Convert model declarations and tracked state.**

  In each listed model file:

  ```swift
  import Combine

  final class DocumentHistory: ObservableObject {
      @Published private(set) var canUndo = false
      // Existing history behavior and methods stay unchanged.
  }
  ```

  Remove `import Observation`, replace `@Observable` with `ObservableObject`, remove `@ObservationIgnored`, and add `@Published` only to properties read by SwiftUI/menu code. Preserve existing access control, initial values, `@MainActor`, and mutation methods. Add `@Published` to `ProjectWorkspace.tabs`, `selectedID`, and `isManaging`, and to all state properties in `EditorSession` that currently trigger view/menu updates. Do not publish `CGImage` caches, task handles, continuations, or Metal state.

- [ ] **Step 4: Add explicit forwarding for nested observable state.**

  In `EditorSession`, retain cancellables and forward child changes:

  ```swift
  private var observationCancellables: Set<AnyCancellable> = []

  private func bindNestedModels() {
      history.objectWillChange
          .receive(on: RunLoop.main)
          .sink { [weak self] _ in self?.objectWillChange.send() }
          .store(in: &observationCancellables)
  }
  ```

  Bind every nested `ObservableObject` that is read through a session or workspace view, and rebind when a nested edit object is replaced. Ensure subscriptions are installed after all stored properties are initialized and do not create retain cycles.

- [ ] **Step 5: Run the focused propagation tests and then all unit tests.**

  ```sh
  xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
    -destination 'platform=macOS' -derivedDataPath /private/tmp/compositor-legacy-tests \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages \
    -only-testing:CompositorTests/CompatibilityTests CODE_SIGNING_ALLOWED=NO

  xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
    -destination 'platform=macOS' -derivedDataPath /private/tmp/compositor-legacy-tests \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages CODE_SIGNING_ALLOWED=NO
  ```

  Expected: compatibility propagation tests and the existing document/rendering tests pass with no `Observation` import or macro diagnostics.

- [ ] **Step 6: Commit the model migration.**

  ```sh
  git add Compositor/Document Compositor/UI/KeyboardShortcuts.swift CompositorTests/CompatibilityTests.swift
  git commit -m "refactor: backport editor observation to Combine"
  ```

### Task 4: Migrate SwiftUI views and window lifecycle

**Files:**
- Modify: `Compositor/CompositorApp.swift`
- Modify: `Compositor/ContentView.swift`
- Modify: `Compositor/UI/ProjectTabs.swift`
- Modify: `Compositor/UI/ProjectWindowBridge.swift`
- Modify: all listed UI files in the file map containing `@Bindable` or two-parameter `.onChange`
- Modify: `Compositor/Document/ProjectWorkspace.swift`

**Interfaces:**
- No view contains `@Bindable`, `@Environment(\.openWindow)`, `ToolbarSpacer`, or an unconditional two-parameter `.onChange`.
- `ProjectWorkspaceView` observes the Combine-backed workspace and passes `@ObservedObject` sessions into child views.
- `CompositorApp` uses `WindowGroup` for the primary scene and `CompositorApplicationDelegate.showEditor` brings the existing AppKit window frontmost.

- [ ] **Step 1: Add a failing static compatibility test.**

  Before migration, run:

  ```sh
  if rg -n '@Bindable|openWindow|ToolbarSpacer|onGeometryChange|sharedBackgroundVisibility' Compositor; then
      exit 1
  fi
  ```

  Expected: FAIL with the current source locations.

- [ ] **Step 2: Replace view property wrappers and observation entry points.**

  In views that currently declare `@Bindable var session`, use:

  ```swift
  @ObservedObject var session: EditorSession
  ```

  In the workspace root, observe the workspace with `@ObservedObject` and pass the current session as an observed object. Keep `$session.property` bindings unchanged after the wrapper conversion; if a binding cannot be synthesized for a computed/nested value, preserve the existing explicit `Binding(get:set:)` form.

- [ ] **Step 3: Replace every two-parameter change handler with the compatibility modifier.**

  For example, change:

  ```swift
  .onChange(of: session.levels == nil) { _, closed in
      updatePanel(closed)
  }
  ```

  to:

  ```swift
  .onValueChangeCompat(of: session.levels == nil) { _, closed in
      updatePanel(closed)
  }
  ```

  Migrate all 33 two-parameter sites reported by the audit, including `ContentView`, control sheets, `ProjectTabs`, `NavigationToolHeader`, and `ColorPaletteControls`. Keep the old one-parameter form only when it compiles against the 12.0 deployment target; otherwise migrate it to a closure that ignores the old value.

- [ ] **Step 4: Replace new geometry and toolbar APIs while preserving layout.**

  Change both `ContentView` geometry calls to `.onGeometryChangeCompat`. Replace the fixed and flexible `ToolbarSpacer` entries with `ToolbarItem(placement: .navigation) { Spacer().frame(width: 8) }` and `ToolbarItem(placement: .navigation) { Spacer() }`. Remove `sharedBackgroundVisibility(.hidden)` because it is cosmetic and has no required Monterey equivalent. Replace direct scroll cosmetics with `.legacyScrollIndicatorsHidden()` and `.legacyScrollBounceBasedOnSize()`.

- [ ] **Step 5: Replace the main scene window actions and preserve first-launch placement.**

  Use an older primary scene:

  ```swift
  WindowGroup {
      ProjectWorkspaceView(applicationDelegate: applicationDelegate).roundedControls()
  }
  .defaultSize(width: 1180, height: 780)
  .commands { /* existing command groups unchanged */ }
  ```

  Remove `@Environment(\.openWindow)` from `ContentView`. Set `applicationDelegate.showEditor` to a closure that finds the existing editor window by identifier, calls `makeKeyAndOrderFront(nil)`, and activates `NSApp`. In `ProjectWindowView.viewDidMoveToWindow`, on the first launch only, set the frame to the screen’s `visibleFrame` and store a user-default marker; do not overwrite a restored frame. Keep `ProjectWindowBridge` as the close-confirmation delegate.

- [ ] **Step 6: Build the app at the old deployment target and run UI/model tests.**

  ```sh
  xcodebuild build -project Compositor.xcodeproj -scheme Compositor -configuration Debug \
    -sdk macosx -destination 'platform=macOS' \
    -derivedDataPath /private/tmp/compositor-legacy-debug \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages \
    MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGNING_ALLOWED=NO

  xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
    -destination 'platform=macOS' -derivedDataPath /private/tmp/compositor-legacy-tests \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages CODE_SIGNING_ALLOWED=NO
  ```

  Expected: the app compiles without unavailable SwiftUI/Observation diagnostics, and existing unit tests remain green.

- [ ] **Step 7: Commit the view/window compatibility migration.**

  ```sh
  git add Compositor/CompositorApp.swift Compositor/ContentView.swift Compositor/UI Compositor/Document/ProjectWorkspace.swift
  git commit -m "feat: backport SwiftUI window and view compatibility"
  ```

### Task 5: Backport concurrency conveniences and verify file/Metal fallbacks

**Files:**
- Modify: `Compositor/Document/ProjectWorkspace.swift`
- Modify: `Compositor/Document/EditorSession.swift`
- Modify: `Compositor/UI/JPEGExportSheet.swift`
- Modify: `Compositor/IO/ProjectController.swift`
- Modify: `Compositor/IO/ImageImporter.swift`
- Modify: `Compositor/IO/ImageExporter.swift`
- Modify: `Compositor/IO/ImageFileDrop.swift`
- Modify: `Compositor/Rendering/MetalBrushCoverage.swift`
- Modify: `Compositor/Rendering/MetalLayerEffects.swift`
- Modify: `CompositorTests/RasterSnapshotTests.swift`
- Modify: `CompositorTests/BrushPerformanceTests.swift`

**Interfaces:**
- All sleeps use `Task.sleep(nanoseconds:)` with `LegacyDelay.milliseconds(...)`.
- File import/export continues to use `NSOpenPanel`, `NSSavePanel`, `NSItemProvider`, `UTType`, and security-scoped URL access.
- Metal GPU paths remain optional and CPU fallback behavior remains available.

- [ ] **Step 1: Write a failing source scan for newer concurrency conveniences.**

  Run:

  ```sh
  rg -n 'Task\.sleep\(for:|Duration' Compositor
  ```

  Expected: the current three `Task.sleep(for:)` sites and `Duration` declaration are reported.

- [ ] **Step 2: Replace the three sleep sites.**

  Use:

  ```swift
  try? await Task.sleep(nanoseconds: LegacyDelay.milliseconds(30))
  try? await Task.sleep(nanoseconds: LegacyDelay.milliseconds(250))
  try? await Task.sleep(nanoseconds: LegacyDelay.milliseconds(200))
  ```

  Preserve cancellation behavior and existing delays exactly.

- [ ] **Step 3: Verify file-panel and provider behavior stays AppKit-based.**

  Run:

  ```sh
  rg -n 'NSOpenPanel|NSSavePanel|NSItemProvider|startAccessingSecurityScopedResource|stopAccessingSecurityScopedResource|UTType' Compositor/IO Compositor/Document/ProjectWorkspace.swift
  rg -n 'Transferable|dropDestination|draggable|fileExporter' Compositor
  ```

  Expected: existing AppKit/provider/security-scoped symbols remain; the second command produces no output. If async panel overloads produce a macOS 12 availability diagnostic, wrap them in a small AppKit continuation helper using `beginSheetModal(for:)` and `runModal()` without changing cancellation/error semantics.

- [ ] **Step 4: Add explicit Metal initialization/fallback assertions.**

  Keep `MetalBrushCoverage.shared` and `MetalLayerEffects.shared` optional. Add tests that invoke the existing rendering path and accept either a successful Metal result or the existing CPU result; never make tests require Apple Silicon. Ensure command buffers check `error`, shader lookup failures throw `ExportError.render`, and `LayerEffectsSurface`/`BrushStroke` still select CPU fallback when the optional GPU object is nil.

- [ ] **Step 5: Run focused import/export/render tests.**

  ```sh
  xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
    -destination 'platform=macOS' -derivedDataPath /private/tmp/compositor-legacy-tests \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages \
    -only-testing:CompositorTests/ImageImportTests \
    -only-testing:CompositorTests/ExportTests \
    -only-testing:CompositorTests/RasterSnapshotTests \
    -only-testing:CompositorTests/BrushPerformanceTests CODE_SIGNING_ALLOWED=NO
  ```

  Expected: import, export, snapshot, and brush/Metal tests pass or report only the host’s explicit lack of a Metal device; no crash or forced global CPU path.

- [ ] **Step 6: Commit concurrency and rendering compatibility changes.**

  ```sh
  git add Compositor/Document Compositor/UI/JPEGExportSheet.swift Compositor/IO Compositor/Rendering CompositorTests
  git commit -m "fix: backport concurrency and rendering fallbacks"
  ```

### Task 6: Set deployment/build/security configuration and release validation

**Files:**
- Modify: `Compositor.xcodeproj/project.pbxproj`
- Modify: `scripts/check-legacy-compatibility.sh`
- Modify: `README.md`
- Modify: `docs/legacy-macos-compatibility.md`
- Do not modify: `Config/Compositor.entitlements` unless the diff is a no-op normalization

**Interfaces:**
- App, unit-test, and UI-test targets resolve `MACOSX_DEPLOYMENT_TARGET = 12.0`.
- Release resolves `ARCHS = $(ARCHS_STANDARD)`, `ONLY_ACTIVE_ARCH = NO`, and has no `EXCLUDED_ARCHS` entry for `x86_64`.
- `scripts/check-legacy-compatibility.sh` validates settings and an optional app bundle.

- [ ] **Step 1: Write the failing configuration assertions.**

  Run:

  ```sh
  rg -n 'MACOSX_DEPLOYMENT_TARGET|ARCHS|ONLY_ACTIVE_ARCH|EXCLUDED_ARCHS' Compositor.xcodeproj/project.pbxproj
  zsh scripts/check-legacy-compatibility.sh
  ```

  Expected: the target still shows `26.5`, and the guard fails.

- [ ] **Step 2: Change all target/configuration deployment settings to 12.0.**

  Replace every project, app-target, test-target, and UI-test-target `MACOSX_DEPLOYMENT_TARGET = 26.5;` entry with `MACOSX_DEPLOYMENT_TARGET = 12.0;`. Add Release-only:

  ```text
  ARCHS = "$(ARCHS_STANDARD)";
  ONLY_ACTIVE_ARCH = NO;
  ```

  Remove any Intel exclusion if one appears. Leave `SWIFT_VERSION = 5.0`, `ENABLE_APP_SANDBOX = YES`, `ENABLE_HARDENED_RUNTIME = YES`, `CODE_SIGN_ENTITLEMENTS`, and network/user-selected file settings unchanged.

- [ ] **Step 3: Add the compatibility report and README build instructions.**

  `docs/legacy-macos-compatibility.md` must state the exact minimum, architecture policy, Sparkle 2.10.0 decision, API fallback categories, and the following reproducible commands:

  ```sh
  xcodebuild build -project Compositor.xcodeproj -scheme Compositor -configuration Release \
    -sdk macosx -derivedDataPath /private/tmp/compositor-legacy-release \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages \
    MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGNING_ALLOWED=NO
  zsh scripts/check-legacy-compatibility.sh \
    /private/tmp/compositor-legacy-release/Build/Products/Release/Compositor.app
  ```

  Do not replace the existing Sparkle feed URL or public key without a real compatibility-fork feed and a newly signed release. Document that the upstream appcast can safely reject updates whose minimum is above the current OS.

- [ ] **Step 4: Run the static guard and inspect entitlements.**

  ```sh
  zsh scripts/check-legacy-compatibility.sh
  plutil -p Config/Compositor.entitlements
  rg -n 'disable-library-validation|allow-jit|allow-unsigned-executable-memory|get-task-allow' Config Compositor.xcodeproj
  ```

  Expected: guard passes; only the intended sandbox/network/user-selected file and Sparkle mach lookup entitlements remain.

- [ ] **Step 5: Build a Release Universal app and verify architecture/load-command metadata.**

  ```sh
  xcodebuild build -project Compositor.xcodeproj -scheme Compositor -configuration Release \
    -sdk macosx -derivedDataPath /private/tmp/compositor-legacy-release \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages \
    MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO

  APP=/private/tmp/compositor-legacy-release/Build/Products/Release/Compositor.app
  lipo -archs "$APP/Contents/MacOS/Compositor"
  otool -l "$APP/Contents/MacOS/Compositor" | rg -A3 LC_BUILD_VERSION
  zsh scripts/check-legacy-compatibility.sh "$APP"
  ```

  Expected: `lipo` includes exactly `x86_64 arm64`; load commands show a macOS 12 minimum; guard passes. If a real Developer ID identity is available, run a separate signed archive/notarization dry run without changing entitlements.

- [ ] **Step 6: Commit configuration and documentation.**

  ```sh
  git add Compositor.xcodeproj/project.pbxproj scripts/check-legacy-compatibility.sh README.md docs/legacy-macos-compatibility.md
  git commit -m "build: target macOS 12 with universal release settings"
  ```

### Task 7: Full verification and handoff

**Files:**
- Modify only if verification exposes a concrete failure in the previous tasks.

- [ ] **Step 1: Run the complete unit-test suite from a clean derived-data path.**

  ```sh
  rm -rf /private/tmp/compositor-legacy-final-tests
  xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
    -destination 'platform=macOS' -derivedDataPath /private/tmp/compositor-legacy-final-tests \
    -clonedSourcePackagesDirPath /private/tmp/compositor-legacy-packages CODE_SIGNING_ALLOWED=NO
  ```

  Expected: exit 0 and zero failed tests. UI tests are run separately only if the host exposes a usable macOS UI-test destination.

- [ ] **Step 2: Run the final static and Universal checks.**

  ```sh
  zsh scripts/check-legacy-compatibility.sh \
    /private/tmp/compositor-legacy-release/Build/Products/Release/Compositor.app
  git diff --check main...HEAD
  git status --short --branch
  ```

  Expected: the guard passes, diff check is clean, and the working tree is clean on `legacy-macos-support`.

- [ ] **Step 3: Inspect the final diff against the spec.**

  Verify that each requirement has evidence: macOS 12 build setting, no unconditional newer SwiftUI/Observation APIs, preserved panels/providers/security, Sparkle 2.10 pin, Metal fallback, `x86_64`/`arm64` slices, and no forbidden entitlement. Record any host limitations explicitly rather than claiming runtime validation that was not performed.

- [ ] **Step 4: Report the branch, commits, verification results, and any environment limitation.**

  The final report must link the compatibility report and specify exact command output for `lipo`, tests, and security checks. If Monterey/Intel runtime hardware was not available, say so and distinguish static/build evidence from runtime evidence.
