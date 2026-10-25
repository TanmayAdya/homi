import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';
import '../fakes/fakes.dart';
import '../fakes/image_bytes.dart';

class _DelayedStaging extends InMemoryStagingStore {
  Completer<void>? gate;
  bool failDiscard = false;
  @override
  Future<StagedImage> put(
    Uint8List bytes,
    ImageAccepted info, {
    String? capturedAt,
    bool orientationNormalized = false,
  }) async {
    if (gate != null) await gate!.future;
    return super.put(
      bytes,
      info,
      capturedAt: capturedAt,
      orientationNormalized: orientationNormalized,
    );
  }

  @override
  Future<bool> discard(StagingKey key) async {
    if (failDiscard) throw StateError('Synthetic storage cleanup failure');
    return super.discard(key);
  }
}

void main() {
  late _DelayedStaging staging;
  late AssessmentController controller;
  late AssessmentFlow flow;
  late String evidenceId;
  setUp(() async {
    staging = _DelayedStaging();
    controller = AssessmentController(ids: SequentialIdFactory());
    final adapter = ScriptedCaptureAdapter()
      ..enqueue(
        CaptureSucceeded(
          pngHeader(width: 800, height: 600),
          capturedAt: '2026-10-23T10:00:00Z',
        ),
      );
    flow = AssessmentFlow(
      controller: controller,
      capture: PhotoCaptureCoordinator(adapter: adapter, staging: staging),
      staging: staging,
    );
    flow.chooseArea(AssessmentArea.entrance);
    await flow.openCamera();
    evidenceId = flow.previewEvidenceId!;
  });
  test(
    'a privacy replacement serializes navigation, deletion and duplicate apply',
    () async {
      final old = flow.evidence[evidenceId]!;
      staging.gate = Completer<void>();
      final pending = flow.applyProcessedPhoto(
        evidenceId,
        pngHeader(width: 500, height: 400),
      );
      expect(flow.isBusy, isTrue);
      flow.startAnother();
      await flow.discardFinding();
      flow.back();
      await flow.applyProcessedPhoto(
        evidenceId,
        pngHeader(width: 200, height: 200),
      );
      expect(flow.previewEvidenceId, evidenceId);
      staging.gate!.complete();
      await pending;
      expect(flow.isBusy, isFalse);
      expect(flow.evidence[evidenceId]!.width, 500);
      expect(flow.evidence[evidenceId]!.capturedAt, old.capturedAt);
      expect(await staging.read(old.key), isNull);
      expect(await staging.keys(), hasLength(1));
    },
  );
  test(
    'late encrypted replacement is discarded after route disposal',
    () async {
      final old = flow.evidence[evidenceId]!;
      staging.gate = Completer<void>();
      final pending = flow.applyProcessedPhoto(
        evidenceId,
        pngHeader(width: 500, height: 400),
      );
      flow.dispose();
      staging.gate!.complete();
      await pending;
      expect(flow.evidence[evidenceId]!.key, old.key);
      expect(await staging.keys(), [old.key]);
    },
  );
  test(
    'external finding removal during storage cannot reattach an edited image',
    () async {
      final old = flow.evidence[evidenceId]!;
      staging.gate = Completer<void>();
      final pending = flow.applyProcessedPhoto(
        evidenceId,
        pngHeader(width: 500, height: 400),
      );
      controller.removeFinding(flow.findingId!);
      staging.gate!.complete();
      await pending;
      expect(controller.drafts, isEmpty);
      expect(await staging.keys(), [old.key]);
      expect(flow.isBusy, isFalse);
    },
  );
  test(
    'old-copy cleanup failure does not report successful privacy editing as failed',
    () async {
      staging.failDiscard = true;
      await flow.applyProcessedPhoto(
        evidenceId,
        pngHeader(width: 500, height: 400),
      );
      expect(flow.evidence[evidenceId]!.width, 500);
      expect(flow.isBusy, isFalse);
    },
  );
  test(
    'storage failure retains original and releases busy state for retry',
    () async {
      final old = flow.evidence[evidenceId]!;
      staging.gate = Completer<void>();
      final pending = flow.applyProcessedPhoto(
        evidenceId,
        pngHeader(width: 500, height: 400),
      );
      final check = expectLater(pending, throwsStateError);
      staging.gate!.completeError(StateError('Synthetic storage failure'));
      await check;
      expect(flow.evidence[evidenceId]!.key, old.key);
      expect(flow.isBusy, isFalse);
    },
  );
}
