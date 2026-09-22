#!/usr/bin/env python3
"""Compositor MCP stdio bridge. Standard library only; edits run in the live app.

No requests are retried: a disconnected mutation may already have committed.
Start Compositor and enable Agent Connection, then register this script as an MCP
stdio server. --endpoint overrides rendezvous discovery for separate builds.
"""
import argparse
import base64
import binascii
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import struct
import sys
import tempfile
import zlib


WIRE_LIMIT = 40 * 1024 * 1024
MAX_BYTES = WIRE_LIMIT  # Backward-compatible name used by older launch scripts/tests.
IMAGE_LIMIT = 24 * 1024 * 1024
PROJECT_LIMIT = 24 * 1024 * 1024
MANIFEST_LIMIT = 4 * 1024 * 1024
ENDPOINT_LIMIT = 64 * 1024
PROJECT_FORMAT = "com.compositor.mcp-project"
NATIVE_FORMAT = "com.compositor.project"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
IMAGE_NAME = re.compile(
    r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}(?:\.mask)?\.png$"
)


def _schema(properties, required):
    return {
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": False,
    }


_PATH = {"type": "string", "minLength": 1}
_DOCUMENT = {"type": "string", "minLength": 1}
_NUMBER = {"type": "number"}
_OVERWRITE = {"type": "boolean"}

LOCAL_TOOLS = [
    {"name": "open_document", "description": "Open a native .comp directory.", "inputSchema": _schema({"path": _PATH}, ["path"])},
    {"name": "save_document", "description": "Save a live document as a native .comp directory.", "inputSchema": _schema({"document_id": _DOCUMENT, "path": _PATH, "overwrite": _OVERWRITE}, ["path"])},
    {"name": "import_image_file", "description": "Import a local image file into a live document.", "inputSchema": _schema({"document_id": _DOCUMENT, "path": _PATH, "x": _NUMBER, "y": _NUMBER}, ["path"])},
    {"name": "export_image", "description": "Export a live document to a local PNG file.", "inputSchema": _schema({"document_id": _DOCUMENT, "path": _PATH, "overwrite": _OVERWRITE}, ["path"])},
]
LOCAL_BY_NAME = {tool["name"]: tool for tool in LOCAL_TOOLS}


class RPCError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _json_loads(data, label):
    try:
        return json.loads(
            data,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("non-finite number")),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        raise ValueError(f"{label} is not valid JSON.") from None


def _safe_path(value):
    if type(value) is not str or not value or "\x00" in value:
        raise ValueError("path must be a non-empty string.")
    raw = Path(value).expanduser()
    if not raw.is_absolute():
        raise ValueError("Path must be absolute.")
    if ".." in raw.parts:
        raise ValueError("Path traversal is not allowed.")
    return raw


def _lstat_regular(path, label="File"):
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        raise ValueError(f"{label} does not exist.") from None
    if stat.S_ISLNK(metadata.st_mode):
        raise ValueError(f"{label} may not be a symlink.")
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"{label} must be a regular file.")
    return metadata


def _bounded_read(path, maximum, label="File", require_private_owner=False):
    metadata = _lstat_regular(path, label)
    if require_private_owner and (metadata.st_uid != os.getuid() or metadata.st_mode & 0o077):
        raise ValueError("Unsafe Compositor endpoint permissions; re-enable Agent Connection in the app.")
    if metadata.st_size > maximum:
        raise ValueError(f"{label} exceeds the {maximum // (1024 * 1024)} MiB limit.")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or opened.st_size > maximum:
            raise ValueError(f"{label} is unsafe or too large.")
        if require_private_owner and (opened.st_uid != os.getuid() or opened.st_mode & 0o077):
            raise ValueError("Unsafe Compositor endpoint permissions; re-enable Agent Connection in the app.")
        chunks = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > maximum:
            raise ValueError(f"{label} exceeds the {maximum // (1024 * 1024)} MiB limit.")
        return data
    finally:
        os.close(descriptor)


def _decode_base64(value, maximum, label):
    if type(value) is not str:
        raise ValueError(f"{label} must be a base64 string.")
    encoded_limit = 4 * ((maximum + 2) // 3)
    try:
        encoded_size = len(value.encode("ascii"))
    except UnicodeEncodeError:
        raise ValueError(f"{label} must be valid base64.") from None
    if encoded_size > encoded_limit:
        raise ValueError(f"{label} exceeds the {maximum // (1024 * 1024)} MiB limit.")
    try:
        data = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError(f"{label} must be valid base64.") from None
    if len(data) > maximum:
        raise ValueError(f"{label} exceeds the {maximum // (1024 * 1024)} MiB limit.")
    return data


def _manifest_files(data):
    if len(data) > MANIFEST_LIMIT:
        raise ValueError("Project manifest exceeds the 4 MiB limit.")
    manifest = _json_loads(data, "Project manifest")
    if not isinstance(manifest, dict) or manifest.get("format") != NATIVE_FORMAT:
        raise ValueError("Project manifest is not a native Compositor manifest.")
    uuid_pattern = r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
    document_id = manifest.get("documentID")
    version, width, height = manifest.get("version"), manifest.get("width"), manifest.get("height")
    if (
        type(document_id) is not str
        or re.fullmatch(uuid_pattern, document_id.upper()) is None
        or type(version) is not int
        or not 1 <= version <= 9
        or manifest.get("colorSpace") != "sRGB"
        or type(width) is not int
        or type(height) is not int
        or not 1 <= width <= 30_000
        or not 1 <= height <= 30_000
    ):
        raise ValueError("Project manifest is missing required native document metadata.")
    layers = manifest.get("layers")
    if not isinstance(layers, list) or len(layers) > 10_000:
        raise ValueError("Project manifest layers must be a bounded array.")
    expected = set()
    for index, layer in enumerate(layers):
        if (
            not isinstance(layer, dict)
            or type(layer.get("id")) is not str
            or type(layer.get("name")) is not str
            or not layer["name"].strip()
            or type(layer.get("isVisible")) is not bool
            or not isinstance(layer.get("transform"), dict)
        ):
            raise ValueError(f"Project layer {index} is missing required native metadata.")
        transform = layer["transform"]
        origin, size = transform.get("origin"), transform.get("size")
        numeric = lambda value: type(value) in (int, float) and math.isfinite(value)
        if (
            type(origin) is not list
            or type(size) is not list
            or len(origin) != 2
            or len(size) != 2
            or not all(numeric(value) for value in origin + size)
            or not 1 <= size[0] <= 300_000
            or not 1 <= size[1] <= 300_000
            or abs(origin[0]) > 1_000_000
            or abs(origin[1]) > 1_000_000
        ):
            raise ValueError(f"Project layer {index} has an invalid transform.")
        layer_id = layer["id"].upper()
        canonical = re.fullmatch(uuid_pattern, layer_id)
        if canonical is None:
            raise ValueError(f"Project layer {index} has no valid UUID.")
        for field, suffix in (("imageFile", ".png"), ("maskFile", ".mask.png")):
            filename = layer.get(field)
            if filename is None:
                continue
            if type(filename) is not str or filename != layer_id + suffix or not IMAGE_NAME.fullmatch(filename):
                raise ValueError(f"Unsafe or non-native project image filename in {field}.")
            expected.add(filename)
    return manifest, expected


def _validate_png(data, label):
    if not data.startswith(PNG_SIGNATURE) or len(data) < 33:
        raise ValueError(f"{label} is not a valid PNG.")
    offset = len(PNG_SIGNATURE)
    saw_header = saw_data = saw_end = False
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        if length > len(data) - offset - 12:
            raise ValueError(f"{label} is not a valid PNG.")
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + length]
        checksum = struct.unpack(">I", data[offset + 8 + length : offset + 12 + length])[0]
        if zlib.crc32(chunk_type + chunk_data) & 0xFFFFFFFF != checksum:
            raise ValueError(f"{label} is not a valid PNG.")
        if not saw_header:
            if chunk_type != b"IHDR" or length != 13:
                raise ValueError(f"{label} is not a valid PNG.")
            width, height = struct.unpack(">II", chunk_data[:8])
            if width == 0 or height == 0:
                raise ValueError(f"{label} is not a valid PNG.")
            saw_header = True
        elif chunk_type == b"IDAT":
            saw_data = True
        elif chunk_type == b"IEND":
            if length != 0 or offset + 12 != len(data):
                raise ValueError(f"{label} is not a valid PNG.")
            saw_end = True
            break
        offset += 12 + length
    if not (saw_header and saw_data and saw_end):
        raise ValueError(f"{label} is not a valid PNG.")


def _reject_symlink(path, label):
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    if stat.S_ISLNK(metadata.st_mode):
        raise ValueError(f"{label} may not be a symlink.")


def _read_project_package(path):
    if path.suffix.lower() != ".comp":
        raise ValueError("Native project paths must end in .comp.")
    try:
        package_meta = path.lstat()
    except FileNotFoundError:
        raise ValueError("Project package does not exist.") from None
    if stat.S_ISLNK(package_meta.st_mode) or not stat.S_ISDIR(package_meta.st_mode):
        raise ValueError("Project package must be a real directory, not a symlink.")
    manifest_path = path / "manifest.json"
    images_path = path / "images"
    manifest_meta = _lstat_regular(manifest_path, "Project manifest")
    try:
        images_meta = images_path.lstat()
    except FileNotFoundError:
        raise ValueError("Project images directory is missing.") from None
    if stat.S_ISLNK(images_meta.st_mode) or not stat.S_ISDIR(images_meta.st_mode):
        raise ValueError("Project images must be a real directory, not a symlink.")
    for entry in list(path.iterdir()) + list(images_path.iterdir()):
        if entry.is_symlink():
            raise ValueError("Project packages may not contain symlinks.")
    manifest_data = _bounded_read(manifest_path, MANIFEST_LIMIT, "Project manifest")
    _, expected = _manifest_files(manifest_data)
    sizes = manifest_meta.st_size
    for filename in expected:
        file_meta = _lstat_regular(images_path / filename, f"Project image {filename}")
        sizes += file_meta.st_size
        if sizes > PROJECT_LIMIT:
            raise ValueError("Project files exceed the 24 MiB automation limit.")
    images = {}
    for filename in sorted(expected):
        image = _bounded_read(images_path / filename, PROJECT_LIMIT, f"Project image {filename}")
        _validate_png(image, f"Project image {filename}")
        images[filename] = base64.b64encode(image).decode("ascii")
    envelope = {
        "format": PROJECT_FORMAT,
        "manifest": base64.b64encode(manifest_data).decode("ascii"),
        "images": images,
    }
    raw = json.dumps(envelope, separators=(",", ":"), sort_keys=True, allow_nan=False).encode("utf-8")
    if len(raw) > PROJECT_LIMIT:
        raise ValueError("Encoded project exceeds the 24 MiB automation transport limit.")
    return base64.b64encode(raw).decode("ascii")


def _decode_project_envelope(encoded):
    raw = _decode_base64(encoded, PROJECT_LIMIT, "Project data")
    envelope = _json_loads(raw, "Project data")
    if not isinstance(envelope, dict) or set(envelope) != {"format", "manifest", "images"}:
        raise ValueError("Project data has an invalid envelope.")
    if envelope["format"] != PROJECT_FORMAT or not isinstance(envelope["images"], dict):
        raise ValueError("Project data has an unsupported format.")
    manifest_data = _decode_base64(envelope["manifest"], MANIFEST_LIMIT, "Project manifest")
    _, expected = _manifest_files(manifest_data)
    if set(envelope["images"]) != expected:
        raise ValueError("Project image filenames do not exactly match the manifest.")
    images = {}
    for filename, value in envelope["images"].items():
        if not IMAGE_NAME.fullmatch(filename) or Path(filename).name != filename:
            raise ValueError("Unsafe project image filename.")
        image = _decode_base64(value, PROJECT_LIMIT, f"Project image {filename}")
        _validate_png(image, f"Project image {filename}")
        images[filename] = image
    return manifest_data, images


def _validate_schema(value, schema, path="arguments"):
    expected = schema.get("type")
    if expected == "object":
        if not isinstance(value, dict):
            raise ValueError(f"{path} must be an object.")
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                raise ValueError(f"Missing {path}.{key}.")
        if schema.get("additionalProperties") is False:
            extras = set(value) - set(properties)
            if extras:
                raise ValueError(f"Unknown argument {path}.{sorted(extras)[0]}.")
        for key, child in value.items():
            if key in properties:
                _validate_schema(child, properties[key], f"{path}.{key}")
    elif expected == "string":
        if type(value) is not str or len(value) < schema.get("minLength", 0):
            raise ValueError(f"{path} must be a non-empty string.")
    elif expected == "boolean":
        if type(value) is not bool:
            raise ValueError(f"{path} must be a boolean.")
    elif expected == "number":
        if type(value) not in (int, float) or not math.isfinite(value):
            raise ValueError(f"{path} must be a finite number.")


def _validate_request(request):
    if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
        raise RPCError(-32600, "Invalid JSON-RPC request.")
    if "id" in request and (type(request["id"]) not in (str, int) and request["id"] is not None):
        raise RPCError(-32600, "Invalid JSON-RPC id.")
    if type(request.get("method")) is not str or not request["method"]:
        raise RPCError(-32600, "Invalid JSON-RPC method.")
    if "params" in request and not isinstance(request["params"], dict):
        raise RPCError(-32602, "params must be an object.")


def _tool_error(request, exc):
    return {
        "jsonrpc": "2.0",
        "id": request.get("id"),
        "result": {"content": [{"type": "text", "text": str(exc)}], "isError": True},
    }


def _native_result(response, operation):
    if not isinstance(response, dict):
        raise ValueError(f"Compositor returned an invalid {operation} response.")
    if "error" in response:
        return None
    result = response.get("result")
    if not isinstance(result, dict):
        raise ValueError(f"Compositor returned an invalid {operation} result.")
    if result.get("isError") is True:
        return None
    return result


def _optional_document(args):
    return {"document_id": args["document_id"]} if "document_id" in args else {}


def _prepare_destination(path, overwrite, kind):
    _reject_symlink(path, kind)
    if path.exists() and overwrite is not True:
        raise FileExistsError(f"Refusing to overwrite an existing {kind.lower()}; pass overwrite=true.")
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
    parent_meta = parent.lstat()
    if stat.S_ISLNK(parent_meta.st_mode) or not stat.S_ISDIR(parent_meta.st_mode):
        raise ValueError("Destination parent must be a real directory, not a symlink.")


def _atomic_export(path, data, overwrite):
    _prepare_destination(path, overwrite, "File")
    if path.exists() and not path.is_file():
        raise ValueError("Export destination must be a regular file.")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        if overwrite is True:
            os.replace(temporary_path, path)
        else:
            # link(2) is an atomic no-clobber install. A destination created after
            # _prepare_destination must not be silently replaced.
            os.link(temporary_path, path, follow_symlinks=False)
            temporary_path.unlink()
    except Exception:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass
        raise


def _write_project_stage(stage, manifest, images):
    (stage / "images").mkdir(parents=True)
    (stage / "manifest.json").write_bytes(manifest)
    for filename, data in images.items():
        (stage / "images" / filename).write_bytes(data)


def _atomic_save(path, manifest, images, overwrite):
    _prepare_destination(path, overwrite, "Project package")
    original = None
    if path.exists():
        original = path.lstat()
        _read_project_package(path)  # Existing targets must themselves be valid native projects.
        current = path.lstat()
        if (current.st_dev, current.st_ino, current.st_mode) != (original.st_dev, original.st_ino, original.st_mode):
            raise RuntimeError("Project destination changed while it was being validated; no files were replaced.")
    workspace = Path(tempfile.mkdtemp(prefix=f".{path.name}.", dir=path.parent))
    stage = workspace / "staged.comp"
    backup = workspace / "backup.comp"
    preserve_workspace = False
    moved_old = False
    try:
        _write_project_stage(stage, manifest, images)
        if path.exists():
            os.replace(path, backup)
            moved_old = True
            moved = backup.lstat()
            if original is None or (moved.st_dev, moved.st_ino, moved.st_mode) != (original.st_dev, original.st_ino, original.st_mode):
                try:
                    if path.exists():
                        preserve_workspace = True
                        raise RuntimeError(f"Project destination changed while saving; the moved item is preserved at {backup}.")
                    os.replace(backup, path)
                    moved_old = False
                except Exception as restore_error:
                    preserve_workspace = True
                    raise RuntimeError(f"Project destination changed while saving; the moved item is preserved at {backup}: {restore_error}") from restore_error
                raise RuntimeError("Project destination changed while saving; the unexpected item was restored and no files were replaced.")
        try:
            os.replace(stage, path)
        except Exception as replacement_error:
            if moved_old:
                try:
                    if path.exists():
                        preserve_workspace = True
                        raise RuntimeError(
                            f"Project replacement failed and the destination reappeared; the previous project is preserved at {backup}."
                        )
                    os.replace(backup, path)
                    moved_old = False
                except Exception as rollback_error:
                    preserve_workspace = True
                    raise RuntimeError(
                        f"Project replacement failed and rollback also failed; the previous project is preserved at {backup}: {rollback_error}"
                    ) from replacement_error
            raise
    finally:
        if not preserve_workspace:
            shutil.rmtree(workspace, ignore_errors=True)


def _local_call(request, endpoint):
    _validate_request(request)
    method = request["method"]
    if method == "tools/call":
        if "id" not in request:
            return None  # Tool notifications must never mutate either the filesystem or the app.
        params = request.get("params", {})
        if type(params.get("name")) is not str:
            raise RPCError(-32602, "tools/call name must be a string.")
        if "arguments" in params and not isinstance(params["arguments"], dict):
            raise RPCError(-32602, "tools/call arguments must be an object.")
    if method == "tools/list":
        response = exchange(request, endpoint)
        if isinstance(response, dict) and isinstance(response.get("result"), dict):
            listed = response["result"].get("tools")
            if isinstance(listed, list):
                native_names = {tool.get("name") for tool in listed if isinstance(tool, dict)}
                response["result"]["tools"] = listed + [tool for tool in LOCAL_TOOLS if tool["name"] not in native_names]
        return response
    if method != "tools/call":
        return exchange(request, endpoint)
    params = request.get("params", {})
    name = params.get("name")
    if name not in LOCAL_BY_NAME:
        return exchange(request, endpoint)
    args = params.get("arguments", {})
    try:
        _validate_schema(args, LOCAL_BY_NAME[name]["inputSchema"])
        path = _safe_path(args["path"])
        if name == "open_document":
            encoded = _read_project_package(path)
            forwarded = {**request, "params": {"name": "open_project_data", "arguments": {"data": encoded}}}
            return exchange(forwarded, endpoint)
        if name == "import_image_file":
            data = _bounded_read(path, IMAGE_LIMIT, "Image")
            forwarded_args = {
                "data": base64.b64encode(data).decode("ascii"),
                "filename": path.name,
                **_optional_document(args),
            }
            if ("x" in args) != ("y" in args):
                raise ValueError("x and y must be provided together.")
            if "x" in args:
                forwarded_args.update(x=args["x"], y=args["y"])
            return exchange({**request, "params": {"name": "import_image", "arguments": forwarded_args}}, endpoint)
        if name == "export_image":
            if path.suffix.lower() != ".png":
                raise ValueError("Export paths must end in .png.")
            _prepare_destination(path, args.get("overwrite"), "File")
            native_args = {"max_dimension": 0, **_optional_document(args)}
            response = exchange({**request, "params": {"name": "render_document", "arguments": native_args}}, endpoint)
            result = _native_result(response, "render")
            if result is None:
                return response
            content = result.get("content")
            structured = result.get("structuredContent")
            if not isinstance(content, list) or not isinstance(structured, dict):
                raise ValueError("Compositor returned no rendered image metadata.")
            width, height = structured.get("width"), structured.get("height")
            if type(width) is not int or type(height) is not int or width <= 0 or height <= 0:
                raise ValueError("Compositor returned invalid rendered image dimensions.")
            image_item = next((item for item in content if isinstance(item, dict) and item.get("type") == "image"), None)
            if not image_item or image_item.get("mimeType") != "image/png":
                raise ValueError("Compositor returned no PNG image.")
            image = _decode_base64(image_item.get("data"), IMAGE_LIMIT, "Rendered image")
            _validate_png(image, "Rendered image")
            _atomic_export(path, image, args.get("overwrite"))
            return {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "result": {
                    "content": [{"type": "text", "text": f"Exported {width}×{height} PNG to {path}."}],
                    "structuredContent": {"path": str(path), "width": width, "height": height, "mime_type": "image/png"},
                    "isError": False,
                },
            }
        if name == "save_document":
            if path.suffix.lower() != ".comp":
                raise ValueError("Native project paths must end in .comp.")
            _prepare_destination(path, args.get("overwrite"), "Project package")
            if path.exists():
                _read_project_package(path)
            response = exchange(
                {**request, "params": {"name": "read_project_data", "arguments": _optional_document(args)}}, endpoint
            )
            result = _native_result(response, "project serialization")
            if result is None:
                return response
            structured = result.get("structuredContent")
            if not isinstance(structured, dict):
                raise ValueError("Compositor returned no project data.")
            if (
                type(structured.get("document_id")) is not str
                or not structured["document_id"]
                or type(structured.get("revision")) is not int
                or structured["revision"] < 0
            ):
                raise ValueError("Compositor returned invalid project metadata.")
            manifest, images = _decode_project_envelope(structured.get("data"))
            _atomic_save(path, manifest, images, args.get("overwrite"))
            return {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "result": {
                    "content": [{"type": "text", "text": f"Saved project to {path}."}],
                    "structuredContent": {"path": str(path), "document_id": structured["document_id"], "revision": structured["revision"]},
                    "isError": False,
                },
            }
    except Exception as exc:
        return _tool_error(request, exc)


def discover(explicit=None):
    candidates = [Path(explicit)] if explicit else [
        Path.home() / "Library/Containers/com.wonderassembly.compositor/Data/Library/Application Support/Compositor/automation.json",
        Path.home() / "Library/Application Support/Compositor/automation.json",
    ]
    for path in candidates:
        try:
            metadata = path.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
                raise ValueError("Unsafe Compositor endpoint permissions; re-enable Agent Connection in the app.")
            value = _json_loads(_bounded_read(path, ENDPOINT_LIMIT, "Compositor endpoint metadata", require_private_owner=True), "Compositor endpoint metadata")
            if (
                type(value) is not dict
                or type(value.get("port")) is not int
                or not 1 <= value["port"] <= 65535
                or type(value.get("token")) is not str
                or len(value["token"]) < 32
            ):
                raise ValueError("Invalid Compositor endpoint metadata.")
            return value
        except FileNotFoundError:
            continue
    raise RuntimeError("Open Compositor and enable Agent Connection in the app menu first.")


def exchange(request, endpoint=None):
    target = discover(endpoint)
    wire = json.dumps({"token": target["token"], "request": request}, separators=(",", ":"), allow_nan=False).encode() + b"\n"
    if len(wire) > WIRE_LIMIT:
        raise ValueError("Request exceeds the 40 MiB limit.")
    with socket.create_connection(("127.0.0.1", target["port"]), timeout=5) as connection:
        connection.settimeout(120)
        connection.sendall(wire)
        data = bytearray()
        while True:
            chunk = connection.recv(65536)
            if not chunk:
                raise ConnectionError("Compositor disconnected. The request may have completed; inspect state before retrying.")
            data.extend(chunk)
            newline = data.find(b"\n")
            if newline >= 0:
                if newline > WIRE_LIMIT:
                    raise ValueError("Response exceeds the 40 MiB limit.")
                try:
                    outer = _json_loads(data[:newline], "Compositor response")
                except ValueError:
                    raise ValueError("Compositor returned malformed JSON.") from None
                if not isinstance(outer, dict) or set(outer) != {"response"}:
                    raise ValueError("Compositor returned an invalid response envelope.")
                response = outer["response"]
                if "id" not in request:
                    if response is not None:
                        raise ValueError("Compositor responded to a notification.")
                    return None
                if (
                    not isinstance(response, dict)
                    or response.get("jsonrpc") != "2.0"
                    or response.get("id") != request.get("id")
                    or (("result" in response) == ("error" in response))
                ):
                    raise ValueError("Compositor returned an invalid JSON-RPC response.")
                if "error" in response:
                    rpc_error = response["error"]
                    if (
                        not isinstance(rpc_error, dict)
                        or type(rpc_error.get("code")) is not int
                        or type(rpc_error.get("message")) is not str
                    ):
                        raise ValueError("Compositor returned an invalid JSON-RPC error.")
                return response
            if len(data) > WIRE_LIMIT:
                raise ValueError("Response exceeds the 40 MiB limit.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint")
    options = parser.parse_args()
    for line in iter(lambda: sys.stdin.buffer.readline(WIRE_LIMIT + 1), b""):
        request = None
        parse_error = False
        try:
            if len(line) > WIRE_LIMIT:
                while not line.endswith(b"\n"):
                    line = sys.stdin.buffer.readline(WIRE_LIMIT + 1)
                    if not line:
                        break
                raise RPCError(-32600, "Request exceeds the 40 MiB limit.")
            try:
                request = json.loads(
                    line,
                    parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("Non-finite JSON number")),
                )
            except Exception:
                parse_error = True
                raise RPCError(-32700, "Malformed JSON.")
            response = _local_call(request, options.endpoint)
        except Exception as exc:
            if isinstance(request, dict) and "id" not in request:
                print(str(exc), file=sys.stderr)
                continue
            code = exc.code if isinstance(exc, RPCError) else (-32700 if parse_error else -32000)
            response = {
                "jsonrpc": "2.0",
                "id": request.get("id") if isinstance(request, dict) else None,
                "error": {"code": code, "message": str(exc)},
            }
        if response is not None:
            sys.stdout.write(json.dumps(response, separators=(",", ":"), allow_nan=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
