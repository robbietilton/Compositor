# Brush palette and full settings editor

October 31, 2026 · Task `task-01e3782b-5718-42b1-a44d-ecb02bff6d82` · Design for review, not app implementation.

## Direction

Keep Compositor's implemented UI conventions. A Brushes button immediately before the existing Paint/Erase segmented control opens a floating brush browser. A single click activates a brush immediately and leaves the browser open. A separate sliders button on each row opens its editor as a document-modal sheet. Save stores the draft in the local collection, makes it the current brush, closes the editor and browser, and returns focus to the canvas. Cancel returns to the browser without changing the active brush or persisted settings. Export Procreate… is available inside the editor and exports the current draft when a valid source mapping exists.

This follows the user's screenshot and explicit interaction request. The [compatibility contract](brush-compatibility-contract.md) remains authoritative for capability, source retention and renderer ownership. Procreate export is an additional user requirement beyond that contract's import scope; this design specifies its UI and failure behavior, not an implemented writer. [Settings research](procreate-brush-settings-research.md) supplies the category inventory; similar source/native control names do not establish archive mappings.

## Reuse the implemented kit

No separate styleguide document or standalone UI-kit package was found. The implemented kit is the following source code; use it as the styleguide and reuse it in production.

| Element | Existing source / convention | Use here |
| --- | --- | --- |
| Tool header | `Compositor/UI/ToolHeaderStyle.swift`; 42 pt high, 13 pt semibold title, 12 pt controls; `BrushControls.swift` uses 12 pt gaps | Insert button inside the Brush-only branch before Mode, preserving the existing segmented Paint/Erase control and all subsequent controls |
| Buttons / menus | `roundedControls()` in `ContentView.swift` sets capsule borders, automatically applied by `FloatingPanelController` | Native capsule buttons; system accent and semantic foregrounds, no new button style |
| Floating window | `FloatingPanelController` movable titled `NSPanel`, session position memory, hide on deactivate | Reuse with stable `brushPalette` identifier and title “Brushes”; default automatic canvas-centered placement, then remembered position |
| Search / list | `FontListPanel` establishes pinned search, divider, scrollable rows, keyboard search; `LayersPanel` establishes dense lists | Reuse layout/interaction conventions, not FontListPanel's font-specific callbacks or dismiss-on-resign behavior |
| Numeric settings | `EffectsSheet`, `BrushControls`, `FilterSheet`: scrub label, slider, rounded field, `.arrowSteps`, `.unitSuffix` | Same row pattern, finite/range validation and aligned fields; native Toggle and Picker for Boolean/enums |
| Modal | Existing document sheets (`ImageSizeSheet`, `RawDevelopSheet`) | SwiftUI sheet on owning document, roundedControls, native Cancel/default action conventions |
| Colors / imagery | System semantic colors; existing palette swatch and picker | Existing foreground color in preview, no duplicate brush color storage or new palette system |

Native design study: [header](../proposals/brush-palette/toolbar.png), [editor](../proposals/brush-palette/editor.png), [browser](../proposals/brush-palette/palette.png), [source](../proposals/brush-palette/Preview.swift). It renders actual SwiftUI/AppKit controls and extracts the actual `ToolHeaderStyle`, `unitSuffix` and `roundedControls` definitions at build time using [render.py](../proposals/brush-palette/render.py). It is a visual study, not production components. Stroke icons are illustrative, buttons do not save/export/import, and the two preview windows do not simulate modal lifecycle. The specification below defines those behaviors.

## Entry and floating browser

Header order: `Brush [Brushes…] [Paint | Erase] Size … Hardness … Opacity …`. The new control is a regular native bordered capsule with the SF Symbol `paintbrush.pointed` and visible “Brushes” label. It has accessibility label “Browse brushes”, help “Browse and edit brushes”, and identifier `brushPaletteButton`. Keep the 12 pt gap used by the header. It appears only for the Brush tool, in both Paint and Erase. Busy state follows the existing header disabled state. It does not change Paint/Erase mode. Press again toggles the palette; do not add an unrequested keyboard shortcut or move existing controls.

Browser content starts at 340 × 420 pt, with 16 pt padding and 12 pt gaps, matching the app's compact panels. Native title bar provides move/close. Top row: “Brushes” and trailing “Import…”. Below: pinned search field “Search Brushes”, native collection picker “All Brushes” / named imported collections / “Compositor”, divider, vertically scrolling rows. Preserve source order within each collection; All Brushes groups by collection, without alphabetizing source brushes. No favorites, tags, marketplace or new collection-management system in this task.

Each row is 56–64 pt high, with a compact stroke thumbnail, name, one secondary status line and a checkmark for the current brush. Selection and focus are native and distinct from the current-brush checkmark. Native thumbnail uses the shared renderer only when renderable; source-provided artwork is marked “Source preview” and never masquerades as a rendered stroke. Fallback is a neutral tip/document icon, not a fabricated stroke. Long names truncate visually with full accessible text/help.

Single click activates “Use <name>”, persists the selected preset and updates the current-brush checkmark without opening an editor. The trailing sliders button, labeled “Edit <name>”, explicitly opens a draft modal. Hover and arrow-key highlighting do not change the active brush. Tab reaches the row activation and Edit actions separately; Return/Space invokes the focused action. Reopening scrolls the current brush into view. Search matches brush and collection names case-insensitively; filtering does not change selection. Escape clears nonempty search, then closes the browser and returns focus to the header button. Closing the browser never resets the selected brush. Clicking the canvas keeps this movable floating palette open.

Empty collection: “No brushes yet” with Import… and the default Compositor round brush available. Empty search: “No brushes match ‘…’” and Clear Search. Import uses a native open panel for `.brush`, `.brushset`, `.brushlibrary`; while working show a small inline progress indicator “Importing brushes…” and disable repeated import, preserving browsing. On success select the imported collection, show “Imported N brushes” and “Review N limitations” if applicable; do not open a modal for every imported brush. Unsafe/malformed imports show an actionable error and leave the collection intact. Import diagnostics list brush names and exact missing shape/grain references, independently of container success.

## Modal editor

Present on the owning document window, not an app-global blocking dialog or another nonmodal floating panel. Keep the browser visible but inert behind the sheet; do not let its floating window cover the sheet or accept input. Restore it only after Cancel. On Save close it and focus the canvas. Multiple document windows must not create two editors for the same collection record; focus the existing editor and disclose any stale record revision before overwrite.

Preferred content size approximately 887 × 626 pt. Three columns: category list 155 pt; settings 420 pt; preview/compatibility 270 pt with dividers. Header/footer span the sheet; settings scroll independently, navigation and preview remain visible. Insets 20 pt and section gaps 16 pt follow EffectsSheet. On shorter displays constrain height to the visible screen and scroll settings; below about 840 pt available width put preview above settings in the main column, keeping categories visible. Do not shrink text or hide categories to fit. Test the final sheet against minimum supported document-window size.

Header: “Brush Editor”, editable brush-name field, and component selector for dual brushes only. Sidebar categories follow the table below. Each category is always reachable; planned categories are not disabled navigation items. Their controls remain visible and disabled with readable “Coming soon” explanation. Do not add redundant counts or status badges to every category. Default category is Properties on first edit; remember the last category during the session. Visual study opens Shape to demonstrate source mapping.

Footer: leading “Export Procreate…”; trailing “Cancel” and accent default “Save”. Save validates name/settings, writes atomically and activates the selected brush. If unchanged, Save still selects that brush. Keyboard Return in a numeric field commits that field first; default Save fires only when the user invokes the default action outside field editing. Escape cancels; dirty drafts prompt “Discard changes to ‘<name>’?” with Keep Editing / Discard. Saving failure keeps the draft and dialog open with “Couldn’t save brush” and Retry; never close on failure. Name-only edits still preserve source provenance. Saving to the local collection does not modify the original source file or the active document's pixel undo.

## Full settings inventory and controls

S = implemented now; M = intended MVP but disabled until engine and binding checks pass; P = retained source values, Coming soon. These states must be derived from actual capabilities, not hard-coded by the design. Every item below is visible in its category; slash-separated entries mean separate labeled fields/toggles, not one combined ambiguous slider. Group labels may be shared; accessibility names must identify the exact property and component.

| Category | Groups and exact visible controls | State and control pattern |
| --- | --- | --- |
| Stroke Path | Spacing; Spacing Jitter; Lateral Jitter; Linear Jitter; Falloff | Spacing M, other controls P; scalar rows. Internal automatic spacing is not source-setting support |
| Stabilization | Compositor Smoothing; StreamLine Amount, Pressure; Stabilization Amount; Motion Filtering Amount, Expression | Smoothing S (0–100 existing units); all source controls P. Keep native smoothing distinct from source stabilization |
| Taper | Native Start Length, End Length; Pressure Taper and Touch Taper groups, each with Start/End Length, Linked Size, Size, Opacity, Pressure, Tip; Tip Animation; Classic Taper | Native size taper M; source variants P; labels and endpoint diagram, numeric rows/toggles/pickers. No claim that native taper reproduces a source taper |
| Shape | Source; Input Style / Orientation; Hardness; Rotation; Scatter; Count; Count Jitter; Randomize; Flip Horizontal; Flip Vertical; Roundness; Angle; Roundness Jitter; Filtering | Procedural Hardness S; known-source mapping and fixed roundness/angle/count/angular scatter M. Other source dynamics P. Source row shows image or procedural disk, exact reference, Embedded / Approximation / Missing; filtering is an enum, flips are toggles |
| Grain | Source; Moving / Texturized; Movement; Scale; Zoom; Rotation; Depth; Depth Jitter; Offset Jitter; Blend Mode; Brightness; Contrast; Filtering; Source Tiling | All P; source image/reference, native segmented choice/pickers, scalar rows. Source Tiling is a disabled action, not an unexplained numeric slider |
| Rendering | Mode (Light/Uniform/Intense/Heavy Glaze, Uniform/Intense Blending); Flow; Wet Edges; Burnt Edges; Edge Blend Mode; Stroke Blend Mode; Luminance Blending; Alpha Threshold; Classic Dual-Normal | Native flow M; source rendering P. Mode/blend pickers, scalar rows, Boolean toggles. Explain flow per dab versus opacity per stroke |
| Wet Mix | Dilution; Charge; Attack; Pull; Grade; Blur; Blur Jitter; Wetness Jitter | All P; scalar rows, source values preserved; do not equate to Smudge |
| Color Dynamics | Stamp and Stroke groups: Hue, Saturation, Lightness, Darkness, Secondary Color jitter; Pressure, Tilt, Rotation response groups for source color properties | All P, hardware qualification for device mappings; preserve only decoded/evidenced source subproperties, show unmapped ones in source details rather than inventing values |
| Dynamics | Speed Size; Speed Opacity; Speed Spacing; Size Jitter; Opacity Jitter | All P; scalar rows; source response values shown without guessed native ranges |
| Pen / Tablet | Pressure Curve; Pressure Size; Pressure Opacity; Pressure Flow; Pressure Bleed; individual source property response; Tilt Response; Tilt Shape Orientation; Barrel Rotation and its source property mappings | Size/opacity S, pressure graph M, remaining response P. Curve has labeled input/output axes and keyboard-editable point list when implemented. Device availability is independent of implementation status |
| Properties | Name; Size; Opacity; Minimum Size; Maximum Size; Minimum Opacity; Maximum Opacity; Smudge Pull; Preview Size; Source Preview settings | Native size/opacity S, source bounds/smudge/preview P. Size 1–2000 px, opacity 1–100% as current UI. Preview-only settings never change brush shape |
| Dual Brush | Primary / Secondary component; Source combination settings; primary-only preview action | Combination P; component chooser allows inspection of every category for each component. No default silent single-component approximation |

Reuse native size, opacity, hardness and smoothing values and limits; use `.arrowSteps`, scrub labels and unit suffixes as already implemented. A value editor rejects NaN/infinity and validates at the model boundary. Unknown source units are shown as source values with their exact field label, not converted to percentages. Missing source value is “Not supplied”, not 0 or an invented default. Native defaults and imported values must be distinguishable (“Compositor value” / “Source value”) wherever mapping is approximate/unmapped. Unsupported values stay readable/copyable at normal secondary-label contrast even when controls are disabled. Expandable “Source Details” holds raw field names/values and unknown-field diagnostics; no archive implementation details in the normal flow.

## Preview, device and error states

Preview stays on the right: title “Drawing Preview”, trailing Clear, neutral canvas and a short status below. Draw with the current draft using the exact canvas brush pipeline on an isolated layer. Changes replay retained preview samples with the same seed; Clear empties preview only. Do not draw onto the active document or add pixel undo. Preview uses the session foreground color; masks are labeled and shown in grayscale. Optional “Pressure ramp” replay is labeled “Simulated pressure”; drawing with a mouse still uses full pressure. Spinner during redraw must not erase the last valid preview. Render failure preserves draft with Retry; incompatible brush replaces drawing area with its reason and any explicitly available approximation action.

| Situation | Text / behavior |
| --- | --- |
| Valid native brush | Draw normally; “Compositor brush” |
| Known missing built-in mapped to procedural tip | “Round approximation — original tip pixels unavailable”; no equivalent/fidelity claim |
| Missing shape | “Missing shape: <exact reference>” with owning component; retain brush for inspection; drawing blocked unless user explicitly chooses Use Round Approximation |
| Missing grain / unsupported active behavior | Explain exact requirement; no silently grain-free stroke. Allow explicit round approximation only if implemented and label the resulting preview/settings |
| Dual brush | Inspect both components; “Combined rendering: Coming soon”. Optional Preview Primary Only explicitly labels the preview |
| Embedded source retained, image stamping unavailable | Show actual embedded source as an asset, “Image-tip rendering: Coming soon”; do not imply importing the image made it renderable |
| Device disconnected or absent | “No compatible tablet connected”; implemented response controls disabled with “Requires pressure input”, “Requires tilt input” or “Requires barrel rotation”. Stored mappings remain visible. Planned controls still say Coming soon, with device requirement as additional detail |
| Partial-capability tablet | Enable only the individual implemented input mappings the device reports; pressure availability does not imply tilt or rotation |

The preview's compatibility summary uses text, not traffic-light scoring: source retention, rendering limitations, missing references and approximation. Selecting an unrenderable brush can open/edit/save metadata, but Save must say it will be selected for inspection and painting unavailable; do not silently activate a different tip.

## Saving and Procreate export

Save is local collection persistence. Export Procreate… opens a native save panel for the current draft, proposes `<brush name>.brush`, and leaves the editor open after export. Canceling the save panel preserves all draft edits. Export does not implicitly commit the local draft, change the active brush or close the modal. Successful export shows inline “Exported ‘<filename>’”; failure shows “Couldn’t export brush” with retry and retains the draft. Native overwrite confirmation applies; write output atomically.

The desired final product exports edited brushes in Procreate `.brush` format. Do not rename native JSON/ZIP or a Compositor preset to `.brush`. Procreate acceptance must include opening the generated file in Procreate and checking name, settings, both dual components and asset references; successful ZIP/plist parsing alone is insufficient.

Until a validated writer exists, keep Export Procreate… visible, disabled with a readable “Edited Procreate export: Coming soon” explanation. An unchanged imported individual `.brush` can separately offer “Export Original…” using retained exact source bytes. For a brush extracted from a set/library, only offer original export when its valid standalone member container is available or a validated repackager exists; copying the outer `.brushset` and changing its extension is invalid. With local edits, label original export clearly: “Exports the imported original. Your Compositor edits are not included.” Native-only brushes need a validated source encoder before edited export is enabled. Never silently fall back to original export after the user selected edited export.

Once writer support is available, preflight the draft: each changed field must be source-mappable; source/reset/dual data and assets must survive writing. If a changed native-only control cannot be represented, show “This edit can’t be represented in Procreate: <control>” and keep the editor open. Do not drop it or claim successful edited export. Offer the explicit original-export option only when applicable. Unchanged unsupported source properties are preserved, not erased. Choosing an approximation for Compositor does not replace the retained Procreate shape reference unless an explicit, supported source edit requested it.

This export requirement is additional implementation scope. The current existing task list has import, data, palette, dynamics and qualification, but no explicit Procreate writer task. The implementation handoff must add writer/round-trip qualification scope before promising edited export at release; this design task does not authorize a guessed binary writer. No task or message is sent to another assignee here.

## Keyboard and accessibility

Use native roles, focus rings, system accent, light/dark appearance and increased contrast. Checkmark, text and focus distinguish current/selected/unsupported states independently of color. Button accessibility “Browse brushes”; row “Use <name>, <status>, current brush” for activation and “Edit <name>” for the separate editor button where applicable; named collection/search; slider, numeric field and suffix read one complete property with units and component. Do not make disabled controls the only path to a reason: adjacent static text and compatibility details remain reachable by VoiceOver. Source references and imported values are selectable text. All icon-only actions require help/accessibility labels; canvas preview exposes drawing area plus text description and a non-drawing inspection path.

Tab order: browser Search → Collection → brush rows → Import; modal Name → component if present → categories → settings → preview actions → Export → Cancel → Save. Follow native list arrow-key behavior. Escape/Return respect the focused field and sheet state. A nested save/open panel consumes Escape without discarding the brush draft. Opening/closing restores the initiating row/header focus. Avoid app-wide tool shortcuts while typing brush names, searching or editing numbers. No custom entrance or hover animation is required.

## Handoff and review checks

Implementation owner uses existing palette build task `task-4305d27c-2f13-493c-aa36-37f72371a37c`, data task `task-234e68c8-1ded-4f2f-ac01-982363b24c61`, input/dynamics tasks and qualification task `task-73865b4c-97fb-48ec-8b0c-d1e5df3577bf`. Preserve the user's new trigger/modal/export requirements in that handoff. Do not change project storage/version for UI-only work. Full writer support remains additional required scope.

Design acceptance:

- [x] Floating browse/search/collection/import and direct activation and explicit Edit flow specified, with live preview boundary.
- [x] All researched categories and controls inventoried with compact grouping, labels and existing-kit references.
- [x] Coming soon, preserved source values and approximate/unmapped states specified.
- [x] Individual device capabilities, missing assets and dual definitions specified.
- [x] Local Save versus draft Procreate export and failure/unsupported mapping states specified.

Implementation acceptance (not claimed complete): test trigger order and unchanged Paint/Erase/tool behavior; keyboard and VoiceOver navigation; smallest supported window, light/dark/high-contrast appearance; source values surviving save/cancel and disconnected hardware; import error/no-results states; preview/commit parity for supported settings; dirty-draft discard, atomic save failures, native-panel cancellation; actual edited `.brush` round-trip in Procreate. Native study is a layout reference only, not evidence for these runtime checks.
