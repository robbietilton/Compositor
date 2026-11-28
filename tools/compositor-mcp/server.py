#!/usr/bin/env python3
"""Local, dependency-free MCP stdio companion for Compositor."""

import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid

BUNDLE_ID = "com.wonderassembly.compositor"
PROTOCOLS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
LIMIT = 256 * 1024
STRING = {"type": "string", "minLength": 1}
ID = {"type": "string", "format": "uuid"}
NUMBER = {"type": "number"}
BOOL = {"type": "boolean"}
DIMENSION = {"type": "integer", "minimum": 1, "maximum": 30000}
TRANSFORM = {
    "type": "object",
    "properties": {**dict.fromkeys(("x", "y", "width", "height", "rotation"), NUMBER),
                   "flip_x": BOOL, "flip_y": BOOL},
    "additionalProperties": False,
}
TOOLS = {}


def tool(name, description, required=None, optional=None, active=True, read_only=False):
    required = dict(required or {})
    if active:
        required = {"project_id": ID, **required}
    TOOLS[name] = {
        "name": name, "description": description,
        "inputSchema": {"type": "object", "properties": {**required, **(optional or {})},
                        "required": list(required), "additionalProperties": False},
        "annotations": {"readOnlyHint": read_only, "openWorldHint": False},
    }


tool("list_projects", "List live Compositor tabs and identify the active one.", active=False, read_only=True)
tool("new_project", "Create a blank canvas in a new tab. Returns its project ID and layer IDs.",
     {"width": DIMENSION, "height": DIMENSION}, active=False)
tool("open_project", "Open a local .comp project in its own tab.", {"path": STRING}, active=False)
tool("select_project", "Switch to an existing tab from list_projects.", {"project_id": ID}, active=False)
tool("get_project", "Inspect the active project. Layer order is bottom to top. Returns IDs, layer metadata, "
     "current adjustment settings and the supported blend and adjustment names.", read_only=True)
tool("list_commands", "Discover the editor’s available menus and tool commands with their current enabled state.", read_only=True)
tool("run_command", "Invoke a native editor command by its ID from list_commands. Some commands open a panel "
     "or select a tool for the user to operate.", {"command_id": STRING})
tool("preview", "Render a flattened PNG preview of the active project, up to 960 pixels on its longer side.", read_only=True)
tool("import_media", "Import a local image, GIF, or movie into the active project as a layer. "
     "Movie layers link to the original file. RAW and Photoshop imports may need interaction in the app.", {"path": STRING})
tool("save_project", "Save an already named project to its current .comp file.")
tool("save_project_copy", "Write a .comp copy to a new local path, leaving the open tab attached to its current file.",
     {"path": STRING})
tool("export_png", "Export the full canvas as a flattened PNG to a new local path.", {"path": STRING})
tool("add_layer", "Add a blank pixel layer or group above the selection.", optional={
     "kind": {"enum": ["pixel", "group"]}, "name": STRING})
tool("add_text", "Create an editable text layer. Position is the layer’s top-left corner in canvas pixels.",
     {"text": STRING, "x": NUMBER, "y": NUMBER, "font_size": {"type": "number", "minimum": 1, "maximum": 2000},
      "color": STRING}, {"font": STRING})
tool("add_shape", "Create an editable rectangle or ellipse in canvas pixels.",
     {"kind": {"enum": ["rectangle", "ellipse"]}, "x": NUMBER, "y": NUMBER,
      "width": DIMENSION, "height": DIMENSION, "color": STRING})
tool("select_layer", "Select a layer by its ID.", {"layer_id": ID})
tool("edit_layer", "Edit layer appearance and placement in one undo step. Transform coordinates and unrotated "
     "dimensions use canvas pixels, with a top-left origin. Rotation is clockwise in degrees.", {"layer_id": ID}, {
         "name": STRING, "visible": BOOL, "opacity": {"type": "number", "minimum": 0, "maximum": 1},
         "blend_mode": STRING, "transform": TRANSFORM})
tool("duplicate_layer", "Duplicate a layer using the editor's native duplication rules.", {"layer_id": ID})
tool("move_layer", "Move a layer one position up or down among its siblings.",
     {"layer_id": ID, "direction": {"enum": ["up", "down"]}})
tool("delete_layer", "Delete a layer as an undoable edit. Groups and live mask sources are handled in the editor.",
     {"layer_id": ID})
tool("add_adjustment", "Add a non-destructive adjustment or filter layer, using a kind from get_project.", {"kind": STRING})
tool("set_adjustment", "Update fields on a native adjustment layer. Read the existing settings with get_project. "
     "Nested settings values replace their corresponding objects.", {"layer_id": ID, "settings": {"type": "object"}})
tool("add_mask", "Add a layer mask using the current selection, or fill it to reveal or hide the whole layer.",
     optional={"reveal": BOOL})
tool("set_selection", "Select all, deselect, or select a rectangle using canvas pixel coordinates.",
     {"mode": {"enum": ["all", "none", "rectangle"]}}, dict.fromkeys(("x", "y", "width", "height"), NUMBER))
tool("invert_pixels", "Invert the active layer's pixels within the current selection.")
tool("brush_stroke", "Paint an undoable stroke using canvas pixel coordinates. The points are in drawing order.", {
    "points": {"type": "array", "minItems": 1, "maxItems": 256,
               "items": {"type": "object", "properties": {"x": NUMBER, "y": NUMBER},
                         "required": ["x", "y"], "additionalProperties": False}},
    "diameter": {"type": "number", "minimum": 1, "maximum": 2000},
    "hardness": {"type": "number", "minimum": 0, "maximum": 1},
    "opacity": {"type": "number", "minimum": 0.01, "maximum": 1}, "color": STRING,
})
tool("select_gif_frame", "Show a GIF frame by one-based position in the filmstrip.", {"frame": {"type": "integer", "minimum": 1}})
tool("set_gif_delay", "Set a uniform GIF frame delay in milliseconds, or pass null to restore original timing.",
     {"milliseconds": {"type": ["number", "null"], "minimum": 20, "maximum": 655350}})
tool("undo", "Undo the last edit in the active project.")
tool("redo", "Redo the last undone edit in the active project.")


class Problem(Exception):
    pass


def secure_directory(path):
    try:
        path.mkdir(mode=0o700, parents=True)
    except FileExistsError:
        pass
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Problem("The MCP mailbox must be a private directory owned by the current user.")


def validate(value, schema, label):
    kinds = schema.get("type", [])
    if isinstance(kinds, str):
        kinds = [kinds]
    checks = {"object": lambda: isinstance(value, dict), "string": lambda: isinstance(value, str),
              "number": lambda: type(value) in (int, float), "integer": lambda: type(value) is int,
              "boolean": lambda: type(value) is bool, "null": lambda: value is None,
              "array": lambda: isinstance(value, list)}
    if kinds and not any(checks[kind]() for kind in kinds):
        raise Problem(f"Invalid {label}.")
    if "enum" in schema and value not in schema["enum"]:
        raise Problem(f"Invalid {label}.")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        if any(key not in value for key in schema.get("required", [])):
            raise Problem(f"Missing required fields in {label}.")
        if schema.get("additionalProperties") is False and value.keys() - props.keys():
            raise Problem(f"Unexpected fields in {label}.")
        for key in value.keys() & props.keys():
            validate(value[key], props[key], key)
    if isinstance(value, list) and "items" in schema:
        if not schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", LIMIT):
            raise Problem(f"Invalid {label}.")
        for item in value:
            validate(item, schema["items"], label)
    if isinstance(value, str) and len(value) < schema.get("minLength", 0):
        raise Problem(f"Invalid {label}.")
    if type(value) in (int, float):
        if not -1e12 <= value <= 1e12 or not schema.get("minimum", -1e12) <= value <= schema.get("maximum", 1e12):
            raise Problem(f"Invalid {label}.")


def output_copy(source, destination):
    if source.is_dir():
        # Reserve the name exclusively before copying a package.
        destination.mkdir()
        try:
            shutil.copytree(source, destination, dirs_exist_ok=True)
        except BaseException:
            shutil.rmtree(destination)
            raise
    else:
        # Build the file beside its destination, then install it without overwriting another file.
        with tempfile.NamedTemporaryFile(dir=destination.parent) as local:
            with source.open("rb") as produced:
                shutil.copyfileobj(produced, local)
            local.flush()
            os.link(local.name, destination)


class Editor:
    def __init__(self, options):
        self.options = options
        self.mailbox = Path("/private/tmp") / f"compositor-mcp-{os.getuid()}"

    def call(self, action, arguments):
        definition = TOOLS.get(action)
        if definition is None:
            raise Problem("Unknown Compositor tool.")
        validate(arguments, definition["inputSchema"], "arguments")
        arguments = dict(arguments)
        source = destination = None
        if action in ("open_project", "import_media"):
            source = Path(arguments.pop("path")).expanduser().resolve(strict=True)
            if action == "import_media" and not source.is_file():
                raise Problem("Import requires one regular file.")
        if action in ("save_project_copy", "export_png"):
            destination = Path(arguments.pop("path")).expanduser().absolute()
            suffix = ".comp" if action == "save_project_copy" else ".png"
            if destination.suffix.lower() != suffix or not destination.parent.is_dir():
                raise Problem(f"Choose a {suffix} path inside an existing directory.")
            if destination.exists() or destination.is_symlink():
                raise Problem("The destination already exists. Choose a new path.")
        secure_directory(self.mailbox)
        request_id = str(uuid.uuid4())
        folder = self.mailbox / (request_id + ".comp")
        folder.mkdir(mode=0o700)
        try:
            request = folder / "request.json"
            payload = {"id": request_id, "action": action, "arguments": arguments,
                       "deadline": time.time() + self.options.timeout}
            if source is not None:
                payload["input"] = str(source)
            data = json.dumps(payload, allow_nan=False).encode()
            if len(data) > LIMIT:
                raise Problem("Compositor request is too large.")
            with open(request, "xb", opener=lambda path, flags: os.open(path, flags, 0o600)) as handle:
                handle.write(data)
            target = ["-a", self.options.app] if self.options.app else ["-b", BUNDLE_ID]
            paths = [str(folder)] + ([str(source)] if source is not None else [])
            process = subprocess.run(["/usr/bin/open", "-g", *target, *paths], capture_output=True,
                                     text=True, timeout=15, check=False)
            if process.returncode:
                raise Problem(process.stderr.strip() or "macOS couldn’t open Compositor.")
            response = folder / "response.json"
            until = time.monotonic() + self.options.timeout
            while not response.exists():
                if time.monotonic() >= until:
                    raise Problem("Compositor didn’t respond. Check its build and any open dialogs. "
                                  "Inspect the project before retrying an edit.")
                time.sleep(0.025)
            result = json.loads(response.read_bytes())
            if "error" in result:
                raise Problem(result["error"])
            if action == "preview":
                image = (folder / "result.png").read_bytes()
                return {"content": [{"type": "image", "mimeType": "image/png",
                                     "data": base64.b64encode(image).decode("ascii")}]}
            if destination is not None:
                output_copy(folder / ("result.comp" if action == "save_project_copy" else "result.png"), destination)
                result["result"]["path"] = str(destination)
            value = result["result"]
            return {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}],
                    "structuredContent": value}
        finally:
            shutil.rmtree(folder, ignore_errors=True)


def handle(editor, request):
    if not isinstance(request, dict) or request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
        return {"id": None, "error": {"code": -32600, "message": "Invalid request"}}
    if "id" not in request:
        return None
    response = {"id": request["id"]}
    method = request["method"]
    params = request.get("params", {})
    if not isinstance(params, dict):
        return {**response, "error": {"code": -32602, "message": "Invalid params"}}
    if method == "initialize":
        version = params.get("protocolVersion")
        result = {"protocolVersion": version if version in PROTOCOLS else PROTOCOLS[0],
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "compositor", "version": "1.0.0"},
                  "instructions": "Start with list_projects. Tools that edit require the active project ID. "
                                  "Use preview to inspect the canvas and undo to reverse edits."}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": list(TOOLS.values())}
    elif method == "tools/call":
        try:
            name = params.get("name")
            if not isinstance(name, str):
                raise Problem("Missing tool name.")
            result = editor.call(name, params.get("arguments", {}))
        except (Problem, OSError, ValueError, subprocess.SubprocessError) as error:
            result = {"isError": True, "content": [{"type": "text", "text": str(error)}]}
    else:
        return {**response, "error": {"code": -32601, "message": "Method not found"}}
    return {**response, "result": result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", help="Path to a particular Compositor.app build")
    parser.add_argument("--timeout", type=int, default=90, choices=range(5, 301), metavar="SECONDS")
    options = parser.parse_args()
    editor = Editor(options)
    while True:
        line = sys.stdin.buffer.readline(LIMIT + 1)
        if not line:
            break
        if len(line) > LIMIT:
            while line and not line.endswith(b"\n"):
                line = sys.stdin.buffer.readline(LIMIT + 1)
            response = {"id": None, "error": {"code": -32600, "message": "Request too large"}}
        else:
            try:
                response = handle(editor, json.loads(line))
            except (ValueError, RecursionError):
                response = {"id": None, "error": {"code": -32700, "message": "Parse error"}}
        if response is not None:
            print(json.dumps({"jsonrpc": "2.0", **response}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
