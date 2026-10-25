import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'app_design_test.dart' show narrowLargeText, reveal;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services, program;
import '../services/case_evidence_api_client_test.dart' as http;

class UnreadableProfileEdits extends MemoryPrivateStore {
  @override
  Future<Map<String, Object?>?> readJson(String key) async {
    if (key.startsWith('profile-edit.')) {
      throw StateError('Fictional private storage failure');
    }
    return super.readJson(key);
  }
}

void main() {
  for (final state in [
    'uncertain',
    'conflict',
    'busy',
    'device failure',
    'device pending',
  ]) {
    testWidgets('$state case cannot show clean saved success at largest text', (
      tester,
    ) async {
      narrowLargeText(tester, scale: 3.2);
      final transport = FakeTransport((request) async {
        expect(request.endpoint.path, '/v1/create-case');
        return http.jsonResponse({...http.requestJson(request), 'revision': 1});
      });
      final app = services(MemoryPrivateStore(), transport);
      addTearDown(app.dispose);
      final c = app.coordinator;
      await c.createDraft();
      await c.save();
      expect(c.hasUnsavedChanges, false);
      c.uncertain = state == 'uncertain';
      c.conflict = state == 'conflict';
      c.busy = state == 'busy';
      if (state.startsWith('device ')) {
        c.busy = true;
        c.uncertain = true;
        c.localSaveFailed = state == 'device failure';
        c.localWritePending = state == 'device pending';
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: CaseWorkspaceScreen(services: app),
        ),
      );
      await tester.pump();
      final statusFinder = find.byKey(const ValueKey('case-save-status'));
      await tester.scrollUntilVisible(
        statusFinder,
        250,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 100,
      );
      final status = tester.widget<SahNotice>(statusFinder);
      expect(status.title, switch (state) {
        'uncertain' => 'Save confirmation needed',
        'conflict' => 'Case versions need review',
        'device failure' => 'Not saved on this device',
        'device pending' => 'Saving on this device',
        _ => 'Case update in progress',
      });
      expect(status.tone, isNot(SahNoticeTone.success));
      expect(
        status.message,
        isNot('Your case matches the last saved version.'),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('case-save-online')),
        250,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 100,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('case-save-online')),
            )
            .onPressed,
        isNull,
      );
      expect(transport.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed refresh removes the previous empty-list claim', (
    tester,
  ) async {
    var reads = 0;
    final transport = FakeTransport((request) async {
      reads += 1;
      if (reads > 1) {
        throw const MatchingTransportException(
          MatchingTransportFailure.network,
        );
      }
      return http.jsonResponse({
        'schemaVersion': '1',
        'cases': [],
        'nextAfterCaseId': null,
      });
    });
    final app = services(MemoryPrivateStore(), transport);
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: CaseHomeScreen(services: app),
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.text('No saved cases yet.'));
    expect(find.text('No saved cases yet.'), findsOneWidget);
    final refreshing = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await tester.pumpAndSettle();
    await refreshing;
    await reveal(tester, find.text('Saved cases are unavailable'));
    expect(find.text('Saved cases are unavailable'), findsOneWidget);
    expect(find.text('Retry saved cases'), findsOneWidget);
    expect(find.text('No saved cases yet.'), findsNothing);
    expect(reads, 2);
    expect(transport.requests.map((r) => r.endpoint.path), [
      '/v1/list-cases',
      '/v1/list-cases',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'local-only profile restore failure does not promise a saved case',
    (tester) async {
      final transport = FakeTransport(
        (_) async => throw StateError('No network expected'),
      );
      final store = UnreadableProfileEdits();
      final app = services(store, transport);
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      final original = app.coordinator.draft!.toJson();
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProfileEditorScreen(services: app),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.textContaining('Unfinished edits could not be restored.'),
      );
      expect(
        find.text(
          'Unfinished edits could not be restored. The current case details are shown; check them before continuing.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('saved case is still available'),
        findsNothing,
      );
      expect(app.coordinator.snapshot, isNull);
      expect(app.coordinator.draft!.toJson(), original);
      expect(transport.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long intake question wraps at largest text and is spoken once', (
    tester,
  ) async {
    narrowLargeText(tester, scale: 3.2);
    const question =
        'Do you intend to remain in this home for at least two years?';
    final definition = {
      'programId': 'fictional-program',
      'questionnaireVersion': List.filled(64, 'a').join(),
      'questions': [
        {
          'key': 'remainingAtHome',
          'label': question,
          'kind': 'boolean',
          'maxLength': null,
          'description': 'Choose the resident’s reported answer.',
        },
      ],
    };
    Map<String, Object?>? server;
    final transport = FakeTransport((request) async {
      if (request.endpoint.path == '/v1/create-case') {
        server = {...http.requestJson(request), 'revision': 1};
        return http.jsonResponse(server);
      }
      expect(request.endpoint.path, '/v2/read-program-intake');
      return http.jsonResponse({
        'schemaVersion': '2',
        'caseId': server!['caseId'],
        'caseRevision': 1,
        'definition': definition,
        'saved': null,
        'isCurrent': false,
      });
    });
    final store = MemoryPrivateStore();
    final app = services(store, transport);
    addTearDown(app.dispose);
    await app.coordinator.createDraft();
    await app.coordinator.save();
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: ProgramIntakeScreen(services: app, program: program()),
      ),
    );
    await tester.pumpAndSettle();
    final fullQuestion = find.byKey(
      const ValueKey('intake-question-remainingAtHome'),
    );
    await reveal(tester, fullQuestion);
    final paragraph = tester.renderObject<RenderParagraph>(fullQuestion);
    expect(paragraph.maxLines, isNull);
    expect(paragraph.didExceedMaxLines, false);
    expect(paragraph.size.height, greaterThan(100));
    expect(
      find.ancestor(of: fullQuestion, matching: find.byType(ExcludeSemantics)),
      findsOneWidget,
    );
    final menu = find.byKey(const ValueKey('remainingAtHome-false'));
    await reveal(tester, menu);
    expect(
      find.bySemanticsLabel(RegExp(RegExp.escape(question))),
      findsOneWidget,
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('No').last);
    await tester.tap(find.text('No').last);
    await tester.pumpAndSettle();
    final key = 'intake.${app.coordinator.draft!.caseId}.fictional-program';
    expect((store.records[key]!['booleans'] as Map)['remainingAtHome'], false);
    expect(transport.requests, hasLength(2));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
