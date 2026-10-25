import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'app_design_test.dart' show reveal;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services, program;
import '../services/case_evidence_api_client_test.dart' as http;

Map<String, Object?> definition() => {
  'programId': 'fictional-program',
  'questionnaireVersion': List.filled(64, 'a').join(),
  'questions': [
    {
      'key': 'hasCoverage',
      'label': 'Coverage reported?',
      'kind': 'boolean',
      'maxLength': null,
      'description': 'Use the reported answer.',
    },
  ],
};

class DelayedIntakeStore extends MemoryPrivateStore {
  DelayedIntakeStore({this.read = false});
  final bool read;
  final entered = Completer<void>(), release = Completer<void>();

  Future<void> _wait(String key, bool reading) async {
    if (key.startsWith('intake.') && reading == read && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
  }

  @override
  Future<Map<String, Object?>?> readJson(String key) async {
    await _wait(key, true);
    return super.readJson(key);
  }

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    await _wait(key, false);
    await super.writeJson(key, value);
  }
}

void main() {
  for (final read in [false, true]) {
    for (final departure in [
      'another case',
      'same case reopened',
      'disposed',
    ]) {
      testWidgets(
        'delayed intake ${read ? 'read' : 'journal'} rejects $departure',
        (tester) async {
          final transport = FakeTransport((request) async {
            final body = http.requestJson(request);
            if (request.endpoint.path == '/v1/create-case') {
              return http.jsonResponse({...body, 'revision': 1});
            }
            expect(request.endpoint.path, '/v2/read-program-intake');
            return http.jsonResponse({
              'schemaVersion': '2',
              'caseId': body['caseId'],
              'caseRevision': 1,
              'definition': definition(),
              'saved': null,
              'isCurrent': false,
            });
          });
          final store = DelayedIntakeStore(read: read);
          final app = services(store, transport);
          addTearDown(app.dispose);
          await app.coordinator.createDraft();
          await app.coordinator.save();
          final original = app.coordinator.snapshot!.caseId;
          await app.coordinator.createDraft();
          await app.coordinator.save();
          final other = app.coordinator.snapshot!.caseId;
          await app.coordinator.restoreLocal(original);
          await tester.pumpWidget(
            MaterialApp(
              theme: SafeAtHomeTheme.light(),
              home: ProgramIntakeScreen(services: app, program: program()),
            ),
          );
          if (!read) {
            await tester.pumpAndSettle();
            final save = find.byKey(const ValueKey('intake-save'));
            await reveal(tester, save);
            await tester.ensureVisible(save);
            await tester.pumpAndSettle();
            await tester.tap(save);
          }
          await tester.pump();
          expect(store.entered.isCompleted, true);
          expect(app.coordinator.busy, false);
          final previousRequests = transport.requests.length;
          if (departure == 'disposed') {
            await tester.pumpWidget(
              const MaterialApp(home: Text('Other screen')),
            );
          } else {
            await app.coordinator.restoreLocal(other);
            if (departure == 'same case reopened') {
              await app.coordinator.restoreLocal(original);
            }
          }
          store.release.complete();
          await tester.pumpAndSettle();
          expect(transport.requests, hasLength(previousRequests));
          expect(
            store.records.containsKey('intake.$other.fictional-program'),
            false,
          );
          if (!read) {
            expect(
              store.records['intake.$original.fictional-program']!['uncertain'],
              true,
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'equal older intake answers are retained but never confirmed current',
    (tester) async {
      Map<String, Object?>? server;
      final transport = FakeTransport((request) async {
        if (request.endpoint.path == '/v1/create-case') {
          server = {...http.requestJson(request), 'revision': 1};
          return http.jsonResponse(server);
        }
        if (request.endpoint.path == '/v1/read-case') {
          server = {...server!, 'revision': 2};
          return http.jsonResponse(server);
        }
        expect(request.endpoint.path, '/v2/read-program-intake');
        return http.jsonResponse({
          'schemaVersion': '2',
          'caseId': server!['caseId'],
          'caseRevision': server!['revision'],
          'definition': definition(),
          'saved': {
            'schemaVersion': '2',
            'caseId': server!['caseId'],
            'caseRevision': 1,
            'programId': 'fictional-program',
            'questionnaireVersion': definition()['questionnaireVersion'],
            'intakeRevision': 1,
            'updatedAt': '2026-10-22T12:00:00.000Z',
            'updatedBy': 'fictional-owner',
            'answers': [
              {'key': 'hasCoverage', 'value': false, 'reviewState': 'reported'},
            ],
          },
          'isCurrent': server!['revision'] == 1,
        });
      });
      final store = MemoryPrivateStore();
      final app = services(store, transport);
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      await app.coordinator.save();
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProgramIntakeScreen(services: app, program: program()),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const ValueKey('intake-reconcile')));
      await tester.tap(find.byKey(const ValueKey('intake-reconcile')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('Saved answers are from an earlier case version.'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('Saved answers are from an earlier case version.'),
        findsOneWidget,
      );
      expect(
        find.text('The submitted answers are confirmed saved.'),
        findsNothing,
      );
      final saved = store
          .records['intake.${app.coordinator.snapshot!.caseId}.fictional-program']!;
      expect((saved['booleans'] as Map)['hasCoverage'], false);
      expect(saved['uncertain'], false);
      expect(app.coordinator.snapshot!.revision, 2);
      expect(
        transport.requests.where(
          (r) => r.endpoint.path == '/v2/save-program-intake',
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
