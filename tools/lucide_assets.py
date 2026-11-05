#!/usr/bin/env python3
"""Builds assets/lucide.txt from lucide-static's icon-nodes.json.

    npm pack lucide-static && tar -xzf lucide-static-*.tgz
    python3 -I tools/lucide_assets.py package/icon-nodes.json package/LICENSE package/icons

The icons folder also holds Lucide's aliases (older names such as trash-2 and history,
D105); those not in icon-nodes.json are read from their SVG files.

Every icon becomes one line, "name<TAB>svg path data": circles, rects, lines and
polylines are turned into path data so the app only needs its SVG path parser.
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET


def num(v):
    f = float(v)
    return str(int(f)) if f == int(f) else repr(f)


NUMBER = re.compile(r"[\s,]*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)")


def absolute_start(d):
    """A path's leading "m" is absolute; once paths are joined it would not be."""
    d = d.strip()
    if not d.startswith("m"):
        return d
    x = NUMBER.match(d, 1)
    y = NUMBER.match(d, x.end())
    rest = d[y.end():].lstrip(" ,")
    if rest and (rest[0].isdigit() or rest[0] in "-+."):
        rest = "l" + rest  # implicit pairs after "m" are relative line-tos
    return f"M{x.group(1)} {y.group(1)}{rest}"


def to_path(tag, a):
    if tag == "path":
        return absolute_start(a["d"])
    if tag in ("circle", "ellipse"):
        cx, cy = float(a.get("cx", 0)), float(a.get("cy", 0))
        rx = float(a.get("r", a.get("rx", 0)))
        ry = float(a.get("r", a.get("ry", 0)))
        return (f"M{num(cx - rx)} {num(cy)}a{num(rx)} {num(ry)} 0 1 0 {num(2 * rx)} 0"
                f"a{num(rx)} {num(ry)} 0 1 0 {num(-2 * rx)} 0z")
    if tag == "rect":
        x, y = float(a.get("x", 0)), float(a.get("y", 0))
        w, h = float(a["width"]), float(a["height"])
        rx = float(a.get("rx", a.get("ry", 0)))
        ry = float(a.get("ry", rx))
        rx, ry = min(rx, w / 2), min(ry, h / 2)
        if rx == 0:
            return f"M{num(x)} {num(y)}h{num(w)}v{num(h)}h{num(-w)}z"
        return (f"M{num(x + rx)} {num(y)}h{num(w - 2 * rx)}a{num(rx)} {num(ry)} 0 0 1 {num(rx)} {num(ry)}"
                f"v{num(h - 2 * ry)}a{num(rx)} {num(ry)} 0 0 1 {num(-rx)} {num(ry)}h{num(-(w - 2 * rx))}"
                f"a{num(rx)} {num(ry)} 0 0 1 {num(-rx)} {num(-ry)}v{num(-(h - 2 * ry))}"
                f"a{num(rx)} {num(ry)} 0 0 1 {num(rx)} {num(-ry)}z")
    if tag == "line":
        return f"M{num(a['x1'])} {num(a['y1'])}L{num(a['x2'])} {num(a['y2'])}"
    if tag in ("polyline", "polygon"):
        pts = a["points"].replace(",", " ").split()
        pairs = [f"{pts[i]} {pts[i + 1]}" for i in range(0, len(pts) - 1, 2)]
        return "M" + "L".join(pairs) + ("z" if tag == "polygon" else "")
    raise ValueError(tag)


def main():
    nodes = json.load(open(sys.argv[1]))
    license_text = open(sys.argv[2]).read() if len(sys.argv) > 2 else ""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "assets", "lucide.txt")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    icons = dict(nodes)
    if len(sys.argv) > 3:
        folder = sys.argv[3]
        for file in os.listdir(folder):
            name = file[:-4]
            if not file.endswith(".svg") or name in icons:
                continue
            svg = ET.parse(os.path.join(folder, file)).getroot()
            icons[name] = [(el.tag.split("}")[-1], el.attrib) for el in svg]
    with open(out, "w") as f:
        for name in sorted(icons):
            d = "".join(to_path(tag, attrs) for tag, attrs in icons[name])
            f.write(f"{name}\t{d}\n")
    if license_text:
        open(os.path.join(root, "assets", "LICENSE-lucide.txt"), "w").write(license_text)
    print(out, len(icons), "icons", f"({len(icons) - len(nodes)} aliases)", os.path.getsize(out), "bytes")


if __name__ == "__main__":
    main()
