import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/presentation/live_assessment_screen.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';

import '../features/assessment/home_safety/home_safety_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HomeSafetyCatalog catalog;
  setUpAll(() async => catalog = await HomeSafetyCatalog.load());
  testWidgets('legacy Rooms busy and failed device saves protect the shell', (
    tester,
  ) async {
    final h = await safetyHarness(loadedCatalog: catalog);
    addTearDown(h.services.dispose);
    final workspace = GlobalKey<CaseWorkspaceScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: CaseWorkspaceScreen(key: workspace, services: h.services),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('plan-tab-rooms')));
    await tester.pumpAndSettle();
    final legacy = tester.state<LiveAssessmentScreenState>(
      find.byType(LiveAssessmentScreen),
    );
    expect(legacy.initialized, isTrue);
    legacy.busy = true;
    expect(workspace.currentState!.canLeave, isFalse);
    expect(await workspace.currentState!.prepareToLeave(), isFalse);
    await tester.tap(find.byKey(const ValueKey('plan-tab-plan')));
    await tester.pumpAndSettle();
    expect(find.byType(LiveAssessmentScreen), findsOneWidget);
    expect(
      find.text('Finish saving before changing sections.'),
      findsOneWidget,
    );
    legacy.busy = false;
    legacy.session.localSaveFailed = true;
    expect(workspace.currentState!.canLeave, isFalse);
    expect(await workspace.currentState!.prepareToLeave(), isFalse);
    legacy.session.localSaveFailed = false;
    await tester.tap(find.byKey(const ValueKey('plan-tab-plan')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('case-plan-title')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy Rooms back and flush reach the actual embedded feature', (
    tester,
  ) async {
    final h = await safetyHarness(loadedCatalog: catalog);
    addTearDown(h.services.dispose);
    final workspace = GlobalKey<CaseWorkspaceScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: CaseWorkspaceScreen(key: workspace, services: h.services),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('plan-tab-rooms')));
    await tester.pumpAndSettle();
    final legacy = tester.state<LiveAssessmentScreenState>(
      find.byType(LiveAssessmentScreen),
    );
    legacy.session.flow.chooseLocation(AssessmentLocation.entrance);
    await tester.pump();
    expect(legacy.session.flow.canGoBack, isTrue);
    expect(workspace.currentState!.handleBack(), isTrue);
    await tester.pump();
    expect(legacy.session.flow.canGoBack, isFalse);
    bool? canLeave;
    unawaited(
      workspace.currentState!.prepareToLeave().then((value) {
        canLeave = value;
      }),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(
      canLeave,
      isTrue,
      reason: 'The legacy device journal must finish before leaving.',
    );
    final saved =
        jsonDecode(utf8.decode(h.store.bytes[legacy.session.localKey]!)) as Map;
    expect(saved['flow'], legacy.session.flow.toLocalJson());
    expect(tester.takeException(), isNull);
  });
}
