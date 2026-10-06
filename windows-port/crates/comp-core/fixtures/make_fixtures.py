"""Builds the golden .comp packages the format tests read back byte for byte.

Every package is written the way docs/writing-comp-files.md describes: the PNGs first, then the
manifest, with the ids, names and file names the macOS app spells them. One layer image is stored
as a palette PNG with transparency, so the Rust decoder's expansion is checked against a file
Python wrote rather than against this crate's own encoder.

The expected pixels are dumped next to each package as raw RGBA or grayscale bytes, read back from
the PNG Pillow just wrote: a test that compares the two is comparing two independent PNG decoders.

Run from this directory:  python make_fixtures.py
"""
from __future__ import annotations

import json
import os
import uuid

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
EXPECTED = os.path.join(HERE, "expected")

SAMPLING = "High quality"


def make_id(group: int, index: int) -> str:
    """A stable uppercase id, so regenerating the fixtures never rewrites them."""
    return str(uuid.UUID(int=(0xC0FFEE00 << 32) | (group << 16) | index)).upper()


def transform(origin, size, rotation=0.0, flip_x=False, flip_y=False, sampling=SAMPLING):
    return {
        "origin": [origin[0], origin[1]],
        "size": [size[0], size[1]],
        "rotation": rotation,
        "flipX": flip_x,
        "flipY": flip_y,
        "sampling": sampling,
    }


def raster(layer_id, name, origin, size, **extra):
    record = {
        "id": layer_id,
        "name": name,
        "isVisible": True,
        "isGroup": False,
        "opacity": 1,
        "blendMode": "Normal",
        "imageFile": layer_id + ".png",
        "transform": transform(origin, size),
    }
    record.update(extra)
    return record


def kind_name(record):
    if record.get("isGroup"):
        return "group"
    if record.get("adjustment"):
        return "adjustment"
    return "raster"


class Fixture:
    """One package under construction, with the expectations its test will check."""

    def __init__(self, name, width, height, version=11, resolution=72):
        self.name = name
        self.width = width
        self.height = height
        self.version = version
        self.resolution = resolution
        self.layers = []
        self.assets = {}
        self.expected = []
        self.guides = None

    def add(self, record):
        self.layers.append(record)
        return record

    def write_rgba(self, owner_id, name, image):
        """Stores an RGBA layer image and remembers the pixels the decoder must produce."""
        path = os.path.join(self.directory(), name)
        image.save(path, "PNG")
        with Image.open(path) as check:
            expected = check.convert("RGBA").tobytes()
        self.remember(owner_id, "image", name, expected, image.width, image.height)

    def write_palette(self, owner_id, name, size, palette, indices, alpha):
        """Stores a layer image as a palette PNG with a transparency table."""
        path = os.path.join(self.directory(), name)
        image = Image.new("P", size)
        image.putpalette(palette)
        image.putdata(list(indices))
        image.info["transparency"] = bytes(alpha)
        image.save(path, "PNG")
        with Image.open(path) as check:
            expected = check.convert("RGBA").tobytes()
        self.remember(owner_id, "image", name, expected, size[0], size[1])

    def write_gray(self, owner_id, name, mask):
        path = os.path.join(self.directory(), name)
        mask.save(path, "PNG")
        with Image.open(path) as check:
            expected = check.convert("L").tobytes()
        self.remember(owner_id, "mask", name, expected, mask.width, mask.height)

    def remember(self, owner_id, kind, name, expected, width, height):
        self.assets[name] = None
        self.expected.append(
            {
                "id": owner_id,
                "kind": kind,
                "file": os.path.join(self.name, name.rsplit(".", 1)[0] + (".rgba" if kind == "image" else ".gray")),
                "width": width,
                "height": height,
                "bytes": expected,
            }
        )

    def directory(self):
        path = os.path.join(HERE, self.name, "images")
        os.makedirs(path, exist_ok=True)
        return path

    def write(self):
        package = os.path.join(HERE, self.name)
        images = os.path.join(package, "images")
        os.makedirs(images, exist_ok=True)
        manifest = {
            "format": "com.compositor.project",
            "version": self.version,
            "colorSpace": "sRGB",
            "resolution": self.resolution,
            "documentID": make_id(9, 1),
            "width": self.width,
            "height": self.height,
            "activeLayerID": self.layers[0]["id"] if self.layers else None,
            "layers": self.layers,
        }
        if self.guides:
            manifest["guides"] = self.guides
        with open(os.path.join(package, "manifest.json"), "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2, sort_keys=True)
            handle.write("\n")
        self.write_expectations()

    def write_expectations(self):
        root = os.path.join(EXPECTED, self.name)
        os.makedirs(root, exist_ok=True)
        assets = []
        for entry in self.expected:
            stem = os.path.basename(entry["file"])
            with open(os.path.join(root, stem), "wb") as handle:
                handle.write(entry["bytes"])
            assets.append({key: entry[key] for key in ("id", "kind", "file", "width", "height")})
        index = {
            "package": self.name,
            "version": self.version,
            "width": self.width,
            "height": self.height,
            "resolution": self.resolution,
            "layerCount": len(self.layers),
            "layers": [
                {
                    "id": record["id"],
                    "name": record["name"],
                    "kind": kind_name(record),
                    "parentID": record.get("parentID"),
                    "opacity": record.get("opacity", 1),
                    "blendMode": record.get("blendMode", "Normal"),
                    "hasImage": "imageFile" in record,
                    "hasMask": "maskFile" in record,
                    "maskEnabled": record.get("maskEnabled"),
                    "maskLinked": record.get("maskLinked"),
                    "adjustmentKind": (record.get("adjustment") or {}).get("kind"),
                    "colorRuns": len(((record.get("text") or {}).get("colorRuns")) or []),
                    "fontRuns": len(((record.get("text") or {}).get("fontRuns")) or []),
                    "shapeKind": (record.get("shape") or {}).get("kind"),
                }
                for record in self.layers
            ],
            "assets": assets,
        }
        with open(os.path.join(EXPECTED, self.name + ".json"), "w", encoding="utf-8") as handle:
            json.dump(index, handle, indent=2, sort_keys=True)
            handle.write("\n")
        print("wrote", self.name, "with", len(assets), "assets")

def vertical_gradient(width, height, top, bottom):
    """A top-to-bottom RGBA ramp, including the alpha channel."""
    span = max(1, height - 1)
    rows = []
    for y in range(height):
        mix = y / span
        pixel = tuple(int(top[channel] + (bottom[channel] - top[channel]) * mix) for channel in range(4))
        rows.extend([pixel] * width)
    image = Image.new("RGBA", (width, height))
    image.putdata(rows)
    return image


def checker(width, height, size, first, second):
    image = Image.new("RGBA", (width, height))
    image.putdata([
        first if ((x // size) + (y // size)) % 2 == 0 else second
        for y in range(height)
        for x in range(width)
    ])
    return image


def gray_gradient(width, height, start, end):
    span = max(1, height - 1)
    mask = Image.new("L", (width, height))
    mask.putdata([int(start + (end - start) * (y / span)) for y in range(height) for _ in range(width)])
    return mask


def radial_mask(width, height, inner=40, outer=250):
    center_x, center_y = (width - 1) / 2.0, (height - 1) / 2.0
    longest = max(1.0, (center_x ** 2 + center_y ** 2) ** 0.5)
    mask = Image.new("L", (width, height))
    mask.putdata([
        int(outer - (outer - inner) * (((x - center_x) ** 2 + (y - center_y) ** 2) ** 0.5) / longest)
        for y in range(height)
        for x in range(width)
    ])
    return mask


def identity_levels():
    return {"channel": "RGB", "ranges": [{"black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255}] * 4}


def layers_fixture():
    """RGBA layers, a palette layer with transparency, grayscale masks and a 1x1 mask."""
    width, height = 64, 48
    fixture = Fixture("golden_layers.comp", width, height, resolution=144)
    gradient, cutout, masked, tiny = (make_id(1, index) for index in range(1, 5))

    fixture.add(raster(gradient, "Gradient", (0, 0), (width, height)))
    fixture.write_rgba(gradient, gradient + ".png", vertical_gradient(width, height, (20, 40, 200, 255), (240, 200, 30, 128)))

    fixture.add(raster(cutout, "Cutout", (30, 8), (24, 16), opacity=0.75, blendMode="Multiply"))
    fixture.write_rgba(cutout, cutout + ".png", checker(24, 16, 4, (255, 255, 255, 255), (0, 0, 0, 0)))

    fixture.add(raster(masked, "Masked", (0, 0), (width, height), maskFile=masked + ".mask.png", maskEnabled=True))
    palette = [0] * 768
    for index in range(4):
        palette[index * 3:index * 3 + 3] = [index * 60, 255 - index * 50, index * 30]
    fixture.write_palette(
        masked,
        masked + ".png",
        (width, height),
        palette,
        [(x + y) % 4 for y in range(height) for x in range(width)],
        [0, 64, 128, 255],
    )
    fixture.write_gray(masked, masked + ".mask.png", radial_mask(width, height))

    fixture.add(raster(tiny, "Tiny Mask", (2, 2), (16, 16), maskFile=tiny + ".mask.png", maskEnabled=True))
    fixture.write_rgba(tiny, tiny + ".png", checker(16, 16, 2, (10, 200, 10, 255), (200, 10, 10, 255)))
    fixture.write_gray(tiny, tiny + ".mask.png", Image.new("L", (1, 1), 90))
    fixture.write()


def group_fixture():
    """A folder with its own opacity and mask, a clipping mask, effects, text runs and guides."""
    width, height = 48, 48
    fixture = Fixture("golden_group.comp", width, height, resolution=72)
    folder, base, clipped, caption, arrow = (make_id(2, index) for index in range(1, 6))

    fixture.add({
        "id": folder,
        "name": "Folder",
        "isVisible": True,
        "isGroup": True,
        "opacity": 0.6,
        "blendMode": "Normal",
        "maskFile": folder + ".mask.png",
        "maskEnabled": True,
        "transform": transform((0, 0), (width, height)),
    })
    fixture.write_gray(folder, folder + ".mask.png", gray_gradient(width, height, 255, 96))

    fixture.add(raster(
        base,
        "Base",
        (0, 0),
        (width, height),
        parentID=folder,
        effects={
            "stroke": {"size": 3, "red": 1, "green": 1, "blue": 1, "opacity": 0.8, "inside": True},
            "outerGlow": {"size": 12, "red": 1, "green": 0.5, "blue": 0, "opacity": 0.7},
            "colorOverlay": {"enabled": False, "red": 0.2, "green": 0.4, "blue": 0.6, "opacity": 0.9},
            "innerShadow": {"angle": 45, "distance": 2, "blur": 3, "red": 0, "green": 0, "blue": 0, "opacity": 0.35},
        },
    ))
    fixture.write_rgba(base, base + ".png", vertical_gradient(width, height, (250, 240, 230, 255), (30, 40, 90, 255)))

    fixture.add(raster(clipped, "Clipped", (0, 0), (width, height), parentID=folder, maskSourceID=base))
    fixture.write_rgba(clipped, clipped + ".png", checker(width, height, 6, (255, 120, 0, 255), (0, 200, 255, 200)))

    fixture.add(raster(
        caption,
        "Caption",
        (4, 4),
        (40, 20),
        parentID=folder,
        text={
            "content": "Golden",
            "fontName": "Helvetica",
            "fontSize": 16,
            "red": 1,
            "green": 1,
            "blue": 1,
            "alignment": "Center",
            "tracking": 0.5,
            "leading": 19,
            "boxSize": {"width": 40, "height": 20},
            "colorRuns": [{"location": 0, "length": 3, "red": 1, "green": 0.8, "blue": 0.2}],
            "fontRuns": [{"location": 3, "length": 3, "fontName": "Georgia-Bold"}],
        },
    ))
    fixture.write_rgba(caption, caption + ".png", Image.new("RGBA", (40, 20), (0, 0, 0, 0)))

    fixture.add(raster(
        arrow,
        "Arrow",
        (6, 30),
        (36, 12),
        shape={
            "kind": "Line",
            "red": 1,
            "green": 0.2,
            "blue": 0.2,
            "cornerRadius": 0,
            "lineWidth": 3,
            "start": [0, 0],
            "end": [1, 1],
        },
    ))
    fixture.write_rgba(arrow, arrow + ".png", checker(36, 12, 3, (0, 0, 0, 0), (255, 60, 60, 255)))

    fixture.guides = [
        {"id": make_id(2, 8), "axis": "horizontal", "position": 12.0},
        {"id": make_id(2, 9), "axis": "vertical", "position": 30.5},
    ]
    fixture.write()


def adjustment_fixture():
    """Adjustment layers, an unlinked mask, and a layer stack with its own resolution."""
    width, height = 32, 32
    fixture = Fixture("golden_adjustment.comp", width, height, resolution=72)
    base, curves, blur, balance, loose = (make_id(3, index) for index in range(1, 6))

    fixture.add(raster(base, "Base", (0, 0), (width, height)))
    fixture.write_rgba(base, base + ".png", vertical_gradient(width, height, (200, 120, 40, 255), (40, 90, 160, 255)))

    fixture.add({
        "id": curves,
        "name": "Warm Grade",
        "isVisible": True,
        "isGroup": False,
        "opacity": 1,
        "blendMode": "Normal",
        "transform": transform((0, 0), (width, height)),
        "adjustment": {
            "kind": "Curves",
            "hue": 0,
            "saturation": 0,
            "lightness": 0,
            "colorize": False,
            "levels": identity_levels(),
            "curves": {
                "channel": "Red",
                "channels": [
                    [{"x": 0, "y": 0}, {"x": 128, "y": 140}, {"x": 255, "y": 255}],
                    [{"x": 0, "y": 0}, {"x": 120, "y": 147}, {"x": 255, "y": 255}],
                    [{"x": 0, "y": 10}, {"x": 255, "y": 245}],
                    [{"x": 0, "y": 8}, {"x": 255, "y": 238}],
                ],
            },
        },
    })

    fixture.add({
        "id": blur,
        "name": "Soft Focus",
        "isVisible": True,
        "isGroup": False,
        "opacity": 0.8,
        "blendMode": "Screen",
        "transform": transform((0, 0), (width, height)),
        "adjustment": {"kind": "Gaussian Blur", "blurRadius": 6.5, "levels": identity_levels()},
    })

    fixture.add({
        "id": balance,
        "name": "Balance",
        "isVisible": True,
        "isGroup": False,
        "opacity": 1,
        "blendMode": "Normal",
        "transform": transform((0, 0), (width, height)),
        "adjustment": {
            "kind": "Color Balance",
            "colorBalanceSettings": {
                "shadowCyanRed": 5,
                "shadowMagentaGreen": -3,
                "shadowYellowBlue": 2,
                "midCyanRed": 12,
                "midMagentaGreen": 0,
                "midYellowBlue": -8,
                "highlightCyanRed": -4,
                "highlightMagentaGreen": 6,
                "highlightYellowBlue": 10,
                "preserveLuminosity": True,
            },
        },
    })

    fixture.add(raster(
        loose,
        "Loose Mask",
        (8, 8),
        (16, 16),
        maskFile=loose + ".mask.png",
        maskEnabled=True,
        maskLinked=False,
        maskPlacement=transform((10.5, 4.25), (16, 16), rotation=15.0),
    ))
    fixture.write_rgba(loose, loose + ".png", checker(16, 16, 4, (0, 255, 255, 255), (255, 0, 255, 255)))
    fixture.write_gray(loose, loose + ".mask.png", gray_gradient(16, 16, 0, 255))
    fixture.write()


def main():
    layers_fixture()
    group_fixture()
    adjustment_fixture()
    print("fixtures are in", HERE)


if __name__ == "__main__":
    main()

