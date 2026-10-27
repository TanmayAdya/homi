# Reviewed Chinese PDF font

`SafeAtHomeCJK-Regular.otf` is a renamed derivative of **Noto Sans CJK SC
Regular 2.004**, Copyright © 2014–2021 Adobe. The original copyright and SIL Open
Font License information remain in the font's readable name table. `OFL.txt` is
the upstream license; the derivative font and its build script remain under the
SIL Open Font License 1.1. Font embedding in draft documents has no license fee.

Official release sources:

- https://github.com/notofonts/noto-cjk/tree/Sans2.004
- https://raw.githubusercontent.com/notofonts/noto-cjk/Sans2.004/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf
- https://raw.githubusercontent.com/notofonts/noto-cjk/Sans2.004/LICENSE

Original OTF SHA-256:
`2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b`.

The repertoire includes both simplified and traditional Chinese, including
supported supplementary-plane Han name characters, alongside Latin text.
The source font's SC regional glyph appearance is retained. No resident text
is simplified, traditionalized, normalized, translated or transliterated.
Unsupported glyphs, variation selectors, combining sequences and positional
controls remain explicit review errors; the original stored value is preserved.

## Why this derivative exists

The original has 510 duplicate Unicode-to-glyph mappings. In pdf-lib 1.17.1's
subset encoder, two different values that select the same glyph ID can share
one `ToUnicode` entry. For example, `兀` (U+5140) and `兀` (U+FA0C) could then
extract as the same character. The derivative assigns each of the 44,810 Unicode
code points a distinct glyph ID while retaining the same visible outline.
Unused alternate glyphs and shaping tables are removed because this renderer
supports horizontal literal character entry, not complex-script layout.

The derivative also rebuilds the exact outlines and advances as one CFF font
dictionary, without hints or subroutines. This avoids fontkit 1.1.1's incorrect
remapping when a subset revisits an earlier CID private dictionary. All 44,811
glyph metrics remain byte-for-byte identical to the earlier derivative. The
font is 10,013,776 bytes, smaller than the 10,747,620-byte CID derivative.

The public `createSubset` / `encodeStream` adapter additionally repairs the
four-byte CFF header: fontkit 1.1.1 writes its source table length as `offSize`
instead of a legal 1–4 value. Only that one byte changes, to 4. FreeType otherwise
rejects the embedded font and silently substituted system fonts can hide missing
Chinese glyphs despite correct text extraction. Native raster checks and subset
outline comparisons are required alongside ToUnicode checks.

Only used glyphs are embedded in each PDF. The immutable font and metrics bytes
are lazily loaded and hash checked; parsed-font caches belong to one export and subset caches belong to each
individual document, not a global cache of resident text. A form and its appended
evidence reuse the parser with separate subset encoders and deterministic, distinct
`SAHFRM` / `SAHEVD` font-name prefixes. The pinned fontkit ArrayBuffer adapter
reads the one verified source allocation without making per-parser copies.
Text, labels and review boxes are serialized into a small PDF before full image
embedding starts. Only plain bytes and verified image-slot bindings leave that
stage, so parser and outline caches become eligible for collection before the
large-photo save. Empty
image slots are replaced in place, preserving the original paint order, and are
removed from the final document. Latin-only exports
keep the existing Helvetica path without loading this font or fontkit.

`SafeAtHomeCJK-Regular.metrics.bin` stores bounded, precomputed outline metrics
by glyph ID. It avoids decoding and retaining thousands of CFF outline paths
just to decide whether a reviewed answer fits. Its header is `SAHCM001`, followed
by big-endian unsigned glyph count and units/em, then five big-endian signed
16-bit values per glyph: advance, left, bottom, right, top. Curve extrema are
rounded outward. Both assets' SHA-256 values are pinned in
`src/pdf/reviewed-text-font.ts` and included in the renderer identity.

## Reproduce locally

Use Python with **FontTools 4.61.1**, download the exact upstream OTF into an
ignored local directory, then run from `backend/`:

```sh
python3 assets/fonts/rebuild.py local-artifacts/NotoSansCJKsc-Regular-2.004.otf
```

The script verifies the original hash before reading the font, preserves source
timestamps, prints both derived hashes, and makes no network requests. Python
and FontTools are build-time tools only; they are not required by the service.
`@pdf-lib/fontkit` 1.1.1 is pinned in `package-lock.json`; pdf-lib's official font
embedding API is documented at https://github.com/Hopding/pdf-lib#fontkit-installation.

`test/reviewed-font-outlines.fixture.json` pins hashes of the original upstream
font's SVG outlines for both Chinese scripts, compatibility/supplementary Han,
Latin, and representatives of every source private dictionary. It catches
outline changes independently of text extraction and bounding-box checks.

For a generated fictional PDF, also run the local acceptance tool (FontTools
4.61.1, pypdf 6.14.2 and Pillow) and rasterize with a native PDF renderer:

```sh
python3 assets/fonts/verify-pdf-outlines.py local-artifacts/fictional-draft.pdf
pdftoppm -png -singlefile local-artifacts/fictional-draft.pdf local-artifacts/fictional-draft
```

The verifier requires FreeType to accept each actual embedded reviewed font,
checks its legal CFF header and single dictionary, and compares every mapped
glyph's complete vector commands and advance with the pinned source. Raster
acceptance must reject invalid embedded fonts or fallback, and visibly check
Simplified/Traditional names, annotations, compatibility and supplementary Han.
