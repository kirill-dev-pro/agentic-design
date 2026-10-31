#!/usr/bin/env python3
"""Writes static instances of installed variable fonts for Agentic Design.

The app renders fonts with stb_truetype, which only draws a variable font's default
instance: every weight of Fraunces looks Regular. This tool takes each variable font in
the user's font folders and writes one static font per named instance of its `fvar`
table into the app's own font folder, which the app scans first.

    python3 -m venv /tmp/ft && /tmp/ft/bin/pip install fonttools
    /tmp/ft/bin/python tools/font_instances.py [font.ttf ...]

Without arguments it looks at ~/Library/Fonts and /Library/Fonts.
"""
import glob
import os
import sys

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

OUT = os.path.expanduser("~/Library/Application Support/Agentic Design/fonts")


def name(font, ids):
    for i in ids:
        n = font["name"].getDebugName(i)
        if n:
            return n
    return None


def main():
    paths = sys.argv[1:] or [p for d in ("~/Library/Fonts", "/Library/Fonts")
                             for p in glob.glob(os.path.join(os.path.expanduser(d), "*.[ot]tf"))]
    os.makedirs(OUT, exist_ok=True)
    for path in paths:
        try:
            font = TTFont(path, lazy=True)
        except Exception:
            continue
        if "fvar" not in font:
            continue
        family = name(font, (16, 1)) or os.path.basename(path)
        axes = {a.axisTag: a.defaultValue for a in font["fvar"].axes}
        for inst in font["fvar"].instances:
            style = font["name"].getDebugName(inst.subfamilyNameID) or "Instance"
            # only the weight (and width/italic) vary between instances; optical size
            # and other axes stay at their defaults, like a browser at normal size
            coords = dict(axes)
            for tag in ("wght", "wdth", "ital", "slnt"):
                if tag in inst.coordinates:
                    coords[tag] = inst.coordinates[tag]
            out = os.path.join(OUT, f"{family.replace(' ', '')}-{style.replace(' ', '')}.ttf")
            if os.path.exists(out):
                continue
            full = TTFont(path)
            try:
                static = instancer.instantiateVariableFont(full, coords, updateFontNames=True)
            except Exception:
                static = instancer.instantiateVariableFont(full, coords)
            # family name the app matches on: the variable font's own family
            for rec in static["name"].names:
                if rec.nameID in (1, 16):
                    rec.string = family
                if rec.nameID in (2, 17):
                    rec.string = style
            static["OS/2"].usWeightClass = int(round(coords.get("wght", static["OS/2"].usWeightClass)))
            static.save(out)
            print(out)


if __name__ == "__main__":
    main()
