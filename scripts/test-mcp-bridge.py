#!/usr/bin/env python3
import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = ROOT / "Compositor/Automation/compositor-mcp.py"
spec = importlib.util.spec_from_file_location("compositor_mcp", BRIDGE_PATH)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

LAYER_ID = "F5A14720-4CC8-40E0-A291-03EA0902B799"
IMAGE_NAME = f"{LAYER_ID}.png"
NATIVE_MANIFEST = base64.b64decode(
    "eyJhY3RpdmVMYXllcklEIjoiOEY0QkMyQUQtQTkwNS00QUJCLUFDOTAtMUQ0Q0U2NzIyQkU0IiwiY29sb3JTcGFjZSI6InNSR0IiLCJkb2N1bWVudElEIjoiNTRDNDA0QkItN0JFMC00QTZGLUIzNTQtMTkwMzQ1NkUyOUM3IiwiZm9ybWF0IjoiY29tLmNvbXBvc2l0b3IucHJvamVjdCIsImhlaWdodCI6MjAwLCJsYXllcnMiOlt7ImJsZW5kTW9kZSI6Ik5vcm1hbCIsImlkIjoiRjVBMTQ3MjAtNENDOC00MEUwLUEyOTEtMDNFQTA5MDJCNzk5IiwiaW1hZ2VGaWxlIjoiRjVBMTQ3MjAtNENDOC00MEUwLUEyOTEtMDNFQTA5MDJCNzk5LnBuZyIsImlzR3JvdXAiOmZhbHNlLCJpc1Zpc2libGUiOnRydWUsIm5hbWUiOiJMYXllciAxIiwib3BhY2l0eSI6MSwidHJhbnNmb3JtIjp7ImZsaXBYIjpmYWxzZSwiZmxpcFkiOmZhbHNlLCJvcmlnaW4iOlsxMCwxMF0sInJvdGF0aW9uIjowLCJzYW1wbGluZyI6IkhpZ2ggcXVhbGl0eSIsInNpemUiOls4MCwyMF19fSx7ImJsZW5kTW9kZSI6Ik5vcm1hbCIsImVmZmVjdHMiOnsic3Ryb2tlIjp7ImJsdWUiOjAsImdyZWVuIjowLCJpbnNpZGUiOmZhbHNlLCJvcGFjaXR5IjoxLCJyZWQiOjAsInNpemUiOjR9fSwiaWQiOiI4RjRCQzJBRC1BOTA1LTRBQkItQUM5MC0xRDRDRTY3MjJCRTQiLCJpbWFnZUZpbGUiOiI4RjRCQzJBRC1BOTA1LTRBQkItQUM5MC0xRDRDRTY3MjJCRTQucG5nIiwiaXNHcm91cCI6ZmFsc2UsImlzVmlzaWJsZSI6dHJ1ZSwibWFza0VuYWJsZWQiOnRydWUsIm1hc2tGaWxlIjoiOEY0QkMyQUQtQTkwNS00QUJCLUFDOTAtMUQ0Q0U2NzIyQkU0Lm1hc2sucG5nIiwibWFza0xpbmtlZCI6dHJ1ZSwibmFtZSI6IkFnZW50IGNvbXBvc2l0ZSIsIm9wYWNpdHkiOjEsInNoYXBlIjp7ImJsdWUiOjAuNywiY29ybmVyUmFkaXVzIjoxMiwiZ3JlZW4iOjAuNSwia2luZCI6IlJlY3RhbmdsZSIsInJlZCI6MC4xfSwidHJhbnNmb3JtIjp7ImZsaXBYIjpmYWxzZSwiZmxpcFkiOmZhbHNlLCJvcmlnaW4iOlsxMTAsMzVdLCJyb3RhdGlvbiI6MCwic2FtcGxpbmciOiJIaWdoIHF1YWxpdHkiLCJzaXplIjpbMTYwLDExMF19fV0sInJlc29sdXRpb24iOjcyLCJ2ZXJzaW9uIjo5LCJ3aWR0aCI6MzIwfQ=="
)
NATIVE_IMAGES = {
    "8F4BC2AD-A905-4ABB-AC90-1D4CE6722BE4.mask.png": base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAAOGVYSWZNTQAqAAAACAABh2kABAAAAAEAAAAaAAAAAAACoAIABAAAAAEAAAABoAMABAAAAAEAAAABAAAAANrqv8QAAAAKSURBVAgdY/gPAAEBAQA2X2eAAAAAAElFTkSuQmCC"
    ),
    "8F4BC2AD-A905-4ABB-AC90-1D4CE6722BE4.png": base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAKAAAABuCAYAAACgLRjpAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAoKADAAQAAAABAAAAbgAAAADxyU8zAAAEqUlEQVR4Ae3ZsUocURiG4XPGrJ2liCkipNWrsFcJQrDwGgKpLGy2sch9WIggQdN7FbENaKGIpZ2Lnpx/dGVXjex8+3V507jq/L/w8HI2O5PTO/8Wd4+W8kxvq+S0mnNeTqXMp5xn3xnhV/+7QCl3tZGbUspZLum03A8OrvY2z//Fkt/6xcf+r0+ppB8ll6855eata/gZApMIlFQecsmHKaedy/7axcuZVwEu9I/Xm5T3a3hzLy/mewRUgRri7UMq29f9jZPRHWOnWz35vtX4fhLfKBGvHQLRVLQVjY3uez4Bn06+iG8sytGLeY3AtALxllxPwi/Dk7ANMP7PV3/xm5NvWl7mJxGIt+Pa2kr8n/DxtKsfOIhvEjqucQi0rdXmYleOWy2p1/tTf8hbr0OXHRMJxFtxGgw+f4j7fLVD4puIjYtcAu2BV9tr4iazayl7EOgiEO017ROOLlNci4BJINpr2sdrpoWsQaCTQH20W+8N8my3ExoX+wRqe3z48HGySRAgQAGNEZ8AAfos2SQIEKCAxohPgAB9lmwSBAhQQGPEJ0CAPks2CQIEKKAx4hMgQJ8lmwQBAhTQGPEJEKDPkk2CAAEKaIz4BAjQZ8kmQYAABTRGfAIE6LNkkyBAgAIaIz4BAvRZskkQIEABjRGfAAH6LNkkCBCggMaIT4AAfZZsEgQIUEBjxCdAgD5LNgkCBCigMeITIECfJZsEAQIU0BjxCRCgz5JNggABCmiM+AQI0GfJJkGAAAU0RnwCBOizZJMgQIACGiM+AQL0WbJJECBAAY0RnwAB+izZJAgQoIDGiE+AAH2WbBIECFBAY8QnQIA+SzYJAgQooDHiEyBAnyWbBAECFNAY8QkQoM+STYIAAQpojPgECNBnySZBgAAFNEZ8AgTos2STIECAAhojPgEC9FmySRAgQAGNEZ8AAfos2SQIEKCAxohPgAB9lmwSBAhQQGPEJ0CAPks2CQIEKKAx4hMgQJ8lmwQBAhTQGPEJEKDPkk2CAAEKaIz4BAjQZ8kmQYAABTRGfAIE6LNkkyBAgAIaIz4BAvRZskkQIEABjRGfAAH6LNkkCBCggMaIT4AAfZZsEgQIUEBjxCdAgD5LNgkCBCigMeITIECfJZsEAQIU0BjxCRCgz5JNggABCmiM+AQI0GfJJkGAAAU0RnwCBOizZJMgQIACGiM+AQL0WbJJECBAAY0RnwAB+izZJAgQoIDGiE+AAH2WbBIEmlTKnTDHCALTC9T2mpTzzfSb2ICAIFDba0opZ8IoIwhMLRDtNbmk06k3sQABQSDaa8r94KCk8iDMM4KALBDNRXvN1d7meS75UN7EIAKCQDQX7T3ehslppxZ5K+xhBIHOAm1rtbkYbAO87K9dPKSyzVtxZ0sGOgpEY9FaNBejzzeir/sbJznl70TYUZTLJxaItqKxaG04lIcvhl8X+sfr9ebgfr1wbvgzviIwrUCN7zZOvtH4YufzCTj8A08n4UoqiU/HQxS+ygLtO2ptqR5oKy/ji6WvTsDRv7S4e7SUZ3pbJafVnPNyfWw3X5+czI5ew2sExgTi0W59whE3meM+X9xqiU+7Y9eMfPMXO1jQvz60080AAAAASUVORK5CYII="
    ),
    IMAGE_NAME: base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAFAAAAAUCAYAAAAa2LrXAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAUKADAAQAAAABAAAAFAAAAACck7LGAAABBElEQVRYCe2Y4QmDMBCFox2jYJfoGu7gJh3CBbqDa7hEBbeo2PeslgTSJj1/+g4eMegJflzi5RXuS8zONbhVQ1foDJ2gI8WEjx2hHuoK5+4Y00Fw0AOapYABmTQ/CeKBVtACaLEiaqMQBS8JzocZQmRpqvL+AkiYy3LG3ojNDnsehorXimwCA+BdypWk4GVz+zxYkV2JKVsVhY1AXWj52sitWQMBPjE5WpO8i5qXPHEJK3YQIEAeVxQ2AiMB8qynsBHoCbCz5SqL7NRI2+vg3Uiv+Tf7ew6bGTJDOyMnJt/CC82ErYYEMctQiMPzIMpQjVdi1FBdfiIbPH9ENTaYy9JPWPov3skp4KF8eIMAAAAASUVORK5CYII="
    ),
}
PNG = NATIVE_IMAGES[IMAGE_NAME]


def manifest_bytes():
    return NATIVE_MANIFEST


def envelope_data(manifest=None, images=None):
    manifest = manifest if manifest is not None else manifest_bytes()
    images = images if images is not None else NATIVE_IMAGES
    envelope = {
        "format": bridge.PROJECT_FORMAT,
        "manifest": base64.b64encode(manifest).decode(),
        "images": {name: base64.b64encode(data).decode() for name, data in images.items()},
    }
    return base64.b64encode(json.dumps(envelope, separators=(",", ":")).encode()).decode()


def native_project_result(data=None):
    return {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {
            "content": [{"type": "text", "text": "serialized"}],
            "structuredContent": {
                "data": data or envelope_data(),
                "revision": 7,
                "document_id": "DOC-1",
            },
            "isError": False,
        },
    }


def render_result(data=PNG, width=10, height=20):
    return {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {
            "content": [{"type": "image", "data": base64.b64encode(data).decode(), "mimeType": "image/png"}],
            "structuredContent": {"width": width, "height": height},
            "isError": False,
        },
    }


def request(name, arguments, request_id=1):
    value = {"jsonrpc": "2.0", "method": "tools/call", "params": {"name": name, "arguments": arguments}}
    if request_id is not ...:
        value["id"] = request_id
    return value


def make_package(path, manifest=None, images=None):
    manifest = manifest if manifest is not None else manifest_bytes()
    images = images if images is not None else NATIVE_IMAGES
    (path / "images").mkdir(parents=True)
    (path / "manifest.json").write_bytes(manifest)
    for name, data in images.items():
        (path / "images" / name).write_bytes(data)


class BridgeTests(unittest.TestCase):
    def endpoint(self, mode=0o600, value=None):
        directory = tempfile.TemporaryDirectory()
        path = Path(directory.name) / "automation.json"
        path.write_text(json.dumps(value or {"port": 4567, "token": "x" * 32}))
        os.chmod(path, mode)
        return directory, path

    def assert_tool_error(self, response, contains=None):
        self.assertTrue(response["result"]["isError"])
        if contains:
            self.assertIn(contains, response["result"]["content"][0]["text"])

    def test_local_tool_schemas_are_closed_and_typed(self):
        for tool in bridge.LOCAL_TOOLS:
            self.assertFalse(tool["inputSchema"]["additionalProperties"])
        with tempfile.TemporaryDirectory() as directory, patch.object(bridge, "exchange") as exchange:
            path = str(Path(directory) / "image.png")
            cases = [
                ("open_document", {"path": path, "extra": True}, "Unknown argument"),
                ("save_document", {"path": path, "overwrite": 1}, "must be a boolean"),
                ("import_image_file", {"path": path, "x": True, "y": 2}, "finite number"),
                ("export_image", {"path": 3}, "non-empty string"),
            ]
            for name, arguments, message in cases:
                with self.subTest(name=name, arguments=arguments):
                    self.assert_tool_error(bridge._local_call(request(name, arguments), None), message)
            exchange.assert_not_called()

    def test_request_envelope_validation_and_tool_notifications_are_silent(self):
        invalid = [
            {},
            {"jsonrpc": "1.0", "id": 1, "method": "ping"},
            {"jsonrpc": "2.0", "id": True, "method": "ping"},
            {"jsonrpc": "2.0", "id": 1, "method": 3},
            {"jsonrpc": "2.0", "id": 1, "method": "ping", "params": []},
        ]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(bridge.RPCError):
                bridge._local_call(value, None)
        with patch.object(bridge, "exchange") as exchange:
            self.assertIsNone(bridge._local_call(request("open_document", {"path": "/tmp/a.comp"}, ...), None))
            self.assertIsNone(bridge._local_call(request("layer_operation", {"action": "add"}, ...), None))
            exchange.assert_not_called()

    def test_nonlocal_calls_forward_unchanged_and_tools_list_appends_local_tools_once(self):
        call = request("layer_operation", {"action": "add"})
        with patch.object(bridge, "exchange", return_value={"ok": True}) as exchange:
            self.assertEqual(bridge._local_call(call, "endpoint"), {"ok": True})
            exchange.assert_called_once_with(call, "endpoint")
        listing = {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
        native = {"result": {"tools": [{"name": "native"}, {"name": "open_document"}]}}
        with patch.object(bridge, "exchange", return_value=native):
            result = bridge._local_call(listing, None)
        names = [tool["name"] for tool in result["result"]["tools"]]
        self.assertEqual(names.count("open_document"), 1)
        self.assertEqual(set(names), {"native", *(tool["name"] for tool in bridge.LOCAL_TOOLS)})

    def test_safe_path_and_bounded_read_reject_traversal_symlinks_and_oversize_before_open(self):
        with self.assertRaises(ValueError):
            bridge._safe_path("relative.png")
        with self.assertRaises(ValueError):
            bridge._safe_path("/tmp/../escape.png")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / "file"
            file.write_bytes(b"abcd")
            self.assertEqual(bridge._bounded_read(file, 4), b"abcd")
            link = root / "link"
            link.symlink_to(file)
            with self.assertRaises(ValueError):
                bridge._bounded_read(link, 4)
            huge = root / "huge"
            huge.write_bytes(b"12345")
            with patch.object(bridge.os, "open") as opened, self.assertRaises(ValueError):
                bridge._bounded_read(huge, 4)
            opened.assert_not_called()

    def test_base64_decoder_checks_encoded_bound_and_validity(self):
        self.assertEqual(bridge._decode_base64("YQ==", 1, "Data"), b"a")
        for value in ("***", "YWJj"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                bridge._decode_base64(value, 1, "Data")

    def test_manifest_contract_rejects_non_native_and_unsafe_filenames(self):
        _, files = bridge._manifest_files(manifest_bytes())
        self.assertEqual(files, set(NATIVE_IMAGES))
        native = json.loads(manifest_bytes())
        self.assertEqual(native["version"], 9)
        self.assertEqual(native["layers"][0]["transform"]["origin"], [10, 10])
        self.assertEqual(native["layers"][0]["transform"]["size"], [80, 20])
        bad_manifest = json.loads(manifest_bytes())
        bad_manifest["layers"][0]["imageFile"] = "../x.png"
        bad = json.dumps(bad_manifest).encode()
        with self.assertRaises(ValueError):
            bridge._manifest_files(bad)
        with self.assertRaises(ValueError):
            bridge._manifest_files(json.dumps({"format": "wrong", "layers": []}).encode())

    def test_manifest_transform_uses_native_cgpoint_cgsize_arrays_with_bounds(self):
        native = json.loads(manifest_bytes())
        native["layers"][0]["transform"]["origin"] = {"x": 10, "y": 10}
        with self.assertRaises(ValueError):
            bridge._manifest_files(json.dumps(native).encode())
        native = json.loads(manifest_bytes())
        native["layers"][0]["transform"]["size"] = [0, 20]
        with self.assertRaises(ValueError):
            bridge._manifest_files(json.dumps(native).encode())

    def test_project_envelope_decode_enforces_exact_files_png_and_24mb_bound(self):
        manifest, images = bridge._decode_project_envelope(envelope_data())
        self.assertEqual(manifest, manifest_bytes())
        self.assertEqual(images, NATIVE_IMAGES)
        with self.assertRaises(ValueError):
            bridge._decode_project_envelope(envelope_data(images={}))
        invalid_images = dict(NATIVE_IMAGES)
        invalid_images[IMAGE_NAME] = b"not png"
        with self.assertRaises(ValueError):
            bridge._decode_project_envelope(envelope_data(images=invalid_images))
        with patch.object(bridge, "PROJECT_LIMIT", 8), self.assertRaises(ValueError):
            bridge._decode_project_envelope(envelope_data())

    def test_open_document_encodes_native_package_and_forwards_exact_open_project_data_args(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "art.comp"
            make_package(package)
            downstream = {"jsonrpc": "2.0", "id": 1, "result": {"isError": False}}
            with patch.object(bridge, "exchange", return_value=downstream) as exchange:
                result = bridge._local_call(request("open_document", {"path": str(package)}), "endpoint")
            self.assertIs(result, downstream)
            forwarded = exchange.call_args.args[0]
            self.assertEqual(forwarded["params"]["name"], "open_project_data")
            self.assertEqual(set(forwarded["params"]["arguments"]), {"data"})
            manifest, images = bridge._decode_project_envelope(forwarded["params"]["arguments"]["data"])
            self.assertEqual(manifest, manifest_bytes())
            self.assertEqual(images[IMAGE_NAME], PNG)

    def test_open_document_rejects_package_and_member_symlinks_without_native_call(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            real = root / "real.comp"
            make_package(real)
            package_link = root / "link.comp"
            package_link.symlink_to(real, target_is_directory=True)
            with patch.object(bridge, "exchange") as exchange:
                self.assert_tool_error(bridge._local_call(request("open_document", {"path": str(package_link)}), None), "symlink")
                image = real / "images" / IMAGE_NAME
                image.unlink()
                image.symlink_to(root / "outside.png")
                self.assert_tool_error(bridge._local_call(request("open_document", {"path": str(real)}), None), "symlink")
                exchange.assert_not_called()

    def test_import_image_forwards_filename_document_and_coordinates_exactly(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "photo.jpeg"
            image.write_bytes(b"jpeg-data")
            downstream = {"result": {"isError": False}}
            arguments = {"path": str(image), "document_id": "DOC", "x": 1.5, "y": -2}
            with patch.object(bridge, "exchange", return_value=downstream) as exchange:
                self.assertIs(bridge._local_call(request("import_image_file", arguments), None), downstream)
            forwarded = exchange.call_args.args[0]
            self.assertEqual(forwarded["params"], {"name": "import_image", "arguments": {
                "data": base64.b64encode(b"jpeg-data").decode(), "filename": "photo.jpeg",
                "document_id": "DOC", "x": 1.5, "y": -2,
            }})

    def test_import_requires_coordinate_pair_and_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(bridge, "exchange") as exchange:
            root = Path(directory)
            image = root / "image.png"
            image.write_bytes(PNG)
            self.assert_tool_error(bridge._local_call(request("import_image_file", {"path": str(image), "x": 1}), None), "together")
            link = root / "link.png"
            link.symlink_to(image)
            self.assert_tool_error(bridge._local_call(request("import_image_file", {"path": str(link)}), None), "symlink")
            exchange.assert_not_called()

    def test_save_roundtrip_omits_null_document_id_and_returns_native_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "saved.comp"
            with patch.object(bridge, "exchange", return_value=native_project_result()) as exchange:
                result = bridge._local_call(request("save_document", {"path": str(destination)}), None)
            self.assertFalse(result["result"]["isError"])
            self.assertEqual(result["result"]["structuredContent"]["revision"], 7)
            self.assertEqual(exchange.call_args.args[0]["params"], {"name": "read_project_data", "arguments": {}})
            self.assertEqual((destination / "manifest.json").read_bytes(), manifest_bytes())
            self.assertEqual((destination / "images" / IMAGE_NAME).read_bytes(), PNG)
            encoded = bridge._read_project_package(destination)
            self.assertEqual(bridge._decode_project_envelope(encoded), (manifest_bytes(), NATIVE_IMAGES))

    def test_save_passes_document_id_and_requires_native_result_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(bridge, "exchange", return_value=native_project_result()) as exchange:
                bridge._local_call(request("save_document", {"path": str(root / "ok.comp"), "document_id": "DOC"}), None)
            self.assertEqual(exchange.call_args.args[0]["params"]["arguments"], {"document_id": "DOC"})
            bad_results = [
                {"result": {"isError": False}},
                {"result": {"structuredContent": {"data": envelope_data(), "revision": 1}, "isError": False}},
                {"result": {"structuredContent": {"data": envelope_data(), "revision": True, "document_id": "D"}, "isError": False}},
            ]
            for index, bad in enumerate(bad_results):
                with self.subTest(index=index), patch.object(bridge, "exchange", return_value=bad):
                    result = bridge._local_call(request("save_document", {"path": str(root / f"bad{index}.comp")}), None)
                    self.assert_tool_error(result, "project")

    def test_save_propagates_native_tool_error_without_writing(self):
        downstream = {"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "busy"}], "isError": True}}
        with tempfile.TemporaryDirectory() as directory, patch.object(bridge, "exchange", return_value=downstream):
            destination = Path(directory) / "saved.comp"
            self.assertIs(bridge._local_call(request("save_document", {"path": str(destination)}), None), downstream)
            self.assertFalse(destination.exists())

    def test_save_overwrite_requires_explicit_true_and_existing_valid_comp(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(bridge, "exchange", return_value=native_project_result()) as exchange:
            root = Path(directory)
            valid = root / "valid.comp"
            make_package(valid)
            refused = bridge._local_call(request("save_document", {"path": str(valid)}), None)
            self.assert_tool_error(refused, "overwrite=true")
            arbitrary = root / "arbitrary.comp"
            arbitrary.mkdir()
            (arbitrary / "valuable.txt").write_text("keep")
            refused = bridge._local_call(request("save_document", {"path": str(arbitrary), "overwrite": True}), None)
            self.assert_tool_error(refused, "manifest")
            self.assertEqual((arbitrary / "valuable.txt").read_text(), "keep")
            plain = root / "ordinary-directory"
            plain.mkdir()
            refused = bridge._local_call(request("save_document", {"path": str(plain), "overwrite": True}), None)
            self.assert_tool_error(refused, ".comp")
            exchange.assert_not_called()

    def test_save_atomic_rollback_restores_complete_nonempty_project(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "existing.comp"
            old_manifest = manifest_bytes()
            make_package(destination, old_manifest, NATIVE_IMAGES)
            (destination / "valuable.txt").write_text("do not lose")
            actual_replace = os.replace
            calls = 0

            def fail_install(source, target):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("simulated install failure")
                return actual_replace(source, target)

            with patch.object(bridge, "exchange", return_value=native_project_result()), patch.object(bridge.os, "replace", side_effect=fail_install):
                result = bridge._local_call(request("save_document", {"path": str(destination), "overwrite": True}), None)
            self.assert_tool_error(result, "simulated install failure")
            self.assertEqual((destination / "manifest.json").read_bytes(), old_manifest)
            self.assertEqual((destination / "valuable.txt").read_text(), "do not lose")
            self.assertEqual((destination / "images" / IMAGE_NAME).read_bytes(), PNG)

    def test_save_failure_never_deletes_an_unexpected_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "existing.comp"
            old_manifest = manifest_bytes()
            make_package(destination, old_manifest, NATIVE_IMAGES)
            actual_replace = os.replace
            calls = 0

            def destination_reappears(source, target):
                nonlocal calls
                calls += 1
                if calls == 2:
                    destination.mkdir()
                    (destination / "concurrent.txt").write_text("preserve me")
                    raise OSError("simulated install failure")
                return actual_replace(source, target)

            with patch.object(bridge, "exchange", return_value=native_project_result()), patch.object(bridge.os, "replace", side_effect=destination_reappears):
                result = bridge._local_call(request("save_document", {"path": str(destination), "overwrite": True}), None)
            self.assert_tool_error(result, "previous project is preserved")
            self.assertEqual((destination / "concurrent.txt").read_text(), "preserve me")
            workspaces = list(root.glob(".existing.comp.*"))
            self.assertEqual(len(workspaces), 1)
            self.assertEqual((workspaces[0] / "backup.comp" / "manifest.json").read_bytes(), old_manifest)

    def test_save_detects_destination_swap_and_restores_unexpected_package(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "existing.comp"
            parked = root / "parked.comp"
            make_package(destination)
            actual_replace = os.replace
            swapped = False

            def swap_before_move(source, target):
                nonlocal swapped
                if not swapped and Path(source) == destination:
                    swapped = True
                    actual_replace(destination, parked)
                    make_package(destination)
                    (destination / "concurrent.txt").write_text("preserve me")
                return actual_replace(source, target)

            with patch.object(bridge, "exchange", return_value=native_project_result()), patch.object(bridge.os, "replace", side_effect=swap_before_move):
                result = bridge._local_call(request("save_document", {"path": str(destination), "overwrite": True}), None)
            self.assert_tool_error(result, "changed while saving")
            self.assertEqual((destination / "concurrent.txt").read_text(), "preserve me")
            self.assertTrue((parked / "manifest.json").is_file())

    def test_export_omits_null_document_id_and_writes_atomic_png_with_dimensions(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "render.png"
            with patch.object(bridge, "exchange", return_value=render_result()) as exchange:
                result = bridge._local_call(request("export_image", {"path": str(destination)}), None)
            self.assertEqual(exchange.call_args.args[0]["params"], {"name": "render_document", "arguments": {"max_dimension": 0}})
            self.assertEqual(destination.read_bytes(), PNG)
            self.assertEqual(result["result"]["structuredContent"]["width"], 10)
            self.assertEqual(result["result"]["structuredContent"]["height"], 20)

    def test_export_contract_errors_and_native_errors_never_replace_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "render.png"
            destination.write_bytes(b"old")
            bad = [
                {"result": {"content": [], "structuredContent": {"width": 1, "height": 1}, "isError": False}},
                render_result(width=0),
                render_result(data=b"not png"),
            ]
            for index, response in enumerate(bad):
                with self.subTest(index=index), patch.object(bridge, "exchange", return_value=response):
                    result = bridge._local_call(request("export_image", {"path": str(destination), "overwrite": True}), None)
                    self.assert_tool_error(result)
                    self.assertEqual(destination.read_bytes(), b"old")
            downstream = {"result": {"content": [{"type": "text", "text": "busy"}], "isError": True}}
            with patch.object(bridge, "exchange", return_value=downstream):
                self.assertIs(bridge._local_call(request("export_image", {"path": str(destination), "overwrite": True}), None), downstream)
                self.assertEqual(destination.read_bytes(), b"old")

    def test_export_atomic_failure_preserves_existing_file_and_removes_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "render.png"
            destination.write_bytes(b"old")
            with patch.object(bridge, "exchange", return_value=render_result()), patch.object(bridge.os, "replace", side_effect=OSError("replace failed")):
                result = bridge._local_call(request("export_image", {"path": str(destination), "overwrite": True}), None)
            self.assert_tool_error(result, "replace failed")
            self.assertEqual(destination.read_bytes(), b"old")
            self.assertEqual([entry.name for entry in root.iterdir()], ["render.png"])

    def test_export_no_overwrite_does_not_clobber_concurrently_created_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "render.png"
            actual_link = os.link

            def race(source, target, **kwargs):
                destination.write_bytes(b"concurrent")
                return actual_link(source, target, **kwargs)

            with patch.object(bridge, "exchange", return_value=render_result()), patch.object(bridge.os, "link", side_effect=race):
                result = bridge._local_call(request("export_image", {"path": str(destination)}), None)
            self.assert_tool_error(result)
            self.assertEqual(destination.read_bytes(), b"concurrent")
            self.assertEqual([entry.name for entry in root.iterdir()], ["render.png"])

    def test_endpoint_permissions_size_and_validation(self):
        directory, path = self.endpoint(0o644)
        with self.assertRaises(ValueError):
            bridge.discover(str(path))
        directory.cleanup()

    def test_endpoint_swap_after_permission_check_is_rejected(self):
        directory, path = self.endpoint()
        replacement = path.with_name("replacement.json")
        replacement.write_text(json.dumps({"port": 9999, "token": "y" * 32}))
        os.chmod(replacement, 0o644)
        actual_open = os.open
        swapped = False

        def swap_before_open(candidate, flags):
            nonlocal swapped
            if not swapped and Path(candidate) == path:
                swapped = True
                path.unlink()
                replacement.rename(path)
            return actual_open(candidate, flags)

        with patch.object(bridge.os, "open", side_effect=swap_before_open), self.assertRaises(ValueError):
            bridge.discover(str(path))
        directory.cleanup()
        directory, path = self.endpoint()
        self.assertEqual(bridge.discover(str(path))["port"], 4567)
        directory.cleanup()
        directory, path = self.endpoint(value={"port": True, "token": "x" * 32})
        with self.assertRaises(ValueError):
            bridge.discover(str(path))
        directory.cleanup()

    def test_exchange_sends_once_handles_split_record_and_rejects_bad_envelope(self):
        sent = []

        class Fake:
            chunks = [b'{"response":', b'{"jsonrpc":"2.0","id":1,"result":{"ok":true}}}\n']
            def __enter__(self): return self
            def __exit__(self, *_args): pass
            def settimeout(self, _timeout): pass
            def sendall(self, data): sent.append(data)
            def recv(self, _size): return self.chunks.pop(0)

        with patch.object(bridge, "discover", return_value={"port": 1, "token": "x" * 32}), patch.object(bridge.socket, "create_connection", return_value=Fake()):
            self.assertEqual(bridge.exchange({"id": 1}), {"jsonrpc": "2.0", "id": 1, "result": {"ok": True}})
        self.assertEqual(len(sent), 1)

        class Bad(Fake):
            chunks = [b'{"wrong":true}\n']

        with patch.object(bridge, "discover", return_value={"port": 1, "token": "x" * 32}), patch.object(bridge.socket, "create_connection", return_value=Bad()):
            with self.assertRaises(ValueError):
                bridge.exchange({"id": 1})

    def test_exchange_rejects_mismatched_ids_and_malformed_rpc_responses(self):
        class Fake:
            def __init__(self, response): self.response = response
            def __enter__(self): return self
            def __exit__(self, *_args): pass
            def settimeout(self, _timeout): pass
            def sendall(self, _data): pass
            def recv(self, _size):
                if self.response is None: return b""
                response, self.response = self.response, None
                return json.dumps({"response": response}).encode() + b"\n"

        bad = [
            {"jsonrpc": "2.0", "id": 2, "result": {}},
            {"jsonrpc": "2.0", "id": 1, "result": {}, "error": {"code": -1, "message": "both"}},
            {"jsonrpc": "2.0", "id": 1, "error": {"code": True, "message": "bad"}},
        ]
        for response in bad:
            with self.subTest(response=response), patch.object(bridge, "discover", return_value={"port": 1, "token": "x" * 32}), patch.object(bridge.socket, "create_connection", return_value=Fake(response)):
                with self.assertRaises(ValueError):
                    bridge.exchange({"jsonrpc": "2.0", "id": 1, "method": "ping"})

    def test_exchange_disconnect_and_wire_limits(self):
        class Dead:
            def __enter__(self): return self
            def __exit__(self, *_args): pass
            def settimeout(self, _timeout): pass
            def sendall(self, _data): pass
            def recv(self, _size): return b""

        with patch.object(bridge, "discover", return_value={"port": 1, "token": "x" * 32}), patch.object(bridge.socket, "create_connection", return_value=Dead()):
            with self.assertRaises(ConnectionError):
                bridge.exchange({"id": 1})
        with patch.object(bridge, "WIRE_LIMIT", 8), patch.object(bridge, "discover", return_value={"port": 1, "token": "x" * 32}), patch.object(bridge.socket, "create_connection") as connection:
            with self.assertRaises(ValueError):
                bridge.exchange({"long": "request"})
            connection.assert_not_called()

    def test_main_reports_parse_and_request_errors_but_silences_notifications(self):
        records = [
            b"not-json\n",
            b"[]\n",
            json.dumps(request("open_document", {"path": "/tmp/a.comp"}, ...)).encode() + b"\n",
            b"",
        ]
        with patch("sys.argv", ["compositor-mcp.py"]), patch("sys.stdin.buffer.readline", side_effect=records), patch("sys.stdout.write") as output, patch("sys.stdout.flush"), patch.object(bridge, "exchange") as exchange:
            bridge.main()
        self.assertEqual(output.call_count, 2)
        responses = [json.loads(call.args[0]) for call in output.call_args_list]
        self.assertEqual([response["error"]["code"] for response in responses], [-32700, -32600])
        exchange.assert_not_called()


if __name__ == "__main__":
    unittest.main()
