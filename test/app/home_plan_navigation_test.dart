import 'homi_navigation_support.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/features/settings/account_settings_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';

import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

const _first = '11111111-0000-4000-8000-000000000001';
const _second = '22222222-0000-4000-8000-000000000002';

class _DelayedKeysStore extends MemoryPrivateStore {
  Completer<List<String>>? keysGate;

  @override
  Future<List<String>> keys() => keysGate?.future ?? super.keys();
}

Future<void> _seed(
  MemoryPrivateStore store,
  String id,
  String city, {
  bool online = false,
}) async {
  final draft = CaseDraft.fromJson({
    'schemaVersion': '1',
    'caseId': id,
    'profile': {
      'city': city,
      'county': null,
      'healthPlan': null,
      'tenure': null,
      'ageYears': null,
      'householdSize': null,
      'annualIncomeUsd': null,
      'ownerConsentReported': null,
    },
    'unresolvedFields': <String>[],
    'findings': <Object>[],
  });
  await store.writeJson('case.$id', {
    'version': 1,
    'draft': draft.toJson(),
    'snapshot': online ? draft.atRevision(1).toJson() : null,
    'uncertain': false,
    'conflict': false,
  });
}

FakeTransport _transport({List<String> online = const []}) =>
    FakeTransport((request) async {
      if (request.endpoint.path != '/v2/list-cases') {
        throw StateError('Navigation must not write or open a different plan');
      }
      return http.jsonResponse({
        'schemaVersion': '2',
        'cases': [
          for (final id in online)
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
    });

Future<void> _mount(WidgetTester tester, AppServices app) async {
  addTearDown(() {
    app.dispose();
    app.session.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: SafeAtHomeTheme.light(),
      home: CaseHomeScreen(services: app),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tab(WidgetTester tester, String name) async {
  if (name == 'plans') {
    await openManagePlans(tester);
  } else if (name == 'account') {
    await tester.tap(find.byKey(const ValueKey('open-account')));
  } else {
    await tester.tap(
      find.byKey(ValueKey('plan-tab-${name == 'home' ? 'plan' : name}')),
    );
  }
  await tester.pumpAndSettle();
}

Future<void> _showDialogFrame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  final scrollable = find.byType(Scrollable).first;
  final position = tester.state<ScrollableState>(scrollable).position;
  position.jumpTo(position.minScrollExtent);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: scrollable,
    maxScrolls: 70,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

void _onlyDiscovery(FakeTransport transport) => expect(
  transport.requests.map((request) => request.endpoint.path),
  everyElement('/v2/list-cases'),
);

void main() {
  testWidgets(
    'Plan is the entry and tabs, Plans and Account never create a plan',
    (tester) async {
      final store = MemoryPrivateStore();
      final transport = _transport();
      final app = services(store, transport);
      await _mount(tester, app);

      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(find.text('Start your first home plan'), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-search')), findsNothing);
      expect(app.coordinator.draft, isNull);
      final generation = app.coordinator.generation;

      for (final (tab, empty) in [
        ('rooms', 'Rooms belong to a plan'),
        ('help', 'Find help'),
        ('tasks', 'Tasks belong to a plan'),
      ]) {
        await _tab(tester, tab);
        expect(find.text(empty), findsOneWidget, reason: tab);
        expect(find.text('Start your first home plan'), findsNothing);
        expect(app.coordinator.draft, isNull);
      }
      await _tab(tester, 'plans');
      expect(find.byKey(const ValueKey('plan-search')), findsOneWidget);
      await _tab(tester, 'account');
      expect(find.byType(AccountSettingsScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('plan-search')), findsOneWidget);
      await _tab(tester, 'home');
      expect(find.text('Start your first home plan'), findsOneWidget);
      expect(find.byType(AccountSettingsScreen), findsNothing);

      expect(app.coordinator.generation, generation);
      expect(app.coordinator.draft, isNull);
      expect(store.records, isEmpty);
      _onlyDiscovery(transport);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Selected plan opens inline without creating or reselecting', (
    tester,
  ) async {
    final store = MemoryPrivateStore();
    await _seed(store, _first, 'San José');
    final transport = _transport();
    final app = services(store, transport);
    await app.coordinator.restoreLocal(_first);
    final generation = app.coordinator.generation;
    final retained = jsonEncode(store.records);
    await _mount(tester, app);

    expect(find.byType(CaseWorkspaceScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.text('San José home plan'), findsWidgets);
    expect(app.coordinator.draft!.caseId, _first);
    expect(app.coordinator.generation, generation);
    expect(jsonEncode(store.records), retained);
    _onlyDiscovery(transport);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Plans searches loaded names and references without changing data',
    (tester) async {
      final store = MemoryPrivateStore();
      await _seed(store, _first, 'San José');
      await _seed(store, _second, 'Redwood City', online: true);
      final transport = _transport(online: [_second]);
      final app = services(store, transport);
      await _mount(tester, app);
      await _tab(tester, 'plans');
      final retained = jsonEncode(store.records);
      final search = find.byKey(const ValueKey('plan-search'));

      await tester.enterText(search, '  SAN JOSÉ  ');
      await tester.pumpAndSettle();
      final local = find.byKey(const ValueKey('local-case-$_first'));
      await _reveal(tester, local);
      expect(tester.widget<SahActionTile>(local).title, 'San José home plan');
      expect(find.byKey(const ValueKey('saved-case-$_second')), findsNothing);

      await _reveal(tester, search);
      await tester.enterText(search, '22222222');
      await tester.pumpAndSettle();
      final online = find.byKey(const ValueKey('saved-case-$_second'));
      await _reveal(tester, online);
      expect(
        tester.widget<SahActionTile>(online).title,
        'Redwood City home plan',
      );
      expect(find.byKey(const ValueKey('local-case-$_first')), findsNothing);

      await _reveal(tester, search);
      await tester.enterText(search, 'No matching fictional city');
      await tester.pumpAndSettle();
      await _reveal(tester, find.text('No loaded plans match'));
      expect(find.text('No loaded plans match'), findsOneWidget);
      await _tab(tester, 'home');
      await _tab(tester, 'plans');
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: search, matching: find.byType(EditableText)),
            )
            .controller
            .text,
        isEmpty,
      );
      await _reveal(tester, local);
      expect(local, findsOneWidget);
      await _reveal(tester, online);
      expect(online, findsOneWidget);

      expect(app.coordinator.draft, isNull);
      expect(jsonEncode(store.records), retained);
      _onlyDiscovery(transport);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelling a list deletion never selects or changes its plan', (
    tester,
  ) async {
    final store = MemoryPrivateStore();
    await _seed(store, _first, 'San José');
    await _seed(store, _second, 'Redwood City');
    final transport = _transport();
    final app = services(store, transport);
    await app.coordinator.restoreLocal(_first);
    final generation = app.coordinator.generation;
    final retained = jsonEncode(store.records);
    await _mount(tester, app);
    await _tab(tester, 'plans');

    final menu = find.byKey(const ValueKey('plan-actions-$_second'));
    await _reveal(tester, menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete plan'));
    await _showDialogFrame(tester);
    expect(find.text('Delete this plan?'), findsOneWidget);
    expect(find.text('Delete local plan'), findsOneWidget);
    expect(app.coordinator.draft!.caseId, _first);
    expect(app.coordinator.generation, generation);
    expect(jsonEncode(store.records), retained);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.coordinator.draft!.caseId, _first);
    expect(app.coordinator.generation, generation);
    expect(jsonEncode(store.records), retained);
    _onlyDiscovery(transport);
    expect(tester.takeException(), isNull);
  });

  testWidgets('receipt-only plans open recovery and never ordinary resume', (
    tester,
  ) async {
    final store = MemoryPrivateStore();
    await store.writeJson('case-delete.$_second', {'serverDeleted': true});
    final transport = _transport();
    final app = services(store, transport);
    final retained = jsonEncode(store.records);
    await _mount(tester, app);
    expect(find.byKey(const ValueKey('home-open-plans')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-open-plans')));
    await tester.pumpAndSettle();

    final pending = find.byKey(const ValueKey('pending-plan-$_second'));
    await _reveal(tester, pending);
    expect(find.byKey(const ValueKey('local-case-$_second')), findsNothing);
    expect(find.byKey(const ValueKey('saved-case-$_second')), findsNothing);
    final title = find.descendant(
      of: pending,
      matching: find.text('Home safety plan'),
    );
    await tester.tap(title);
    await _showDialogFrame(tester);
    expect(find.text('Check plan deletion'), findsOneWidget);
    expect(find.text('Check deletion status'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('confirm-delete-home-plan')),
      findsNothing,
    );
    expect(find.byType(CaseWorkspaceScreen), findsNothing);
    expect(app.coordinator.draft, isNull);
    expect(jsonEncode(store.records), retained);
    _onlyDiscovery(transport);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(jsonEncode(store.records), retained);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Plan management and deletion remain usable at 320px and 3.2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 3.2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final store = MemoryPrivateStore();
      await _seed(store, _first, 'San José');
      final transport = _transport();
      final app = services(store, transport);
      final retained = jsonEncode(store.records);
      await _mount(tester, app);
      expect(tester.takeException(), isNull);
      await _reveal(tester, find.byKey(const ValueKey('case-start')));
      expect(
        find.byKey(const ValueKey('case-start')).hitTestable(),
        findsOneWidget,
      );
      await _tab(tester, 'plans');
      final menu = find.byKey(const ValueKey('plan-actions-$_first'));
      await _reveal(tester, menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final delete = find.text('Delete plan');
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final cancel = find.text('Cancel');
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      expect(cancel.hitTestable(), findsOneWidget);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      await _tab(tester, 'account');
      expect(find.byType(AccountSettingsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _tab(tester, 'home');
      expect(find.byType(AccountSettingsScreen), findsNothing);
      expect(jsonEncode(store.records), retained);
      expect(app.coordinator.draft, isNull);
      _onlyDiscovery(transport);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving Account blocks interaction while deletion receipts reload',
    (tester) async {
      final store = _DelayedKeysStore();
      await _seed(store, _first, 'San José');
      final transport = _transport();
      final app = services(store, transport);
      await app.coordinator.restoreLocal(_first);
      final generation = app.coordinator.generation;
      await _mount(tester, app);
      await _tab(tester, 'account');
      expect(find.byType(AccountSettingsScreen), findsOneWidget);

      await store.writeJson('case-delete.$_first', {'serverDeleted': true});
      final retained = jsonEncode(store.records);
      final gate = Completer<List<String>>();
      store.keysGate = gate;
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey('active-plan-selector')),
            )
            .enabled,
        false,
      );
      final workspace = find.byType(CaseWorkspaceScreen);
      expect(
        find.ancestor(
          of: workspace,
          matching: find.byWidgetPredicate(
            (widget) => widget is IgnorePointer && widget.ignoring,
          ),
        ),
        findsWidgets,
      );

      store.keysGate = null;
      gate.complete(store.records.keys.toList());
      await tester.pumpAndSettle();
      expect(find.byType(CaseWorkspaceScreen), findsNothing);
      await openManagePlans(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('pending-plan-$_first')),
        findsOneWidget,
      );
      expect(app.coordinator.draft!.caseId, _first);
      expect(app.coordinator.generation, generation);
      expect(jsonEncode(store.records), retained);
      _onlyDiscovery(transport);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tab changes recheck a receipt added after discovery', (
    tester,
  ) async {
    final store = MemoryPrivateStore();
    await _seed(store, _first, 'San José');
    final transport = _transport();
    final app = services(store, transport);
    await app.coordinator.restoreLocal(_first);
    final generation = app.coordinator.generation;
    await _mount(tester, app);
    await store.writeJson('case-delete.$_first', {'serverDeleted': true});
    final retained = jsonEncode(store.records);
    await _tab(tester, 'rooms');
    expect(find.byType(CaseWorkspaceScreen), findsNothing);
    await openManagePlans(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pending-plan-$_first')), findsOneWidget);
    expect(app.coordinator.draft!.caseId, _first);
    expect(app.coordinator.generation, generation);
    expect(jsonEncode(store.records), retained);
    _onlyDiscovery(transport);
    expect(tester.takeException(), isNull);
  });
}
