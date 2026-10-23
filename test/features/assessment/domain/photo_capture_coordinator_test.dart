import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';
import '../fakes/fakes.dart';
import '../fakes/image_bytes.dart';

void main() {
  late ScriptedCaptureAdapter adapter;
  late InMemoryStagingStore staging;
  late PhotoCaptureCoordinator coordinator;

  setUp(() {
    adapter = ScriptedCaptureAdapter();
    staging = InMemoryStagingStore();
    coordinator = PhotoCaptureCoordinator(adapter: adapter, staging: staging);
  });

  CaptureSucceeded validPhoto() =>
      CaptureSucceeded(jpegHeader(width: 4032, height: 3024));

  test('a valid photo is validated and staged', () async {
    adapter.enqueue(validPhoto());
    final PhotoOutcome outcome = await coordinator.capture(bathroomOverview);

    expect(outcome, isA<PhotoStaged>());
    final StagedImage staged = (outcome as PhotoStaged).image;
    expect(staged.format, SupportedImageFormat.jpeg);
    expect((staged.width, staged.height), (4032, 3024));
    expect(staged.key.value, isNot(contains('evidence')));
    expect(await staging.keys(), [staged.key]);
    expect(adapter.requests.single.promptId, 'bathroom-overview');
  });

  test('cancelling keeps nothing new and is not an error', () async {
    adapter.enqueue(const CaptureCancelled());
    expect(await coordinator.capture(bathroomOverview), isA<PhotoKept>());
    expect(await staging.keys(), isEmpty);
  });

  group('retake', () {
    test('a successful retake discards the replaced photo', () async {
      adapter.enqueue(validPhoto());
      final StagedImage first =
          (await coordinator.capture(bathroomOverview) as PhotoStaged).image;

      adapter.enqueue(validPhoto());
      final PhotoOutcome outcome = await coordinator.capture(
        bathroomOverview,
        replacing: first.key,
      );

      final StagedImage second = (outcome as PhotoStaged).image;
      expect(outcome.replaced, first.key);
      expect(second.key, isNot(first.key));
      expect(await staging.keys(), [second.key]);
    });

    test('a cancelled retake keeps the original photo', () async {
      adapter.enqueue(validPhoto());
      final StagedImage first =
          (await coordinator.capture(bathroomOverview) as PhotoStaged).image;

      adapter.enqueue(const CaptureCancelled());
      expect(
        await coordinator.capture(bathroomOverview, replacing: first.key),
        isA<PhotoKept>(),
      );
      expect(await staging.keys(), [first.key]);
    });

    test('a rejected retake keeps the original photo', () async {
      adapter.enqueue(validPhoto());
      final StagedImage first =
          (await coordinator.capture(bathroomOverview) as PhotoStaged).image;

      adapter.enqueue(CaptureSucceeded(ftypHeader('heic')));
      final PhotoOutcome outcome = await coordinator.capture(
        bathroomOverview,
        replacing: first.key,
      );
      expect((outcome as PhotoRejected).reason, ImageRejection.heif);
      expect(await staging.keys(), [first.key]);
    });
  });

  group('permissions', () {
    test('a permanent denial stops relaunching the camera', () async {
      adapter.enqueue(const CapturePermissionDenied(canAskAgain: false));
      final PhotoOutcome first = await coordinator.capture(bathroomOverview);
      expect((first as PhotoPermissionBlocked).canAskAgain, isFalse);
      expect(coordinator.permissionBlocked, isTrue);

      final PhotoOutcome second = await coordinator.capture(bathroomOverview);
      expect(second, isA<PhotoPermissionBlocked>());
      expect(
        adapter.requests,
        hasLength(1),
        reason: 'camera must not be relaunched',
      );
    });

    test('returning from Settings allows one new attempt', () async {
      adapter.enqueue(const CapturePermissionDenied(canAskAgain: false));
      await coordinator.capture(bathroomOverview);

      coordinator.permissionMayHaveChanged();
      adapter.enqueue(validPhoto());
      expect(await coordinator.capture(bathroomOverview), isA<PhotoStaged>());
      expect(adapter.requests, hasLength(2));
    });

    test('a denial that can be asked again does not block', () async {
      adapter.enqueue(const CapturePermissionDenied(canAskAgain: true));
      final PhotoOutcome outcome = await coordinator.capture(bathroomOverview);
      expect((outcome as PhotoPermissionBlocked).canAskAgain, isTrue);
      expect(coordinator.permissionBlocked, isFalse);
    });
  });

  group('failures', () {
    test('unsupported image is rejected and not staged', () async {
      adapter.enqueue(CaptureSucceeded(ftypHeader('heic')));
      final PhotoOutcome outcome = await coordinator.capture(bathroomOverview);
      expect((outcome as PhotoRejected).reason, ImageRejection.heif);
      expect(await staging.keys(), isEmpty);
    });

    test('camera unavailable', () async {
      adapter.enqueue(const CaptureUnavailable());
      expect(
        await coordinator.capture(bathroomOverview),
        isA<PhotoUnavailable>(),
      );
    });

    test('adapter failure code passes through', () async {
      adapter.enqueue(const CaptureFailed('camera_interrupted'));
      final PhotoOutcome outcome = await coordinator.capture(bathroomOverview);
      expect((outcome as PhotoFailed).code, 'camera_interrupted');
    });

    test('a thrown adapter error becomes a safe failure', () async {
      adapter.enqueueError();
      final PhotoOutcome outcome = await coordinator.capture(bathroomOverview);
      expect((outcome as PhotoFailed).code, PhotoFailed.adapterError);
      expect(coordinator.isBusy, isFalse);
    });

    test('a staging error becomes a safe failure', () async {
      final failing = PhotoCaptureCoordinator(
        adapter: adapter,
        staging: FailingStagingStore(),
      );
      adapter.enqueue(validPhoto());
      final PhotoOutcome outcome = await failing.capture(bathroomOverview);
      expect((outcome as PhotoFailed).code, PhotoFailed.stagingError);
    });
  });

  test('a second capture while one is open is refused', () async {
    final pending = Completer<CaptureResult>();
    adapter.enqueueFuture(pending.future);

    final Future<PhotoOutcome> first = coordinator.capture(bathroomOverview);
    expect(coordinator.isBusy, isTrue);

    final PhotoOutcome second = await coordinator.capture(bathroomOverview);
    expect((second as PhotoFailed).code, PhotoFailed.busy);
    expect(adapter.requests, hasLength(1));

    pending.complete(const CaptureCancelled());
    expect(await first, isA<PhotoKept>());
    expect(coordinator.isBusy, isFalse);
  });

  test('remove and discardAll clean up staged photos', () async {
    adapter
      ..enqueue(validPhoto())
      ..enqueue(validPhoto())
      ..enqueue(validPhoto());
    final StagedImage a =
        (await coordinator.capture(bathroomOverview) as PhotoStaged).image;
    await coordinator.capture(bathroomOverview);
    await coordinator.capture(bathroomOverview);

    await coordinator.remove(a.key);
    expect(await staging.keys(), hasLength(2));

    expect(await coordinator.discardAll(), 2);
    expect(await staging.keys(), isEmpty);
  });

  test('staged bytes are a private copy', () async {
    final Uint8List bytes = jpegHeader(width: 10, height: 10);
    adapter.enqueue(CaptureSucceeded(bytes));
    final StagedImage staged =
        (await coordinator.capture(bathroomOverview) as PhotoStaged).image;

    bytes[0] = 0x00;
    final Uint8List? stored = await staging.read(staged.key);
    expect(stored![0], 0xFF);
  });
}
