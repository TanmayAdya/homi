#!/usr/bin/env python3
"""Rebuild the pinned, exact-code-point PDF font locally. Requires FontTools 4.61.1.
The input is the unmodified Noto Sans CJK SC 2.004 OTF downloaded from the URL
in README.md. No network, external credentials, or resident data are used.
"""
from hashlib import sha256
from math import floor, ceil
from pathlib import Path
import struct
import sys
from fontTools import subset
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.ttLib import TTFont

SOURCE_SHA256 = "2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b"
source = Path(sys.argv[1])
output = Path(__file__).resolve().parent
if sha256(source.read_bytes()).hexdigest() != SOURCE_SHA256:
    raise SystemExit("The source font does not match the reviewed release.")
font = TTFont(source, recalcTimestamp=False)
options = subset.Options()
options.layout_features = []
options.name_IDs = ["*"]
options.name_languages = ["*"]
options.recalc_timestamp = False
subsetter = subset.Subsetter(options=options)
subsetter.populate(unicodes=font.getBestCmap())
subsetter.subset(font)
for tag in ("GSUB", "GPOS", "GDEF", "BASE", "DSIG"):
    if tag in font:
        del font[tag]
cff = font["CFF "].cff.topDictIndex[0]
order = font.getGlyphOrder()
used = set(order)
unused = [i for i in range(1, 65535) if f"cid{i:05}" not in used]
seen = set()
for codepoint, glyph in sorted(font.getBestCmap().items()):
    if glyph not in seen:
        seen.add(glyph)
        continue
    alias = f"cid{unused.pop():05}"
    index = len(cff.CharStrings.charStringsIndex)
    cff.CharStrings.charStringsIndex.append(cff.CharStrings[glyph])
    cff.CharStrings.charStrings[alias] = index
    cff.charset.append(alias)
    cff.FDSelect.gidArray.append(cff.FDSelect.gidArray[cff.CharStrings.charStrings[glyph]])
    order.append(alias)
    font["hmtx"].metrics[alias] = font["hmtx"].metrics[glyph]
    if "vmtx" in font:
        font["vmtx"].metrics[alias] = font["vmtx"].metrics[glyph]
    for table in font["cmap"].tables:
        if table.isUnicode() and table.cmap.get(codepoint) == glyph:
            table.cmap[codepoint] = alias
font.setGlyphOrder(order)
glyphs = font.getGlyphSet()
charstrings = {}
for name in order:
    pen = T2CharStringPen(font["hmtx"].metrics[name][0], glyphs, roundTolerance=0)
    glyphs[name].draw(pen)
    charstrings[name] = pen.getCharString()
builder = FontBuilder(font=font, isTTF=False)
builder.setupCFF("SafeAtHomeCJK-Regular", {
    "FullName": "Safe at Home CJK Regular", "FamilyName": "Safe at Home CJK",
    "Weight": "Regular", "version": "2.004.2",
    "Notice": "Copyright 2014-2021 Adobe (http://www.adobe.com/). Noto is a trademark of Google Inc.",
}, charstrings, {})
names = {1: "Safe at Home CJK", 2: "Regular", 3: "SafeAtHomeCJK-Regular-2.004.2",
         4: "Safe at Home CJK Regular", 6: "SafeAtHomeCJK-Regular",
         16: "Safe at Home CJK", 17: "Regular"}
for entry in font["name"].names:
    if entry.nameID in names:
        entry.string = names[entry.nameID].encode(entry.getEncoding())
font["CFF "].cff.fontNames = ["SafeAtHomeCJK-Regular"]
font_path = output / "SafeAtHomeCJK-Regular.otf"
font.save(font_path)
font = TTFont(font_path, recalcTimestamp=False)
glyphs = font.getGlyphSet()
metrics = bytearray(b"SAHCM001" + struct.pack(">II", len(font.getGlyphOrder()), font["head"].unitsPerEm))
for name in font.getGlyphOrder():
    pen = BoundsPen(glyphs)
    glyphs[name].draw(pen)
    bounds = pen.bounds or (0, 0, 0, 0)
    metrics.extend(struct.pack(">hhhhh", font["hmtx"].metrics[name][0],
                               floor(bounds[0]), floor(bounds[1]), ceil(bounds[2]), ceil(bounds[3])))
metrics_path = output / "SafeAtHomeCJK-Regular.metrics.bin"
metrics_path.write_bytes(metrics)
for path in (font_path, metrics_path):
    print(path.name, len(path.read_bytes()), sha256(path.read_bytes()).hexdigest())
