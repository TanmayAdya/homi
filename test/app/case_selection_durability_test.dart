import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/shared/models/case_list.dart';
import 'case_coordinator_test.dart' show FakeTransport;
import 'case_local_durability_test.dart' show ControlledCaseStore, changeCity;
import 'live_workflows_test.dart' show services;
import '../services/case_evidence_api_client_test.dart' as http;

void main() {
  testWidgets(
    'failed device save can resume its in-memory case and retry offline',
    (tester) async {
      final store = ControlledCaseStore();
      final transport = FakeTransport((request) async {
        if (request.endpoint.path != '/v1/list-cases') {
          throw StateError(
            'Retrying device persistence must not send a mutation',
          );
        }
        return http.jsonResponse({
          'schemaVersion': '1',
          'cases': [],
          'nextAfterCaseId': null,
        });
      });
      final app = services(store, transport);
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      final c = app.coordinator;
      await c.createDraft();
      final id = c.currentDraft().caseId;
      c.uncertain = true;
      store.hold = true;
      final saving = c.updateDraft(
        changeCity(c.currentDraft(), 'Fictional retained correction'),
      );
      final failed = expectLater(saving, throwsStateError);
      store.pending.single.completeError(StateError('Fictional full storage'));
      await failed;
      store.hold = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: CaseHomeScreen(services: app),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('case-start')))
            .onPressed,
        isNull,
      );
      final keep = find.byKey(const ValueKey('continue-undurable-case'));
      await tester.ensureVisible(keep);
      await tester.pumpAndSettle();
      await tester.tap(keep);
      await tester.pumpAndSettle();
      expect(c.currentDraft().caseId, id);
      expect(c.currentDraft().profile.city, 'Fictional retained correction');
      final retry = find.byKey(const ValueKey('case-retry-device-save'));
      await tester.scrollUntilVisible(
        retry,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(c.hasUndurableEdits, false);
      expect(c.uncertain, true);
      final persisted = store.records['case.$id']!;
      expect(persisted['uncertain'], true);
      expect(
        ((persisted['draft'] as Map)['profile'] as Map)['city'],
        'Fictional retained correction',
      );
      expect(
        transport.requests.every((r) => r.endpoint.path == '/v1/list-cases'),
        true,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('case-start')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('case-start')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final state in ['pending', 'failed']) {
    for (final action in ['create', 'local resume', 'server resume']) {
      test(
        '$action preserves the current draft while its device save is $state',
        () async {
          final store = ControlledCaseStore();
          final transport = FakeTransport(
            (_) async => throw StateError('No remote request expected'),
          );
          final app = services(store, transport);
          addTearDown(() {
            app.dispose();
            app.session.dispose();
          });
          final c = app.coordinator;
          await c.createDraft();
          final original = c.currentDraft().caseId;
          await c.createDraft();
          final other = c.currentDraft().caseId;
          await c.restoreLocal(original);
          store.hold = true;
          final saving = c.updateDraft(
            changeCity(c.currentDraft(), 'Fictional unsaved correction'),
          );
          final failed = expectLater(saving, throwsStateError);
          store.hold = false;
          if (state == 'failed') {
            store.pending.single.completeError(
              StateError('Fictional disk failure'),
            );
            await failed;
          }
          try {
            final depart = switch (action) {
              'create' => c.createDraft(),
              'local resume' => c.restoreLocal(other),
              _ => c.resume(
                CaseSummary.fromJson({'caseId': other, 'caseRevision': 1}),
              ),
            };
            await expectLater(depart, throwsStateError);
            expect(c.currentDraft().caseId, original);
            expect(
              c.currentDraft().profile.city,
              'Fictional unsaved correction',
            );
            expect(transport.requests, isEmpty);
            expect(c.localWritePending, state == 'pending');
            expect(c.localSaveFailed, state == 'failed');
          } finally {
            if (!store.pending.single.isCompleted) {
              store.pending.single.completeError(
                StateError('Fictional disk failure'),
              );
            }
            await failed;
          }
        },
      );
    }
  }
}
