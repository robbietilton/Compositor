# Using Compositor with Codex and Claude

Compositor exposes the document open in the app as a local [Model Context Protocol](https://modelcontextprotocol.io/) server. An agent can create editable layers, paint and retouch, make selections, crop, inspect a rendered preview and save the project without simulating mouse input.

## Start the server

1. Open **Compositor › MCP Server…**.
2. Turn on **Enabled**.
3. Copy the endpoint and access token, or choose **Copy Connection JSON**.

The default endpoint is `http://127.0.0.1:49678/mcp`. Compositor listens only on this Mac and every request must include `Authorization: Bearer <access-token>`. Regenerating the token immediately invalidates the old one.

Only local Codex or Claude sessions can reach the loopback endpoint. A cloud-hosted agent cannot connect to it directly.

## Codex

Add this to `~/.codex/config.toml`, replacing `PASTE_TOKEN` with the token shown by Compositor:

```toml
[mcp_servers.compositor]
url = "http://127.0.0.1:49678/mcp"
http_headers = { Authorization = "Bearer PASTE_TOKEN" }
```

Restart Codex after changing the configuration, then verify the connection with `codex mcp list`. Codex also supports `bearer_token_env_var` if the token should not be stored in the configuration file. See the official [Codex MCP setup](https://developers.openai.com/learn/docs-mcp) and [configuration reference](https://developers.openai.com/codex/config-reference/).

## Claude Code

Run this from the project where Claude Code should use Compositor, replacing `PASTE_TOKEN`:

```sh
claude mcp add --transport http compositor http://127.0.0.1:49678/mcp \
  --header "Authorization: Bearer PASTE_TOKEN"
```

Alternatively, **Copy Connection JSON** in Compositor produces a complete HTTP server object that can be passed to `claude mcp add-json compositor '<json>'`. Check the connection with `claude mcp get compositor` or `/mcp`. See the official [Claude Code MCP guide](https://docs.anthropic.com/en/docs/claude-code/mcp).

## Recommended agent workflow

1. Call `compositor_get_document` to read the canvas, active layer, selection and viewport.
2. Use document coordinates; `(0, 0)` is the top-left of the canvas.
3. Prefer editable Shape, Type and Pen layers when they fit the design. Use paint and retouching tools for raster work.
4. Call `compositor_render_document` after meaningful changes and inspect the returned PNG.
5. Use `compositor_history` to undo or redo. Call `compositor_save_document` only when the user asks to save.

Tool calls affect the open Compositor tab and appear on the canvas immediately.

## Tool coverage

| Compositor tool or operation | MCP tool | Main actions |
| --- | --- | --- |
| Inspect canvas | `compositor_get_document` | Canvas, layers, editable properties, selection and viewport |
| New document | `compositor_create_document` | Size, resolution and background |
| Move / Transform | `compositor_update_layer` | Position, size, rotation, flip, opacity and blend mode |
| Marquee | `compositor_set_selection` | Rectangle and ellipse |
| Lasso | `compositor_set_selection` | Polygonal paths |
| Magic Wand / Object Selection | `compositor_set_selection` | Color- and object-based selections |
| Selection commands | `compositor_set_selection` | Select all, deselect, invert, add, subtract and feather |
| Crop | `compositor_crop` | Whole-pixel document rectangle |
| Brush / Eraser | `compositor_paint_stroke` | Color, size, hardness, opacity and path |
| Spot Healing | `compositor_paint_stroke` | Healing path |
| Clone Stamp | `compositor_paint_stroke` | Source point, aligned mode and path |
| Blur / Smudge / Liquify | `compositor_paint_stroke` | Retouching mode and path |
| Gradient | `compositor_apply_gradient` | Linear or radial layer or mask gradient |
| Layer masks | `compositor_manage_mask` | Add from a selection, remove, enable, disable, invert, link, unlink, copy and load as a selection |
| Live masks | `compositor_manage_mask` | Assign or remove another layer as a live mask source |
| Pen | `compositor_add_vector_path` | Editable anchors, cubic handles, fill or stroke |
| Shape | `compositor_add_shape` | Editable rectangle, ellipse or line |
| Type | `compositor_add_text` | Editable text, font, color, alignment and text box |
| Eyedropper | `compositor_sample_color` | Composite color at a document point |
| Hand / Zoom | `compositor_set_view` | Fit, pan and zoom |
| Layers | `compositor_manage_layer` | Add, group, duplicate, rename, delete and place |
| Layer selection | `compositor_select_layer` | Set the active layer |
| History | `compositor_history` | Undo and redo |
| Preview | `compositor_render_document` | Render a PNG for visual inspection |
| Save | `compositor_save_document` | Save an existing `.comp` project |

Several related interface modes share one API intentionally. For example, Brush, Eraser and retouching modes all take a document-space point path through `compositor_paint_stroke`; this gives an agent the same creative operation without fragile pointer automation.
