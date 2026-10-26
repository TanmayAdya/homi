import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/ids/id_factory.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/length_unit.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/measurement_input.dart';
import 'package:safe_at_home/features/assessment/domain/review/finding_review_state.dart';
import 'package:safe_at_home/features/assessment/domain/review/finding_review_tracker.dart';
import 'package:safe_at_home/features/assessment/domain/review/review_snapshot.dart';
import 'package:safe_at_home/shared/models/contracts.dart';

import '../fakes/fakes.dart';
import '../support/v1_case_schema.dart';

MeasurementInput _input(
  String text, [
  LengthUnit unit = LengthUnit.millimetre,
  DecimalSeparator separator = DecimalSeparator.point,
]) {
  final LengthParseResult result = MeasurementParser(
    separator,
  ).parse(text, unit);
  if (result is! LengthParsed) throw StateError('Test input did not parse');
  return result.input;
}

class _ListIdFactory implements IdFactory {
  _ListIdFactory({this.findings = const [], this.evidence = const []});
  final List<String> findings;
  final List<String> evidence;
  int _f = 0;
  int _e = 0;

  @override
  String newFindingId() => findings[_f++];

  @override
  String newEvidenceId() => evidence[_e++];
}

void main() {
  late AssessmentController controller;

  setUp(() {
    controller = AssessmentController(ids: SequentialIdFactory());
  });

  FindingReviewState stateOf(String id) => controller.reviewOf(id)!.state;

  test(
    'one explicit review checks entered measurements without changing their methods',
    () {
      final id = controller.startFinding(AssessmentArea.entrance);
      controller.setObservation(
        id,
        'A raised threshold makes entry difficult.',
      );
      controller.setMeasurement(
        id,
        'thresholdHeight',
        _input('2', LengthUnit.inch),
      );
      controller.setMeasurement(
        id,
        'clearOpening',
        _input('80', LengthUnit.centimetre),
        method: MeasurementMethod.estimated,
      );
      expect(controller.confirmDisplayedRecord(id).applied, isTrue);
      final finding = controller.toFinding(id)!;
      expect(finding.measurements.every((m) => m.confirmed), isTrue);
      expect(finding.measurements.map((m) => m.method), [
        'manual',
        'estimated',
      ]);
      expect(stateOf(id), FindingReviewState.confirmed);
      controller.setMeasurement(
        id,
        'thresholdHeight',
        _input('3', LengthUnit.inch),
      );
      expect(stateOf(id), FindingReviewState.needsReview);
      expect(controller.toFinding(id)!.measurements.first.confirmed, isFalse);
    },
  );

  test('failed or dismissed review does not confirm measurements', () {
    final id = controller.startFinding(AssessmentArea.entrance);
    controller.setMeasurement(id, 'thresholdHeight', _input('20'));
    expect(controller.confirmDisplayedRecord(id).applied, isFalse);
    expect(controller.draftOf(id)!.measurements.single.confirmed, isFalse);
    controller.setObservation(id, 'Threshold');
    controller.dismiss(id);
    expect(controller.confirmDisplayedRecord(id).applied, isFalse);
    expect(controller.draftOf(id)!.measurements.single.confirmed, isFalse);
  });

  String entranceFinding() {
    final String id = controller.startFinding(AssessmentArea.entrance);
    controller.setObservation(id, 'I notice a raised threshold');
    controller.addEvidence(id, version: 'staged-1');
    return id;
  }

  group('IDs', () {
    test('come only from the injected factory, in order', () {
      final String a = controller.startFinding(AssessmentArea.bathroom);
      final String b = controller.startFinding(AssessmentArea.entrance);
      expect([a, b], ['finding-1', 'finding-2']);
      expect(controller.addEvidence(a, version: 's1'), 'evidence-1');
      expect(controller.addEvidence(b, version: 's2'), 'evidence-2');
    });

    test('stay the same through edits, replacement and review', () {
      final String id = entranceFinding();
      final String evidenceId = controller
          .draftOf(id)!
          .evidence
          .single
          .evidenceId;
      controller
        ..setObservation(id, 'I notice a raised threshold at the door')
        ..replaceEvidence(id, evidenceId, version: 'staged-2')
        ..setMeasurement(id, 'thresholdHeight', _input('20'))
        ..confirm(id);
      final Finding finding = controller.toFinding(id)!;
      expect(finding.id, id);
      expect(finding.evidenceIds, [evidenceId]);
    });

    test('an ID outside the shared ID rules is rejected', () {
      final c = AssessmentController(
        ids: _ListIdFactory(findings: [' finding-1']),
      );
      expect(
        () => c.startFinding(AssessmentArea.bathroom),
        throwsFormatException,
      );
    });

    test('a repeated finding ID is rejected, even after removal', () {
      final c = AssessmentController(
        ids: _ListIdFactory(findings: ['f-1', 'f-1']),
      );
      final String id = c.startFinding(AssessmentArea.bathroom);
      c.removeFinding(id);
      expect(() => c.startFinding(AssessmentArea.bathroom), throwsStateError);
    });

    test('a repeated evidence ID is rejected, even after removal', () {
      final c = AssessmentController(
        ids: _ListIdFactory(findings: ['f-1'], evidence: ['e-1', 'e-1']),
      );
      final String id = c.startFinding(AssessmentArea.bathroom);
      c.removeEvidence(id, c.addEvidence(id, version: 's1'));
      expect(() => c.addEvidence(id, version: 's2'), throwsStateError);
    });

    test('an unknown finding ID is an argument error', () {
      expect(() => controller.setObservation('nope', 'x'), throwsArgumentError);
      expect(() => controller.confirm('nope'), throwsArgumentError);
      expect(() => controller.toFinding('nope'), throwsArgumentError);
    });
  });

  group('v1 Finding output', () {
    test('has exactly the six v1 keys and satisfies the schema', () {
      final String id = entranceFinding();
      controller.setMeasurement(
        id,
        'thresholdHeight',
        _input('1.5', LengthUnit.inch),
      );
      final Map<String, Object?> json = controller.toFinding(id)!.toJson();

      expect(json.keys.toSet(), {
        'id',
        'room',
        'observation',
        'reviewState',
        'evidenceIds',
        'measurements',
      });
      expect(acceptsCaseDef(json, 'finding'), isTrue);
    });

    test('each measurement has exactly the five v1 keys', () {
      final String id = entranceFinding();
      controller.setMeasurement(
        id,
        'thresholdHeight',
        _input('1.5', LengthUnit.inch),
      );
      final List<Object?> measurements =
          controller.toFinding(id)!.toJson()['measurements']! as List<Object?>;
      expect(measurements.single, {
        'type': 'thresholdHeight',
        'value': 38.1,
        'unit': 'mm',
        'method': 'manual',
        'confirmed': false,
      });
      expect(acceptsCaseDef(measurements.single, 'measurement'), isTrue);
    });

    test('module-local details never appear in the JSON', () {
      final String id = entranceFinding();
      controller
        ..setMeasurement(
          id,
          'clearOpening',
          _input('80,5', LengthUnit.centimetre, DecimalSeparator.comma),
        )
        ..requestAnotherView(id);
      final String encoded = jsonEncode(controller.toFinding(id)!.toJson());
      for (final String leaked in [
        'originalText',
        'displayPrecision',
        'decimalSeparator',
        '80,5',
        '"cm"',
        'staged-1',
        'history',
        'anotherView',
        'snapshot',
      ]) {
        expect(encoded, isNot(contains(leaked)), reason: leaked);
      }
    });

    test('area maps to the v1 room value', () {
      final String b = controller.startFinding(AssessmentArea.bathroom);
      final String e = controller.startFinding(AssessmentArea.entrance);
      controller
        ..setObservation(b, 'x')
        ..setObservation(e, 'y');
      expect(controller.toFinding(b)!.room, 'bathroom');
      expect(controller.toFinding(e)!.room, 'entrance');
    });

    test(
      'the observation is trimmed on the wire but kept as typed locally',
      () {
        final String id = controller.startFinding(AssessmentArea.entrance);
        controller.setObservation(id, '  I notice a step \n');
        expect(controller.toFinding(id)!.observation, 'I notice a step');
        expect(controller.draftOf(id)!.observation, '  I notice a step \n');
      },
    );

    test('no observation means no v1 Finding yet', () {
      final String id = controller.startFinding(AssessmentArea.bathroom);
      controller.addEvidence(id, version: 's1');
      expect(controller.toFinding(id), isNull);
      controller.setObservation(id, '   ');
      expect(controller.toFinding(id), isNull);
      expect(controller.findings, isEmpty);
      expect(controller.incompleteFindingIds, [id]);
    });

    test('findings lists every complete finding in creation order', () {
      final String a = entranceFinding();
      final String incomplete = controller.startFinding(
        AssessmentArea.bathroom,
      );
      final String c = entranceFinding();
      controller.dismiss(c);
      expect(controller.findings.map((f) => f.id), [a, c]);
      expect(controller.findings.last.reviewState, 'dismissed');
      expect(controller.incompleteFindingIds, [incomplete]);
    });

    test('the review state on the wire follows the tracker', () {
      final String id = entranceFinding();
      expect(controller.toFinding(id)!.reviewState, 'needs_review');
      controller.confirm(id);
      expect(controller.toFinding(id)!.reviewState, 'confirmed');
      controller.dismiss(id);
      expect(controller.toFinding(id)!.reviewState, 'dismissed');
    });
  });

  group('measurements', () {
    test('unmeasured types are absent, never zero', () {
      final String id = entranceFinding();
      controller.setMeasurement(id, 'thresholdHeight', _input('20'));
      final Finding finding = controller.toFinding(id)!;
      expect(finding.measurements.map((m) => m.type), ['thresholdHeight']);
    });

    test('clearing makes a measurement unknown again', () {
      final String id = entranceFinding();
      controller.setMeasurement(id, 'clearOpening', _input('800'));
      expect(controller.clearMeasurement(id, 'clearOpening'), isTrue);
      expect(controller.toFinding(id)!.measurements, isEmpty);
      expect(controller.clearMeasurement(id, 'clearOpening'), isFalse);
    });

    test('a recorded zero is kept and prompts review where implausible', () {
      final String id = entranceFinding();
      controller
        ..setMeasurement(id, 'clearOpening', _input('0'))
        ..setMeasurement(id, 'thresholdHeight', _input('0'));
      final FindingDraft draft = controller.draftOf(id)!;
      expect(draft.measurementOf('clearOpening')!.promptsZeroReview, isTrue);
      expect(
        draft.measurementOf('thresholdHeight')!.promptsZeroReview,
        isFalse,
      );
      expect(controller.toFinding(id)!.measurements.map((m) => m.value), [
        0,
        0,
      ]);
    });

    test('units convert deterministically to millimetres', () {
      final String id = entranceFinding();
      controller
        ..setMeasurement(
          id,
          'clearOpening',
          _input('80', LengthUnit.centimetre),
        )
        ..setMeasurement(
          id,
          'thresholdHeight',
          _input('0.75', LengthUnit.inch),
        );
      final List<Measurement> m = controller.toFinding(id)!.measurements;
      expect(m[0].value, 800);
      expect(m[0].value, isA<int>());
      expect(m[1].value, 19.05);
    });

    test('the original input is kept locally', () {
      final String id = entranceFinding();
      controller.setMeasurement(
        id,
        'thresholdHeight',
        _input('1.5', LengthUnit.inch),
      );
      final MeasurementInput input = controller
          .draftOf(id)!
          .measurementOf('thresholdHeight')!
          .input;
      expect(input.originalText, '1.5');
      expect(input.unit, LengthUnit.inch);
      expect(input.displayPrecision, 1);
    });

    test('an unknown measurement type is rejected', () {
      final String id = entranceFinding();
      expect(
        () => controller.setMeasurement(id, 'doorWidth', _input('800')),
        throwsArgumentError,
      );
    });

    test(
      'a changed value starts unconfirmed; the same value keeps its review',
      () {
        final String id = entranceFinding();
        controller
          ..setMeasurement(id, 'clearOpening', _input('800'))
          ..confirmMeasurement(id, 'clearOpening');
        expect(controller.toFinding(id)!.measurements.single.confirmed, isTrue);

        controller.setMeasurement(id, 'clearOpening', _input('800'));
        expect(controller.toFinding(id)!.measurements.single.confirmed, isTrue);

        controller.setMeasurement(id, 'clearOpening', _input('790'));
        expect(
          controller.toFinding(id)!.measurements.single.confirmed,
          isFalse,
        );
      },
    );

    test('the same length typed in another unit counts as a new entry', () {
      final String id = entranceFinding();
      controller
        ..setMeasurement(id, 'clearOpening', _input('800'))
        ..confirmMeasurement(id, 'clearOpening')
        ..setMeasurement(
          id,
          'clearOpening',
          _input('80', LengthUnit.centimetre),
        );
      expect(controller.toFinding(id)!.measurements.single.confirmed, isFalse);
    });

    test('an estimate stays an estimate after confirmation', () {
      final String id = entranceFinding();
      controller
        ..setMeasurement(
          id,
          'thresholdHeight',
          _input('20'),
          method: MeasurementMethod.estimated,
        )
        ..confirmMeasurement(id, 'thresholdHeight');
      final Measurement m = controller.toFinding(id)!.measurements.single;
      expect(m.method, 'estimated');
      expect(m.confirmed, isTrue);
    });

    test('a correction keeps its position in the list', () {
      final String id = entranceFinding();
      controller
        ..setMeasurement(id, 'clearOpening', _input('800'))
        ..setMeasurement(id, 'thresholdHeight', _input('20'))
        ..setMeasurement(id, 'clearOpening', _input('790'));
      expect(controller.toFinding(id)!.measurements.map((m) => m.type), [
        'clearOpening',
        'thresholdHeight',
      ]);
    });

    test('confirmMeasurement on an unrecorded type returns false', () {
      final String id = entranceFinding();
      expect(controller.confirmMeasurement(id, 'clearOpening'), isFalse);
    });
  });

  group('finding review', () {
    test('a new finding starts in needs_review', () {
      expect(stateOf(entranceFinding()), FindingReviewState.needsReview);
    });

    test('confirming with no observation is refused', () {
      final String id = controller.startFinding(AssessmentArea.entrance);
      expect(
        controller.confirm(id).rejection,
        ReviewRejection.emptyObservation,
      );
    });

    test('the confirmed snapshot matches the v1 Finding that is output', () {
      final String id = entranceFinding();
      controller.setMeasurement(id, 'thresholdHeight', _input('20'));
      controller.confirm(id);
      final Finding finding = controller.toFinding(id)!;
      expect(
        ReviewSnapshot.fromFinding(
          finding,
          evidenceVersions: {
            for (final e in controller.draftOf(id)!.evidence)
              e.evidenceId: e.version,
          },
        ),
        controller.reviewOf(id)!.confirmedSnapshot,
      );
    });

    test('editing the observation withdraws confirmation', () {
      final String id = entranceFinding();
      controller.confirm(id);
      controller.setObservation(id, 'I notice a raised threshold, about 2 cm');
      expect(stateOf(id), FindingReviewState.needsReview);
    });

    test('whitespace-only edits keep confirmation', () {
      final String id = entranceFinding();
      controller.confirm(id);
      controller.setObservation(id, 'I notice a raised threshold  ');
      expect(stateOf(id), FindingReviewState.confirmed);
    });

    test('replacing an image withdraws confirmation and keeps the ID', () {
      final String id = entranceFinding();
      final String evidenceId = controller
          .draftOf(id)!
          .evidence
          .single
          .evidenceId;
      controller.confirm(id);
      controller.replaceEvidence(id, evidenceId, version: 'staged-2');
      expect(stateOf(id), FindingReviewState.needsReview);
      expect(controller.toFinding(id)!.evidenceIds, [evidenceId]);
    });

    test('replacing with the same version changes nothing', () {
      final String id = entranceFinding();
      final String evidenceId = controller
          .draftOf(id)!
          .evidence
          .single
          .evidenceId;
      controller.confirm(id);
      controller.replaceEvidence(id, evidenceId, version: 'staged-1');
      expect(stateOf(id), FindingReviewState.confirmed);
    });

    test('replacing evidence that is not on the finding is an error', () {
      final String id = entranceFinding();
      expect(
        () => controller.replaceEvidence(id, 'evidence-99', version: 'x'),
        throwsArgumentError,
      );
    });

    test('adding or removing an image withdraws confirmation', () {
      final String id = entranceFinding();
      controller.confirm(id);
      final String added = controller.addEvidence(id, version: 'staged-2');
      expect(stateOf(id), FindingReviewState.needsReview);

      controller.confirm(id);
      expect(controller.removeEvidence(id, added), isTrue);
      expect(stateOf(id), FindingReviewState.needsReview);
      expect(controller.removeEvidence(id, added), isFalse);
    });

    test('changing a measurement value withdraws confirmation', () {
      final String id = entranceFinding();
      controller.setMeasurement(id, 'thresholdHeight', _input('20'));
      controller.confirm(id);
      controller.setMeasurement(id, 'thresholdHeight', _input('25'));
      expect(stateOf(id), FindingReviewState.needsReview);
    });

    test('adding or clearing a measurement withdraws confirmation', () {
      final String id = entranceFinding();
      controller.confirm(id);
      controller.setMeasurement(id, 'thresholdHeight', _input('20'));
      expect(stateOf(id), FindingReviewState.needsReview);

      controller.confirm(id);
      controller.clearMeasurement(id, 'thresholdHeight');
      expect(stateOf(id), FindingReviewState.needsReview);
    });

    test('confirming a measurement leaves the finding confirmed', () {
      final String id = entranceFinding();
      controller.setMeasurement(id, 'thresholdHeight', _input('20'));
      controller.confirm(id);
      controller.confirmMeasurement(id, 'thresholdHeight');
      expect(stateOf(id), FindingReviewState.confirmed);
    });

    test('requesting another view, then adding one, clears the request', () {
      final String id = entranceFinding();
      controller.confirm(id);
      controller.requestAnotherView(id);
      expect(stateOf(id), FindingReviewState.needsReview);
      expect(controller.reviewOf(id)!.anotherViewRequested, isTrue);

      controller.addEvidence(id, version: 'staged-2');
      expect(controller.reviewOf(id)!.anotherViewRequested, isFalse);
      expect(stateOf(id), FindingReviewState.needsReview);
    });

    test('dismiss, then restore before confirming again', () {
      final String id = entranceFinding();
      controller.dismiss(id);
      expect(stateOf(id), FindingReviewState.dismissed);
      expect(controller.confirm(id).rejection, ReviewRejection.dismissed);

      controller.restore(id);
      expect(stateOf(id), FindingReviewState.needsReview);
      expect(controller.confirm(id).applied, isTrue);
    });

    test('editing a dismissed finding keeps it dismissed', () {
      final String id = entranceFinding();
      controller.dismiss(id);
      controller.setObservation(id, 'Something else');
      expect(stateOf(id), FindingReviewState.dismissed);
    });
  });

  group('removal and clearing', () {
    test('removeFinding returns its last state and stops tracking it', () {
      final String id = entranceFinding();
      final FindingDraft? removed = controller.removeFinding(id);
      expect(removed!.evidence.single.version, 'staged-1');
      expect(controller.draftOf(id), isNull);
      expect(controller.reviewOf(id), isNull);
      expect(controller.findings, isEmpty);
      expect(controller.removeFinding(id), isNull);
    });

    test('clear drops every finding and review', () {
      final String a = entranceFinding();
      entranceFinding();
      controller.clear();
      expect(controller.drafts, isEmpty);
      expect(controller.findings, isEmpty);
      expect(controller.reviewOf(a), isNull);
    });
  });

  test('drafts cannot be modified from outside', () {
    final String id = entranceFinding();
    final FindingDraft draft = controller.draftOf(id)!;
    expect(
      () => draft.evidence.add(
        const EvidenceVersion(evidenceId: 'x', version: 'y'),
      ),
      throwsUnsupportedError,
    );
    expect(() => controller.drafts.clear(), throwsUnsupportedError);
  });

  group('measurement history', () {
    test('corrections and clearing keep the earlier values locally', () {
      var now = DateTime.utc(2026, 10, 18, 9);
      final c = AssessmentController(
        ids: SequentialIdFactory(),
        clock: () => now,
      );
      final String id = c.startFinding(AssessmentArea.entrance);
      c.setMeasurement(
        id,
        'thresholdHeight',
        _input('2', LengthUnit.centimetre),
      );
      c.confirmMeasurement(id, 'thresholdHeight');
      now = now.add(const Duration(minutes: 1));
      c.setMeasurement(id, 'thresholdHeight', _input('25'));
      now = now.add(const Duration(minutes: 1));
      c.clearMeasurement(id, 'thresholdHeight');

      final List<MeasurementChange> history = c.measurementHistoryOf(
        id,
        'thresholdHeight',
      );
      expect(history.map((h) => h.kind), [
        MeasurementChangeKind.corrected,
        MeasurementChangeKind.cleared,
      ]);
      expect(history.first.previous.input.originalText, '2');
      expect(history.first.previous.input.unit, LengthUnit.centimetre);
      expect(history.first.previous.confirmed, isTrue);
      expect(history.first.at, DateTime.utc(2026, 10, 18, 9, 1));
      expect(history.last.previous.input.millimetres, 25);
      expect(c.toFinding(id), isNull);
    });

    test('re-entering the same value adds no history', () {
      final String id = entranceFinding();
      controller
        ..setMeasurement(id, 'clearOpening', _input('800'))
        ..setMeasurement(id, 'clearOpening', _input('800'));
      expect(controller.measurementHistoryOf(id, 'clearOpening'), isEmpty);
    });

    test('history never appears in v1 JSON', () {
      final String id = entranceFinding();
      controller
        ..setMeasurement(id, 'clearOpening', _input('811'))
        ..setMeasurement(id, 'clearOpening', _input('800'));
      expect(
        jsonEncode(controller.toFinding(id)!.toJson()),
        isNot(contains('811')),
      );
    });

    test('history is dropped with its finding and on clear', () {
      final String a = entranceFinding();
      final String b = entranceFinding();
      controller
        ..setMeasurement(a, 'clearOpening', _input('811'))
        ..setMeasurement(a, 'clearOpening', _input('800'))
        ..setMeasurement(b, 'clearOpening', _input('811'))
        ..setMeasurement(b, 'clearOpening', _input('800'));
      controller.removeFinding(a);
      expect(controller.measurementHistoryOf(a, 'clearOpening'), isEmpty);
      expect(controller.measurementHistoryOf(b, 'clearOpening'), hasLength(1));
      controller.clear();
      expect(controller.measurementHistoryOf(b, 'clearOpening'), isEmpty);
    });
  });

  group('removed findings', () {
    test('are remembered until clear', () {
      final String a = entranceFinding();
      entranceFinding();
      controller.removeFinding(a);
      expect(controller.removedFindingIds, {a});
      expect(controller.removeFinding('unknown'), isNull);
      expect(controller.removedFindingIds, {a});
      controller.clear();
      expect(controller.removedFindingIds, isEmpty);
    });
  });

  group('notifications', () {
    test('every change notifies listeners; no-ops do not', () {
      var count = 0;
      controller.addListener(() => count++);

      final String id = controller.startFinding(AssessmentArea.entrance);
      expect(count, 1);
      controller.setObservation(id, 'I notice a step');
      expect(count, 2);
      controller.setObservation(id, 'I notice a step');
      expect(count, 2);
      controller.addEvidence(id, version: 's1');
      controller.setMeasurement(id, 'thresholdHeight', _input('20'));
      controller.confirmMeasurement(id, 'thresholdHeight');
      expect(count, 5);
      controller.confirm(id);
      expect(count, 6);
      controller.restore(id);
      expect(count, 6);
      controller.dismiss(id);
      controller.removeFinding(id);
      controller.clear();
      expect(count, 9);
    });
  });
}
