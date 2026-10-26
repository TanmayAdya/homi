import 'homi_navigation_support.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/cases/case_display_details.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'case_local_durability_test.dart' show ControlledCaseStore, changeCity;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

class _ControlledReads extends MemoryPrivateStore {
  Future<List<String>> Function()? keyRead;
  Completer<Map<String, Object?>?>? caseRead;
  int caseReads = 0;

  @override
  Future<List<String>> keys() => keyRead?.call() ?? super.keys();

  @override
  Future<Map<String, Object?>?> readJson(String key) {
    if (key.startsWith('case.') && caseRead != null) {
      caseReads++;
      return caseRead!.future;
    }
    return super.readJson(key);
  }
}

MatchingHttpResponse _page({String? id}) => http.jsonResponse({
  'schemaVersion': '2',
  'cases': [
    if (id != null)
      {
        'caseId': id,
        'caseRevision': 1,
        'name': null,
        'nameRevision': 0,
        'lastMutationId': null,
      },
  ],
  'nextAfterCaseId': null,
});

const _onlineId = '10000000-0000-4000-8000-000000000001';

Future<void> _tick(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await _tick(tester);
  if (find.byKey(const PageStorageKey('manage-plans')).evaluate().isEmpty) {
    await openManagePlans(tester);
    await _tick(tester);
  }
  final scrollable = find.byType(Scrollable).first;
  final position = tester.state<ScrollableState>(scrollable).position;
  position.jumpTo(position.minScrollExtent);
  await _tick(tester);
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: scrollable,
    maxScrolls: 60,
  );
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await _tick(tester);
}

void main() {
  testWidgets(
    'saved plans use recorded city names and appear only once after restart',
    (tester) async {
      final store = MemoryPrivateStore();
      final previous = services(store, FakeTransport((_) async => _page()));
      await previous.coordinator.createDraft();
      final draft = changeCity(previous.coordinator.currentDraft(), 'San José');
      final id = draft.caseId;
      await store.writeJson('case.$id', {
        'version': 1,
        'draft': draft.toJson(),
        'snapshot': draft.atRevision(1).toJson(),
        'uncertain': false,
        'conflict': false,
      });
      previous.dispose();
      previous.session.dispose();
      final app = services(store, FakeTransport((_) async => _page(id: id)));
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await tester.pumpWidget(MaterialApp(home: CaseHomeScreen(services: app)));
      await tester.pumpAndSettle();
      final saved = find.byKey(ValueKey('saved-case-$id'));
      await _reveal(tester, saved);
      final card = tester.widget<SahActionTile>(saved);
      expect(card.title, 'San José home plan');
      expect(card.subtitle, 'Saved online · ${homePlanReference(id)}');
      expect(find.byKey(ValueKey('local-case-$id')), findsNothing);
      expect(
        find.text('Not saved online · check before continuing'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a plan without local details has a plain name and reference', (
    tester,
  ) async {
    final app = services(
      MemoryPrivateStore(),
      FakeTransport((_) async => _page(id: _onlineId)),
    );
    addTearDown(() {
      app.dispose();
      app.session.dispose();
    });
    await tester.pumpWidget(MaterialApp(home: CaseHomeScreen(services: app)));
    await tester.pumpAndSettle();
    final saved = find.byKey(const ValueKey('saved-case-$_onlineId'));
    await _reveal(tester, saved);
    final card = tester.widget<SahActionTile>(saved);
    expect(card.title, 'Home safety plan');
    expect(card.subtitle, 'Saved online · Reference 10000000');
    expect(card.subtitle, isNot(contains('revision')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large-text device draft opens while online discovery is still waiting',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 3.2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final remote = Completer<MatchingHttpResponse>();
      final transport = FakeTransport((_) => remote.future);
      final app = services(MemoryPrivateStore(), transport);
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await app.coordinator.createDraft();
      final id = app.coordinator.currentDraft().caseId;
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: CaseHomeScreen(services: app),
        ),
      );
      await _tick(tester);
      final local = find.byKey(ValueKey('local-case-$id'));
      final localTitle = find.descendant(
        of: local,
        matching: find.text('Home safety plan'),
      );
      await _reveal(tester, localTitle);
      expect(remote.isCompleted, false);
      expect(tester.widget<SahActionTile>(local).onTap, isNotNull);
      expect(localTitle.hitTestable(), findsOneWidget);
      await tester.tap(localTitle);
      await _tick(tester);
      expect(find.byType(CaseWorkspaceScreen), findsOneWidget);
      expect(app.coordinator.currentDraft().caseId, id);
      expect(transport.requests, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      remote.complete(_page());
      await _tick(tester);
    },
  );

  testWidgets(
    'return publishes a new local case and coalesces discovery into one refresh',
    (tester) async {
      final first = Completer<MatchingHttpResponse>();
      final second = Completer<MatchingHttpResponse>();
      var calls = 0;
      final transport = FakeTransport((request) {
        if (request.endpoint.path == '/v1/create-case') {
          return Future.value(http.apiError('SERVICE_UNAVAILABLE', 503));
        }
        expect(request.endpoint.path, '/v2/list-cases');
        calls++;
        if (calls == 1) return first.future;
        if (calls == 2) return second.future;
        throw StateError('Discovery must not retry its own failure');
      });
      final app = services(MemoryPrivateStore(), transport);
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await tester.pumpWidget(MaterialApp(home: CaseHomeScreen(services: app)));
      await _tick(tester);
      await tester.tap(find.byKey(const ValueKey('case-start')));
      await _tick(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('plan-name-save')));
      await tester.tap(find.byKey(const ValueKey('plan-name-save')));
      await _tick(tester);
      final created = app.coordinator.currentDraft().caseId;
      expect(find.byType(CaseWorkspaceScreen), findsOneWidget);
      await openManagePlans(tester);
      await _tick(tester);
      await _reveal(tester, find.byKey(ValueKey('local-case-$created')));
      final refresh = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator),
      );
      await refresh.onRefresh();
      await refresh.onRefresh();
      expect(calls, 1);
      first.complete(_page(id: _onlineId));
      await _tick(tester);
      expect(calls, 2);
      expect(find.byKey(const ValueKey('saved-case-$_onlineId')), findsNothing);
      expect(find.byKey(ValueKey('local-case-$created')), findsOneWidget);
      second.completeError(StateError('Fictional offline connection'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      await _reveal(tester, find.text('Saved cases are unavailable'));
      expect(find.text('Saved cases are unavailable'), findsOneWidget);
      await _reveal(tester, find.byKey(ValueKey('local-case-$created')));
      expect(
        tester
            .widget<SahActionTile>(find.byKey(ValueKey('local-case-$created')))
            .onTap,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delayed local and online results cannot publish after the owner epoch ends',
    (tester) async {
      final local = Completer<List<String>>();
      final remote = Completer<MatchingHttpResponse>();
      final store = _ControlledReads()..keyRead = () => local.future;
      final app = services(store, FakeTransport((_) => remote.future));
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await tester.pumpWidget(MaterialApp(home: CaseHomeScreen(services: app)));
      await _tick(tester);
      final session = app.session as FakeSession;
      await session.signOut();
      session.owner = 'fictional-owner';
      local.complete(['case.$_onlineId']);
      remote.complete(_page(id: _onlineId));
      await _tick(tester);
      expect(find.byKey(const ValueKey('local-case-$_onlineId')), findsNothing);
      expect(find.byKey(const ValueKey('saved-case-$_onlineId')), findsNothing);
      expect(find.text('Saved cases are unavailable'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late draft restore cannot navigate after sign-out or start twice',
    (tester) async {
      final remote = Completer<MatchingHttpResponse>();
      final store = _ControlledReads();
      final app = services(store, FakeTransport((_) => remote.future));
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await app.coordinator.createDraft();
      final id = app.coordinator.currentDraft().caseId;
      final retained = store.records['case.$id'];
      store.caseRead = Completer<Map<String, Object?>?>();
      await tester.pumpWidget(MaterialApp(home: CaseHomeScreen(services: app)));
      await _tick(tester);
      final local = find.byKey(ValueKey('local-case-$id'));
      await _reveal(tester, local);
      final readsBeforeOpen = store.caseReads;
      final open = tester.widget<SahActionTile>(local).onTap!;
      open();
      open();
      await _tick(tester);
      expect(store.caseReads, readsBeforeOpen + 1);
      await app.session.signOut();
      store.caseRead!.complete(retained);
      remote.complete(_page());
      await _tick(tester);
      expect(find.byType(CaseWorkspaceScreen), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a failed local refresh keeps plans visible but blocks resume', (
    tester,
  ) async {
    final store = _ControlledReads();
    final app = services(store, FakeTransport((_) async => _page()));
    addTearDown(() {
      app.dispose();
      app.session.dispose();
    });
    await app.coordinator.createDraft();
    final id = app.coordinator.currentDraft().caseId;
    await tester.pumpWidget(MaterialApp(home: CaseHomeScreen(services: app)));
    await tester.pumpAndSettle();
    final local = find.byKey(ValueKey('local-case-$id'));
    await _reveal(tester, local);
    store.keyRead = () async => throw StateError('Fictional device error');
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    await _reveal(tester, local);
    expect(local, findsOneWidget);
    expect(tester.widget<SahActionTile>(local).onTap, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an older local read cannot replace a newer device list', (
    tester,
  ) async {
    final firstLocal = Completer<List<String>>();
    final remote = Completer<MatchingHttpResponse>();
    final store = _ControlledReads();
    final app = services(store, FakeTransport((_) => remote.future));
    addTearDown(() {
      app.dispose();
      app.session.dispose();
    });
    await app.coordinator.createDraft();
    final id = app.coordinator.currentDraft().caseId;
    store.keyRead = () => firstLocal.future;
    await tester.pumpWidget(MaterialApp(home: CaseHomeScreen(services: app)));
    await _tick(tester);
    store.keyRead = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _tick(tester);
    final local = find.byKey(ValueKey('local-case-$id'));
    await _reveal(tester, local);
    expect(local, findsOneWidget);
    firstLocal.complete([]);
    await _tick(tester);
    expect(local, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    remote.complete(_page());
    await _tick(tester);
  });

  testWidgets(
    'pending discovery never bypasses the undurable selection guard',
    (tester) async {
      final remote = Completer<MatchingHttpResponse>();
      final store = ControlledCaseStore();
      final app = services(store, FakeTransport((_) => remote.future));
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await app.coordinator.createDraft();
      final id = app.coordinator.currentDraft().caseId;
      store.hold = true;
      final saving = app.coordinator.updateDraft(
        changeCity(app.coordinator.currentDraft(), 'Fictional unsaved detail'),
      );
      await tester.pumpWidget(MaterialApp(home: CaseHomeScreen(services: app)));
      await _tick(tester);
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey('active-plan-selector')),
            )
            .enabled,
        false,
      );
      await tester.tap(find.byKey(const ValueKey('plan-tab-help')));
      await _tick(tester);
      expect(
        find.text('Finish saving before changing sections.'),
        findsOneWidget,
      );
      expect(find.byType(CaseWorkspaceScreen), findsOneWidget);
      expect(app.coordinator.currentDraft().caseId, id);
      expect(
        app.coordinator.currentDraft().profile.city,
        'Fictional unsaved detail',
      );
      store.pending.single.complete();
      await saving;
      remote.complete(_page());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
