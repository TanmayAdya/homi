import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/application/native_capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/image/private_media_platform.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_flow_screen.dart';

import '../fakes/decodable_photo.dart';
import '../fakes/fakes.dart';

class _Picker extends ImagePicker {
  final attempts = <Completer<XFile?>>[];
  final metadataRequests = <bool>[];
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) {
    metadataRequests.add(requestFullMetadata);
    final result = Completer<XFile?>();
    attempts.add(result);
    return result.future;
  }
}

class _Media extends PrivateMediaPlatform {
  @override
  Future<void> prepareCaptureStorage() async {}
  @override
  Future<Uint8List> normalizePath(String path) async => fictionalPng();
}

void main() {
  late _Picker picker;
  late AssessmentFlow flow;
  late AssessmentController controller;
  late PhotoCaptureCoordinator capture;
  late InMemoryStagingStore staging;

  Future<void> open(
    WidgetTester tester, {
    String errorCode = 'PHOTO_IMPORT_FAILED',
  }) async {
    picker = _Picker();
    staging = InMemoryStagingStore();
    controller = AssessmentController(ids: SequentialIdFactory());
    capture = PhotoCaptureCoordinator(
      adapter: NativeCaptureAdapter(
        context: () => throw StateError('Library import must not open camera.'),
        media: _Media(),
        picker: picker,
      ),
      staging: staging,
    );
    flow = AssessmentFlow(
      controller: controller,
      capture: capture,
      staging: staging,
    );
    addTearDown(() {
      flow.dispose();
      controller.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(home: AssessmentFlowScreen(flow: flow)),
    );
    await tester.tap(find.byKey(const ValueKey('area-entrance')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a photo'));
    await tester.pump();
    expect(flow.isBusy, isTrue);
    expect(capture.isBusy, isTrue);
    expect(picker.attempts, hasLength(1));
    picker.attempts.single.completeError(PlatformException(code: errorCode));
    await tester.pumpAndSettle();
    expect(flow.isBusy, isFalse);
    expect(capture.isBusy, isFalse);
    expect(flow.cameraBlocked, isFalse);
    expect(
      find.textContaining(
        errorCode == 'PHOTO_IMPORT_TIMEOUT'
            ? 'took too long to become available'
            : 'could not be imported',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Something went wrong taking'), findsNothing);
    expect(await staging.keys(), isEmpty);
  }

  testWidgets(
    'native import failure releases busy and a second import can succeed',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('Choose a photo'));
      await tester.pump();
      expect(picker.attempts, hasLength(2));
      final directory = Directory.systemTemp.createTempSync(
        'sah-import-retry-test-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final raw = File('${directory.path}/fictional.png')
        ..writeAsBytesSync(fictionalPng());
      picker.attempts.last.complete(XFile(raw.path));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(flow.isBusy, isFalse);
      expect(capture.isBusy, isFalse);
      expect(flow.step, AssessmentStep.preview);
      expect(find.text('Check the photo'), findsOneWidget);
      expect(await staging.keys(), hasLength(1));
      expect(raw.existsSync(), isFalse);
      expect(picker.metadataRequests, [false, false]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('timed-out import restores Back and the no-photo route', (
    tester,
  ) async {
    await open(tester, errorCode: 'PHOTO_IMPORT_TIMEOUT');
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Continue without a photo'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(flow.step, AssessmentStep.chooseArea);
    expect(find.byKey(const ValueKey('area-entrance')), findsOneWidget);
    expect(picker.attempts, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
