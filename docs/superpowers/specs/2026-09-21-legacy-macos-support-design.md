# Legacy macOS Support Design

## Goal

Create a compatibility fork of Compositor on branch `legacy-macos-support` that launches on macOS 12 Monterey and later, preserves the existing UI and editing behavior, and produces a signed-capable Universal macOS app containing both `x86_64` and `arm64` slices.

## Scope and success criteria

- Preferred minimum deployment target: macOS 12.0.
- Required systems: macOS 12 Monterey, 13 Ventura, 14 Sonoma, 15 Sequoia, and newer releases.
- Required architectures: Intel `x86_64` and Apple Silicon `arm64`.
- No broad feature removal. A feature may be guarded or disabled only when its platform API has no safe equivalent.
- Existing canvas, layers, tabs, import/export, keyboard shortcuts, panels, Metal rendering, sandbox, hardened runtime, and Sparkle update verification remain functional.
- Release validation must prove the built executable reports `x86_64 arm64` through `lipo -archs`.

The local checkout is the compatibility fork. Publishing to a separate GitHub fork is intentionally out of scope because no destination account or repository URL was supplied.

## Findings from the source audit

The upstream project currently targets macOS 26.5 and Xcode 26.3. The source uses:

- SwiftUI `Window`, `openWindow`, `defaultWindowPlacement`, and modern toolbar APIs.
- `onGeometryChange`, two-parameter `onChange`, `ToolbarSpacer`, `sharedBackgroundVisibility`, `scrollBounceBehavior`, and `scrollIndicators`.
- The Observation framework through `@Observable`, `@Bindable`, and `@ObservationIgnored` in the editor/session model and views.
- AppKit `NSOpenPanel`, `NSSavePanel`, `NSItemProvider`, security-scoped URLs, and existing AppKit window/panel bridges.
- Core Image, ImageIO, Uniform Type Identifiers, and runtime-compiled Metal compute pipelines.
- Sparkle 2.10.0 through Swift Package Manager.

Sparkle 2.10.0 is retained: the official Sparkle release notes and documentation state that 2.10 requires macOS 12.0 or later and supports sandboxed applications, EdDSA signatures, and Apple code signing. No Sparkle downgrade is required.

## Compatibility matrix

| API family | Minimum relevant OS | Current use | Compatibility treatment |
| --- | ---: | --- | --- |
| `Window` scene / `openWindow` | macOS 13+ | Main editor scene and reopen callback | Use the older `WindowGroup` scene for the main window and an AppKit-backed show/reopen closure. Keep one editor window and preserve the current tab model. |
| `defaultWindowPlacement` | macOS 15+ | Initial full visible-display placement | Move first-launch placement into the existing AppKit window bridge. Do not disturb restored window frames. |
| `ToolbarSpacer` / `sharedBackgroundVisibility` | macOS 26-era SwiftUI | Editor toolbar spacing and appearance | Replace with `ToolbarItem`/`Spacer` and omit the cosmetic background modifier on older systems. |
| `@Observable`, `@Bindable`, Observation macros | macOS 14+ | Session, workspace, panels, filter/edit state | Replace the UI-facing model layer with `ObservableObject`/`@Published` and `@ObservedObject`/`@StateObject`; explicitly forward changes from nested observable models where the old Observation graph tracked them automatically. |
| two-parameter `.onChange` | macOS 14+ | 33 view sites | Add a compatibility modifier backed by the old one-parameter `.onChange`, retaining old/new values through local state, then migrate all call sites. |
| `onGeometryChange` | macOS 17/15 SDK family | Canvas and toolbar width measurement | Add a `GeometryReader` + `PreferenceKey` compatibility modifier. |
| `scrollIndicators` / `scrollBounceBehavior` | newer SwiftUI releases | Cosmetic scroll behavior | Guard where useful and use no-op visual fallbacks on Monterey. Scrolling itself remains available. |
| `fileImporter` / `onDrop` / `NSItemProvider` | macOS 11+ family | Image import and drag/drop | Keep the existing provider-based path. Use AppKit `NSOpenPanel`/`NSSavePanel` for project and export dialogs; do not introduce `Transferable`, `dropDestination`, or `draggable`. |
| Uniform Type Identifiers | macOS 11+ | File and project types | Keep `UTType`; preserve declared document types and security-scoped access. |
| `Task.sleep(for:)` / newer Duration conveniences | newer Swift runtime/SDK | Busy indicators and JPEG preview debounce | Replace with `Task.sleep(nanoseconds:)` constants or a small compatibility helper. Keep async work and cancellation semantics unchanged. |
| Core Image / ImageIO / Core Graphics | macOS 12 compatible | Import, export, filters, compositing | No API replacement expected; compile and test with the 12.0 deployment floor. |
| Metal compute pipelines | Metal 2-capable Intel/AMD and Apple GPUs | Brush coverage and layer effects | Keep GPU paths. Validate device, queue, library, functions, buffers, and command completion; retain current CPU fallbacks when initialization or execution fails. |
| Sparkle 2.10 | macOS 12+ | Signed update checks | Keep version 2.10.0, EdDSA public key, HTTPS feed, sandbox helper entitlements, and code-signing requirements. Compatibility appcast entries must advertise the correct minimum system version. |

No project usage of `Transferable`, `dropDestination`, `draggable`, `inspector`, `navigationSplitView`, `windowResizability`, Swift macros beyond Observation, or Apple-Silicon-only Metal APIs was found in the initial scan. A release scan will enforce that result.

## Architecture

### 1. Compatibility support layer

Add small SwiftUI compatibility helpers for:

- value changes with old/new values;
- geometry changes through preferences;
- conditional cosmetic modifiers such as scroll indicators/bounce behavior;
- legacy nanosecond sleeps where direct replacement is clearer.

The helpers must use APIs available on macOS 12 in their unconditional implementation. Newer APIs, if retained for visual parity, may appear only inside explicit `if #available` branches.

### 2. Combine-backed observation fallback

The current editor model is heavily coupled to Observation macros, which prevents a genuine macOS 12 deployment. Convert the affected reference types to `ObservableObject`. Mark UI-visible mutable state with `@Published`, leave renderer caches and continuations un-published, and explicitly forward `objectWillChange` from nested objects that the old Observation system tracked transitively. Convert SwiftUI views from `@Bindable` to `@ObservedObject` or `@StateObject` while preserving the existing bindings and call sites.

The conversion is intentionally limited to the model/view observation boundary; document structs, rendering algorithms, and editing behavior are not redesigned.

### 3. Window and file flow

Retain the existing AppKit bridges for close confirmation, floating panels, import, export, and security-scoped URLs. Remove only the newer SwiftUI window actions that prevent macOS 12 compilation. The main SwiftUI scene remains responsible for menus and toolbar content, while AppKit owns the reopen callback and first-launch/restored-window placement.

### 4. Build and release configuration

Set the app, unit-test, and UI-test deployment target to `12.0`. Keep `SWIFT_VERSION = 5.0` and the current Xcode toolchain. Make Release explicitly build both standard macOS architectures with `ONLY_ACTIVE_ARCH = NO` and no Intel exclusion. Do not add runtime exceptions or weaken signing/security entitlements.

Update compatibility documentation and the release validation script. The script will check:

- all relevant deployment targets are exactly 12.0;
- no forbidden Observation/new-window symbols remain unguarded;
- no forbidden security entitlements were added;
- the built app executable contains both required slices;
- Sparkle remains 2.10.0 and the appcast metadata does not advertise an incompatible minimum for a compatibility release.

## Error handling and fallbacks

- If an older SwiftUI modifier is unavailable, the compatibility helper must leave the view usable with the closest visual behavior rather than fail at launch.
- If a Metal device, shader function, pipeline, command buffer, or feature family is unavailable, use the existing CPU/render fallback and surface the existing render error path; do not crash or force a global CPU renderer.
- If a file panel is cancelled, preserve current no-op behavior. If a security-scoped URL cannot be accessed, report the existing localized import/export error and always stop access when it was started.
- Sparkle update checks must continue to reject updates whose appcast minimum system version is above the current OS. No signature verification or HTTPS behavior may be bypassed.

## Testing and verification

1. Establish a clean baseline and run the existing unit-test suite where the current toolchain permits it.
2. Add focused tests for compatibility helpers and model change propagation, including nested session/history changes and geometry/value change delivery.
3. Build Debug and Release with macOS 12 deployment settings and signing disabled only for local compilation checks.
4. Run the existing unit tests and UI tests where the host permits them.
5. Build a Release Universal app and verify:

   ```sh
   lipo -archs Compositor.app/Contents/MacOS/Compositor
   otool -l Compositor.app/Contents/MacOS/Compositor | rg -A3 LC_BUILD_VERSION
   codesign --display --entitlements :- Compositor.app
   ```

6. Inspect the final diff for accidental UI redesign, forbidden entitlements, unconditional newer APIs, and changes outside the compatibility scope.

Runtime testing on actual Monterey Intel hardware remains a release recommendation if that hardware is unavailable in the build environment; static availability checks, compilation, Universal binary inspection, and the existing CPU/Metal tests are mandatory here.

## Security invariants

Keep App Sandbox, user-selected read/write access, outgoing network access, Hardened Runtime, Sparkle helper mach lookups, EdDSA verification, HTTPS, and normal code-signing/notarization compatibility. Do not add `com.apple.security.cs.disable-library-validation`, JIT, unsigned executable memory, `get-task-allow` to Release, or any sandbox bypass.

