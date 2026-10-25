import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import '../fakes/fakes.dart';
import '../fakes/image_bytes.dart';

class _ReadingStore extends InMemoryStagingStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool fail = false, missing = false;
  @override
  Future<Uint8List?> read(StagingKey key) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    if (fail) throw StateError('Synthetic unreadable private photo');
    return missing ? null : super.read(key);
  }
}

void main() {
  late _ReadingStore staging;
  late ScriptedCaptureAdapter adapter;
  late AssessmentController controller;
  late AssessmentFlow flow;
  setUp(() {
    staging = _ReadingStore();
    adapter = ScriptedCaptureAdapter()
      ..enqueue(CaptureSucceeded(pngHeader(width: 800, height: 600)));
    controller = AssessmentController(ids: SequentialIdFactory());
    flow = AssessmentFlow(
      controller: controller,
      capture: PhotoCaptureCoordinator(adapter: adapter, staging: staging),
      staging: staging,
    );
    flow.chooseArea(AssessmentArea.entrance);
  });
  test(
    'capture stays busy until encrypted preview read ends, blocking reset and duplicate capture',
    () async {
      final capture = flow.openCamera();
      await staging.entered.future;
      final finding = flow.findingId;
      expect(flow.isBusy, isTrue);
      expect(flow.canGoBack, isFalse);
      flow.back();
      flow.startAnother();
      await flow.discardFinding();
      await flow.openCamera();
      expect(flow.findingId, finding);
      expect(adapter.requests, hasLength(1));
      staging.release.complete();
      await capture;
      expect(flow.isBusy, isFalse);
      expect(flow.step, AssessmentStep.preview);
      expect(flow.bytesFor(flow.previewEvidenceId!), isNotNull);
    },
  );
  for (final missing in [false, true]) {
    test(
      'preview ${missing ? 'missing bytes' : 'read failure'} leaves an attached photo and releases busy for retry',
      () async {
        staging.fail = !missing;
        staging.missing = missing;
        final capture = flow.openCamera();
        await staging.entered.future;
        staging.release.complete();
        await capture;
        expect(flow.isBusy, isFalse);
        expect(flow.step, AssessmentStep.preview);
        expect(flow.notice, isA<PhotoPreviewUnavailableNotice>());
        expect(flow.evidence[flow.previewEvidenceId!], isNotNull);
        staging.fail = false;
        staging.missing = false;
        await flow.loadBytes(flow.previewEvidenceId!);
        expect(flow.bytesFor(flow.previewEvidenceId!), isNotNull);
      },
    );
  }
  test(
    'disposal during preview read does not navigate or notify a dead route',
    () async {
      final capture = flow.openCamera();
      await staging.entered.future;
      final stepBeforeDisposal = flow.step;
      flow.dispose();
      staging.release.complete();
      await capture;
      expect(flow.isBusy, isFalse);
      expect(flow.step, stepBeforeDisposal);
    },
  );
  test(
    'retake read failure cannot display the previous photo as the new image',
    () async {
      staging.release.complete();
      await flow.openCamera();
      final id = flow.previewEvidenceId!;
      expect(flow.bytesFor(id), isNotNull);
      staging.fail = true;
      adapter.enqueue(CaptureSucceeded(pngHeader(width: 400, height: 300)));
      await flow.openCamera(retake: true);
      expect(flow.previewEvidenceId, id);
      expect(flow.evidence[id]!.width, 400);
      expect(flow.bytesFor(id), isNull);
      expect(flow.notice, isA<PhotoPreviewUnavailableNotice>());
    },
  );
}
