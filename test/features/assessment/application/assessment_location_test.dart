import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/shared/models/contracts.dart';

import '../fakes/fakes.dart';

AssessmentFlow flowFor(AssessmentController controller) {
  final staging = InMemoryStagingStore();
  return AssessmentFlow(
    controller: controller,
    capture: PhotoCaptureCoordinator(
      adapter: ScriptedCaptureAdapter(),
      staging: staging,
    ),
    staging: staging,
  );
}

CaseSnapshot snapshot(AssessmentController controller) =>
    CaseSnapshot.fromJson({
      'schemaVersion': '1',
      'caseId': 'fictional-case',
      'revision': 1,
      'profile': {
        'city': null,
        'county': null,
        'healthPlan': null,
        'tenure': null,
        'ageYears': null,
        'householdSize': null,
        'annualIncomeUsd': null,
        'ownerConsentReported': null,
      },
      'unresolvedFields': <String>[],
      'findings': controller.findings.map((f) => f.toJson()).toList(),
    });

void main() {
  for (final location in AssessmentLocation.values) {
    test('${location.name} survives local and cross-device resume', () {
      final controller = AssessmentController(ids: SequentialIdFactory());
      final flow = flowFor(controller);
      addTearDown(flow.dispose);
      addTearDown(controller.dispose);
      flow.chooseLocation(location);
      flow.continueWithoutPhoto();
      expect(flow.saveDetails(), false);
      expect(controller.findings, isEmpty);
      flow.setObservationText('Getting around this area is difficult.');

      final restoredController = AssessmentController(
        ids: SequentialIdFactory(),
      )..restoreLocal(controller.toLocalJson());
      final restored = flowFor(restoredController)
        ..restoreLocal(flow.toLocalJson());
      addTearDown(restored.dispose);
      addTearDown(restoredController.dispose);
      expect(restored.location, location);
      expect(
        restored.observationText,
        'Getting around this area is difficult.',
      );
      expect(restored.saveDetails(), true);
      final saved = restoredController.findings.single;
      expect(saved.room, location.area.roomWireValue);
      expect(
        saved.observation,
        location.area == AssessmentArea.other
            ? '${location.title}: Getting around this area is difficult.'
            : 'Getting around this area is difficult.',
      );

      final remoteController = AssessmentController(ids: SequentialIdFactory())
        ..hydrate(snapshot(restoredController), evidenceVersions: {});
      final remote = flowFor(remoteController)..openFinding(saved.id);
      addTearDown(remote.dispose);
      addTearDown(remoteController.dispose);
      expect(remote.location, location);
      expect(remote.observationText, 'Getting around this area is difficult.');
      remote.edit();
      expect(remote.saveDetails(), true);
      expect(remoteController.findings.single.observation, saved.observation);
      remote.edit();
      remote.setObservationText('I would like help here.');
      expect(remote.saveDetails(), true);
      expect(
        remoteController.findings.single.observation,
        location.area == AssessmentArea.other
            ? '${location.title}: I would like help here.'
            : 'I would like help here.',
      );
    });
  }

  test('unrecognized legacy descriptions remain intact', () {
    final controller = AssessmentController(ids: SequentialIdFactory());
    final id = controller.startFinding(AssessmentArea.other);
    const description = 'Upstairs landing: The area by the door is narrow.';
    controller.setObservation(id, description);
    final flow = flowFor(controller)..openFinding(id);
    addTearDown(flow.dispose);
    addTearDown(controller.dispose);
    expect(flow.location, isNull);
    expect(flow.observationText, description);
    flow.edit();
    expect(flow.saveDetails(), true);
    expect(controller.findings.single.observation, description);
    final legacy = flow.toLocalJson()..remove('location');
    flow.restoreLocal(legacy);
    expect(flow.location, isNull);
    expect(flow.observationText, description);
  });

  test('local recovery rejects a location bound to another area', () {
    final controller = AssessmentController(ids: SequentialIdFactory());
    final flow = flowFor(controller)
      ..chooseLocation(AssessmentLocation.kitchen);
    addTearDown(flow.dispose);
    addTearDown(controller.dispose);
    final malformed = flow.toLocalJson()..['area'] = 'bathroom';
    expect(() => flow.restoreLocal(malformed), throwsFormatException);
  });
}
