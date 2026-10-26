import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/requests/private_export_screen.dart';
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services, program;
import '../contracts/form_answers_test.dart' as fixture;
import '../services/case_evidence_api_client_test.dart' as http;

class _DelayedExportStore extends MemoryPrivateStore {
  _DelayedExportStore(this.stage);
  final String stage;
  bool armed = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> _delay(String key, String operation) async {
    if (armed &&
        key.startsWith('export.') &&
        stage == operation &&
        !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
  }

  @override
  Future<Map<String, Object?>?> readJson(String key) async {
    await _delay(key, 'read');
    return super.readJson(key);
  }

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    await _delay(key, 'write');
    await super.writeJson(key, value);
  }
}

void main() {
  for (final stage in ['read', 'write']) {
    for (final departure in [
      'another case',
      'away and back',
      'disposed screen',
    ]) {
      testWidgets(
        'delayed export journal $stage cannot submit after $departure',
        (tester) async {
          final transport = FakeTransport((request) async {
            final body = http.requestJson(request);
            switch (request.endpoint.path) {
              case '/v1/create-case':
                return http.jsonResponse({...body, 'revision': 1});
              case '/v1/list-evidence':
                return http.jsonResponse({
                  'schemaVersion': '1',
                  'caseId': body['caseId'],
                  'caseRevision': 1,
                  'catalogRevision': 0,
                  'evidence': <Object>[],
                });
              case '/v2/read-form-answers':
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
              default:
                throw StateError(
                  'No export is authorized after its screen leaves',
                );
            }
          });
          final store = _DelayedExportStore(stage);
          final app = services(store, transport);
          addTearDown(() {
            app.dispose();
            app.session.dispose();
          });
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
              home: PrivateExportScreen(
                services: app,
                program: program(programId: 'scfhp-eaa'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final prepare = find.text('Create draft PDF');
          await tester.scrollUntilVisible(
            prepare,
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(prepare);
          await tester.pumpAndSettle();
          store.armed = true;
          await tester.tap(prepare);
          await tester.pump();
          expect(store.entered.isCompleted, true);
          if (departure == 'disposed screen') {
            await tester.pumpWidget(
              const MaterialApp(home: Text('Another screen')),
            );
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
              (r) => r.endpoint.path == '/v2/create-draft-export',
            ),
            isEmpty,
          );
          expect(store.records.containsKey('export.$other.scfhp-eaa'), false);
          expect(
            store.records.containsKey('export.$original.scfhp-eaa'),
            stage == 'write',
          );
          if (stage == 'write') {
            expect(
              (store.records['export.$original.scfhp-eaa']!['request']
                  as Map)['caseId'],
              original,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        },
      );
    }
  }
}
