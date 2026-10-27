import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/programs/live_programs_screen.dart';
import 'package:safe_at_home/features/tracking/program_progress_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../../app/case_coordinator_test.dart' show FakeTransport;
import '../../app/live_workflows_test.dart' as live;
import '../../services/case_evidence_api_client_test.dart' as http;
import '../tracking/device_reminders_test.dart' show task;
import '../tracking/program_progress_screen_test.dart' as tracking show app;

const _caseId = '11111111-0000-4000-8000-000000000001';

Map<String, Object?> _task(String id) => {
  ...task(id).data,
  'title': 'Fictional navigation',
};

void _dispose(AppServices app) => addTearDown(() {
  app.dispose();
  app.session.dispose();
});

Widget _tasks(AppServices app, GlobalKey<ProgramProgressScreenState> key) =>
    MaterialApp(
      theme: SafeAtHomeTheme.light(),
      home: ProgramProgressScreen(key: key, services: app, tasksFirst: true),
    );

Map<String, Object?> _program(int index) => {
  'programId': 'fictional-$index',
  'programName': 'Fictional navigation program $index',
  'ruleVersion': 'fictional-rule-$index',
  'isDemo': true,
  'availability': 'unverified',
  'recheckAfter': DateTime.now()
      .toUtc()
      .add(const Duration(days: 1))
      .toIso8601String(),
  'status': 'needs_confirmation',
  'checks': [
    {
      'id': 'fictional-check',
      'status': 'unknown',
      'reasonCode': 'MANUAL_REVIEW',
      'explanation': 'Fictional requirement needs program review.',
      'missingFields': <String>[],
      'resolvedBy': 'program',
      'sourceIds': <String>[],
    },
  ],
  'sources': <Object>[],
  'requiredDocuments': <String>[],
  'intake': null,
};

void main() {
  testWidgets('Assistant opens task 20 and All tasks restores the list', (
    tester,
  ) async {
    final app = await tracking.app(
      initialTasks: [for (var i = 0; i < 20; i++) _task('task-$i')],
    );
    _dispose(app);
    final key = GlobalKey<ProgramProgressScreenState>();
    await tester.pumpWidget(_tasks(app, key));
    await tester.pumpAndSettle();
    expect(find.text('Fictional navigation task-0'), findsOneWidget);
    expect(
      find.text('Fictional navigation task-19').hitTestable(),
      findsNothing,
    );

    key.currentState!.openAssistantTask('task-19');
    await tester.pumpAndSettle();
    expect(
      find.text('Fictional navigation task-19').hitTestable(),
      findsOneWidget,
    );
    expect(find.text('Fictional navigation task-0'), findsNothing);
    expect(find.text('All tasks'), findsOneWidget);

    await tester.tap(find.text('All tasks'));
    await tester.pumpAndSettle();
    expect(find.text('All tasks'), findsNothing);
    expect(
      find.text('Fictional navigation task-0').hitTestable(),
      findsOneWidget,
    );
    expect(app.progress!.cached[_caseId]!.tasks, hasLength(20));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Assistant ignores deleted and stale task targets', (
    tester,
  ) async {
    MatchingHttpResponse? nextRead;
    final app = await tracking.app(
      initialTasks: [_task('retained'), _task('deleted')],
      readResponse: () async => nextRead,
    );
    _dispose(app);
    final key = GlobalKey<ProgramProgressScreenState>();
    await tester.pumpWidget(_tasks(app, key));
    await tester.pumpAndSettle();

    nextRead = http.jsonResponse({
      'schemaVersion': '3',
      'caseId': _caseId,
      'caseRevision': 1,
      'revision': 1,
      'programs': <Object>[],
      'tasks': [
        {..._task('retained'), 'title': 'Fictional navigation retained'},
      ],
      'nextOffset': null,
      'acknowledgedMutationId': null,
      'historyVersion': 'e' * 64,
    });
    await app.progress!.refresh(_caseId);
    await tester.pumpAndSettle();
    key.currentState!.openAssistantTask('deleted');
    await tester.pumpAndSettle();
    expect(find.text('All tasks'), findsNothing);
    expect(find.text('Fictional navigation retained'), findsOneWidget);
    expect(find.text('Fictional navigation deleted'), findsNothing);

    await app.coordinator.clearSelected();
    key.currentState!.openAssistantTask('retained');
    await tester.pumpWidget(_tasks(app, key));
    await tester.pumpAndSettle();
    expect(find.text('All tasks'), findsNothing);
    expect(find.text('Fictional navigation retained'), findsNothing);
    expect(
      find.text('The plan changed. Reopen it before editing next steps.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Assistant opens program 20, restores all programs, and ignores stale targets',
    (tester) async {
      final transport = FakeTransport((request) async {
        final body = http.requestJson(request);
        if (request.endpoint.path == '/v1/create-case') {
          return http.jsonResponse({...body, 'revision': 1});
        }
        if (request.endpoint.path == '/v1/match-case') {
          final now = DateTime.now().toUtc().toIso8601String();
          return http.jsonResponse({
            'schemaVersion': '1',
            'caseId': body['caseId'],
            'caseRevision': body['expectedCaseRevision'],
            'evaluatedAt': now,
            'evaluationDate': now.substring(0, 10),
            'matches': [for (var i = 0; i < 20; i++) _program(i)],
          });
        }
        throw StateError('Only fictional matching is configured');
      });
      final app = live.services(live.MemoryPrivateStore(), transport);
      _dispose(app);
      await app.coordinator.createDraft();
      await app.coordinator.save();
      final key = GlobalKey<LiveProgramsScreenState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: LiveProgramsScreen(key: key, services: app),
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.assistantMatches!.matches, hasLength(20));
      expect(find.text('Fictional navigation program 19'), findsNothing);

      key.currentState!.openAssistantProgram('fictional-19');
      await tester.pumpAndSettle();
      expect(
        find.text('Fictional navigation program 19').hitTestable(),
        findsOneWidget,
      );
      expect(find.text('Fictional navigation program 0'), findsNothing);
      expect(find.text('Rule version: fictional-rule-19'), findsOneWidget);
      await tester.tap(find.text('All programs'));
      await tester.pumpAndSettle();
      expect(find.text('All programs'), findsNothing);
      expect(
        find.text('Fictional navigation program 0').hitTestable(),
        findsOneWidget,
      );

      key.currentState!.openAssistantProgram('missing-program');
      await tester.pumpAndSettle();
      expect(find.text('All programs'), findsNothing);

      final before = app.coordinator.draft!.toJson();
      await app.coordinator.updateDraft(
        CaseDraft.fromJson({
          ...before,
          'profile': {
            ...before['profile'] as Map,
            'city': 'Fictional changed city',
          },
        }),
      );
      expect(key.currentState!.assistantMatches, isNull);
      key.currentState!.openAssistantProgram('fictional-19');
      await tester.pumpAndSettle();
      expect(find.text('All programs'), findsNothing);
      expect(find.text('Fictional navigation program 19'), findsNothing);
      await app.coordinator.clearSelected();
      key.currentState!.openAssistantProgram('fictional-0');
      await tester.pumpAndSettle();
      expect(find.text('All programs'), findsNothing);
      expect(find.text('Fictional navigation program 0'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
