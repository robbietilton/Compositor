# Brush palette implementation handoff

The existing native palette, import flow, preset storage, panel controls and painting pipeline are reused. Clicking a native brush activates it; the separate sliders button intentionally opens its editor. Search receives focus when the palette opens.

The editor exposes the researched settings in category groups. Native size, opacity, round-tip hardness, smoothing and supported pressure mappings use the existing engine. Other controls remain disabled and labeled Coming soon. Imported brushes are inspection-only: component selection, retained source references and missing-asset diagnostics are available; undecoded values say Not mapped. Saving and Procreate export remain unavailable for source-backed brushes.

The interactive drawing preview uses an isolated EditorSession and the same painting implementation as the canvas. It preserves the 4:3 canvas aspect ratio, replays strokes after settings changes, displays errors inline and clears unused undo snapshots. It does not change the real document or collection. Settings and source details scroll within the screen-bounded editor.

## Verification

The Debug macOS build and 32 targeted tests passed: BrushPaletteTests, BrushLibraryTests, BrushTests and PenPressureTests. The new checks compare preview output with canvas pixels after replay, verify Clear/history/error recovery and collection isolation, and host both native and imported editors using the existing panel kit. Captured native layouts were visually inspected:

- [Native editor](../proposals/brush-palette/implemented-editor.png)
- [Imported source inspector](../proposals/brush-palette/implemented-source-inspector.png)

Test result: `/private/tmp/CompositorCanaryDerived/Logs/Test/Test-Compositor-2026.10.31_15-22-22-+0200.xcresult`.

Human review should cover keyboard navigation, VoiceOver and real tablet input. Full Stroke Path, Shape and Rendering behavior remains in the existing follow-up tasks; this UI work does not implement those engines or Procreate export. Changes are local and uncommitted; no new canary was packaged for this task.
