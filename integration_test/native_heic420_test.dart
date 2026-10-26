// Additive coverage: this does not replace the 4:4:4 HEIC test in
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'support/generated_rotated_heic420.dart';

const _media = MethodChannel('safe_at_home/private_media');

Uint8List? _configuration(Uint8List bytes, int start, int end) {
  final data = ByteData.sublistView(bytes);
  var offset = start;
  while (offset < end) {
    expect(offset + 8, lessThanOrEqualTo(end));
    final size = data.getUint32(offset);
    expect(size, greaterThanOrEqualTo(8));
    expect(offset + size, lessThanOrEqualTo(end));
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    if (type == 'hvcC') {
      return Uint8List.sublistView(bytes, offset + 8, offset + size);
    }
    if (type == 'meta' || type == 'iprp' || type == 'ipco') {
      final childStart = offset + (type == 'meta' ? 12 : 8);
      expect(childStart, lessThanOrEqualTo(offset + size));
      final found = _configuration(bytes, childStart, offset + size);
      if (found != null) return found;
    }
    offset += size;
  }
  return null;
}

void _expectNoPrivateJpegMetadata(Uint8List bytes) {
  expect(bytes.take(2), [0xff, 0xd8]);
  var offset = 2;
  while (offset + 3 < bytes.length) {
    expect(bytes[offset], 0xff);
    final marker = bytes[offset + 1];
    if (marker == 0xda) return;
    expect(
      marker,
      isNot(anyOf(0xe1, 0xed)),
      reason: 'Normalized JPEG must omit EXIF/GPS/XMP and IPTC segments',
    );
    final size = (bytes[offset + 2] << 8) | bytes[offset + 3];
    expect(size, greaterThanOrEqualTo(2));
    expect(offset + 2 + size, lessThanOrEqualTo(bytes.length));
    offset += 2 + size;
  }
  fail('Normalized JPEG has no bounded pixel scan.');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native 4:2:0 HEIC rotates actual pixels and strips source metadata',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Text('Manufactured HEIC420 acceptance; no personal photo'),
          ),
        ),
      );
      final input = generatedRotatedHeic420();
      expect(input.length, lessThan(128 * 1024));
      final configuration = _configuration(input, 0, input.length);
      expect(configuration, isNotNull);
      expect(configuration!.length, greaterThanOrEqualTo(23));
      expect(configuration[0], 1);
      expect(configuration[1] & 31, 3, reason: 'HEVC Main Still Picture');
      expect(configuration[16] & 3, 1, reason: 'Actual YUV420 declaration');
      expect(configuration[17] & 7, 0, reason: '8-bit luma');
      expect(configuration[18] & 7, 0, reason: '8-bit chroma');
      expect(String.fromCharCodes(input), contains('Exif'));

      final root = await _media.invokeMethod<String>('privateRootDirectory');
      expect(root, isNotNull);
      final folder = Directory('$root/native-heic420-check-${newUuidV4()}');
      await folder.create(recursive: true);
      await _media.invokeMethod('preparePrivateDirectory', {
        'path': folder.path,
      });
      try {
        final source = File('${folder.path}/manufactured-420.heic');
        await source.writeAsBytes(input, flush: true);
        final result = await _media.invokeMapMethod<String, dynamic>(
          'normalizeImage',
          {'path': source.path},
        );
        expect(result, isNotNull);
        final bytes = result!['bytes'] as Uint8List;
        expect(bytes.length, lessThanOrEqualTo(8 * 1024 * 1024));
        final codec = await ui.instantiateImageCodec(bytes);
        try {
          final frame = await codec.getNextFrame();
          try {
            final width = frame.image.width, height = frame.image.height;
            expect((width, height), (48, 80));
            expect((result['width'], result['height']), (width, height));
            final rgba = (await frame.image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            const expected = [
              [25, 70, 220],
              [220, 40, 40],
              [230, 190, 20],
              [20, 180, 70],
            ];
            for (var quadrant = 0; quadrant < 4; quadrant++) {
              final x = width * (quadrant.isEven ? 1 : 3) ~/ 4;
              final y = height * (quadrant < 2 ? 1 : 3) ~/ 4;
              final offset = (y * width + x) * 4;
              for (var channel = 0; channel < 3; channel++) {
                expect(
                  rgba[offset + channel],
                  closeTo(expected[quadrant][channel], 35),
                  reason: 'Upright quadrant $quadrant channel $channel',
                );
              }
              expect(rgba[offset + 3], 255);
            }
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
        _expectNoPrivateJpegMetadata(bytes);
      } finally {
        if (await folder.exists()) await folder.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
