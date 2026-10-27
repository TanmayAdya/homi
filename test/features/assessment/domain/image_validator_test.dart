import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:safe_at_home/features/assessment/domain/image/image_limits.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';
import '../fakes/image_bytes.dart';

const _validator = ImageValidator();

ImageAccepted _accepted(Uint8List bytes) {
  final ImageCheck result = _validator.check(bytes);
  expect(result, isA<ImageAccepted>());
  return result as ImageAccepted;
}

ImageRejection _rejected(Uint8List bytes) {
  final ImageCheck result = _validator.check(bytes);
  expect(result, isA<ImageRejected>());
  return (result as ImageRejected).reason;
}

void main() {
  test('server limits match the documented values', () {
    expect(ImageLimits.server.maxBytes, 8388608);
    expect(ImageLimits.server.maxPixels, 16000000);
    expect(ImageLimits.server.maxEdge, 8192);
  });

  group('PNG', () {
    test('reads IHDR dimensions', () {
      final ImageAccepted result = _accepted(
        pngHeader(width: 4000, height: 3000),
      );
      expect(result.format, SupportedImageFormat.png);
      expect(result.format.mediaType, 'image/png');
      expect((result.width, result.height), (4000, 3000));
    });

    test('truncated header is unreadable', () {
      final Uint8List full = pngHeader(width: 10, height: 10);
      expect(
        _rejected(Uint8List.sublistView(full, 0, 20)),
        ImageRejection.unreadableDimensions,
      );
    });

    test('wrong first chunk is unreadable', () {
      final Uint8List bytes = pngHeader(width: 10, height: 10);
      bytes[12] = 0x58;
      expect(_rejected(bytes), ImageRejection.unreadableDimensions);
    });
  });

  group('JPEG', () {
    test('reads baseline SOF0 after APP0', () {
      final ImageAccepted result = _accepted(
        jpegHeader(width: 4032, height: 3024),
      );
      expect(result.format, SupportedImageFormat.jpeg);
      expect((result.width, result.height), (4032, 3024));
    });

    test('reads progressive SOF2', () {
      final ImageAccepted result = _accepted(
        jpegHeader(width: 1200, height: 900, sofMarker: 0xC2),
      );
      expect((result.width, result.height), (1200, 900));
    });

    test('skips DHT instead of reading it as a frame header', () {
      final ImageAccepted result = _accepted(
        jpegHeader(width: 640, height: 480, withDhtBeforeSof: true),
      );
      expect((result.width, result.height), (640, 480));
    });

    test('handles fill bytes before a marker', () {
      final ImageAccepted result = _accepted(
        jpegHeader(width: 640, height: 480, withFillBytes: true),
      );
      expect((result.width, result.height), (640, 480));
    });

    test('works without APP0', () {
      final ImageAccepted result = _accepted(
        jpegHeader(width: 800, height: 600, withApp0: false),
      );
      expect((result.width, result.height), (800, 600));
    });

    test('scan before frame is unreadable', () {
      expect(
        _rejected(jpegWithScanBeforeFrame()),
        ImageRejection.unreadableDimensions,
      );
    });

    test('truncated frame is unreadable', () {
      final Uint8List full = jpegHeader(
        width: 800,
        height: 600,
        withApp0: false,
      );
      expect(
        _rejected(Uint8List.sublistView(full, 0, 7)),
        ImageRejection.unreadableDimensions,
      );
    });

    test('zero height (defined later by DNL) is rejected', () {
      expect(
        _rejected(jpegHeader(width: 800, height: 0)),
        ImageRejection.zeroDimension,
      );
    });
  });

  group('HEIF family', () {
    test('HEIC major brand', () {
      expect(
        _rejected(ftypHeader('heic', compatible: ['mif1', 'heic'])),
        ImageRejection.heif,
      );
    });

    test('generic mif1 brand', () {
      expect(_rejected(ftypHeader('mif1')), ImageRejection.heif);
    });

    test('HEIF brand found only in compatible list', () {
      expect(
        _rejected(ftypHeader('xxxx', compatible: ['isom', 'heix'])),
        ImageRejection.heif,
      );
    });

    test('a non-image ftyp file (MP4) is unsupported, not HEIF', () {
      expect(
        _rejected(ftypHeader('isom', compatible: ['iso2', 'mp41'])),
        ImageRejection.unsupportedFormat,
      );
    });
  });

  group('format is identified by content only', () {
    test('empty bytes', () {
      expect(_rejected(Uint8List(0)), ImageRejection.empty);
    });

    test('unknown bytes are unsupported', () {
      expect(
        _rejected(Uint8List.fromList('GIF89a'.codeUnits + List.filled(20, 0))),
        ImageRejection.unsupportedFormat,
      );
    });

    test('a lone JPEG SOI without a following marker is unsupported', () {
      expect(
        _rejected(Uint8List.fromList([0xFF, 0xD8, 0x00, 0x00])),
        ImageRejection.unsupportedFormat,
      );
    });
  });

  group('limits', () {
    test('exactly 8 MiB is accepted', () {
      final Uint8List bytes = padTo(
        pngHeader(width: 100, height: 100),
        8 * 1024 * 1024,
      );
      expect(_accepted(bytes).byteLength, 8388608);
    });

    test('one byte over 8 MiB is rejected before parsing', () {
      final Uint8List bytes = padTo(
        pngHeader(width: 100, height: 100),
        8 * 1024 * 1024 + 1,
      );
      expect(_rejected(bytes), ImageRejection.tooManyBytes);
    });

    test('edge of 8192 is accepted when pixels fit', () {
      final ImageAccepted result = _accepted(
        pngHeader(width: 8192, height: 1000),
      );
      expect(result.width, 8192);
    });

    test('edge over 8192 is rejected', () {
      expect(
        _rejected(pngHeader(width: 8193, height: 10)),
        ImageRejection.edgeTooLong,
      );
      expect(
        _rejected(jpegHeader(width: 10, height: 8193)),
        ImageRejection.edgeTooLong,
      );
    });

    test('exactly 16,000,000 pixels is accepted', () {
      _accepted(pngHeader(width: 4000, height: 4000));
    });

    test('over 16,000,000 pixels is rejected', () {
      final ImageCheck result = _validator.check(
        pngHeader(width: 4001, height: 4000),
      );
      expect(result, isA<ImageRejected>());
      final rejected = result as ImageRejected;
      expect(rejected.reason, ImageRejection.tooManyPixels);
      expect((rejected.width, rejected.height), (4001, 4000));
    });

    test('zero width is rejected', () {
      expect(
        _rejected(pngHeader(width: 0, height: 10)),
        ImageRejection.zeroDimension,
      );
    });

    test('custom limits are respected', () {
      const tight = ImageValidator(
        limits: ImageLimits(maxBytes: 1000, maxPixels: 100, maxEdge: 20),
      );
      final ImageCheck result = tight.check(pngHeader(width: 11, height: 10));
      expect((result as ImageRejected).reason, ImageRejection.tooManyPixels);
    });
  });
}
