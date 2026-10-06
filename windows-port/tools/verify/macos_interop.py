r"""Checks that a package would be accepted by the macOS app.

Two independent rule sets are applied, both ported from the Swift sources rather than from the Rust
implementation:

* **Decoding** - what the synthesized \`Codable\` initializers require. Swift does *not* fall back to a
  property's default value when a key is missing, so a non-optional property that this project omits
  makes the whole manifest fail to decode.
* **Validation** - \`ProjectStore.validate\`: naming, version gates, ranges and limits.

Run:  python macos_interop.py <package> [<package> ...]
Exit code 1 when any package would be rejected.
"""

from __future__ import annotations

import json
import os
import re
import sys

MANIFEST_REQUIRED = ["format", "version", "colorSpace", "documentID", "width", "height", "layers"]
LAYER_REQUIRED = ["id", "name", "isVisible", "transform"]
TRANSFORM_REQUIRED = ["origin", "size", "rotation", "flipX", "flipY", "sampling"]
ADJUSTMENT_REQUIRED = ["kind", "hue", "saturation", "lightness", "colorize", "levels", "curves"]
LEVELS_REQUIRED = ["channel", "ranges"]
CURVES_REQUIRED = ["channel", "channels"]
LEVEL_RANGE_REQUIRED = ["black", "gamma", "white", "outputBlack", "outputWhite"]
STROKE_REQUIRED = ["size", "red", "green", "blue", "opacity", "inside"]
SHADOW_REQUIRED = ["angle", "distance", "blur", "red", "green", "blue", "opacity"]
OVERLAY_REQUIRED = ["red", "green", "blue", "opacity"]
GLOW_REQUIRED = ["size", "red", "green", "blue", "opacity"]
TEXT_REQUIRED = ["content", "fontName", "fontSize", "red", "green", "blue", "alignment", "tracking", "leading"]
SHAPE_REQUIRED = ["kind", "red", "green", "blue", "cornerRadius"]

BLEND_MODES = {
    "Normal", "Darken", "Multiply", "Color Burn", "Linear Burn", "Lighten", "Screen",
    "Color Dodge", "Linear Dodge (Add)", "Overlay", "Soft Light", "Hard Light", "Vivid Light",
    "Linear Light", "Pin Light", "Hard Mix", "Difference", "Exclusion", "Subtract", "Divide",
    "Hue", "Saturation", "Color", "Luminosity",
}
SAMPLING = {"High quality", "Smooth", "Nearest"}
ADJUSTMENT_KINDS = {
    "Hue/Saturation", "Levels", "Curves", "Exposure", "Gradient Map", "Grain", "Invert",
    "Black & White", "Color Balance", "Gaussian Blur", "Motion Blur", "Add Noise",
}
NEIGHBOR_KINDS = {"Gaussian Blur", "Motion Blur", "Add Noise"}
MAX_SIDE = 30_000

# Swift decodes these with UUID(uuidString:), which accepts either case, and compares asset names
# against uuidString, which always renders uppercase. A lowercase identifier is therefore legal as long
# as the file name matches its uppercase form -- the same rule comp-core applies.
UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")


def missing(record, keys, where, problems):
    for key in keys:
        if key not in record:
            problems.append(f"{where}: missing required key {key!r} (Swift Codable fails the whole decode)")


def check_keys_are_camel_case(value, where, problems):
    if isinstance(value, dict):
        for key, item in value.items():
            if "_" in key:
                problems.append(f"{where}: key {key!r} uses snake_case; macOS spells these in camelCase")
            check_keys_are_camel_case(item, f"{where}.{key}", problems)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            check_keys_are_camel_case(item, f"{where}[{index}]", problems)


def check_uuid(value, where, problems):
    if not isinstance(value, str) or not UUID_RE.match(value):
        problems.append(f"{where}: {value!r} is not a UUID; Swift decodes this with UUID(uuidString:)")


def validate_package(package):
    problems = []
    manifest_path = os.path.join(package, "manifest.json")
    if not os.path.isfile(manifest_path):
        return ["no manifest.json"]
    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)

    missing(manifest, MANIFEST_REQUIRED, "manifest", problems)
    check_keys_are_camel_case(manifest, "manifest", problems)
    version = manifest.get("version", 0)
    if not isinstance(version, int) or not 1 <= version <= 11:
        problems.append(f"manifest.version {version!r} is outside 1...11")
    if manifest.get("format") != "com.compositor.project":
        problems.append(f"manifest.format {manifest.get('format')!r} is not com.compositor.project")
    if manifest.get("colorSpace") != "sRGB":
        problems.append(f"manifest.colorSpace {manifest.get('colorSpace')!r} is not sRGB")
    if not isinstance(manifest.get("width"), int) or not 1 <= manifest["width"] <= MAX_SIDE:
        problems.append("manifest.width is out of range")
    if not isinstance(manifest.get("height"), int) or not 1 <= manifest["height"] <= MAX_SIDE:
        problems.append("manifest.height is out of range")
    resolution = manifest.get("resolution")
    if resolution is not None and not (isinstance(resolution, (int, float)) and 1 <= resolution <= 9600):
        problems.append(f"manifest.resolution {resolution!r} is outside 1...9600")
    check_uuid(manifest.get("documentID"), "manifest.documentID", problems)

    layers = manifest.get("layers")
    if not isinstance(layers, list):
        return problems + ["manifest.layers is not an array"]
    if len(layers) > 10_000:
        problems.append("more than 10,000 layers")

    ids = set()
    for index, layer in enumerate(layers):
        where = f"layers[{index}]"
        if not isinstance(layer, dict):
            problems.append(f"{where}: not an object")
            continue
        missing(layer, LAYER_REQUIRED, where, problems)
        check_uuid(layer.get("id"), f"{where}.id", problems)
        layer_id = layer.get("id")
        if layer_id in ids:
            problems.append(f"{where}: duplicate id {layer_id}")
        ids.add(layer_id)
        name = layer.get("name")
        if not isinstance(name, str) or not name.strip() or len(name.encode()) > 16_384:
            problems.append(f"{where}.name is empty or too long")

        transform = layer.get("transform")
        if isinstance(transform, dict):
            missing(transform, TRANSFORM_REQUIRED, f"{where}.transform", problems)
            if transform.get("sampling") not in SAMPLING:
                problems.append(f"{where}.transform.sampling {transform.get('sampling')!r} is not a known value")
            size = transform.get("size")
            if not (isinstance(size, list) and len(size) == 2 and all(isinstance(v, (int, float)) for v in size)
                    and size[0] > 0 and size[1] > 0):
                problems.append(f"{where}.transform.size must be two positive numbers")
            origin = transform.get("origin")
            if not (isinstance(origin, list) and len(origin) == 2
                    and all(isinstance(v, (int, float)) for v in origin)):
                problems.append(f"{where}.transform.origin must be two numbers")
        elif transform is not None:
            problems.append(f"{where}.transform is not an object")

        is_group = layer.get("isGroup") is True
        image_file = layer.get("imageFile")
        if image_file is not None and image_file != f"{str(layer_id).upper()}.png":
            problems.append(f"{where}.imageFile {image_file!r} is not '<id.uuidString>.png'")
        if is_group and image_file is not None:
            problems.append(f"{where}: a folder cannot carry pixels")
        if layer.get("blendMode") is not None and layer["blendMode"] not in BLEND_MODES:
            problems.append(f"{where}.blendMode {layer['blendMode']!r} is not one of the 24 names")
        opacity = layer.get("opacity", 1.0)
        if not (isinstance(opacity, (int, float)) and 0.0 <= opacity <= 1.0):
            problems.append(f"{where}.opacity {opacity!r} is outside 0...1")
        if version < 3 and (opacity != 1.0 or layer.get("blendMode", "Normal") != "Normal"):
            problems.append(f"{where}: version {version} cannot carry opacity or a blend mode")
        if is_group:
            if layer.get("blendMode") not in (None, "Normal"):
                problems.append(f"{where}: a folder's blend mode must stay Normal")
            if version < 8 and opacity != 1.0:
                problems.append(f"{where}: version {version} cannot give a folder an opacity")

        mask_file = layer.get("maskFile")
        if mask_file is not None:
            minimum = 6 if is_group else 4
            if version < minimum:
                problems.append(f"{where}: version {version} cannot carry this mask (needs {minimum})")
            if mask_file != f"{str(layer_id).upper()}.mask.png":
                problems.append(f"{where}.maskFile {mask_file!r} is not '<id.uuidString>.mask.png'")
        if layer.get("maskEnabled") is not None and mask_file is None:
            problems.append(f"{where}.maskEnabled without maskFile")

        source = layer.get("maskSourceID")
        if source is not None:
            if version < 5:
                problems.append(f"{where}: version {version} cannot carry a clipping link")
            check_uuid(source, f"{where}.maskSourceID", problems)
            if source == layer_id:
                problems.append(f"{where}: a layer cannot clip to itself")
            node = next((item for item in layers if item.get("id") == source), None)
            if node is None:
                problems.append(f"{where}.maskSourceID points at a missing layer")
            elif node.get("isGroup") is True:
                problems.append(f"{where}.maskSourceID points at a folder")

        adjustment = layer.get("adjustment")
        if adjustment is not None:
            if version < 7:
                problems.append(f"{where}: version {version} cannot carry an adjustment layer")
            if is_group or image_file is not None:
                problems.append(f"{where}: an adjustment layer cannot be a folder or carry pixels")
            if isinstance(adjustment, dict):
                missing(adjustment, ADJUSTMENT_REQUIRED, f"{where}.adjustment", problems)
                if adjustment.get("kind") not in ADJUSTMENT_KINDS:
                    problems.append(f"{where}.adjustment.kind {adjustment.get('kind')!r} is unknown")
                if adjustment.get("kind") in NEIGHBOR_KINDS and version < 9:
                    problems.append(f"{where}: {adjustment.get('kind')} needs version 9")
                levels = adjustment.get("levels")
                if isinstance(levels, dict):
                    missing(levels, LEVELS_REQUIRED, f"{where}.adjustment.levels", problems)
                    for r_index, entry in enumerate(levels.get("ranges", [])):
                        if isinstance(entry, dict):
                            missing(entry, LEVEL_RANGE_REQUIRED,
                                    f"{where}.adjustment.levels.ranges[{r_index}]", problems)
                curves = adjustment.get("curves")
                if isinstance(curves, dict):
                    missing(curves, CURVES_REQUIRED, f"{where}.adjustment.curves", problems)
                # Swift encodes a dictionary whose key is a RawRepresentable enum (ColorRange) as an
                # unkeyed array of alternating keys and values, so `adjustments` must be an array.
                hsv = adjustment.get("hsvSettings")
                if isinstance(hsv, dict):
                    adjustments = hsv.get("adjustments")
                    if adjustments is not None and not isinstance(adjustments, list):
                        problems.append(
                            f"{where}.adjustment.hsvSettings.adjustments must be an array of alternating "
                            "range names and records; Swift's [ColorRange: X] encodes that way and would "
                            "not decode a keyed object"
                        )
                seed = adjustment.get("noiseSeed")
                if seed is not None and not (isinstance(seed, int) and 0 <= seed <= 4_294_967_295):
                    problems.append(f"{where}.adjustment.noiseSeed {seed!r} does not fit Swift's UInt32")

        effects = layer.get("effects")
        if isinstance(effects, dict):
            for key, required in (("stroke", STROKE_REQUIRED), ("shadow", SHADOW_REQUIRED),
                                  ("colorOverlay", OVERLAY_REQUIRED), ("innerShadow", SHADOW_REQUIRED),
                                  ("outerGlow", GLOW_REQUIRED), ("innerGlow", GLOW_REQUIRED)):
                if isinstance(effects.get(key), dict):
                    missing(effects[key], required, f"{where}.effects.{key}", problems)
                    if "enabled" in effects[key] and not isinstance(effects[key]["enabled"], bool):
                        problems.append(f"{where}.effects.{key}.enabled is not a flag")

        text = layer.get("text")
        if isinstance(text, dict):
            missing(text, TEXT_REQUIRED, f"{where}.text", problems)
            if text.get("alignment") not in {"Left", "Center", "Right"}:
                problems.append(f"{where}.text.alignment {text.get('alignment')!r} is unknown")
            if text.get("colorRuns") is not None and version < 10:
                problems.append(f"{where}: colorRuns needs version 10")
            if text.get("fontRuns") is not None and version < 11:
                problems.append(f"{where}: fontRuns needs version 11")
            for run in text.get("fontRuns") or []:
                if "fontName" not in run:
                    problems.append(f"{where}.text.fontRuns entries need fontName")
            for run in text.get("colorRuns") or []:
                for key in ("location", "length", "red", "green", "blue"):
                    if key not in run:
                        problems.append(f"{where}.text.colorRuns entries need {key}")
            if image_file is None or is_group or adjustment is not None:
                problems.append(f"{where}: text metadata needs a plain pixel layer")

        shape = layer.get("shape")
        if isinstance(shape, dict):
            missing(shape, SHAPE_REQUIRED, f"{where}.shape", problems)

        if layer.get("parentID") is not None:
            if version == 1:
                problems.append(f"{where}: version 1 cannot nest layers")
            parent = next((item for item in layers if item.get("id") == layer["parentID"]), None)
            if parent is None:
                problems.append(f"{where}.parentID points at a missing layer")
            elif parent.get("isGroup") is not True:
                problems.append(f"{where}.parentID points at a layer that is not a folder")

    guides = manifest.get("guides") or []
    if guides and version < 8:
        problems.append(f"version {version} cannot carry guides")
    if len(guides) > 1_000:
        problems.append("more than 1,000 guides")
    for index, guide in enumerate(guides):
        where = f"guides[{index}]"
        missing(guide, ["id", "axis", "position"], where, problems)
        check_uuid(guide.get("id"), f"{where}.id", problems)
        if guide.get("axis") not in {"horizontal", "vertical"}:
            problems.append(f"{where}.axis {guide.get('axis')!r} is unknown")

    active = manifest.get("activeLayerID")
    if active is not None and active not in ids:
        problems.append("manifest.activeLayerID does not name a layer")

    # Every asset the manifest names must exist, be a PNG, and be a regular file.
    for index, layer in enumerate(layers):
        for key in ("imageFile", "maskFile"):
            name = layer.get(key)
            if not name:
                continue
            path = os.path.join(package, "images", name)
            if not os.path.isfile(path) or os.path.islink(path):
                problems.append(f"layers[{index}].{key}: {name} is missing, a link, or not a file")
    return problems


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    failed = 0
    for package in argv[1:]:
        problems = validate_package(package)
        name = os.path.basename(package.rstrip("/\\"))
        if problems:
            failed += 1
            print(f"REJECT {name}")
            for problem in problems[:12]:
                print(f"       {problem}")
        else:
            print(f"ACCEPT {name}")
    print(f"\n{len(argv) - 1 - failed}/{len(argv) - 1} packages would load in the macOS app")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
