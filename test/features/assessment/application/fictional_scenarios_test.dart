import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/fictional_scenarios.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/contracts.dart';

import '../fakes/fakes.dart';
import '../support/v1_case_schema.dart';

AssessmentController _build() {
  final controller = AssessmentController(ids: SequentialIdFactory());
  addFictionalBathroomScenario(controller);
  addFictionalEntranceScenario(controller);
  return controller;
}

Map<String, Object?> _fixtureCaseWith(List<Finding> findings) {
  final List<dynamic> scenarios =
      jsonDecode(
            File('contracts/v1/fixtures/scenarios.json').readAsStringSync(),
          )
          as List<dynamic>;
  final Map<String, Object?> json = Map<String, Object?>.from(
    scenarios.first['case'] as Map,
  );
  json['findings'] = findings.map((f) => f.toJson()).toList();
  return json;
}

void main() {
  test('IDs are stable and come from the injected factory', () {
    final AssessmentController controller = _build();
    expect(controller.findings.map((f) => f.id), [
      'finding-1',
      'finding-2',
      'finding-3',
    ]);
    expect(controller.findings.expand((f) => f.evidenceIds), [
      'evidence-1',
      'evidence-2',
      'evidence-3',
    ]);
    expect(
      jsonEncode(_build().findings.map((f) => f.toJson()).toList()),
      jsonEncode(controller.findings.map((f) => f.toJson()).toList()),
    );
  });

  test('all three v1 review states appear', () {
    final List<Finding> findings = _build().findings;
    expect(findings.map((f) => f.reviewState), [
      'needs_review',
      'dismissed',
      'confirmed',
    ]);
    expect(findings.map((f) => f.room), ['bathroom', 'bathroom', 'entrance']);
  });

  test('every finding satisfies the v1 finding schema', () {
    for (final Finding finding in _build().findings) {
      expect(acceptsCaseDef(finding.toJson(), 'finding'), isTrue);
    }
  });

  test('the schema check rejects extra keys and invalid states', () {
    final Map<String, Object?> json = _build().findings.first.toJson();
    expect(acceptsCaseDef({...json, 'reviewHistory': []}, 'finding'), isFalse);
    expect(
      acceptsCaseDef({...json, 'reviewState': 'corrected'}, 'finding'),
      isFalse,
    );
  });

  test('the findings form a valid v1 case at the shared write boundary', () {
    final Map<String, Object?> json = _fixtureCaseWith(_build().findings);
    expect(acceptsCase(json), isTrue);
    expect(() => parseWritableCase(json), returnsNormally);
    expect(
      CaseSnapshot.fromJson(json).findings.map((f) => f.toJson()),
      _build().findings.map((f) => f.toJson()),
    );
  });

  test('unmeasured values are absent rather than zero', () {
    final List<Finding> findings = _build().findings;
    final Finding entrance = findings.last;
    expect(entrance.measurements.map((m) => m.type), ['thresholdHeight']);
    expect(findings[1].measurements, isEmpty);
  });

  test('measurements carry millimetres, method and their own review', () {
    final List<Finding> findings = _build().findings;
    expect(findings.first.measurements.single.toJson(), {
      'type': 'curbHeight',
      'value': 450,
      'unit': 'mm',
      'method': 'manual',
      'confirmed': false,
    });
    expect(findings.last.measurements.single.toJson(), {
      'type': 'thresholdHeight',
      'value': 38.1,
      'unit': 'mm',
      'method': 'manual',
      'confirmed': true,
    });
  });

  test('the obscured bathroom finding asks for another view', () {
    final AssessmentController controller = _build();
    expect(controller.reviewOf('finding-1')!.anotherViewRequested, isTrue);
  });

  test('observations make no professional, legal or eligibility claims', () {
    final RegExp forbidden = RegExp(
      r'unsafe|non-?compliant|violation|diagnos|medical|necessary|eligib|'
      r'approv|hazard|code\b|ADA',
      caseSensitive: false,
    );
    for (final Finding finding in _build().findings) {
      expect(finding.observation, isNot(matches(forbidden)));
    }
  });
}
