# Writes the site's web fonts (site/src/fonts/*.woff2): Latin subsets of the sample's fonts
# (designs/sample/fonts, OFL). Run from the repository root:
#   python3 site/tools/fonts.py        (needs fontTools and brotli: pip install fonttools brotli)
import os
from fontTools import subset
from fontTools.ttLib import TTFont

SRC = "designs/sample/fonts"
OUT = "site/src/fonts"
# Basic Latin, Latin-1, general punctuation (· — – “ ” ‘ ’ …), arrows, the euro sign
UNICODES = "U+0020-007E,U+00A0-00FF,U+0131,U+0152-0153,U+2013-2014,U+2018-201E,U+2022,U+2026,U+2032-2033,U+20AC,U+2122,U+2190-2193,U+2212"
FONTS = {
	"Inter-Regular.ttf": "inter-400.woff2",
	"Inter-Medium.ttf": "inter-500.woff2",
	"Inter-SemiBold.ttf": "inter-600.woff2",
	"Inter-Bold.ttf": "inter-700.woff2",
	"jetbrains-mono-latin-400-normal.woff": "jetbrains-mono-400.woff2",
	"jetbrains-mono-latin-600-normal.woff": "jetbrains-mono-600.woff2",
}
os.makedirs(OUT, exist_ok=True)
opts = subset.Options()
opts.flavor = "woff2"
opts.layout_features = ["kern", "liga", "calt", "tnum", "case", "ss01", "cv11"]
opts.name_IDs = ["*"]
opts.notdef_outline = True
for src, out in FONTS.items():
	font = TTFont(os.path.join(SRC, src))
	sub = subset.Subsetter(opts)
	sub.populate(unicodes=subset.parse_unicodes(UNICODES))
	sub.subset(font)
	font.flavor = "woff2"
	font.save(os.path.join(OUT, out))
	print(out, os.path.getsize(os.path.join(OUT, out)))
