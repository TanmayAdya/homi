import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/application/native_capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';

const _native = MethodChannel('safe_at_home/private_media');
const _request = CaptureRequest(
  area: AssessmentArea.bathroom,
  view: CaptureView.overview,
  promptId: 'operator-generated-heic',
  source: CaptureSource.library,
);

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

void _expectNoSourceMetadata(Uint8List bytes) {
  expect(bytes.take(2), [0xff, 0xd8]);
  var offset = 2;
  while (offset + 3 < bytes.length) {
    expect(bytes[offset], 0xff);
    final marker = bytes[offset + 1];
    if (marker == 0xda) return;
    expect(
      marker,
      isNot(anyOf(0xe1, 0xed)),
      reason: 'Imported JPEG must omit EXIF/GPS/XMP and source IPTC segments',
    );
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    expect(length, greaterThanOrEqualTo(2));
    expect(offset + 2 + length, lessThanOrEqualTo(bytes.length));
    offset += 2 + length;
  }
  fail('The imported JPEG did not contain a bounded pixel scan');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real iOS picker cancels, imports generated HEIC, then cancels again',
    (tester) async {
      late BuildContext appContext;
      final instruction = ValueNotifier<String>(
        'Native photo picker check. Use only the generated four-color photo.',
      );
      addTearDown(() async {
        try {
          await _native
              .invokeMethod<void>('clearTemporaryMedia')
              .timeout(const Duration(seconds: 5));
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          instruction.dispose();
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: Builder(
            builder: (context) {
              appContext = context;
              return Scaffold(
                appBar: AppBar(title: const Text('Generated photo check')),
                body: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: ValueListenableBuilder<String>(
                      valueListenable: instruction,
                      builder: (_, value, _) => Text(value),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      final adapter = NativeCaptureAdapter(context: () => appContext);

      Future<CaptureResult> operate(String marker, String guidance) async {
        instruction.value = guidance;
        await tester.pump();
        CaptureResult? result;
        Object? failure;
        final pending = adapter
            .capture(_request)
            .then<void>(
              (value) {
                result = value;
              },
              onError: (Object error, StackTrace stack) {
                failure = error;
              },
            );
        debugPrint('$marker: $guidance');
        final elapsed = Stopwatch()..start();
        while (result == null && failure == null) {
          if (elapsed.elapsed > const Duration(seconds: 90)) {
            fail('Timed out waiting for the operator at $marker');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await pending;
        if (failure != null) fail('Native capture threw at $marker');
        await tester.pump();
        return result!;
      }

      final cancelled = await operate(
        'LOCAL_NATIVE_PICKER_CANCEL_FIRST',
        'Cancel the system photo picker without selecting a photo.',
      );
      expect(cancelled, isA<CaptureCancelled>());
      debugPrint('LOCAL_NATIVE_PICKER_FIRST_CANCEL_PASSED');

      final selected = await operate(
        'LOCAL_NATIVE_PICKER_SELECT_HEIC',
        'Select only the generated four-color HEIC photo seeded for this check.',
      );
      expect(selected, isA<CaptureSucceeded>());
      if (selected is! CaptureSucceeded) {
        fail('The real picker did not return the generated photo');
      }
      expect(selected.capturedAt, isNull);
      expect(selected.orientationNormalized, isTrue);
      expect(selected.bytes.length, lessThanOrEqualTo(8 * 1024 * 1024));
      final (width, height, rgba) = await _pixels(selected.bytes);
      expect((width, height), (48, 80));
      const expected = <List<int>>[
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
            reason: 'Upright generated quadrant $quadrant channel $channel',
          );
        }
        expect(rgba[offset + 3], 255);
      }
      _expectNoSourceMetadata(selected.bytes);
      debugPrint(
        'LOCAL_NATIVE_PICKER_HEIC_PASSED: upright pixels, metadata removed, no invented capture date',
      );

      final cancelledAgain = await operate(
        'LOCAL_NATIVE_PICKER_CANCEL_AGAIN',
        'Cancel the system photo picker again to confirm it can reopen.',
      );
      expect(cancelledAgain, isA<CaptureCancelled>());
      expect(tester.takeException(), isNull);
      instruction.value =
          'Generated photo check passed. No library photo was deleted.';
      await tester.pump();
      debugPrint(
        'LOCAL_NATIVE_PICKER_PASSED: cancel, real import, reopen/cancel',
      );
    },
    skip:
        !const bool.fromEnvironment('SAH_NATIVE_PICKER_REVIEW') ||
        !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
