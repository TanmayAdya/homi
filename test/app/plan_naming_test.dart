import 'homi_navigation_support.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';

import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'case_local_durability_test.dart' show changeCity;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

class _NameStore extends MemoryPrivateStore {
  bool failWrites = false;
  Completer<Map<String, Object?>?>? delayedNameRead;
  int delayedNameReads = 0;

  @override
  Future<Map<String, Object?>?> readJson(String key) async {
    if (key.startsWith('case.') && delayedNameRead != null) {
      delayedNameReads++;
      return delayedNameRead!.future;
    }
    return super.readJson(key);
  }

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (failWrites) throw StateError('Fictional private storage failure');
    await super.writeJson(key, value);
  }
}

void main() {
  late _NameStore store;
  late FakeTransport transport;
  late AppServices app;
  final remoteCases = <String, Map<String, Object?>>{};
  final remoteNames = <String, Map<String, Object?>>{};

  void initialize({_NameStore? existingStore}) {
    store = existingStore ?? _NameStore();
    if (existingStore == null) {
      remoteCases.clear();
      remoteNames.clear();
    }
    transport = FakeTransport((request) async {
      final body = http.requestJson(request);
      final id = body['caseId'] as String?;
      Map<String, Object?> nameState(String id) =>
          remoteNames[id] ??
          {
            'schemaVersion': '2',
            'caseId': id,
            'name': null,
            'nameRevision': 0,
            'lastMutationId': null,
          };
      switch (request.endpoint.path) {
        case '/v2/list-cases':
          return http.jsonResponse({
            'schemaVersion': '2',
            'cases': [
              for (final id in remoteCases.keys.toList()..sort())
                {
                  'caseId': id,
                  'caseRevision': remoteCases[id]!['revision'],
                  'name': nameState(id)['name'],
                  'nameRevision': nameState(id)['nameRevision'],
                  'lastMutationId': nameState(id)['lastMutationId'],
                },
            ],
            'nextAfterCaseId': null,
          });
        case '/v1/create-case':
          remoteCases[id!] = {...body, 'revision': 1};
          return http.jsonResponse(remoteCases[id]);
        case '/v2/read-plan-name':
          return remoteCases.containsKey(id)
              ? http.jsonResponse(nameState(id!))
              : http.apiError('CASE_NOT_FOUND', 404);
        case '/v2/save-plan-name':
          if (!remoteCases.containsKey(id)) {
            return http.apiError('CASE_NOT_FOUND', 404);
          }
          final previous = nameState(id!);
          if (body['expectedNameRevision'] != previous['nameRevision']) {
            return http.apiError('PLAN_NAME_CONFLICT', 409);
          }
          remoteNames[id] = {
            'schemaVersion': '2',
            'caseId': id,
            'name': body['name'],
            'nameRevision': (previous['nameRevision'] as int) + 1,
            'lastMutationId': body['mutationId'],
          };
          return http.jsonResponse(remoteNames[id]);
        default:
          throw StateError('Unexpected fictional naming request');
      }
    });
    app = services(store, transport);
  }

  void expectMetadataRequests({int creates = 0}) {
    expect(
      transport.requests.where((r) => r.endpoint.path == '/v1/create-case'),
      hasLength(creates),
    );
    expect(
      transport.requests.every(
        (r) => {
          '/v2/list-cases',
          '/v2/read-plan-name',
          '/v2/save-plan-name',
          '/v1/create-case',
        }.contains(r.endpoint.path),
      ),
      true,
    );
  }

  Future<void> tick(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
  }

  Future<void> openHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: CaseHomeScreen(services: app),
      ),
    );
    await tick(tester);
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    final scroll = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scroll).position.jumpTo(0);
    await tick(tester);
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        200,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
    }
    await tester.ensureVisible(target);
    await tick(tester);
  }

  Future<void> start(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('case-start'));
    await reveal(tester, button);
    await tester.tap(button);
    await tick(tester);
    expect(find.text('Name your plan'), findsOneWidget);
  }

  Future<void> closePendingName(WidgetTester tester) async {
    final close = find.text('Close');
    if (close.evaluate().isNotEmpty) {
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('Name saved on this device'),
        ),
        findsOneWidget,
      );
      await tester.tap(close);
      await tick(tester);
    }
  }

  Future<void> saveName(WidgetTester tester, String value) async {
    final field = find.byKey(const ValueKey('plan-name-input'));
    await reveal(tester, field);
    await tester.enterText(field, value);
    tester.testTextInput.hide();
    await tester.pump();
    final save = find.byKey(const ValueKey('plan-name-save'));
    await reveal(tester, save);
    await tester.tap(save);
    await tick(tester);
    await closePendingName(tester);
  }

  Future<void> plans(WidgetTester tester) async {
    await openManagePlans(tester);
    await tick(tester);
  }

  Future<void> choosePlanAction(
    WidgetTester tester,
    String id,
    String label,
  ) async {
    final menu = find.byKey(ValueKey('plan-actions-$id'));
    await reveal(tester, menu);
    await tester.tap(menu);
    await tick(tester);
    await tester.tap(find.text(label));
    await tick(tester);
  }

  String title(WidgetTester tester, String id) {
    final local = find.byKey(ValueKey('local-case-$id'));
    return tester
        .widget<SahActionTile>(
          local.evaluate().isNotEmpty
              ? local
              : find.byKey(ValueKey('saved-case-$id')),
        )
        .title;
  }

  tearDown(() {
    app.dispose();
    app.session.dispose();
  });

  testWidgets('cancelling the new-plan name creates no empty plan', (
    tester,
  ) async {
    initialize();
    await openHome(tester);
    await start(tester);
    await tester.enterText(
      find.byKey(const ValueKey('plan-name-input')),
      'Unfinished name',
    );
    await tester.tap(find.text('Cancel'));
    await tick(tester);
    expect(app.coordinator.draft, isNull);
    expect(await app.coordinator.localCaseIds(), isEmpty);
    expect(find.byType(CaseWorkspaceScreen), findsNothing);
    expectMetadataRequests();
  });

  testWidgets('named plan opens with its name and survives app restart', (
    tester,
  ) async {
    initialize();
    await openHome(tester);
    await start(tester);
    await saveName(tester, 'Cedar house');
    final id = app.coordinator.currentDraft().caseId;
    expect(find.byType(CaseWorkspaceScreen), findsOneWidget);
    expect(find.text('Cedar house'), findsWidgets);
    expectMetadataRequests(creates: 1);
    expect(remoteNames[id]!['name'], 'Cedar house');
    await tester.pumpWidget(const SizedBox());
    app.dispose();
    app.session.dispose();
    final persisted = store;
    initialize(existingStore: persisted);
    await openHome(tester);
    await plans(tester);
    expect(title(tester, id), 'Cedar house');
    expectMetadataRequests();
  });

  testWidgets('blank name is optional when creating a plan', (tester) async {
    initialize();
    await openHome(tester);
    await start(tester);
    await saveName(tester, '');
    expect(find.byType(CaseWorkspaceScreen), findsOneWidget);
    expect(find.text('Home safety plan'), findsWidgets);
    expect(await app.coordinator.localCaseIds(), hasLength(1));
    expectMetadataRequests(creates: 1);
  });

  testWidgets(
    'list rename preserves selection and updates search and deletion',
    (tester) async {
      initialize();
      await app.coordinator.createDraft();
      final target = app.coordinator.currentDraft().caseId;
      await app.coordinator.updateDraft(
        changeCity(app.coordinator.currentDraft(), 'San José'),
      );
      await app.coordinator.createDraft();
      final selected = app.coordinator.currentDraft().caseId;
      final generation = app.coordinator.generation;
      await openHome(tester);
      await plans(tester);
      await choosePlanAction(tester, target, 'Rename plan');
      await saveName(tester, 'Oak cottage');
      expect(app.coordinator.currentDraft().caseId, selected);
      expect(app.coordinator.generation, generation);
      expect(title(tester, target), 'Oak cottage');
      final search = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.label is Text &&
            (widget.decoration!.label! as Text).data == 'Search loaded plans',
      );
      await reveal(tester, search);
      await tester.enterText(search, 'Oak');
      tester.testTextInput.hide();
      await tick(tester);
      expect(find.byKey(ValueKey('local-case-$target')), findsOneWidget);
      expect(find.byKey(ValueKey('local-case-$selected')), findsNothing);
      await tester.enterText(search, 'San José');
      tester.testTextInput.hide();
      await tick(tester);
      expect(find.byKey(ValueKey('local-case-$target')), findsOneWidget);
      expect(title(tester, target), 'Oak cottage');
      expect(find.byKey(ValueKey('local-case-$selected')), findsNothing);
      await choosePlanAction(tester, target, 'Delete plan');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('plan-deletion-dialog')),
          matching: find.text('Oak cottage'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tick(tester);
      expect(
        await app.coordinator.localCaseIds(),
        containsAll([target, selected]),
      );
      expectMetadataRequests();
    },
  );

  testWidgets(
    'managed rename can cancel or reset without cluttering the plan',
    (tester) async {
      initialize();
      await openHome(tester);
      await start(tester);
      await saveName(tester, 'Cedar house');
      expect(find.byKey(const ValueKey('plan-rename')), findsNothing);
      final target = app.coordinator.currentDraft().caseId;
      await plans(tester);
      await choosePlanAction(tester, target, 'Rename plan');
      expect(find.text('Cedar house'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('plan-name-input')),
        'Cancelled replacement',
      );
      await tester.tap(find.text('Cancel'));
      await tick(tester);
      expect(find.text('Cancelled replacement'), findsNothing);
      expect(find.text('Cedar house'), findsWidgets);
      await choosePlanAction(tester, target, 'Rename plan');
      await saveName(tester, '   ');
      expect(find.text('Cedar house'), findsNothing);
      expect(find.text('Home safety plan'), findsWidgets);
      expectMetadataRequests(creates: 1);
      expect(remoteNames.values.single['name'], isNull);
      expect(remoteNames.values.single['nameRevision'], 2);
    },
  );

  testWidgets('failed rename keeps typed text and supports an explicit retry', (
    tester,
  ) async {
    initialize();
    await app.coordinator.createDraft();
    final target = app.coordinator.currentDraft().caseId;
    await openHome(tester);
    await plans(tester);
    await choosePlanAction(tester, target, 'Rename plan');
    store.failWrites = true;
    await saveName(tester, 'Retained name');
    expect(find.byKey(const ValueKey('plan-name-input')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('plan-name-input')))
          .controller!
          .text,
      'Retained name',
    );
    expect(
      find.textContaining('Fictional private storage failure'),
      findsNothing,
    );
    expect(title(tester, target), 'Home safety plan');
    store.failWrites = false;
    await tester.tap(find.byKey(const ValueKey('plan-name-save')));
    await tick(tester);
    await closePendingName(tester);
    expect(find.byKey(const ValueKey('plan-name-input')), findsNothing);
    expect(title(tester, target), 'Retained name');
    expectMetadataRequests();
  });

  testWidgets('managed rename ignores a late name read after disposal', (
    tester,
  ) async {
    initialize();
    await app.coordinator.createDraft();
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CaseHomeScreen(services: app),
                ),
              ),
              child: const Text('Open plans'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open plans'));
    await tick(tester);
    final target = app.coordinator.currentDraft().caseId;
    await plans(tester);
    store.delayedNameRead = Completer<Map<String, Object?>?>();
    await choosePlanAction(tester, target, 'Rename plan');
    expect(store.delayedNameReads, 1);
    expect(find.byKey(const ValueKey('plan-name-input')), findsNothing);
    store.delayedNameRead!.complete(null);
    await tick(tester);
    expect(find.byKey(const ValueKey('plan-name-input')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tick(tester);
    store.delayedNameRead = Completer<Map<String, Object?>?>();
    await choosePlanAction(tester, target, 'Rename plan');
    await tester.pumpWidget(
      const MaterialApp(
        key: ValueKey('outside-plans'),
        home: Scaffold(body: Text('Outside plans')),
      ),
    );
    await tick(tester);
    store.delayedNameRead!.complete(null);
    await tick(tester);
    expect(find.byType(CaseHomeScreen), findsNothing);
    expect(find.byKey(const ValueKey('plan-name-input')), findsNothing);
    expect(find.text('Outside plans'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expectMetadataRequests();
  });

  testWidgets('naming and saving work at 320px and 3.2x text', (tester) async {
    initialize();
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 3.2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await openHome(tester);
    await start(tester);
    expect(tester.takeException(), isNull);
    await saveName(tester, 'Cedar house');
    expect(find.byType(CaseWorkspaceScreen), findsOneWidget);
    expect(find.text('Cedar house'), findsWidgets);
    expect(tester.takeException(), isNull);
    expectMetadataRequests(creates: 1);
  });
}
