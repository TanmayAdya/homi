import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/tracking/program_progress_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/tracking.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../../app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../../app/live_workflows_test.dart' show MemoryPrivateStore;
import '../../services/case_evidence_api_client_test.dart' as http;
import 'device_reminders_test.dart' show FakeNotificationDevice, task;

const _caseId = '11111111-0000-4000-8000-000000000001';

Future<AppServices> app({
  List<Map<String, Object?>> programs = const [],
  List<Map<String, Object?>>? initialTasks,
  Future<MatchingHttpResponse?> Function()? readResponse,
  FakeNotificationDevice? device,
  List<Map<String, Object?>>? saved,
}) async {
  final store = MemoryPrivateStore(),
      tasks = (initialTasks ?? [task('one').data, task('two').data])
          .map(
            (t) => <String, Object?>{
              ...t,
              'title': '${t['title']} ${t['id']}',
              if (programs.isNotEmpty) 'programId': programs.first['programId'],
            },
          )
          .toList();
  var revision = 0;
  final transport = FakeTransport((request) async {
    final body = jsonDecode(utf8.decode(request.body)) as Map;
    if (request.endpoint.path == '/v3/read-progress') {
      final response = await readResponse?.call();
      if (response != null) return response;
    }
    String? ack;
    if (request.endpoint.path == '/v3/save-progress') {
      expect(store.records['progress-pending.$_caseId'], isNotNull);
      final operation = body['operation'] as Map,
          incoming = Map<String, Object?>.from(operation['task'] as Map);
      saved?.add(Map<String, Object?>.from(operation));
      final index = tasks.indexWhere((t) => t['id'] == incoming['id']);
      incoming['needsReview'] = false;
      if (index < 0) {
        tasks.add(incoming);
      } else {
        tasks[index] = incoming;
      }
      revision++;
      ack = body['mutationId'] as String;
    }
    return http.jsonResponse({
      'schemaVersion': '3',
      'caseId': _caseId,
      'caseRevision': 1,
      'revision': revision,
      'programs': programs,
      'tasks': tasks,
      'nextOffset': null,
      'acknowledgedMutationId': ack,
      'historyVersion': 'f' * 64,
    });
  });
  final services = AppServices(
    config: LiveAppConfig(
      apiOrigin: Uri.parse('https://example.org'),
      supabaseUrl: Uri.parse('https://fictional.supabase.co'),
      publishableKey: 'fictional',
      trackingEnabled: true,
    ),
    session: FakeSession(),
    store: store,
    transport: transport,
    notificationDevice: device ?? FakeNotificationDevice(),
  );
  await services.progressReady;
  final draft = CaseDraft.fromJson({
    'schemaVersion': '1',
    'caseId': _caseId,
    'profile': {
      'city': null,
      'county': null,
      'healthPlan': null,
      'tenure': null,
      'ageYears': null,
      'householdSize': null,
      'annualIncomeUsd': null,
      'ownerConsentReported': null,
    },
    'unresolvedFields': <Object>[],
    'findings': <Object>[],
  });
  await store.writeJson('case.$_caseId', {
    'version': 1,
    'draft': draft.toJson(),
    'snapshot': draft.atRevision(1).toJson(),
    'uncertain': false,
    'conflict': false,
  });
  await services.coordinator.restoreLocal(_caseId);
  return services;
}

void main() {
  testWidgets(
    'program dashboard separates unresolved requirements from tasks and retains retired reports',
    (tester) async {
      Map<String, Object?> program(String id, {bool retired = false}) => {
        'programId': id,
        'name': 'Fictional $id',
        'trackedAt': '2026-10-24T12:00:00.000Z',
        'trackedBy': 'fictional-owner',
        'latest': !retired
            ? null
            : {
                'updateId': '11111111-0000-4000-8000-000000000099',
                'status': 'withdrawn',
                'occurredOn': '2026-10-23',
                'source': 'self_report',
                'note': null,
                'nextAction': null,
                'responsibleParty': null,
                'followUpOn': null,
                'revision': 1,
                'caseRevision': 1,
                'recordedAt': '2026-10-24T12:00:00.000Z',
                'recordedBy': 'fictional-reporter',
              },
        'proposal': null,
        'retired': retired,
        'ruleVersion': retired ? null : 'fictional-r1',
        'unresolvedRequirements': retired ? 0 : 1,
        'requirements': retired
            ? null
            : [
                {
                  'id': 'fictional-check',
                  'status': 'unknown',
                  'explanation': 'Fictional income check needs confirmation',
                },
              ],
      };
      final services = await app(
        programs: [program('active'), program('retired', retired: true)],
      );
      addTearDown(() {
        services.dispose();
        services.session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProgramProgressScreen(services: services),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fictional active'), findsOneWidget);
      expect(find.text('Not started / no update recorded'), findsOneWidget);
      expect(find.text('Unresolved program requirements: 1'), findsOneWidget);
      expect(find.text('Open tasks: 2'), findsOneWidget);
      expect(
        find.text(
          'Needs confirmation: Fictional income check needs confirmation',
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Fictional retired'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Withdrawn'), findsOneWidget);
      expect(
        find.text(
          'No longer in the current program registry. History is retained.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Reported 2026-10-24T12:00:00.000Z by fictional-reporter'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'checkbox completes one task and quick add creates another with defaults',
    (tester) async {
      final saved = <Map<String, Object?>>[];
      final services = await app(saved: saved);
      addTearDown(() {
        services.dispose();
        services.session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProgramProgressScreen(services: services, tasksFirst: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(2));
      expect(find.text('Complete task'), findsNothing);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('Done (1)'), findsOneWidget);
      expect(saved.last['task'], containsPair('state', 'completed'));
      await tester.enterText(
        find.byKey(const ValueKey('task-quick-add')),
        '  Fictional provider call  ',
      );
      await tester.tap(find.byKey(const ValueKey('task-quick-add-button')));
      await tester.pumpAndSettle();
      final added = saved.last;
      expect(added['type'], 'put_task');
      expect(added['expectedTaskRevision'], 0);
      expect(added['task'], containsPair('title', 'Fictional provider call'));
      expect(added['task'], containsPair('kind', 'other'));
      expect(added['task'], containsPair('state', 'pending'));
      expect(added['task'], containsPair('dueOn', null));
      expect(added['task'], containsPair('responsiblePerson', null));
      expect(added['task'], containsPair('revision', 1));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('task-quick-add')))
            .controller!
            .text,
        isEmpty,
      );
      expect(services.progress!.cached[_caseId]!.tasks.length, 3);
      expect(
        services.progress!.cached[_caseId]!.tasks.where((t) => t.open).length,
        2,
      );
      expect(services.progress!.pending, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('completed tasks can reopen without changing other tasks', (
    tester,
  ) async {
    final services = await app();
    addTearDown(() {
      services.dispose();
      services.session.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: ProgramProgressScreen(services: services, tasksFirst: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    final completed = services.progress!.cached[_caseId]!.tasks.firstWhere(
      (t) => !t.open,
    );
    expect(find.text(completed.title), findsNothing, reason: 'Done collapses');
    await tester.tap(find.text('Done (1)'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('task-done-${completed.id}')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    final tasks = services.progress!.cached[_caseId]!.tasks;
    expect(tasks.every((t) => t.open), isTrue);
    expect(
      tasks.firstWhere((t) => t.id == completed.id).revision,
      completed.revision + 1,
    );
    expect(services.progress!.pending, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'loading is not an empty task list and successful empty state can add',
    (tester) async {
      final gate = Completer<MatchingHttpResponse?>();
      final services = await app(
        initialTasks: [],
        readResponse: () => gate.future,
      );
      addTearDown(() {
        services.dispose();
        services.session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: Scaffold(
            body: ProgramProgressScreen(
              services: services,
              tasksFirst: true,
              embedded: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Loading tasks and program progress'), findsOneWidget);
      expect(find.text('Nothing to do yet'), findsNothing);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      gate.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('Nothing to do yet'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('task-quick-add-button')),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final (code, status, message) in [
    (
      'NOT_FOUND',
      404,
      'Tasks are unavailable on this service. Try again after the service is updated.',
    ),
    (
      'SERVICE_UNAVAILABLE',
      503,
      'Tasks are temporarily unavailable. Try again later.',
    ),
    (
      'INTERNAL_ERROR',
      500,
      'The service could not finish the request. Try again.',
    ),
  ]) {
    testWidgets('$code has recovery and never claims a healthy empty list', (
      tester,
    ) async {
      var fail = true;
      final services = await app(
        initialTasks: [],
        readResponse: () async => fail ? http.apiError(code, status) : null,
      );
      addTearDown(() {
        services.dispose();
        services.session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProgramProgressScreen(services: services, tasksFirst: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(find.text('Nothing to do yet'), findsNothing);
      expect(find.textContaining('Private server'), findsNothing);
      fail = false;
      await tester.ensureVisible(
        find.byKey(const ValueKey('progress-retry-load')),
      );
      await tester.tap(find.byKey(const ValueKey('progress-retry-load')));
      await tester.pumpAndSettle();
      expect(find.text('Nothing to do yet'), findsOneWidget);
      expect(find.text(message), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'failed refresh preserves cached tasks and disables writes until recovery',
    (tester) async {
      var fail = false;
      final services = await app(
        readResponse: () async {
          if (fail) throw MatchingApiException.forCode('NETWORK_ERROR');
          return null;
        },
      );
      addTearDown(() {
        services.dispose();
        services.session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProgramProgressScreen(services: services, tasksFirst: true),
        ),
      );
      await tester.pumpAndSettle();
      fail = true;
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Cannot connect. Showing the last saved tasks; refresh before making changes.',
        ),
        findsOneWidget,
      );
      expect(services.progress!.cached[_caseId]!.tasks, hasLength(2));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('task-quick-add-button')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).onChanged,
        isNull,
      );
      expect(
        tester.widget<ListTile>(find.byType(ListTile).first).onTap,
        isNull,
      );
      fail = false;
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).onChanged,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('background access loss removes cached task content', (
    tester,
  ) async {
    var revoked = false;
    final services = await app(
      readResponse: () async =>
          revoked ? http.apiError('CASE_NOT_FOUND', 404) : null,
    );
    addTearDown(() {
      services.dispose();
      services.session.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: ProgramProgressScreen(services: services, tasksFirst: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(services.progress!.cached[_caseId]!.tasks, hasLength(2));
    revoked = true;
    await services.progress!.refreshAll();
    await tester.pumpAndSettle();
    expect(services.progress!.cached[_caseId], isNull);
    expect(
      find.textContaining('Fictional private health paperwork'),
      findsNothing,
    );
    expect(
      find.text('This case is unavailable to the signed-in user.'),
      findsOneWidget,
    );
    expect(find.text('Nothing to do yet'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Spanish large-text dashboard preserves resident content and exposes task actions',
    (tester) async {
      final services = await app();
      addTearDown(() {
        services.dispose();
        services.session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          locale: const Locale('es'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ProgramProgressScreen(services: services, tasksFirst: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mis próximos pasos'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Fictional private health paperwork one'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Fictional private health paperwork one'), findsWidgets);
      expect(services.progress!.cached[_caseId]!.tasks.length, 2);
      expect(find.byType(Checkbox), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Tasks tab suggests a task from a tracked program and keeps program progress secondary',
    (tester) async {
      final saved = <Map<String, Object?>>[];
      final services = await app(
        saved: saved,
        initialTasks: [],
        programs: [
          {
            'programId': 'fictional-program',
            'name': 'Fictional repair grant',
            'trackedAt': '2026-10-24T12:00:00.000Z',
            'trackedBy': 'fictional-owner',
            'latest': null,
            'proposal': null,
            'retired': false,
            'ruleVersion': 'fictional-r1',
            'unresolvedRequirements': 2,
            'requirements': null,
          },
        ],
      );
      addTearDown(() {
        services.dispose();
        services.session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: Scaffold(
            body: ProgramProgressScreen(
              services: services,
              tasksFirst: true,
              workspaceMode: true,
              embedded: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tasks'), findsOneWidget);
      expect(find.text('Program progress'), findsNothing);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      expect(find.text('Suggested for you'), findsOneWidget);
      expect(find.text('Nothing to do yet'), findsOneWidget);
      const title = 'Confirm what Fictional repair grant still needs';
      expect(find.text(title), findsOneWidget);
      expect(saved, isEmpty, reason: 'suggestions are never added silently');
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, title),
          matching: find.widgetWithText(TextButton, 'Add'),
        ),
      );
      await tester.pumpAndSettle();
      final task = saved.single['task'] as Map;
      expect(task['title'], title);
      expect(task['programId'], 'fictional-program');
      expect(task['basedOnRuleVersion'], 'fictional-r1');
      expect(task['kind'], 'documents');
      expect(
        find.text(title),
        findsOneWidget,
        reason: 'now a task, not a suggestion',
      );
      expect(find.text('Suggested for you'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Tracked programs'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Fictional repair grant'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'task page edits the date with a picker, keeps ISO on the wire, and manages the device reminder',
    (tester) async {
      final saved = <Map<String, Object?>>[];
      final device = FakeNotificationDevice();
      final services = await app(saved: saved, device: device);
      addTearDown(() {
        services.dispose();
        services.session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProgramProgressScreen(services: services, tasksFirst: true),
        ),
      );
      await tester.pumpAndSettle();
      final first = services.progress!.cached[_caseId]!.tasks.first;
      await tester.tap(find.text(first.title));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Task'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'What needs doing?'), findsOne);
      expect(find.text('Saturday, January 5, 2030'), findsOneWidget);

      await tester.tap(find.text('Device reminder'));
      await tester.pumpAndSettle();
      expect(find.text('Saturday, January 5, 2030'), findsNWidgets(2));
      expect(find.text('9:00 AM'), findsOneWidget);
      await tester.tap(find.text('Enable reminder'));
      await tester.pumpAndSettle();
      final reminder = services.progress!.reminders.forTask(_caseId, first.id)!;
      expect(reminder.enabled, isTrue);
      expect(reminder.data['date'], '2030-01-05');
      expect(reminder.data['time'], '09:00');
      expect(reminder.zone, 'America/Los_Angeles');
      expect(device.scheduled, hasLength(1));
      expect(find.text('Snooze reminder'), findsOneWidget);
      await tester.tap(find.text('Disable reminder'));
      await tester.pumpAndSettle();
      expect(
        services.progress!.reminders.forTask(_caseId, first.id)!.enabled,
        isFalse,
      );
      expect(device.scheduled, isEmpty);
      expect(saved, isEmpty, reason: 'reminders stay on this phone');

      await tester.tap(find.text('Saturday, January 5, 2030'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Sunday, January 20, 2030'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'For (optional note)'),
        'Fictional neighbor',
      );
      await tester.scrollUntilVisible(
        find.text('Save task'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save task'));
      await tester.pumpAndSettle();
      final task = saved.single['task'] as Map;
      expect(task['id'], first.id);
      expect(task['dueOn'], '2030-01-20');
      expect(task['responsiblePerson'], 'Fictional neighbor');
      expect(task['kind'], first.kind);
      expect(saved.single['expectedTaskRevision'], first.revision);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new task page is titled New task and defers reminders', (
    tester,
  ) async {
    final services = await app();
    addTearDown(() {
      services.dispose();
      services.session.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: ProgramProgressScreen(services: services, tasksFirst: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add with details'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'New task'), findsOneWidget);
    expect(find.text('No target date'), findsOneWidget);
    expect(
      find.text(
        'You can set a reminder on this phone after the task is saved.',
      ),
      findsOneWidget,
    );
    expect(find.text('Device reminder'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  test('all new catalogs preserve placeholders in all five translations', () {
    final placeholders = RegExp(r'\{[a-zA-Z]+\}');
    for (final entry in trackingTranslations.entries) {
      expect(entry.value.keys.toSet(), {
        'es',
        'zh-Hans',
        'zh-Hant',
        'vi',
        'fil',
      }, reason: entry.key);
      final original = placeholders
          .allMatches(entry.key)
          .map((m) => m[0])
          .toSet();
      for (final translated in entry.value.values) {
        expect(
          placeholders.allMatches(translated).map((m) => m[0]).toSet(),
          original,
          reason: entry.key,
        );
      }
    }
  });
}
