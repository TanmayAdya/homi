import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../integration_test/fictional_journey_test.dart'
    show
        normalizedGlyphInkMask,
        normalizedInkDifference,
        pdfGlyphRectsForMatch,
        requiresEmbeddedChineseFont;

void main() {
  List<(int, int)> ink(bool Function(int, int) accepts) => [
    for (var y = 0; y < 32; y++)
      for (var x = 0; x < 32; x++)
        if (accepts(x, y)) (x, y),
  ];

  test(
    'UTF-16 boxes preserve supplementary prefixes and exact name bounds',
    () {
      const prefix = '𠮷 A ';
      const name = '陈兀兀𠮷华';
      final boxes = <PdfRect>[];
      final byRune = <PdfRect>[];
      var position = 0.0;
      for (final rune in '$prefix$name尾'.runes) {
        final box = PdfRect(position, 12, position + 8, 2);
        position += 10;
        byRune.add(box);
        boxes.add(box);
        if (rune > 0xffff) boxes.add(box);
      }
      final text = PdfPageRawText('$prefix$name尾', boxes);
      final result = pdfGlyphRectsForMatch(text, name);
      expect(
        result,
        byRune.sublist(prefix.runes.length, prefix.runes.length + 5),
      );
      expect(result, hasLength(5));
      expect(pdfGlyphRectsForMatch(text, '尾'), [byRune.last]);
      expect(result[1], isNot(result[2]));
    },
  );

  test(
    'surrogate bounds combine without including empty origin placeholders',
    () {
      final text = PdfPageRawText('𠮷华𠮷', const [
        PdfRect(30, 14, 36, 4),
        PdfRect(34, 12, 40, 2),
        PdfRect(42, 14, 50, 2),
        PdfRect(52, 14, 60, 2),
        PdfRect.empty,
      ]);
      expect(pdfGlyphRectsForMatch(text, '𠮷华𠮷'), const [
        PdfRect(30, 14, 40, 2),
        PdfRect(42, 14, 50, 2),
        PdfRect(52, 14, 60, 2),
      ]);
    },
  );

  test(
    'scalar-aligned native boxes retain offsets after supplementary text',
    () {
      final boxes = List.generate(4, (i) => PdfRect(i * 10, 12, i * 10 + 8, 2));
      final text = PdfPageRawText('𠮷陈𠮷华', boxes);
      expect(pdfGlyphRectsForMatch(text, '陈𠮷华'), boxes.sublist(1));
    },
  );

  test('unrecognized PDF text-to-box alignment fails instead of guessing', () {
    final text = PdfPageRawText('𠮷𠮷华', List.filled(4, PdfRect.empty));
    expect(() => pdfGlyphRectsForMatch(text, '华'), throwsStateError);
  });

  test(
    'missing custom CJK faces and Chinese charsets fail the fallback guard',
    () {
      PdfFontQuery font(String face, PdfFontCharset charset) => PdfFontQuery(
        face: face,
        charset: charset,
        weight: 400,
        isItalic: false,
        pitchFamily: 0,
      );
      expect(
        requiresEmbeddedChineseFont(
          font('SAHFRM+SafeAtHomeCJK-Regular', PdfFontCharset.ansi),
        ),
        true,
      );
      expect(
        requiresEmbeddedChineseFont(
          font('SAHEVD+SafeAtHomeCJK-Regular', PdfFontCharset.default_),
        ),
        true,
      );
      expect(
        requiresEmbeddedChineseFont(
          font('Unexpected fallback', PdfFontCharset.gb2312),
        ),
        true,
      );
      expect(
        requiresEmbeddedChineseFont(
          font('Unexpected fallback', PdfFontCharset.chineseBig5),
        ),
        true,
      );
      expect(
        requiresEmbeddedChineseFont(font('Helvetica', PdfFontCharset.ansi)),
        false,
      );
      expect(
        requiresEmbeddedChineseFont(font('Arial', PdfFontCharset.default_)),
        false,
      );
    },
  );

  test(
    'repeated missing-glyph boxes normalize alike after shift and scale',
    () {
      final box = ink((x, y) => x < 2 || x > 29 || y < 2 || y > 29);
      final shiftedScaled = <(int, int)>[
        for (final (x, y) in box)
          for (var dy = 0; dy < 2; dy++)
            for (var dx = 0; dx < 2; dx++) (x * 2 + dx + 11, y * 2 + dy + 7),
      ];
      expect(
        normalizedInkDifference(
          normalizedGlyphInkMask(box),
          normalizedGlyphInkMask(shiftedScaled),
        ),
        closeTo(0, 0.000001),
      );
    },
  );

  test('the occupancy heuristic separates visibly different ink patterns', () {
    final masks = [
      normalizedGlyphInkMask(ink((x, y) => x < 2 || x > 29 || y < 2 || y > 29)),
      normalizedGlyphInkMask(ink((x, y) => (x - y).abs() <= 1)),
      normalizedGlyphInkMask(
        ink((x, y) => (x - 15).abs() <= 1 || (y - 15).abs() <= 1),
      ),
      normalizedGlyphInkMask(ink((x, y) => x < 2 || x > 29 || y > 29)),
    ];
    for (var i = 0; i < masks.length; i++) {
      for (var j = i + 1; j < masks.length; j++) {
        expect(normalizedInkDifference(masks[i], masks[j]), greaterThan(0.18));
      }
    }
  });
}
