import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/local_help/referral_catalog.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/referral_directory.dart';

Map<String, dynamic> snapshot() =>
    jsonDecode(jsonEncode(ReferralCatalog.bundled().toJson()))
        as Map<String, dynamic>;
void main() {
  test('same-state county name and FIPS contradictions require correction', () {
    expect(
      () => HelpLocation(
        city: '',
        county: 'San Mateo County',
        zip: null,
        stateCode: 'CA',
        countyFips: '06085',
      ),
      throwsFormatException,
    );
    final rural = HelpLocation(
      city: '',
      county: 'Craig',
      zip: '24127',
      stateCode: 'VA',
      countyFips: '51045',
    );
    expect(HelpLocation.fromJson(rural.toJson()).countyFips, '51045');
  });
  test(
    'offline release round-trips, deduplicates count, exposes exact geographic gaps',
    () {
      final catalog = ReferralCatalog.bundled();
      final restored = ReferralCatalog.fromJson(snapshot());
      expect(restored.toJson(), catalog.toJson());
      expect(catalog.organizationCount, 17);
      final coverage = catalog.coverageReport(DateTime(2026, 10, 26));
      final states = coverage['states'] as List;
      expect(states, hasLength(51));
      expect(states.where((s) => s['organizationCount'] == 0), hasLength(45));
      expect(states.every((s) => s['referralRouting'] == true), true);
      expect(
        states.every((s) => s['verifiedNationwideEligibility'] == false),
        true,
      );
      expect(coverage['nationalLocatorCount'], 5);
      expect(
        catalog.providers.where(
          (p) => p.providerKind == ReferralProviderKind.programReferral,
        ),
        hasLength(2),
      );
    },
  );
  test(
    'review queue has owners and date-bound stale status, not open-intake guesses',
    () {
      final catalog = ReferralCatalog.bundled();
      final queue = catalog.reviewQueue(DateTime(2027, 2, 1));
      expect(queue, hasLength(catalog.providers.length));
      expect(
        queue.every((r) => r['ownerRole'] != null && r['needsReview'] == true),
        true,
      );
      expect(queue.map((r) => r['intake']).toSet(), {'unknown', 'closed'});
    },
  );
  test(
    'catalog rejects duplicate organizations and malformed state/county updates',
    () {
      var v = snapshot();
      (v['providers'] as List).add((v['providers'] as List).first);
      expect(() => ReferralCatalog.fromJson(v), throwsFormatException);
      v = snapshot();
      final org = (v['providers'] as List).firstWhere(
        (p) => p['id'] == 'renovation-alliance-va',
      );
      org['serviceAreas'][0]['countyFips'] = '06023';
      expect(() => ReferralCatalog.fromJson(v), throwsFormatException);
      v = snapshot();
      (v['providers'] as List).first['website'] =
          'https://example.org/?case=private';
      expect(() => ReferralCatalog.fromJson(v), throwsFormatException);
    },
  );
  test(
    'release format refuses missing provenance, unknown fields and unsupported schema',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => v['schemaVersion'] = '2',
        (v) => v['secret'] = 'not a catalog field',
        (v) => v['providers'][0]['sources'] = [],
        (v) => v['providers'][0]['availability'] = 'accepting',
        (v) => v['providers'][0]['kind'] = 'organization',
      ]) {
        final v = snapshot();
        mutate(v);
        expect(() => ReferralCatalog.fromJson(v), throwsFormatException);
      }
    },
  );
  test(
    'validated archived release can be restored and updates retain saved contact IDs',
    () {
      final old = ReferralCatalog.bundled();
      final archived = jsonEncode(old.toJson());
      final update = ReferralCatalog(
        version: 'fictional-next',
        providers: old.providers.skip(1).toList(),
      );
      expect(() => update.requireCompatibleUpdate(old), throwsFormatException);
      final rollback = ReferralCatalog.fromJson(jsonDecode(archived));
      rollback.requireCompatibleUpdate(old);
      expect(
        rollback.provider('referral-211-national')!.website,
        'https://211.org/about-us/your-local-211',
      );
      expect(rollback.version, old.version);
    },
  );
  test(
    'organization roles distinguish CIL coordination, government funding, repairs and referral',
    () {
      final catalog = ReferralCatalog.bundled();
      expect(
        catalog.provider('provider-cid-san-mateo')!.roles,
        contains(ReferralRole.coordinator),
      );
      expect(
        catalog.provider('ability360-az')!.roles,
        isNot(contains(ReferralRole.repairProvider)),
      );
      expect(
        catalog.provider('provider-napa-housing-rehabilitation')!.roles,
        contains(ReferralRole.modificationFunder),
      );
      expect(
        catalog.provider('rt-seattle-wa')!.roles,
        contains(ReferralRole.repairProvider),
      );
      expect(catalog.provider('referral-cil-national')!.roles, [
        ReferralRole.referralService,
      ]);
    },
  );
}
