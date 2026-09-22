# Compositor agent connection

The MCP server runs **inside Compositor** and edits the same tabs, layers, selections and history as the person using the app. A small Python stdio bridge connects MCP clients to the running app. Python has no third-party runtime dependencies.

## Connect

1. Build and open this version of Compositor.
2. In **Compositor → Agent Connection**, enable **MCP**.
3. Choose **Copy MCP Configuration** and add the copied entry to your client's MCP configuration.

The menu shows connection status. Turning the connection off closes clients, invalidates their token, and cancels pending work. Edits already committed remain in native undo history. Keep the app open while using its tools.

## Collaboration

List documents first. Keep the returned `document_id` and pass it on subsequent calls, rather than relying on whichever tab is selected. Read the current document before modifying it. Mutation tools accept an `expected_revision` so stale edits can be rejected. Agent calls also reject active human editing operations; finish or cancel the gesture/dialog and retry.

Edits use the app's native undo history. Tools report validation and execution failures with `isError`; protocol errors use JSON-RPC errors. A transport disconnect is not proof that a mutation failed: read state before retrying.

## HTML/CSS designs

`import_html` accepts `html`, optional `css`, `width`, `height`, and an optional `name`. It creates a new visible tab without replacing the current document. Supply self-contained markup with data URLs for images and fonts. Author JavaScript, external network requests and local file URLs are disabled.

Simple layout elements become editable native layers. Browser effects that have no faithful native equivalent use raster layers; the result reports conversion warnings. Do not assume every CSS property can become a native Compositor property. The original markup is available through `compositor://html/{document_id}` for the current app session; save source separately for later HTML re-imports.

Canvas coordinates are pixels with the origin at the upper left. Current HTML imports are limited to 4096 pixels per side, 16 million canvas pixels, 2000 DOM elements, and bounded source/layer budgets.

A complete [960 × 640 example](examples/agent-layout.html) imports as 11 layers. Pass the file contents as `html`, with `width: 960` and `height: 640`.

![HTML layout imported into native Compositor layers](examples/agent-layout.png)

## Transport and security

The application retains its macOS sandbox. The private bridge binds only to `127.0.0.1` on an ephemeral port. Its random per-start token is stored in an owner-only application-support file. The bridge checks ownership and permissions, and the app authenticates every request. The rendezvous file lives in the app's sandbox container when sandboxed.

The private wire is one newline-delimited authenticated JSON envelope per TCP connection. It is **not an HTTP endpoint**; MCP clients use the stdio bridge, not this private transport. Requests and responses are limited to 40 MiB. There are no automatic mutation retries. The stdio bridge processes one request at a time and cannot consume client `notifications/cancelled` while waiting on that request. Disable the app connection to cancel pending work; completed edits remain undoable.

## Reuse

The JSON-RPC error conventions were adapted from Marcus Horndt's MIT-licensed [compositor-mcp](https://github.com/marcushorndt/compositor-mcp), revision `cf2bf8c`. Its license is retained in `docs/licenses/compositor-mcp-MIT.txt` and bundled with the app as `compositor-mcp-LICENSE.txt`. The standalone server's snapshot store and headless editing handlers were not adopted: the integrated server uses this application's `ProjectWorkspace` and `EditorSession`, avoiding a second document model. Optional external image-generation services are not required.

## Build and test

Requirements: macOS 26.5 or later and Xcode with the macOS 26.5 SDK or later; Python 3.9 or later for the bundled stdio bridge.

```sh
./scripts/build-mcp.sh
./scripts/build-mcp.sh --install
# Optional second argument chooses a different app destination.
python3 -B scripts/test-mcp-bridge.py -v
xcodebuild -project Compositor.xcodeproj -scheme Compositor \
  -configuration Debug -derivedDataPath build \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 -only-testing:CompositorTests test
```

The install command creates `~/Applications/Compositor MCP.app` and refuses to overwrite an existing application. Open it, then enable the connection in the menu. This is a locally signed development build, not a notarized release. The local build script keeps the app sandbox and disables hardened-runtime library validation because ad-hoc signing has no team identity matching the bundled Sparkle framework. Signed distribution should use an Apple development team and the project’s hardened Release settings.

## Tool coverage

The server advertises 32 tools. Each tool has a JSON schema; `get_capabilities` returns the app's enum values and complete default models for adjustments, effects and filters. Use those values instead of guessing parameter names.

| Area | Tools |
| --- | --- |
| Discovery and state | `get_capabilities`, `list_documents`, `describe_document`, `get_editor_state` |
| Documents and project data | `new_document`, `close_document`, `read_project_data`, `open_project_data`, `open_document`, `save_document` |
| Import and export | `import_html`, `import_image`, `import_image_file`, `render_document`, `export_image` |
| Compositing | `layer_operation`, `transform_operation`, `mask_operation`, `adjustment_operation`, `effect_operation` |
| Drawing and pixels | `text_operation`, `shape_operation`, `paint_stroke`, `gradient_operation`, `pixel_operation`, `filter_operation` |
| Canvas and selection | `canvas_operation`, `guide_operation`, `selection_operation`, `sample_selection` |
| Collaboration | `history_operation`, `settings_operation` |

`read_project_data` exposes the entire native editable project, including original layer and mask pixels, text, shapes, effects, adjustments, guide and canvas metadata. `open_project_data` validates and imports that format into a new tab. Direct filesystem tools live in the stdio bridge so the sandboxed GUI does not need broad disk access.

`save_document` writes a native `.comp` project directory using an atomic replacement, with explicit `overwrite: true` required to replace a previous project. It saves a copy; it does not change the sandboxed GUI's Save destination or mark its tab clean. Use the app's Save command if you want subsequent manual saves tied to that path. Export writes PNG at full canvas resolution. Existing output files also require explicit overwrite.

Images and self-contained project envelopes are limited to 24 MiB each; a manifest is limited to 4 MiB. Large production projects can still be edited in the GUI, but may exceed the current MCP file-transfer budget. Render previews default to a 1600-pixel longest edge; request `max_dimension: 0` for full resolution.

## Examples

Import an editable layout into a new tab:

```json
{
  "name": "import_html",
  "arguments": {
    "name": "Launch card",
    "width": 1200,
    "height": 800,
    "html": "<main><h1>Make room for ideas.</h1><p>A shared canvas.</p></main>",
    "css": "body{margin:0;background:#162730;color:#f5f1e6;font-family:Arial}main{padding:80px}h1{font-size:80px}p{font-size:28px}"
  }
}
```

Use the returned `document_id` with `describe_document`, then use layer IDs to update text, move layers or add effects. Revision values cover the workspace; refresh state after a human edit or a tab switch.

Create a selection-based mask:

1. `selection_operation` with `action: "ellipse"` and its canvas bounds.
2. `mask_operation` with `action: "add"`, the target `layer_id`, `from_selection: true`, and `revealing: false`.
3. The native mask command creates a black mask with white inside the selection and consumes the selection in one undo step. `revealing: true` reverses those mask values.
4. `paint_stroke` with `target: "mask"` can refine it; white reveals and black hides. Use `target: "layer"` to resume painting image pixels.

The HTML importer prioritizes faithful appearance. Supported flat text/shapes remain editable; gradients and embedded assets use isolated raster layers. Unsupported stacking, shadows and transforms may flatten the entire design, with a warning. HTML source is session-only and is not stored in `.comp` projects. Keep the original source alongside the project when future re-import is needed.


Layered Photoshop imports use `import_image` with a `.psd` filename and base64 data, or `import_image_file` with an absolute PSD path. The native reader supports 8-bit RGB PSD files, including its supported layer, group, mask and adjustment types. Conversion notes are returned in the tool result: Photoshop text, smart objects and unsupported layer types may become pixels, and unsupported effects may be discarded. Compositor does not write PSD files; preserve the editable result as `.comp`.

For an independent mask transform, first use `mask_operation` with `action: "set_linked"` and `linked: false`, then `transform_operation` with `target: "mask"`. `link`/`unlink` instead create or remove a clipping relationship to another source layer. Delete calls reject a source that still has clipping dependents; unlink those dependents first. Filter and transform tools default to the layer target and support an explicit mask target, so a previous human mask selection cannot redirect their edits.
