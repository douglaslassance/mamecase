#!/usr/bin/env python3
"""Give the compiled app icon a real dark appearance.

`ictool --export-intermediate-representation` turns AppIcon.icon into an
asset catalog whose properties are keyed per appearance (light / dark /
tinted), and `actool` compiles that into Assets.car. The keys exist, but
the document format has no working way to set them: every
`*-specializations` array in icon.json is parsed and then dropped, so the
dark appearance always inherits the light glyph colour. That is what made
the icon black-on-black. macOS swaps in the system dark background and
leaves the dark ink alone.

So we patch the catalog between the two tools: point the layer's dark fill
at a light colour. Light appearance keeps the light squircle and dark ink,
dark appearance gets the system dark slate and a light picto.

Usage: patch_icon_ir.py <exported-ir-directory>
"""

import json
import os
import sys

# Picto colour for the dark appearance, off-white and deliberately not pure.
DARK_APPEARANCE_GLYPH = {
    "color-space": "srgb",
    "components": {"alpha": "1.000", "red": "0.960", "green": "0.960", "blue": "0.970"},
}
COLORSET_NAME = "Color-DarkAppearance"


def main(ir_dir):
    catalogs = [
        os.path.join(ir_dir, entry)
        for entry in os.listdir(ir_dir)
        if entry.endswith(".xcassets")
    ]
    if not catalogs:
        sys.exit(f"no .xcassets found in {ir_dir}")
    catalog = catalogs[0]

    assets = os.path.join(catalog, "AppIcon_Assets")
    colorset = os.path.join(assets, f"{COLORSET_NAME}.colorset")
    os.makedirs(colorset, exist_ok=True)
    with open(os.path.join(colorset, "Contents.json"), "w") as fh:
        json.dump(
            {
                "colors": [{"color": DARK_APPEARANCE_GLYPH, "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
            },
            fh,
            indent=2,
        )

    patched = 0
    for root, _dirs, files in os.walk(catalog):
        if not root.endswith(".iconstacklayer") or "Contents.json" not in files:
            continue
        path = os.path.join(root, "Contents.json")
        with open(path) as fh:
            layer = json.load(fh)
        for entry in layer.get("properties", {}).get("fill", []):
            if entry.get("icon-studio-appearance") != "dark":
                continue
            entry["value"] = {
                "color": {
                    "matching-style": "fully-qualified-name",
                    "name": f"AppIcon_Assets/{COLORSET_NAME}",
                    "type": "color-set",
                },
                "type": "solid",
            }
            patched += 1
        with open(path, "w") as fh:
            json.dump(layer, fh, indent=2)

    if not patched:
        sys.exit("no dark fill entries found, did the IR format change?")
    print(f"patched {patched} dark fill entr{'y' if patched == 1 else 'ies'}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
