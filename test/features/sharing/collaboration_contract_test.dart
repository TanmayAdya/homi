import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/collaboration.dart';
import 'package:safe_at_home/shared/models/sharing.dart';
import '../../support/contract_schema.dart';

List<Map<String, Object?>> collaborationFixtures() =>
    (jsonDecode(
              File(
                'contracts/v3/fixtures/sharing-collaboration.json',
              ).readAsStringSync(),
            )
            as List)
        .cast<Map<String, Object?>>();
Map<String, Object?> collaborationFixture(String route) =>
    collaborationFixtures().firstWhere((v) => v['route'] == route)['response']!
        as Map<String, Object?>;
void main() {
  test(
    'all collaboration request/response fixtures satisfy schema and typed Dart boundaries',
    () {
      final schema =
          jsonDecode(
                File(
                  'contracts/v3/sharing-collaboration.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final fixture in collaborationFixtures()) {
        expect(
          acceptsContract(
            fixture['request'],
            schema[r'$defs'][fixture['route']],
            {},
            schema,
          ),
          isTrue,
        );
        expect(
          acceptsContract(
            fixture['response'],
            schema[r'$defs']['state'],
            {},
            schema,
          ),
          isTrue,
        );
        final state = SharingResponse.fromJson(
          fixture['response'],
          fixture['route']! as String,
        ).collaboration!;
        expect(state.tasks.single.title, 'Fictional selected task');
      }
    },
  );
  test(
    'raw task/import fields, out-of-scope tasks and premature proposal approval are rejected',
    () {
      final original = collaborationFixture('read-collaboration'),
          task = Map<String, Object?>.from(
            (original['tasks'] as List).single as Map,
          );
      for (final key in [
        'referral',
        'imported',
        'contactNote',
        'evidence',
        'formAnswers',
      ]) {
        expect(
          () => CollaborationState.fromJson({
            ...original,
            'tasks': [
              {...task, key: 'private'},
            ],
          }),
          throwsFormatException,
        );
      }
      expect(
        () => CollaborationState.fromJson({
          ...original,
          'scope': {
            'taskIds': [],
            'allowTaskProgress': true,
            'allowStatusProposals': true,
          },
        }),
        throwsFormatException,
      );
      final proposed = collaborationFixture('propose-shared-status'),
          proposal = Map<String, Object?>.from(
            (proposed['proposals'] as List).single as Map,
          );
      expect(
        () => CollaborationState.fromJson({
          ...proposed,
          'proposals': [
            {...proposal, 'state': 'accepted'},
          ],
        }),
        throwsFormatException,
      );
    },
  );
}
