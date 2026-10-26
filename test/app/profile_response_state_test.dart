import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/cases/profile_response_state.dart';
import 'package:safe_at_home/features/cases/profile_response_store.dart';
import 'package:safe_at_home/shared/models/contracts.dart';

import 'live_workflows_test.dart' show MemoryPrivateStore;
import 'profile_recovery_test.dart' show ProfileTestStore, appFor;

CaseProfile profile([Map<String, Object?> changes = const {}]) =>
    CaseProfile.fromJson({
      'city': null,
      'county': null,
      'healthPlan': null,
      'tenure': null,
      'ageYears': null,
      'householdSize': null,
      'annualIncomeUsd': null,
      'ownerConsentReported': null,
      ...changes,
    });

const uncertain = ProfileResponseState(
  coverage: ProfileCoverageChoice.notSure,
  tenureNotSure: true,
  consentNotSure: true,
);

class HeldResponseStore extends MemoryPrivateStore {
  bool hold = false;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<Map<String, Object?>?> readJson(String key) async {
    final value = await super.readJson(key);
    if (hold) {
      entered.complete();
      await release.future;
    }
    return value;
  }
}

void main() {
  test(
    'unanswered and explicit uncertainty count differently without v1 facts',
    () {
      final facts = profile();
      expect(const ProfileResponseState().answeredCount(facts), 0);
      expect(uncertain.answeredCount(facts), 3);
      expect(facts.toJson().values, everyElement(isNull));
      expect(
        ProfileResponseState.fromJson(uncertain.toJson()).toJson(),
        uncertain.toJson(),
      );
      expect(
        () => CaseProfile.fromJson({
          ...facts.toJson(),
          'responses': uncertain.toJson(),
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'false, zero and known answers are preserved and never counted twice',
    () {
      final facts = profile({
        'city': 'Fictional city',
        'healthPlan': 'Fictional health plan',
        'tenure': 'renter',
        'ageYears': 0,
        'householdSize': 1,
        'annualIncomeUsd': 0,
        'ownerConsentReported': false,
      });
      expect(uncertain.answeredCount(facts), 7);
      expect(
        uncertain.forProfile(facts).toJson(),
        const ProfileResponseState().toJson(),
      );
      expect(facts.ownerConsentReported, false);
      expect(facts.annualIncomeUsd, 0);
    },
  );

  test('strict response schema rejects invented answers and fields', () {
    for (final bad in [
      {...uncertain.toJson(), 'coverage': 'approved'},
      {...uncertain.toJson(), 'tenureNotSure': 'yes'},
      {...uncertain.toJson(), 'consent': true},
      {'coverage': null},
    ]) {
      expect(() => ProfileResponseState.fromJson(bad), throwsFormatException);
    }
  });

  test(
    'encrypted store round trip is bound to case and complete profile',
    () async {
      final disk = MemoryPrivateStore();
      final responses = ProfileResponseStore(
        store: disk,
        isCurrentCase: (id) => id == 'fictional-case',
      );
      addTearDown(responses.dispose);
      await responses.write('fictional-case', profile(), uncertain);
      final reopened = ProfileResponseStore(
        store: disk,
        isCurrentCase: (id) => id == 'fictional-case',
      );
      addTearDown(reopened.dispose);
      expect(
        (await reopened.read(
          'fictional-case',
          profile(),
        )).answeredCount(profile()),
        3,
      );
      final externallyChanged = profile({'city': 'Another fictional city'});
      expect(
        reopened
            .currentFor('fictional-case', externallyChanged)
            .answeredCount(externallyChanged),
        1,
      );
      expect(
        (await reopened.read('fictional-case', externallyChanged)).coverage,
        isNull,
      );
      await responses.write('fictional-case', externallyChanged, uncertain);
      expect(
        (await reopened.read(
          'fictional-case',
          externallyChanged,
        )).answeredCount(externallyChanged),
        4,
      );
      disk.records['profile-response.fictional-case']!['caseId'] =
          'another-case';
      await expectLater(
        reopened.read('fictional-case', externallyChanged),
        throwsFormatException,
      );
      expect(
        reopened.currentFor('fictional-case', externallyChanged).coverage,
        isNull,
      );
    },
  );

  test(
    'older disk read cannot replace a newer successful response save',
    () async {
      final disk = HeldResponseStore();
      final responses = ProfileResponseStore(
        store: disk,
        isCurrentCase: (_) => true,
      );
      addTearDown(responses.dispose);
      await responses.write(
        'fictional-case',
        profile(),
        const ProfileResponseState(),
      );
      disk.hold = true;
      final oldRead = responses.read('fictional-case', profile());
      await disk.entered.future;
      await responses.write('fictional-case', profile(), uncertain);
      disk.release.complete();
      await oldRead;
      expect(
        responses
            .currentFor('fictional-case', profile())
            .answeredCount(profile()),
        3,
      );
    },
  );

  test('scope switch and switch back reject a late read', () async {
    final disk = HeldResponseStore();
    var generation = 1;
    final responses = ProfileResponseStore(
      store: disk,
      isCurrentCase: (_) => true,
      scopeKey: () => generation,
    );
    addTearDown(responses.dispose);
    await responses.write('fictional-case', profile(), uncertain);
    disk.hold = true;
    final lateRead = responses.read('fictional-case', profile());
    final rejection = expectLater(lateRead, throwsStateError);
    await disk.entered.future;
    generation += 2;
    expect(
      responses
          .currentFor('fictional-case', profile())
          .answeredCount(profile()),
      0,
    );
    disk.release.complete();
    await rejection;
  });

  test(
    'disposed account cannot receive or expose a late private read',
    () async {
      final disk = HeldResponseStore();
      final responses = ProfileResponseStore(
        store: disk,
        isCurrentCase: (_) => true,
      );
      await responses.write('fictional-case', profile(), uncertain);
      disk.hold = true;
      final lateRead = responses.read('fictional-case', profile());
      final rejection = expectLater(lateRead, throwsStateError);
      await disk.entered.future;
      responses.dispose();
      disk.release.complete();
      await rejection;
      expect(
        responses
            .currentFor('fictional-case', profile())
            .answeredCount(profile()),
        0,
      );
    },
  );

  test(
    'local case cleanup removes response metadata only for that case',
    () async {
      final disk = ProfileTestStore();
      final app = await appFor(disk);
      final draft = app.coordinator.currentDraft();
      await app.profileResponses.write(draft.caseId, draft.profile, uncertain);
      disk.records['profile-response.another-fictional-case'] = {
        'preserve': true,
      };
      await app.coordinator.clearSelected();
      expect(
        disk.records.containsKey('profile-response.${draft.caseId}'),
        false,
      );
      expect(disk.records['profile-response.another-fictional-case'], {
        'preserve': true,
      });
      expect(
        app.profileResponses
            .currentFor(draft.caseId, draft.profile)
            .answeredCount(draft.profile),
        0,
      );
    },
  );

  test(
    'resident state and ZIP stay device-only and follow the entered place',
    () async {
      const located = ProfileResponseState(
        coverage: ProfileCoverageChoice.notSure,
        stateCode: 'CA',
        zip: '95112',
      );
      final facts = profile({
        'city': 'Fictional city',
        'county': 'Santa Clara',
      });
      expect(located.answeredCount(facts), 3);
      expect(facts.toJson().keys, isNot(contains('zip')));
      expect(const ProfileResponseState().toJson().keys, {
        'coverage',
        'tenureNotSure',
        'consentNotSure',
      });
      for (final bad in [
        {...located.toJson(), 'stateCode': 'ca'},
        {...located.toJson(), 'stateCode': 'ZZ'},
        {...located.toJson(), 'zip': '9511'},
        {...located.toJson(), 'zip': '95112-1234'},
        {...located.toJson(), 'zip': 95112},
      ]) {
        expect(() => ProfileResponseState.fromJson(bad), throwsFormatException);
      }

      final disk = MemoryPrivateStore();
      final responses = ProfileResponseStore(
        store: disk,
        isCurrentCase: (id) => id == 'fictional-case',
      );
      addTearDown(responses.dispose);
      await responses.write('fictional-case', facts, located);
      expect(disk.records['profile-response.fictional-case']!['version'], 2);
      final read = await responses.read('fictional-case', facts);
      expect((read.stateCode, read.zip), ('CA', '95112'));

      final incomeChanged = profile({...facts.toJson(), 'annualIncomeUsd': 0});
      final kept = await responses.read('fictional-case', incomeChanged);
      expect((kept.stateCode, kept.zip, kept.coverage), ('CA', '95112', null));

      final moved = profile({...facts.toJson(), 'city': 'Another city'});
      final dropped = await responses.read('fictional-case', moved);
      expect((dropped.stateCode, dropped.zip), (null, null));

      disk.records['profile-response.fictional-case'] = {
        'version': 1,
        'caseId': 'fictional-case',
        'profileFingerprint': ProfileResponseState.fingerprint(facts),
        'responses': uncertain.toJson(),
      };
      final legacy = await responses.read('fictional-case', facts);
      expect(legacy.toJson(), uncertain.toJson());
      disk.records['profile-response.fictional-case'] = {
        'version': 1,
        'caseId': 'fictional-case',
        'profileFingerprint': ProfileResponseState.fingerprint(facts),
        'placeFingerprint': ProfileResponseState.placeFingerprint(facts),
        'responses': uncertain.toJson(),
      };
      await expectLater(
        responses.read('fictional-case', facts),
        throwsFormatException,
      );
    },
  );
}
