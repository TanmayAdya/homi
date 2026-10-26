import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/plan_name_dialog.dart';
import 'package:safe_at_home/shared/models/account_plan_name.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../case_discovery_api_client_test.dart' show jsonResponse, requestJson;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

class _Server {
  final names = <String, AccountPlanName>{};
  final saves = <PlanNameSaveRequest>[];
  bool offline = false, loseNextSaveReply = false;

  AccountPlanName renameElsewhere(String id, String name) {
    final next = AccountPlanName(
      caseId: id,
      name: name,
      nameRevision: names[id]!.nameRevision + 1,
      lastMutationId: 'other-device-${names[id]!.nameRevision + 1}',
    );
    names[id] = next;
    return next;
  }

  Future<MatchingHttpResponse> call(MatchingHttpRequest request) async {
    if (offline) {
      throw const MatchingTransportException(MatchingTransportFailure.network);
    }
    final body = requestJson(request);
    final id = body['caseId'] as String;
    switch (request.endpoint.path) {
      case '/v1/create-case':
        names[id] = AccountPlanName.initial(id);
        return jsonResponse({...body, 'revision': 1});
      case '/v2/read-plan-name':
        return jsonResponse(names[id]!.toJson());
      case '/v2/save-plan-name':
        final mutation = PlanNameSaveRequest.fromJson(body);
        saves.add(mutation);
        final previous = names[id]!;
        if (mutation.expectedNameRevision != previous.nameRevision) {
          return jsonResponse({
            'schemaVersion': '2',
            'error': {
              'code': 'PLAN_NAME_CONFLICT',
              'message': 'Fictional conflict',
            },
          }, status: 409);
        }
        names[id] = AccountPlanName(
          caseId: id,
          name: mutation.name,
          nameRevision: previous.nameRevision + 1,
          lastMutationId: mutation.mutationId,
        );
        if (loseNextSaveReply) {
          loseNextSaveReply = false;
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return jsonResponse(names[id]!.toJson());
      default:
        throw StateError(
          'Unexpected fictional route: ${request.endpoint.path}',
        );
    }
  }
}

void main() {
  late _Server server;
  late FakeTransport transport;
  late AppServices app;
  late String id;
  final field = find.byKey(const ValueKey('plan-name-input'));
  final save = find.byKey(const ValueKey('plan-name-save'));

  Future<void> preparePlan() async {
    server = _Server();
    transport = FakeTransport(server.call);
    app = services(MemoryPrivateStore(), transport);
    await app.coordinator.createDraft();
    id = app.coordinator.draft!.caseId;
    await app.coordinator.save();
    await app.coordinator.savePlanName(id, 'Original home');
  }

  tearDown(() {
    expect(
      transport.requests.every(
        (request) => {
          '/v1/create-case',
          '/v2/read-plan-name',
          '/v2/save-plan-name',
        }.contains(request.endpoint.path),
      ),
      true,
    );
    app.dispose();
    app.session.dispose();
  });

  Future<void> makeConflict() async {
    server.offline = true;
    await app.coordinator.savePlanName(id, 'My offline name');
    server.renameElsewhere(id, 'Name from another phone');
    server.offline = false;
    await app.coordinator.syncPlanName(id);
    expect(app.coordinator.nameSync!.hasConflict(id), true);
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showPlanNameDialog(
                  context: context,
                  defaultName: 'Home safety plan',
                  initialName: app.coordinator.planNameFor(id),
                  coordinator: app.coordinator,
                  caseId: id,
                  onSave: (name) => app.coordinator.savePlanName(id, name),
                ),
              ),
              child: const Text('Open name editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open name editor'));
    await tester.pumpAndSettle();
  }

  Future<void> revealAndTap(WidgetTester tester, Finder finder) async {
    await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
    await tester.pumpAndSettle();
    expect(finder.hitTestable(), findsOneWidget);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  for (final keepLocal in [false, true]) {
    final label = keepLocal ? 'Keep this device’s name' : 'Use account name';
    testWidgets(
      '$label binds the displayed revision and requires a fresh review',
      (tester) async {
        await preparePlan();
        await makeConflict();
        await openDialog(tester);
        expect(find.text('On this device: My offline name'), findsOneWidget);
        expect(
          find.text('In your account: Name from another phone'),
          findsOneWidget,
        );
        expect(tester.widget<TextField>(field).enabled, false);
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
        final choice = find.widgetWithText(TextButton, label);
        final renderedChoice = tester.widget<TextButton>(choice);
        final savesBefore = server.saves.length;

        final newer = server.renameElsewhere(id, 'A newer account name');
        await app.coordinator.nameSync!.accept(newer);
        renderedChoice.onPressed!();
        await tester.pumpAndSettle();
        expect(server.saves, hasLength(savesBefore));
        expect(server.names[id]!.name, 'A newer account name');
        expect(app.coordinator.nameSync!.hasConflict(id), true);
        expect(app.coordinator.planNameFor(id), 'My offline name');
        expect(
          find.text('In your account: A newer account name'),
          findsOneWidget,
        );

        await revealAndTap(tester, choice);
        expect(app.coordinator.nameSync!.hasConflict(id), false);
        expect(app.coordinator.nameSync!.pendingFor(id), false);
        final expected = keepLocal ? 'My offline name' : 'A newer account name';
        expect(app.coordinator.planNameFor(id), expected);
        expect(tester.widget<TextField>(field).controller!.text, expected);
        expect(tester.widget<TextField>(field).enabled, true);
        expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
        if (keepLocal) {
          expect(server.saves, hasLength(savesBefore + 1));
          expect(server.saves.last.expectedNameRevision, newer.nameRevision);
          expect(server.saves.last.name, 'My offline name');
          expect(server.names[id]!.nameRevision, newer.nameRevision + 1);
        } else {
          expect(server.saves, hasLength(savesBefore));
          expect(server.names[id]!.nameRevision, newer.nameRevision);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Check name sync settles a lost successful reply without a second save',
    (tester) async {
      await preparePlan();
      await openDialog(tester);
      await tester.enterText(field, 'Name with lost reply');
      tester.testTextInput.hide();
      server.loseNextSaveReply = true;
      await revealAndTap(tester, save);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(server.names[id]!.name, 'Name with lost reply');
      expect(app.coordinator.nameSync!.pendingFor(id), true);
      expect(find.textContaining('sync pending'), findsWidgets);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Name with lost reply',
      );
      expect(tester.widget<TextField>(field).enabled, false);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      final savesBefore = server.saves.length;

      await revealAndTap(tester, find.text('Check name sync'));
      expect(app.coordinator.nameSync!.pendingFor(id), false);
      expect(server.saves, hasLength(savesBefore));
      expect(find.text('Check name sync'), findsNothing);
      expect(find.text('Name saved to your account'), findsWidgets);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Name with lost reply',
      );
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await revealAndTap(tester, save);
      expect(find.byType(AlertDialog), findsNothing);
      expect(server.saves, hasLength(savesBefore));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'conflict is readable and actionable at 320 pixels with 3.2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 3.2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final semantics = tester.ensureSemantics();
      try {
        await preparePlan();
        await makeConflict();
        await openDialog(tester);
        expect(tester.takeException(), isNull);
        for (final label in [
          'On this device: My offline name',
          'In your account: Name from another phone',
          'Keep this device’s name',
        ]) {
          final text = find.text(label);
          await Scrollable.ensureVisible(tester.element(text), alignment: .5);
          await tester.pumpAndSettle();
          expect(text.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        final useAccount = find.widgetWithText(TextButton, 'Use account name');
        await Scrollable.ensureVisible(
          tester.element(useAccount),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(useAccount).label,
          contains('Use account name'),
        );
        await revealAndTap(tester, useAccount);
        expect(app.coordinator.planNameFor(id), 'Name from another phone');
        expect(app.coordinator.nameSync!.pendingFor(id), false);
        await revealAndTap(tester, save);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'changing the selected plan requires reopening conflict actions',
    (tester) async {
      await preparePlan();
      await makeConflict();
      await openDialog(tester);
      final originalId = id;
      final savesBefore = server.saves.length;
      await app.coordinator.createDraft();
      await tester.pumpAndSettle();
      await revealAndTap(
        tester,
        find.widgetWithText(TextButton, 'Keep this device’s name'),
      );
      expect(app.coordinator.nameSync!.pendingFor(originalId), true);
      expect(app.coordinator.planNameFor(originalId), 'My offline name');
      expect(server.saves, hasLength(savesBefore));
      expect(server.names[originalId]!.name, 'Name from another phone');
      expect(tester.takeException(), isNull);
    },
  );
}
