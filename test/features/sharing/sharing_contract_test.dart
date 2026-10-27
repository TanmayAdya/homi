import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/sharing.dart';
import '../../support/contract_schema.dart';

List<Map<String, Object?>> sharingFixtures() =>
    (jsonDecode(
              File(
                'contracts/v3/fixtures/permission-sharing.json',
              ).readAsStringSync(),
            )
            as List)
        .cast<Map<String, Object?>>();
Map<String, Object?> sharedFixture() =>
    sharingFixtures().firstWhere(
          (v) => v['route'] == 'read-shared-case',
        )['response']
        as Map<String, Object?>;
void main() {
  test(
    'all ten sharing requests and responses match strict v3 schema and Dart contracts',
    () {
      final schema =
          jsonDecode(
                File(
                  'contracts/v3/permission-sharing.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final fixture in sharingFixtures()) {
        final route = fixture['route']! as String;
        for (final side in ['request', 'response']) {
          expect(
            acceptsContract(
              fixture[side],
              schema[r'$defs']['$route-$side'],
              {},
              schema,
            ),
            isTrue,
            reason: '$route $side',
          );
        }
        SharingResponse.fromJson(fixture['response'], route);
      }
    },
  );
  test(
    'unknown profile, photo, PDF fields and out-of-scope findings fail the Dart boundary',
    () {
      final raw = sharedFixture(),
          projection = Map<String, Object?>.from(raw['projection']! as Map);
      for (final key in ['profile', 'photos', 'pdfs', 'annualIncomeUsd']) {
        expect(
          () => SharingResponse.fromJson({
            ...raw,
            'projection': {...projection, key: 'private'},
          }, 'read-shared-case'),
          throwsFormatException,
        );
      }
      final member = Map<String, Object?>.from(raw['membership']! as Map);
      expect(
        () => SharingResponse.fromJson({
          ...raw,
          'membership': {
            ...member,
            'scope': {
              'findingIds': [],
              'programIds': [],
              'allowHelperNotes': true,
            },
          },
        }, 'read-shared-case'),
        throwsFormatException,
      );
      expect(
        () => CaseMembership.fromJson({...member, 'role': 'viewer'}),
        throwsFormatException,
      );
    },
  );
  test(
    'owner-typed labels: additive fixtures, owner-only recipient label, strict values',
    () {
      final schema =
          jsonDecode(
                File(
                  'contracts/v3/permission-sharing.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final fixtures =
          (jsonDecode(
                    File(
                      'contracts/v3/fixtures/sharing-labels.json',
                    ).readAsStringSync(),
                  )
                  as List)
              .cast<Map<String, Object?>>();
      for (final fixture in fixtures) {
        final route = fixture['route']! as String;
        for (final side in ['request', 'response']) {
          expect(
            acceptsContract(
              fixture[side],
              schema[r'$defs']['$route-$side'],
              {},
              schema,
            ),
            isTrue,
            reason: '$route $side',
          );
        }
      }
      Map<String, Object?> response(String route) =>
          fixtures.firstWhere((f) => f['route'] == route)['response']!
              as Map<String, Object?>;
      final owner = SharingResponse.fromJson(
        response('list-sharing'),
        'list-sharing',
      ).shares.single.membership;
      expect(owner.recipientLabel, 'Fictional neighbor Ana');
      expect(owner.ownerLabel, 'Fictional Sam');
      final mine = response('list-shared-cases'),
          row = Map<String, Object?>.from(
            (mine['memberships']! as List).single as Map,
          );
      final shared = SharingResponse.fromJson(
        mine,
        'list-shared-cases',
      ).memberships.single;
      expect(shared.ownerLabel, 'Fictional Sam');
      expect(shared.recipientLabel, isNull);
      expect(
        SharingResponse.fromJson(
          response('review-invitation'),
          'review-invitation',
        ).membership!.ownerLabel,
        'Fictional Sam',
      );
      expect(
        () => SharingResponse.fromJson({
          ...mine,
          'memberships': [
            {...row, 'recipientLabel': 'Owner-only'},
          ],
        }, 'list-shared-cases'),
        throwsFormatException,
        reason: 'a recipient must never receive the owner-only label',
      );
      expect(
        acceptsContract(
          {
            ...mine,
            'memberships': [
              {...row, 'recipientLabel': 'Owner-only'},
            ],
          },
          schema[r'$defs']['list-shared-cases-response'],
          {},
          schema,
        ),
        isFalse,
      );
      for (final bad in [
        '',
        ' padded',
        'x' * 81,
        'new\nline',
        '\u202eflip',
        7,
        null,
      ]) {
        expect(
          () => CaseMembership.fromJson({...row, 'ownerLabel': bad}),
          throwsFormatException,
          reason: '$bad',
        );
      }
      final legacy = Map<String, Object?>.from(row)..remove('ownerLabel');
      expect(CaseMembership.fromJson(legacy).ownerLabel, isNull);
      expect(validSharingLabel('Fictional Ana'), isTrue);
    },
  );
}
