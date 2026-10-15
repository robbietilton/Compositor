# Compositor MCP server

Compositor includes a native macOS MCP server for editable Pen paths. Codex, Claude Code and other stdio MCP clients
can create and refine vector work in a saved `.comp` project while it is open. Compositor notices each complete write
and reloads the canvas.

The server is a separate command-line executable rather than the sandboxed GUI process. This lets an MCP client grant
it access to the project path explicitly, without giving the editor a background network listener or broadening the
editor's sandbox.

## Build

Xcode 26 or its matching command-line tools are required.

```sh
./scripts/build-mcp.sh
```

The script prints the absolute executable path. In this checkout it is:

```text
/Users/zhangwenyu/Documents/GitHub/Compositor/build/CompositorMCP/release/compositor-mcp
```

## Connect Codex

```sh
codex mcp add compositor -- /Users/zhangwenyu/Documents/GitHub/Compositor/build/CompositorMCP/release/compositor-mcp
codex mcp list
```

Codex also accepts the equivalent `~/.codex/config.toml` entry:

```toml
[mcp_servers.compositor]
command = "/Users/zhangwenyu/Documents/GitHub/Compositor/build/CompositorMCP/release/compositor-mcp"
startup_timeout_sec = 10
tool_timeout_sec = 60
```

Codex CLI, the Codex IDE extension and the ChatGPT desktop app share MCP configuration on the same Codex host. In the
desktop app or IDE, the same server can instead be added as an **STDIO** server and then restarted.

## Connect Claude Code

```sh
claude mcp add compositor --scope user -- /Users/zhangwenyu/Documents/GitHub/Compositor/build/CompositorMCP/release/compositor-mcp
claude mcp get compositor
```

An equivalent Claude Desktop or project `.mcp.json` entry is:

```json
{
  "mcpServers": {
    "compositor": {
      "type": "stdio",
      "command": "/Users/zhangwenyu/Documents/GitHub/Compositor/build/CompositorMCP/release/compositor-mcp",
      "args": []
    }
  }
}
```

Use an absolute command path. Project-scoped Claude configurations require approval the first time they are loaded.

## Pen tools

All coordinates in the MCP API are document pixels. Colors use RGB values from 0 to 1. A node has an `anchor` and
optional `in_handle` / `out_handle`; omitted handles equal the anchor and therefore make a corner.

| Tool | Purpose |
| --- | --- |
| `compositor_list_pen_paths` | Read all editable Pen paths and their document-space nodes. |
| `compositor_create_pen_path` | Add a closed `Shape` path or an open `Line` path without painting pixels. |
| `compositor_update_pen_path` | Rename, recolor, show/hide, change width/mode, or replace nodes to move/add/delete points. |
| `compositor_delete_pen_path` | Delete a path unless it is used as a live-mask source. |
| `compositor_inspect_pen_path_geometry` | Return path length plus arc-length position, tangent, normal and angle samples. |

For example, a client can call `compositor_create_pen_path` with:

```json
{
  "project_path": "/Users/me/Desktop/Poster.comp",
  "name": "Title Arc",
  "mode": "Line",
  "color": { "red": 1, "green": 0.75, "blue": 0.2 },
  "line_width": 6,
  "nodes": [
    {
      "anchor": { "x": 180, "y": 420 },
      "out_handle": { "x": 300, "y": 300 }
    },
    {
      "anchor": { "x": 620, "y": 420 },
      "in_handle": { "x": 500, "y": 300 }
    }
  ]
}
```

The result is an ordinary editable Pen layer with a transparent identity PNG. Fill and brush-stroke remain explicit
commands in the GUI, so creating or editing a path never changes pixels. The MCP server writes the backing first and then
atomically replaces `manifest.json`, so Compositor never loads a half-written path. Calls reject malformed projects,
unsupported future format versions, non-finite coordinates, excessive nodes and unsafe deletion of live-mask sources.
A path that has a fill, a brush stroke, erasing or separate pieces (added in Compositor) can be renamed or shown/hidden
through MCP, but changing its shape, mode, color or width is refused, since rewriting it would drop that work.

## Text-on-path hand-off

The GUI app now exposes `TextPathPlacement`, `VectorPathGeometry`, `VectorPathSample`,
`EditorSession.textPathGeometry(for:)` and `EditorSession.textPathPlacement(for:...)`. This is intentionally a geometry
contract, not a second text engine:

- Text owns content, fonts, shaping, tracking and glyph editing.
- Pen owns editable Bezier nodes and converts the layer transform into document-space geometry.
- The geometry API supplies total arc length, nearest offset, position, tangent, normal and baseline-offset sampling.
- A future text layer can persist `TextPathPlacement.pathLayerID` and recalculate glyph positions whenever that path
  changes.

`compositor_inspect_pen_path_geometry` exposes the same contract to agents. Visual text-on-path rendering is not turned
on yet; the interface is ready for the text maintainer to connect without changing Pen internals.

## Operational notes

- Save the document as a `.comp` project before calling the tools.
- If the open document has unsaved local edits, Compositor keeps its existing conflict prompt instead of overwriting
  the user's work silently.
- External MCP edits reset that document's in-memory undo history when the app reloads it, just like another editor
  changing the project on disk.
- The server reads and writes only the `project_path` supplied in a tool call. It does not listen on a port or use the
  network.
