import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/demo_scenario_service.dart';

List<dynamic> rawScenarios() =>
    jsonDecode(File(AssetDemoScenarioService.assetPath).readAsStringSync())
        as List<dynamic>;

Map<String, dynamic> rawCase([int index = 0]) =>
    rawScenarios()[index]['case'] as Map<String, dynamic>;

Map<String, dynamic> rawMatch([int index = 0]) =>
    rawScenarios()[index]['match'] as Map<String, dynamic>;

void main() {
  test(
    'fictional cases expose the three distinct outcomes without policy code',
    () {
      final scenarios = parseDemoScenarios(rawScenarios());
      expect(scenarios.map((s) => s.id), ['matched', 'not-matched', 'unknown']);
      expect(scenarios.map((s) => s.matchResponse.matches.single.status), [
        'meets_known_criteria',
        'does_not_meet_criterion',
        'needs_confirmation',
      ]);
      for (final scenario in scenarios) {
        final route = scenario.matchResponse.matches.single;
        expect(route.isDemo, isTrue);
        expect(route.availability, 'unverified');
        expect(route.sources, isEmpty);
        expect(route.intake, isNull);
        expect(route.checks.map((c) => c.id), ['city', 'plan']);
        expect(scenario.caseSnapshot.caseId, scenario.matchResponse.caseId);
      }
      expect(
        scenarios.last.matchResponse.matches.single.checks.last.missingFields,
        ['profile.healthPlan'],
      );
    },
  );

  test('zero income and false consent survive; unknown values remain null', () {
    final known = CaseSnapshot.fromJson(rawCase()).profile;
    final unknown = CaseSnapshot.fromJson(rawCase(2)).profile;
    expect(known.annualIncomeUsd, 0);
    expect(known.ownerConsentReported, isFalse);
    expect(unknown.annualIncomeUsd, isNull);
    expect(unknown.ownerConsentReported, isNull);
    expect(unknown.healthPlan, isNull);
  });

  test('all explicit profile unknowns are supported', () {
    final input = rawCase();
    final profile = input['profile'] as Map<String, dynamic>;
    for (final key in profile.keys.toList()) {
      profile[key] = null;
    }
    expect(CaseSnapshot.fromJson(input).profile.city, isNull);
  });

  test(
    'missing nullable fields are rejected rather than silently defaulted',
    () {
      final input = rawCase();
      (input['profile'] as Map).remove('ownerConsentReported');
      expect(() => CaseSnapshot.fromJson(input), throwsFormatException);
    },
  );

  test('unknown fields are rejected at top-level and nested boundaries', () {
    final input = rawCase()..['ownerId'] = 'untrusted-owner';
    expect(() => CaseSnapshot.fromJson(input), throwsFormatException);
    final nested = rawCase();
    nested['profile']['eligible'] = true;
    expect(() => CaseSnapshot.fromJson(nested), throwsFormatException);
  });

  test(
    'numeric strings, fractional ages, non-finite numbers and fake booleans fail',
    () {
      for (final bad in <(String, Object)>[
        ('annualIncomeUsd', '0'),
        ('annualIncomeUsd', double.infinity),
        ('ageYears', 65.5),
        ('ageYears', -1),
        ('householdSize', 0),
        ('ownerConsentReported', 'false'),
        ('ownerConsentReported', 0),
      ]) {
        final input = rawCase();
        input['profile'][bad.$1] = bad.$2;
        expect(
          () => CaseSnapshot.fromJson(input),
          throwsFormatException,
          reason: '${bad.$1} must reject ${bad.$2}',
        );
      }
      expect(
        () => CaseSnapshot.fromJson(rawCase()..['revision'] = 0),
        throwsFormatException,
      );
    },
  );

  test(
    'measurement shape preserves zero and rejects negative lengths or wrong units',
    () {
      final zero = rawCase();
      zero['findings'][0]['measurements'][0]['value'] = 0;
      expect(
        CaseSnapshot.fromJson(zero).findings.single.measurements.single.value,
        0,
      );
      for (final bad in <(String, Object)>[
        ('value', -1),
        ('unit', 'inches'),
        ('method', 'ai'),
        ('confirmed', 'true'),
      ]) {
        final input = rawCase();
        input['findings'][0]['measurements'][0][bad.$1] = bad.$2;
        expect(() => CaseSnapshot.fromJson(input), throwsFormatException);
      }
    },
  );

  test('status strings cannot accidentally imply agency approval', () {
    final input = rawMatch();
    input['matches'][0]['status'] = 'approved';
    expect(() => MatchResponse.fromJson(input), throwsFormatException);
  });

  test(
    'calendar dates and UTC timestamps reject normalization and offset ambiguity',
    () {
      for (final date in ['2026-02-30', '2026-13-01', '2026-2-01']) {
        final input = rawMatch()..['evaluationDate'] = date;
        expect(() => MatchResponse.fromJson(input), throwsFormatException);
      }
      for (final timestamp in [
        '2026-02-30T19:00:00Z',
        '2026-10-13T25:00:00Z',
        '2026-10-13T19:60:00Z',
        '2026-10-13T19:00:00-07:00',
        '2026-10-13T19:00:00',
        'not-a-time',
      ]) {
        final input = rawMatch()..['evaluatedAt'] = timestamp;
        expect(() => MatchResponse.fromJson(input), throwsFormatException);
      }
      expect(
        MatchResponse.fromJson(
          rawMatch()..['evaluationDate'] = '2028-02-29',
        ).evaluationDate,
        '2028-02-29',
      );
    },
  );

  test('real source records parse and check references must resolve', () {
    final input = rawMatch();
    final route = input['matches'][0] as Map<String, dynamic>;
    route['sources'] = [
      {
        'id': 'source-a',
        'url': 'https://example.org/policy',
        'title': 'Test source',
        'reviewedOn': '2026-10-13',
        'effectiveFrom': null,
        'effectiveUntil': null,
      },
    ];
    route['checks'][0]['sourceIds'] = ['source-a'];
    expect(
      MatchResponse.fromJson(input).matches.single.sources.single.id,
      'source-a',
    );
    route['checks'][0]['sourceIds'] = ['missing-source'];
    expect(() => MatchResponse.fromJson(input), throwsFormatException);
    route['checks'][0]['sourceIds'] = ['source-a'];
    route['sources'][0]['url'] = 'javascript:alert(1)';
    expect(() => MatchResponse.fromJson(input), throwsFormatException);
  });

  test(
    'freshness expires exactly at the server deadline without a case edit',
    () {
      final snapshot = CaseSnapshot.fromJson(rawCase());
      final response = MatchResponse.fromJson(rawMatch());
      expect(
        response.isFreshFor(
          snapshot,
          now: DateTime.parse('2026-10-14T18:59:59Z'),
        ),
        isTrue,
      );
      expect(
        response.isFreshFor(
          snapshot,
          now: DateTime.parse('2026-10-14T19:00:00Z'),
        ),
        isFalse,
      );
      expect(
        response.isFreshFor(
          snapshot,
          now: DateTime.parse('2026-10-15T19:00:00Z'),
        ),
        isFalse,
      );
      expect(
        response.isFreshFor(
          snapshot,
          now: DateTime.parse('2026-10-12T19:00:00Z'),
        ),
        isFalse,
      );
    },
  );

  test(
    'freshness rejects changed cases, unknown deadlines and empty results',
    () {
      final now = DateTime.parse('2026-10-13T20:00:00Z');
      final snapshot = CaseSnapshot.fromJson(rawCase());
      final response = MatchResponse.fromJson(rawMatch());
      expect(
        response.isFreshFor(
          CaseSnapshot.fromJson(rawCase()..['revision'] = 2),
          now: now,
        ),
        isFalse,
      );
      expect(
        response.isFreshFor(
          CaseSnapshot.fromJson(rawCase()..['caseId'] = 'another-case'),
          now: now,
        ),
        isFalse,
      );
      final unresolved = rawMatch();
      unresolved['matches'][0]['recheckAfter'] = null;
      expect(
        MatchResponse.fromJson(unresolved).isFreshFor(snapshot, now: now),
        isFalse,
      );
      final empty = rawMatch()..['matches'] = [];
      expect(
        MatchResponse.fromJson(empty).isFreshFor(snapshot, now: now),
        isFalse,
      );
    },
  );

  test(
    'fixtures reject mismatched responses, duplicate IDs and non-demo routes',
    () {
      final mismatch = rawScenarios();
      mismatch[0]['match']['caseId'] = 'different-case';
      expect(() => parseDemoScenarios(mismatch), throwsFormatException);
      final duplicates = rawScenarios();
      duplicates[1]['id'] = duplicates[0]['id'];
      expect(() => parseDemoScenarios(duplicates), throwsFormatException);
      final nonDemo = rawScenarios();
      nonDemo[0]['match']['matches'][0]['isDemo'] = false;
      expect(() => parseDemoScenarios(nonDemo), throwsFormatException);
    },
  );

  test('parsed lists cannot be mutated to change a saved snapshot', () {
    final scenario = parseDemoScenarios(rawScenarios()).first;
    expect(
      () => scenario.caseSnapshot.findings.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => scenario.caseSnapshot.findings.single.evidenceIds.add('new'),
      throwsUnsupportedError,
    );
    expect(
      () => scenario.matchResponse.matches.single.checks.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'asset adapter loads and parses the shared fixture without a backend',
    () async {
      final bundle = _MemoryBundle(
        File(AssetDemoScenarioService.assetPath).readAsStringSync(),
      );
      final scenarios = await AssetDemoScenarioService(
        bundle: bundle,
      ).loadScenarios();
      expect(bundle.requestedKeys, [AssetDemoScenarioService.assetPath]);
      expect(scenarios.length, 3);
      expect(scenarios.last.caseSnapshot.profile.healthPlan, isNull);
    },
  );

  test(
    'asset adapter propagates invalid content rather than fabricating results',
    () async {
      final service = AssetDemoScenarioService(
        bundle: _MemoryBundle('{broken json'),
      );
      await expectLater(service.loadScenarios(), throwsFormatException);
    },
  );
}

class _MemoryBundle extends CachingAssetBundle {
  _MemoryBundle(this.content);
  final String content;
  final requestedKeys = <String>[];

  @override
  Future<ByteData> load(String key) async {
    requestedKeys.add(key);
    final bytes = Uint8List.fromList(utf8.encode(content));
    return ByteData.sublistView(bytes);
  }
}
