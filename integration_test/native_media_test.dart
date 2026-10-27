import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'support/generated_orientation_jpegs.dart';
import 'support/generated_rotated_heic.dart';

const _media = MethodChannel('safe_at_home/private_media');

Future<Uint8List> _generatedPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 4096, 2048),
    Paint()..color = const Color(0xFFFFCC66),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 2048, 1024),
    Paint()..color = const Color(0xFF1D7167),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(4096, 2048);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<(int, int, Uint8List)> _pixels(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      return (
        frame.image.width,
        frame.image.height,
        (await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List(),
      );
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

List<int> _jpegMarkers(Uint8List bytes) {
  expect(bytes.take(2), [0xff, 0xd8]);
  final markers = <int>[];
  var offset = 2;
  while (offset + 3 < bytes.length) {
    expect(bytes[offset], 0xff);
    final marker = bytes[offset + 1];
    markers.add(marker);
    if (marker == 0xda) return markers;
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    expect(length, greaterThanOrEqualTo(2));
    expect(offset + 2 + length, lessThanOrEqualTo(bytes.length));
    offset += 2 + length;
  }
  fail('JPEG pixel scan was not found within the bounded image.');
}

class _ObservedDeviceSecrets implements SecretValueStore {
  final delegate = DeviceSecretStore();
  final keys = <String>{};
  @override
  Future<String?> read(String key) => delegate.read(key);
  @override
  Future<void> write(String key, String value) async {
    keys.add(key);
    await delegate.write(key, value);
  }

  @override
  Future<void> delete(String key) => delegate.delete(key);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final fixture in generatedOrientationPhotos) {
    testWidgets(
      'native JPEG orientation ${fixture.orientation} transforms actual pixels and strips metadata',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Text(
                'Manufactured orientation acceptance; no personal photo',
              ),
            ),
          ),
        );
        final root = await _media.invokeMethod<String>('privateRootDirectory');
        expect(root, isNotNull);
        final folder = Directory(
          '$root/native-orientation-check-${newUuidV4()}',
        );
        await folder.create(recursive: true);
        await _media.invokeMethod('preparePrivateDirectory', {
          'path': folder.path,
        });
        try {
          final sourceBytes = fixture.bytes;
          expect(_jpegMarkers(sourceBytes), contains(0xe1));
          final source = File('${folder.path}/manufactured.jpg');
          await source.writeAsBytes(sourceBytes, flush: true);
          final prepared = await _media.invokeMapMethod<String, dynamic>(
            'normalizeImage',
            {'path': source.path},
          );
          final bytes = prepared!['bytes'] as Uint8List;
          final (width, height, rgba) = await _pixels(bytes);
          expect((width, height), (fixture.width, fixture.height));
          expect((prepared['width'], prepared['height']), (width, height));
          for (var quadrant = 0; quadrant < 4; quadrant++) {
            final x = width * (quadrant.isEven ? 1 : 3) ~/ 4;
            final y = height * (quadrant < 2 ? 1 : 3) ~/ 4;
            final offset = (y * width + x) * 4;
            for (var channel = 0; channel < 3; channel++) {
              expect(
                rgba[offset + channel],
                closeTo(fixture.expectedCorners[quadrant][channel], 35),
                reason:
                    'EXIF ${fixture.orientation}, upright quadrant $quadrant channel $channel',
              );
            }
            expect(rgba[offset + 3], 255);
          }
          final outputMarkers = _jpegMarkers(bytes);
          expect(
            outputMarkers,
            isNot(contains(0xe1)),
            reason: 'EXIF/GPS/XMP must be stripped',
          );
          expect(
            outputMarkers,
            isNot(contains(0xed)),
            reason: 'Source IPTC must not be copied',
          );
        } finally {
          if (await folder.exists()) await folder.delete(recursive: true);
        }
      },
    );
  }

  testWidgets(
    'native HEIC normalization rotates pixels and removes source metadata',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Text('Generated HEIC acceptance; no personal photo'),
          ),
        ),
      );
      final root = await _media.invokeMethod<String>('privateRootDirectory');
      final folder = Directory('$root/native-heic-check-${newUuidV4()}');
      await folder.create(recursive: true);
      await _media.invokeMethod('preparePrivateDirectory', {
        'path': folder.path,
      });
      try {
        final source = File('${folder.path}/generated.heic');
        await source.writeAsBytes(generatedRotatedHeic(), flush: true);
        final result = await _media.invokeMapMethod<String, dynamic>(
          'normalizeImage',
          {'path': source.path},
        );
        final bytes = result!['bytes'] as Uint8List;
        final (width, height, rgba) = await _pixels(bytes);
        expect((width, height), (48, 80));
        expect((result['width'], result['height']), (width, height));
        final expected = <List<int>>[
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
        }
        expect(bytes.take(2), [0xff, 0xd8]);
        var offset = 2;
        var reachedPixels = false;
        while (offset + 3 < bytes.length) {
          expect(bytes[offset], 0xff);
          final marker = bytes[offset + 1];
          if (marker == 0xda) {
            reachedPixels = true;
            break;
          }
          expect(
            marker,
            isNot(anyOf(0xe1, 0xed)),
            reason:
                'Normalized image must not copy source location/identity metadata',
          );
          final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
          expect(length, greaterThanOrEqualTo(2));
          expect(offset + 2 + length, lessThanOrEqualTo(bytes.length));
          offset += 2 + length;
        }
        expect(reachedPixels, isTrue);
      } finally {
        if (await folder.exists()) await folder.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'native private media bounds pixels and bakes crop and opaque covers',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Fictional native media acceptance')),
        ),
      );
      final root = await _media.invokeMethod<String>('privateRootDirectory');
      expect(root, isNotNull);
      final folder = Directory('$root/native-media-check-${newUuidV4()}');
      await folder.create(recursive: true);
      await _media.invokeMethod('preparePrivateDirectory', {
        'path': folder.path,
      });
      try {
        final raw = File('${folder.path}/generated.png');
        await raw.writeAsBytes(await _generatedPng(), flush: true);
        final prepared = await _media.invokeMapMethod<String, dynamic>(
          'normalizeImage',
          {'path': raw.path},
        );
        expect(prepared!['width'], 2048);
        expect(prepared['height'], 1024);
        final bytes = prepared['bytes'] as Uint8List;
        expect(bytes.take(2), [0xff, 0xd8]);
        expect(bytes.length, lessThanOrEqualTo(8 * 1024 * 1024));

        final edited = await _media.invokeMapMethod<String, dynamic>(
          'editImage',
          {
            'bytes': bytes,
            'redactions': [
              [.25, .25, .5, .5],
            ],
            'crop': [.125, .125, .75, .75],
          },
        );
        final (width, height, rgba) = await _pixels(
          edited!['bytes'] as Uint8List,
        );
        expect((width, height), (1536, 768));
        expect(edited['width'], width);
        expect(edited['height'], height);
        final center = ((height ~/ 2) * width + width ~/ 2) * 4;
        expect(
          rgba.sublist(center, center + 3).every((value) => value <= 5),
          isTrue,
        );
        expect(rgba[center + 3], 255);
        expect(rgba.sublist(0, 3).any((value) => value > 40), isTrue);

        await expectLater(
          _media.invokeMethod('editImage', {
            'bytes': bytes,
            'redactions': [],
            'crop': [.5, .5, .001, .001],
          }),
          throwsA(isA<PlatformException>()),
        );
        await expectLater(
          _media.invokeMethod('normalizeImage', {
            'path': '/outside-the-app/fictional.png',
          }),
          throwsA(isA<PlatformException>()),
        );
      } finally {
        if (await folder.exists()) await folder.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'encrypted case and staged pixels resume with real device key storage',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Fictional private storage acceptance')),
        ),
      );
      final root = await _media.invokeMethod<String>('privateRootDirectory');
      final account = 'native-acceptance-${newUuidV4()}';
      final folder = Directory('$root/$account');
      await folder.create(recursive: true);
      await _media.invokeMethod('preparePrivateDirectory', {
        'path': folder.path,
      });
      final secrets = _ObservedDeviceSecrets();
      LocalPrivateStore store() => LocalPrivateStore(
        directory: folder,
        accountId: account,
        secrets: secrets,
      );
      var first = store();
      try {
        const record = {
          'fictionalMarker': 'native-encrypted-case-only',
          'originalText': ' .5 ',
          'unit': 'in',
        };
        final image = await _generatedPng();
        await first.writeJson('case.native-test', record);
        await first.writeBytes('staged.native-test', image);
        await first.close();
        first = store();
        expect(await first.readJson('case.native-test'), record);
        expect(await first.readBytes('staged.native-test'), image);
        final files = await folder
            .list()
            .where((entry) => entry is File)
            .cast<File>()
            .toList();
        expect(files, hasLength(2));
        for (final file in files) {
          final content = await file.readAsBytes();
          expect(
            String.fromCharCodes(
              content,
            ).contains('native-encrypted-case-only'),
            isFalse,
          );
          expect(file.path.contains('case.native-test'), isFalse);
        }
        expect(secrets.keys, hasLength(1));
        expect(await secrets.read(secrets.keys.single), isNotNull);
      } finally {
        await first.clear();
        expect(await folder.exists(), isFalse);
        for (final key in secrets.keys) {
          expect(await secrets.read(key), isNull);
        }
      }
    },
  );
}
