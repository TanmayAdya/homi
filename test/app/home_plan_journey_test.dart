import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/home_plan_journey.dart';

Widget _host(HomePlanJourney journey) => MaterialApp(
  theme: SafeAtHomeTheme.light(),
  home: Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: journey,
      ),
    ),
  ),
);

Finder _step(HomePlanStep step) =>
    find.byKey(ValueKey('home-plan-step-${step.name}'));

void main() {
  testWidgets('static guide describes the journey without claiming progress', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_host(const HomePlanJourney()));

      expect(find.text('Resident details'), findsOneWidget);
      expect(find.text('Rooms and concerns'), findsOneWidget);
      expect(find.text('Improvements and assistance'), findsOneWidget);
      expect(find.textContaining('Next step'), findsNothing);
      expect(find.textContaining('Complete'), findsNothing);
      for (final step in HomePlanStep.values) {
        final data = tester.getSemantics(_step(step)).getSemanticsData();
        expect(data.hasAction(SemanticsAction.tap), isFalse);
        expect(data.flagsCollection.isButton, isFalse);
        expect(data.label, startsWith('Step ${step.index + 1} of 3.'));
      }
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('shortcuts call only their action and label the suggested step', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final tapped = <HomePlanStep>[];
      await tester.pumpWidget(
        _host(
          HomePlanJourney(
            currentStep: HomePlanStep.assessment,
            onProfile: () => tapped.add(HomePlanStep.profile),
            onAssessment: () => tapped.add(HomePlanStep.assessment),
            onAssistance: () => tapped.add(HomePlanStep.assistance),
          ),
        ),
      );

      for (final step in HomePlanStep.values) {
        final finder = _step(step);
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        final data = tester.getSemantics(finder).getSemanticsData();
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        expect(data.flagsCollection.isButton, isTrue);
        expect(
          data.label.contains('Next step'),
          step == HomePlanStep.assessment,
        );
        expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }
      expect(tapped, HomePlanStep.values);
      expect(find.text('Step 2 · Next step'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    '320px and large text keep every shortcut readable and reachable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 3.2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final tapped = <HomePlanStep>[];
      await tester.pumpWidget(
        _host(
          HomePlanJourney(
            currentStep: HomePlanStep.profile,
            onProfile: () => tapped.add(HomePlanStep.profile),
            onAssessment: () => tapped.add(HomePlanStep.assessment),
            onAssistance: () => tapped.add(HomePlanStep.assistance),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      for (final step in HomePlanStep.values) {
        final title = find
            .descendant(of: _step(step), matching: find.byType(Text))
            .at(1);
        await tester.ensureVisible(title);
        await tester.pumpAndSettle();
        expect(title.hitTestable(), findsOneWidget);
        await tester.tap(title);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(tapped, HomePlanStep.values);
    },
  );
}
