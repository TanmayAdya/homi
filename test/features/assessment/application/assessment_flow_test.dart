import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/domain/annotation/box_annotation.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/length_unit.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/measurement_input.dart';
import 'package:safe_at_home/features/assessment/domain/review/finding_review_state.dart';
import 'package:safe_at_home/shared/models/contracts.dart';

import '../fakes/fakes.dart';
import '../fakes/image_bytes.dart';

void main() {
  late ScriptedCaptureAdapter adapter;
  late InMemoryStagingStore staging;
  late AssessmentController controller;
  late AssessmentFlow flow;

  setUp(() {
    adapter = ScriptedCaptureAdapter();
    staging = InMemoryStagingStore();
    controller = AssessmentController(ids: SequentialIdFactory());
    flow = AssessmentFlow(
      controller: controller,
      capture: PhotoCaptureCoordinator(adapter: adapter, staging: staging),
      staging: staging,
    );
  });

  CaptureSucceeded photo([int width = 4032]) =>
      CaptureSucceeded(jpegHeader(width: width, height: 3024));

  Future<void> captureOne([CaptureResult? result]) async {
    adapter.enqueue(result ?? photo());
    await flow.openCamera();
  }

  Future<void> toDetails() async {
    flow.chooseArea(AssessmentArea.bathroom);
    await captureOne();
    flow.continueFromPreview();
  }

  test('a finding is created only once there is content', () async {
    flow.chooseArea(AssessmentArea.entrance);
    expect(flow.step, AssessmentStep.viewPrompt);
    expect(controller.drafts, isEmpty);
    flow.back();
    expect(flow.step, AssessmentStep.chooseArea);
    flow.chooseArea(AssessmentArea.bathroom);
    expect(flow.area, AssessmentArea.bathroom);
    expect(controller.drafts, isEmpty);
  });

  group('capture outcomes', () {
    test('a staged photo moves to preview and is attached', () async {
      flow.chooseArea(AssessmentArea.bathroom);
      await captureOne();
      expect(flow.step, AssessmentStep.preview);
      final String evidenceId = flow.previewEvidenceId!;
      expect(
        controller.draftOf(flow.findingId!)!.evidence.single.evidenceId,
        evidenceId,
      );
      expect(flow.bytesFor(evidenceId), isNotNull);
      expect(flow.evidence[evidenceId], isNotNull);
      expect(adapter.requests.single.promptId, 'bathroom-overview');
    });

    test(
      'cancelling stays on the prompt with a notice and no finding',
      () async {
        flow.chooseArea(AssessmentArea.bathroom);
        await captureOne(const CaptureCancelled());
        expect(flow.step, AssessmentStep.viewPrompt);
        expect(flow.notice, isA<CaptureCancelledNotice>());
        expect(controller.drafts, isEmpty);
      },
    );

    test('a retryable denial explains and allows another attempt', () async {
      flow.chooseArea(AssessmentArea.bathroom);
      await captureOne(const CapturePermissionDenied(canAskAgain: true));
      expect((flow.notice! as PermissionNotice).canAskAgain, isTrue);
      expect(flow.cameraBlocked, isFalse);
      await captureOne();
      expect(flow.step, AssessmentStep.preview);
    });

    test('a permanent denial does not relaunch the camera', () async {
      flow.chooseArea(AssessmentArea.bathroom);
      await captureOne(const CapturePermissionDenied(canAskAgain: false));
      expect(flow.cameraBlocked, isTrue);

      await flow.openCamera();
      expect(adapter.requests, hasLength(1));
      expect((flow.notice! as PermissionNotice).canAskAgain, isFalse);

      flow.permissionMayHaveChanged();
      expect(flow.notice, isNull);
      await captureOne();
      expect(adapter.requests, hasLength(2));
      expect(flow.step, AssessmentStep.preview);
    });

    test('no camera offers continuing without a photo', () async {
      flow.chooseArea(AssessmentArea.entrance);
      await captureOne(const CaptureUnavailable());
      expect(flow.notice, isA<CameraUnavailableNotice>());
      flow.continueWithoutPhoto();
      expect(flow.step, AssessmentStep.details);
      expect(controller.draftOf(flow.findingId!)!.evidence, isEmpty);
    });

    test('an unusable photo is explained and nothing is attached', () async {
      flow.chooseArea(AssessmentArea.entrance);
      await captureOne(CaptureSucceeded(ftypHeader('heic')));
      expect((flow.notice! as PhotoRejectedNotice).reason, ImageRejection.heif);
      expect(flow.step, AssessmentStep.viewPrompt);
      expect(await staging.keys(), isEmpty);
    });

    test('an adapter failure is reported without details', () async {
      flow.chooseArea(AssessmentArea.entrance);
      adapter.enqueueError();
      await flow.openCamera();
      expect(flow.notice, isA<CaptureFailedNotice>());
    });

    test('a second tap while the camera is open is ignored', () async {
      flow.chooseArea(AssessmentArea.entrance);
      final completer = Completer<CaptureResult>();
      adapter.enqueueFuture(completer.future);
      final Future<void> first = flow.openCamera();
      expect(flow.isBusy, isTrue);
      expect(flow.canGoBack, isFalse);
      await flow.openCamera();
      expect(adapter.requests, hasLength(1));
      completer.complete(photo());
      await first;
      expect(flow.isBusy, isFalse);
      expect(flow.step, AssessmentStep.preview);
    });

    test('a result arriving after dispose changes nothing', () async {
      flow.chooseArea(AssessmentArea.entrance);
      final completer = Completer<CaptureResult>();
      adapter.enqueueFuture(completer.future);
      final Future<void> pending = flow.openCamera();
      flow.dispose();
      completer.complete(photo());
      await pending;
      expect(controller.drafts, isEmpty);
      expect(await staging.keys(), isEmpty);
    });
  });

  group('preview', () {
    test(
      'retake replaces the photo, keeps the ID and the typed values',
      () async {
        await toDetails();
        flow.setObservationText('I notice a raised tub edge');
        flow.setMeasurementText('curbHeight', '45');
        flow.setMeasurementUnit('curbHeight', LengthUnit.centimetre);
        flow.back();
        expect(flow.step, AssessmentStep.preview);
        final String evidenceId = flow.previewEvidenceId!;
        final StagingKey oldKey = flow.evidence[evidenceId]!.key;

        adapter.enqueue(photo(3000));
        await flow.openCamera(retake: true);

        expect(flow.previewEvidenceId, evidenceId);
        expect(flow.evidence[evidenceId]!.key, isNot(oldKey));
        expect(await staging.read(oldKey), isNull);
        expect(flow.observationText, 'I notice a raised tub edge');
        expect(flow.entryFor('curbHeight').text, '45');
        expect(flow.entryFor('curbHeight').unit, LengthUnit.centimetre);
      },
    );

    test('a cancelled retake keeps the original photo', () async {
      flow.chooseArea(AssessmentArea.bathroom);
      await captureOne();
      final StagingKey key = flow.evidence[flow.previewEvidenceId!]!.key;
      adapter.enqueue(const CaptureCancelled());
      await flow.openCamera(retake: true);
      expect(flow.evidence[flow.previewEvidenceId!]!.key, key);
      expect(flow.notice, isA<CaptureCancelledNotice>());
    });

    test('remove detaches the photo and discards its staged copy', () async {
      flow.chooseArea(AssessmentArea.bathroom);
      await captureOne();
      final String evidenceId = flow.previewEvidenceId!;
      await flow.removePreviewPhoto();
      expect(flow.step, AssessmentStep.viewPrompt);
      expect(flow.notice, isA<PhotoRemovedNotice>());
      expect(controller.draftOf(flow.findingId!)!.evidence, isEmpty);
      expect(flow.evidence[evidenceId], isNull);
      expect(await staging.keys(), isEmpty);
    });

    test('a close-up is a second photo on the same finding', () async {
      flow.chooseArea(AssessmentArea.entrance);
      await captureOne();
      final String first = flow.previewEvidenceId!;
      flow.addCloseUp();
      await captureOne();
      expect(adapter.requests.last.view, CaptureView.closeUp);
      expect(controller.draftOf(flow.findingId!)!.evidence, hasLength(2));

      flow.back();
      flow.back();
      expect(flow.step, AssessmentStep.preview);
      expect(flow.previewEvidenceId, first);
    });

    test('back skips a preview whose photo was removed', () async {
      flow.chooseArea(AssessmentArea.entrance);
      await captureOne();
      flow.addCloseUp();
      await captureOne();
      flow.back();
      flow.back();
      await flow.removePreviewPhoto();
      expect(flow.step, AssessmentStep.viewPrompt);
      flow.back();
      expect(flow.step, isNot(AssessmentStep.preview));
    });
  });

  group('details', () {
    test('an observation is required', () async {
      await toDetails();
      expect(flow.saveDetails(), isFalse);
      expect(flow.errors.observationMissing, isTrue);
      flow.setObservationText('I notice a raised edge');
      expect(flow.errors.observationMissing, isFalse);
    });

    test('empty measurement fields stay unknown', () async {
      await toDetails();
      flow.setObservationText('I notice a raised edge');
      expect(flow.saveDetails(), isTrue);
      expect(flow.step, AssessmentStep.review);
      expect(controller.toFinding(flow.findingId!)!.measurements, isEmpty);
    });

    test(
      'invalid input is reported per field and nothing is applied',
      () async {
        await toDetails();
        flow.setObservationText('I notice a raised edge');
        flow.setMeasurementText('curbHeight', '1,5');
        flow.setMeasurementText('clearOpening', '-3');
        expect(flow.saveDetails(), isFalse);
        expect(flow.errors.measurements, {
          'curbHeight': LengthParseError.unexpectedSeparator,
          'clearOpening': LengthParseError.negative,
        });
        expect(controller.toFinding(flow.findingId!), isNull);

        flow.setMeasurementText('curbHeight', '45');
        expect(flow.errors.measurements.keys, ['clearOpening']);
      },
    );

    test('values are converted and recorded with their method', () async {
      await toDetails();
      flow
        ..setObservationText('I notice a raised edge')
        ..setMeasurementText('curbHeight', '45')
        ..setMeasurementUnit('curbHeight', LengthUnit.centimetre)
        ..setMeasurementText('clearOpening', '30')
        ..setMeasurementUnit('clearOpening', LengthUnit.inch)
        ..setMeasurementMethod('clearOpening', MeasurementMethod.estimated);
      expect(flow.saveDetails(), isTrue);
      final List<Measurement> m = controller
          .toFinding(flow.findingId!)!
          .measurements;
      expect(m.map((e) => (e.type, e.value, e.method)), [
        ('curbHeight', 450, 'manual'),
        ('clearOpening', 762, 'estimated'),
      ]);
    });

    test('clearing a field later removes the measurement', () async {
      await toDetails();
      flow
        ..setObservationText('I notice a raised edge')
        ..setMeasurementText('curbHeight', '45');
      flow.saveDetails();
      flow.edit();
      flow.setMeasurementText('curbHeight', '  ');
      flow.saveDetails();
      expect(controller.toFinding(flow.findingId!)!.measurements, isEmpty);
    });

    test('comma-decimal locales parse with their own separator', () async {
      flow = AssessmentFlow(
        controller: controller,
        capture: PhotoCaptureCoordinator(adapter: adapter, staging: staging),
        staging: staging,
        decimalSeparator: DecimalSeparator.comma,
      );
      await toDetails();
      flow
        ..setObservationText('I notice a raised edge')
        ..setMeasurementText('curbHeight', '4,5')
        ..setMeasurementUnit('curbHeight', LengthUnit.centimetre);
      expect(flow.saveDetails(), isTrue);
      expect(
        controller.toFinding(flow.findingId!)!.measurements.single.value,
        45,
      );
    });
  });

  group('review', () {
    Future<String> toReview() async {
      await toDetails();
      flow.setObservationText('I notice a raised edge');
      flow.saveDetails();
      return flow.findingId!;
    }

    test('editing returns to details with the typed text', () async {
      await toReview();
      flow.edit();
      expect(flow.step, AssessmentStep.details);
      expect(flow.observationText, 'I notice a raised edge');
    });

    test(
      'requesting another view withdraws confirmation and prompts a close-up',
      () async {
        final String id = await toReview();
        controller.confirm(id);
        flow.requestAnotherView();
        expect(controller.reviewOf(id)!.state, FindingReviewState.needsReview);
        expect(flow.step, AssessmentStep.viewPrompt);
        expect(flow.view, CaptureView.closeUp);
        flow.back();
        expect(flow.step, AssessmentStep.review);
      },
    );

    test('a dismissed finding cannot request another view', () async {
      final String id = await toReview();
      controller.dismiss(id);
      flow.requestAnotherView();
      expect(flow.step, AssessmentStep.review);
    });

    test('start another keeps the finding and its staged photo', () async {
      final String id = await toReview();
      flow.startAnother();
      expect(flow.step, AssessmentStep.chooseArea);
      expect(flow.findingId, isNull);
      expect(flow.observationText, isEmpty);
      expect(controller.draftOf(id), isNotNull);
      expect(await staging.keys(), hasLength(1));
    });

    test('discard removes the finding and its staged photos', () async {
      final String id = await toReview();
      await flow.discardFinding();
      expect(controller.draftOf(id), isNull);
      expect(await staging.keys(), isEmpty);
      expect(flow.evidence.evidenceIds, isEmpty);
      expect(flow.step, AssessmentStep.chooseArea);
    });
  });

  group('annotations', () {
    late AnnotationStore annotations;

    setUp(() {
      var n = 0;
      annotations = AnnotationStore(newId: () => 'box-${++n}');
      flow = AssessmentFlow(
        controller: controller,
        capture: PhotoCaptureCoordinator(adapter: adapter, staging: staging),
        staging: staging,
        annotations: annotations,
      );
    });

    CaptureSucceeded png() =>
        CaptureSucceeded(pngHeader(width: 1200, height: 900));

    test('only images with known orientation can be marked', () async {
      flow.chooseArea(AssessmentArea.entrance);
      await captureOne();
      expect(flow.annotatableImage(flow.previewEvidenceId!), isNull);

      flow.addCloseUp();
      await captureOne(png());
      final AnnotatedImage image = flow.annotatableImage(
        flow.previewEvidenceId!,
      )!;
      expect((image.width, image.height), (1200, 900));
      expect(image.version, startsWith('local:'));
    });

    test('a retake makes earlier boxes stale', () async {
      flow.chooseArea(AssessmentArea.entrance);
      await captureOne(png());
      final String evidenceId = flow.previewEvidenceId!;
      final BoxAnnotation box = annotations.add(
        findingId: flow.findingId!,
        image: flow.annotatableImage(evidenceId)!,
      );

      adapter.enqueue(png());
      await flow.openCamera(retake: true);
      expect(annotations[box.id]!.stale, isTrue);
      expect(annotations.on(flow.annotatableImage(evidenceId)!), isEmpty);
    });

    test('a cancelled retake keeps boxes current', () async {
      flow.chooseArea(AssessmentArea.entrance);
      await captureOne(png());
      final BoxAnnotation box = annotations.add(
        findingId: flow.findingId!,
        image: flow.annotatableImage(flow.previewEvidenceId!)!,
      );
      adapter.enqueue(const CaptureCancelled());
      await flow.openCamera(retake: true);
      expect(annotations[box.id]!.stale, isFalse);
    });

    test('removing the photo or the finding removes its boxes', () async {
      flow.chooseArea(AssessmentArea.entrance);
      await captureOne(png());
      annotations.add(
        findingId: flow.findingId!,
        image: flow.annotatableImage(flow.previewEvidenceId!)!,
      );
      await flow.removePreviewPhoto();
      expect(annotations.all, isEmpty);

      await captureOne(png());
      annotations.add(
        findingId: flow.findingId!,
        image: flow.annotatableImage(flow.previewEvidenceId!)!,
      );
      await flow.discardFinding();
      expect(annotations.all, isEmpty);
    });
  });

  group('reopening a finding', () {
    Future<String> makeFinding() async {
      flow.chooseArea(AssessmentArea.entrance);
      await captureOne();
      flow.continueFromPreview();
      flow
        ..setObservationText('I notice a raised threshold.')
        ..setMeasurementText('thresholdHeight', '1.5')
        ..setMeasurementUnit('thresholdHeight', LengthUnit.inch);
      flow.saveDetails();
      final String id = flow.findingId!;
      controller.confirm(id);
      flow.startAnother();
      return id;
    }

    test('loads the observation and measurements as typed', () async {
      final String id = await makeFinding();
      flow.openFinding(id);
      expect(flow.step, AssessmentStep.review);
      expect(flow.findingId, id);
      expect(flow.area, AssessmentArea.entrance);
      expect(flow.observationText, 'I notice a raised threshold.');
      expect(flow.entryFor('thresholdHeight').text, '1.5');
      expect(flow.entryFor('thresholdHeight').unit, LengthUnit.inch);
      expect(flow.entryFor('clearOpening').text, isEmpty);
    });

    test('saving unchanged details keeps the confirmation', () async {
      final String id = await makeFinding();
      flow.openFinding(id);
      flow.edit();
      expect(flow.saveDetails(), isTrue);
      expect(controller.reviewOf(id)!.state, FindingReviewState.confirmed);
    });

    test('a real edit withdraws the confirmation', () async {
      final String id = await makeFinding();
      flow.openFinding(id);
      flow.edit();
      flow.setMeasurementText('thresholdHeight', '1.25');
      flow.saveDetails();
      expect(controller.reviewOf(id)!.state, FindingReviewState.needsReview);
      expect(
        controller.measurementHistoryOf(id, 'thresholdHeight'),
        hasLength(1),
      );
    });

    test('back returns to the list and leaves the finding', () async {
      final String id = await makeFinding();
      flow.openFinding(id);
      flow.back();
      expect(flow.step, AssessmentStep.chooseArea);
      expect(flow.findingId, isNull);
      expect(flow.observationText, isEmpty);

      flow.chooseArea(AssessmentArea.bathroom);
      await captureOne();
      expect(flow.findingId, isNot(id));
      expect(controller.draftOf(id)!.evidence, hasLength(1));
    });

    test('text typed with another decimal mark is shown in this one', () async {
      final String id = controller.startFinding(AssessmentArea.entrance);
      controller.setObservation(id, 'I notice a step.');
      final LengthParseResult parsed = const MeasurementParser(
        DecimalSeparator.comma,
      ).parse('3,5', LengthUnit.centimetre);
      controller.setMeasurement(
        id,
        'thresholdHeight',
        (parsed as LengthParsed).input,
      );
      flow.openFinding(id);
      expect(flow.entryFor('thresholdHeight').text, '3.5');
      flow.edit();
      expect(flow.saveDetails(), isTrue);
      expect(
        controller.measurementHistoryOf(id, 'thresholdHeight'),
        isEmpty,
        reason: 'same value; only the decimal mark differs',
      );
    });

    test('an unknown finding or a busy camera is ignored', () async {
      flow.openFinding('nope');
      expect(flow.step, AssessmentStep.chooseArea);
    });
  });

  group('opening a photo from review', () {
    Future<(String, String)> atReview() async {
      flow.chooseArea(AssessmentArea.entrance);
      await captureOne();
      final String evidenceId = flow.previewEvidenceId!;
      flow.continueFromPreview();
      flow.setObservationText('I notice a raised threshold.');
      flow.saveDetails();
      return (flow.findingId!, evidenceId);
    }

    test('shows the photo on the preview step', () async {
      final (_, String evidenceId) = await atReview();
      flow.openPhoto(evidenceId);
      expect(flow.step, AssessmentStep.preview);
      expect(flow.previewEvidenceId, evidenceId);
      flow.back();
      expect(flow.step, AssessmentStep.review);
    });

    test('retake from there replaces the photo and keeps its ID', () async {
      final (String id, String evidenceId) = await atReview();
      controller.confirm(id);
      flow.openPhoto(evidenceId);
      adapter.enqueue(photo(3000));
      await flow.openCamera(retake: true);
      expect(controller.draftOf(id)!.evidence.single.evidenceId, evidenceId);
      expect(controller.reviewOf(id)!.state, FindingReviewState.needsReview);
    });

    test(
      'remove from there returns to review, not the removed photo',
      () async {
        final (String id, String evidenceId) = await atReview();
        flow.openPhoto(evidenceId);
        await flow.removePreviewPhoto();
        expect(flow.step, AssessmentStep.review);
        expect(controller.draftOf(id)!.evidence, isEmpty);
      },
    );

    test(
      'a photo already uploaded (no local copy) can still be retaken',
      () async {
        final (String id, String evidenceId) = await atReview();
        final StagingKey key = flow.evidence.remove(evidenceId)!.key;
        await staging.discard(key);

        flow.openPhoto(evidenceId);
        expect(flow.step, AssessmentStep.preview);
        adapter.enqueue(photo(3000));
        await flow.openCamera(retake: true);
        expect(flow.evidence[evidenceId], isNotNull);
        expect(controller.draftOf(id)!.evidence.single.evidenceId, evidenceId);
      },
    );

    test('only works on review and for attached photos', () async {
      final (_, String evidenceId) = await atReview();
      flow.openPhoto('evidence-99');
      expect(flow.step, AssessmentStep.review);
      flow.edit();
      flow.openPhoto(evidenceId);
      expect(flow.step, AssessmentStep.details);
    });
  });
}
