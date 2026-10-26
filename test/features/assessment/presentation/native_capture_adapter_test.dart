import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:safe_at_home/features/assessment/application/native_capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/image/private_media_platform.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../../app/app_design_test.dart' show narrowLargeText;
import '../../../app/core_localization_test.dart' show localized;
import '../fakes/image_bytes.dart';

const _camera = CameraDescription(
  name: 'synthetic',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);
const _request = CaptureRequest(
  area: AssessmentArea.entrance,
  view: CaptureView.overview,
  promptId: 'synthetic-entrance',
);

class _Camera extends CameraController {
  _Camera() : super(_camera, ResolutionPreset.high, enableAudio: false);
  final picture = Completer<XFile>();
  bool closed = false;
  int shots = 0;
  @override
  Future<void> initialize() async {
    value = value.copyWith(
      isInitialized: true,
      previewSize: const Size(640, 480),
    );
  }

  @override
  Future<XFile> takePicture() {
    shots++;
    return picture.future;
  }

  @override
  Widget buildPreview() => const ColoredBox(color: Colors.grey);
  @override
  Future<void> dispose() async {
    closed = true;
    await super.dispose();
  }
}

class _Media extends PrivateMediaPlatform {
  _Media({this.prepared, this.decoded});
  final Future<void>? prepared;
  final Future<Uint8List>? decoded;
  final preparationStarted = Completer<void>();
  final normalizationStarted = Completer<void>();
  int normalized = 0;
  @override
  Future<void> prepareCaptureStorage() async {
    if (!preparationStarted.isCompleted) preparationStarted.complete();
    await prepared;
  }

  @override
  Future<Uint8List> normalizePath(String path) async {
    normalized++;
    if (!normalizationStarted.isCompleted) normalizationStarted.complete();
    return await decoded ?? pngHeader(width: 800, height: 600);
  }
}

class _Picker extends ImagePicker {
  final selected = Completer<XFile?>();
  final opened = Completer<void>();
  int calls = 0;
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) {
    calls++;
    expect(source, ImageSource.gallery);
    expect(requestFullMetadata, isFalse);
    if (!opened.isCompleted) opened.complete();
    return selected.future;
  }
}

const _libraryRequest = CaptureRequest(
  area: AssessmentArea.entrance,
  view: CaptureView.overview,
  promptId: 'synthetic-entrance',
  source: CaptureSource.library,
);

void main() {
  for (final locale in [
    const Locale('es'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ]) {
    testWidgets(
      '$locale real camera route translates preparation, shutter and interruption at 320px/3.2x',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final words = AppLocalizations(locale);
        final cameras = Completer<List<CameraDescription>>();
        final camera = _Camera();
        late BuildContext host;
        await tester.pumpWidget(
          localized(
            locale,
            Builder(
              builder: (context) {
                host = context;
                return const Scaffold();
              },
            ),
          ),
        );
        final adapter = NativeCaptureAdapter(
          context: () => host,
          media: _Media(),
          loadCameras: () => cameras.future,
          cameraControllerFactory: (_) => camera,
        );
        final pending = adapter.capture(_request);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text(words.text('Take a home photo')), findsOneWidget);
        expect(
          tester
              .widget<CircularProgressIndicator>(
                find.byType(CircularProgressIndicator),
              )
              .semanticsLabel,
          words.text('Preparing camera'),
        );
        expect(
          find.text(
            words.text(
              'Keep people, mail, medicines and account details out of the picture.',
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        cameras.complete([_camera]);
        await tester.pumpAndSettle();
        final shutter = find.text(words.text('Take photo'));
        expect(shutter.hitTestable(), findsOneWidget);
        await tester.tap(shutter);
        await tester.pumpAndSettle();
        expect(find.text(words.text('Taking photo…')), findsOneWidget);
        camera.picture.completeError(
          CameraException('fictional', 'Private native failure'),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(words.text('The photo was interrupted. Please try again.')),
          findsOneWidget,
        );
        expect(find.textContaining('Private native failure'), findsNothing);
        expect(tester.takeException(), isNull);
        Navigator.of(host).pop();
        await tester.pumpAndSettle();
        expect(await pending, isA<CaptureCancelled>());
      },
    );
  }

  for (final request in [_request, _libraryRequest]) {
    test(
      'expired ${request.source.name} preparation never opens native UI',
      () async {
        final prepared = Completer<void>();
        final media = _Media(prepared: prepared.future);
        final picker = _Picker();
        var current = true;
        var cameraLookups = 0;
        final adapter = NativeCaptureAdapter(
          context: () => throw StateError('Stale native UI must not open'),
          media: media,
          picker: picker,
          isCurrent: () => current,
          loadCameras: () async {
            cameraLookups++;
            return [_camera];
          },
        );
        final capture = adapter.capture(request);
        await media.preparationStarted.future;
        current = false;
        prepared.complete();
        expect(await capture, isA<CaptureCancelled>());
        expect(picker.calls, 0);
        expect(cameraLookups, 0);
        expect(media.normalized, 0);
      },
    );
  }

  test(
    'late library result is deleted without decoding after scope expiry',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sah-stale-import-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/fictional.jpg',
      ).writeAsBytes([1, 2, 3]);
      final media = _Media();
      final picker = _Picker();
      var current = true;
      final adapter = NativeCaptureAdapter(
        context: () => throw StateError('Library capture has no Flutter route'),
        media: media,
        picker: picker,
        isCurrent: () => current,
      );
      final capture = adapter.capture(_libraryRequest);
      await picker.opened.future;
      current = false;
      picker.selected.complete(XFile(file.path));
      expect(await capture, isA<CaptureCancelled>());
      expect(media.normalized, 0);
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'scope expiry during normalization cannot return staged pixels',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sah-stale-decode-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/fictional.jpg',
      ).writeAsBytes([1, 2, 3]);
      final decoded = Completer<Uint8List>();
      final media = _Media(decoded: decoded.future);
      final picker = _Picker();
      var current = true;
      final adapter = NativeCaptureAdapter(
        context: () => throw StateError('Library capture has no Flutter route'),
        media: media,
        picker: picker,
        isCurrent: () => current,
      );
      final capture = adapter.capture(_libraryRequest);
      await picker.opened.future;
      picker.selected.complete(XFile(file.path));
      await media.normalizationStarted.future;
      current = false;
      decoded.complete(pngHeader(width: 800, height: 600));
      expect(await capture, isA<CaptureCancelled>());
      expect(media.normalized, 1);
      expect(await file.exists(), isFalse);
    },
  );

  testWidgets(
    'backgrounded camera result is deleted and cannot complete the reopened capture',
    (tester) async {
      final media = _Media();
      final controllers = <_Camera>[];
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold(body: Text('Home'));
            },
          ),
        ),
      );
      final adapter = NativeCaptureAdapter(
        context: () => context,
        media: media,
        loadCameras: () async => [_camera],
        cameraControllerFactory: (_) {
          final value = _Camera();
          controllers.add(value);
          return value;
        },
      );
      final pending = adapter.capture(_request);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Take photo'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(controllers.first.closed, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(controllers, hasLength(2));
      expect(find.text('Take photo'), findsOneWidget);
      await tester.tap(find.text('Take photo'));
      await tester.pump();
      expect(controllers.last.shots, 1);
      final directory = Directory.systemTemp.createTempSync('sah-camera-test-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/fictional.jpg')
        ..writeAsBytesSync([1, 2, 3]);
      controllers.first.picture.complete(XFile(file.path));
      for (var i = 0; i < 20 && file.existsSync(); i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(file.existsSync(), isFalse);
      await tester.pumpAndSettle();
      expect(media.normalized, 0);
      expect(find.text('Taking photo…'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(await pending, isA<CaptureCancelled>());
    },
  );
  testWidgets(
    'foreground result is normalized, capture dated and its raw copy removed',
    (tester) async {
      final media = _Media();
      final controller = _Camera();
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold(body: Text('Home'));
            },
          ),
        ),
      );
      final adapter = NativeCaptureAdapter(
        context: () => context,
        media: media,
        loadCameras: () async => [_camera],
        cameraControllerFactory: (_) => controller,
      );
      final pending = adapter.capture(_request);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Take photo'));
      await tester.pump();
      final directory = Directory.systemTemp.createTempSync('sah-camera-test-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/fictional.jpg')
        ..writeAsBytesSync([1, 2, 3]);
      CaptureResult? result;
      pending.then((value) => result = value);
      controller.picture.complete(XFile(file.path));
      for (var i = 0; i < 20 && result == null; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(result, isA<CaptureSucceeded>());
      final photo = result! as CaptureSucceeded;
      expect(photo.orientationNormalized, isTrue);
      expect(DateTime.tryParse(photo.capturedAt!), isNotNull);
      expect(file.existsSync(), isFalse);
      await tester.pumpAndSettle();
      expect(media.normalized, 1);
      expect(find.text('Home'), findsOneWidget);
    },
  );
}
