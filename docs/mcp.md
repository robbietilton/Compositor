# Driving Compositor from an AI agent (MCP)

Compositor has a built-in [Model Context Protocol](https://modelcontextprotocol.io) server, so an AI agent such as Claude Code can make and edit images in the open app while you watch: new canvases, image layers, adjustment layers, effects, selections, filters, and any menu command. Every change is an ordinary step in the undo history.

For writing `.comp` files directly instead, with no app running, see [writing-comp-files.md](writing-comp-files.md).

## Turning it on

1. **Compositor › Agent Access…**, then **Let AI agents use Compositor**. The status turns green: `On at http://127.0.0.1:39271/mcp`.
2. **Copy Command**, and run it in a terminal to add Compositor to Claude Code:

   ```sh
   claude mcp add --transport http compositor http://127.0.0.1:39271/mcp --header "Authorization: Bearer <token>"
   ```

   **Copy JSON for Other Apps** gives the same as an `mcpServers` entry for apps configured with JSON.
   For Claude Desktop's own chat: quit Claude Desktop (it writes its settings back over the file while it's open), then **Add to Claude Desktop…** puts Compositor in its `claude_desktop_config.json`, keeping its other servers and the file as it was in a `.bak`; open Claude Desktop again. Claude Desktop starts Compositor as a helper, `Compositor --mcp-stdio`, which passes its messages on to the open app; no Node.js, and no token in Claude Desktop's settings. Install Compositor in Applications first, since the entry points to where it is. **Copy JSON** under it gives the same entry to paste by hand.
3. Optionally **Add Folder…**: agents can open, import and save files only inside the folders listed there (the app is sandboxed). Without one, they can still make images, send images in as base64 and get the result back directly.

The server listens on the loopback interface only, so nothing on the network can reach it, and it answers only requests that carry its token. **Make New Token** replaces the token; agents set up with the old one stop working. It stays off until you turn it on, and remembers the setting.

## What it offers

| Tool | Does |
|---|---|
| `list_documents`, `get_document` | What's open; a document in full, every layer with its settings (the JSON a `.comp` manifest holds) |
| `new_document`, `open_document`, `save_document` | Make a canvas in a new tab; open or save a `.comp` |
| `render`, `export_image` | See the canvas (or one layer) as an image; export a PNG or JPEG to a file or back to the agent |
| `add_layer` | An image (base64 or a file: PNG, JPEG, HEIC, WebP, TIFF, GIF, SVG, PDF, PSD, RAW), an empty layer, or a folder |
| `update_layer` | Name, visibility, opacity, blend mode, transform, effects, adjustment settings, as one undo step |
| `select_layers`, `delete_layers`, `duplicate_layers`, `group_layers`, `merge_layers`, `move_layer`, `add_mask` | Arrange layers |
| `add_text`, `update_text`, `list_fonts` | Text layers that stay editable: words, font, size, color, alignment, spacing, a wrapping box, letters in other colors or faces |
| `add_shape`, `update_shape` | Rectangles (rounded, smoothed), ellipses and lines (dashed, capped) that redraw sharply when scaled |
| `paint` | Strokes along points, with pen pressure if wanted: Brush, Eraser, Spot Healing, Clone Stamp, Blur, Smudge, Liquify, on pixels or a mask |
| `gradient` | Linear or radial, between two colors or to clear, on pixels or a mask |
| `gif_frames`, `edit_gif` | An animated GIF layer's frames: show one to paint or filter it, duplicate, delete, set delays |
| `select` | Rectangle, ellipse, polygon, all, none, invert, or the subject; add or subtract; feather |
| `fill` | Fill the selection (or layer) with a color |
| `apply_filter` | Any filter from the Filter and Image menus with its settings, Content-Aware Fill and Remove Background included |
| `add_adjustment_layer` | Any adjustment layer, with its settings |
| `canvas_size`, `image_size`, `crop`, `trim`, `rotate_canvas`, `flip` | The canvas by value, without their dialogs |
| `undo`, `redo` | Edit › Undo and Redo |
| `list_commands`, `run_command` | Everything in the menus and the tool list, by name, as Search Commands finds it |

Commands whose names end in "…" open a dialog for you to answer, so `run_command` refuses them unless the agent passes `allow_dialog`.

Tools act on the document in front unless they're given `document`, and on the selected layer unless they're given `layer_id`. Coordinates are document pixels from the top-left. If you're in the middle of something (typing text, a dialog open), tools that would change the document don't, and say why, so the agent can ask you to finish first.

## Camera Raw

`apply_filter` takes every Camera Raw setting under `cameraRaw`, panel by panel as the filter shows them: e.g. `{"cameraRaw": {"exposure": 0.5, "curve": {"shadows": -20}, "mixer": {"saturation": {"Oranges": -30}}, "grading": {"highlights": {"hue": 40, "saturation": 25}}}}`. Point Color picks go in `mixer.points` (`{"color": "#FF8000", "saturationShift": -40}`), and Upright's guides in `geometry.guides` (`{"start": [0.1, 0.2], "end": [0.9, 0.25]}`, fractions of the layer from its top-left). A name it doesn't know is answered with the ones it does.

## How it works

`AgentServer` (in `Compositor/Agents`) is a small HTTP/1.1 server on Network.framework speaking MCP's Streamable HTTP transport: each JSON-RPC message is a POST to `/mcp`, answered with JSON. It's stateless, with no session id or event stream, since every tool returns its whole result. `MCPHandler` handles `initialize`, `ping`, `tools/list` and `tools/call`; the tools in `AgentTools+*.swift` call the same `EditorSession` methods the menus and panels do. `MCPStdioBridge` is the same app started with `--mcp-stdio`: it reads JSON-RPC lines on stdin, posts each to the server with the port and token from the app's own settings, and writes the replies to stdout, for apps that only start servers as commands. Nothing new is saved, so the project format is unchanged.
