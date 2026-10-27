import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/requests/form_review_screen.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart'
    show MemoryPrivateStore, services, program, input;
import '../contracts/form_answers_test.dart' as fixture;
import '../services/case_evidence_api_client_test.dart' as http;

class DelayedFormStore extends MemoryPrivateStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (key.startsWith('form.') &&
        value['uncertain'] == true &&
        !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.writeJson(key, value);
  }
}

void main() {
  for (final departure in [
    'another case',
    'away and back',
    'disposed screen',
  ]) {
    testWidgets('delayed form journal cannot submit after $departure', (
      tester,
    ) async {
      final cases = <String, Map<String, Object?>>{};
      final transport = FakeTransport((request) async {
        final body = http.requestJson(request);
        if (request.endpoint.path == '/v1/create-case') {
          final saved = {...body, 'revision': 1};
          cases[body['caseId'] as String] = saved;
          return http.jsonResponse(saved);
        }
        if (request.endpoint.path == '/v2/read-form-answers') {
          return http.jsonResponse({
            ...fixture.responseJson(),
            'schemaVersion': '2',
            'caseId': body['caseId'],
            'caseRevision': 1,
            'saved': {
              ...fixture.savedJson(),
              'caseId': body['caseId'],
              'caseRevision': 1,
            },
            'fieldDefinitions': [
              {
                'key': 'memberFirstName',
                'label': 'Given name',
                'kind': 'text',
                'maxLength': 160,
              },
            ],
            'artifactKind': 'official_form_draft',
          });
        }
        throw StateError('No form write is authorized after leaving its case');
      });
      final store = DelayedFormStore();
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
          home: FormReviewScreen(
            services: app,
            program: program(programId: 'scfhp-eaa'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('form-save'));
      await tester.scrollUntilVisible(
        save,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pump();
      expect(store.entered.isCompleted, true);
      expect(app.coordinator.busy, false);
      if (departure == 'disposed screen') {
        await tester.pumpWidget(const MaterialApp(home: Text('Other screen')));
      } else {
        await app.coordinator.restoreLocal(other);
        if (departure == 'away and back') {
          await app.coordinator.restoreLocal(original);
        }
      }
      store.release.complete();
      await tester.pumpAndSettle();
      expect(
        transport.requests.where(
          (r) => r.endpoint.path == '/v2/save-form-answers',
        ),
        isEmpty,
      );
      expect(store.records['form.$original.scfhp-eaa']!['uncertain'], true);
      expect(store.records.containsKey('form.$other.scfhp-eaa'), false);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'reconcile preserves values but requires fresh review after another case revision',
    (tester) async {
      Map<String, Object?>? server;
      var answerReads = 0;
      final transport = FakeTransport((request) async {
        switch (request.endpoint.path) {
          case '/v1/create-case':
            server = {...http.requestJson(request), 'revision': 1};
            return http.jsonResponse(server);
          case '/v1/read-case':
            server = {...server!, 'revision': 2};
            return http.jsonResponse(server);
          case '/v2/read-form-answers':
            answerReads++;
            return http.jsonResponse({
              ...fixture.responseJson(),
              'schemaVersion': '2',
              'caseId': server!['caseId'],
              'caseRevision': server!['revision'],
              'saved': {
                ...fixture.savedJson(),
                'caseId': server!['caseId'],
                'caseRevision': 1,
              },
              'isCurrent': server!['revision'] == 1,
              'fieldDefinitions': [
                {
                  'key': 'memberFirstName',
                  'label': 'Given name',
                  'kind': 'text',
                  'maxLength': 160,
                },
              ],
              'artifactKind': 'official_form_draft',
            });
          default:
            throw StateError('No writes expected after initial case creation');
        }
      });
      final store = MemoryPrivateStore();
      final app = services(store, transport);
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      await app.coordinator.save();
      final match = program(programId: 'scfhp-eaa');
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: FormReviewScreen(services: app, program: match),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> reveal(Finder finder, double direction) async {
        await tester.scrollUntilVisible(
          finder,
          direction,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      expect(find.byKey(const ValueKey('form-confirmed')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('form-unconfirmed-memberFirstName')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('form-reconcile')), findsNothing);
      server = {...server!, 'revision': 2};
      await app.coordinator.adoptRemoteSnapshot(
        CaseSnapshot.fromJson({
          ...app.coordinator.currentCase().toJson(),
          'revision': 2,
        }),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: FormReviewScreen(services: app, program: match),
        ),
      );
      await tester.pumpAndSettle();
      final unconfirmed = find.byKey(
        const ValueKey('form-unconfirmed-memberFirstName'),
      );
      await reveal(unconfirmed, 250);
      expect(unconfirmed, findsOneWidget);
      expect(find.byKey(const ValueKey('form-confirmed')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('form-change-memberFirstName')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input('Given name')).controller!.text,
        'Fictional',
      );
      expect(app.coordinator.snapshot!.revision, 2);
      expect(answerReads, 2);
      final draft = store.records['form.${server!['caseId']}.scfhp-eaa']!;
      expect((draft['reviewed'] as Map)['memberFirstName'], false);
      final reconcile = find.byKey(const ValueKey('form-reconcile'));
      await reveal(reconcile, -250);
      await tester.tap(reconcile);
      await tester.pumpAndSettle();
      expect(answerReads, 3);
      await reveal(
        find.textContaining('Saved answers are from an earlier case or form.'),
        -250,
      );
      expect(find.text('Your answers were saved.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
