# Compositor MCP

AI apps that speak the Model Context Protocol (MCP), such as Claude, Claude Code and Codex, can work in Compositor: open and make projects, add layers, text and shapes, paint, adjust, mask, preview, export and save. They work in the editor you see, in its normal undo history.

## Connect

1. In **Compositor → Settings → General**, turn on **Allow MCP control**.
2. Under **Add Compositor to your AI app**, click **Copy Setup** next to your app and paste it where the row says:
   - **Claude Code**: paste into Terminal.
   - **Claude**: add it under `"mcpServers"` in Claude's Settings › Developer › Edit Config, then restart Claude.
   - **Codex**: add it to `~/.codex/config.toml`, then restart Codex.
3. Ask your AI app to do something in Compositor.

The setup points your AI app at `compositor-mcp`, a small program inside Compositor.app. Nothing else needs installing. If Compositor moves (into Applications, say), copy the setup again.

If Allow MCP control is off, Compositor asks the first time an AI app tries to use it, and remembers your answer. Turning it off blocks new requests, including from AI apps that are still running.

## How it works

The AI app starts `compositor-mcp` and talks to it over stdin and stdout. For each tool it uses, `compositor-mcp` writes the request to a private folder that only your macOS account can read (`/private/tmp/compositor-mcp-<your user ID>`) and opens it in Compositor, launching it in the background if need be, followed by any file the request brings, such as an image to import. Compositor answers in the same folder. Opening files in Compositor is how a sandboxed app is allowed to read them, so `compositor-mcp` runs outside the sandbox. It reads files it's asked to import or open and writes exports and copies where it's asked. It never replaces an existing file.

There's no network connection, listening port or background service, and nothing runs in Compositor between requests. Projects hold no MCP data. The setting applies to every AI app under your macOS account, so connect only AI apps you trust with your projects.

## Typical workflow

1. Call `list_projects`. Pick the tab to work in and call `select_project` if it isn't active. Use `new_project` for a blank canvas or `open_project` for a saved project.
2. Call `get_project` for the canvas size, layer IDs, layer order and current settings. Most tools take the active project's ID. If someone switches tabs midway, later calls are refused until `select_project`.
3. Import media, add text or shapes, paint, transform layers, change their appearance, or work with masks and selections. `list_commands` and `run_command` reach the editor's Image, Layer, Select, Filter and View menus and its tools. A command that opens a panel or dialog brings Compositor forward for you to finish it.
4. Call `preview` to see the canvas. Use `undo` and `redo`, `export_png` for a flattened image, or `save_project_copy` for a layered copy. `save_project` saves a project that already has a file. To keep working in a new file, save a copy and open it.

GIFs and videos import as animated layers. GIF frames and timing have their own tools. Movies stay linked to their original files. Use the timeline in the app to play and scrub them.

Compositor refuses edits while another tool or dialog is in use. Some imports, such as RAW development, need you in the app. If a call times out, check the project before trying again.
