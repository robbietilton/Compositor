# Compositor MCP

Compositor can be controlled by a local Model Context Protocol (MCP) client. The client starts the separate Python companion over stdio. Compositor processes each request in the same editor you see on screen, with its normal undo history and project format.

## Connect a client

Use a Compositor build that includes the MCP bridge, and Python 3.9 or later. The companion uses the standard library.

Point your client's stdio server configuration at the companion in this checkout. Use absolute paths for the interpreter, script, and app. Omit `--app` and its argument to use the registered Compositor app.

```json
{
  "mcpServers": {
    "compositor": {
      "command": "/absolute/path/to/python3",
      "args": [
        "/absolute/path/to/Compositor/tools/compositor-mcp/server.py",
        "--app",
        "/Applications/Compositor.app"
      ]
    }
  }
}
```

MCP control starts off. Compositor asks for permission on the first request that reaches the editor. It remembers your choice. To enable or revoke access later, open **Compositor → Settings → General** and change **Allow MCP control**. Turning it off blocks new requests, including from clients that are still running.

Stop or remove the companion in your MCP client to disconnect it. The companion makes no network connection. It wakes the app through macOS file-open events and uses a private, per-user temporary mailbox for each request. There is no listening port, launch agent, in-app polling, bundled Python runtime, or dependency to install. Regular projects contain no MCP data. Compositor's setting applies to all local MCP clients under your macOS account, so use clients you trust with your projects.

## Typical workflow

1. Call `list_projects`. Pick the intended tab and call `select_project` if it is not active. Use `new_project` to start with a blank canvas or `open_project` to open a saved project.
2. Call `get_project` for canvas dimensions, layer IDs, layer order, and current settings. Most tools require the active project's ID. If someone changes tabs during a workflow, subsequent calls reject the stale target.
3. Import media, add text or shapes, paint, transform layers, adjust their appearance, or work with masks and selections. `list_commands` and `run_command` also expose the editor's Image, Layer, Select, Filter and View menu actions and tool choices. Commands that open a dialog or start a canvas interaction leave that interaction in the app.
4. Call `preview` to see the current canvas. Use `undo` or `redo` for normal edit history, `export_png` for flattened pixels, or `save_project_copy` for a new layered package. `save_project` writes an existing project's file. An untitled project can be saved as a copy and then opened to continue working in the named file.

GIFs and videos import as native animated layers. GIF frame selection and timing have direct tools. MOV and MP4 links continue to point to the original movie. Use the app's timeline for movie playback and scrubbing.

The editor rejects edits while it is busy with another tool or dialog. Some native imports, such as RAW development, need input in the app. If an operation times out, inspect the project before retrying. PNG exports and project copies require a new path and refuse to replace an existing file.

The server exposes its tool schemas through `tools/list`. See the [MCP stdio specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) for the transport.
