#!/usr/bin/env python3
"""Compare every embedded reviewed glyph with its pinned source outline.

Local acceptance tool only: FontTools 4.61.1, pypdf 6.14.2 and Pillow. It never
changes the PDF or uses the network. Native raster review is still required.
"""
from io import BytesIO
from pathlib import Path
import re
import sys

from fontTools.cffLib import CFFFontSet
from fontTools.pens.recordingPen import RecordingPen
from fontTools.ttLib import TTFont
from PIL import ImageFont
from pypdf import PdfReader
from pypdf.generic import DictionaryObject

source = TTFont(Path(__file__).with_name("SafeAtHomeCJK-Regular.otf"))
glyphs = source.getGlyphSet()
cmap = source.getBestCmap()
checked_fonts = set()
checked_forms = set()
glyph_count = 0


def identity(reference):
    return (reference.idnum, reference.generation)


def check_font(reference):
    global glyph_count
    font = reference.get_object()
    if not isinstance(font, DictionaryObject):
        return
    if not str(font.get("/BaseFont", "")).startswith(("/SAHFRM+", "/SAHEVD+")):
        return
    if identity(reference) in checked_fonts:
        return
    checked_fonts.add(identity(reference))
    descendant = font["/DescendantFonts"][0].get_object()
    raw = descendant["/FontDescriptor"]["/FontFile3"].get_data()
    assert raw[:4] == bytes([1, 0, 4, 4]), "Invalid CFF header would trigger fallback fonts"
    ImageFont.truetype(BytesIO(raw), 20)
    subset = CFFFontSet()
    subset.decompile(BytesIO(raw), None)
    top = subset.topDictIndex[0]
    assert len(top.FDArray) == 1, "Reviewed source must use one font dictionary"
    unicode = font["/ToUnicode"].get_data().decode("ascii")
    assert "beginbfrange" not in unicode, "Unexpected mapping syntax"
    for group in re.findall(r"beginbfchar(.*?)endbfchar", unicode, re.S):
        for cid_hex, unicode_hex in re.findall(r"<([A-Fa-f0-9]+)>\s*<([A-Fa-f0-9]+)>", group):
            cid = int(cid_hex, 16)
            text = bytes.fromhex(unicode_hex).decode("utf-16-be")
            assert len(text) == 1 and cid != 0, "Unexpected reviewed glyph mapping"
            expected = RecordingPen()
            glyphs[cmap[ord(text)]].draw(expected)
            actual = RecordingPen()
            charstring = top.CharStrings[top.charset[cid]]
            charstring.draw(actual)
            assert actual.value == expected.value, f"Subset outline changed for U+{ord(text):04X}"
            assert charstring.width == source["hmtx"].metrics[cmap[ord(text)]][0]
            glyph_count += 1


def resources(value):
    value = value.get_object()
    for reference in value.get("/Font", {}).get_object().values() if "/Font" in value else []:
        check_font(reference)
    for reference in value.get("/XObject", {}).get_object().values() if "/XObject" in value else []:
        if identity(reference) in checked_forms:
            continue
        checked_forms.add(identity(reference))
        obj = reference.get_object()
        if obj.get("/Subtype") == "/Form" and "/Resources" in obj:
            resources(obj["/Resources"])


for filename in sys.argv[1:]:
    checked_fonts.clear()
    checked_forms.clear()
    glyph_count = 0
    for page in PdfReader(filename).pages:
        resources(page["/Resources"])
    assert checked_fonts and glyph_count, "No reviewed font found"
    print(f"{Path(filename).name}: {len(checked_fonts)} native font subsets accepted; "
          f"{glyph_count} exact source outlines/advances matched")
