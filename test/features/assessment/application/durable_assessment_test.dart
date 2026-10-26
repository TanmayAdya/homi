import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/application/encrypted_staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/length_unit.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/measurement_input.dart';
import 'package:safe_at_home/features/assessment/domain/review/finding_review_state.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import '../fakes/fakes.dart';

class _Secrets implements SecretValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

MeasurementInput input(String raw, LengthUnit unit) =>
    (const MeasurementParser(DecimalSeparator.comma).parse(raw, unit)
            as LengthParsed)
        .input;
CaseSnapshot snapshot(AssessmentController c) => CaseSnapshot.fromJson({
  'schemaVersion': '1',
  'caseId': 'case-1',
  'revision': 4,
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
  'findings': c.findings.map((f) => f.toJson()).toList(),
});
void main() {
  test(
    'editing an existing other-room concern preserves custom measurements',
    () {
      final c = AssessmentController(ids: SequentialIdFactory());
      final id = c.startFinding(AssessmentArea.other);
      c.setObservation(id, 'Indoor stairs');
      final wire = snapshot(c).toJson();
      (wire['findings'] as List).single['measurements'] = [
        {
          'type': 'customStepHeight',
          'value': 170,
          'unit': 'mm',
          'method': 'manual',
          'confirmed': false,
        },
      ];
      c.hydrate(CaseSnapshot.fromJson(wire), evidenceVersions: {});
      final staging = InMemoryStagingStore();
      final flow = AssessmentFlow(
        controller: c,
        capture: PhotoCaptureCoordinator(
          adapter: ScriptedCaptureAdapter(),
          staging: staging,
        ),
        staging: staging,
      );
      flow.openFinding(id);
      flow.edit();
      flow.setObservationText(
        'Indoor stairs are difficult to use without a handrail.',
      );
      expect(flow.saveDetails(), isTrue);
      c.confirmDisplayedRecord(id);
      expect(
        c.findings.single.measurements.single.toJson(),
        (wire['findings'] as List).single['measurements'].single,
      );
      expect(c.findings.single.room, 'other');
      flow.dispose();
      c.dispose();
    },
  );
  test(
    'stairs and other-area concerns survive local and cross-device resume',
    () {
      final c = AssessmentController(ids: SequentialIdFactory());
      final id = c.startFinding(AssessmentArea.other);
      c.setObservation(id, 'The indoor stairs have no handrail.');
      c.confirmDisplayedRecord(id);
      final restored = AssessmentController(ids: SequentialIdFactory());
      restored.restoreLocal(c.toLocalJson());
      expect(restored.draftOf(id)!.area, AssessmentArea.other);
      restored.hydrate(
        snapshot(c),
        evidenceVersions: {},
        metadata: c.metadataFor(c.findings),
      );
      expect(restored.toFinding(id)!.toJson(), c.toFinding(id)!.toJson());
      expect(restored.draftOf(id)!.area, AssessmentArea.other);
    },
  );

  test(
    'combined review leaves unavailable original measurements unverified',
    () {
      final c = AssessmentController(ids: SequentialIdFactory());
      final id = c.startFinding(AssessmentArea.entrance);
      c.setObservation(id, 'Threshold');
      c.setMeasurement(id, 'thresholdHeight', input('2', LengthUnit.inch));
      final restored = AssessmentController(ids: SequentialIdFactory());
      restored.hydrate(snapshot(c), evidenceVersions: {});
      restored.confirmDisplayedRecord(id);
      expect(restored.toFinding(id)!.reviewState, 'confirmed');
      expect(restored.toFinding(id)!.measurements.single.confirmed, isFalse);
    },
  );
  test(
    'restoring a private draft preserves original entry, correction and review histories',
    () {
      final c = AssessmentController(ids: SequentialIdFactory());
      final id = c.startFinding(AssessmentArea.entrance);
      c.setObservation(id, 'Door clear opening');
      c.setMeasurement(id, 'clearOpening', input(' 01,5 ', LengthUnit.metre));
      c.setMeasurement(id, 'clearOpening', input('1,6', LengthUnit.metre));
      c.confirmMeasurement(id, 'clearOpening');
      c.confirm(id);
      final restored = AssessmentController(ids: SequentialIdFactory());
      restored.restoreLocal(
        Map<String, Object?>.from(
          jsonDecode(jsonEncode(c.toLocalJson())) as Map,
        ),
      );
      expect(
        restored.draftOf(id)!.measurementOf('clearOpening')!.input.originalText,
        '1,6',
      );
      expect(
        restored.draftOf(id)!.measurementOf('clearOpening')!.input.unit,
        LengthUnit.metre,
      );
      expect(
        restored
            .measurementHistoryOf(id, 'clearOpening')
            .single
            .previous
            .input
            .originalText,
        ' 01,5 ',
      );
      expect(
        restored.reviewOf(id)!.history.map((e) => e.kind),
        c.reviewOf(id)!.history.map((e) => e.kind),
      );
      expect(restored.toFinding(id)!.toJson(), c.toFinding(id)!.toJson());
    },
  );

  test(
    'cross-device hydration joins metadata by finding and type without inventing original units',
    () {
      final c = AssessmentController(ids: SequentialIdFactory());
      final id = c.startFinding(AssessmentArea.entrance);
      c.setObservation(id, 'Threshold');
      c.setMeasurement(id, 'thresholdHeight', input('01,5', LengthUnit.inch));
      final saved = snapshot(c);
      final restored = AssessmentController(ids: SequentialIdFactory());
      restored.hydrate(
        saved,
        evidenceVersions: {},
        metadata: c.metadataFor(c.findings),
      );
      final m = restored.draftOf(id)!.measurementOf('thresholdHeight')!;
      expect(m.input.originalText, '01,5');
      expect(m.input.unit, LengthUnit.inch);
      expect(m.input.millimetres, 38.1);
      expect(m.recordedAt, isNotNull);
      restored.hydrate(saved, evidenceVersions: {});
      expect(
        restored
            .draftOf(id)!
            .measurementOf('thresholdHeight')!
            .originalInputKnown,
        isFalse,
      );
      final metadata =
          restored.metadataFor(restored.findings)['measurements'] as List;
      expect((metadata.single as Map)['source'], 'legacy_unknown');
      expect(metadata.single['originalText'], isNull);
    },
  );

  test('missing saved evidence invalidates confirmation on hydration', () {
    final c = AssessmentController(ids: SequentialIdFactory());
    final id = c.startFinding(AssessmentArea.bathroom);
    c.setObservation(id, 'A possible obstruction');
    c.addEvidence(id, version: 'staged');
    c.confirm(id);
    final restored = AssessmentController(ids: SequentialIdFactory());
    restored.hydrate(snapshot(c), evidenceVersions: {});
    expect(restored.reviewOf(id)!.state, FindingReviewState.needsReview);
  });

  test(
    'encrypted staged photos survive restart and remain isolated by case/account',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sah-assessment-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final secrets = _Secrets();
      LocalPrivateStore store(String account) => LocalPrivateStore(
        directory: directory,
        accountId: account,
        secrets: secrets,
      );
      final first = EncryptedStagingStore(
        store('resident-a'),
        caseId: 'case-1',
      );
      final bytes = Uint8List.fromList(
        utf8.encode('fictional private image content'),
      );
      final photo = await first.put(
        bytes,
        ImageAccepted(
          format: SupportedImageFormat.jpeg,
          width: 100,
          height: 100,
          byteLength: bytes.length,
        ),
        capturedAt: '2026-10-22T10:00:00.000Z',
        orientationNormalized: true,
      );
      final resumed = EncryptedStagingStore(
        store('resident-a'),
        caseId: 'case-1',
      );
      expect(await resumed.read(photo.key), bytes);
      expect(
        await EncryptedStagingStore(
          store('resident-a'),
          caseId: 'case-2',
        ).read(photo.key),
        isNull,
      );
      expect(
        await EncryptedStagingStore(
          store('resident-b'),
          caseId: 'case-1',
        ).read(photo.key),
        isNull,
      );
      final disk = await directory
          .list()
          .where((e) => e is File)
          .cast<File>()
          .first;
      expect(
        await disk.readAsString(),
        isNot(contains('fictional private image content')),
      );
      await resumed.discardAll();
      expect(await resumed.read(photo.key), isNull);
    },
  );
}
